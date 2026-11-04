// Dynamic water at any frame rate (FusionFix frameratevigilante "Fix water physics", 360 port).
//
// CWater keeps a 100 x 100 float grid of water surface speed at 0x82C94618, one cell per 2 m,
// wrapped: cell = ((x/2 + 100000) % 100) * 100 + ((y/2 + 100000) % 100) for integer world
// x, y (C division and remainder). Two writers add to it every frame, without the time step:
// - sub_82290FA0 (x, y, f1 = amount), AddToDynamicWaterSpeed: cell += f1, clamped to
//   [-20, 20]. Its only caller is the heli downwash, sub_82547BC0, which stamps five cells (the
//   centre and +-4 m) under the rotor every frame. At 60 fps it pushes twice as hard.
// - sub_82291048 (x, y, f1 = target, f2 = factor), ModifyDynamicWaterSpeed: skipped while
//   |0x82C9E258[cell]| >= 4; otherwise cell = f1*f2 + cell*(1 - f2), then limited. Called by
//   buoyancy, sub_826811D0, for everything floating. At 60 fps it converges twice as fast.
// The fix scales the downwash amount by step/(1/30), like FF, and turns the buoyancy factor
// into 1 - (1 - f2)^(step/(1/30)): the same convergence per second at any rate. That stays in
// [0, 1], where FF's f2 * step/(1/30) is linear and can overshoot. Unchanged at 30 fps.
//
// gta4_water_speed_log measures it: every 60 frames, how much each writer changed the grid per
// game second (sum of |after - before| over the cells it wrote), the calls, and the RMS of the
// whole grid. With the fix on, a fixed 30 and a fixed 60 step (gta4_debug_fixed_step_hz)
// should give the same per-second numbers; off, the downwash line doubles at 60.
#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdint>

#include <rex/cvar.h>
#include <rex/logging.h>

#include "gta4_init.h"

REXCVAR_DEFINE_BOOL(gta4_water_speed_fps_fix, false, "GTA IV/Fixes",
                    "Helicopter downwash and buoyancy stir the water the same amount per second at "
                    "any frame rate (twice as much at 60 fps otherwise)");
REXCVAR_DEFINE_BOOL(gta4_water_speed_log, false, "GTA IV/Diagnostics",
                    "Log how much the downwash and buoyancy change the water speed grid per game "
                    "second, every 60 frames");

namespace {

constexpr uint32_t kSpeedGrid = 0x82C94618;  // float[100 * 100]
constexpr uint32_t kGridCells = 100 * 100;
constexpr uint32_t kGameClockMs = 0x82C6C2A4;
constexpr uint32_t kGameStep = 0x82C6C2A4 + 8;
constexpr uint32_t kFrameCounter = 0x82C6C2B8;

float StepScale(uint8_t* base) {
  const float step = std::bit_cast<float>(REX_LOAD_U32(kGameStep));
  if (!std::isfinite(step) || step <= 0.0f) return 1.0f;
  return std::min(step * 30.0f, 4.0f);
}

uint32_t CellAddress(int32_t x, int32_t y) {
  const int32_t row = (x / 2 + 100000) % 100, column = (y / 2 + 100000) % 100;
  return kSpeedGrid + uint32_t(row * 100 + column) * 4;
}

float LoadFloat(uint8_t* base, uint32_t address) { return std::bit_cast<float>(REX_LOAD_U32(address)); }

// Game thread only (both writers run in vehicle and physics processing).
struct Window {
  bool valid = false;
  uint32_t frame = 0, clock_ms = 0;
  uint32_t add_calls = 0, modify_calls = 0;
  double add_change = 0, modify_change = 0, modify_factor = 0;
};
Window window;

void ObserveWindow(uint8_t* base) {
  const uint32_t frame = REX_LOAD_U32(kFrameCounter), clock_ms = REX_LOAD_U32(kGameClockMs);
  if (!window.valid) {
    window = {};
    window.valid = true;
    window.frame = frame;
    window.clock_ms = clock_ms;
    return;
  }
  if (frame - window.frame < 60) return;
  const double game_seconds = double(clock_ms - window.clock_ms) / 1000.0;
  double square_sum = 0;
  for (uint32_t i = 0; i < kGridCells; ++i) {
    const double v = LoadFloat(base, kSpeedGrid + i * 4);
    square_sum += v * v;
  }
  const double per_second = game_seconds > 0 ? 1.0 / game_seconds : 0.0;
  REXLOG_INFO(
      "gta4-water fix={} frames={} game-s={:.3f} step={:.4f} downwash calls={} change/s={:.3f} "
      "buoyancy calls={} change/s={:.3f} factor={:.4f} grid-rms={:.4f}",
      REXCVAR_GET(gta4_water_speed_fps_fix), frame - window.frame, game_seconds,
      LoadFloat(base, kGameStep), window.add_calls, window.add_change * per_second,
      window.modify_calls, window.modify_change * per_second,
      window.modify_calls ? window.modify_factor / window.modify_calls : 0.0,
      std::sqrt(square_sum / kGridCells));
  window.valid = false;
  ObserveWindow(base);
}

}  // namespace

extern "C" void sub_82290FA0(PPCContext& ctx, uint8_t* base) {
  if (REXCVAR_GET(gta4_water_speed_fps_fix)) ctx.f1.f64 = double(float(ctx.f1.f64) * StepScale(base));
  if (!REXCVAR_GET(gta4_water_speed_log)) {
    __imp__sub_82290FA0(ctx, base);
    return;
  }
  ObserveWindow(base);
  const uint32_t cell = CellAddress(ctx.r3.s32, ctx.r4.s32);
  const float before = LoadFloat(base, cell);
  __imp__sub_82290FA0(ctx, base);
  ++window.add_calls;
  window.add_change += std::fabs(double(LoadFloat(base, cell)) - before);
}

extern "C" void sub_82291048(PPCContext& ctx, uint8_t* base) {
  if (REXCVAR_GET(gta4_water_speed_fps_fix)) {
    const float scale = StepScale(base);
    const double factor = std::clamp(ctx.f2.f64, 0.0, 1.0);
    if (scale != 1.0f && factor == ctx.f2.f64)
      ctx.f2.f64 = double(float(1.0 - std::pow(1.0 - factor, double(scale))));
  }
  if (!REXCVAR_GET(gta4_water_speed_log)) {
    __imp__sub_82291048(ctx, base);
    return;
  }
  ObserveWindow(base);
  const uint32_t cell = CellAddress(ctx.r3.s32, ctx.r4.s32);
  const float before = LoadFloat(base, cell);
  const double factor = ctx.f2.f64;
  __imp__sub_82291048(ctx, base);
  ++window.modify_calls;
  window.modify_factor += factor;
  window.modify_change += std::fabs(double(LoadFloat(base, cell)) - before);
}
