// Dynamic water at any frame rate (FusionFix frameratevigilante "Fix water physics", 360 port).
//
// CWater keeps a 100 x 100 float grid of water surface speed at 0x82C94618, one cell per 2 m,
// wrapped: cell = ((x/2 + 100000) % 100) * 100 + ((y/2 + 100000) % 100) for integer world
// x, y (C division and remainder). Water ripples are queued with sub_82347B08
// (CWaterFx::RegisterRipple: r3 = manager, r4 = type, r5/r6 = position/direction, f1, f2; it
// appends to a 32-entry list and writes nothing back). Its only callers are three emitters,
// each firing when (u16 seed at +44 + CTimer frame count + k) % N == 0, so twice as often at
// 60 fps:
// - sub_82547BC0, heli downwash (r4 = the heli): N from the height between two table values,
//   divided by the time scale. Only the ripple is behind that test: after it (loc_8254823C) the
//   downwash adds to the grid through sub_82290FA0 (AddToDynamicWaterSpeed: cell += f1, clamped
//   to +-20) for five cells on every call, a fixed amount per frame (the rotor term times a
//   constant, not the step), so twice as much per second at 60 fps.
// - sub_823491E8 (called from sub_8267F9F8) and sub_8267F318 (called from sub_82680278): wake and
//   splash ripples of floating things (FF: boat ripples, swim ripples).
// - Buoyancy (sub_826811D0) also calls sub_82291048 (ModifyDynamicWaterSpeed: skipped while
//   |0x82C9E258[cell]| >= 4; otherwise cell = f1*f2 + cell*(1 - f2), then limited) every frame
//   with a factor from submersion and speed, not the step: it converges twice as fast at 60.
//
// gta4_water_ripple_rate_fix keeps a share min(1, step/(1/30)) of the emitters' firings (a
// per-emitter accumulator, so no frame-parity aliasing with even N), and scales each downwash
// grid push by min(step/(1/30), 1). Firings per second and downwash push per second then match
// 30 fps. gta4_water_speed_fps_fix makes the buoyancy
// factor 1 - (1 - f2)^(step/(1/30)): the same convergence per second at any rate. Both unchanged
// at 30 fps or below.
//
// gta4_water_speed_log measures the inputs, which neither the boat's speed nor the grid's
// clamp can blur: every 60 frames, per game second, the emitter firings and the ones kept, the
// downwash pushes and their total, and the buoyancy calls and their total relaxation
// (sum of -ln(1 - applied factor)). See the "Measuring" note in docs/HIGH_FPS_FIXES.md.
#include <algorithm>
#include <array>
#include <bit>
#include <cmath>
#include <cstdint>

#include <rex/cvar.h>
#include <rex/logging.h>

#include "gta4_init.h"

REXCVAR_DEFINE_BOOL(gta4_water_speed_fps_fix, true, "GTA IV/Fixes",
                    "Buoyancy stirs the water at the same rate per second at any frame rate "
                    "(twice as fast at 60 fps otherwise)");
REXCVAR_DEFINE_BOOL(gta4_water_ripple_rate_fix, true, "GTA IV/Fixes",
                    "Heli downwash, wake and splash ripples (and the downwash push on the water) "
                    "fire as often per second at any frame rate (twice as often at 60 fps "
                    "otherwise)");
REXCVAR_DEFINE_BOOL(gta4_water_speed_log, false, "GTA IV/Diagnostics",
                    "Log the water inputs per game second every 60 frames: ripple firings, "
                    "downwash pushes, buoyancy relaxation");

namespace {

constexpr uint32_t kSpeedGrid = 0x82C94618;  // float[100 * 100]
constexpr uint32_t kGridCells = 100 * 100;
constexpr uint32_t kGameClockMs = 0x82C6C2A4;
constexpr uint32_t kGameStep = 0x82C6C2A4 + 8;
constexpr uint32_t kFrameCounter = 0x82C6C2B8;

float LoadFloat(uint8_t* base, uint32_t address) { return std::bit_cast<float>(REX_LOAD_U32(address)); }

float StepScale(uint8_t* base) {
  const float step = LoadFloat(base, kGameStep);
  if (!std::isfinite(step) || step <= 0.0f) return 1.0f;
  return std::min(step * 30.0f, 4.0f);
}

// The emitters run on the game thread.
enum Site : int { kNone = 0, kDownwash = 1, kWake = 2, kSplash = 3, kSites = 4 };
thread_local int site = kNone;
std::array<double, kSites> share{};  // per emitter, firings owed

struct Window {
  bool valid = false;
  uint32_t frame = 0, clock_ms = 0;
  std::array<uint32_t, kSites> fired{}, kept{};
  uint32_t pushes = 0, buoyancy_calls = 0;
  double push_sum = 0, factor_sum = 0, applied_sum = 0, relaxation = 0;
};
Window window;

void ObserveWindow(uint8_t* base) {
  if (!REXCVAR_GET(gta4_water_speed_log)) return;
  const uint32_t frame = REX_LOAD_U32(kFrameCounter), clock_ms = REX_LOAD_U32(kGameClockMs);
  if (!window.valid) {
    window = {};
    window.valid = true;
    window.frame = frame;
    window.clock_ms = clock_ms;
    return;
  }
  if (frame - window.frame < 60) return;
  const double seconds = double(clock_ms - window.clock_ms) / 1000.0;
  const double per_second = seconds > 0 ? 1.0 / seconds : 0.0;
  double square_sum = 0;
  for (uint32_t i = 0; i < kGridCells; ++i) {
    const double v = LoadFloat(base, kSpeedGrid + i * 4);
    square_sum += v * v;
  }
  const auto& w = window;
  REXLOG_INFO(
      "gta4-water ripple-fix={} speed-fix={} frames={} game-s={:.3f} step={:.4f} | "
      "downwash fired/s={:.2f} kept/s={:.2f} pushes/s={:.2f} push={:.4f} push/s={:.3f} | "
      "wake fired/s={:.2f} kept/s={:.2f} | splash fired/s={:.2f} kept/s={:.2f} | "
      "buoyancy calls/s={:.1f} factor={:.4f} applied={:.4f} relax/s={:.3f} | grid-rms={:.4f}",
      REXCVAR_GET(gta4_water_ripple_rate_fix), REXCVAR_GET(gta4_water_speed_fps_fix), frame - w.frame,
      seconds, LoadFloat(base, kGameStep), w.fired[kDownwash] * per_second,
      w.kept[kDownwash] * per_second, w.pushes * per_second, w.pushes ? w.push_sum / w.pushes : 0.0,
      w.push_sum * per_second, w.fired[kWake] * per_second, w.kept[kWake] * per_second,
      w.fired[kSplash] * per_second, w.kept[kSplash] * per_second, w.buoyancy_calls * per_second,
      w.buoyancy_calls ? w.factor_sum / w.buoyancy_calls : 0.0,
      w.buoyancy_calls ? w.applied_sum / w.buoyancy_calls : 0.0, w.relaxation * per_second,
      std::sqrt(square_sum / kGridCells));
  window.valid = false;
  ObserveWindow(base);
}

void RunEmitter(PPCContext& ctx, uint8_t* base, int which, void (*original)(PPCContext&, uint8_t*)) {
  ObserveWindow(base);
  const int outer_site = site;
  site = which;
  original(ctx, base);
  site = outer_site;
}

}  // namespace

extern "C" void sub_82547BC0(PPCContext& ctx, uint8_t* base) { RunEmitter(ctx, base, kDownwash, __imp__sub_82547BC0); }
extern "C" void sub_823491E8(PPCContext& ctx, uint8_t* base) { RunEmitter(ctx, base, kWake, __imp__sub_823491E8); }
extern "C" void sub_8267F318(PPCContext& ctx, uint8_t* base) { RunEmitter(ctx, base, kSplash, __imp__sub_8267F318); }

extern "C" void sub_82347B08(PPCContext& ctx, uint8_t* base) {
  if (site == kNone) {
    __imp__sub_82347B08(ctx, base);
    return;
  }
  const bool log = REXCVAR_GET(gta4_water_speed_log);
  if (log) ++window.fired[site];
  if (REXCVAR_GET(gta4_water_ripple_rate_fix)) {
    share[site] = std::min(share[site] + std::min(StepScale(base), 1.0f), 1.0);
    if (share[site] < 1.0 - 1e-4) {
      return;
    }
    share[site] = std::max(0.0, share[site] - 1.0);
  }
  if (log) ++window.kept[site];
  __imp__sub_82347B08(ctx, base);
}

extern "C" void sub_82290FA0(PPCContext& ctx, uint8_t* base) {
  if (site == kDownwash && REXCVAR_GET(gta4_water_ripple_rate_fix))
    ctx.f1.f64 = double(float(ctx.f1.f64) * std::min(StepScale(base), 1.0f));
  if (site == kDownwash && REXCVAR_GET(gta4_water_speed_log)) {
    ++window.pushes;
    window.push_sum += ctx.f1.f64;
  }
  __imp__sub_82290FA0(ctx, base);
}

extern "C" void sub_82291048(PPCContext& ctx, uint8_t* base) {
  const double factor = ctx.f2.f64;
  if (REXCVAR_GET(gta4_water_speed_fps_fix)) {
    const float scale = StepScale(base);
    if (scale != 1.0f && factor >= 0.0 && factor <= 1.0)
      ctx.f2.f64 = double(float(1.0 - std::pow(1.0 - factor, double(scale))));
  }
  ObserveWindow(base);
  if (!REXCVAR_GET(gta4_water_speed_log)) {
    __imp__sub_82291048(ctx, base);
    return;
  }
  ++window.buoyancy_calls;
  window.factor_sum += factor;
  window.applied_sum += ctx.f2.f64;
  if (ctx.f2.f64 > 0.0 && ctx.f2.f64 < 1.0) window.relaxation += -std::log(1.0 - ctx.f2.f64);
  __imp__sub_82291048(ctx, base);
}
