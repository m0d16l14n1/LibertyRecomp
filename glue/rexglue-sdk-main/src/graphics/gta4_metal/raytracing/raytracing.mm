#include "raytracing.h"
#include <rex/cvar.h>
#include <string>

REXCVAR_DEFINE_STRING(gta4_metal_raytracing, "off", "GPU",
    "Ray-traced lighting: off, ao (ambient occlusion) or shadows (sun shadows; later stage)");

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
                  uint32_t user_id) {
  instance = {};
  for (int column = 0; column < 4; ++column)
    for (int row = 0; row < 3; ++row) instance.transformationMatrix.columns[column].elements[row] = column == row ? 1.0f : 0.0f;
  instance.options = MTLAccelerationStructureInstanceOptionOpaque;
  instance.mask = 0xFF;
  instance.intersectionFunctionTableOffset = 0;
  instance.userID = user_id;
  instance.accelerationStructureID = structure.gpuResourceID;
}

bool EncodeAccelerationStructureWork(id<MTLCommandBuffer> commands, std::span<const AccelerationStructureOp> ops,
                                     std::string& error) {
  if (ops.empty()) return true;
  id<MTLAccelerationStructureCommandEncoder> encoder = [commands accelerationStructureCommandEncoder];
  if (!encoder) { error = "Metal acceleration-structure encoder unavailable"; return false; }
  encoder.label = @"Liberty ray tracing structures";
  bool ok = true;
  for (const auto& op : ops) {
    if (!op.destination || !op.scratch) { error = "acceleration-structure op without destination or scratch"; ok = false; break; }
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
                                 descriptor:PrimitiveDescriptor(op.geometry, true, op.fast_build)
                                destination:op.destination
                              scratchBuffer:op.scratch
                        scratchBufferOffset:op.scratch_offset];
        break;
      case AccelerationStructureOp::Kind::kBuildInstances:
        if (!op.instances || !op.instance_count) { error = "instance build without instances"; ok = false; break; }
        [encoder buildAccelerationStructure:op.destination
                                 descriptor:InstanceDescriptor(op.instances, op.instance_offset, op.instance_count)
                              scratchBuffer:op.scratch
                        scratchBufferOffset:op.scratch_offset];
        break;
    }
    if (!ok) break;
  }
  [encoder endEncoding];
  return ok;
}

}  // namespace rex::graphics::gta4_metal::raytracing
