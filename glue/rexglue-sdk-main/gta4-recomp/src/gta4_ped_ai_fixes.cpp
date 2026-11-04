// Peds pinned down in cover recover at any frame rate (FusionFix DecreaseAmountPinnedDown, 360 port).
//
// sub_823C39B8 (CPedIntelligence per-frame processing, r3 = the intelligence) lowers how pinned
// down the ped is (signed byte +712, 0-100, raised by being shot at in sub_823C3C60) by
// (int)(game time step * 30). The cast truncates: below 1/30 s per frame that is 0, so above
// 30 fps the value never goes down and peds that were shot at stay ducked in cover for good.
// IS_PED_PINNED_DOWN (sub_825C5320) reads the same byte. A forced pin (FORCE_PED_PINNED_DOWN:
// timer +708, flag +716) sets the byte itself and is left alone. After the original, the lost
// fraction is carried per intelligence and taken off in whole points.
#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdint>
#include <unordered_map>

#include <rex/cvar.h>

#include "gta4_init.h"

REXCVAR_DEFINE_BOOL(gta4_ped_static_counter_30hz, true, "GTA IV/Fixes",
                    "Count how long a ped is stuck at 30 Hz above 30 fps (tasks give up after 30 "
                    "counts, twice as early at 60 fps)");
REXCVAR_DEFINE_BOOL(gta4_ped_pinned_down_carry, true, "GTA IV/Fixes",
                    "Peds pinned down in cover recover above 30 fps (the decay truncated to 0)");

namespace {

constexpr uint32_t kGameStep = 0x82C6C2A4 + 8;  // CTimer game clock step (seconds)
constexpr uint32_t kForcedTime = 708;           // FORCE_PED_PINNED_DOWN remaining seconds
constexpr uint32_t kPinnedDown = 712;           // int8, 0-100
constexpr size_t kMaximumTracked = 4096;

// Ped AI runs on the game thread. Keyed by guest address: a reused intelligence inherits less
// than one point.
std::unordered_map<uint32_t, float> remainders;

}  // namespace

extern "C" void sub_823C39B8(PPCContext& ctx, uint8_t* base) {
  const uint32_t intelligence = ctx.r3.u32;
  const bool enabled = REXCVAR_GET(gta4_ped_pinned_down_carry) && intelligence;
  const float forced = enabled ? std::bit_cast<float>(REX_LOAD_U32(intelligence + kForcedTime)) : 0.0f;
  __imp__sub_823C39B8(ctx, base);
  if (!enabled) {
    if (!remainders.empty()) remainders.clear();
    return;
  }
  const float step = std::bit_cast<float>(REX_LOAD_U32(kGameStep));
  const int32_t pinned = int8_t(REX_LOAD_U8(intelligence + kPinnedDown));
  if (forced > 0.0f || pinned <= 0 || !std::isfinite(step) || step <= 0.0f || step > 1.0f) {
    remainders.erase(intelligence);
    return;
  }
  const float amount = step * 30.0f;  // the game's product, truncated by its fctiwz
  if (remainders.size() >= kMaximumTracked) remainders.clear();
  float& remainder = remainders[intelligence];
  remainder += amount - float(int32_t(amount));
  if (remainder < 1.0f) return;
  const int32_t points = int32_t(remainder);
  remainder -= float(points);
  REX_STORE_U8(intelligence + kPinnedDown, uint8_t(pinned > points ? pinned - points : 0));
}

// Task attempt / stuck counter at 30 Hz (FusionFix CPedIntelligence::ProcessStaticCounter, "NPC
// pathfinding"). sub_823C17E8 (r3 = the intelligence, its ped at +64; called from sub_823C35C0)
// adds one to +612 every call while the ped stays near the position saved at +624, and clears
// it when the ped moves; +616 counts the calls since that position was saved. Tasks give up at
// a fixed count (30), so at 60 fps a ped stuck behind a car or a wall gives up in half the time.
// Above 30 fps the original runs only when a 1/30 s accumulator of the game step fills, per
// intelligence; at or below 30 fps it runs every frame as before.
namespace {
std::unordered_map<uint32_t, float> static_counter_time;  // game thread
}  // namespace

extern "C" void sub_823C17E8(PPCContext& ctx, uint8_t* base) {
  const uint32_t intelligence = ctx.r3.u32;
  if (!REXCVAR_GET(gta4_ped_static_counter_30hz) || !intelligence) {
    if (!static_counter_time.empty()) static_counter_time.clear();
    __imp__sub_823C17E8(ctx, base);
    return;
  }
  constexpr float kLogicalStep = 1.0f / 30.0f;
  const float step = std::bit_cast<float>(REX_LOAD_U32(kGameStep));
  if (!std::isfinite(step) || step <= 0.0f || step >= kLogicalStep) {
    static_counter_time.erase(intelligence);
    __imp__sub_823C17E8(ctx, base);
    return;
  }
  if (static_counter_time.size() >= kMaximumTracked) static_counter_time.clear();
  float& time = static_counter_time[intelligence];
  time += step;
  if (time < kLogicalStep) return;  // the function returns nothing: skipping it is a no-op
  time = std::min(time - kLogicalStep, kLogicalStep);
  __imp__sub_823C17E8(ctx, base);
}
