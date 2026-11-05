#include "raytracing.h"
#include <rex/cvar.h>
#include "../../../ui/metal/metal4_queue.h"
#include <string>

REXCVAR_DEFINE_STRING(gta4_metal_raytracing, "off", "GPU",
    "Ray-traced lighting: off, ao (ambient occlusion) or shadows (sun shadows)");

namespace rex::graphics::gta4_metal::raytracing {

Mode ParseMode(std::string_view value) {
  if (value == "ao") return Mode::kAmbientOcclusion;
  if (value == "shadows") return Mode::kShadows;
  return Mode::kOff;
}

Mode CurrentMode() { return ParseMode(rex::cvar::GetFlagByName("gta4_metal_raytracing")); }

MTLPrimitiveAccelerationStructureDescriptor* PrimitiveDescriptor(const TriangleGeometry& geometry, bool refittable,
                                                                 bool fast_build) {
  auto* triangles = [MTLAccelerationStructureTriangleGeometryDescriptor descriptor];
  triangles.vertexBuffer = geometry.vertices;
  triangles.vertexBufferOffset = geometry.vertex_offset;
  triangles.vertexStride = kCapturedVertexStride;
  triangles.vertexFormat = MTLAttributeFormatFloat3;  // .w of each captured float4 is ignored
  triangles.indexBuffer = geometry.indices;
  triangles.indexBufferOffset = geometry.index_offset;
  triangles.indexType = MTLIndexTypeUInt32;
  triangles.triangleCount = geometry.triangle_count;
  triangles.opaque = YES;  // AO and shadows treat every captured surface as solid
  auto* descriptor = [MTLPrimitiveAccelerationStructureDescriptor descriptor];
  descriptor.geometryDescriptors = @[ triangles ];
  MTLAccelerationStructureUsage usage = MTLAccelerationStructureUsageNone;
  if (refittable) usage |= MTLAccelerationStructureUsageRefit;
  if (fast_build) usage |= MTLAccelerationStructureUsagePreferFastBuild;
  descriptor.usage = usage;
  return descriptor;
}

MTLInstanceAccelerationStructureDescriptor* InstanceDescriptor(id<MTLBuffer> instances, NSUInteger offset,
                                                               uint32_t count) {
  auto* descriptor = [MTLInstanceAccelerationStructureDescriptor descriptor];
  descriptor.instanceDescriptorType = MTLAccelerationStructureInstanceDescriptorTypeIndirect;
  descriptor.instanceDescriptorBuffer = instances;
  descriptor.instanceDescriptorBufferOffset = offset;
  descriptor.instanceDescriptorStride = sizeof(MTLIndirectAccelerationStructureInstanceDescriptor);
  descriptor.instanceCount = count;
  descriptor.usage = MTLAccelerationStructureUsagePreferFastBuild;  // rebuilt every frame
  return descriptor;
}

void FillInstance(MTLIndirectAccelerationStructureInstanceDescriptor& instance, id<MTLAccelerationStructure> structure,
                  uint32_t user_id, uint32_t mask) {
  FillInstance(instance, structure.gpuResourceID, user_id, mask);
}

void FillInstance(MTLIndirectAccelerationStructureInstanceDescriptor& instance, MTLResourceID structure,
                  uint32_t user_id, uint32_t mask) {
  instance = {};
  for (int column = 0; column < 4; ++column)
    for (int row = 0; row < 3; ++row) instance.transformationMatrix.columns[column].elements[row] = column == row ? 1.0f : 0.0f;
  instance.options = MTLAccelerationStructureInstanceOptionOpaque;
  instance.mask = mask;
  instance.intersectionFunctionTableOffset = 0;
  instance.userID = user_id;
  instance.accelerationStructureID = structure;
}

namespace {
bool EncodeOps(id<MTLAccelerationStructureCommandEncoder> encoder, std::span<const AccelerationStructureOp> ops,
               std::string& error) {
  for (const auto& op : ops) {
    if (!op.destination || !op.scratch) { error = "acceleration-structure op without destination or scratch"; return false; }
    switch (op.kind) {
      case AccelerationStructureOp::Kind::kBuildPrimitive:
        [encoder buildAccelerationStructure:op.destination
                                 descriptor:PrimitiveDescriptor(op.geometry, op.refittable, op.fast_build)
                              scratchBuffer:op.scratch
                        scratchBufferOffset:op.scratch_offset];
        break;
      case AccelerationStructureOp::Kind::kRefitPrimitive:
        // The descriptor must describe the same topology the structure was built with.
        [encoder refitAccelerationStructure:op.source ? op.source : op.destination
                                 descriptor:op.descriptor ? op.descriptor
                                                          : PrimitiveDescriptor(op.geometry, true, op.fast_build)
                                destination:op.destination
                              scratchBuffer:op.scratch
                        scratchBufferOffset:op.scratch_offset];
        break;
      case AccelerationStructureOp::Kind::kBuildInstances:
        if (!op.instances || !op.instance_count) { error = "instance build without instances"; return false; }
        [encoder buildAccelerationStructure:op.destination
                                 descriptor:InstanceDescriptor(op.instances, op.instance_offset, op.instance_count)
                              scratchBuffer:op.scratch
                        scratchBufferOffset:op.scratch_offset];
        break;
    }
  }
  return true;
}

// Metal 4: the same builds with MTL4 descriptors, which name buffers by GPU address.
MTL4BufferRange Range(id<MTLBuffer> buffer, NSUInteger offset) {
  return MTL4BufferRangeMake(buffer.gpuAddress + offset, buffer.length > offset ? buffer.length - offset : 0);
}

MTL4PrimitiveAccelerationStructureDescriptor* PrimitiveDescriptor4(const TriangleGeometry& geometry, bool refittable,
                                                                   bool fast_build) {
  auto* triangles = [MTL4AccelerationStructureTriangleGeometryDescriptor new];
  triangles.vertexBuffer = Range(geometry.vertices, geometry.vertex_offset);
  triangles.vertexStride = kCapturedVertexStride;
  triangles.vertexFormat = MTLAttributeFormatFloat3;
  triangles.indexBuffer = Range(geometry.indices, geometry.index_offset);
  triangles.indexType = MTLIndexTypeUInt32;
  triangles.triangleCount = geometry.triangle_count;
  triangles.opaque = YES;
  auto* descriptor = [MTL4PrimitiveAccelerationStructureDescriptor new];
  descriptor.geometryDescriptors = @[ triangles ];
  MTLAccelerationStructureUsage usage = MTLAccelerationStructureUsageNone;
  if (refittable) usage |= MTLAccelerationStructureUsageRefit;
  if (fast_build) usage |= MTLAccelerationStructureUsagePreferFastBuild;
  descriptor.usage = usage;
  return descriptor;
}

bool EncodeOps4(id<MTL4ComputeCommandEncoder> encoder, std::span<const AccelerationStructureOp> ops,
                std::string& error) {
  for (const auto& op : ops) {
    if (!op.destination || !op.scratch) { error = "acceleration-structure op without destination or scratch"; return false; }
    const auto scratch = Range(op.scratch, op.scratch_offset);
    switch (op.kind) {
      case AccelerationStructureOp::Kind::kBuildPrimitive:
        [encoder buildAccelerationStructure:op.destination
                                 descriptor:PrimitiveDescriptor4(op.geometry, op.refittable, op.fast_build)
                              scratchBuffer:scratch];
        break;
      case AccelerationStructureOp::Kind::kRefitPrimitive: {
        // Same topology and usage as the build (op.descriptor is the Metal 3 form of it).
        id<MTLAccelerationStructure> source = op.source ? op.source : op.destination;
        [encoder refitAccelerationStructure:source
                                 descriptor:PrimitiveDescriptor4(op.geometry, true, op.fast_build)
                                destination:op.destination == source ? nil : op.destination
                              scratchBuffer:scratch];
        break;
      }
      case AccelerationStructureOp::Kind::kBuildInstances: {
        if (!op.instances || !op.instance_count) { error = "instance build without instances"; return false; }
        auto* descriptor = [MTL4InstanceAccelerationStructureDescriptor new];
        descriptor.instanceDescriptorType = MTLAccelerationStructureInstanceDescriptorTypeIndirect;
        descriptor.instanceDescriptorBuffer = Range(op.instances, op.instance_offset);
        descriptor.instanceDescriptorStride = sizeof(MTLIndirectAccelerationStructureInstanceDescriptor);
        descriptor.instanceCount = op.instance_count;
        descriptor.usage = MTLAccelerationStructureUsagePreferFastBuild;
        [encoder buildAccelerationStructure:op.destination descriptor:descriptor scratchBuffer:scratch];
        break;
      }
    }
  }
  return true;
}

// Every buffer and structure the ops touch, for the Metal 4 residency set.
NSArray<id<MTLResource>>* OpResources(std::span<const AccelerationStructureOp> ops) {
  NSMutableArray<id<MTLResource>>* used = [NSMutableArray arrayWithCapacity:ops.size() * 3 + 1];
  for (const auto& op : ops) {
    if (op.destination) [used addObject:op.destination];
    if (op.source && op.source != op.destination) [used addObject:op.source];
    if (op.scratch) [used addObject:op.scratch];  // repeats are fine: the proxy's set deduplicates
    if (op.geometry.vertices) [used addObject:op.geometry.vertices];
    if (op.geometry.indices && op.geometry.indices != op.geometry.vertices) [used addObject:op.geometry.indices];
    if (op.instances) [used addObject:op.instances];
  }
  return used;
}
}  // namespace

bool EncodeAccelerationStructureWork(id<MTLCommandBuffer> commands, std::span<const AccelerationStructureOp> ops,
                                     std::string& error, id<MTLHeap> resident_heap) {
  if (ops.empty()) return true;
  if (rex::ui::metal::IsMetal4(commands)) {
    // Natively on the proxy's MTL4 command buffer: no side-queue hop and its two event waits.
    __block bool ok = false;
    std::string* failure = &error;
    const auto* first = ops.data();
    const size_t count = ops.size();
    if (!rex::ui::metal::EncodeMetal4Compute(commands, OpResources(ops), resident_heap,
            ^(id<MTL4ComputeCommandEncoder> encoder) { ok = EncodeOps4(encoder, std::span(first, count), *failure); },
            @"Liberty ray tracing structures")) {
      error = "Metal 4 acceleration-structure encoder unavailable";
      return false;
    }
    return ok;
  }
  // A Metal 3 `commands`: EncodeMetal3 runs the block on it before it returns, so the block
  // may use `ops` and write `error` through a pointer.
  __block bool ok = false;
  std::string* failure = &error;
  const auto* first = ops.data();
  const size_t count = ops.size();
  rex::ui::metal::EncodeMetal3(commands, ^(id<MTLCommandBuffer> metal3) {
    id<MTLAccelerationStructureCommandEncoder> encoder = [metal3 accelerationStructureCommandEncoder];
    if (!encoder) { *failure = "Metal acceleration-structure encoder unavailable"; return; }
    encoder.label = @"Liberty ray tracing structures";
    if (resident_heap) [encoder useHeap:resident_heap];
    ok = EncodeOps(encoder, std::span(first, count), *failure);
    [encoder endEncoding];
  });
  return ok;
}

}  // namespace rex::graphics::gta4_metal::raytracing
