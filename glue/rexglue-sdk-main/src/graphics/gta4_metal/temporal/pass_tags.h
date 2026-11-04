#pragma once
#import <Metal/Metal.h>

// Optional GPU timing of the compute and blit passes around MetalFX. The renderer's pass timer
// (gta4_metal_gpu_pass_log) installs the taggers; without them encoders are created as before.
// The temporal library cannot depend on the renderer (its tests link it alone), hence the hooks.
namespace rex::graphics::gta4_metal::temporal {
using ComputePassTagger = void (*)(MTLComputePassDescriptor*, const char* category);
using BlitPassTagger = void (*)(MTLBlitPassDescriptor*, const char* category);
void SetPassTaggers(ComputePassTagger compute, BlitPassTagger blit);
ComputePassTagger CurrentComputePassTagger();
BlitPassTagger CurrentBlitPassTagger();

inline id<MTLComputeCommandEncoder> ComputeEncoder(id<MTLCommandBuffer> commands, const char* category) {
  if (auto tag = CurrentComputePassTagger()) {
    auto pass = [MTLComputePassDescriptor computePassDescriptor];
    tag(pass, category);
    return [commands computeCommandEncoderWithDescriptor:pass];
  }
  return [commands computeCommandEncoder];
}
inline id<MTLBlitCommandEncoder> BlitEncoder(id<MTLCommandBuffer> commands, const char* category) {
  if (auto tag = CurrentBlitPassTagger()) {
    auto pass = [MTLBlitPassDescriptor blitPassDescriptor];
    tag(pass, category);
    return [commands blitCommandEncoderWithDescriptor:pass];
  }
  return [commands blitCommandEncoder];
}
}  // namespace rex::graphics::gta4_metal::temporal
