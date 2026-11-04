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
//   clock <hour> <minute>   weather <0..7>   invincible   nowanted
//
// Coordinates are world metres: Algonquin is west (x < 600), Broker and Dukes east (Hove Beach
// safehouse ~ 892 -500, Downtown Broker ~ 1040 150). Early in the story Algonquin is closed and
// entering it gives six stars; `nowanted` keeps the police off anyway.

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
};
struct Result {
  bool called = false;
  uint32_t value = 0;
  std::vector<uint32_t> outs;
};

class Invoker {
 public:
  Invoker(PPCContext& parent, uint8_t* base) : parent_(parent), base_(base) {}

  Result Call(std::string_view name, std::initializer_list<Arg> args) {
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
    if (args.size() > 16 || parent_.r1.u32 < 0x400) return result;
    // A frame below the caller's stack: back chain, context, return slot, arguments, outs.
    const uint32_t frame = (parent_.r1.u32 - 0x400u) & ~15u;
    if (!Span(frame, 0x400, true)) return result;
    const uint32_t context = frame + 0x80, ret = frame + 0xC0, argv = frame + 0x100,
                   outs = frame + 0x180;
    std::memset(rex::memory::GuestPtr(base_, frame + 0x80), 0, 0x400 - 0x80);
    Write(base_, frame, parent_.r1.u32);
    Write(base_, context, ret);
    Write(base_, context + 4, uint32_t(args.size()));
    Write(base_, context + 8, argv);
    uint32_t i = 0, out_count = 0;
    for (const Arg& a : args) {
      Write(base_, argv + i * 4, a.out ? outs + 16 * out_count++ : a.value);
      ++i;
    }
    PPCContext call = parent_;
    call.r1.u32 = frame;
    call.r3.u32 = context;
    call.lr = kNativeReturnAddress;
    function(call, base_);
    result.called = true;
    result.value = Read(base_, ret);
    for (uint32_t o = 0; o < out_count; ++o) result.outs.push_back(Read(base_, outs + 16 * o));
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

std::string WorldCommand(const std::vector<std::string>& args) {
  const std::string& cmd = args[0];
  std::vector<float> f;
  for (size_t i = 1; i < args.size(); ++i) {
    float v;
    if (cmd != "car" && !ParseFloat(args[i], v)) return "err '" + args[i] + "' is not a number";
    if (cmd != "car") f.push_back(v);
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
        // Move first so the streaming around the target starts, then load it fully.
        n.Call("SET_CHAR_COORDINATES", {{p.ped}, {F(x)}, {F(y)}, {F(z)}});
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

  if (cmd == "car") {
    if (args.size() < 2) return "err car needs a model name";
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
                                               {pos.outs[2]}, {0, true}, {1}});
      if (car.outs.empty() || !car.outs[0]) return "err CREATE_CAR made no car";
      const uint32_t vehicle = car.outs[0];
      n.Call("SET_CAR_HEADING", {{vehicle}, {heading.outs[0]}});
      n.Call("SET_CAR_ON_GROUND_PROPERLY", {{vehicle}});
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
  return "err unknown command '" + cmd + "'";
}

}  // namespace gta4::dev_pad
