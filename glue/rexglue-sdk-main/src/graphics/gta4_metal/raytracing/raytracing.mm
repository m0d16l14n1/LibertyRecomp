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
}  // namespace

bool EncodeAccelerationStructureWork(id<MTLCommandBuffer> commands, std::span<const AccelerationStructureOp> ops,
                                     std::string& error, id<MTLHeap> resident_heap) {
  if (ops.empty()) return true;
  // EncodeMetal3 runs the block before it returns (on `commands`, or on a hop), so the
  // block may use `ops` and write `error` through a pointer.
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
