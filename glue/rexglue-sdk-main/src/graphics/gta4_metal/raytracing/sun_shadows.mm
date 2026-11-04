#include "sun_shadows.h"
#include "raytracing.h"
#include "metal_raytracing_library.h"
#include <rex/cvar.h>
#include <rex/logging.h>
#include <simd/simd.h>
#include <algorithm>
#include <cstring>
#include <unordered_map>

REXCVAR_DEFINE_STRING(gta4_metal_raytracing_shadow_view, "combine", "GPU",
    "Ray-traced sun shadows: combine (min with the shadow cascade), replace (traced only), "
    "show (traced visibility in grey) or none (trace only)");
REXCVAR_DEFINE_DOUBLE(gta4_metal_raytracing_shadow_angle, 0.5, "GPU",
    "Ray-traced sun shadows: angular radius of the sun in degrees (penumbra softness; 0 = hard)")
    .range(0.0, 5.0);
REXCVAR_DEFINE_DOUBLE(gta4_metal_raytracing_shadow_distance, 250.0, "GPU",
    "Ray-traced sun shadows: how far towards the sun a caster can be, in metres")
    .range(5.0, 2000.0);
REXCVAR_DEFINE_BOOL(gta4_metal_raytracing_shadow_foliage, false, "GPU",
    "Ray-traced sun shadows: alpha-tested geometry (foliage, fences) casts as solid triangles too");

namespace rex::graphics::gta4_metal::raytracing {

// Must match RtShadowParams in shaders/rtao.metal.
struct RtShadowParams {
  simd_float4 to_sun = {0, 0, 1, 0};  // xyz unit direction towards the sun, w 1 when there is one
  float cone_tangent = 0.0f, max_distance = 250.0f;
  uint32_t mask = kInstanceMaskOpaque;
  float replace = 0.0f;
};
static_assert(sizeof(RtShadowParams) == 32 && offsetof(RtShadowParams, cone_tangent) == 16 &&
              offsetof(RtShadowParams, mask) == 24);

ShadowSettings CurrentShadowSettings() {
  ShadowSettings settings;
  settings.view = ParseShadowView(rex::cvar::GetFlagByName("gta4_metal_raytracing_shadow_view"));
  settings.cone_tangent = ConeTangent(rex::cvar::Query<double>("gta4_metal_raytracing_shadow_angle"));
  settings.max_distance = float(rex::cvar::Query<double>("gta4_metal_raytracing_shadow_distance"));
  settings.foliage = rex::cvar::Query<bool>("gta4_metal_raytracing_shadow_foliage");
  settings.normal_mode = CurrentAoSettings().normal_mode;
  return settings;
}

namespace {
id<MTLTexture> Texture(id<MTLDevice> device, MTLPixelFormat format, NSUInteger width, NSUInteger height,
                       NSString* label) {
  auto* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height
                                                                    mipmapped:NO];
  descriptor.storageMode = MTLStorageModePrivate;
  descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
  id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
  texture.label = label;
  return texture;
}
void Dispatch(id<MTLComputeCommandEncoder> e, id<MTLComputePipelineState> pipeline, NSUInteger width,
              NSUInteger height) {
  const NSUInteger w = pipeline.threadExecutionWidth;
  const NSUInteger h = std::max<NSUInteger>(1, pipeline.maxTotalThreadsPerThreadgroup / w);
  [e dispatchThreads:MTLSizeMake(width, height, 1) threadsPerThreadgroup:MTLSizeMake(w, std::min<NSUInteger>(h, 8), 1)];
}
}  // namespace

struct SunShadows::Impl {
  id<MTLDevice> device = nil;
  id<MTLLibrary> library = nil;
  id<MTLComputePipelineState> trace = nil, temporal = nil, atrous = nil, upsample = nil, stats = nil;
  id<MTLTexture> no_normals = nil, no_motion = nil;
  // Trace size: raw (r visibility, g view distance), two histories, one filter output.
  id<MTLTexture> raw = nil, history[2] = {nil, nil}, filtered = nil, shadow = nil;
  NSUInteger width = 0, height = 0;
  uint32_t current = 0;
  bool history_valid = false;
  uint64_t frames = 0;
  CpuTime encode_time;
  simd_float4x4 previous_clip_to_world = matrix_identity_float4x4;
  std::unordered_map<uint64_t, id<MTLRenderPipelineState>> show;  // by target format

  id<MTLComputePipelineState> Kernel(NSString* name, std::string& error) {
    id<MTLFunction> function = [library newFunctionWithName:name];
    if (!function) { error = std::string("ray-traced shadow kernel missing: ") + name.UTF8String; return nil; }
    NSError* native_error = nil;
    id<MTLComputePipelineState> state = [device newComputePipelineStateWithFunction:function error:&native_error];
    if (!state)
      error = std::string("ray-traced shadow kernel failed: ") + name.UTF8String + ": " +
              (native_error ? native_error.localizedDescription.UTF8String : "unknown");
    return state;
  }
  bool Resize(NSUInteger w, NSUInteger h) {
    if (w == width && h == height && shadow) return true;
    const NSUInteger tw = (w + 1) / 2, th = (h + 1) / 2;
    raw = Texture(device, MTLPixelFormatRG16Float, tw, th, @"Liberty RT shadow raw");
    for (int i = 0; i < 2; ++i) history[i] = Texture(device, MTLPixelFormatRGBA16Float, tw, th, @"Liberty RT shadow history");
    filtered = Texture(device, MTLPixelFormatRGBA16Float, tw, th, @"Liberty RT shadow filter");
    shadow = Texture(device, MTLPixelFormatRG16Float, w, h, @"Liberty RT shadow");
    width = w; height = h;
    history_valid = false;
    return raw && history[0] && history[1] && filtered && shadow;
  }
  id<MTLRenderPipelineState> ShowPipeline(MTLPixelFormat format, std::string& error) {
    if (auto found = show.find(uint64_t(format)); found != show.end()) return found->second;
    auto* descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.label = @"Liberty RT shadow show";
    descriptor.vertexFunction = [library newFunctionWithName:@"rtao_apply_vertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"rtao_apply_show"];  // grey from .r
    descriptor.colorAttachments[0].pixelFormat = format;
    descriptor.colorAttachments[0].writeMask = MTLColorWriteMaskRed | MTLColorWriteMaskGreen | MTLColorWriteMaskBlue;
    NSError* native_error = nil;
    id<MTLRenderPipelineState> state = [device newRenderPipelineStateWithDescriptor:descriptor error:&native_error];
    if (!state)
      error = std::string("ray-traced shadow show pipeline failed: ") +
              (native_error ? native_error.localizedDescription.UTF8String : "unknown");
    show[uint64_t(format)] = state;  // a failure is remembered too: no retry every frame
    return state;
  }
};

SunShadows::SunShadows() : impl_(std::make_unique<Impl>()) {}
SunShadows::~SunShadows() = default;
bool SunShadows::initialized() const { return impl_->upsample != nil; }
uint64_t SunShadows::traced_frames() const { return impl_->frames; }
const CpuTime& SunShadows::encode_time() const { return impl_->encode_time; }

bool SunShadows::Initialize(id<MTLDevice> device, std::string& error) {
  auto& s = *impl_;
  s.device = device;
  auto data = dispatch_data_create(kMetalRaytracingLibrary, sizeof(kMetalRaytracingLibrary), nullptr,
                                   DISPATCH_DATA_DESTRUCTOR_DEFAULT);
  NSError* native_error = nil;
  s.library = [device newLibraryWithData:data error:&native_error];
  if (!s.library) {
    error = native_error ? native_error.localizedDescription.UTF8String : "ray-traced shadow library creation failed";
    return false;
  }
  id<MTLComputePipelineState> upsample = nil;
  if (!(s.trace = s.Kernel(@"rtshadow_trace", error)) || !(s.temporal = s.Kernel(@"rtao_temporal", error)) ||
      !(s.atrous = s.Kernel(@"rtao_atrous", error)) || !(s.stats = s.Kernel(@"rtshadow_stats", error)) ||
      !(upsample = s.Kernel(@"rtshadow_upsample", error)))
    return false;
  s.no_normals = Texture(device, MTLPixelFormatRGBA8Unorm, 1, 1, @"Liberty RT shadow no normals");
  s.no_motion = Texture(device, MTLPixelFormatRG16Float, 1, 1, @"Liberty RT shadow no motion");
  if (!s.no_normals || !s.no_motion) { error = "ray-traced shadow texture allocation failed"; return false; }
  s.upsample = upsample;  // last: initialized() means every kernel is there
  return true;
}

id<MTLTexture> SunShadows::Encode(id<MTLCommandBuffer> commands, const AoFrame& frame,
                                  const std::optional<std::array<float, 3>>& towards_sun,
                                  const ShadowSettings& settings, std::string& error) {
  auto& s = *impl_;
  if (!s.upsample || !frame.scene || !frame.depth || frame.depth.sampleCount != 1) return nil;
  ScopedCpuTime timed(s.encode_time);
  if (!s.Resize(frame.depth.width, frame.depth.height)) { error = "ray-traced shadow texture allocation failed"; return nil; }

  RtaoParams p{};
  std::memcpy(&p.clip_to_world, frame.clip_to_world.data(), sizeof(p.clip_to_world));
  p.previous_world_to_clip = simd_inverse(s.previous_clip_to_world);
  p.camera_position = simd_make_float4(frame.camera_position[0], frame.camera_position[1], frame.camera_position[2], 1);
  p.input_size = simd_make_uint2(uint32_t(s.width), uint32_t(s.height));
  p.trace_size = simd_make_uint2(uint32_t(s.raw.width), uint32_t(s.raw.height));
  // Shadows move with cars, peds and the sun: a shorter history than the AO's.
  p.history_blend_minimum = 0.2f;
  p.depth_rejection = 0.05f;
  p.frame = uint32_t(s.frames);
  p.normal_mode = frame.normals ? settings.normal_mode : 0u;
  p.reversed_depth = frame.reversed_depth;
  p.jitter_ndc = simd_make_float2(frame.jitter_ndc[0], frame.jitter_ndc[1]);
  p.valid_history = s.history_valid && !frame.camera_cut && frame.motion;

  RtShadowParams sp;
  if (towards_sun) sp.to_sun = simd_make_float4((*towards_sun)[0], (*towards_sun)[1], (*towards_sun)[2], 1.0f);
  sp.cone_tangent = settings.cone_tangent;
  sp.max_distance = settings.max_distance;
  sp.mask = ShadowRayMask(settings.foliage);
  sp.replace = settings.view == ShadowView::kReplace ? 1.0f : 0.0f;
  const uint32_t previous = s.current, current = s.current ^ 1u;

  // One encoder per kernel: the Metal 4 proxy orders work at encoder boundaries.
  const auto pass = [&](NSString* label, id<MTLComputePipelineState> pipeline, NSUInteger w, NSUInteger h,
                        void (^bind)(id<MTLComputeCommandEncoder>)) {
    id<MTLComputeCommandEncoder> e = [commands computeCommandEncoder];
    if (!e) return false;
    e.label = label;
    [e setComputePipelineState:pipeline];
    [e setBytes:&p length:sizeof(p) atIndex:0];
    [e setBytes:&sp length:sizeof(sp) atIndex:2];
    bind(e);
    Dispatch(e, pipeline, w, h);
    [e endEncoding];
    return true;
  };
  const NSUInteger tw = s.raw.width, th = s.raw.height;
  id<MTLAccelerationStructure> scene = frame.scene;
  id<MTLHeap> structures = frame.structures;
  id<MTLTexture> depth = frame.depth, motion = frame.motion ? frame.motion : s.no_motion;
  id<MTLTexture> raw = s.raw, normals = frame.normals ? frame.normals : s.no_normals;
  id<MTLTexture> before = s.history[previous], now = s.history[current], filtered = s.filtered, shadow = s.shadow;
  const uint32_t step = 1;
  const uint32_t* step_pointer = &step;
  const bool ok =
      pass(@"Liberty RT shadow trace", s.trace, tw, th, ^(id<MTLComputeCommandEncoder> e) {
        // Instances name their structures by gpuResourceID: the heap must be resident too.
        if (structures) [e useHeap:structures];
        [e useResource:scene usage:MTLResourceUsageRead];
        [e setAccelerationStructure:scene atBufferIndex:1];
        [e setTexture:depth atIndex:0];
        [e setTexture:normals atIndex:1];
        [e setTexture:raw atIndex:2];
      }) &&
      pass(@"Liberty RT shadow temporal", s.temporal, tw, th, ^(id<MTLComputeCommandEncoder> e) {
        [e setTexture:raw atIndex:0];
        [e setTexture:motion atIndex:1];
        [e setTexture:before atIndex:2];
        [e setTexture:now atIndex:3];
      }) &&
      pass(@"Liberty RT shadow filter", s.atrous, tw, th, ^(id<MTLComputeCommandEncoder> e) {
        [e setBytes:step_pointer length:sizeof(uint32_t) atIndex:1];
        [e setTexture:now atIndex:0];
        [e setTexture:filtered atIndex:1];
      }) &&
      pass(@"Liberty RT shadow upsample", s.upsample, s.width, s.height, ^(id<MTLComputeCommandEncoder> e) {
        [e setTexture:filtered atIndex:0];
        [e setTexture:depth atIndex:1];
        [e setTexture:shadow atIndex:2];
      });
  if (!ok) { error = "ray-traced shadow compute encoder unavailable"; return nil; }

  // Statistics on frames 0, 1 and every 300th: where the sun is, how much is shadowed.
  if (s.frames < 2 || s.frames % 300 == 0) {
    id<MTLBuffer> stats = [s.device newBufferWithLength:32 * 4 options:MTLResourceStorageModeShared];
    if (!stats) { error = "ray-traced shadow statistics allocation failed"; return nil; }
    std::memset(stats.contents, 0, stats.length);
    const bool counted = pass(@"Liberty RT shadow stats", s.stats, tw, th, ^(id<MTLComputeCommandEncoder> e) {
      [e setBuffer:stats offset:0 atIndex:3];
      [e setBuffer:stats offset:64 atIndex:4];
      [e setTexture:depth atIndex:0];
      [e setTexture:normals atIndex:1];
      [e setTexture:raw atIndex:2];
      [e setTexture:shadow atIndex:3];
    });
    if (!counted) { error = "ray-traced shadow statistics encoder unavailable"; return nil; }
    const uint64_t traced = s.frames;
    const auto sun = sp.to_sun;
    const float cone = sp.cone_tangent, distance = sp.max_distance;
    const uint32_t mask = sp.mask, normal_mode = p.normal_mode;
    const auto view = settings.view;
    [commands addCompletedHandler:^(id<MTLCommandBuffer>) {
      const auto* u = static_cast<const uint32_t*>(stats.contents);
      const auto* f = static_cast<const float*>(stats.contents) + 16;
      const double traced_pixels = std::max(1u, u[0]);
      REXLOG_INFO("gta4-metal-raytracing-shadow-stats: frame={} pixels={} sky={} facing-away={} shadowed-raw={} "
          "shadowed-fraction={:.3f} visibility-mean={:.3f} mean-n-dot-sun={:.3f} towards-sun=({:.3f},{:.3f},{:.3f}) "
          "sun={} cone-tangent={:.4f} max-distance={} mask={} normal-mode={} view={}",
          traced, u[0], u[1], u[2], u[3], u[3] / traced_pixels, f[0] / std::max(1.0f, f[1]), f[2] / traced_pixels,
          sun.x, sun.y, sun.z, sun.w != 0.0f, cone, distance, mask, normal_mode, uint32_t(view));
    }];
  }
  std::memcpy(&s.previous_clip_to_world, frame.clip_to_world.data(), sizeof(s.previous_clip_to_world));
  s.current = current;
  s.history_valid = true;
  ++s.frames;
  return s.shadow;
}

bool SunShadows::Show(id<MTLCommandBuffer> commands, id<MTLTexture> target, id<MTLTexture> shadow, std::string& error) {
  auto& s = *impl_;
  if (!target || !shadow || target.width != shadow.width || target.height != shadow.height || target.sampleCount != 1)
    return true;
  id<MTLRenderPipelineState> pipeline = s.ShowPipeline(target.pixelFormat, error);
  if (!pipeline) return false;
  auto* pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = target;
  pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> e = [commands renderCommandEncoderWithDescriptor:pass];
  if (!e) { error = "ray-traced shadow show pass unavailable"; return false; }
  e.label = @"Liberty RT shadow show";
  [e setRenderPipelineState:pipeline];
  [e setFragmentTexture:shadow atIndex:0];
  [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
  [e endEncoding];
  return true;
}

void SunShadows::Reset() {
  auto& s = *impl_;
  s.raw = s.filtered = s.shadow = nil;
  s.history[0] = s.history[1] = nil;
  s.width = s.height = 0;
  s.history_valid = false;
  s.previous_clip_to_world = matrix_identity_float4x4;
}

}  // namespace rex::graphics::gta4_metal::raytracing
