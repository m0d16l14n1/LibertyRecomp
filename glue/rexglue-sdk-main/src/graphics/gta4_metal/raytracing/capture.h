#pragma once
// World-geometry capture for ray tracing: after a world draw is encoded, the
// renderer offers it here. When the cache wants this draw's positions (a new
// build or a mover's refit), Capture encodes a rasterization-disabled replay
// with the capture variant of its vertex shader into the same render encoder.
// At the ray-tracing hook, EncodeScene() encodes the frame's builds and refits
// and the instance structure through EncodeAccelerationStructureWork.
#import <Metal/Metal.h>
#include "accel_cache.h"
#include "capture_policy.h"
#include "raytracing.h"
#include <functional>
#include <memory>
#include <string>

namespace rex::graphics::gta4_metal::raytracing {

// The draw exactly as encoded (after fan/quad/restart conversion in draw.mm).
struct DrawGeometry {
  uint64_t identity = 0;  // GeometryIdentityOf(key); 0: not capturable (uncaptured buffers, UP)
  Placement placement;
  MTLPrimitiveType primitive = MTLPrimitiveTypeTriangle;
  bool indexed = false, index32 = false;
  id<MTLBuffer> indices = nil;  // CPU-mapped (captured guest index buffers and uploads both are)
  NSUInteger index_offset = 0;  // indexed: the byte offset of the draw's first index
  uint32_t first = 0;           // non-indexed: the first vertex
  uint32_t count = 0;           // indices, or vertices
  int32_t base_vertex = 0;
};

struct CaptureSettings {
  AccelBudget budget;
  uint64_t positions_bytes_per_frame = 32ull << 20;
  uint32_t frames_in_flight = 3;
};

// The pipeline that replays a world draw's vertex shader for capture: `real`
// with the capture vertex function, no fragment stage and rasterization off.
// Attachment formats and the vertex layout are kept so the render encoder
// accepts it. Compiled asynchronously; `ready` is called on a Metal thread.
void CreateCapturePipeline(id<MTLDevice> device, MTLRenderPipelineDescriptor* real, id<MTLFunction> capture_vertex,
                           void (^ready)(id<MTLRenderPipelineState> state, NSError* error));

class Capture {
 public:
  Capture();
  ~Capture();
  Capture(const Capture&) = delete;
  Capture& operator=(const Capture&) = delete;

  bool Initialize(id<MTLDevice> device, const CaptureSettings& settings, std::string& error);
  bool initialized() const;

  // Starts a frame (ending one still open). Nothing is captured until SetCamera().
  void BeginFrame();
  bool frame_open() const;
  // ClipToWorldColumns() of the camera the frame's world draws use, once it is adopted.
  void SetCamera(const std::array<float, 16>& clip_to_world_columns);
  bool has_camera() const;
  // After a world draw: encodes its capture replay when the cache asks for one.
  // `select_pipeline` binds the capture pipeline through the renderer's binding cache.
  bool Draw(id<MTLRenderCommandEncoder> render, const DrawGeometry& draw,
            const std::function<void()>& select_pipeline, std::string& error);
  // The ray-tracing hook, outside any encoder: builds/refits, then the instance
  // structure. Returns nil when the scene is empty. Trace passes must make heap()
  // and the returned structure resident (useHeap:/useResource:).
  id<MTLAccelerationStructure> EncodeScene(id<MTLCommandBuffer> commands, std::string& error);
  // Encodes once per frame: later calls return the same structure, and draws after it are
  // not captured (geometry drawn after the lighting hook stays out of the scene).
  id<MTLHeap> heap() const;
  // Ends the frame; structures evicted now are released frames_in_flight frames later.
  // Builds EncodeScene() did not encode this frame are dropped and retried.
  void EndFrame();
  void Reset();  // device loss or mode change: releases everything once the GPU is idle

  const AccelStatistics& statistics() const;
  uint64_t captured_draws() const;
  uint64_t rejected_draws() const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace rex::graphics::gta4_metal::raytracing
