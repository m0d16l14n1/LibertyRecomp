// Acceleration-structure work through EncodeAccelerationStructureWork on a Metal 3 queue and
// on the Metal 4 proxy (native MTL4 compute encoder, no Metal 3 hop): primitive builds into a
// heap, the indirect instance build, rays traced in the same command buffer, then a refit
// after the geometry moves.
#include "graphics/gta4_metal/raytracing/raytracing.h"
#include "ui/metal/metal4_queue.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>
namespace rt = rex::graphics::gta4_metal::raytracing;
namespace {
size_t checks = 0;
void Check(bool x, const char* s) {
  ++checks;
  if (!x) throw std::runtime_error(s);
}
constexpr uint32_t kRays = 64;
NSString* const kKernel = @R"(
#include <metal_stdlib>
using namespace metal;
using namespace raytracing;
kernel void trace(instance_acceleration_structure scene [[buffer(0)]], device float* out [[buffer(1)]],
                  uint id [[thread_position_in_grid]]) {
  ray r(float3(-1.5f + 3.0f * (float(id) + 0.5f) / 64.0f, 0.1f, 0.0f), float3(0, 0, 1), 0.0f, 100.0f);
  intersector<instancing, triangle_data> i;
  auto hit = i.intersect(r, scene);
  out[id] = hit.type == intersection_type::none ? -1.0f : hit.distance + 10.0f * float(hit.instance_id);
}
)";
// Quad over x in [x0, x1], y in [-1, 1] at depth z: 4 float4 vertices, 2 triangles.
void Quad(float* v, float x0, float x1, float z) {
  const float p[4][2] = {{x0, -1}, {x1, -1}, {x1, 1}, {x0, 1}};
  for (int i = 0; i < 4; ++i) { v[i * 4] = p[i][0]; v[i * 4 + 1] = p[i][1]; v[i * 4 + 2] = z; v[i * 4 + 3] = 1; }
}
float Expected(uint32_t id, float za, float zb) {
  const float x = -1.5f + 3.0f * (float(id) + 0.5f) / 64.0f;
  if (x >= -1 && x < 0) return za;
  if (x > 0 && x <= 1) return zb + 10;
  return -1;
}
struct Fixture {
  id<MTLDevice> device;
  id<MTLComputePipelineState> pipeline;
  id<MTLHeap> heap;
  id<MTLBuffer> vertices, indices, scratch, instances, out;
  id<MTLAccelerationStructure> blas[2], scene;
  NSUInteger build_scratch = 0, refit_scratch = 0, scene_scratch = 0;
  rt::TriangleGeometry Geometry(int i) const { return {vertices, NSUInteger(i) * 64, 4, indices, 0, 2}; }
};
void Setup(Fixture& f, id<MTLDevice> device) {
  f.device = device;
  NSError* e = nil;
  id<MTLLibrary> library = [device newLibraryWithSource:kKernel options:nil error:&e];
  Check(library != nil, "kernel compiles");
  f.pipeline = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"trace"] error:&e];
  Check(f.pipeline != nil, "pipeline");
  f.vertices = [device newBufferWithLength:128 options:MTLResourceStorageModeShared];
  const uint32_t idx[6] = {0, 1, 2, 0, 2, 3};
  f.indices = [device newBufferWithBytes:idx length:sizeof(idx) options:MTLResourceStorageModeShared];
  Quad(static_cast<float*>(f.vertices.contents), -1, 0, 2);
  Quad(static_cast<float*>(f.vertices.contents) + 16, 0, 1, 3);
  const auto sizes = [device accelerationStructureSizesWithDescriptor:rt::PrimitiveDescriptor(f.Geometry(0), true, false)];
  const auto placement = [device heapAccelerationStructureSizeAndAlignWithSize:sizes.accelerationStructureSize];
  MTLHeapDescriptor* h = [MTLHeapDescriptor new];
  h.size = (placement.size + placement.align) * 2;
  h.storageMode = MTLStorageModePrivate;
  f.heap = [device newHeapWithDescriptor:h];
  Check(f.heap != nil, "heap");
  for (auto& b : f.blas) { b = [f.heap newAccelerationStructureWithSize:sizes.accelerationStructureSize]; Check(b != nil, "blas"); }
  const auto scene_sizes = [device accelerationStructureSizesWithDescriptor:rt::InstanceDescriptor(nil, 0, 2)];
  f.scene = [device newAccelerationStructureWithSize:scene_sizes.accelerationStructureSize];
  f.build_scratch = (sizes.buildScratchBufferSize + 255) & ~NSUInteger(255);
  f.refit_scratch = (sizes.refitScratchBufferSize + 255) & ~NSUInteger(255);
  f.scene_scratch = f.build_scratch * 2;
  f.scratch = [device newBufferWithLength:f.scene_scratch + scene_sizes.buildScratchBufferSize + 256
                                  options:MTLResourceStorageModePrivate];
  f.instances = [device newBufferWithLength:2 * sizeof(MTLIndirectAccelerationStructureInstanceDescriptor)
                                    options:MTLResourceStorageModeShared];
  auto* inst = static_cast<MTLIndirectAccelerationStructureInstanceDescriptor*>(f.instances.contents);
  for (int i = 0; i < 2; ++i) rt::FillInstance(inst[i], f.blas[i], uint32_t(i), 0xFF);
  f.out = [device newBufferWithLength:kRays * sizeof(float) options:MTLResourceStorageModeShared];
}
void Trace(Fixture& f, id<MTLCommandBuffer> cb) {
  id<MTLComputeCommandEncoder> c = [cb computeCommandEncoder];
  [c setComputePipelineState:f.pipeline];
  [c setAccelerationStructure:f.scene atBufferIndex:0];
  [c setBuffer:f.out offset:0 atIndex:1];
  [c useHeap:f.heap];
  [c dispatchThreads:MTLSizeMake(kRays, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
  [c endEncoding];
}
void Scene(Fixture& f, id<MTLCommandBuffer> cb) {
  rt::AccelerationStructureOp op;
  op.kind = rt::AccelerationStructureOp::Kind::kBuildInstances;
  op.destination = f.scene; op.scratch = f.scratch; op.scratch_offset = f.scene_scratch;
  op.instances = f.instances; op.instance_count = 2;
  std::string error;
  Check(rt::EncodeAccelerationStructureWork(cb, std::span(&op, 1), error, f.heap) && error.empty(), "scene build");
}
void Verify(Fixture& f, float za, float zb, const char* what) {
  const float* got = static_cast<const float*>(f.out.contents);
  for (uint32_t i = 0; i < kRays; ++i) {
    const float want = Expected(i, za, zb);
    const float x = -1.5f + 3.0f * (float(i) + 0.5f) / 64.0f;
    if (std::fabs(x) < 0.05f || std::fabs(std::fabs(x) - 1) < 0.05f) continue;  // quad edges
    Check(std::fabs(got[i] - want) < 1e-3f, what);
  }
}
void RunOn(id<MTLDevice> device, id<MTLCommandQueue> queue, const char* name) {
  Fixture f;
  Setup(f, device);
  std::string error;
  // Frame 1: build both, build the scene, trace; one command buffer.
  id<MTLCommandBuffer> cb = [queue commandBuffer];
  std::vector<rt::AccelerationStructureOp> ops(2);
  for (int i = 0; i < 2; ++i) {
    ops[i].kind = rt::AccelerationStructureOp::Kind::kBuildPrimitive;
    ops[i].destination = f.blas[i]; ops[i].scratch = f.scratch; ops[i].scratch_offset = f.build_scratch * i;
    ops[i].geometry = f.Geometry(i);
  }
  Check(rt::EncodeAccelerationStructureWork(cb, ops, error, f.heap) && error.empty(), "primitive builds");
  Scene(f, cb);
  Trace(f, cb);
  [cb commit];
  [cb waitUntilCompleted];
  Check(cb.status == MTLCommandBufferStatusCompleted, "frame 1 completed");
  Verify(f, 2, 3, "frame 1 distances");
  // Frame 2: quad 0 moves to z = 4; refit it in place, rebuild the scene, trace.
  Quad(static_cast<float*>(f.vertices.contents), -1, 0, 4);
  cb = [queue commandBuffer];
  rt::AccelerationStructureOp refit;
  refit.kind = rt::AccelerationStructureOp::Kind::kRefitPrimitive;
  refit.destination = refit.source = f.blas[0];
  refit.scratch = f.scratch; refit.scratch_offset = 0;
  refit.geometry = f.Geometry(0);
  auto* d = rt::PrimitiveDescriptor(f.Geometry(0), true, false);
  refit.descriptor = d;
  Check(rt::EncodeAccelerationStructureWork(cb, std::span(&refit, 1), error, f.heap) && error.empty(), "refit");
  Scene(f, cb);
  Trace(f, cb);
  [cb commit];
  [cb waitUntilCompleted];
  Check(cb.status == MTLCommandBufferStatusCompleted, "frame 2 completed");
  Verify(f, 4, 3, "frame 2 distances after refit");
  std::printf("%s: built, traced, refit\n", name);
}
void Run() {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  Check(device != nil && device.supportsRaytracing, "ray-tracing device");
  RunOn(device, [device newCommandQueue], "metal3");
  std::string error;
  id<MTLCommandQueue> queue4 = rex::ui::metal::NewMetal4Queue(device, error);
  if (!queue4) { std::printf("metal4: skipped (%s)\n", error.c_str()); return; }
  RunOn(device, queue4, "metal4");
  const auto stats = rex::ui::metal::Metal4StatisticsOf(queue4);
  Check(stats.metal3_hops == 0, "no Metal 3 hops on the proxy");
}
}  // namespace
int main() {
  @autoreleasepool {
    try {
      Run();
    } catch (const std::exception& e) {
      std::fprintf(stderr, "metal ray-tracing structures: FAILED: %s (after %zu checks)\n", e.what(), checks);
      return 1;
    }
    std::printf("metal ray-tracing structures: %zu checks passed\n", checks);
  }
  return 0;
}
