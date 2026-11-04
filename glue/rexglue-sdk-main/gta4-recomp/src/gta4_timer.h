#pragma once
// CTimer extras kept by the CTimer::Update hook (gta4_timer_carry_fix.cpp). Game thread only.
#include <cstdint>

namespace gta4::timer {

// Counts frames as the game would at 30 fps (FusionFix "logical frame counter"): advances by
// one on a frame once 1/30 s of game step has built up, and never more than once a frame, so
// at 30 fps or below it advances every frame like CTimer's own frame counter (0x82C6C2B8).
uint32_t LogicalFrameCount();

}  // namespace gta4::timer
