#pragma once
#include <array>
#include <cstddef>
#include <cstdint>

namespace rex::graphics::gta4_metal {
// Dirty words 0/1 describe VS/PS float banks. Observe EVERY draw and clear,
// even if it is culled, empty, or rejected before an upload. Cached-list replay
// supplies full masks; mutable deferred-light effects require full snapshots.
//
// The masks accumulate until the bank is copied, so Dirty() is every 64-byte
// register group written since the last copy. Group g (registers 4g..4g+3) is
// bit 63-g of its word, for both banks (graphics_system.cpp kVertex/PixelConstantDirtySpans;
// the pixel bank's 56 groups use bits 63..8, bits 7..0 belong to other state).
class GuestConstantTracking {
 public:
  void Observe(uint32_t device, uint64_t vertex, uint64_t pixel, bool force) {
    if (device != device_) { Reset(); device_ = device; }
    dirty_[0] |= force ? ~uint64_t{0} : vertex;
    dirty_[1] |= force ? ~uint64_t{0} : pixel;
  }
  bool Clean(size_t bank) const { return copied_[bank] && !dirty_[bank]; }
  // Copied() since the last Reset(): Dirty() is then exact relative to that copy.
  bool Known(size_t bank) const { return copied_[bank]; }
  uint64_t Dirty(size_t bank) const { return dirty_[bank]; }
  void Copied(size_t bank) { copied_[bank] = true; dirty_[bank] = 0; }
  void Reset() { copied_.fill(false); dirty_.fill(0); }
  static constexpr uint64_t GroupBit(size_t group) { return uint64_t{1} << (63 - group); }
 private:
  uint32_t device_ = 0;
  std::array<bool, 2> copied_{};
  std::array<uint64_t, 2> dirty_{};
};
}  // namespace rex::graphics::gta4_metal
