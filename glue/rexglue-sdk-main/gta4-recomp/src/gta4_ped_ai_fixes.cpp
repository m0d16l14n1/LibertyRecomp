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
#include <string>
#include <unordered_map>

#include <rex/cvar.h>
#include <rex/logging.h>

#include "gta4_init.h"

REXCVAR_DEFINE_BOOL(gta4_ped_static_counter_30hz, true, "GTA IV/Fixes",
                    "Count how long a ped is stuck at 30 Hz above 30 fps (tasks give up after 30 "
                    "counts, twice as early at 60 fps)");
REXCVAR_DEFINE_BOOL(gta4_ped_pinned_down_carry, true, "GTA IV/Fixes",
                    "Peds pinned down in cover recover above 30 fps (the decay truncated to 0)");
REXCVAR_DEFINE_BOOL(gta4_ladder_heading_tolerance_fix, true, "GTA IV/Fixes",
                    "Climbing onto a ladder doesn't stall above 30 fps (the turn-to-face step "
                    "uses the slide step's 0.1 tolerance instead of 0.02)");
REXCVAR_DEFINE_BOOL(gta4_ladder_log, false, "GTA IV/Diagnostics",
                    "Log each subtask the ladder climb task starts (class name, frame), to see "
                    "where a climb stalls");

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

// Ladder stalls (FF "Fix stalls when trying to climb ladders"). CTaskComplexClimbLadder
// (vtable 0x82045D84) makes its turn-to-face subtask in slot 18, sub_826A17F0, and in
// sub_826A1138 (called from slot 18 and slot 20, sub_826A1BB8): CTaskSimpleMoveAchieveHeading's
// constructor sub_823FE5F0 (r3 = task, f1 = heading, f2 = rate 2.0, f3 = tolerance) gets 0.02
// from 0x82017558. CTaskSimpleSlideToCoord checks 0.1. Above 30 fps the tasks finish in the
// wrong order and the ped stands at the ladder. FF passes 0.1. The 0.02 constant has 22 other
// readers, so only these calls get 0.1.
namespace {
thread_local int ladder_subtask_depth = 0;
uint32_t ladder_tolerance_patched = 0;
}  // namespace

namespace {

// The class name of a guest object through its RTTI: vtable[-1] is the complete object
// locator, +12 its type descriptor, whose name ".?AVName@@" starts at +8.
std::string GuestClassName(uint8_t* base, uint32_t object) {
  auto in_image = [](uint32_t a) { return a >= 0x82000000 && a < 0x83000000; };
  if (!object) return "none";
  const uint32_t vtable = REX_LOAD_U32(object);
  if (!in_image(vtable)) return "?";
  const uint32_t locator = REX_LOAD_U32(vtable - 4);
  if (!in_image(locator)) return "?";
  const uint32_t type = REX_LOAD_U32(locator + 12);
  if (!in_image(type)) return "?";
  std::string name;
  for (uint32_t i = 0; i < 64; ++i) {
    const char c = char(REX_LOAD_U8(type + 8 + i));
    if (!c) break;
    name.push_back(c);
  }
  if (name.rfind(".?AV", 0) == 0) name = name.substr(4);
  if (const auto at = name.find("@@"); at != std::string::npos) name.resize(at);
  return name;
}

uint32_t ladder_log_lines = 0;
void LogLadderSubtask(uint8_t* base, const char* which, uint32_t task, uint32_t subtask) {
  if (!REXCVAR_GET(gta4_ladder_log) || ladder_log_lines >= 400) return;
  ++ladder_log_lines;
  REXLOG_INFO("gta4-ladder {} frame={} climb={:08X} subtask={} ({:08X}) fix={}", which,
              REX_LOAD_U32(0x82C6C2B8), task, GuestClassName(base, subtask), subtask,
              REXCVAR_GET(gta4_ladder_heading_tolerance_fix));
}
}  // namespace

// Slot 18 (first subtask) and slot 20 (next subtask) return the new subtask in r3.
extern "C" void sub_826A17F0(PPCContext& ctx, uint8_t* base) {
  const uint32_t task = ctx.r3.u32;
  ++ladder_subtask_depth;
  __imp__sub_826A17F0(ctx, base);
  --ladder_subtask_depth;
  LogLadderSubtask(base, "first", task, ctx.r3.u32);
}

// Slot 20 runs every frame (it returns the current subtask while nothing changes), so only a
// changed subtask is logged.
thread_local uint32_t ladder_last_task = 0, ladder_last_subtask = 0;
extern "C" void sub_826A1BB8(PPCContext& ctx, uint8_t* base) {
  const uint32_t task = ctx.r3.u32;
  __imp__sub_826A1BB8(ctx, base);
  if (task == ladder_last_task && ctx.r3.u32 == ladder_last_subtask) return;
  ladder_last_task = task;
  ladder_last_subtask = ctx.r3.u32;
  LogLadderSubtask(base, "next", task, ctx.r3.u32);
}

extern "C" void sub_826A1138(PPCContext& ctx, uint8_t* base) {
  ++ladder_subtask_depth;
  __imp__sub_826A1138(ctx, base);
  --ladder_subtask_depth;
}

extern "C" void sub_823FE5F0(PPCContext& ctx, uint8_t* base) {
  if (ladder_subtask_depth > 0 && REXCVAR_GET(gta4_ladder_heading_tolerance_fix) &&
      float(ctx.f3.f64) == 0.02f) {
    ctx.f3.f64 = double(0.1f);
    if (ladder_tolerance_patched++ < 4)
      REXLOG_INFO("gta4-ladder heading tolerance 0.02 -> 0.1 (task {:08X})", ctx.r3.u32);
  }
  __imp__sub_823FE5F0(ctx, base);
}
