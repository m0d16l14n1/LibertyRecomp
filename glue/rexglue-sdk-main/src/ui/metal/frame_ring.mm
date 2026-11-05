#include "frame_ring.h"

#include "context.h"

namespace rex::ui::metal {

FrameRing::~FrameRing() {
  std::string ignored;
  WaitIdle(ignored);
}

bool FrameRing::Owns(const Slot& candidate) const {
  for (const auto& slot : slots_) if (&slot == &candidate) return true;
  return false;
}

FrameRing::Slot* FrameRing::TryBegin(std::string& error) {
  error.clear();
  for (size_t index = 0; index < active_slot_count_; ++index) {
    const size_t selected = (next_ + index) % active_slot_count_;
    auto& slot = slots_[selected];
    if (slot.encoding) continue;
    if (slot.submission) {
      const auto status = slot.submission.status;
      if (status == MTLCommandBufferStatusError) {
        error = MetalError(slot.submission.error, "Metal submission failed.");
        return nullptr;
      }
      if (status != MTLCommandBufferStatusCompleted) continue;
      slot.submission = nil;
    }
    // One arena more than slots: the arena this frame takes was written two frames back or
    // earlier, and both of its users finished before this slot freed up (one queue, in order).
    // The wait is a backstop for that order.
    const size_t arenas = active_slot_count_ + 1;
    const size_t arena = size_t(begun_ % arenas);
    for (id<MTLCommandBuffer> user : {arenas_[arena].own, arenas_[arena].next}) {
      if (!user) continue;
      const auto status = user.status;
      if (status == MTLCommandBufferStatusCompleted || status == MTLCommandBufferStatusError) continue;
      if (status == MTLCommandBufferStatusNotEnqueued) continue;  // never committed: not on the GPU
      [user waitUntilCompleted];
    }
    arenas_[arena].own = arenas_[arena].next = nil;
    arenas_[arena].uploads.Reset();
    slot.uploads = &arenas_[arena].uploads;
    slot.arena = arena;
    slot.serial = ++begun_;
    slot.previous_committed = last_committed_ && last_arena_ != SIZE_MAX;
    last_arena_ = arena;
    last_committed_ = false;
    slot.encoding = true;
    next_ = (selected + 1) % active_slot_count_;
    return &slot;
  }
  return nullptr;
}

FrameRing::Slot* FrameRing::Begin(std::string& error) {
  if (auto* slot = TryBegin(error)) return slot;
  if (!error.empty()) return nullptr;
  for (size_t i = 0; i < active_slot_count_; ++i) {
    auto& slot = slots_[(next_ + i) % active_slot_count_];
    if (!slot.submission) continue;
    [slot.submission waitUntilCompleted];
    return TryBegin(error);
  }
  error = "All Metal frame slots are already being encoded";
  return nullptr;
}

bool FrameRing::Commit(Slot& slot, id<MTLCommandBuffer> command_buffer) {
  if (!Owns(slot) || !slot.encoding || slot.submission || !command_buffer ||
      command_buffer.status != MTLCommandBufferStatusNotEnqueued ||
      !command_buffer.retainedReferences) return false;
  slot.submission = command_buffer;
  slot.encoding = false;
  arenas_[slot.arena].own = command_buffer;
  // The frame begun before this one may be read by this one (its previous-frame uploads).
  const size_t arenas = active_slot_count_ + 1;
  arenas_[(slot.arena + arenas - 1) % arenas].next = command_buffer;
  if (slot.arena == last_arena_) last_committed_ = true;
  [command_buffer commit];
  return true;
}

void FrameRing::Cancel(Slot& slot) {
  if (Owns(slot) && !slot.submission) slot.encoding = false;
}

bool FrameRing::WaitIdle(std::string& error) {
  error.clear();
  for (auto& slot : slots_) {
    if (!slot.submission) continue;
    [slot.submission waitUntilCompleted];
    if (slot.submission.status == MTLCommandBufferStatusError && error.empty())
      error = MetalError(slot.submission.error, "Metal submission failed.");
    slot.submission = nil;
  }
  for (auto& arena : arenas_) {
    for (id<MTLCommandBuffer> user : {arena.own, arena.next})
      if (user && user.status != MTLCommandBufferStatusNotEnqueued) [user waitUntilCompleted];
    arena.own = arena.next = nil;
  }
  return error.empty();
}

size_t FrameRing::reserved_bytes() const {
  size_t bytes = 0;
  for (const auto& arena : arenas_) bytes += arena.uploads.reserved_bytes();
  return bytes;
}

}  // namespace rex::ui::metal
