#pragma once
#import <Metal/Metal.h>

#include <string>

// Opt-in GPU time per render pass (gta4_metal_gpu_pass_log). Uses Metal timestamp counters sampled
// at stage boundaries: each tagged render pass records start-of-vertex and end-of-fragment
// timestamps, which completion handlers resolve and sum per category. Every 300 frames the average
// milliseconds per frame for each category is appended to a CSV. No-ops when disabled.
//
// Call sites run on the renderer's single submitting thread (the producer lock serializes them).
namespace rex::graphics::gta4_metal::gpu_pass_timer {

void Initialize(id<MTLDevice> device, const std::string& csv_path);
bool enabled();
// Attach timestamp sampling to a render pass before its encoder is created.
void Tag(MTLRenderPassDescriptor* pass, std::string category);
// The same for compute and blit passes (start and end of the encoder). The temporal passes
// around MetalFX use these through temporal::SetPassTaggers, installed by Initialize.
void Tag(MTLComputePassDescriptor* pass, std::string category);
void Tag(MTLBlitPassDescriptor* pass, std::string category);
// Hand every pass tagged since the previous commit to `commands`' completion handler. Also adds
// the command buffer's whole GPU span ("#gpu-span") and the part of it no tagged pass covers
// ("#gpu-untagged": MetalFX scaling and interpolation, which cannot be tagged, and idle gaps).
void Commit(id<MTLCommandBuffer> commands);
// Count an event (e.g. why a render pass ended); reported per frame alongside the pass timings.
void Count(const std::string& key);
// One presented frame; flushes averages every 300 frames.
void FrameEnd();

}  // namespace rex::graphics::gta4_metal::gpu_pass_timer
