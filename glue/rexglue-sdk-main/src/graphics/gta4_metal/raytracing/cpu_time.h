#pragma once
// Encode-thread CPU time of the ray-tracing paths, for the renderer's 300-frame log line
// (capture-cpu-us and friends): cumulative nanoseconds and calls, read as windowed deltas.
#include <chrono>
#include <cstdint>

namespace rex::graphics::gta4_metal::raytracing {

struct CpuTime {
  uint64_t ns = 0, calls = 0;
};

class ScopedCpuTime {
 public:
  explicit ScopedCpuTime(CpuTime& time) : time_(time), start_(std::chrono::steady_clock::now()) {}
  ~ScopedCpuTime() {
    time_.ns += uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - start_).count());
    ++time_.calls;
  }
  ScopedCpuTime(const ScopedCpuTime&) = delete;
  ScopedCpuTime& operator=(const ScopedCpuTime&) = delete;

 private:
  CpuTime& time_;
  std::chrono::steady_clock::time_point start_;
};

}  // namespace rex::graphics::gta4_metal::raytracing
