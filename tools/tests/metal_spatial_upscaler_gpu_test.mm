// MetalFX spatial pre-pass for the presenter: upscales on a Metal 3 queue and through the
// Metal 4 proxy, to the requested size, with the image's content; declines what it should.
#include "ui/metal/metal4_queue.h"
#include "ui/metal/spatial_upscaler.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>
namespace {
size_t checks = 0;
void Check(bool x, const char* s) {
  ++checks;
  if (!x) throw std::runtime_error(s);
}
constexpr NSUInteger kInW = 64, kInH = 36, kOutW = 160, kOutH = 90;
// Left half dark red, right half a vertical green ramp; blue constant.
void Pixel(NSUInteger x, NSUInteger y, NSUInteger w, NSUInteger h, uint8_t* p) {
  if (x < w / 2) { p[0] = 160; p[1] = 20; } else { p[0] = 20; p[1] = uint8_t(255 * y / (h - 1)); }
  p[2] = 64; p[3] = 255;
}
id<MTLTexture> Source(id<MTLDevice> device, MTLPixelFormat format = MTLPixelFormatRGBA8Unorm) {
  MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:kInW height:kInH mipmapped:NO];
  d.storageMode = MTLStorageModeShared;
  d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
  id<MTLTexture> t = [device newTextureWithDescriptor:d];
  if (format == MTLPixelFormatRGBA8Unorm) {
    std::vector<uint8_t> bytes(kInW * kInH * 4);
    for (NSUInteger y = 0; y < kInH; ++y)
      for (NSUInteger x = 0; x < kInW; ++x) Pixel(x, y, kInW, kInH, &bytes[(y * kInW + x) * 4]);
    [t replaceRegion:MTLRegionMake2D(0, 0, kInW, kInH) mipmapLevel:0 withBytes:bytes.data() bytesPerRow:kInW * 4];
  }
  return t;
}
std::vector<uint8_t> Upscale(id<MTLDevice> device, id<MTLCommandQueue> queue, rex::ui::metal::SpatialUpscaler& up,
                             id<MTLTexture> source, bool metal4) {
  std::string error;
  id<MTLCommandBuffer> cb = [queue commandBuffer];
  Check(rex::ui::metal::IsMetal4(cb) == metal4, "queue kind");
  id<MTLTexture> out = up.Encode(device, cb, source, kOutW, kOutH, error);
  Check(out != nil && error.empty(), "spatial output");
  Check(out.width == kOutW && out.height == kOutH && out.pixelFormat == source.pixelFormat, "output size and format");
  Check((out.usage & MTLTextureUsageShaderRead) != 0, "output readable by the bilinear pass");
  id<MTLBuffer> read = [device newBufferWithLength:kOutW * kOutH * 4 options:MTLResourceStorageModeShared];
  id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
  [blit copyFromTexture:out sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
             sourceSize:MTLSizeMake(kOutW, kOutH, 1) toBuffer:read destinationOffset:0
 destinationBytesPerRow:kOutW * 4 destinationBytesPerImage:kOutW * kOutH * 4];
  [blit endEncoding];
  [cb commit];
  [cb waitUntilCompleted];
  Check(cb.status == MTLCommandBufferStatusCompleted, "command buffer completed");
  const auto* p = static_cast<const uint8_t*>(read.contents);
  return std::vector<uint8_t>(p, p + kOutW * kOutH * 4);
}
void CheckImage(const std::vector<uint8_t>& got) {
  // Away from the vertical edge (and its sharpening ring) the content matches the source
  // sampled at the same normalized position.
  double worst = 0;
  for (NSUInteger y = 2; y + 2 < kOutH; ++y)
    for (NSUInteger x = 2; x + 2 < kOutW; ++x) {
      if (x > kOutW / 2 - 8 && x < kOutW / 2 + 8) continue;
      const double v = (y + 0.5) / kOutH;
      uint8_t want[4];
      Pixel(x < kOutW / 2 ? 0 : kInW - 1, 0, kInW, kInH, want);
      if (x >= kOutW / 2) want[1] = uint8_t(std::lround(std::clamp(255 * (v * kInH - 0.5) / (kInH - 1), 0.0, 255.0)));
      const uint8_t* g = &got[(y * kOutW + x) * 4];
      for (int c = 0; c < 3; ++c) worst = std::max(worst, std::fabs(double(g[c]) - want[c]));
    }
  std::printf("  worst channel error away from the edge: %.0f\n", worst);
  Check(worst <= 12, "upscaled content matches the source");
  // The edge stays an edge: within a few output pixels red goes from 160 to 20.
  const uint8_t* l = &got[(kOutH / 2 * kOutW + kOutW / 2 - 4) * 4];
  const uint8_t* r = &got[(kOutH / 2 * kOutW + kOutW / 2 + 3) * 4];
  Check(l[0] > 130 && r[0] < 50, "edge kept sharp");
}
void Run() {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  Check(device != nil, "device");
  id<MTLTexture> source = Source(device);
  rex::ui::metal::SpatialUpscaler up3;
  std::string error;
  {
    id<MTLCommandQueue> queue = [device newCommandQueue];
    // Declines non-upscales and unsupported formats without an error.
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    Check(up3.Encode(device, cb, source, kInW, kInH, error) == nil && error.empty(), "same size declined");
    Check(up3.Encode(device, cb, source, kOutW, kInH, error) == nil && error.empty(), "one axis declined");
    id<MTLTexture> odd = Source(device, MTLPixelFormatR32Float);
    Check(up3.Encode(device, cb, odd, kOutW, kOutH, error) == nil && error.empty(), "format declined");
    [cb commit];
    auto image = Upscale(device, queue, up3, source, false);
    std::printf("metal3:\n");
    CheckImage(image);
    auto again = Upscale(device, queue, up3, source, false);
    Check(again == image, "reused scaler gives the same image");
    Check(up3.encodes() == 2, "encode count");
    std::string error4;
    id<MTLCommandQueue> queue4 = rex::ui::metal::NewMetal4Queue(device, error4);
    if (!queue4) { std::printf("metal4: skipped (%s)\n", error4.c_str()); return; }
    rex::ui::metal::SpatialUpscaler up4;
    auto image4 = Upscale(device, queue4, up4, source, true);
    std::printf("metal4:\n");
    CheckImage(image4);
    size_t differ = 0;
    for (size_t i = 0; i < image.size(); ++i) differ += std::abs(int(image[i]) - int(image4[i])) > 2;
    std::printf("  bytes differing from metal3 by >2: %zu\n", differ);
    Check(differ == 0, "metal4 matches metal3");
    // Switching the same object between queue kinds rebuilds the scaler.
    auto switched = Upscale(device, queue4, up3, source, true);
    Check(switched == image4, "scaler rebuilt for the metal4 queue");
  }
}
}  // namespace
int main() {
  @autoreleasepool {
    try {
      Run();
    } catch (const std::exception& e) {
      std::fprintf(stderr, "metal spatial upscaler: FAILED: %s (after %zu checks)\n", e.what(), checks);
      return 1;
    }
    std::printf("metal spatial upscaler: %zu checks passed\n", checks);
  }
  return 0;
}
