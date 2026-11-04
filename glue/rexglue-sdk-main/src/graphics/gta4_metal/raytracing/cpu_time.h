#pragma once
// Encode-thread CPU time of the ray-tracing paths, for the renderer's 300-frame log line
// (capture-cpu-us and friends): cumulative nanoseconds and calls, read as windowed deltas.
#include <chrono>
#include <cstdint>
#include <mach/mach_time.h>

namespace rex::graphics::gta4_metal::raytracing {

// Monotonic nanoseconds for the encode-thread timers. steady_clock::now() goes through
// clock_gettime and mach_continuous_time; it was 3% of the render thread under the bench (the
// frame log's submit timer). mach_absolute_time is a commpage read.
inline uint64_t FastNowNs() {
  static const mach_timebase_info_data_t timebase = [] {
    mach_timebase_info_data_t t{};
    mach_timebase_info(&t);
    return t;
  }();
  const uint64_t ticks = mach_absolute_time();
  return timebase.numer == timebase.denom ? ticks : ticks * timebase.numer / timebase.denom;
}

struct CpuTime {
  uint64_t ns = 0, calls = 0;
  uint64_t timed = 0;  // calls that were timed: ns covers these (all of them for ScopedCpuTime)
  uint64_t sampler = 0x9E3779B97F4A7C15ull;  // ScopedSampledCpuTime's selection state
};

// True for about one call in (mask + 1), chosen pseudo-randomly (xorshift64) rather than every
// Nth call, so a periodic command pattern (state, state, draw, ...) cannot alias with it.
inline bool SampleOneIn(uint64_t& state, uint64_t mask) {
  state ^= state << 13; state ^= state >> 7; state ^= state << 17;
  return (state & mask) == 0;
}

class ScopedCpuTime {
 public:
  explicit ScopedCpuTime(CpuTime& time) : time_(time), start_(FastNowNs()) {}
  ~ScopedCpuTime() {
    time_.ns += FastNowNs() - start_;
    ++time_.calls;
    ++time_.timed;
  }
  ScopedCpuTime(const ScopedCpuTime&) = delete;
  ScopedCpuTime& operator=(const ScopedCpuTime&) = delete;

 private:
  CpuTime& time_;
  uint64_t start_;
};

// Counts every call but reads the clock on about one in `Period` (two clock reads cost about
// 1% of a 3 us draw). ns / timed is the mean; calls is the true count.
template <uint64_t Period>
class ScopedSampledCpuTime {
  static_assert(Period && (Period & (Period - 1)) == 0);
 public:
  explicit ScopedSampledCpuTime(CpuTime& time) : time_(time), timed_(SampleOneIn(time.sampler, Period - 1)) {
    ++time.calls;
    if (timed_) start_ = FastNowNs();
  }
  ~ScopedSampledCpuTime() {
    if (!timed_) return;
    time_.ns += FastNowNs() - start_;
    ++time_.timed;
  }
  ScopedSampledCpuTime(const ScopedSampledCpuTime&) = delete;
  ScopedSampledCpuTime& operator=(const ScopedSampledCpuTime&) = delete;

 private:
  CpuTime& time_;
  bool timed_;
  uint64_t start_ = 0;
};

}  // namespace rex::graphics::gta4_metal::raytracing
