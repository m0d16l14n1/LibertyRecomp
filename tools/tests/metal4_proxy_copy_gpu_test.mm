// Metal 4 proxy copies: each blit selector the renderer uses, through the proxy's direct
// methods, moves the right bytes; consecutive copies in one encoder stay ordered.
#include "ui/metal/metal4_queue.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
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
id<MTLTexture> Texture(id<MTLDevice> device, NSUInteger w, NSUInteger h, MTLStorageMode mode = MTLStorageModeShared) {
  MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                width:w height:h mipmapped:NO];
  d.storageMode = mode;
  d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
  return [device newTextureWithDescriptor:d];
}
void Run() {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  Check(device != nil, "device");
  std::string error;
  id<MTLCommandQueue> queue = rex::ui::metal::NewMetal4Queue(device, error);
  if (!queue) { std::printf("metal4 proxy copy: skipped (%s)\n", error.c_str()); return; }
  Check(rex::ui::metal::IsMetal4(queue), "proxy queue");
  constexpr NSUInteger W = 16, H = 8, row = W * 4;
  std::vector<uint8_t> pattern(row * H);
  for (size_t i = 0; i < pattern.size(); ++i) pattern[i] = uint8_t(i * 7 + 3);
  id<MTLBuffer> source = [device newBufferWithBytes:pattern.data() length:pattern.size() options:MTLResourceStorageModeShared];
  id<MTLBuffer> staging = [device newBufferWithLength:pattern.size() options:MTLResourceStorageModeShared];
  id<MTLBuffer> out = [device newBufferWithLength:pattern.size() options:MTLResourceStorageModeShared];
  id<MTLBuffer> out2 = [device newBufferWithLength:pattern.size() options:MTLResourceStorageModeShared];
  id<MTLTexture> a = Texture(device, W, H, MTLStorageModePrivate), b = Texture(device, W, H, MTLStorageModePrivate);
  id<MTLCommandBuffer> cb = [queue commandBuffer];
  Check(rex::ui::metal::IsMetal4(cb), "proxy command buffer");
  id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
  // A chain where each copy reads what the one before wrote: buffer->buffer->texture->texture
  // (whole and region forms)->buffer, then buffer->buffer.
  [blit copyFromBuffer:source sourceOffset:0 toBuffer:staging destinationOffset:0 size:pattern.size()];
  [blit copyFromBuffer:staging sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:row * H
            sourceSize:MTLSizeMake(W, H, 1) toTexture:a destinationSlice:0 destinationLevel:0
     destinationOrigin:MTLOriginMake(0, 0, 0)];
  [blit copyFromTexture:a toTexture:b];
  [blit copyFromTexture:b sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
             sourceSize:MTLSizeMake(W, H / 2, 1) toTexture:a destinationSlice:0 destinationLevel:0
      destinationOrigin:MTLOriginMake(0, H / 2, 0)];
  [blit copyFromTexture:a sourceSlice:0 sourceLevel:0 toTexture:b destinationSlice:0 destinationLevel:0
             sliceCount:1 levelCount:1];
  [blit copyFromTexture:b sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
             sourceSize:MTLSizeMake(W, H, 1) toBuffer:out destinationOffset:0 destinationBytesPerRow:row
   destinationBytesPerImage:row * H];
  [blit copyFromBuffer:out sourceOffset:0 toBuffer:out2 destinationOffset:0 size:pattern.size()];
  [blit endEncoding];
  [cb commit];
  [cb waitUntilCompleted];
  Check(cb.status == MTLCommandBufferStatusCompleted, "command buffer completed");
  const auto* got = static_cast<const uint8_t*>(out2.contents);
  // Rows 0..H/2-1: the pattern; rows H/2..H-1: rows 0..H/2-1 copied down.
  for (NSUInteger y = 0; y < H; ++y)
    for (NSUInteger x = 0; x < row; ++x) {
      const uint8_t want = pattern[(y % (H / 2)) * row + x];
      Check(got[y * row + x] == want, "copied bytes in order");
    }
}
}  // namespace
int main() {
  @autoreleasepool {
    try {
      Run();
    } catch (const std::exception& e) {
      std::fprintf(stderr, "metal4 proxy copy: FAILED: %s (after %zu checks)\n", e.what(), checks);
      return 1;
    }
    std::printf("metal4 proxy copy: %zu checks passed\n", checks);
  }
  return 0;
}
