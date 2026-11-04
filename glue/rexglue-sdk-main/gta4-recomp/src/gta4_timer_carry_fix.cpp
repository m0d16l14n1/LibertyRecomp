// CTimer millisecond clocks keep their fraction (FusionFix "MillisecondClocks", 360 port).
//
// sub_8227FE40 is CTimer::Update. It advances six millisecond clocks, each a block of
// {u32 ms, u32 previous ms, f32 step seconds, f32 1/step} at 0x82C6C254 + 16*i
// (0x82C6C2A4 is the game clock, also copied to 0x82C6C2BC). Each adds
// fctiwz(step * 1000), truncated: at 60 fps 16.67 ms becomes 16, so every clock runs 4% slow
// (1% at 30 fps). Fades, script timers read from these clocks and mission timers stretch.
// After the original update, each clock that advanced by exactly the truncated step this
// frame gets its lost fraction carried, a whole millisecond at a time.
#include <array>
#include <bit>
#include <cmath>
#include <cstdint>

#include <chrono>

#include <rex/cvar.h>
#include <rex/logging.h>

#include "gta4_init.h"
#include "gta4_write_watch.h"

REXCVAR_DEFINE_BOOL(gta4_timer_millisecond_carry, true, "GTA IV/Fixes",
                    "Carry the fraction of a millisecond the game's clocks drop every frame "
                    "(they run 4% slow at 60 fps, 1% at 30)");

namespace {

constexpr std::array<uint32_t, 6> kClocks = {0x82C6C254, 0x82C6C264, 0x82C6C274,
                                             0x82C6C284, 0x82C6C294, 0x82C6C2A4};
constexpr size_t kGameClock = 5;
constexpr uint32_t kGameClockCopy = 0x82C6C2BC;  // = game clock unless sub_829E5508 overrides it
constexpr uint32_t kStepOffset = 8;

// CTimer::Update runs on the game thread only.
std::array<double, kClocks.size()> fraction{};
// Every 600 updates: how far the game clock moved against the host clock (1.00 = real time
// while unpaused; the truncation alone gives about 0.96 at 60 fps).
struct RateWindow { uint32_t game = 0; std::chrono::steady_clock::time_point host{}; uint32_t updates = 0; bool valid = false; uint64_t carried = 0; };
RateWindow rate;
void ObserveRate(uint32_t game_clock) {
  const auto now = std::chrono::steady_clock::now();
  if (!rate.valid) { rate = {game_clock, now, 0, true}; return; }
  if (++rate.updates < 600) return;
  const double host_ms = std::chrono::duration<double, std::milli>(now - rate.host).count();
  REXLOG_INFO("gta4-timer-carry carry={} carried-ms={} game-ms={} host-ms={:.0f} rate={:.3f}",
              REXCVAR_GET(gta4_timer_millisecond_carry), rate.carried, game_clock - rate.game, host_ms,
              host_ms > 0 ? double(game_clock - rate.game) / host_ms : 0.0);
  rate = {game_clock, now, 0, true};
}

}  // namespace

extern "C" void sub_8227FE40(PPCContext& ctx, uint8_t* base) {
  gta4::write_watch::Tick(base);  // diagnostic, off unless gta4_watch_write is set
  if (!REXCVAR_GET(gta4_timer_millisecond_carry)) {
    fraction = {};
    __imp__sub_8227FE40(ctx, base);
    ObserveRate(REX_LOAD_U32(kClocks[kGameClock]));
    return;
  }
  std::array<uint32_t, kClocks.size()> before{};
  for (size_t i = 0; i < kClocks.size(); ++i) before[i] = REX_LOAD_U32(kClocks[i]);
  __imp__sub_8227FE40(ctx, base);
  const uint32_t game_after = REX_LOAD_U32(kClocks[kGameClock]);
  const bool copy_follows = REX_LOAD_U32(kGameClockCopy) == game_after;
  for (size_t i = 0; i < kClocks.size(); ++i) {
    const uint32_t after = REX_LOAD_U32(kClocks[i]);
    const float step = std::bit_cast<float>(REX_LOAD_U32(kClocks[i] + kStepOffset));
    if (!std::isfinite(step) || step <= 0.0f || step > 1.0f) {
      fraction[i] = 0;
      continue;
    }
    // The game's own product and truncation (single precision, then toward zero).
    const float milliseconds = step * 1000.0f;
    const int32_t whole = int32_t(milliseconds);
    // Paused clocks do not advance (and keep last frame's step); a clock set elsewhere this
    // frame (a load, a script) moved by some other amount. Neither gets a carry.
    if (int32_t(after - before[i]) != whole) continue;
    fraction[i] += double(milliseconds) - double(whole);
    if (fraction[i] < 1.0) continue;
    const uint32_t carried = uint32_t(fraction[i]);
    fraction[i] -= carried;
    REX_STORE_U32(kClocks[i], after + carried);
    if (i == kGameClock) rate.carried += carried;
    if (i == kGameClock && copy_follows) REX_STORE_U32(kGameClockCopy, after + carried);
  }
  ObserveRate(REX_LOAD_U32(kClocks[kGameClock]));
}
