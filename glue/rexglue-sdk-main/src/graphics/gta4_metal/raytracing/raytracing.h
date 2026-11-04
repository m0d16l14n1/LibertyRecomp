#pragma once
// Ray-traced AO (and later sun shadows) for the GTA IV Metal renderer.
// Design: docs/RAYTRACING.md. Stage 1 here: the public types, the one entry
// point for every acceleration-structure build/refit, and the cvar. The frame
// hook and capture call site follow once the G-buffer layout is confirmed.
#import <Metal/Metal.h>
#include <simd/simd.h>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>

namespace rex::graphics::gta4_metal::raytracing {

// gta4_metal_raytracing = off | shadows | ao
enum class Mode : uint8_t { kOff, kShadows, kAmbientOcclusion };
Mode ParseMode(std::string_view value);  // anything unrecognised is kOff
Mode CurrentMode();                      // the cvar, read once per frame by the caller

// Must match RtaoParams in shaders/rtao.metal.
struct RtaoParams {
  simd_float4x4 clip_to_world;           // world = M * (ndc.xy, device depth, 1), unjittered
  simd_float4x4 previous_world_to_clip;
  simd_float4 camera_position;
  simd_uint2 input_size, trace_size;
  float radius = 2.0f, strength = 0.85f, history_blend_minimum = 0.08f, depth_rejection = 0.05f;
  uint32_t frame = 0, normal_mode = 0, reversed_depth = 0, valid_history = 0;
};
static_assert(sizeof(RtaoParams) == 192 && offsetof(RtaoParams, input_size) == 144 &&
              offsetof(RtaoParams, radius) == 160 && offsetof(RtaoParams, frame) == 176);

// Must match LibertyCaptureDraw in tools/metal/raytracing_capture_variants.py.
struct CaptureDraw {
  simd_float4x4 clip_to_world;
  uint32_t first_vertex = 0, vertex_count = 0, flags = 0, padding = 0;
};
static_assert(sizeof(CaptureDraw) == 80);
inline constexpr NSUInteger kCaptureDrawBuffer = 6, kCapturePositionsBuffer = 7;
inline constexpr NSUInteger kCapturedVertexStride = 16;  // float4 per vertex, w = 1; NaN = unplaced

// Triangles for a primitive structure: captured world positions plus the draw's
// 32-bit triangle-list indices (strips are converted before this).
struct TriangleGeometry {
  id<MTLBuffer> vertices = nil;
  NSUInteger vertex_offset = 0, vertex_count = 0;
  id<MTLBuffer> indices = nil;
  NSUInteger index_offset = 0;
  uint32_t triangle_count = 0;
};

// One acceleration-structure command. Every build and refit in this module goes
// through EncodeAccelerationStructureWork, so a Metal 4 backend can route the list
// to MTL4ComputeCommandEncoder (or a Metal 3 side queue) without touching callers.
struct AccelerationStructureOp {
  enum class Kind : uint8_t { kBuildPrimitive, kRefitPrimitive, kBuildInstances };
  Kind kind = Kind::kBuildPrimitive;
  id<MTLAccelerationStructure> destination = nil;
  id<MTLAccelerationStructure> source = nil;  // refit: the structure refit (may equal destination)
  id<MTLBuffer> scratch = nil;
  NSUInteger scratch_offset = 0;
  TriangleGeometry geometry;  // primitive ops
  bool refittable = true;     // primitive builds: allow later refits
  bool fast_build = false;    // primitive builds: movers trade trace speed for build speed
  // kBuildInstances: MTLIndirectAccelerationStructureInstanceDescriptor array. Instances
  // name their structures by gpuResourceID, so no structure array travels with the op.
  id<MTLBuffer> instances = nil;
  NSUInteger instance_offset = 0;
  uint32_t instance_count = 0;
};

// Metal 3 implementation: one MTLAccelerationStructureCommandEncoder for the whole list.
bool EncodeAccelerationStructureWork(id<MTLCommandBuffer> commands, std::span<const AccelerationStructureOp> ops,
                                     std::string& error);

// Descriptors the ops above use, for size queries (accelerationStructureSizesWithDescriptor).
MTLPrimitiveAccelerationStructureDescriptor* PrimitiveDescriptor(const TriangleGeometry& geometry, bool refittable,
                                                                 bool fast_build);
MTLInstanceAccelerationStructureDescriptor* InstanceDescriptor(id<MTLBuffer> instances, NSUInteger offset,
                                                               uint32_t count);
// An identity-transform, opaque instance of `structure` (captured positions are world space).
void FillInstance(MTLIndirectAccelerationStructureInstanceDescriptor& instance, id<MTLAccelerationStructure> structure,
                  uint32_t user_id);

}  // namespace rex::graphics::gta4_metal::raytracing
