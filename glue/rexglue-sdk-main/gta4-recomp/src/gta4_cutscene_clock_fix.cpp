// Cutscene time follows the audio smoothly (FusionFix cutscenecam.ixx CutsceneClock, 360 port).
//
// sub_821E5390 is CCutsceneManager::GetTimeStep(float* time). While a cutscene plays
// (ms_State 0x82B977F0 == 8) with audio, it stores max(0, audio_ms - ms_fTimePassedSinceLast-
// AudioStart (0x82B95EF4)), where audio_ms is audCutsceneAudioEntity (0x830329F0)::GetPlayTimeMs
// (sub_82525FB8) plus the episode-2 drift ramps (e2_int, GT06_AA). The audio thread moves that
// position in steps that do not line up with the frames, so every animated object and the camera
// hold still for a frame or two and then jump: judder at any frame rate, and motion vectors that
// alternate between none and large (frame generation then interpolates jumps).
// Other states and the no-audio case (game time step * 1000 + time) are left to the game.
//
// The clock follows the host frame time between audio updates, is pulled toward the audio
// position (500 ms to make up a small difference, 100 ms for 30 ms or more), never runs further
// ahead of the audio than one audio update, never goes back, and takes the audio position as it
// is after a jump or a long frame (250 ms).
#include <algorithm>
#include <bit>
#include <chrono>
#include <cmath>
#include <cstdint>

#include <rex/cvar.h>
#include <rex/logging.h>

#include "gta4_init.h"

REXCVAR_DEFINE_BOOL(gta4_cutscene_smooth_clock, true, "GTA IV/Fixes",
                    "Cutscene animation follows its audio smoothly instead of in the audio "
                    "thread's steps (cutscene judder)");
REXCVAR_DEFINE_BOOL(gta4_cutscene_camera_cut_hold_fix, true, "GTA IV/Fixes",
                    "Hold an animated camera only on the frames at a camera cut, not for the rest "
                    "of the shot above 30 fps (FusionFix)");
REXCVAR_DEFINE_BOOL(gta4_cutscene_clock_log, false, "GTA IV/Diagnostics",
                    "Log the per-frame cutscene time step, the game's and the smoothed, every 60 "
                    "playing frames (gta4-cutscene-clock)");

namespace {

constexpr uint32_t kCutsceneState = 0x82B977F0;     // CCutsceneManager::ms_State
constexpr int32_t kStatePlaying = 8;
constexpr uint32_t kTimeSinceAudioStart = 0x82B95EF4;  // ms_fTimePassedSinceLastAudioStart

class SmoothClock {
 public:
  static constexpr double kResyncMs = 250.0, kSlowPullMs = 500.0, kFastPullMs = 100.0;

  void Unlock() { locked_ = false; }

  double Update(int32_t audio_ms, double now_ms) {
    const double frame_ms = now_ms - last_now_ms_;
    last_now_ms_ = now_ms;
    if (!locked_) {
      locked_ = true;
      clock_ms_ = audio_ms;
      last_audio_ms_ = audio_ms;
      audio_step_ms_ = 0.0;
      return clock_ms_;
    }
    if (audio_ms != last_audio_ms_) {
      const double step = double(audio_ms - last_audio_ms_);
      if (step > 0.0 && step < kResyncMs)
        audio_step_ms_ = audio_step_ms_ > 0.0 ? audio_step_ms_ + (step - audio_step_ms_) * 0.1 : step;
      last_audio_ms_ = audio_ms;
    }
    double error = double(audio_ms) - clock_ms_;
    if (frame_ms < 0.0 || frame_ms > kResyncMs || std::abs(error) > kResyncMs) {
      // A jump in the audio (a new section, a skip): take it. A long frame (loading, a pause,
      // the window in the background): catch up with the audio without going back.
      clock_ms_ = std::abs(error) > kResyncMs ? double(audio_ms) : std::max(clock_ms_, double(audio_ms));
      return clock_ms_;
    }
    double clock = clock_ms_ + frame_ms;
    error = double(audio_ms) - clock;
    clock += error * std::min(1.0, frame_ms / (std::abs(error) < 30.0 ? kSlowPullMs : kFastPullMs));
    // While the audio does not move (it stalled), wait for it.
    clock = std::min(clock, double(audio_ms) + std::max(audio_step_ms_, 10.0) + 5.0);
    clock_ms_ = std::max(clock_ms_, clock);
    return clock_ms_;
  }
  double audio_step_ms() const { return audio_step_ms_; }

 private:
  bool locked_ = false;
  double clock_ms_ = 0.0, last_now_ms_ = 0.0, audio_step_ms_ = 0.0;
  int32_t last_audio_ms_ = -1;
};

// Per-frame step statistics of one time series (the game's, the smoothed).
struct StepStatistics {
  bool primed = false;
  float last = 0;
  uint32_t frames = 0, held = 0;
  double sum = 0, squares = 0, largest = 0;
  void Add(float value) {
    if (primed) {
      const double step = double(value) - double(last);
      ++frames;
      held += step == 0.0;
      sum += step;
      squares += step * step;
      largest = std::max(largest, std::abs(step));
    }
    primed = true;
    last = value;
  }
  double Mean() const { return frames ? sum / frames : 0.0; }
  double Deviation() const {
    if (!frames) return 0.0;
    const double mean = Mean();
    return std::sqrt(std::max(0.0, squares / frames - mean * mean));
  }
};

// The cutscene manager runs on the game thread only.
SmoothClock smooth_clock;
StepStatistics game_steps, smooth_steps;

double HostMilliseconds() {
  using namespace std::chrono;
  return duration<double, std::milli>(steady_clock::now().time_since_epoch()).count();
}

void ResetStatistics() {
  game_steps = {};
  smooth_steps = {};
}

}  // namespace

extern "C" void sub_821E5390(PPCContext& ctx, uint8_t* base) {
  const uint32_t time_address = ctx.r3.u32;
  __imp__sub_821E5390(ctx, base);
  const bool enabled = REXCVAR_GET(gta4_cutscene_smooth_clock);
  const bool log = REXCVAR_GET(gta4_cutscene_clock_log);
  if (int32_t(REX_LOAD_U32(kCutsceneState)) != kStatePlaying || (!enabled && !log)) {
    smooth_clock.Unlock();
    ResetStatistics();
    return;
  }
  const float game_time = std::bit_cast<float>(REX_LOAD_U32(time_address));
  const float since_audio_start = std::bit_cast<float>(REX_LOAD_U32(kTimeSinceAudioStart));
  // With audio the game stored max(0, audio_ms - since_audio_start); the audio position (drift
  // ramps included) is that plus since_audio_start. Without audio (or clamped at 0) the stored
  // value is something else: leave it to the game.
  const uint32_t play = [&] {
    // sub_82525FB8: the entity's current stream slot (2 + (byte 156 + 1) % 2), its play time at +172.
    constexpr uint32_t kAudioEntity = 0x830329F0;
    const int32_t slot = (int32_t(REX_LOAD_U8(kAudioEntity + 156)) + 1) % 2;
    const uint32_t stream = REX_LOAD_U32(kAudioEntity + uint32_t(2 + slot) * 4);
    return stream ? REX_LOAD_U32(stream + 172) : 0xFFFFFFFFu;
  }();
  if (int32_t(play) == -1 || !(game_time > 0.0f) || !std::isfinite(since_audio_start)) {
    smooth_clock.Unlock();
    return;
  }
  const int32_t audio_ms = int32_t(std::lround(double(game_time) + double(since_audio_start)));
  const double clock = smooth_clock.Update(audio_ms, HostMilliseconds());
  const float smoothed = std::max(0.0f, float(clock - double(since_audio_start)));
  if (enabled) REX_STORE_U32(time_address, std::bit_cast<uint32_t>(smoothed));
  if (!log) return;
  game_steps.Add(game_time);
  smooth_steps.Add(smoothed);
  if (game_steps.frames < 60) return;
  REXLOG_INFO(
      "gta4-cutscene-clock applied={} frames={} game: held={} step-mean={:.2f} sd={:.2f} max={:.1f} | "
      "smooth: held={} step-mean={:.2f} sd={:.2f} max={:.1f} | audio-step={:.1f} lead={:.1f} time={:.0f}",
      enabled, game_steps.frames, game_steps.held, game_steps.Mean(), game_steps.Deviation(),
      game_steps.largest, smooth_steps.held, smooth_steps.Mean(), smooth_steps.Deviation(),
      smooth_steps.largest, smooth_clock.audio_step_ms(), double(smoothed) - double(game_time),
      double(smoothed));
  const float last_game = game_steps.last, last_smooth = smooth_steps.last;
  ResetStatistics();
  game_steps.Add(last_game);
  smooth_steps.Add(last_smooth);
}

// Camera cuts hold only at the cut (FusionFix cutscenecam.ixx, the two +0x1B4 stores).
// sub_82604DD8 (r3 = the animated camera, r4 = its phase; called from sub_82605030) turns the
// phase into a 30 fps animation frame and looks for the camera-cut tag (144) on the frames around
// it. Near a cut it puts the phase back to the last one (+440) and stores the held frame + 1 at
// +436 (-1 = none); while +436 holds a frame, later calls take that frame instead of the phase's.
// Above 30 fps several frames fall on one animation frame, so the camera kept the held frame
// past the cut: a visible hitch at cuts. Keeping +436 at -1 (what FusionFix's NOPs do) holds the
// camera only on frames that really are at the cut.
extern "C" void sub_82604DD8(PPCContext& ctx, uint8_t* base) {
  const uint32_t camera = ctx.r3.u32;
  __imp__sub_82604DD8(ctx, base);
  constexpr uint32_t kHeldFrame = 436;
  constexpr uint32_t kNone = 0xBF800000;  // -1.0f
  if (REXCVAR_GET(gta4_cutscene_camera_cut_hold_fix) && camera && REX_LOAD_U32(camera + kHeldFrame) != kNone)
    REX_STORE_U32(camera + kHeldFrame, kNone);
}
