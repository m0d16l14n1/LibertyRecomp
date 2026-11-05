// FrameRing upload arenas: one more arena than frame slots, and an arena is reset only after its
// frame and the frame begun after it (which may bind its uploads) have both completed.
#include "ui/metal/frame_ring.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>
namespace {
size_t checks = 0;
void Check(bool x, const char* s) {
  ++checks;
  if (!x) throw std::runtime_error(s);
}
// A command buffer that stays incomplete until `event` reaches `value`.
id<MTLCommandBuffer> Blocked(id<MTLCommandQueue> queue, id<MTLSharedEvent> event, uint64_t value) {
  id<MTLCommandBuffer> cb = [queue commandBuffer];
  [cb encodeWaitForEvent:event value:value];
  return cb;
}
void Run() {
  using rex::ui::metal::FrameRing;
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  Check(device != nil, "Metal device");
  id<MTLCommandQueue> a = [device newCommandQueue], b = [device newCommandQueue];
  std::string error;
  {
    // Serials, previous_committed, and four distinct arenas for four consecutive frames.
    FrameRing ring(1 << 20, 3);
    const rex::ui::metal::UploadArena* seen[4] = {};
    for (uint64_t k = 1; k <= 8; ++k) {
      auto* slot = ring.Begin(error);
      Check(slot && error.empty(), "begin");
      Check(slot->serial == k, "serial in begin order");
      Check(slot->previous_committed == (k > 1), "previous frame committed");
      if (k <= 4) {
        for (uint64_t j = 1; j < k; ++j) Check(seen[j - 1] != slot->uploads, "consecutive frames use distinct arenas");
        seen[k - 1] = slot->uploads;
      }
      auto upload = slot->uploads->Allocate(device, 64, 16);
      Check(bool(upload), "allocate");
      std::memset(upload.data, int(k), 64);
      id<MTLCommandBuffer> cb = [a commandBuffer];
      Check(ring.Commit(*slot, cb), "commit");
      [cb waitUntilCompleted];
    }
    // A cancelled frame is not a committed previous frame.
    auto* cancelled = ring.Begin(error);
    Check(cancelled != nullptr, "begin before cancel");
    ring.Cancel(*cancelled);
    auto* after = ring.Begin(error);
    Check(after && !after->previous_committed, "frame after a cancelled one has no committed previous");
    ring.Cancel(*after);
  }
  {
    // Two slots, three arenas. Frame 2 (on another queue) stays in flight while frame 3 completes,
    // so frame 4 gets a free slot but frame 1's arena is still read by frame 2: Begin waits.
    FrameRing ring(1 << 20, 2);
    id<MTLSharedEvent> gate = [device newSharedEvent];
    auto* f1 = ring.Begin(error);
    Check(f1 != nullptr, "frame 1");
    auto u1 = f1->uploads->Allocate(device, 64, 16);
    std::memset(u1.data, 0x11, 64);
    const auto* arena1 = f1->uploads;
    id<MTLCommandBuffer> c1 = [a commandBuffer];
    Check(ring.Commit(*f1, c1), "commit 1");
    [c1 waitUntilCompleted];
    auto* f2 = ring.Begin(error);
    Check(f2 != nullptr && f2->previous_committed, "frame 2");
    id<MTLCommandBuffer> c2 = Blocked(b, gate, 1);
    Check(ring.Commit(*f2, c2), "commit 2");
    auto* f3 = ring.Begin(error);
    Check(f3 != nullptr, "frame 3 takes frame 1's slot");
    Check(f3->uploads != arena1, "frame 3 does not take frame 1's arena");
    id<MTLCommandBuffer> c3 = [a commandBuffer];
    Check(ring.Commit(*f3, c3), "commit 3");
    [c3 waitUntilCompleted];
    Check(static_cast<const unsigned char*>(u1.data)[0] == 0x11, "frame 1 uploads intact while frame 2 runs");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_global_queue(0, 0), ^{
      gate.signaledValue = 1;
    });
    const auto start = std::chrono::steady_clock::now();
    auto* f4 = ring.TryBegin(error);
    const auto waited = std::chrono::steady_clock::now() - start;
    Check(f4 != nullptr && error.empty(), "frame 4");
    Check(f4->uploads == arena1, "frame 4 reuses frame 1's arena");
    Check(c2.status == MTLCommandBufferStatusCompleted, "frame 1's arena reset only after frame 2 completed");
    Check(waited >= std::chrono::milliseconds(200), "begin waited for the frame reading the arena");
    ring.Cancel(*f4);
  }
}
}  // namespace
int main() {
  @autoreleasepool {
    try {
      Run();
    } catch (const std::exception& e) {
      std::fprintf(stderr, "frame ring: FAILED: %s (after %zu checks)\n", e.what(), checks);
      return 1;
    }
    std::printf("frame ring: %zu checks passed\n", checks);
  }
  return 0;
}
