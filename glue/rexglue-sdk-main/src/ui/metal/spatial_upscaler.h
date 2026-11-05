#pragma once

#import <Metal/Metal.h>

#include <cstdint>
#include <string>

namespace rex::ui::metal {

// MetalFX spatial upscaling of the finished game image before the presenter's bilinear output
// pass (present_effect = bilinear): the output pass then samples a display-sized image instead of
// stretching the 720p one. Uses the MTL4FX object on a Metal 4 proxy command buffer and the
// Metal 3 one otherwise. Not for HDR-range input: the game image is display-referred here.
class SpatialUpscaler {
 public:
  // Upscales `source` to width x height into a texture this object owns, encoded on `commands`.
  // Returns nil (and leaves `source` to the caller) when there is nothing to upscale, the format
  // is unsupported, or the scaler cannot be made; `error` is set only for a real failure.
  id<MTLTexture> Encode(id<MTLDevice> device, id<MTLCommandBuffer> commands, id<MTLTexture> source,
                        uint32_t width, uint32_t height, std::string& error);
  void Reset();
  uint64_t encodes() const { return encodes_; }

 private:
  bool Configure(id<MTLDevice> device, id<MTLCommandBuffer> commands, id<MTLTexture> source,
                 uint32_t width, uint32_t height, std::string& error);
  id<MTLTexture> output_ = nil;
  id scaler3_ = nil;  // id<MTLFXSpatialScaler>
  id scaler4_ = nil;  // id<MTL4FXSpatialScaler>
  id<MTLFence> fence_ = nil;
  MTLPixelFormat format_ = MTLPixelFormatInvalid;
  uint32_t in_width_ = 0, in_height_ = 0, out_width_ = 0, out_height_ = 0;
  bool metal4_ = false;
  bool unavailable_ = false;  // the device or format refused once: stay on bilinear
  uint64_t encodes_ = 0;
};

}  // namespace rex::ui::metal
