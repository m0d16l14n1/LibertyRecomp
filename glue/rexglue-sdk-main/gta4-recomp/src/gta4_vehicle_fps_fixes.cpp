// Vehicle effects that advance per frame instead of per second (FusionFix frameratevigilante,
// 360 ports). Each scales the per-frame amount by game step / (1/30): unchanged at 30 fps.
#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdint>

#include <rex/cvar.h>

#include "gta4_init.h"

REXCVAR_DEFINE_BOOL(gta4_heli_rotor_speed_fix, true, "GTA IV/Fixes",
                    "Helicopter rotors spin at the same speed at any frame rate (twice as fast at "
                    "60 fps otherwise)");

namespace {

constexpr uint32_t kGameStep = 0x82C6C2A4 + 8;  // CTimer game clock step (seconds)

float StepScale(uint8_t* base) {
  const float step = std::bit_cast<float>(REX_LOAD_U32(kGameStep));
  if (!std::isfinite(step) || step <= 0.0f) return 1.0f;
  return std::min(step * 30.0f, 4.0f);
}

}  // namespace

// Helicopter rotor speed (FF "Helicopter rotor speeds", CHeli::PreRender). sub_822A8478 (CHeli
// vtable slot 32, r3 = the heli; skipped while paused) turns the main rotor angle (+8120) by
// speed (+8116) * 21.0 * 0.03 and the tail rotor (+8124) by speed * 25.0 * 0.03 every frame,
// wrapped to 2 pi. The 21 and 25 are data at 0x82A9974C / 0x82A99748, read only here: they are
// scaled by the step for the call and put back.
extern "C" void sub_822A8478(PPCContext& ctx, uint8_t* base) {
  constexpr uint32_t kMainRotorRate = 0x82A9974C, kTailRotorRate = 0x82A99748;
  const float scale = REXCVAR_GET(gta4_heli_rotor_speed_fix) ? StepScale(base) : 1.0f;
  if (scale == 1.0f) {
    __imp__sub_822A8478(ctx, base);
    return;
  }
  const uint32_t main_rate = REX_LOAD_U32(kMainRotorRate), tail_rate = REX_LOAD_U32(kTailRotorRate);
  REX_STORE_U32(kMainRotorRate, std::bit_cast<uint32_t>(std::bit_cast<float>(main_rate) * scale));
  REX_STORE_U32(kTailRotorRate, std::bit_cast<uint32_t>(std::bit_cast<float>(tail_rate) * scale));
  __imp__sub_822A8478(ctx, base);
  REX_STORE_U32(kMainRotorRate, main_rate);
  REX_STORE_U32(kTailRotorRate, tail_rate);
}
