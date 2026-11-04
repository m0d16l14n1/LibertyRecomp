// Vehicle effects that advance per frame instead of per second (FusionFix frameratevigilante,
// 360 ports). Each either scales the per-frame amount by game step / (1/30) or counts frames
// with the 30 fps logical counter: unchanged at 30 fps or below.
#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdint>

#include <rex/cvar.h>

#include "gta4_init.h"
#include "gta4_timer.h"

REXCVAR_DEFINE_BOOL(gta4_heli_rotor_speed_fix, true, "GTA IV/Fixes",
                    "Helicopter rotors spin at the same speed at any frame rate (twice as fast at "
                    "60 fps otherwise)");
REXCVAR_DEFINE_BOOL(gta4_heli_blinker_fix, true, "GTA IV/Fixes",
                    "Helicopter warning lights blink at the 30 fps rate at any frame rate (twice "
                    "as often and half as long at 60 fps otherwise)");
REXCVAR_DEFINE_BOOL(gta4_chase_blip_spin_fix, true, "GTA IV/Fixes",
                    "Police chase blips on the radar turn at the 30 fps rate at any frame rate "
                    "(twice as fast at 60 fps otherwise)");

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

// Helicopter warning lights (FF "Helicopter blinkers' speed", CHeli::PreRender2). sub_822AB0B0
// (r3 = the heli) takes n = random seed (u16 at +44) + CTimer frame count (0x82C6C2B8) and
// lights four lamps each for one frame in 32: id 65 when n % 32 == 0, 66 at (n + 12), 67 at
// (n + 15), 68 at (n - 8). The flag goes to sub_822AAD38 (65, 66) and sub_822AAA30 (67, 68) in
// r5. Both are hooked: inside this call, for this heli and those ids, r5 is worked out again
// from the logical frame count. Nothing global is swapped, so other threads reading the frame
// count see the real one.
namespace {
thread_local uint32_t blinker_heli = 0;

void OverrideBlinker(PPCContext& ctx, uint8_t* base) {
  if (blinker_heli == 0 || ctx.r3.u32 != blinker_heli) return;
  int32_t offset;
  switch (ctx.r4.u32) {
    case 65: offset = 0; break;
    case 66: offset = 12; break;
    case 67: offset = 15; break;
    case 68: offset = -8; break;
    default: return;
  }
  const uint32_t n = uint32_t(REX_LOAD_U16(blinker_heli + 44)) + gta4::timer::LogicalFrameCount();
  ctx.r5.u64 = ((n + uint32_t(offset)) & 31) == 0 ? 1 : 0;
}
}  // namespace

extern "C" void sub_822AB0B0(PPCContext& ctx, uint8_t* base) {
  if (!REXCVAR_GET(gta4_heli_blinker_fix)) {
    __imp__sub_822AB0B0(ctx, base);
    return;
  }
  const uint32_t outer = blinker_heli;
  blinker_heli = ctx.r3.u32;
  __imp__sub_822AB0B0(ctx, base);
  blinker_heli = outer;
}

extern "C" void sub_822AAD38(PPCContext& ctx, uint8_t* base) {
  OverrideBlinker(ctx, base);
  __imp__sub_822AAD38(ctx, base);
}

extern "C" void sub_822AAA30(PPCContext& ctx, uint8_t* base) {
  OverrideBlinker(ctx, base);
  __imp__sub_822AAA30(ctx, base);
}

// Police chase blip spin (FF "Cop blips' animation speed", CVehicle::UpdateChaseRadarBlip).
// sub_8215B4C0 (r3 = the vehicle, blip handle at +3864) sets the blip's rotation, property 16
// through sub_82334990 (r3 = property, r4 = blip, f1 = value), to
// ((frame count * 21) mod 360) * pi/180: 21 degrees per frame. Inside this call that one value
// is worked out again from the logical frame count. The flashing colour uses the millisecond
// clock and is left alone.
namespace {
thread_local uint32_t chase_blip_vehicle = 0;
}  // namespace

extern "C" void sub_8215B4C0(PPCContext& ctx, uint8_t* base) {
  if (!REXCVAR_GET(gta4_chase_blip_spin_fix)) {
    __imp__sub_8215B4C0(ctx, base);
    return;
  }
  const uint32_t outer = chase_blip_vehicle;
  chase_blip_vehicle = ctx.r3.u32;
  __imp__sub_8215B4C0(ctx, base);
  chase_blip_vehicle = outer;
}

extern "C" void sub_82334990(PPCContext& ctx, uint8_t* base) {
  constexpr uint32_t kBlipRotation = 16, kBlipHandle = 3864;
  constexpr float kRadiansPerDegree = 0.017453292f;  // the game's constant at 0x820BEEF4
  if (chase_blip_vehicle != 0 && ctx.r3.u32 == kBlipRotation &&
      ctx.r4.u32 == REX_LOAD_U32(chase_blip_vehicle + kBlipHandle)) {
    // The game's arithmetic: u32 product, unsigned remainder, float degrees times the constant.
    const uint32_t degrees = (gta4::timer::LogicalFrameCount() * 21u) % 360u;
    ctx.f1.f64 = double(float(degrees) * kRadiansPerDegree);
  }
  __imp__sub_82334990(ctx, base);
}
