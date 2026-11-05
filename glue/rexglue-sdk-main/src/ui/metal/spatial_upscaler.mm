#import "spatial_upscaler.h"

#import <MetalFX/MetalFX.h>

#include "metal4_queue.h"

namespace rex::ui::metal {

namespace {
bool Supported(MTLPixelFormat format) {
  switch (format) {
    case MTLPixelFormatRGBA8Unorm:
    case MTLPixelFormatBGRA8Unorm:
    case MTLPixelFormatRGBA16Float:
    case MTLPixelFormatRGB10A2Unorm:
    case MTLPixelFormatBGR10A2Unorm:
      return true;
    default:
      return false;
  }
}
}  // namespace

void SpatialUpscaler::Reset() {
  output_ = nil; scaler3_ = nil; scaler4_ = nil; fence_ = nil;
  format_ = MTLPixelFormatInvalid;
  in_width_ = in_height_ = out_width_ = out_height_ = 0;
}

bool SpatialUpscaler::Configure(id<MTLDevice> device, id<MTLCommandBuffer> commands, id<MTLTexture> source,
                                uint32_t width, uint32_t height, std::string& error) {
  const bool metal4 = IsMetal4(commands);
  if (output_ && format_ == source.pixelFormat && in_width_ == source.width && in_height_ == source.height &&
      out_width_ == width && out_height_ == height && metal4_ == metal4)
    return true;
  Reset();
  if (![MTLFXSpatialScalerDescriptor supportsDevice:device]) { unavailable_ = true; return false; }
  MTLFXSpatialScalerDescriptor* d = [MTLFXSpatialScalerDescriptor new];
  d.colorTextureFormat = d.outputTextureFormat = source.pixelFormat;
  d.inputWidth = source.width; d.inputHeight = source.height;
  d.outputWidth = width; d.outputHeight = height;
  // The finished title image: display-referred, gamma encoded (or its float copy in [0,1]).
  d.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
  MTLTextureUsage output_usage = MTLTextureUsageShaderRead;
  MTLTextureUsage color_usage = 0;
  if (metal4) {
    if (@available(macOS 26.0, *)) {
      id<MTL4Compiler> compiler = Metal4Compiler(commands.commandQueue);
      id<MTL4FXSpatialScaler> scaler = compiler ? [d newSpatialScalerWithDevice:device compiler:compiler] : nil;
      if (!scaler) { unavailable_ = true; return false; }
      fence_ = [device newFence];
      scaler.fence = fence_;
      output_usage |= scaler.outputTextureUsage; color_usage = scaler.colorTextureUsage;
      scaler4_ = scaler;
    } else {
      unavailable_ = true; return false;
    }
  } else {
    id<MTLFXSpatialScaler> scaler = [d newSpatialScalerWithDevice:device];
    if (!scaler) { unavailable_ = true; return false; }
    output_usage |= scaler.outputTextureUsage; color_usage = scaler.colorTextureUsage;
    scaler3_ = scaler;
  }
  if ((source.usage & color_usage) != color_usage) { Reset(); unavailable_ = true; return false; }
  MTLTextureDescriptor* t = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:source.pixelFormat
                                                                               width:width height:height mipmapped:NO];
  t.storageMode = MTLStorageModePrivate;
  t.usage = output_usage;
  output_ = [device newTextureWithDescriptor:t];
  if (!output_) { Reset(); error = "MetalFX spatial output allocation failed"; return false; }
  output_.label = @"Liberty MetalFX spatial output";
  format_ = source.pixelFormat;
  in_width_ = uint32_t(source.width); in_height_ = uint32_t(source.height);
  out_width_ = width; out_height_ = height;
  metal4_ = metal4;
  return true;
}

id<MTLTexture> SpatialUpscaler::Encode(id<MTLDevice> device, id<MTLCommandBuffer> commands, id<MTLTexture> source,
                                       uint32_t width, uint32_t height, std::string& error) {
  if (unavailable_ || !source || !commands || !width || !height) return nil;
  // Upscaling only: at or below the source size bilinear (or nothing) is already right.
  if (width <= source.width || height <= source.height) return nil;
  if (!Supported(source.pixelFormat) || source.textureType != MTLTextureType2D || source.sampleCount != 1) return nil;
  if (!Configure(device, commands, source, width, height, error)) return nil;
  if (scaler4_) {
    if (@available(macOS 26.0, *)) {
      id<MTL4FXSpatialScaler> scaler = scaler4_;
      scaler.colorTexture = source;
      scaler.outputTexture = output_;
      scaler.inputContentWidth = source.width;
      scaler.inputContentHeight = source.height;
      NSArray<id<MTLResource>>* used = @[ source, output_ ];
      if (!EncodeMetal4(commands, fence_, used, ^(id<MTL4CommandBuffer> cb) { [scaler encodeToCommandBuffer:cb]; },
                        @"MetalFX spatial upscaler")) {
        error = "MetalFX spatial encode failed";
        return nil;
      }
    }
  } else {
    id<MTLFXSpatialScaler> scaler = scaler3_;
    scaler.colorTexture = source;
    scaler.outputTexture = output_;
    scaler.inputContentWidth = source.width;
    scaler.inputContentHeight = source.height;
    [scaler encodeToCommandBuffer:commands];
  }
  ++encodes_;
  return output_;
}

}  // namespace rex::ui::metal
