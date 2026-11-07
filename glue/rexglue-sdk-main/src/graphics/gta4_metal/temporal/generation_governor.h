#pragma once
// Automatic MetalFX frame generation (gta4_metalfx_frame_generation_auto).
//
// Frame generation shows each real frame with a generated midpoint and paces real frames to half
// the refresh, so it only helps in one band: real frames too slow to keep up with the refresh
// (they miss vsync and judder), yet fast enough that a real frame plus the interpolation fits in
// two refreshes. Above the band the game shows every frame for real; below it generation cannot
// keep its pace, and the midpoint has to bridge large motion, where it tears.
//
// Fed once per real frame with that frame's work: the interval between real frames minus the
// time the presenter held it for pacing. Generation turns on when the work has stayed above the
// refresh for `kEnterNs` and the work plus the learned interpolation cost fits in two refreshes;
// it turns off when the work stops fitting in two refreshes for `kLeaveSlowNs`, when fewer than
// `kMinPairedShare` of the real frames get their generated midpoint over a second (the pairs
// cannot be kept on time, measured on an M5 Air: 26 ms real frames left every fifth pair in
// flight and showed 40 fps, no better than not generating), or when the work without the
// interpolation cost would fit in a refresh with room to spare for `kLeaveFastNs`. The first two
// back off: the cooldown doubles with each failure in a row (from `kCooldownNs`, at most
// `kMaxCooldownNs`) and resets after generation has lasted `kSuccessNs`. The interpolation cost
// is learned on every switch on: the work a second into generating minus the work just before.
#include <algorithm>
#include <cstdint>

namespace rex::graphics::gta4_metal::temporal {

class GenerationGovernor {
 public:
  static constexpr uint64_t kEnterNs = 1'000'000'000;
  static constexpr uint64_t kLeaveSlowNs = 1'000'000'000;
  static constexpr uint64_t kLeaveFastNs = 2'000'000'000;
  static constexpr uint64_t kCooldownNs = 8'000'000'000;
  static constexpr uint64_t kMaxCooldownNs = 120'000'000'000;
  static constexpr uint64_t kSuccessNs = 10'000'000'000;
  static constexpr uint64_t kPairWarmupNs = 500'000'000;
  static constexpr uint64_t kPairWindowNs = 1'000'000'000;
  static constexpr double kMinPairedShare = 0.75;
  static constexpr double kEnterBudget = 1.75;  // refreshes a real frame plus its midpoint may take
  static constexpr uint64_t kLearnAfterNs = 1'000'000'000;
  static constexpr double kInitialCostMs = 4.0;

  enum class Change { kNone, kOn, kOffSlow, kOffFast, kOffUnpaired };

  // `work_ns`: the real frame's interval minus its pacing wait. `interval_ns`: the real frame's
  // interval (advances the governor's clock). `refresh_hz`: the display's refresh. `paired`: the
  // previous real frame got its generated midpoint (read only while generating).
  Change Update(uint64_t interval_ns, uint64_t work_ns, uint32_t refresh_hz, bool paired = true) {
    if (!interval_ns || interval_ns > 250'000'000) {  // a pause, load or hitch: start over
      above_ns_ = fast_ns_ = slow_ns_ = 0;
      smoothed_ms_ = 0;
      return Change::kNone;
    }
    const double period = 1000.0 / double(refresh_hz ? refresh_hz : 60);
    const double work = double(std::min(work_ns, interval_ns)) * 1.0e-6;
    smoothed_ms_ = smoothed_ms_ > 0 ? (7.0 * smoothed_ms_ + work) / 8.0 : work;
    now_ns_ += interval_ns;
    if (!generating_) {
      if (cooldown_until_ns_ > now_ns_) return Change::kNone;
      const bool judders = smoothed_ms_ > 1.10 * period;
      const bool fits = smoothed_ms_ + cost_ms_ <= kEnterBudget * period;
      above_ns_ = judders && fits ? above_ns_ + interval_ns : 0;
      if (above_ns_ < kEnterNs) return Change::kNone;
      generating_ = true;
      before_ms_ = smoothed_ms_;
      on_since_ns_ = now_ns_;
      learned_ = false;
      above_ns_ = fast_ns_ = slow_ns_ = 0;
      window_ns_ = window_paired_ns_ = 0;
      return Change::kOn;
    }
    if (now_ns_ - on_since_ns_ >= kSuccessNs) failures_ = 0;
    if (now_ns_ - on_since_ns_ >= kPairWarmupNs) {
      window_ns_ += interval_ns;
      if (paired) window_paired_ns_ += interval_ns;
      if (window_ns_ >= kPairWindowNs) {
        const double share = double(window_paired_ns_) / double(window_ns_);
        window_ns_ = window_paired_ns_ = 0;
        if (share < kMinPairedShare) return Fail(Change::kOffUnpaired);
      }
    }
    if (!learned_ && now_ns_ - on_since_ns_ >= kLearnAfterNs) {
      const double measured = std::clamp(smoothed_ms_ - before_ms_, 0.0, 2.0 * period);
      cost_ms_ = 0.5 * cost_ms_ + 0.5 * measured;
      learned_ = true;
    }
    slow_ns_ = smoothed_ms_ > 2.05 * period ? slow_ns_ + interval_ns : 0;
    fast_ns_ = learned_ && smoothed_ms_ - cost_ms_ < 0.85 * period ? fast_ns_ + interval_ns : 0;
    if (slow_ns_ >= kLeaveSlowNs) return Fail(Change::kOffSlow);
    if (fast_ns_ >= kLeaveFastNs) {
      generating_ = false;
      slow_ns_ = fast_ns_ = 0;
      return Change::kOffFast;
    }
    return Change::kNone;
  }

  bool generating() const { return generating_; }
  uint32_t failures() const { return failures_; }
  double smoothed_work_ms() const { return smoothed_ms_; }
  double cost_ms() const { return cost_ms_; }
  void Reset() { *this = GenerationGovernor{}; }

 private:
  Change Fail(Change why) {
    generating_ = false;
    const uint64_t cooldown = std::min(kMaxCooldownNs, kCooldownNs << std::min(failures_, 4u));
    cooldown_until_ns_ = now_ns_ + cooldown;
    ++failures_;
    slow_ns_ = fast_ns_ = window_ns_ = window_paired_ns_ = 0;
    return why;
  }
  bool generating_ = false, learned_ = false;
  uint32_t failures_ = 0;
  uint64_t window_ns_ = 0, window_paired_ns_ = 0;
  double smoothed_ms_ = 0, cost_ms_ = kInitialCostMs, before_ms_ = 0;
  uint64_t now_ns_ = 0, above_ns_ = 0, fast_ns_ = 0, slow_ns_ = 0;
  uint64_t on_since_ns_ = 0, cooldown_until_ns_ = 0;
};

}  // namespace rex::graphics::gta4_metal::temporal
