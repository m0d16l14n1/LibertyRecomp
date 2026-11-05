#pragma once

#import <Metal/Metal.h>

#include <array>
#include <cstddef>
#include <string>

#include "upload_arena.h"

namespace rex::ui::metal {

// Single CPU owner. Metal's command-buffer status is the GPU completion boundary.
// No completion block captures a renderer, window, or frame pointer.
class FrameRing {
 public:
  // Up to three title command buffers in flight: with two, CPU submit and GPU time both just
  // under a 60 Hz tick still miss ticks on jitter (alternating 17/33 ms frames). The active
  // count comes from gta4_native_frames_in_flight.
  static constexpr size_t kSlotCount = 3;
  struct Slot {
    // This frame's upload arena. It outlives the frame by one: it is reset only after this frame
    // and the frame begun after it have completed, so that next frame may bind this frame's
    // uploads (the renderer's previous-frame constants) without copying them.
    UploadArena* uploads = nullptr;
    id<MTLCommandBuffer> submission = nil;
    bool encoding = false;
    uint64_t serial = 0;              // begin order, from 1
    bool previous_committed = false;  // the frame begun just before this one was committed
    size_t arena = 0;
  };
  explicit FrameRing(size_t upload_budget = UploadArena::kDefaultBudget, size_t slot_count = kSlotCount)
      : arenas_{Arena{upload_budget}, Arena{upload_budget}, Arena{upload_budget}, Arena{upload_budget}},
        active_slot_count_(slot_count < 1 ? 1 : slot_count > kSlotCount ? kSlotCount : slot_count) {}
  FrameRing(const FrameRing&) = delete;
  FrameRing& operator=(const FrameRing&) = delete;
  ~FrameRing();

  Slot* TryBegin(std::string& error);
  Slot* Begin(std::string& error);
  bool Commit(Slot& slot, id<MTLCommandBuffer> command_buffer);
  void Cancel(Slot& slot);
  bool WaitIdle(std::string& error);
  size_t reserved_bytes() const;

 private:
  bool Owns(const Slot& slot) const;
  struct Arena {
    explicit Arena(size_t budget) : uploads(budget) {}
    UploadArena uploads;
    id<MTLCommandBuffer> own = nil, next = nil;  // the frame that wrote it, the frame after it
  };
  std::array<Slot, kSlotCount> slots_;
  std::array<Arena, kSlotCount + 1> arenas_;
  size_t next_ = 0;
  uint64_t begun_ = 0;
  size_t last_arena_ = SIZE_MAX;  // the arena of the frame begun last
  bool last_committed_ = false;
  size_t active_slot_count_ = kSlotCount;
};

}  // namespace rex::ui::metal
