#import "metal4_queue.h"

#include <rex/cvar.h>

REXCVAR_DEFINE_STRING(gta4_metal4_render_barrier, "full", "GPU/Metal",
    "Metal 4 queue barrier before each render pass: full (wait for all earlier work before vertex and "
    "fragment stages), fragment (measurement only: vertex work may overlap earlier passes) or tracked "
    "(fragment after render-only work; full after compute, copies or a Metal 3 hop; a vertex barrier "
    "inside the pass when it samples an earlier pass's attachment in the vertex stage)");
REXCVAR_DEFINE_STRING(gta4_metal4_residency, "frame", "GPU/Metal",
    "Metal 4 residency: frame (each command buffer rebuilds its own residency set) or persistent "
    "(one queue-level set; resources join once and leave after about 1000 command buffers unused)");

#import <objc/runtime.h>

#include <atomic>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

// The proxies implement the subset of the Metal 3 protocols the renderer uses;
// anything else is forwarded to the Metal 4 object (or fails loudly if it has none).
#pragma clang diagnostic ignored "-Wprotocol"
#pragma clang diagnostic ignored "-Wobjc-protocol-property-synthesis"
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wobjc-property-implementation"

namespace {
constexpr NSUInteger kChunkBytes = 4u << 20;
constexpr NSUInteger kTransientAlignment = 16;
constexpr MTLStages kRenderStages = MTLStageVertex | MTLStageFragment;
constexpr MTLStages kComputeStages = MTLStageDispatch | MTLStageBlit;

// -conformsToProtocol: walks the class's protocol lists; it was most of the proxy's
// per-resource cost. Resource classes are few, so cache the answer per class.
template <typename Protocol>
bool Conforms(id object, Protocol* protocol) {
  struct Entry { Class cls; Protocol* protocol; bool conforms; };
  thread_local std::vector<Entry> cache;
  const Class cls = object_getClass(object);
  for (const Entry& e : cache)
    if (e.cls == cls && e.protocol == protocol) return e.conforms;
  const bool conforms = [object conformsToProtocol:protocol];
  cache.push_back({cls, protocol, conforms});
  return conforms;
}
enum class Kind { kUnknown, kTexture, kBuffer };
enum class RenderBarrier { kFull, kFragment, kTracked };
// Persistent residency: an allocation leaves the queue set after this many command buffers unused.
constexpr uint64_t kPersistentIdleCommandBuffers = 1000;
struct Persisted {
  __strong id<MTLAllocation> allocation;  // keeps the address from being reused while it is in the set
  uint64_t last = 0;
};
// Per-command-buffer front of _seen for the bind hot path: a resource already tracked in
// this command buffer and its GPU address or resource ID. Direct-mapped, no eviction cost.
constexpr size_t kBindCacheSize = 512;
struct BindCacheEntry {
  const void* key = nullptr;
  uint64_t value = 0;
};
inline size_t BindCacheIndex(const void* p) {
  const uintptr_t v = reinterpret_cast<uintptr_t>(p);
  return ((v >> 4) ^ (v >> 13)) & (kBindCacheSize - 1);
}
}  // namespace

@class LXCommandBuffer;

@interface LXQueue : NSObject <MTLCommandQueue> {
 @public
  id<MTLDevice> _device;
  id<MTL4CommandQueue> _queue4;
  id<MTLCommandQueue> _side3;
  std::mutex _lock;
  NSMutableArray<id<MTL4CommandAllocator>>* _allocators;
  NSMutableArray<id<MTL4CommandBuffer>>* _buffers;
  NSMutableArray<id<MTLResidencySet>>* _sets;
  NSMutableArray<id<MTLBuffer>>* _chunks;
  NSMutableArray<id<MTL4ArgumentTable>>* _tables;
  NSUInteger _tableTextures;
  NSString* _label;
  id<MTL4Compiler> _compiler;
  MTLStages _renderBefore;
  RenderBarrier _renderBarrier;
  std::atomic<uint64_t> _commandBuffers, _parts, _encoders, _barriers, _transient, _resident, _hops;
  std::atomic<uint64_t> _binds, _bindHits, _fragmentBarriers, _vertexBarriers, _evicted, _residencyCommits;
  // gta4_metal4_residency = persistent
  BOOL _persistentResidency;
  std::mutex _persistLock;
  id<MTLResidencySet> _persistent;
  std::unordered_map<const void*, Persisted> _persisted;
  uint64_t _commandBufferIndex;
  bool _persistDirty;
}
- (id<MTL4CommandAllocator>)takeAllocator;
- (id<MTL4CommandBuffer>)takeBuffer;
- (id<MTLResidencySet>)takeSet;
- (id<MTLBuffer>)takeChunk:(NSUInteger)minimum;
- (id<MTL4ArgumentTable>)takeTable;
- (void)giveTable:(id<MTL4ArgumentTable>)table;
- (id<MTLCommandQueue>)side3;
- (void)persist:(id<MTLAllocation>)allocation;
- (void)commitPersistent:(BOOL)evict;
@end

@interface LXCommandBuffer : NSObject <MTLCommandBuffer> {
 @public
  LXQueue* _q;
  id<MTL4CommandBuffer> _cb;
  id<MTL4CommandAllocator> _allocator;
  NSMutableArray* _finished;  // MTL4 command buffers and allocators of committed parts
  id<MTLResidencySet> _set;
  NSMutableArray* _retained;
  std::unordered_set<const void*> _seen;
  BindCacheEntry _bindCache[kBindCacheSize];
  BOOL _nonRenderSinceRender;              // tracked barriers: compute, copies or a hop since the last render pass
  std::unordered_set<const void*> _attachments;  // tracked barriers: textures written as attachments so far
  id<MTLBuffer> _chunk;
  NSUInteger _used;
  NSMutableArray<id<MTLBuffer>>* _chunks;
  NSMutableArray<MTLCommandBufferHandler>* _completed;
  NSMutableArray<MTLCommandBufferHandler>* _scheduled;
  NSMutableArray<id<MTLEvent>>* _waitEvents;
  std::vector<uint64_t> _waitValues;
  NSMutableArray<id<MTLEvent>>* _signalEvents;
  std::vector<uint64_t> _signalValues;
  NSMutableArray<id<MTLDrawable>>* _drawables;
  std::atomic<int> _status;
  NSError* _error;
  CFTimeInterval _gpuStart, _gpuEnd;
  std::atomic<uint64_t> _earlierGpuNs;  // GPU time of the parts before the last one
  std::atomic<double> _firstStart;
  NSString* _label;
  dispatch_group_t _done;
  BOOL _committed;
}
- (void)track:(id<MTLResource>)resource;
- (void)track:(id<MTLResource>)resource kind:(Kind)kind;
- (uint64_t)bufferAddress:(id<MTLBuffer>)buffer;
- (MTLResourceID)textureID:(id<MTLTexture>)texture;
- (BOOL)isAttachment:(id<MTLTexture>)texture;
- (void)trackHeap:(id<MTLHeap>)heap;
- (uint64_t)bytes:(const void*)bytes length:(NSUInteger)length;
- (void)hop:(void (^)(id<MTLCommandBuffer>))body;
- (void)native:(id<MTLFence>)fence resources:(NSArray<id<MTLResource>>*)resources body:(void (^)(id<MTL4CommandBuffer>))body;
@end

static void Barrier(LXQueue* q, id<MTL4CommandEncoder> e, MTLStages before) {
  [e barrierAfterQueueStages:MTLStageAll beforeStages:before visibilityOptions:MTL4VisibilityOptionDevice];
  ++q->_barriers;
}

// ---------------------------------------------------------------------------------------------
@interface LXRender : NSObject <MTLRenderCommandEncoder> {
 @public
  LXCommandBuffer* _owner;
  id<MTL4RenderCommandEncoder> _e;
  id<MTL4ArgumentTable> _vt, _ft;
  BOOL _vertexBarrier;  // tracked barriers: this pass already waits before its vertex stage
}
@end

@implementation LXRender
- (id)forwardingTargetForSelector:(SEL)selector { return _e; }
- (id<MTLDevice>)device { return _owner->_q->_device; }
- (NSString*)label { return _e.label; }
- (void)setLabel:(NSString*)label { _e.label = label; }
- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)s { [_e setRenderPipelineState:s]; }
- (void)setDepthStencilState:(id<MTLDepthStencilState>)s { [_e setDepthStencilState:s]; }
- (void)setViewport:(MTLViewport)v { [_e setViewport:v]; }
- (void)setScissorRect:(MTLScissorRect)r { [_e setScissorRect:r]; }
- (void)setCullMode:(MTLCullMode)m { [_e setCullMode:m]; }
- (void)setFrontFacingWinding:(MTLWinding)w { [_e setFrontFacingWinding:w]; }
- (void)setTriangleFillMode:(MTLTriangleFillMode)m { [_e setTriangleFillMode:m]; }
- (void)setDepthClipMode:(MTLDepthClipMode)m { [_e setDepthClipMode:m]; }
- (void)setDepthBias:(float)b slopeScale:(float)s clamp:(float)c { [_e setDepthBias:b slopeScale:s clamp:c]; }
- (void)setStencilReferenceValue:(uint32_t)v { [_e setStencilReferenceValue:v]; }
- (void)setStencilFrontReferenceValue:(uint32_t)f backReferenceValue:(uint32_t)b {
  [_e setStencilFrontReferenceValue:f backReferenceValue:b];
}
- (void)setBlendColorRed:(float)r green:(float)g blue:(float)b alpha:(float)a {
  [_e setBlendColorRed:r green:g blue:b alpha:a];
}
- (void)setVisibilityResultMode:(MTLVisibilityResultMode)m offset:(NSUInteger)o { [_e setVisibilityResultMode:m offset:o]; }

static void BindBuffer(LXCommandBuffer* owner, id<MTL4ArgumentTable> t, id<MTLBuffer> b, NSUInteger offset, NSUInteger index) {
  if (!b) return;
  [t setAddress:[owner bufferAddress:b] + offset atIndex:index];
}
static void BindTexture(LXCommandBuffer* owner, id<MTL4ArgumentTable> t, id<MTLTexture> texture, NSUInteger index) {
  [t setTexture:texture ? [owner textureID:texture] : MTLResourceID{} atIndex:index];
}
// Tracked barriers: a vertex-stage read of a texture an earlier pass rendered into needs the
// vertex stage to wait too (the pass started with a fragment-only barrier).
static void BindVertexTexture(LXRender* r, id<MTLTexture> texture, NSUInteger index) {
  LXCommandBuffer* owner = r->_owner;
  if (texture && !r->_vertexBarrier && owner->_q->_renderBarrier == RenderBarrier::kTracked &&
      [owner isAttachment:texture]) {
    [r->_e barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageVertex visibilityOptions:MTL4VisibilityOptionDevice];
    r->_vertexBarrier = YES;
    ++owner->_q->_barriers; ++owner->_q->_vertexBarriers;
  }
  BindTexture(owner, r->_vt, texture, index);
}
static void BindSampler(id<MTL4ArgumentTable> t, id<MTLSamplerState> sampler, NSUInteger index) {
  MTLResourceID rid{};
  if (sampler) rid = sampler.gpuResourceID;
  [t setSamplerState:rid atIndex:index];
}

- (void)setVertexBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i { BindBuffer(_owner, _vt, b, o, i); }
- (void)setFragmentBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i { BindBuffer(_owner, _ft, b, o, i); }
- (void)setVertexBuffers:(id<MTLBuffer> const[])b offsets:(const NSUInteger[])o withRange:(NSRange)r {
  for (NSUInteger i = 0; i < r.length; ++i) BindBuffer(_owner, _vt, b[i], o[i], r.location + i);
}
- (void)setFragmentBuffers:(id<MTLBuffer> const[])b offsets:(const NSUInteger[])o withRange:(NSRange)r {
  for (NSUInteger i = 0; i < r.length; ++i) BindBuffer(_owner, _ft, b[i], o[i], r.location + i);
}
- (void)setVertexBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i { (void)o; (void)i; abort(); }
- (void)setVertexBytes:(const void*)p length:(NSUInteger)n atIndex:(NSUInteger)i {
  [_vt setAddress:[_owner bytes:p length:n] atIndex:i];
}
- (void)setFragmentBytes:(const void*)p length:(NSUInteger)n atIndex:(NSUInteger)i {
  [_ft setAddress:[_owner bytes:p length:n] atIndex:i];
}
- (void)setVertexTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i { BindVertexTexture(self, t, i); }
- (void)setFragmentTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i { BindTexture(_owner, _ft, t, i); }
- (void)setVertexTextures:(id<MTLTexture> const[])t withRange:(NSRange)r {
  for (NSUInteger i = 0; i < r.length; ++i) BindVertexTexture(self, t[i], r.location + i);
}
- (void)setFragmentTextures:(id<MTLTexture> const[])t withRange:(NSRange)r {
  for (NSUInteger i = 0; i < r.length; ++i) BindTexture(_owner, _ft, t[i], r.location + i);
}
- (void)setVertexSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i { BindSampler(_vt, s, i); }
- (void)setFragmentSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i { BindSampler(_ft, s, i); }
- (void)setFragmentSamplerStates:(id<MTLSamplerState> const[])s withRange:(NSRange)r {
  for (NSUInteger i = 0; i < r.length; ++i) BindSampler(_ft, s[i], r.location + i);
}
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)u stages:(MTLRenderStages)s { [_owner track:r]; }
- (void)useResources:(const id<MTLResource> __unsafe_unretained[])r count:(NSUInteger)n usage:(MTLResourceUsage)u
              stages:(MTLRenderStages)s {
  for (NSUInteger i = 0; i < n; ++i) [_owner track:r[i]];
}
- (void)useHeap:(id<MTLHeap>)h stages:(MTLRenderStages)s { [_owner trackHeap:h]; }
- (void)useHeaps:(const id<MTLHeap> __unsafe_unretained[])h count:(NSUInteger)n stages:(MTLRenderStages)s {
  for (NSUInteger i = 0; i < n; ++i) [_owner trackHeap:h[i]];
}
- (void)drawPrimitives:(MTLPrimitiveType)t vertexStart:(NSUInteger)s vertexCount:(NSUInteger)c {
  [_e drawPrimitives:t vertexStart:s vertexCount:c];
}
- (void)drawPrimitives:(MTLPrimitiveType)t vertexStart:(NSUInteger)s vertexCount:(NSUInteger)c instanceCount:(NSUInteger)n {
  [_e drawPrimitives:t vertexStart:s vertexCount:c instanceCount:n];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)t indexCount:(NSUInteger)c indexType:(MTLIndexType)it
                  indexBuffer:(id<MTLBuffer>)b indexBufferOffset:(NSUInteger)o {
  [_owner track:b];
  [_e drawIndexedPrimitives:t indexCount:c indexType:it indexBuffer:b.gpuAddress + o indexBufferLength:b.length - o];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)t indexCount:(NSUInteger)c indexType:(MTLIndexType)it
                  indexBuffer:(id<MTLBuffer>)b indexBufferOffset:(NSUInteger)o instanceCount:(NSUInteger)n
                   baseVertex:(NSInteger)v baseInstance:(NSUInteger)bi {
  [_owner track:b];
  [_e drawIndexedPrimitives:t indexCount:c indexType:it indexBuffer:b.gpuAddress + o indexBufferLength:b.length - o
              instanceCount:n baseVertex:v baseInstance:bi];
}
- (void)endEncoding {
  [_e endEncoding];
  // Tables are captured at each draw, so they can serve the next encoder at once.
  [_owner->_q giveTable:_vt]; [_owner->_q giveTable:_ft];
  _vt = _ft = nil; _e = nil;
}
@end

// ---------------------------------------------------------------------------------------------
// Blits run on an MTL4 compute encoder, whose copy selectors match the Metal 3 blit ones.
// Copies in one encoder are ordered by an encoder barrier, as a Metal 3 blit encoder orders
// copies that touch the same resources.
@interface LXCopy : NSObject <MTLBlitCommandEncoder> {
 @public
  LXCommandBuffer* _owner;
  id<MTL4ComputeCommandEncoder> _e;
  BOOL _first;
}
@end

static void TrackInvocationResources(LXCommandBuffer* owner, NSInvocation* invocation) {
  NSMethodSignature* signature = invocation.methodSignature;
  for (NSUInteger i = 2; i < signature.numberOfArguments; ++i) {
    if (std::strcmp([signature getArgumentTypeAtIndex:i], "@") != 0) continue;
    __unsafe_unretained id value = nil;
    [invocation getArgument:&value atIndex:i];
    if (value && Conforms(value, @protocol(MTLResource))) [owner track:value];
  }
}

@implementation LXCopy
- (id<MTLDevice>)device { return _owner->_q->_device; }
- (NSString*)label { return _e.label; }
- (void)setLabel:(NSString*)label { _e.label = label; }
- (NSMethodSignature*)methodSignatureForSelector:(SEL)selector {
  return [(NSObject*)_e methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation*)invocation {
  const char* name = sel_getName(invocation.selector);
  const bool copy = !std::strncmp(name, "copy", 4) || !std::strncmp(name, "fill", 4) || !std::strncmp(name, "generate", 8);
  if (copy) {
    TrackInvocationResources(_owner, invocation);
    if (!_first) {
      [_e barrierAfterEncoderStages:MTLStageBlit beforeEncoderStages:MTLStageBlit visibilityOptions:MTL4VisibilityOptionDevice];
      ++_owner->_q->_barriers;
    }
    _first = NO;
  }
  [invocation invokeWithTarget:_e];
}
- (void)endEncoding { [_e endEncoding]; _e = nil; }
@end

// ---------------------------------------------------------------------------------------------
@interface LXCompute : NSObject <MTLComputeCommandEncoder> {
 @public
  LXCommandBuffer* _owner;
  id<MTL4ComputeCommandEncoder> _e;
  id<MTL4ArgumentTable> _t;
  BOOL _serial, _dispatched;
}
@end

@implementation LXCompute
- (id)forwardingTargetForSelector:(SEL)selector { return _e; }
- (id<MTLDevice>)device { return _owner->_q->_device; }
- (NSString*)label { return _e.label; }
- (void)setLabel:(NSString*)label { _e.label = label; }
- (MTLDispatchType)dispatchType { return _serial ? MTLDispatchTypeSerial : MTLDispatchTypeConcurrent; }
- (void)setComputePipelineState:(id<MTLComputePipelineState>)s { [_e setComputePipelineState:s]; }
- (void)setBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i { BindBuffer(_owner, _t, b, o, i); }
- (void)setBuffers:(id<MTLBuffer> const[])b offsets:(const NSUInteger[])o withRange:(NSRange)r {
  for (NSUInteger i = 0; i < r.length; ++i) BindBuffer(_owner, _t, b[i], o[i], r.location + i);
}
- (void)setBytes:(const void*)p length:(NSUInteger)n atIndex:(NSUInteger)i {
  [_t setAddress:[_owner bytes:p length:n] atIndex:i];
}
- (void)setTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i { BindTexture(_owner, _t, t, i); }
- (void)setTextures:(id<MTLTexture> const[])t withRange:(NSRange)r {
  for (NSUInteger i = 0; i < r.length; ++i) BindTexture(_owner, _t, t[i], r.location + i);
}
- (void)setSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i { BindSampler(_t, s, i); }
- (void)setSamplerStates:(id<MTLSamplerState> const[])s withRange:(NSRange)r {
  for (NSUInteger i = 0; i < r.length; ++i) BindSampler(_t, s[i], r.location + i);
}
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)u { [_owner track:r]; }
- (void)useResources:(const id<MTLResource> __unsafe_unretained[])r count:(NSUInteger)n usage:(MTLResourceUsage)u {
  for (NSUInteger i = 0; i < n; ++i) [_owner track:r[i]];
}
- (void)useHeap:(id<MTLHeap>)h { [_owner trackHeap:h]; }
- (void)useHeaps:(const id<MTLHeap> __unsafe_unretained[])h count:(NSUInteger)n {
  for (NSUInteger i = 0; i < n; ++i) [_owner trackHeap:h[i]];
}
- (void)orderDispatch {
  // A serial Metal 3 compute encoder orders dependent dispatches; keep that order.
  if (_serial && _dispatched) {
    [_e barrierAfterEncoderStages:MTLStageDispatch beforeEncoderStages:MTLStageDispatch
                visibilityOptions:MTL4VisibilityOptionDevice];
    ++_owner->_q->_barriers;
  }
  _dispatched = YES;
}
- (void)dispatchThreads:(MTLSize)g threadsPerThreadgroup:(MTLSize)t {
  [self orderDispatch]; [_e dispatchThreads:g threadsPerThreadgroup:t];
}
- (void)dispatchThreadgroups:(MTLSize)g threadsPerThreadgroup:(MTLSize)t {
  [self orderDispatch]; [_e dispatchThreadgroups:g threadsPerThreadgroup:t];
}
- (void)memoryBarrierWithScope:(MTLBarrierScope)scope {
  [_e barrierAfterEncoderStages:MTLStageDispatch beforeEncoderStages:MTLStageDispatch
              visibilityOptions:MTL4VisibilityOptionDevice];
  ++_owner->_q->_barriers;
}
- (void)endEncoding {
  [_e endEncoding];
  [_owner->_q giveTable:_t];
  _t = nil; _e = nil;
}
@end

// ---------------------------------------------------------------------------------------------
@implementation LXCommandBuffer
- (instancetype)initWithQueue:(LXQueue*)q {
  if (!(self = [super init])) return nil;
  _q = q;
  _finished = [NSMutableArray new];
  _retained = [NSMutableArray arrayWithCapacity:1024];
  _chunks = [NSMutableArray new];
  _completed = [NSMutableArray new];
  _scheduled = [NSMutableArray new];
  _waitEvents = [NSMutableArray new];
  _signalEvents = [NSMutableArray new];
  _drawables = [NSMutableArray new];
  _done = dispatch_group_create();
  _status = MTLCommandBufferStatusNotEnqueued;
  _set = q->_persistentResidency ? nil : [q takeSet];
  _nonRenderSinceRender = YES;  // what the previous command buffer ended with is unknown here
  ++q->_commandBuffers;
  if (q->_persistentResidency) {
    std::lock_guard<std::mutex> lock(q->_persistLock);
    ++q->_commandBufferIndex;
  }
  [self beginPart];
  return self;
}
- (void)beginPart {
  _allocator = [_q takeAllocator];
  _cb = [_q takeBuffer];
  [_cb beginCommandBufferWithAllocator:_allocator];
  if (_label) _cb.label = _label;
  ++_q->_parts;
}
- (id<MTLDevice>)device { return _q->_device; }
- (id<MTLCommandQueue>)commandQueue { return _q; }
- (NSString*)label { return _label; }
- (void)setLabel:(NSString*)label { _label = [label copy]; _cb.label = _label; }
- (BOOL)retainedReferences { return YES; }
- (MTLCommandBufferErrorOption)errorOptions { return MTLCommandBufferErrorOptionNone; }
- (MTLCommandBufferStatus)status { return MTLCommandBufferStatus(_status.load()); }
- (NSError*)error { return _error; }
- (CFTimeInterval)GPUStartTime { return _gpuStart; }
- (CFTimeInterval)GPUEndTime { return _gpuEnd; }
- (CFTimeInterval)kernelStartTime { return _gpuStart; }
- (CFTimeInterval)kernelEndTime { return _gpuEnd; }

- (void)track:(id<MTLResource>)resource { [self track:resource kind:Kind::kUnknown]; }
- (void)track:(id<MTLResource>)resource kind:(Kind)kind {
  if (!resource) return;
  if (!_seen.insert((__bridge const void*)resource).second) return;
  [_retained addObject:resource];
  id<MTLAllocation> allocation = resource;
  if (id<MTLHeap> heap = resource.heap) {
    if (!_seen.insert((__bridge const void*)heap).second) return;
    [_retained addObject:heap];
    allocation = heap;
  } else if (kind == Kind::kTexture ||
             (kind == Kind::kUnknown && Conforms(resource, @protocol(MTLTexture)))) {
    id<MTLTexture> texture = (id<MTLTexture>)resource;
    // Drawables are resident through their layer's residency set (AddLayerResidency).
    if (texture.isFramebufferOnly) return;
    if (id<MTLTexture> parent = texture.parentTexture) { [self track:parent kind:Kind::kTexture]; return; }
    if (id<MTLBuffer> buffer = texture.buffer) { [self track:buffer kind:Kind::kBuffer]; return; }
  }
  if (_q->_persistentResidency) { [_q persist:allocation]; return; }
  [_set addAllocation:allocation];
  ++_q->_resident;
}
- (void)trackHeap:(id<MTLHeap>)heap {
  if (!heap || !_seen.insert((__bridge const void*)heap).second) return;
  [_retained addObject:heap];
  if (_q->_persistentResidency) { [_q persist:heap]; return; }
  [_set addAllocation:heap];
  ++_q->_resident;
}
// The bind hot path: one direct-mapped probe instead of a hash-set insert and a message for
// the address on every bind. The entry is valid for this command buffer, which retains the
// resource (no address reuse while it lives).
- (uint64_t)bufferAddress:(id<MTLBuffer>)buffer {
  ++_q->_binds;
  BindCacheEntry& e = _bindCache[BindCacheIndex((__bridge const void*)buffer)];
  if (e.key == (__bridge const void*)buffer) { ++_q->_bindHits; return e.value; }
  [self track:buffer kind:Kind::kBuffer];
  e.key = (__bridge const void*)buffer;
  e.value = buffer.gpuAddress;
  return e.value;
}
- (MTLResourceID)textureID:(id<MTLTexture>)texture {
  ++_q->_binds;
  BindCacheEntry& e = _bindCache[BindCacheIndex((__bridge const void*)texture)];
  MTLResourceID rid{};
  static_assert(sizeof(rid) == sizeof(e.value));
  if (e.key == (__bridge const void*)texture) {
    ++_q->_bindHits;
    std::memcpy(&rid, &e.value, sizeof(rid));
    return rid;
  }
  [self track:texture kind:Kind::kTexture];
  rid = texture.gpuResourceID;
  e.key = (__bridge const void*)texture;
  std::memcpy(&e.value, &rid, sizeof(rid));
  return rid;
}
- (BOOL)isAttachment:(id<MTLTexture>)texture {
  if (_attachments.count((__bridge const void*)texture)) return YES;
  id<MTLTexture> parent = texture.parentTexture;
  return parent && _attachments.count((__bridge const void*)parent);
}
- (uint64_t)bytes:(const void*)bytes length:(NSUInteger)length {
  NSUInteger offset = (_used + kTransientAlignment - 1) & ~(kTransientAlignment - 1);
  if (!_chunk || offset + length > _chunk.length) {
    _chunk = [_q takeChunk:MAX(length, kChunkBytes)];
    [_chunks addObject:_chunk];
    [self track:_chunk kind:Kind::kBuffer];
    offset = 0;
  }
  std::memcpy(static_cast<uint8_t*>(_chunk.contents) + offset, bytes, length);
  _used = offset + length;
  _q->_transient += length;
  return _chunk.gpuAddress + offset;
}

- (id<MTLRenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor*)d {
  MTL4RenderPassDescriptor* r = [MTL4RenderPassDescriptor new];
  for (NSUInteger i = 0; i < 8; ++i) {
    MTLRenderPassColorAttachmentDescriptor* a = d.colorAttachments[i];
    if (!a.texture) continue;
    [self track:a.texture kind:Kind::kTexture]; [self track:a.resolveTexture kind:Kind::kTexture];
    if (_q->_renderBarrier == RenderBarrier::kTracked) {
      _attachments.insert((__bridge const void*)a.texture);
      if (a.resolveTexture) _attachments.insert((__bridge const void*)a.resolveTexture);
    }
    r.colorAttachments[i] = a;
  }
  if (d.depthAttachment.texture) {
    [self track:d.depthAttachment.texture kind:Kind::kTexture]; [self track:d.depthAttachment.resolveTexture kind:Kind::kTexture];
    if (_q->_renderBarrier == RenderBarrier::kTracked) _attachments.insert((__bridge const void*)d.depthAttachment.texture);
    r.depthAttachment = d.depthAttachment;
  }
  if (d.stencilAttachment.texture) {
    [self track:d.stencilAttachment.texture kind:Kind::kTexture];
    if (_q->_renderBarrier == RenderBarrier::kTracked) _attachments.insert((__bridge const void*)d.stencilAttachment.texture);
    r.stencilAttachment = d.stencilAttachment;
  }
  if (d.visibilityResultBuffer) {
    [self track:d.visibilityResultBuffer kind:Kind::kBuffer];
    r.visibilityResultBuffer = d.visibilityResultBuffer;
    r.visibilityResultType = d.visibilityResultType;
  }
  r.renderTargetArrayLength = d.renderTargetArrayLength;
  r.renderTargetWidth = d.renderTargetWidth;
  r.renderTargetHeight = d.renderTargetHeight;
  r.defaultRasterSampleCount = d.defaultRasterSampleCount;
  id<MTL4RenderCommandEncoder> e = [_cb renderCommandEncoderWithDescriptor:r];
  if (!e) return nil;
  MTLStages before = _q->_renderBefore;
  if (_q->_renderBarrier == RenderBarrier::kTracked) {
    // Only render passes since the last barrier: their writes are attachments (fragment stage),
    // so this pass's fragment stage waits and its vertex stage may overlap. Anything else
    // (compute, copies, a hop) may have written buffers the vertex stage reads: full barrier.
    before = _nonRenderSinceRender ? kRenderStages : MTLStageFragment;
    _nonRenderSinceRender = NO;
  }
  if (before == MTLStageFragment) ++_q->_fragmentBarriers;
  Barrier(_q, e, before);
  LXRender* p = [LXRender new];
  p->_owner = self; p->_e = e;
  p->_vt = [_q takeTable]; p->_ft = [_q takeTable];
  [e setArgumentTable:p->_vt atStages:MTLRenderStageVertex];
  [e setArgumentTable:p->_ft atStages:MTLRenderStageFragment];
  ++_q->_encoders;
  return p;
}
- (id<MTLBlitCommandEncoder>)blitCommandEncoder {
  id<MTL4ComputeCommandEncoder> e = [_cb computeCommandEncoder];
  if (!e) return nil;
  _nonRenderSinceRender = YES;
  Barrier(_q, e, kComputeStages);
  LXCopy* p = [LXCopy new];
  p->_owner = self; p->_e = e; p->_first = YES;
  ++_q->_encoders;
  return p;
}
- (id<MTLBlitCommandEncoder>)blitCommandEncoderWithDescriptor:(MTLBlitPassDescriptor*)d { return [self blitCommandEncoder]; }
- (id<MTLComputeCommandEncoder>)computeEncoder:(BOOL)serial {
  id<MTL4ComputeCommandEncoder> e = [_cb computeCommandEncoder];
  if (!e) return nil;
  _nonRenderSinceRender = YES;
  Barrier(_q, e, kComputeStages);
  LXCompute* p = [LXCompute new];
  p->_owner = self; p->_e = e; p->_serial = serial;
  p->_t = [_q takeTable];
  [e setArgumentTable:p->_t];
  ++_q->_encoders;
  return p;
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoder { return [self computeEncoder:YES]; }
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDispatchType:(MTLDispatchType)t {
  return [self computeEncoder:t == MTLDispatchTypeSerial];
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDescriptor:(MTLComputePassDescriptor*)d {
  return [self computeEncoder:d.dispatchType == MTLDispatchTypeSerial];
}
- (void)pushDebugGroup:(NSString*)s { [_cb pushDebugGroup:s]; }
- (void)popDebugGroup { [_cb popDebugGroup]; }
- (void)addCompletedHandler:(MTLCommandBufferHandler)block { [_completed addObject:[block copy]]; }
- (void)addScheduledHandler:(MTLCommandBufferHandler)block { [_scheduled addObject:[block copy]]; }
- (void)encodeWaitForEvent:(id<MTLEvent>)event value:(uint64_t)value {
  [_waitEvents addObject:event]; _waitValues.push_back(value);
}
- (void)encodeSignalEvent:(id<MTLEvent>)event value:(uint64_t)value {
  [_signalEvents addObject:event]; _signalValues.push_back(value);
}
- (void)presentDrawable:(id<MTLDrawable>)drawable { [_drawables addObject:drawable]; }
- (void)enqueue {}

// Ends the open MTL4 command buffer and commits it; the last part carries the feedback.
- (void)finishPart:(BOOL)last {
  if (_q->_persistentResidency) {
    // The queue-level set (added to the queue once) holds everything; commit what changed.
    [_q commitPersistent:last];
  } else {
    [_set commit];
    [_cb useResidencySet:_set];
    ++_q->_residencyCommits;
  }
  [_cb endCommandBuffer];
  id<MTL4CommandQueue> q4 = _q->_queue4;
  for (NSUInteger i = 0; i < _waitEvents.count; ++i) [q4 waitForEvent:_waitEvents[i] value:_waitValues[i]];
  [_waitEvents removeAllObjects]; _waitValues.clear();
  id<MTL4CommandBuffer> buffers[1] = {_cb};
  [_finished addObject:_cb]; [_finished addObject:_allocator];
  _cb = nil; _allocator = nil;
  if (!last) {
    MTL4CommitOptions* options = [MTL4CommitOptions new];
    __block LXCommandBuffer* me = self;
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
      const double start = feedback.GPUStartTime, end = feedback.GPUEndTime;
      if (end > start) me->_earlierGpuNs += uint64_t((end - start) * 1e9);
      double none = 0;
      me->_firstStart.compare_exchange_strong(none, start);
      me = nil;
    }];
    [q4 commit:buffers count:1 options:options];
    return;
  }
  for (id<MTLDrawable> d in _drawables) [q4 waitForDrawable:d];
  MTL4CommitOptions* options = [MTL4CommitOptions new];
  __block LXCommandBuffer* me = self;  // released by the feedback handler
  [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
    [me complete:feedback];
    me = nil;
  }];
  _status = MTLCommandBufferStatusCommitted;
  dispatch_group_enter(_done);
  [q4 commit:buffers count:1 options:options];
  for (NSUInteger i = 0; i < _signalEvents.count; ++i) [q4 signalEvent:_signalEvents[i] value:_signalValues[i]];
  for (id<MTLDrawable> d in _drawables) { [q4 signalDrawable:d]; [d present]; }
  [_drawables removeAllObjects]; [_signalEvents removeAllObjects]; _signalValues.clear();
  _status = MTLCommandBufferStatusScheduled;
  for (MTLCommandBufferHandler h in _scheduled) h(self);
  [_scheduled removeAllObjects];
}
- (void)commit {
  if (_committed) return;
  _committed = YES;
  [self finishPart:YES];
}
- (void)complete:(id<MTL4CommitFeedback>)feedback {
  _error = feedback.error;
  // Start of the first part; end such that end - start is the GPU time of all parts.
  const double last = feedback.GPUEndTime > feedback.GPUStartTime ? feedback.GPUEndTime - feedback.GPUStartTime : 0;
  const double first = _firstStart.load();
  _gpuStart = first > 0 ? first : feedback.GPUStartTime;
  _gpuEnd = _gpuStart + last + double(_earlierGpuNs.load()) * 1e-9;
  _status = _error ? MTLCommandBufferStatusError : MTLCommandBufferStatusCompleted;
  for (MTLCommandBufferHandler h in _completed) h(self);
  [_completed removeAllObjects];
  {
    std::lock_guard<std::mutex> lock(_q->_lock);
    for (id object in _finished) {
      if ([object conformsToProtocol:@protocol(MTL4CommandAllocator)]) {
        [(id<MTL4CommandAllocator>)object reset];
        [_q->_allocators addObject:object];
      } else {
        [_q->_buffers addObject:object];
      }
    }
    if (_set) {
      [_set removeAllAllocations];
      [_q->_sets addObject:_set];
    }
    [_q->_chunks addObjectsFromArray:_chunks];
  }
  [_finished removeAllObjects]; [_chunks removeAllObjects];
  _set = nil; _chunk = nil;
  [_retained removeAllObjects]; _seen.clear();
  dispatch_group_leave(_done);
}
- (void)waitUntilScheduled {}
- (void)waitUntilCompleted {
  if (_committed) dispatch_group_wait(_done, DISPATCH_TIME_FOREVER);
}
- (void)native:(id<MTLFence>)fence resources:(NSArray<id<MTLResource>>*)resources body:(void (^)(id<MTL4CommandBuffer>))body {
  for (id<MTLResource> r in resources) [self track:r];
  _nonRenderSinceRender = YES;
  id<MTL4ComputeCommandEncoder> e = [_cb computeCommandEncoder];
  Barrier(_q, e, kComputeStages);
  if (fence) [e updateFence:fence afterEncoderStages:kComputeStages];
  [e endEncoding];
  ++_q->_encoders;
  body(_cb);
}
- (void)hop:(void (^)(id<MTLCommandBuffer>))body {
  id<MTLEvent> event = [_q->_device newEvent];
  _nonRenderSinceRender = YES;
  [self finishPart:NO];
  [_q->_queue4 signalEvent:event value:1];
  id<MTLCommandBuffer> m3 = [[_q side3] commandBuffer];
  m3.label = @"Liberty Metal 3 hop";
  [m3 encodeWaitForEvent:event value:1];
  body(m3);
  [m3 encodeSignalEvent:event value:2];
  [m3 commit];
  [self beginPart];
  [_waitEvents addObject:event]; _waitValues.push_back(2);
  [_retained addObject:m3];
  ++_q->_hops;
}
@end

// ---------------------------------------------------------------------------------------------
@implementation LXQueue
- (id<MTLDevice>)device { return _device; }
- (NSString*)label { return _label; }
- (void)setLabel:(NSString*)label { _label = [label copy]; }
- (id<MTLCommandBuffer>)commandBuffer { return [[LXCommandBuffer alloc] initWithQueue:self]; }
- (id<MTLCommandBuffer>)commandBufferWithUnretainedReferences { return [self commandBuffer]; }
- (id<MTLCommandBuffer>)commandBufferWithDescriptor:(MTLCommandBufferDescriptor*)d { return [self commandBuffer]; }
- (void)insertDebugCaptureBoundary {}
- (void)addResidencySet:(id<MTLResidencySet>)set { [_queue4 addResidencySet:set]; }
- (void)removeResidencySet:(id<MTLResidencySet>)set { [_queue4 removeResidencySet:set]; }
- (id<MTL4CommandAllocator>)takeAllocator {
  std::lock_guard<std::mutex> lock(_lock);
  id<MTL4CommandAllocator> a = _allocators.lastObject;
  if (a) { [_allocators removeLastObject]; return a; }
  return [_device newCommandAllocator];
}
- (id<MTL4CommandBuffer>)takeBuffer {
  std::lock_guard<std::mutex> lock(_lock);
  id<MTL4CommandBuffer> b = _buffers.lastObject;
  if (b) { [_buffers removeLastObject]; return b; }
  return [_device newCommandBuffer];
}
- (id<MTLResidencySet>)takeSet {
  std::lock_guard<std::mutex> lock(_lock);
  id<MTLResidencySet> s = _sets.lastObject;
  if (s) { [_sets removeLastObject]; return s; }
  MTLResidencySetDescriptor* d = [MTLResidencySetDescriptor new];
  d.initialCapacity = 2048;
  d.label = @"Liberty Metal 4 command buffer";
  return [_device newResidencySetWithDescriptor:d error:nil];
}
- (id<MTLBuffer>)takeChunk:(NSUInteger)minimum {
  std::lock_guard<std::mutex> lock(_lock);
  for (NSUInteger i = 0; i < _chunks.count; ++i)
    if (_chunks[i].length >= minimum) {
      id<MTLBuffer> c = _chunks[i];
      [_chunks removeObjectAtIndex:i];
      return c;
    }
  id<MTLBuffer> c = [_device newBufferWithLength:minimum options:MTLResourceStorageModeShared |
                                                              MTLResourceCPUCacheModeWriteCombined];
  c.label = @"Liberty Metal 4 transient";
  return c;
}
- (id<MTL4ArgumentTable>)takeTable {
  {
    std::lock_guard<std::mutex> lock(_lock);
    id<MTL4ArgumentTable> t = _tables.lastObject;
    if (t) { [_tables removeLastObject]; return t; }
  }
  MTL4ArgumentTableDescriptor* d = [MTL4ArgumentTableDescriptor new];
  d.maxBufferBindCount = 31;
  d.maxTextureBindCount = _tableTextures;
  d.maxSamplerStateBindCount = 16;
  d.initializeBindings = YES;
  return [_device newArgumentTableWithDescriptor:d error:nil];
}
- (void)giveTable:(id<MTL4ArgumentTable>)table {
  if (!table) return;
  std::lock_guard<std::mutex> lock(_lock);
  [_tables addObject:table];
}
- (void)persist:(id<MTLAllocation>)allocation {
  std::lock_guard<std::mutex> lock(_persistLock);
  auto [it, inserted] = _persisted.try_emplace((__bridge const void*)allocation);
  it->second.last = _commandBufferIndex;
  if (!inserted) return;
  it->second.allocation = allocation;
  [_persistent addAllocation:allocation];
  _persistDirty = true;
  ++_resident;
}
- (void)commitPersistent:(BOOL)evict {
  std::lock_guard<std::mutex> lock(_persistLock);
  // Every 64 command buffers: drop what has not been bound for a long time. It is far past
  // any command buffer in flight, and a later bind adds it again.
  if (evict && _commandBufferIndex % 64 == 0 && _commandBufferIndex > kPersistentIdleCommandBuffers) {
    const uint64_t oldest = _commandBufferIndex - kPersistentIdleCommandBuffers;
    for (auto it = _persisted.begin(); it != _persisted.end();) {
      if (it->second.last < oldest) {
        [_persistent removeAllocation:it->second.allocation];
        it = _persisted.erase(it);
        _persistDirty = true;
        ++_evicted;
      } else {
        ++it;
      }
    }
  }
  if (!_persistDirty) return;
  [_persistent commit];
  _persistDirty = false;
  ++_residencyCommits;
}
- (id<MTLCommandQueue>)side3 {
  std::lock_guard<std::mutex> lock(_lock);
  if (!_side3) {
    _side3 = [_device newCommandQueue];
    _side3.label = @"Liberty Metal 3 hop";
  }
  return _side3;
}
@end

namespace rex::ui::metal {

id<MTLCommandQueue> NewMetal4Queue(id<MTLDevice> device, std::string& error) {
  if (@available(macOS 26.0, *)) {
    if (![device supportsFamily:MTLGPUFamilyMetal4]) { error = "The GPU has no Metal 4 support."; return nil; }
    LXQueue* q = [LXQueue new];
    q->_device = device;
    const std::string barrier = REXCVAR_GET(gta4_metal4_render_barrier);
    q->_renderBarrier = barrier == "fragment" ? RenderBarrier::kFragment
                      : barrier == "tracked" ? RenderBarrier::kTracked : RenderBarrier::kFull;
    q->_renderBefore = q->_renderBarrier == RenderBarrier::kFragment ? MTLStageFragment : kRenderStages;
    MTL4CommandQueueDescriptor* descriptor = [MTL4CommandQueueDescriptor new];
    descriptor.label = @"Liberty Metal 4";
    q->_queue4 = [device newMTL4CommandQueueWithDescriptor:descriptor error:nil];
    if (!q->_queue4) { error = "Metal 4 command queue creation failed."; return nil; }
    q->_allocators = [NSMutableArray new]; q->_buffers = [NSMutableArray new];
    q->_sets = [NSMutableArray new]; q->_chunks = [NSMutableArray new]; q->_tables = [NSMutableArray new];
    // The largest texture table this device accepts, down to the Metal 3 per-stage limit.
    for (NSUInteger count : {128u, 96u, 64u, 31u}) {
      MTL4ArgumentTableDescriptor* d = [MTL4ArgumentTableDescriptor new];
      d.maxBufferBindCount = 31; d.maxTextureBindCount = count; d.maxSamplerStateBindCount = 16;
      if ([device newArgumentTableWithDescriptor:d error:nil]) { q->_tableTextures = count; break; }
    }
    if (!q->_tableTextures) { error = "Metal 4 argument table creation failed."; return nil; }
    if (REXCVAR_GET(gta4_metal4_residency) == "persistent") {
      MTLResidencySetDescriptor* d = [MTLResidencySetDescriptor new];
      d.initialCapacity = 8192;
      d.label = @"Liberty Metal 4 persistent";
      q->_persistent = [device newResidencySetWithDescriptor:d error:nil];
      if (!q->_persistent) { error = "Metal 4 persistent residency set creation failed."; return nil; }
      [q->_queue4 addResidencySet:q->_persistent];
      q->_persistentResidency = YES;
    }
    return q;
  }
  error = "Metal 4 needs macOS 26 or later.";
  return nil;
}
bool IsMetal4(id<MTLCommandQueue> queue) { return [(NSObject*)queue isKindOfClass:[LXQueue class]]; }
bool IsMetal4(id<MTLCommandBuffer> commands) { return [(NSObject*)commands isKindOfClass:[LXCommandBuffer class]]; }

void EncodeMetal3(id<MTLCommandBuffer> commands, void (^body)(id<MTLCommandBuffer>)) {
  if (IsMetal4(commands)) [(LXCommandBuffer*)commands hop:body];
  else body(commands);
}

bool EncodeMetal4(id<MTLCommandBuffer> commands, id<MTLFence> fence, NSArray<id<MTLResource>>* resources,
                  void (^body)(id<MTL4CommandBuffer>)) {
  if (!IsMetal4(commands)) return false;
  [(LXCommandBuffer*)commands native:fence resources:resources body:body];
  return true;
}

id<MTL4Compiler> Metal4Compiler(id<MTLCommandQueue> queue) {
  if (!IsMetal4(queue)) return nil;
  LXQueue* q = (LXQueue*)queue;
  std::lock_guard<std::mutex> lock(q->_lock);
  if (!q->_compiler) q->_compiler = [q->_device newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:nil];
  return q->_compiler;
}

void AddLayerResidency(id<MTLCommandQueue> queue, CAMetalLayer* layer) {
  if (!IsMetal4(queue) || !layer) return;
  if (@available(macOS 26.0, *)) [((LXQueue*)queue)->_queue4 addResidencySet:layer.residencySet];
}

Metal4Statistics Metal4StatisticsOf(id<MTLCommandQueue> queue) {
  Metal4Statistics s;
  if (!IsMetal4(queue)) return s;
  LXQueue* q = (LXQueue*)queue;
  s.command_buffers = q->_commandBuffers; s.parts = q->_parts; s.encoders = q->_encoders;
  s.barriers = q->_barriers; s.transient_bytes = q->_transient; s.resident = q->_resident; s.metal3_hops = q->_hops;
  s.binds = q->_binds; s.bind_hits = q->_bindHits; s.fragment_barriers = q->_fragmentBarriers;
  s.vertex_barriers = q->_vertexBarriers; s.evicted = q->_evicted; s.residency_commits = q->_residencyCommits;
  return s;
}

}  // namespace rex::ui::metal
