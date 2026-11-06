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

  // Narrower barriers: copies of unrelated resources need no encoder barrier, while a copy that
  // touches what an earlier copy read or wrote still needs one. The queue counts both
  // (copy_barriers/copy_independent) and the proxy reports them in gta4-metal4.
  constexpr NSUInteger kIndependent = 8, kCopyBytes = 256;
  std::vector<id<MTLBuffer>> independent_sources, independent_targets;
  for (NSUInteger i = 0; i < kIndependent; ++i) {
    std::vector<uint8_t> value(kCopyBytes, uint8_t(i * 31 + 1));
    independent_sources.push_back([device newBufferWithBytes:value.data() length:value.size()
                                                     options:MTLResourceStorageModeShared]);
    independent_targets.push_back([device newBufferWithLength:value.size() options:MTLResourceStorageModeShared]);
    Check(independent_sources.back() && independent_targets.back(), "independent buffers");
  }
  auto before = rex::ui::metal::Metal4StatisticsOf(queue);
  id<MTLCommandBuffer> copies = [queue commandBuffer];
  id<MTLBlitCommandEncoder> independent = [copies blitCommandEncoder];
  for (NSUInteger i = 0; i < kIndependent; ++i)
    [independent copyFromBuffer:independent_sources[i] sourceOffset:0 toBuffer:independent_targets[i]
              destinationOffset:0 size:kCopyBytes];
  [independent endEncoding];
  auto after = rex::ui::metal::Metal4StatisticsOf(queue);
  Check(after.barriers - before.barriers == 1, "independent copies: only the encoder's queue barrier");
  Check(after.copy_barriers == before.copy_barriers, "independent copies take no encoder barrier");
  Check(after.copy_independent - before.copy_independent == kIndependent, "independent copies counted");

  // Write, read, write, read through one texture: each later copy conflicts with the one before.
  std::vector<uint8_t> second_pattern(pattern.size(), 0xA5);
  id<MTLBuffer> first = [device newBufferWithBytes:pattern.data() length:pattern.size()
                                           options:MTLResourceStorageModeShared];
  id<MTLBuffer> second = [device newBufferWithBytes:second_pattern.data() length:second_pattern.size()
                                            options:MTLResourceStorageModeShared];
  id<MTLBuffer> read_back_first = [device newBufferWithLength:pattern.size() options:MTLResourceStorageModeShared];
  id<MTLBuffer> read_back_second = [device newBufferWithLength:pattern.size() options:MTLResourceStorageModeShared];
  before = rex::ui::metal::Metal4StatisticsOf(queue);
  id<MTLBlitCommandEncoder> conflicts = [copies blitCommandEncoder];
  [conflicts copyFromBuffer:first sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:row * H
                 sourceSize:MTLSizeMake(W, H, 1) toTexture:a destinationSlice:0 destinationLevel:0
         destinationOrigin:MTLOriginMake(0, 0, 0)];
  [conflicts copyFromTexture:a sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                 sourceSize:MTLSizeMake(W, H, 1) toBuffer:read_back_first destinationOffset:0
       destinationBytesPerRow:row destinationBytesPerImage:row * H];
  [conflicts copyFromBuffer:second sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:row * H
                 sourceSize:MTLSizeMake(W, H, 1) toTexture:a destinationSlice:0 destinationLevel:0
         destinationOrigin:MTLOriginMake(0, 0, 0)];
  [conflicts copyFromTexture:a sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                 sourceSize:MTLSizeMake(W, H, 1) toBuffer:read_back_second destinationOffset:0
       destinationBytesPerRow:row destinationBytesPerImage:row * H];
  [conflicts endEncoding];
  after = rex::ui::metal::Metal4StatisticsOf(queue);
  Check(after.copy_barriers - before.copy_barriers == 3, "write/read chain barriers");
  Check(after.copy_independent - before.copy_independent == 1, "first copy of the chain is free");
  Check(after.copy_merged - before.copy_merged == 1, "the second blit encoder continues the first");
  Check(after.encoders == before.encoders, "a merged blit encoder opens no MTL4 encoder");

  // Across blit encoders: the second reads what the first wrote, so the shared MTL4 encoder
  // still barriers between them (Metal 3 orders separate encoders).
  id<MTLBuffer> hop_a = [device newBufferWithLength:pattern.size() options:MTLResourceStorageModeShared];
  id<MTLBuffer> hop_b = [device newBufferWithLength:pattern.size() options:MTLResourceStorageModeShared];
  before = rex::ui::metal::Metal4StatisticsOf(queue);
  id<MTLBlitCommandEncoder> write = [copies blitCommandEncoder];
  [write copyFromBuffer:source sourceOffset:0 toBuffer:hop_a destinationOffset:0 size:pattern.size()];
  [write endEncoding];
  id<MTLBlitCommandEncoder> read = [copies blitCommandEncoder];
  [read copyFromBuffer:hop_a sourceOffset:0 toBuffer:hop_b destinationOffset:0 size:pattern.size()];
  [read endEncoding];
  after = rex::ui::metal::Metal4StatisticsOf(queue);
  Check(after.copy_merged - before.copy_merged == 2, "consecutive blit encoders merge");
  Check(after.copy_barriers - before.copy_barriers == 1, "a dependency across merged encoders barriers");
  [copies commit];
  [copies waitUntilCompleted];
  Check(copies.status == MTLCommandBufferStatusCompleted, "copy command buffer completed");
  for (NSUInteger i = 0; i < kIndependent; ++i) {
    const auto* data = static_cast<const uint8_t*>(independent_targets[i].contents);
    for (NSUInteger j = 0; j < kCopyBytes; ++j)
      Check(data[j] == uint8_t(i * 31 + 1), "independent copy bytes");
  }
  const auto* read_first = static_cast<const uint8_t*>(read_back_first.contents);
  const auto* read_second = static_cast<const uint8_t*>(read_back_second.contents);
  for (NSUInteger i = 0; i < pattern.size(); ++i) {
    Check(read_first[i] == pattern[i], "read after write through a texture");
    Check(read_second[i] == second_pattern[i], "read after the second write through a texture");
  }
  const auto* hop = static_cast<const uint8_t*>(hop_b.contents);
  for (NSUInteger i = 0; i < pattern.size(); ++i) Check(hop[i] == pattern[i], "copy chain across merged encoders");
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
