#include "capture.h"
#include "shadow_policy.h"
#include <algorithm>
#include <array>
#include <cstring>
#include <optional>
#include <deque>
#include <unordered_set>
#include <vector>

namespace rex::graphics::gta4_metal::raytracing {
namespace {
struct Blas {
  id<MTLAccelerationStructure> structure = nil;
  id<MTLBuffer> indices = nil;  // persistent relative triangle list
  uint32_t first_vertex = 0, vertex_count = 0, triangle_count = 0;
  NSUInteger refit_scratch = 0;
  MTLResourceID resource_id{};  // structure.gpuResourceID, read once at the build
  MTLPrimitiveAccelerationStructureDescriptor* refit_descriptor = nil;  // re-pointed at each refit's positions
  uint32_t mask = kInstanceMaskOpaque;  // InstanceMaskOf(alpha tested), fixed at the build
};
NSUInteger AlignUp(NSUInteger value, NSUInteger alignment) { return (value + alignment - 1) / alignment * alignment; }
}  // namespace

void CreateCapturePipeline(id<MTLDevice> device, MTLRenderPipelineDescriptor* real, id<MTLFunction> capture_vertex,
                           void (^ready)(id<MTLRenderPipelineState>, NSError*)) {
  MTLRenderPipelineDescriptor* descriptor = [real copy];
  descriptor.vertexFunction = capture_vertex;
  descriptor.fragmentFunction = nil;
  descriptor.rasterizationEnabled = NO;
  descriptor.binaryArchives = nil;  // capture pipelines are not part of the shipped pipeline seed
  descriptor.alphaToCoverageEnabled = NO;
  for (NSUInteger i = 0; i < 8; ++i) {
    descriptor.colorAttachments[i].writeMask = MTLColorWriteMaskNone;
    descriptor.colorAttachments[i].blendingEnabled = NO;
  }
  descriptor.label = [NSString stringWithFormat:@"Liberty capture %@", real.label ?: @""];
  [device newRenderPipelineStateWithDescriptor:descriptor completionHandler:ready];
}

struct Capture::Impl {
  id<MTLDevice> device = nil;
  CaptureSettings settings;
  AccelCache<Blas> cache;
  id<MTLHeap> heap = nil;
  struct FrameSlot {
    id<MTLBuffer> positions = nil;  // private: written by capture draws, read by builds
    NSUInteger positions_used = 0;
    id<MTLBuffer> scratch = nil;
    id<MTLBuffer> instances = nil;
    id<MTLAccelerationStructure> scene = nil;
  };
  std::vector<FrameSlot> slots;
  FrameSlot* slot = nullptr;
  uint64_t frame = 0;
  bool frame_open = false, frame_active = false;  // active: open, with a camera
  id<MTLAccelerationStructure> encoded = nil;      // this frame's scene, once EncodeScene ran
  std::array<float, 16> clip_to_world{};
  struct Pending {
    AccelerationStructureOp op;
    NSUInteger scratch_size = 0;
    AccelCache<Blas>::Slot* built = nullptr;  // a build: abandoned if the frame never encodes it
  };
  std::vector<Pending> pending;
  std::deque<std::pair<uint64_t, Blas>> retiring;  // released once the GPU cannot use them
  std::unordered_set<uint64_t> rejected;            // identities that cannot be captured
  uint64_t captured = 0, rejected_draws = 0;
  CpuTime draw_time, scene_time;
  // The instance structure's sizes for instance counts up to scene_sizes_count (rounded up, so
  // the query runs when the scene grows past a 256 boundary, not every frame).
  MTLAccelerationStructureSizes scene_sizes{};
  NSUInteger scene_sizes_count = 0;

  NSUInteger AllocatePositions(uint32_t vertices) {
    // Packed (16-byte float4s): no gaps, so the whole used range is captured positions.
    const NSUInteger size = NSUInteger(vertices) * kCapturedVertexStride;
    if (slot->positions_used + size > slot->positions.length) return NSNotFound;
    const NSUInteger offset = slot->positions_used;
    slot->positions_used += size;
    return offset;
  }
  void Retire(Blas& blas) {
    if (blas.structure || blas.indices) retiring.emplace_back(frame, std::move(blas));
    blas = {};
  }
};

Capture::Capture() : impl_(std::make_unique<Impl>()) {}
Capture::~Capture() = default;

bool Capture::Initialize(id<MTLDevice> device, const CaptureSettings& settings, std::string& error) {
  auto& s = *impl_;
  if (![device supportsRaytracing]) { error = "Metal device does not support ray tracing"; return false; }
  s.device = device;
  s.settings = settings;
  s.cache.set_budget(settings.budget);
  auto* heap = [MTLHeapDescriptor new];
  heap.storageMode = MTLStorageModePrivate;
  heap.hazardTrackingMode = MTLHazardTrackingModeTracked;  // trace passes wait for this frame's builds
  heap.size = NSUInteger(settings.budget.total_bytes);
  s.heap = [device newHeapWithDescriptor:heap];
  if (!s.heap) { error = "ray-tracing structure heap allocation failed"; return false; }
  s.heap.label = @"Liberty ray tracing structures";
  s.slots.resize(std::max(settings.frames_in_flight, 1u) + 1);
  for (auto& slot : s.slots) {
    slot.positions = [device newBufferWithLength:NSUInteger(settings.positions_bytes_per_frame)
                                         options:MTLResourceStorageModePrivate];
    if (!slot.positions) { error = "ray-tracing capture buffer allocation failed"; return false; }
    slot.positions.label = @"Liberty captured positions";
  }
  return true;
}

bool Capture::initialized() const { return impl_->heap != nil; }
id<MTLHeap> Capture::heap() const { return impl_->heap; }
const AccelStatistics& Capture::statistics() const { return impl_->cache.statistics(); }
uint64_t Capture::captured_draws() const { return impl_->captured; }
uint64_t Capture::rejected_draws() const { return impl_->rejected_draws; }
const CpuTime& Capture::draw_time() const { return impl_->draw_time; }
const CpuTime& Capture::scene_time() const { return impl_->scene_time; }

void Capture::BeginFrame() {
  auto& s = *impl_;
  if (s.frame_open) EndFrame();
  if (!s.heap) return;
  ++s.frame;
  s.frame_open = true;
  s.frame_active = false;
  s.encoded = nil;
  s.slot = &s.slots[s.frame % s.slots.size()];
  s.slot->positions_used = 0;
  s.pending.clear();
  s.cache.BeginFrame(s.frame);
}
bool Capture::frame_open() const { return impl_->frame_open; }
void Capture::SetCamera(const std::array<float, 16>& clip_to_world_columns) {
  auto& s = *impl_;
  if (!s.frame_open) return;
  s.clip_to_world = clip_to_world_columns;
  s.frame_active = true;
}
bool Capture::has_camera() const { return impl_->frame_active; }
id<MTLBuffer> Capture::positions(NSUInteger& vertices) const {
  const auto& s = *impl_;
  vertices = s.slot ? s.slot->positions_used / kCapturedVertexStride : 0;
  return s.slot ? s.slot->positions : nil;
}

bool Capture::Draw(id<MTLRenderCommandEncoder> render, const DrawGeometry& draw,
                   const std::function<void()>& select_pipeline, std::string& error) {
  auto& s = *impl_;
  ScopedCpuTime timed(s.draw_time);
  // After EncodeScene the frame's structures are encoded: later draws (forward geometry after
  // the lighting) are left out of the scene.
  if (!s.frame_active || s.encoded || !draw.identity || !draw.count) return true;
  Topology topology;
  if (draw.primitive == MTLPrimitiveTypeTriangle) topology = Topology::kList;
  else if (draw.primitive == MTLPrimitiveTypeTriangleStrip) topology = Topology::kStrip;
  else return true;  // points and lines carry no surfaces
  if (s.rejected.count(draw.identity)) return true;
  const auto decision = s.cache.Request({CacheIdentityOf(draw.identity, topology, draw.count),
                                        draw.placement.motion, draw.placement.dynamic});
  if (decision.action == CaptureAction::kReuse || decision.action == CaptureAction::kSkip) return true;
  auto& slot = *decision.slot;
  const auto reject = [&] {
    ++s.rejected_draws;
    s.rejected.insert(draw.identity);
    s.cache.Abandon(slot);
    return true;
  };

  Blas blas;
  if (decision.action == CaptureAction::kBuild) {
    std::optional<TriangleList> list;
    if (draw.indexed) {
      const auto* bytes = static_cast<const uint8_t*>(draw.indices.contents);
      const NSUInteger element = draw.index32 ? 4 : 2;
      if (!bytes || draw.index_offset + NSUInteger(draw.count) * element > draw.indices.length) return reject();
      const uint8_t* base = bytes + draw.index_offset;
      const auto read = [&](uint32_t i) -> uint32_t {
        if (draw.index32) { uint32_t v; std::memcpy(&v, base + size_t(i) * 4, 4); return v; }
        uint16_t v; std::memcpy(&v, base + size_t(i) * 2, 2); return v;
      };
      // Metal restarts strips at the all-ones index of the index type, as draw.mm relies on.
      const uint32_t restart = draw.index32 ? UINT32_MAX : 0xFFFFu;
      list = BuildTriangleList(topology, draw.count, read, draw.base_vertex, topology == Topology::kStrip
                                                                              ? std::optional<uint32_t>(restart) : std::nullopt);
    } else {
      list = BuildTriangleList(topology, draw.count, [&](uint32_t i) { return draw.first + i; }, 0, std::nullopt);
    }
    if (!list || list->indices.empty()) return reject();
    blas.first_vertex = list->first_vertex;
    blas.vertex_count = list->vertex_count;
    blas.triangle_count = uint32_t(list->indices.size() / 3);
    blas.mask = InstanceMaskOf(draw.alpha_tested);
    blas.indices = [s.device newBufferWithBytes:list->indices.data() length:list->indices.size() * sizeof(uint32_t)
                                        options:MTLResourceStorageModeShared | MTLResourceHazardTrackingModeUntracked];
    if (!blas.indices) { s.cache.Abandon(slot); return true; }
  } else {
    blas = slot.payload;  // a refit keeps the stored topology
  }

  const NSUInteger positions = s.AllocatePositions(blas.vertex_count);
  if (positions == NSNotFound) {
    // Out of capture space this frame: a build waits for the next one; a mover stays as it was.
    if (decision.action == CaptureAction::kBuild) s.cache.Abandon(slot);
    return true;
  }
  TriangleGeometry geometry{s.slot->positions, positions, blas.vertex_count, blas.indices, 0, blas.triangle_count};

  Impl::Pending pending;
  pending.op.geometry = geometry;
  pending.op.scratch = nil;  // assigned in EncodeScene, once the frame's scratch need is known
  if (decision.action == CaptureAction::kBuild) {
    const bool fast = draw.placement.dynamic;
    const auto sizes = [s.device accelerationStructureSizesWithDescriptor:PrimitiveDescriptor(geometry, true, fast)];
    const auto placement = [s.device heapAccelerationStructureSizeAndAlignWithSize:sizes.accelerationStructureSize];
    blas.structure = placement.size ? [s.heap newAccelerationStructureWithSize:sizes.accelerationStructureSize] : nil;
    if (!blas.structure) { s.cache.Abandon(slot); return true; }  // heap fragmented or full: retried later
    blas.refit_scratch = sizes.refitScratchBufferSize;
    blas.resource_id = blas.structure.gpuResourceID;
    blas.refit_descriptor = PrimitiveDescriptor(geometry, true, fast);
    pending.op.kind = AccelerationStructureOp::Kind::kBuildPrimitive;
    pending.op.destination = blas.structure;
    pending.op.fast_build = fast;
    pending.scratch_size = sizes.buildScratchBufferSize;
    pending.built = &slot;
    s.cache.Built(slot, placement.size, blas);
  } else {
    pending.op.kind = AccelerationStructureOp::Kind::kRefitPrimitive;
    pending.op.destination = pending.op.source = blas.structure;
    pending.op.fast_build = draw.placement.dynamic;
    // The build's own descriptor (same topology and usage), pointed at this frame's positions.
    if (auto* d = blas.refit_descriptor) {
      auto* triangles = static_cast<MTLAccelerationStructureTriangleGeometryDescriptor*>(d.geometryDescriptors[0]);
      triangles.vertexBuffer = geometry.vertices;
      triangles.vertexBufferOffset = geometry.vertex_offset;
      pending.op.descriptor = d;
    }
    pending.scratch_size = blas.refit_scratch;
  }

  select_pipeline();
  CaptureDraw parameters;
  std::memcpy(&parameters.clip_to_world, s.clip_to_world.data(), sizeof(parameters.clip_to_world));
  parameters.first_vertex = blas.first_vertex;
  parameters.vertex_count = blas.vertex_count;
  [render setVertexBytes:&parameters length:sizeof(parameters) atIndex:kCaptureDrawBuffer];
  [render setVertexBuffer:s.slot->positions offset:positions atIndex:kCapturePositionsBuffer];
  // Each vertex once, with the draw's own base vertex folded into first_vertex.
  [render drawPrimitives:MTLPrimitiveTypePoint vertexStart:blas.first_vertex vertexCount:blas.vertex_count];
  ++s.captured;
  s.pending.push_back(std::move(pending));
  (void)error;
  return true;
}

id<MTLAccelerationStructure> Capture::EncodeScene(id<MTLCommandBuffer> commands, std::string& error) {
  auto& s = *impl_;
  if (!s.frame_active || !s.slot) return nil;
  if (s.encoded) return s.encoded;  // once per frame
  const auto& scene = s.cache.scene();
  if (scene.empty()) return nil;
  ScopedCpuTime timed(s.scene_time);

  // One scratch buffer for the frame: each op gets its own aligned range.
  NSUInteger scratch_need = 0;
  for (auto& p : s.pending) { p.op.scratch_offset = scratch_need; scratch_need = AlignUp(scratch_need + p.scratch_size, 256); }
  const NSUInteger instance_bytes = scene.size() * sizeof(MTLIndirectAccelerationStructureInstanceDescriptor);
  if (scene.size() > s.scene_sizes_count) {
    s.scene_sizes_count = AlignUp(scene.size(), 256);
    s.scene_sizes = [s.device accelerationStructureSizesWithDescriptor:InstanceDescriptor(nil, 0, uint32_t(s.scene_sizes_count))];
  }
  const auto scene_sizes = s.scene_sizes;
  const NSUInteger scene_scratch = AlignUp(scratch_need, 256);
  scratch_need = scene_scratch + scene_sizes.buildScratchBufferSize;
  if (!s.slot->scratch || s.slot->scratch.length < scratch_need) {
    s.slot->scratch = [s.device newBufferWithLength:AlignUp(scratch_need + scratch_need / 4, 1 << 16)
                                            options:MTLResourceStorageModePrivate];
    if (!s.slot->scratch) { error = "ray-tracing scratch allocation failed"; return nil; }
  }
  if (!s.slot->instances || s.slot->instances.length < instance_bytes) {
    s.slot->instances = [s.device newBufferWithLength:AlignUp(instance_bytes * 3 / 2, 1 << 12)
                                              options:MTLResourceStorageModeShared];
    if (!s.slot->instances) { error = "ray-tracing instance allocation failed"; return nil; }
  }
  if (!s.slot->scene || s.slot->scene.size < scene_sizes.accelerationStructureSize) {
    s.slot->scene = [s.device newAccelerationStructureWithSize:scene_sizes.accelerationStructureSize * 3 / 2];
    if (!s.slot->scene) { error = "ray-tracing scene allocation failed"; return nil; }
  }
  auto* instances = static_cast<MTLIndirectAccelerationStructureInstanceDescriptor*>(s.slot->instances.contents);
  for (size_t i = 0; i < scene.size(); ++i) FillInstance(instances[i], scene[i]->payload.resource_id, uint32_t(i), scene[i]->payload.mask);

  std::vector<AccelerationStructureOp> primitives;
  primitives.reserve(s.pending.size());
  for (auto& p : s.pending) { p.op.scratch = s.slot->scratch; primitives.push_back(p.op); }
  // Two encoders: the instance build reads the primitive structures this frame built or refit.
  if (!EncodeAccelerationStructureWork(commands, primitives, error, s.heap)) return nil;
  AccelerationStructureOp scene_op;
  scene_op.kind = AccelerationStructureOp::Kind::kBuildInstances;
  scene_op.destination = s.slot->scene;
  scene_op.scratch = s.slot->scratch;
  scene_op.scratch_offset = scene_scratch;
  scene_op.instances = s.slot->instances;
  scene_op.instance_count = uint32_t(scene.size());
  if (!EncodeAccelerationStructureWork(commands, std::span(&scene_op, 1), error, s.heap)) return nil;
  s.pending.clear();
  s.encoded = s.slot->scene;
  return s.encoded;
}

void Capture::EndFrame() {
  auto& s = *impl_;
  if (!s.frame_open) return;
  // Builds EncodeScene did not encode (no hook this frame, or it failed) were never
  // made: drop them so the next frame captures and builds them again.
  for (auto& p : s.pending)
    if (p.built) { s.Retire(p.built->payload); s.cache.Abandon(*p.built); }
  s.pending.clear();
  s.cache.EndFrame([&](Blas& blas) { s.Retire(blas); });
  const uint64_t delay = s.slots.size();
  while (!s.retiring.empty() && s.frame - s.retiring.front().first >= delay) s.retiring.pop_front();
  s.frame_open = s.frame_active = false;
  s.encoded = nil;
}

void Capture::Reset() {
  auto& s = *impl_;
  s.cache.Clear([&](Blas& blas) { blas = {}; });
  s.retiring.clear();
  s.rejected.clear();
  s.pending.clear();
  for (auto& slot : s.slots) { slot.scene = nil; slot.scratch = nil; slot.instances = nil; slot.positions_used = 0; }
  s.scene_sizes_count = 0;
  s.frame_open = s.frame_active = false;
}

}  // namespace rex::graphics::gta4_metal::raytracing
