#pragma once
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <cstdint>
#include <string>

namespace rex::ui::metal {

// Metal 4 command model behind the Metal 3 protocols (gta4_metal_api = metal4).
//
// NewMetal4Queue returns an object that conforms to MTLCommandQueue. Its command
// buffers conform to MTLCommandBuffer and their encoders to MTLRenderCommandEncoder,
// MTLBlitCommandEncoder and MTLComputeCommandEncoder, so the renderer encodes as
// before. Underneath:
//  - MTL4CommandQueue, MTL4CommandBuffer and pooled MTL4CommandAllocators;
//  - bindings go to MTL4ArgumentTables (GPU addresses and resource IDs);
//    set*Bytes copies into a per-command-buffer transient buffer;
//  - every bound or declared resource joins the command buffer's residency set (or, with
//    gta4_metal4_residency = persistent, one queue-level set) and is retained until the GPU
//    completes it (MTL4 command buffers retain nothing);
//  - blits run on an MTL4ComputeCommandEncoder;
//  - hazards: a queue barrier (all stages, device visibility) at the start of every
//    encoder and an encoder barrier between copies and between dispatches. That is at
//    least as strict as Metal 3 tracking of the same passes;
//  - completion handlers run from MTL4 commit feedback; encodeWait/SignalEvent and
//    presentDrawable become queue waits/signals around the commit.
// Returns nil (with `error`) when the device has no Metal 4 support.
id<MTLCommandQueue> NewMetal4Queue(id<MTLDevice> device, std::string& error);
bool IsMetal4(id<MTLCommandQueue> queue);
bool IsMetal4(id<MTLCommandBuffer> commands);

// Encodes `body` into a real Metal 3 command buffer that runs at this point of
// `commands`: on a Metal 4 proxy the work encoded so far is committed, a Metal 3
// side queue runs `body`, and what follows waits for it (MTLEvent). For APIs that
// need a Metal 3 command buffer (MetalFX MTLFX*). On a Metal 3 buffer `body` runs
// on `commands` itself. No encoder may be open on `commands`.
void EncodeMetal3(id<MTLCommandBuffer> commands, void (^body)(id<MTLCommandBuffer>));

// Encodes Metal 4 native work (MTL4FX) into the open MTL4 command buffer of a proxy
// `commands`. `resources` join its residency set. An empty encoder first waits for all
// earlier queue work and then updates `fence`, which the MetalFX object waits for (set it
// as the object's fence); the next proxy encoder's queue barrier orders what follows.
// No encoder may be open on `commands`. Returns false on a Metal 3 buffer.
bool EncodeMetal4(id<MTLCommandBuffer> commands, id<MTLFence> fence, NSArray<id<MTLResource>>* resources,
                  void (^body)(id<MTL4CommandBuffer>), NSString* label = nil);  // label: gta4_metal4_pass_timing
// Opens a compute encoder on the open MTL4 command buffer of a proxy `commands` for MTL4-only
// commands (acceleration-structure builds), after a queue barrier on all earlier work; `body`
// encodes into it and the proxy ends it. `resources` and `heap` join the residency set. No
// encoder may be open on `commands`. Returns false on a Metal 3 buffer or without an encoder.
bool EncodeMetal4Compute(id<MTLCommandBuffer> commands, NSArray<id<MTLResource>>* resources, id<MTLHeap> heap,
                         void (^body)(id<MTL4ComputeCommandEncoder>), NSString* label = nil);
// One MTL4Compiler per Metal 4 queue (nil on Metal 3), for MTL4FX objects.
id<MTL4Compiler> Metal4Compiler(id<MTLCommandQueue> queue);

// Drawables of `layer` become resident on a Metal 4 queue (no-op on Metal 3).
void AddLayerResidency(id<MTLCommandQueue> queue, CAMetalLayer* layer);

struct Metal4Statistics {
  uint64_t command_buffers = 0, parts = 0, encoders = 0, barriers = 0;
  uint64_t transient_bytes = 0, resident = 0, metal3_hops = 0;
  uint64_t binds = 0, bind_hits = 0;                    // buffer/texture binds, and those the bind cache served
  uint64_t fragment_barriers = 0, vertex_barriers = 0;  // render barriers before fragment only; in-pass vertex waits
  uint64_t copy_barriers = 0, copy_independent = 0;     // copy encoder barriers, and copies that needed none
  uint64_t evicted = 0, residency_commits = 0;          // gta4_metal4_residency
};
// Cumulative counters of a Metal 4 queue (zero on Metal 3).
Metal4Statistics Metal4StatisticsOf(id<MTLCommandQueue> queue);

}  // namespace rex::ui::metal
