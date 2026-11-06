// World control for unattended benches (development tool): dev pad commands that call the
// game's own script natives to put the player somewhere, give them a car and let the game's
// driving AI take it through the city.
//
// Natives are called from inside a running script thread, as a script would call them: the
// WAIT native (every script calls it every frame) is wrapped while the dev pad is enabled, and
// queued jobs run in the wrapper before the original WAIT. Entities created there (CREATE_CAR)
// belong to that script thread, like any mission entity. Nothing here is active unless
// gta4_pad_script or gta4_pad_pipe is set.
//
//   await [timeout]                 until the world runs (the save is loaded, no loading screen)
//   road <x> <y> <z>                the player on foot onto the road node closest to x y z
//   teleport <x> <y> <z> [heading]  the player on foot to x y z
//   car <model>                     a car at the player (model name: sultan, comet, ...), player inside
//   drive <speed m/s> [style]       the game's AI drives the player's car around the city (wander)
//   goto <x> <y> <z> [speed m/s]    the game's AI drives the player's car to x y z
//   blips                           every map blip and its coordinates (a mission's destination)
//   clock <hour> <minute>   weather <0..7>   invincible   nowanted
//   heli <model> [lift m]           a helicopter lift metres above the player (blades at full
//                                   speed), player inside; fly it with the pad (rt climbs, ly pitches)
//   water [radius m] | water <x> <y>  the player on foot into the nearest open water (water 50 m
//                                   around in all directions; swimming), e.g. before `car jetmax`
//   weapon <id> [ammo]              give and select a weapon (7 pistol, 10 shotgun, 12 uzi,
//                                   14 ak47, 15 m4, 18 rocket launcher)
//   peds [count] [hostile 0|1] [radius m]   random peds in a ring around the player; hostile
//                                   ones get a pistol and attack the player
//   cars <model> [count] [radius m] parked cars in a ring around the player
//   explode [count]                 blow up the oldest cars made by `cars`
//   boom [distance m] [type] [radius m]  an explosion ahead of the player
//   where                           log and reply the player position, car/water flags, health
//   native <NAME> [args]            any native: ints, floats (with a '.'), $ped, $player, $car
//                                   (last car made), out (an out slot), "text" (a string, may
//                                   hold spaces); replies value and outs
//   cutscene <name> [timeout s]     play a cutscene (cuts.img name without .cut: intro, rom2_a,
//                                   ...): INIT_CUTSCENE, wait until loaded, START_CUTSCENE, wait
//                                   until HAS_CUTSCENE_FINISHED, CLEAR_CUTSCENE (default 300 s)
//
// Coordinates are world metres: Algonquin is west (x < 600), Broker and Dukes east (Hove Beach
// safehouse ~ 892 -500, Downtown Broker ~ 1040 150). Early in the story Algonquin is closed and
// entering it gives six stars; `nowanted` keeps the police off anyway.

#include <array>
#include <fmt/format.h>
#include <algorithm>
#include <bit>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

#include <rex/logging.h>
#include <rex/memory/utils.h>
#include <rex/runtime.h>
#include <rex/system/function_dispatcher.h>
#include <rex/system/kernel_state.h>
#include <rex/system/xmemory.h>

#include "gta4_dev_pad.h"
#include "gta4_init.h"

namespace gta4::dev_pad {
namespace {

constexpr uint32_t kExecutingThread = 0x8319277C;  // the script thread running now
constexpr uint32_t kThreadName = 92;               // inline program name in a script thread
constexpr uint32_t kNativeReturnAddress = 0x82844BA0;  // inside the script VM's native call

bool Span(uint32_t address, uint32_t size, bool write) {
  auto* kernel = REX_KERNEL_STATE();
  auto* memory = kernel ? kernel->memory() : nullptr;
  if (!memory || !address || uint64_t(address) + size > uint64_t(UINT32_MAX) + 1) return false;
  auto* heap = memory->LookupHeap(address);
  const uint32_t last = uint32_t(uint64_t(address) + size - 1);
  if (!heap || heap != memory->LookupHeap(last)) return false;
  using rex::memory::PageAccess;
  const auto access = heap->QueryRangeAccess(address, last);
  return access == PageAccess::kReadWrite || access == PageAccess::kExecuteReadWrite ||
         (!write && (access == PageAccess::kReadOnly || access == PageAccess::kExecuteReadOnly));
}
uint32_t Read(uint8_t* base, uint32_t address) {
  uint32_t v;
  std::memcpy(&v, rex::memory::GuestPtr(base, address), 4);
  return __builtin_bswap32(v);
}
void Write(uint8_t* base, uint32_t address, uint32_t v) {
  v = __builtin_bswap32(v);
  std::memcpy(rex::memory::GuestPtr(base, address), &v, 4);
}
uint32_t F(float f) { return std::bit_cast<uint32_t>(f); }
float AsFloat(uint32_t v) { return std::bit_cast<float>(v); }

// GTA IV model and native names hash with Jenkins one-at-a-time over the lowercase name.
uint32_t Hash(std::string_view name) {
  uint32_t h = 0;
  for (char c : name) {
    if (c >= 'A' && c <= 'Z') c = char(c - 'A' + 'a');
    h += uint8_t(c);
    h += h << 10;
    h ^= h >> 6;
  }
  h += h << 3;
  h ^= h >> 11;
  h += h << 15;
  return h;
}

std::mutex g_native_mutex;
std::unordered_map<uint32_t, uint32_t> g_natives;     // name hash -> guest handler
std::unordered_map<std::string, uint32_t> g_hashes;   // name -> hash, where the name was seen
uint32_t g_wait_original = 0, g_wait_thunk = 0;
thread_local std::string t_registering;  // the name sub_82845600 is registering right now
bool g_hash_checked = false;

// One native call. An argument marked out points at a fresh slot; outs[i] holds its value.
struct Arg {
  uint32_t value = 0;
  bool out = false;
  std::string text;  // non-empty: a string copied into the call frame; the argument points at it
};
struct Result {
  bool called = false;
  uint32_t value = 0;
  std::vector<uint32_t> outs;
  std::vector<std::array<uint32_t, 3>> vectors;  // the first three words of each out slot (a Vector3 out)
};

class Invoker {
 public:
  static constexpr uint32_t kFrameBytes = 0x600;  // 0x400 call frame + 0x200 for string arguments

  Invoker(PPCContext& parent, uint8_t* base) : parent_(parent), base_(base) {}

  Result Call(std::string_view name, std::initializer_list<Arg> args) {
    return Call(name, std::vector<Arg>(args));
  }
  Result Call(std::string_view name, const std::vector<Arg>& args) {
    Result result;
    uint32_t address = 0;
    {
      std::lock_guard lock(g_native_mutex);
      const auto known = g_hashes.find(std::string(name));
      const uint32_t hash = known != g_hashes.end() ? known->second : Hash(name);
      if (auto it = g_natives.find(hash); it != g_natives.end()) address = it->second;
    }
    auto* runtime = rex::Runtime::instance();
    auto* dispatcher = runtime ? runtime->function_dispatcher() : nullptr;
    auto* function = dispatcher && address ? dispatcher->GetFunction(address) : nullptr;
    if (!function) {
      REXLOG_ERROR("dev world: native {} is not registered", name);
      return result;
    }
    if (args.size() > 16 || parent_.r1.u32 < kFrameBytes) return result;
    // A frame below the caller's stack: back chain, context, return slot, arguments, outs,
    // string arguments.
    const uint32_t frame = (parent_.r1.u32 - kFrameBytes) & ~15u;
    if (!Span(frame, kFrameBytes, true)) return result;
    const uint32_t context = frame + 0x80, ret = frame + 0xC0, argv = frame + 0x100,
                   outs = frame + 0x180, strings = frame + 0x400;
    std::memset(rex::memory::GuestPtr(base_, frame + 0x80), 0, kFrameBytes - 0x80);
    uint32_t text_used = 0;
    for (const Arg& a : args) {
      if (a.text.empty()) continue;
      if (text_used + a.text.size() + 1 > kFrameBytes - 0x400) {
        REXLOG_ERROR("dev world: native {} string arguments exceed {} bytes", name, kFrameBytes - 0x400);
        return result;
      }
      std::memcpy(rex::memory::GuestPtr(base_, strings + text_used), a.text.data(), a.text.size());
      text_used += (uint32_t(a.text.size()) + 4) & ~3u;  // NUL included (the frame is zeroed)
    }
    Write(base_, frame, parent_.r1.u32);
    Write(base_, context, ret);
    Write(base_, context + 4, uint32_t(args.size()));
    Write(base_, context + 8, argv);
    uint32_t i = 0, out_count = 0, text_at = 0;
    for (const Arg& a : args) {
      uint32_t value = a.value;
      if (a.out) {
        value = outs + 16 * out_count++;
      } else if (!a.text.empty()) {
        value = strings + text_at;
        text_at += (uint32_t(a.text.size()) + 4) & ~3u;
      }
      Write(base_, argv + i * 4, value);
      ++i;
    }
    // Slots past the given arguments point at scratch memory: a native that takes more
    // arguments than we passed (a wrong signature) writes there instead of guest address 0.
    for (uint32_t spare = 0; i < 32; ++i, ++spare) Write(base_, argv + i * 4, outs + 16 * (24 + spare % 16));
    PPCContext call = parent_;
    call.r1.u32 = frame;
    call.r3.u32 = context;
    call.lr = kNativeReturnAddress;
    function(call, base_);
    result.called = true;
    result.value = Read(base_, ret);
    for (uint32_t o = 0; o < out_count; ++o) {
      result.outs.push_back(Read(base_, outs + 16 * o));
      result.vectors.push_back({Read(base_, outs + 16 * o), Read(base_, outs + 16 * o + 4),
                                Read(base_, outs + 16 * o + 8)});
    }
    return result;
  }

 private:
  PPCContext& parent_;
  uint8_t* base_;
};

// A job runs on a script thread, once per frame until it returns a reply.
using Job = std::function<std::optional<std::string>(Invoker&)>;
struct Pending {
  Job job;
  std::string reply;
  bool done = false;
};
std::mutex g_job_mutex;
std::condition_variable g_job_done;
std::deque<std::shared_ptr<Pending>> g_jobs;

std::string RunOnScriptThread(Job job, std::chrono::seconds timeout = std::chrono::seconds(60)) {
  if (!g_wait_thunk) return "err the WAIT native was not wrapped (dev pad off at startup?)";
  auto pending = std::make_shared<Pending>();
  pending->job = std::move(job);
  std::unique_lock lock(g_job_mutex);
  g_jobs.push_back(pending);
  if (!g_job_done.wait_for(lock, timeout, [&] { return pending->done; })) {
    std::erase(g_jobs, pending);
    return "err timed out waiting for a script thread";
  }
  return pending->reply;
}

std::string ThreadName(uint8_t* base, uint32_t thread) {
  std::string name;
  for (uint32_t i = 0; i < 64; ++i) {
    const char c = char(*rex::memory::GuestPtr(base, thread + kThreadName + i));
    if (!c) break;
    name.push_back(c >= 'A' && c <= 'Z' ? char(c - 'A' + 'a') : c);
  }
  return name;
}

void RunJobs(PPCContext& ctx, uint8_t* base) {
  std::shared_ptr<Pending> pending;
  {
    std::lock_guard lock(g_job_mutex);
    if (g_jobs.empty()) return;
    pending = g_jobs.front();
  }
  // Prefer the persistent "main" script: its entities live as long as the session.
  if (!Span(kExecutingThread, 4, false)) return;
  const uint32_t thread = Read(base, kExecutingThread);
  if (!thread || !Span(thread + kThreadName, 64, false) || ThreadName(base, thread) != "main")
    return;
  Invoker invoker(ctx, base);
  std::optional<std::string> reply = pending->job(invoker);
  if (!reply) return;
  std::lock_guard lock(g_job_mutex);
  pending->reply = std::move(*reply);
  pending->done = true;
  std::erase(g_jobs, pending);
  g_job_done.notify_all();
}

void WaitWrapper(PPCContext& ctx, uint8_t* base) {
  RunJobs(ctx, base);
  auto* runtime = rex::Runtime::instance();
  auto* dispatcher = runtime ? runtime->function_dispatcher() : nullptr;
  if (auto* original = dispatcher ? dispatcher->GetFunction(g_wait_original) : nullptr)
    original(ctx, base);
}

// Player handles, fetched in every job (handles stay valid while the session lasts).
struct Player {
  uint32_t id = 0, ped = 0;
  bool ok = false;
};
Player GetPlayer(Invoker& n) {
  Player p;
  const Result id = n.Call("GET_PLAYER_ID", {});
  if (!id.called) return p;
  p.id = id.value;
  const Result ped = n.Call("GET_PLAYER_CHAR", {{p.id}, {0, true}});
  if (!ped.called || ped.outs.empty() || !ped.outs[0]) return p;
  p.ped = ped.outs[0];
  p.ok = true;
  return p;
}

bool ParseFloat(const std::string& text, float& out) {
  char* end = nullptr;
  out = std::strtof(text.c_str(), &end);
  return end && *end == '\0';
}

struct Vec3 {
  float x = 0, y = 0, z = 0;
};
std::optional<Vec3> Position(Invoker& n, uint32_t ped) {
  const Result pos = n.Call("GET_CHAR_COORDINATES", {{ped}, {0, true}, {0, true}, {0, true}});
  if (pos.outs.size() < 3) return std::nullopt;
  return Vec3{AsFloat(pos.outs[0]), AsFloat(pos.outs[1]), AsFloat(pos.outs[2])};
}
float Heading(Invoker& n, uint32_t ped) {
  const Result h = n.Call("GET_CHAR_HEADING", {{ped}, {0, true}});
  return h.outs.empty() ? 0.0f : AsFloat(h.outs[0]);
}
// GTA headings: degrees counterclockwise from north (+y).
Vec3 Ahead(const Vec3& from, float heading, float distance) {
  const float r = heading * 0.0174533f;
  return {from.x - std::sin(r) * distance, from.y + std::cos(r) * distance, from.z};
}
bool InAnyCar(Invoker& n, uint32_t ped) {
  const Result r = n.Call("IS_CHAR_IN_ANY_CAR", {{ped}});
  return r.called && r.value;
}
// The player on foot at x y z, out of any car first.
void PutPlayer(Invoker& n, uint32_t ped, const Vec3& at) {
  if (InAnyCar(n, ped))
    n.Call("WARP_CHAR_FROM_CAR_TO_COORD", {{ped}, {F(at.x)}, {F(at.y)}, {F(at.z)}});
  else
    n.Call("SET_CHAR_COORDINATES", {{ped}, {F(at.x)}, {F(at.y)}, {F(at.z)}});
}

// Entities the bench commands made (handles; only touched on the script thread).
std::deque<uint32_t> g_bench_cars;
uint32_t g_last_car = 0;

}  // namespace

void ObserveNativeRegistration(PPCContext& ctx, uint8_t* base) {
  if (!WorldEnabled()) return;
  std::string name;
  for (uint32_t i = 0; i < 96 && Span(ctx.r3.u32 + i, 1, false); ++i) {
    const char c = char(*rex::memory::GuestPtr(base, ctx.r3.u32 + i));
    if (!c) break;
    name.push_back(c);
  }
  t_registering = std::move(name);
}

}  // namespace gta4::dev_pad

// The native table insert (table, name hash, handler): every native passes here, those named
// through sub_82845600 and the built-in commands (WAIT among them) registered directly.
extern "C" void __imp__sub_82846948(PPCContext& ctx, uint8_t* base);
extern "C" void sub_82846948(PPCContext& ctx, uint8_t* base) {
  using namespace gta4::dev_pad;
  if (WorldEnabled()) {
    const uint32_t hash = ctx.r4.u32, handler = ctx.r5.u32;
    {
      std::lock_guard lock(g_native_mutex);
      g_natives[hash] = handler;
      if (!t_registering.empty()) {
        g_hashes[t_registering] = hash;
        if (!g_hash_checked) {
          g_hash_checked = true;
          if (Hash(t_registering) != hash)
            REXLOG_WARN("dev world: native hash differs from one-at-a-time: {} {:08X} != {:08X}",
                        t_registering, hash, Hash(t_registering));
        }
      }
    }
    t_registering.clear();
    if (hash == Hash("WAIT") && handler != g_wait_thunk) {
      auto* runtime = rex::Runtime::instance();
      auto* dispatcher = runtime ? runtime->function_dispatcher() : nullptr;
      if (dispatcher) {
        g_wait_original = handler;
        if (!g_wait_thunk) g_wait_thunk = dispatcher->AllocateThunk(WaitWrapper, uint32_t(ctx.lr));
        if (g_wait_thunk) {
          ctx.r5.u32 = g_wait_thunk;
          REXLOG_INFO("dev world: WAIT {:08X} wrapped through {:08X}", handler, g_wait_thunk);
        }
      }
    }
  }
  __imp__sub_82846948(ctx, base);
}

namespace gta4::dev_pad {

// native <NAME> [args]: ints, floats (with a '.'), $ped, $player, $car (the last car made) and
// out (an out slot). For trying natives from a pad without a rebuild.
std::string NativeCommand(const std::vector<std::string>& args) {
  if (args.size() < 2) return "err native needs a name";
  const std::string name = args[1];
  // "a quoted string" may span several words: join them back (single spaces).
  std::vector<std::string> words;
  for (size_t i = 2; i < args.size(); ++i) {
    std::string w = args[i];
    if (w.size() > 1 && w.front() == '"' && w.back() != '"') {
      while (++i < args.size()) {
        w += ' ' + args[i];
        if (args[i].back() == '"') break;
      }
    }
    if (w.front() == '"' && (w.size() < 2 || w.back() != '"')) return "err unterminated string " + w;
    words.push_back(std::move(w));
  }
  for (const auto& w : words) {
    if (w == "$ped" || w == "$player" || w == "$car" || w == "out" || w.front() == '"') continue;
    float v;
    if (!ParseFloat(w, v)) return "err '" + w + "' is not a number";
  }
  return RunOnScriptThread([=](Invoker& n) -> std::optional<std::string> {
    const Player p = GetPlayer(n);
    if (!p.ok) return "err no player";
    std::vector<Arg> call;
    for (const auto& w : words) {
      if (w == "$ped") call.push_back({p.ped});
      else if (w == "$player") call.push_back({p.id});
      else if (w == "$car") call.push_back({g_last_car});
      else if (w == "out") call.push_back({0, true});
      else if (w.front() == '"') {
        if (w.size() == 2) return "err empty string argument";
        call.push_back({0, false, w.substr(1, w.size() - 2)});
      }
      else if (w.find('.') != std::string::npos) call.push_back({F(std::strtof(w.c_str(), nullptr))});
      else call.push_back({uint32_t(std::strtol(w.c_str(), nullptr, 0))});
    }
    const Result r = n.Call(name, call);
    if (!r.called) return "err native " + name + " was not called";
    std::string reply = "ok " + std::to_string(r.value);
    for (uint32_t o : r.outs) {
      char b[48];
      std::snprintf(b, sizeof(b), " %u/%g", o, AsFloat(o));
      reply += b;
    }
    REXLOG_INFO("dev world: native {} -> {}", name, reply.substr(3));
    return reply;
  });
}

// cutscene <name> [timeout s]: the sequence a mission script uses, from the "main" script.
std::string CutsceneCommand(const std::vector<std::string>& args) {
  if (args.size() < 2) return "err cutscene needs a name (cuts.img, without .cut)";
  const std::string name = args[1];
  float timeout = 300.0f;
  if (args.size() > 2 && (!ParseFloat(args[2], timeout) || timeout <= 0)) return "err bad timeout " + args[2];
  int stage = 0, frames = 0, loaded_at = 0;
  const auto started = std::chrono::steady_clock::now();
  return RunOnScriptThread(
      [=](Invoker& n) mutable -> std::optional<std::string> {
        ++frames;
        const double seconds =
            std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
        if (stage == 0) {
          if (!n.Call("INIT_CUTSCENE", {{0, false, name}}).called) return "err INIT_CUTSCENE was not called";
          REXLOG_INFO("dev world: cutscene {} init", name);
          stage = 1;
          return std::nullopt;
        }
        if (stage == 1) {
          const Result loaded = n.Call("HAS_CUTSCENE_LOADED", {});
          if (!loaded.called || !loaded.value) {
            if (seconds < 60.0) return std::nullopt;
            n.Call("CLEAR_CUTSCENE", {});
            return "err cutscene " + name + " did not load in 60 s";
          }
          n.Call("START_CUTSCENE", {});
          loaded_at = frames;
          REXLOG_INFO("dev world: cutscene {} loaded after {} frames, started", name, frames);
          stage = 2;
          return std::nullopt;
        }
        const Result finished = n.Call("HAS_CUTSCENE_FINISHED", {});
        // A start takes a few frames to show as running: finished counts after 30 frames.
        const bool done = finished.called && finished.value && frames - loaded_at > 30;
        if (!done && seconds < timeout) return std::nullopt;
        n.Call("CLEAR_CUTSCENE", {});
        const std::string reply = "ok " + name + (done ? " finished" : " timed out") +
                                  " frames=" + std::to_string(frames - loaded_at) +
                                  " seconds=" + std::to_string(int(seconds));
        REXLOG_INFO("dev world: cutscene {}", reply.substr(3));
        return reply;
      },
      std::chrono::seconds(int(timeout) + 70));
}

std::string WorldCommand(const std::vector<std::string>& args) {
  const std::string& cmd = args[0];
  if (cmd == "native") return NativeCommand(args);
  if (cmd == "cutscene") return CutsceneCommand(args);
  // These take a model name first; the numbers follow it.
  const bool named = cmd == "car" || cmd == "heli" || cmd == "cars";
  std::vector<float> f;
  for (size_t i = named ? 2 : 1; i < args.size(); ++i) {
    float v;
    if (!ParseFloat(args[i], v)) return "err '" + args[i] + "' is not a number";
    f.push_back(v);
  }

  if (cmd == "teleport" || cmd == "road") {
    if (f.size() < 3) return "err " + cmd + " needs x y z";
    const bool road = cmd == "road";
    const float x = f[0], y = f[1], z = f[2], heading = f.size() > 3 ? f[3] : 0.0f;
    int stage = 0;
    float rx = x, ry = y, rz = z, rh = heading;
    return RunOnScriptThread([=](Invoker& n) mutable -> std::optional<std::string> {
      const Player p = GetPlayer(n);
      if (!p.ok) return "err no player";
      if (stage == 0) {
        // Move first so the streaming around the target starts, then load it fully. Out of
        // any car (boat, helicopter) first, so the vehicle stays behind.
        PutPlayer(n, p.ped, {x, y, z});
        n.Call("LOAD_SCENE", {{F(x)}, {F(y)}, {F(z)}});
        stage = 1;
        return std::nullopt;
      }
      if (road) {
        // Path nodes stream by region around the player, so the nearest node can first come
        // from the area left behind: retry (up to ~10 s) until one lies near the target. The
        // heading points from the nearest node to the second nearest, along the road.
        ++stage;
        const Result first = n.Call("GET_CLOSEST_CAR_NODE",
                                    {{F(x)}, {F(y)}, {F(z)}, {0, true}, {0, true}, {0, true}});
        const Result second = n.Call("GET_NTH_CLOSEST_CAR_NODE",
                                     {{F(x)}, {F(y)}, {F(z)}, {2}, {0, true}, {0, true}, {0, true}});
        const bool found = first.called && first.value && first.outs.size() == 3;
        const float nx = found ? AsFloat(first.outs[0]) : 0, ny = found ? AsFloat(first.outs[1]) : 0;
        const bool near = found && std::hypot(nx - x, ny - y) < 60.0f;
        if (!near && stage < 600) return std::nullopt;
        if (!found) return "err no road node near " + std::to_string(x) + " " + std::to_string(y);
        rx = nx;
        ry = ny;
        rz = AsFloat(first.outs[2]);
        if (second.called && second.value && second.outs.size() == 3) {
          const float dx = AsFloat(second.outs[0]) - rx, dy = AsFloat(second.outs[1]) - ry;
          // GTA headings: degrees counterclockwise from north (+y).
          if (dx != 0 || dy != 0) rh = std::atan2(-dx, dy) * 57.29578f;
        }
        if (!near)
          REXLOG_WARN("dev world: road node {:.0f} m from the target after {} frames",
                      std::hypot(nx - x, ny - y), stage);
      }
      n.Call("SET_CHAR_COORDINATES", {{p.ped}, {F(rx)}, {F(ry)}, {F(rz)}});
      n.Call("SET_CHAR_HEADING", {{p.ped}, {F(rh)}});
      char buffer[96];
      std::snprintf(buffer, sizeof(buffer), "ok %.1f %.1f %.1f heading %.0f", rx, ry, rz, rh);
      REXLOG_INFO("dev world: {} -> {}", cmd, buffer + 3);
      return std::string(buffer);
    }, std::chrono::seconds(120));
  }

  if (cmd == "car" || cmd == "heli") {
    if (args.size() < 2) return "err " + cmd + " needs a model name";
    const bool heli = cmd == "heli";
    const float lift = heli ? (f.empty() ? 40.0f : f[0]) : 0.0f;
    const uint32_t model = Hash(args[1]);
    const std::string model_name = args[1];
    int frames = 0;
    return RunOnScriptThread([=](Invoker& n) mutable -> std::optional<std::string> {
      const Player p = GetPlayer(n);
      if (!p.ok) return "err no player";
      if (frames++ == 0) n.Call("REQUEST_MODEL", {{model}});
      const Result loaded = n.Call("HAS_MODEL_LOADED", {{model}});
      if (!loaded.called) return "err HAS_MODEL_LOADED failed";
      if (!loaded.value) return frames > 600 ? std::optional<std::string>("err model " + model_name +
                                                                          " did not load")
                                             : std::nullopt;
      const Result pos = n.Call("GET_CHAR_COORDINATES", {{p.ped}, {0, true}, {0, true}, {0, true}});
      const Result heading = n.Call("GET_CHAR_HEADING", {{p.ped}, {0, true}});
      if (pos.outs.size() < 3 || heading.outs.empty()) return "err cannot read the player position";
      const Result car = n.Call("CREATE_CAR", {{model}, {pos.outs[0]}, {pos.outs[1]},
                                               {F(AsFloat(pos.outs[2]) + lift)}, {0, true}, {1}});
      if (car.outs.empty() || !car.outs[0]) return "err CREATE_CAR made no car";
      const uint32_t vehicle = car.outs[0];
      g_last_car = vehicle;
      n.Call("SET_CAR_HEADING", {{vehicle}, {heading.outs[0]}});
      if (heli) {
        n.Call("SET_HELI_BLADES_FULL_SPEED", {{vehicle}});
      } else {
        n.Call("SET_CAR_ON_GROUND_PROPERLY", {{vehicle}});
      }
      n.Call("WARP_CHAR_INTO_CAR", {{p.ped}, {vehicle}});
      n.Call("MARK_MODEL_AS_NO_LONGER_NEEDED", {{model}});
      REXLOG_INFO("dev world: car {} ({:08X}) handle {} at {:.1f} {:.1f} {:.1f}", model_name, model,
                  vehicle, AsFloat(pos.outs[0]), AsFloat(pos.outs[1]), AsFloat(pos.outs[2]));
      return "ok car " + std::to_string(vehicle);
    });
  }

  if (cmd == "drive") {
    const float speed = f.empty() ? 15.0f : f[0];
    const uint32_t style = f.size() > 1 ? uint32_t(f[1]) : 0;
    return RunOnScriptThread([=](Invoker& n) -> std::optional<std::string> {
      const Player p = GetPlayer(n);
      if (!p.ok) return "err no player";
      const Result car = n.Call("GET_CAR_CHAR_IS_USING", {{p.ped}, {0, true}});
      if (car.outs.empty() || !car.outs[0]) return "err the player is not in a car";
      n.Call("TASK_CAR_DRIVE_WANDER", {{p.ped}, {car.outs[0]}, {F(speed)}, {style}});
      return "ok";
    });
  }

  if (cmd == "blips") {
    // Every map blip (types 1-8) with its coordinates, e.g. to read a mission's destination.
    return RunOnScriptThread([=](Invoker& n) -> std::optional<std::string> {
      std::string reply = "ok";
      for (uint32_t type = 1; type <= 8; ++type) {
        uint32_t blip = n.Call("GET_FIRST_BLIP_INFO_ID", {{type}}).value;
        for (int guard = 0; blip && guard < 64; ++guard) {
          const Result c = n.Call("GET_BLIP_COORDS", {{blip}, {0, true}});
          if (!c.vectors.empty())
            reply += fmt::format(" | type={} {:.1f} {:.1f} {:.1f}", type, AsFloat(c.vectors[0][0]),
                                 AsFloat(c.vectors[0][1]), AsFloat(c.vectors[0][2]));
          blip = n.Call("GET_NEXT_BLIP_INFO_ID", {{type}}).value;
        }
      }
      return reply;
    });
  }

  if (cmd == "goto") {
    // goto <x> <y> <z> [speed m/s]: the game's AI drives the player's car there (as a mission's
    // TASK_CAR_DRIVE_TO_COORD: obey roads, stop within 5 m).
    if (f.size() < 3) return "err goto needs x y z";
    const float x = f[0], y = f[1], z = f[2], speed = f.size() > 3 ? f[3] : 15.0f;
    return RunOnScriptThread([=](Invoker& n) -> std::optional<std::string> {
      const Player p = GetPlayer(n);
      if (!p.ok) return "err no player";
      const Result car = n.Call("GET_CAR_CHAR_IS_USING", {{p.ped}, {0, true}});
      if (car.outs.empty() || !car.outs[0]) return "err the player is not in a car";
      n.Call("TASK_CAR_DRIVE_TO_COORD", {{p.ped}, {car.outs[0]}, {F(x)}, {F(y)}, {F(z)}, {F(speed)},
                                         {1}, {0}, {2}, {F(5.0f)}, {uint32_t(-1)}});
      return "ok";
    });
  }

  if (cmd == "clock") {
    if (f.size() < 2) return "err clock needs hour minute";
    const uint32_t hour = uint32_t(f[0]), minute = uint32_t(f[1]);
    return RunOnScriptThread([=](Invoker& n) -> std::optional<std::string> {
      n.Call("SET_TIME_OF_DAY", {{hour}, {minute}});
      return "ok";
    });
  }

  if (cmd == "weather") {
    if (f.empty()) return "err weather needs 0..7";
    const uint32_t kind = uint32_t(f[0]);
    return RunOnScriptThread([=](Invoker& n) -> std::optional<std::string> {
      n.Call("FORCE_WEATHER_NOW", {{kind}});
      return "ok";
    });
  }

  if (cmd == "invincible" || cmd == "nowanted") {
    return RunOnScriptThread([=](Invoker& n) -> std::optional<std::string> {
      const Player p = GetPlayer(n);
      if (!p.ok) return "err no player";
      if (cmd == "invincible") {
        n.Call("SET_CHAR_INVINCIBLE", {{p.ped}, {1}});
      } else {
        // The police leave the player alone even where the story still closes an island (a
        // locked island gives six stars on entry; early saves have Algonquin closed).
        n.Call("SET_MAX_WANTED_LEVEL", {{0}});
        n.Call("SET_WANTED_MULTIPLIER", {{F(0.0f)}});
        n.Call("SET_POLICE_IGNORE_PLAYER", {{p.id}, {1}});
        n.Call("CLEAR_WANTED_LEVEL", {{p.id}});
      }
      return "ok";
    });
  }
  if (cmd == "water") {
    // water <x> <y>: there. water [radius]: the nearest open water around the player, ring by
    // ring (one ring per frame): water level within 5 m of the sea and the ground (where its
    // collision is loaded) at least 2 m below it.
    const bool at = f.size() >= 2;
    const float radius = !at && !f.empty() ? f[0] : 800.0f;
    const float tx = at ? f[0] : 0, ty = at ? f[1] : 0;
    int ring = -1;
    Vec3 center;
    return RunOnScriptThread([=](Invoker& n) mutable -> std::optional<std::string> {
      const Player p = GetPlayer(n);
      if (!p.ok) return "err no player";
      auto water_at = [&](float x, float y, float& level) {
        // GET_WATER_HEIGHT(x, y, z, &height): the water surface below z.
        const Result w = n.Call("GET_WATER_HEIGHT", {{F(x)}, {F(y)}, {F(50.0f)}, {0, true}});
        if (!w.called || !w.value || w.outs.empty()) return false;
        level = AsFloat(w.outs[0]);
        if (std::fabs(level) > 5.0f) return false;
        const Result g = n.Call("GET_GROUND_Z_FOR_3D_COORD", {{F(x)}, {F(y)}, {F(level + 60.0f)}, {0, true}});
        return !(g.called && !g.outs.empty() && AsFloat(g.outs[0]) != 0.0f &&
                 AsFloat(g.outs[0]) > level - 2.0f);
      };
      auto go = [&](float x, float y, float level) {
        PutPlayer(n, p.ped, {x, y, level});
        char b[96];
        std::snprintf(b, sizeof(b), "ok %.1f %.1f %.1f", x, y, level);
        REXLOG_INFO("dev world: water -> {}", b + 3);
        return std::string(b);
      };
      // Open water: also water 50 m away in all eight directions (no slips, docks or
      // enclosed basins; a river or the bay passes).
      auto open_water_at = [&](float x, float y, float& level) {
        if (!water_at(x, y, level)) return false;
        for (int k = 0; k < 8; ++k) {
          float other = 0;
          const float a = 0.7853982f * float(k);
          if (!water_at(x + 50.0f * std::cos(a), y + 50.0f * std::sin(a), other) ||
              std::fabs(other - level) > 1.0f)
            return false;
        }
        return true;
      };
      float level = 0;
      if (at) {
        if (!water_at(tx, ty, level)) return "err no open water at " + std::to_string(tx) + " " + std::to_string(ty);
        return go(tx, ty, level);
      }
      if (ring < 0) {
        const auto pos = Position(n, p.ped);
        if (!pos) return "err cannot read the player position";
        center = *pos;
        ring = 0;
      }
      const float r = 15.0f * float(ring++);
      if (r > radius) return "err no open water within " + std::to_string(int(radius)) + " m";
      const int points = std::max(1, int(6.2831853f * r / 15.0f));
      for (int i = 0; i < points; ++i) {
        const float a = 6.2831853f * float(i) / float(points);
        const float x = center.x + r * std::cos(a), y = center.y + r * std::sin(a);
        if (open_water_at(x, y, level)) return go(x, y, level);
      }
      return std::nullopt;
    }, std::chrono::seconds(120));
  }

  if (cmd == "weapon") {
    if (f.empty()) return "err weapon needs an id";
    const uint32_t weapon = uint32_t(f[0]), ammo = f.size() > 1 ? uint32_t(f[1]) : 9999u;
    return RunOnScriptThread([=](Invoker& n) -> std::optional<std::string> {
      const Player p = GetPlayer(n);
      if (!p.ok) return "err no player";
      n.Call("GIVE_WEAPON_TO_CHAR", {{p.ped}, {weapon}, {ammo}, {0}});
      n.Call("SET_CURRENT_CHAR_WEAPON", {{p.ped}, {weapon}, {1}});
      return "ok";
    });
  }

  if (cmd == "peds") {
    const int count = f.empty() ? 6 : int(f[0]);
    const bool hostile = f.size() > 1 ? f[1] != 0.0f : true;
    const float radius = f.size() > 2 ? f[2] : 12.0f;
    // CREATE_RANDOM_CHAR picks from the ped models streamed in around the player and makes nothing
    // while none are (just after a teleport, on water, or when streaming is behind: it failed on a
    // Metal 4 run). So: retry the missing peds each frame, after 2 s also with CREATE_CHAR of a fixed
    // model that is requested here, and give up after 10 s with an ok reply, so the pad goes on.
    constexpr const char* kFallbackModel = "M_Y_THIEF";
    const uint32_t fallback = Hash(kFallbackModel);
    constexpr int kFallbackAfterFrames = 60, kGiveUpAfterFrames = 300;
    int frames = 0, made = 0, random_made = 0;
    return RunOnScriptThread([=](Invoker& n) mutable -> std::optional<std::string> {
      const Player p = GetPlayer(n);
      if (!p.ok) return "err no player";
      const auto pos = Position(n, p.ped);
      if (!pos) return "err cannot read the player position";
      ++frames;
      if (frames == kFallbackAfterFrames) n.Call("REQUEST_MODEL", {{fallback}});
      bool fallback_loaded = false;
      if (frames >= kFallbackAfterFrames) {
        const Result loaded = n.Call("HAS_MODEL_LOADED", {{fallback}});
        fallback_loaded = loaded.called && loaded.value;
      }
      for (int i = made; i < count; ++i) {
        const float a = 6.2831853f * float(i) / float(std::max(1, count));
        const float x = pos->x + radius * std::cos(a), y = pos->y + radius * std::sin(a);
        uint32_t ped = 0;
        const Result random = n.Call("CREATE_RANDOM_CHAR", {{F(x)}, {F(y)}, {F(pos->z)}, {0, true}});
        if (!random.outs.empty() && random.outs[0]) {
          ped = random.outs[0];
          ++random_made;
        } else if (fallback_loaded) {
          // CREATE_CHAR(type, model, x, y, z, &ped, network): 26 is a mission ped.
          const Result fixed = n.Call("CREATE_CHAR", {{26}, {fallback}, {F(x)}, {F(y)}, {F(pos->z)}, {0, true}, {1}});
          if (!fixed.outs.empty() && fixed.outs[0]) ped = fixed.outs[0];
        }
        if (!ped) break;  // nothing streamed in yet: try the rest next frame
        ++made;
        if (hostile) {
          n.Call("GIVE_WEAPON_TO_CHAR", {{ped}, {7}, {500}, {0}});
          n.Call("SET_CURRENT_CHAR_WEAPON", {{ped}, {7}, {1}});
          n.Call("TASK_COMBAT", {{ped}, {p.ped}});
        }
      }
      if (made < count && frames < kGiveUpAfterFrames) return std::nullopt;
      if (frames >= kFallbackAfterFrames) n.Call("MARK_MODEL_AS_NO_LONGER_NEEDED", {{fallback}});
      if (made < count)
        REXLOG_WARN("dev world: peds made only {} of {} after {} frames (random {}, {} {})", made, count, frames,
                    random_made, kFallbackModel, made - random_made);
      REXLOG_INFO("dev world: peds made {} of {} hostile={} frames={} random={} fallback={}", made, count, hostile,
                  frames, random_made, made - random_made);
      return "ok " + std::to_string(made);
    });
  }

  if (cmd == "cars") {
    if (args.size() < 2) return "err cars needs a model name";
    const uint32_t model = Hash(args[1]);
    const std::string model_name = args[1];
    const int count = f.empty() ? 4 : int(f[0]);
    const float radius = f.size() > 1 ? f[1] : 15.0f;
    int frames = 0;
    return RunOnScriptThread([=](Invoker& n) mutable -> std::optional<std::string> {
      const Player p = GetPlayer(n);
      if (!p.ok) return "err no player";
      if (frames++ == 0) n.Call("REQUEST_MODEL", {{model}});
      const Result loaded = n.Call("HAS_MODEL_LOADED", {{model}});
      if (!loaded.called || !loaded.value)
        return frames > 600 ? std::optional<std::string>("err model " + model_name + " did not load")
                            : std::nullopt;
      const auto pos = Position(n, p.ped);
      if (!pos) return "err cannot read the player position";
      int made = 0;
      for (int i = 0; i < count; ++i) {
        const float a = 6.2831853f * (float(i) + 0.5f) / float(std::max(1, count));
        const Result car = n.Call("CREATE_CAR", {{model}, {F(pos->x + radius * std::cos(a))},
                                                 {F(pos->y + radius * std::sin(a))}, {F(pos->z)},
                                                 {0, true}, {1}});
        if (car.outs.empty() || !car.outs[0]) continue;
        n.Call("SET_CAR_ON_GROUND_PROPERLY", {{car.outs[0]}});
        g_bench_cars.push_back(car.outs[0]);
        g_last_car = car.outs[0];
        ++made;
      }
      n.Call("MARK_MODEL_AS_NO_LONGER_NEEDED", {{model}});
      return made ? "ok " + std::to_string(made) : std::string("err CREATE_CAR made no car");
    });
  }

  if (cmd == "explode") {
    const int count = f.empty() ? 1 : int(f[0]);
    return RunOnScriptThread([=](Invoker& n) -> std::optional<std::string> {
      int done = 0;
      for (; done < count && !g_bench_cars.empty(); ++done) {
        n.Call("EXPLODE_CAR", {{g_bench_cars.front()}, {1}, {0}});
        g_bench_cars.pop_front();
      }
      return done ? "ok " + std::to_string(done) : std::string("err no cars left to explode");
    });
  }

  if (cmd == "boom") {
    const float distance = f.empty() ? 15.0f : f[0];
    const uint32_t type = f.size() > 1 ? uint32_t(f[1]) : 0u;
    const float radius = f.size() > 2 ? f[2] : 6.0f;
    return RunOnScriptThread([=](Invoker& n) -> std::optional<std::string> {
      const Player p = GetPlayer(n);
      if (!p.ok) return "err no player";
      const auto pos = Position(n, p.ped);
      if (!pos) return "err cannot read the player position";
      const Vec3 at = Ahead(*pos, Heading(n, p.ped), distance);
      n.Call("ADD_EXPLOSION", {{F(at.x)}, {F(at.y)}, {F(at.z)}, {type}, {F(radius)}, {1}, {0}, {F(1.0f)}});
      return "ok";
    });
  }

  if (cmd == "where") {
    return RunOnScriptThread([=](Invoker& n) -> std::optional<std::string> {
      const Player p = GetPlayer(n);
      if (!p.ok) return "err no player";
      const auto pos = Position(n, p.ped);
      if (!pos) return "err cannot read the player position";
      const Result water = n.Call("IS_CHAR_IN_WATER", {{p.ped}});
      const Result health = n.Call("GET_CHAR_HEALTH", {{p.ped}, {0, true}});
      char b[128];
      std::snprintf(b, sizeof(b), "ok %.1f %.1f %.1f heading %.0f car=%d water=%d health=%u", pos->x,
                    pos->y, pos->z, Heading(n, p.ped), InAnyCar(n, p.ped) ? 1 : 0,
                    water.called && water.value ? 1 : 0, health.outs.empty() ? 0u : health.outs[0]);
      REXLOG_INFO("dev world: where -> {}", b + 3);
      return std::string(b);
    });
  }

  return "err unknown command '" + cmd + "'";
}

}  // namespace gta4::dev_pad
