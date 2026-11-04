// Diagnostic: which code writes a guest address (gta4_watch_write, off by default).
//
// The host page holding the target is made read-only. A write to it faults; the handler records
// the host PC and LR when the write falls in the watched range, makes the page writable again
// and returns, so the store re-executes and succeeds. A rearm thread protects the page again
// ~50 us later, so writes to the rest of the page in that gap are missed (each frame catches
// the next ones). Generated functions are exported (`sub_XXXXXXXX`), so dladdr names the
// writer. Our handler sits in front of the runtime's (MMIO, physical write watches) and passes
// on every fault that is not on the watched page.
//
// gta4_watch_write:
//   ""                          off
//   "0x82C6C2A4[:len]"          a guest address (len bytes, default 4)
//   "player:OFF[:len]"          the player's CPed + OFF
//   "player-ai:OFF[:len]"       the player's CPedIntelligence (*(ped + 540)) + OFF
//   "ped-ai:N:OFF[:len]"        the CPedIntelligence of the N-th live ped of the ped pool other
//                               than the player (0 = the first)
//   "pinned-ai[:OFF[:len]]"     the first non-player ped whose pinned-down byte (+712) is > 0;
//                               default OFF 712, len 1
// OFF and len are hex with 0x or decimal. A watch of up to 0x1000 bytes logs every
// (offset, writer) pair it sees. The target is resolved once when the cvar changes (or, for a
// ped target, when that ped's intelligence is gone); writes are no longer watched once
// gta4_watch_write_max hits are logged.
// Caveat: a kernel write into the page (a file read into that buffer) would fail with EFAULT
// rather than fault; ped and global data are not I/O buffers.
#include "gta4_write_watch.h"

#include <dlfcn.h>
#include <signal.h>
#include <sys/mman.h>
#include <unistd.h>

#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <thread>
#include <tuple>

#include <fmt/format.h>
#include <rex/cvar.h>
#include <rex/logging.h>

#include "gta4_init.h"

REXCVAR_DEFINE_STRING(gta4_watch_write, "", "GTA IV/Diagnostics",
                      "Log the code writing a guest address: 0xADDR[:len], player:OFF[:len], "
                      "player-ai:OFF[:len], ped-ai:N:OFF[:len] or pinned-ai[:OFF[:len]] "
                      "(gta4-watch lines; empty = off)");
REXCVAR_DEFINE_UINT32(gta4_watch_write_max, 4000, "GTA IV/Diagnostics",
                      "Writes gta4_watch_write records before it stops watching");

namespace {

constexpr uint32_t kCurrentPlayerIndex = 0x82A98778;
constexpr uint32_t kPlayerInfoTable = 0x82C01C70;
constexpr uint32_t kPlayerInfoPed = 1400;
constexpr uint32_t kPedIntelligence = 540;
constexpr uint32_t kIntelligencePinnedDown = 712;
constexpr uint32_t kPedPool = 0x831D5388;  // *: {entries, flags (byte per slot), count, entry size}
constexpr uint32_t kMaximumRange = 0x1000;

struct Hit {
  uint64_t pc, lr, address;
};

// Shared with the signal handler: plain atomics only.
std::atomic<uintptr_t> page_begin{0}, page_end{0}, watch_begin{0}, watch_end{0};
std::atomic<bool> armed{false}, protected_now{false};
std::atomic<uint64_t> other_writes{0}, dropped{0};
constexpr size_t kRing = 1024;
std::array<Hit, kRing> ring{};
std::atomic<uint64_t> ring_write{0};
std::atomic<uint64_t> ring_read{0};  // advanced by the game thread
std::atomic_flag ring_lock = ATOMIC_FLAG_INIT;  // faults on several threads at once
struct sigaction previous_segv{}, previous_bus{};
std::once_flag installed;

void Chain(const struct sigaction& previous, int signal_number, siginfo_t* info, void* context) {
  if (previous.sa_flags & SA_SIGINFO) {
    if (previous.sa_sigaction) return previous.sa_sigaction(signal_number, info, context);
  } else if (previous.sa_handler != SIG_DFL && previous.sa_handler != SIG_IGN && previous.sa_handler) {
    return previous.sa_handler(signal_number);
  }
  // Default action: restore it and let the fault happen again.
  signal(signal_number, SIG_DFL);
}

void Handler(int signal_number, siginfo_t* info, void* context) {
  const uintptr_t address = reinterpret_cast<uintptr_t>(info->si_addr);
  const uintptr_t begin = page_begin.load(std::memory_order_acquire);
  if (begin && address >= begin && address < page_end.load(std::memory_order_relaxed)) {
    if (address >= watch_begin.load(std::memory_order_relaxed) &&
        address < watch_end.load(std::memory_order_relaxed)) {
      const auto* machine = static_cast<ucontext_t*>(context)->uc_mcontext;
      while (ring_lock.test_and_set(std::memory_order_acquire)) {
      }
      const uint64_t slot = ring_write.load(std::memory_order_relaxed);
      if (slot - ring_read.load(std::memory_order_acquire) < kRing) {
#if defined(__aarch64__)
        ring[slot % kRing] = {uint64_t(machine->__ss.__pc), uint64_t(machine->__ss.__lr), address};
#else
        ring[slot % kRing] = {uint64_t(machine->__ss.__rip), 0, address};
#endif
        ring_write.store(slot + 1, std::memory_order_release);
      } else {
        dropped.fetch_add(1, std::memory_order_relaxed);
      }
      ring_lock.clear(std::memory_order_release);
    } else {
      other_writes.fetch_add(1, std::memory_order_relaxed);
    }
    mprotect(reinterpret_cast<void*>(begin), page_end.load(std::memory_order_relaxed) - begin,
             PROT_READ | PROT_WRITE);
    protected_now.store(false, std::memory_order_release);
    return;  // the store re-executes on the writable page
  }
  Chain(signal_number == SIGBUS ? previous_bus : previous_segv, signal_number, info, context);
}

void Install() {
  struct sigaction action{};
  action.sa_sigaction = Handler;
  action.sa_flags = SA_SIGINFO | SA_ONSTACK;
  sigemptyset(&action.sa_mask);
  sigaction(SIGSEGV, &action, &previous_segv);
  sigaction(SIGBUS, &action, &previous_bus);
  std::thread([] {
    // Protects again only after the page was seen writable for a whole period, so a faulting
    // store has re-executed (a store refaulting would be counted twice).
    bool pending = false;
    for (;;) {
      std::this_thread::sleep_for(std::chrono::microseconds(50));
      if (!armed.load(std::memory_order_acquire) || protected_now.load(std::memory_order_acquire)) {
        pending = false;
        continue;
      }
      if (!pending) {
        pending = true;
        continue;
      }
      pending = false;
      const uintptr_t begin = page_begin.load(std::memory_order_acquire);
      if (!begin) continue;
      if (mprotect(reinterpret_cast<void*>(begin), page_end.load() - begin, PROT_READ) == 0)
        protected_now.store(true, std::memory_order_release);
    }
  }).detach();
}

void Disarm() {
  armed.store(false, std::memory_order_release);
  const uintptr_t begin = page_begin.exchange(0);
  if (begin) mprotect(reinterpret_cast<void*>(begin), page_end.load() - begin, PROT_READ | PROT_WRITE);
  protected_now.store(false);
}

std::optional<uint32_t> Number(std::string_view text) {
  if (text.empty()) return std::nullopt;
  const std::string owned(text);
  char* end = nullptr;
  const unsigned long value = std::strtoul(owned.c_str(), &end, 0);
  if (!end || *end) return std::nullopt;
  return uint32_t(value);
}

uint32_t PlayerPed(uint8_t* base) {
  const uint32_t index = REX_LOAD_U32(kCurrentPlayerIndex);
  if (index >= 4) return 0;
  const uint32_t info = REX_LOAD_U32(kPlayerInfoTable + index * 4);
  return info ? REX_LOAD_U32(info + kPlayerInfoPed) : 0;
}

// The live peds of the pool other than the player, in slot order; stops at `want` (or the first
// pinned-down one when `pinned`).
uint32_t PoolPed(uint8_t* base, uint32_t want, bool pinned) {
  const uint32_t pool = REX_LOAD_U32(kPedPool);
  if (!pool) return 0;
  const uint32_t entries = REX_LOAD_U32(pool + 0), flags = REX_LOAD_U32(pool + 4);
  const uint32_t count = REX_LOAD_U32(pool + 8), size = REX_LOAD_U32(pool + 12);
  if (!entries || !flags || count > 4096 || size < 64 || size > 0x4000) return 0;
  const uint32_t player = PlayerPed(base);
  uint32_t seen = 0;
  for (uint32_t i = 0; i < count; ++i) {
    if (REX_LOAD_U8(flags + i) & 0x80) continue;  // free slot
    const uint32_t ped = entries + i * size;
    if (ped == player) continue;
    const uint32_t intelligence = REX_LOAD_U32(ped + kPedIntelligence);
    if (!intelligence) continue;
    if (pinned ? int8_t(REX_LOAD_U8(intelligence + kIntelligencePinnedDown)) > 0 : seen++ == want)
      return ped;
  }
  return 0;
}

struct Target {
  uint32_t guest = 0, length = 0, ped = 0, intelligence = 0;
  std::string description;
};

std::optional<Target> Resolve(uint8_t* base, std::string_view spec) {
  std::array<std::string_view, 4> parts{};
  size_t n = 0;
  while (n < parts.size()) {
    const size_t colon = spec.find(':');
    parts[n++] = spec.substr(0, colon);
    if (colon == spec.npos) break;
    spec.remove_prefix(colon + 1);
  }
  Target t;
  const auto length = [&](size_t i, uint32_t fallback) {
    return i < n ? Number(parts[i]).value_or(0) : fallback;
  };
  if (parts[0] == "player" || parts[0] == "player-ai") {
    t.ped = PlayerPed(base);
    if (!t.ped || n < 2) return std::nullopt;
    if (parts[0] == "player-ai") t.intelligence = REX_LOAD_U32(t.ped + kPedIntelligence);
    const uint32_t object = parts[0] == "player" ? t.ped : t.intelligence;
    const auto offset = Number(parts[1]);
    if (!object || !offset) return std::nullopt;
    t.guest = object + *offset;
    t.length = length(2, 4);
  } else if (parts[0] == "ped-ai" || parts[0] == "pinned-ai") {
    const bool pinned = parts[0] == "pinned-ai";
    const auto which = pinned ? std::optional<uint32_t>(0) : (n >= 2 ? Number(parts[1]) : std::nullopt);
    if (!which) return std::nullopt;
    t.ped = PoolPed(base, *which, pinned);
    if (!t.ped) return std::nullopt;
    t.intelligence = REX_LOAD_U32(t.ped + kPedIntelligence);
    const size_t first = pinned ? 1 : 2;
    const auto offset = first < n ? Number(parts[first]) : std::optional<uint32_t>(pinned ? kIntelligencePinnedDown : 0);
    if (!t.intelligence || !offset) return std::nullopt;
    t.guest = t.intelligence + *offset;
    t.length = length(first + 1, pinned ? 1 : 4);
  } else {
    const auto address = Number(parts[0]);
    if (!address) return std::nullopt;
    t.guest = *address;
    t.length = length(1, 4);
  }
  if (!t.length || t.length > kMaximumRange) return std::nullopt;
  return t;
}

std::string Symbol(uint64_t pc) {
  Dl_info info{};
  if (pc && dladdr(reinterpret_cast<void*>(pc), &info) && info.dli_sname)
    return fmt::format("{}+0x{:X}", info.dli_sname, pc - uint64_t(uintptr_t(info.dli_saddr)));
  return fmt::format("0x{:X}", pc);
}

// Game thread state.
std::string active_spec, warned_spec;
Target target;
uint64_t host_target = 0;  // host address of target.guest
uint32_t hits_logged = 0, ticks = 0;
std::map<std::tuple<uint32_t, std::string, std::string>, uint32_t> window;  // (offset, writer, caller) -> count

}  // namespace

namespace gta4::write_watch {

void Tick(uint8_t* base) {
  const std::string& spec = REXCVAR_GET(gta4_watch_write);
  if (spec.empty()) {
    if (!active_spec.empty()) { Disarm(); active_spec.clear(); window.clear(); }
    return;
  }
  // A ped target whose intelligence was released or reused re-resolves.
  const bool lost = target.ped && target.intelligence &&
                    REX_LOAD_U32(target.ped + kPedIntelligence) != target.intelligence;
  if (spec != active_spec || lost) {
    Disarm();
    window.clear();
    active_spec = spec;
    hits_logged = 0;
    const auto resolved = Resolve(base, spec);
    if (!resolved) {
      if (warned_spec != spec) REXLOG_WARN("gta4-watch spec={} not resolved (retrying each frame)", spec);
      warned_spec = spec;
      active_spec.clear();  // retry next frame (no ped yet, a typo stays quiet after one warning)
      target = {};
      return;
    }
    target = *resolved;
    std::call_once(installed, Install);
    const uintptr_t first = uintptr_t(base + target.guest + REX_PHYS_HOST_OFFSET(target.guest));
    const uintptr_t page = uintptr_t(getpagesize());
    host_target = first;
    watch_begin.store(first);
    watch_end.store(first + target.length);
    page_end.store((first + target.length + page - 1) & ~(page - 1));
    page_begin.store(first & ~(page - 1), std::memory_order_release);
    armed.store(true, std::memory_order_release);
    REXLOG_INFO("gta4-watch armed spec={} guest=0x{:08X} len={} ped=0x{:08X} intelligence=0x{:08X} host-page=0x{:X}",
                spec, target.guest, target.length, target.ped, target.intelligence, page_begin.load());
  }
  if (!armed.load()) return;
  const uint64_t written = ring_write.load(std::memory_order_acquire);
  for (uint64_t next = ring_read.load(); next < written; ring_read.store(++next, std::memory_order_release)) {
    const Hit& hit = ring[next % kRing];
    const uint32_t offset = uint32_t(hit.address - host_target);
    auto& count = window[{offset, Symbol(hit.pc), Symbol(hit.lr)}];
    if (!count++ && hits_logged < 64)  // first sight of each writer, right away
      REXLOG_INFO("gta4-watch new-writer guest=0x{:08X} (+0x{:X}) writer={} caller={}",
                  target.guest + offset, offset, Symbol(hit.pc), Symbol(hit.lr));
    if (++hits_logged >= REXCVAR_GET(gta4_watch_write_max)) {
      REXLOG_INFO("gta4-watch stopped after {} writes", hits_logged);
      Disarm();
      break;
    }
  }
  if (++ticks % 60 && armed.load()) return;
  for (const auto& [key, count] : window)
    REXLOG_INFO("gta4-watch frames=60 guest=0x{:08X} (+0x{:X}) writes={} writer={} caller={}",
                target.guest + std::get<0>(key), std::get<0>(key), count, std::get<1>(key), std::get<2>(key));
  const uint64_t others = other_writes.exchange(0), lost_hits = dropped.exchange(0);
  if (!window.empty() || others || lost_hits)
    REXLOG_INFO("gta4-watch frames=60 other-writes-on-page={} dropped={}", others, lost_hits);
  window.clear();
}

}  // namespace gta4::write_watch
