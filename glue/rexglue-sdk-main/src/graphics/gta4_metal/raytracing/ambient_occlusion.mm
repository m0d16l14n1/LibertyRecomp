#include "ambient_occlusion.h"
#include "raytracing.h"
#include "metal_raytracing_library.h"
#include <rex/cvar.h>
#include <rex/logging.h>
#include <simd/simd.h>
#include <algorithm>
#include <cstring>
#include <unordered_map>

REXCVAR_DEFINE_STRING(gta4_metal_raytracing_ao_view, "apply", "GPU",
    "Ray-traced AO output: apply (darken the lit image), show (AO in grey instead of lighting), "
    "debug (r = world x / 10, g = hit within radius, b = long-ray hit distance) or none (trace only)");
REXCVAR_DEFINE_STRING(gta4_metal_raytracing_ao_normals, "gbuffer", "GPU",
    "Ray-traced AO surface normals: depth (reconstructed), gbuffer (GBufferTextureSampler1 rgb) or gbuffer-yx");
REXCVAR_DEFINE_DOUBLE(gta4_metal_raytracing_ao_radius, 2.0, "GPU", "Ray-traced AO ray length in metres")
    .range(0.25, 8.0);
REXCVAR_DEFINE_DOUBLE(gta4_metal_raytracing_ao_occlusion, 0.85, "GPU",
    "Ray-traced AO: how dark a contact hit is in the AO term (0-1)")
    .range(0.0, 1.0);
REXCVAR_DEFINE_DOUBLE(gta4_metal_raytracing_ao_strength, 0.6, "GPU",
    "Ray-traced AO: how much of the AO term darkens the lit image (0-1)")
    .range(0.0, 1.0);

namespace rex::graphics::gta4_metal::raytracing {

AoSettings CurrentAoSettings() {
  AoSettings settings;
  const auto view = rex::cvar::GetFlagByName("gta4_metal_raytracing_ao_view");
  settings.view = view == "show" ? AoView::kShow : view == "debug" ? AoView::kDebug
                : view == "none" ? AoView::kNone : view == "multiply" ? AoView::kMultiply : AoView::kApply;
  const auto normals = rex::cvar::GetFlagByName("gta4_metal_raytracing_ao_normals");
  settings.normal_mode = normals == "gbuffer" ? 1u : normals == "gbuffer-yx" ? 2u : 0u;
  settings.radius = float(rex::cvar::Query<double>("gta4_metal_raytracing_ao_radius"));
  settings.occlusion = float(rex::cvar::Query<double>("gta4_metal_raytracing_ao_occlusion"));
  settings.apply_strength = float(rex::cvar::Query<double>("gta4_metal_raytracing_ao_strength"));
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

struct AmbientOcclusion::Impl {
  id<MTLDevice> device = nil;
  id<MTLLibrary> library = nil;
  id<MTLComputePipelineState> trace = nil, temporal = nil, atrous = nil, upsample = nil;
  id<MTLComputePipelineState> debug_trace = nil, debug_ao = nil, debug_positions = nil;
  id<MTLTexture> debug = nil;  // trace size, see rtao_debug_trace
  id<MTLTexture> no_normals = nil, no_motion = nil;  // bound where the kernels take an unused input
  // Trace size: raw (r visibility, g view distance), two histories, a filter pair.
  id<MTLTexture> raw = nil, history[2] = {nil, nil}, filter[2] = {nil, nil}, ao = nil;
  NSUInteger width = 0, height = 0;
  uint32_t current = 0;
  bool history_valid = false;
  uint64_t frames = 0;
  CpuTime encode_time;
  simd_float4x4 previous_clip_to_world = matrix_identity_float4x4;
  std::unordered_map<uint64_t, id<MTLRenderPipelineState>> apply;  // (format << 2) | view

  id<MTLComputePipelineState> Kernel(NSString* name, std::string& error) {
    id<MTLFunction> function = [library newFunctionWithName:name];
    if (!function) { error = std::string("ray-traced AO kernel missing: ") + name.UTF8String; return nil; }
    NSError* native_error = nil;
    id<MTLComputePipelineState> state = [device newComputePipelineStateWithFunction:function error:&native_error];
    if (!state)
      error = std::string("ray-traced AO kernel failed: ") + name.UTF8String + ": " +
              (native_error ? native_error.localizedDescription.UTF8String : "unknown");
    return state;
  }
  bool Resize(NSUInteger w, NSUInteger h) {
    if (w == width && h == height && ao) return true;
    const NSUInteger tw = (w + 1) / 2, th = (h + 1) / 2;
    raw = Texture(device, MTLPixelFormatRG16Float, tw, th, @"Liberty RTAO raw");
    for (int i = 0; i < 2; ++i) {
      history[i] = Texture(device, MTLPixelFormatRGBA16Float, tw, th, @"Liberty RTAO history");
      filter[i] = Texture(device, MTLPixelFormatRGBA16Float, tw, th, @"Liberty RTAO filter");
    }
    ao = Texture(device, MTLPixelFormatR16Float, w, h, @"Liberty RTAO");
    debug = Texture(device, MTLPixelFormatRGBA16Float, tw, th, @"Liberty RTAO debug");
    width = w; height = h;
    history_valid = false;
    return raw && history[0] && history[1] && filter[0] && filter[1] && ao && debug;
  }
  id<MTLRenderPipelineState> ApplyPipeline(MTLPixelFormat format, AoView view, std::string& error) {
    if (view == AoView::kMultiply) view = AoView::kApply;  // the same multiply pipeline
    const bool show = view == AoView::kShow || view == AoView::kDebug;
    const uint64_t key = uint64_t(format) << 2 | uint64_t(view);
    if (auto found = apply.find(key); found != apply.end()) return found->second;
    auto* descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.label = show ? @"Liberty RTAO show" : @"Liberty RTAO apply";
    descriptor.vertexFunction = [library newFunctionWithName:@"rtao_apply_vertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:view == AoView::kDebug ? @"rtao_apply_debug"
                                                              : show ? @"rtao_apply_show" : @"rtao_apply_multiply"];
    auto* color = descriptor.colorAttachments[0];
    color.pixelFormat = format;
    color.writeMask = MTLColorWriteMaskRed | MTLColorWriteMaskGreen | MTLColorWriteMaskBlue;
    if (!show) {
      color.blendingEnabled = YES;  // dst * src
      color.sourceRGBBlendFactor = MTLBlendFactorDestinationColor;
      color.destinationRGBBlendFactor = MTLBlendFactorZero;
      color.rgbBlendOperation = MTLBlendOperationAdd;
    }
    NSError* native_error = nil;
    id<MTLRenderPipelineState> state = [device newRenderPipelineStateWithDescriptor:descriptor error:&native_error];
    if (!state)
      error = std::string("ray-traced AO apply pipeline failed: ") +
              (native_error ? native_error.localizedDescription.UTF8String : "unknown");
    apply[key] = state;  // a failure is remembered too: no retry every frame
    return state;
  }
};

AmbientOcclusion::AmbientOcclusion() : impl_(std::make_unique<Impl>()) {}
AmbientOcclusion::~AmbientOcclusion() = default;
bool AmbientOcclusion::initialized() const { return impl_->upsample != nil; }
uint64_t AmbientOcclusion::traced_frames() const { return impl_->frames; }
const CpuTime& AmbientOcclusion::encode_time() const { return impl_->encode_time; }

bool AmbientOcclusion::Initialize(id<MTLDevice> device, std::string& error) {
  auto& s = *impl_;
  s.device = device;
  auto data = dispatch_data_create(kMetalRaytracingLibrary, sizeof(kMetalRaytracingLibrary), nullptr,
                                   DISPATCH_DATA_DESTRUCTOR_DEFAULT);
  NSError* native_error = nil;
  s.library = [device newLibraryWithData:data error:&native_error];
  if (!s.library) {
    error = native_error ? native_error.localizedDescription.UTF8String : "ray-traced AO library creation failed";
    return false;
  }
  if (!(s.trace = s.Kernel(@"rtao_trace", error)) || !(s.temporal = s.Kernel(@"rtao_temporal", error)) ||
      !(s.atrous = s.Kernel(@"rtao_atrous", error)) || !(s.upsample = s.Kernel(@"rtao_upsample", error)) ||
      !(s.debug_trace = s.Kernel(@"rtao_debug_trace", error)) || !(s.debug_ao = s.Kernel(@"rtao_debug_ao", error)) ||
      !(s.debug_positions = s.Kernel(@"rtao_debug_positions", error)))
    return false;
  s.no_normals = Texture(device, MTLPixelFormatRGBA8Unorm, 1, 1, @"Liberty RTAO no normals");
  s.no_motion = Texture(device, MTLPixelFormatRG16Float, 1, 1, @"Liberty RTAO no motion");
  if (!s.no_normals || !s.no_motion) { error = "ray-traced AO texture allocation failed"; return false; }
  return true;
}

id<MTLTexture> AmbientOcclusion::Encode(id<MTLCommandBuffer> commands, const AoFrame& frame,
                                        const AoSettings& settings, std::string& error) {
  auto& s = *impl_;
  if (!s.upsample || !frame.scene || !frame.depth || frame.depth.sampleCount != 1) return nil;
  ScopedCpuTime timed(s.encode_time);
  if (!s.Resize(frame.depth.width, frame.depth.height)) { error = "ray-traced AO texture allocation failed"; return nil; }

  RtaoParams p{};
  std::memcpy(&p.clip_to_world, frame.clip_to_world.data(), sizeof(p.clip_to_world));
  p.previous_world_to_clip = simd_inverse(s.previous_clip_to_world);
  p.camera_position = simd_make_float4(frame.camera_position[0], frame.camera_position[1], frame.camera_position[2], 1);
  p.input_size = simd_make_uint2(uint32_t(s.width), uint32_t(s.height));
  p.trace_size = simd_make_uint2(uint32_t(s.raw.width), uint32_t(s.raw.height));
  p.radius = settings.radius;
  p.strength = settings.occlusion;
  p.frame = uint32_t(s.frames);
  p.normal_mode = frame.normals ? settings.normal_mode : 0u;
  p.reversed_depth = frame.reversed_depth;
  p.jitter_ndc = simd_make_float2(frame.jitter_ndc[0], frame.jitter_ndc[1]);
  p.valid_history = s.history_valid && !frame.camera_cut && frame.motion;
  const uint32_t previous = s.current, current = s.current ^ 1u;

  // One encoder per kernel: each reads the last one's output, and the Metal 4 proxy
  // orders work at encoder boundaries (dispatches inside one MTL4 encoder are not).
  const auto pass = [&](NSString* label, id<MTLComputePipelineState> pipeline, NSUInteger w, NSUInteger h,
                        void (^bind)(id<MTLComputeCommandEncoder>)) {
    id<MTLComputeCommandEncoder> e = [commands computeCommandEncoder];
    if (!e) return false;
    e.label = label;
    [e setComputePipelineState:pipeline];
    [e setBytes:&p length:sizeof(p) atIndex:0];
    bind(e);
    Dispatch(e, pipeline, w, h);
    [e endEncoding];
    return true;
  };
  const NSUInteger tw = s.raw.width, th = s.raw.height;
  id<MTLAccelerationStructure> scene = frame.scene;
  id<MTLHeap> structures = frame.structures;
  id<MTLTexture> depth = frame.depth, motion = frame.motion ? frame.motion : s.no_motion;
  id<MTLTexture> raw = s.raw, normals = frame.normals ? frame.normals : s.no_normals, before = s.history[previous], now = s.history[current];
  id<MTLTexture> f0 = s.filter[0], f1 = s.filter[1], ao = s.ao;
  const uint32_t steps[2] = {1, 2};
  const uint32_t* step = steps;
  const bool ok =
      pass(@"Liberty RTAO trace", s.trace, tw, th, ^(id<MTLComputeCommandEncoder> e) {
        // Instances name their structures by gpuResourceID: the heap must be resident too.
        if (structures) [e useHeap:structures];
        [e useResource:scene usage:MTLResourceUsageRead];
        [e setAccelerationStructure:scene atBufferIndex:1];
        [e setTexture:depth atIndex:0];
        [e setTexture:normals atIndex:1];
        [e setTexture:raw atIndex:2];
      }) &&
      pass(@"Liberty RTAO temporal", s.temporal, tw, th, ^(id<MTLComputeCommandEncoder> e) {
        [e setTexture:raw atIndex:0];
        [e setTexture:motion atIndex:1];
        [e setTexture:before atIndex:2];
        [e setTexture:now atIndex:3];
      }) &&
      pass(@"Liberty RTAO filter 1", s.atrous, tw, th, ^(id<MTLComputeCommandEncoder> e) {
        [e setBytes:&step[0] length:sizeof(uint32_t) atIndex:1];
        [e setTexture:now atIndex:0];
        [e setTexture:f0 atIndex:1];
      }) &&
      pass(@"Liberty RTAO filter 2", s.atrous, tw, th, ^(id<MTLComputeCommandEncoder> e) {
        [e setBytes:&step[1] length:sizeof(uint32_t) atIndex:1];
        [e setTexture:f0 atIndex:0];
        [e setTexture:f1 atIndex:1];
      }) &&
      pass(@"Liberty RTAO upsample", s.upsample, s.width, s.height, ^(id<MTLComputeCommandEncoder> e) {
        [e setTexture:f1 atIndex:0];
        [e setTexture:depth atIndex:1];
        [e setTexture:ao atIndex:2];
      });
  if (!ok) { error = "ray-traced AO compute encoder unavailable"; return nil; }

  // Diagnostics: the debug view every frame; statistics on frames 0, 1 and every 300th.
  const bool statistics = s.frames < 2 || s.frames % 300 == 0;
  if (settings.view == AoView::kDebug || statistics) {
    // uints [0, 16), floats [16, 32); min starts at all ones.
    id<MTLBuffer> stats = [s.device newBufferWithLength:32 * 4 options:MTLResourceStorageModeShared];
    if (!stats) { error = "ray-traced AO statistics allocation failed"; return nil; }
    std::memset(stats.contents, 0, stats.length);
    static_cast<uint32_t*>(stats.contents)[5] = UINT32_MAX;
    id<MTLTexture> debug = s.debug;
    id<MTLBuffer> positions = frame.captured_positions;
    const uint32_t position_count = uint32_t(std::min<NSUInteger>(frame.captured_vertices, UINT32_MAX));
    const bool counted =
        pass(@"Liberty RTAO debug trace", s.debug_trace, tw, th, ^(id<MTLComputeCommandEncoder> e) {
          if (structures) [e useHeap:structures];
          [e useResource:scene usage:MTLResourceUsageRead];
          [e setAccelerationStructure:scene atBufferIndex:1];
          [e setBuffer:stats offset:0 atIndex:2];
          [e setBuffer:stats offset:64 atIndex:3];
          [e setTexture:depth atIndex:0];
          [e setTexture:normals atIndex:1];
          [e setTexture:debug atIndex:2];
        }) &&
        (!statistics ||
         (pass(@"Liberty RTAO debug ao", s.debug_ao, s.width, s.height, ^(id<MTLComputeCommandEncoder> e) {
            [e setBuffer:stats offset:0 atIndex:2];
            [e setBuffer:stats offset:64 atIndex:3];
            [e setTexture:ao atIndex:0];
          }) &&
          (!positions || !position_count ||
           pass(@"Liberty RTAO debug positions", s.debug_positions, position_count, 1, ^(id<MTLComputeCommandEncoder> e) {
             [e setBuffer:positions offset:0 atIndex:0];
             [e setBytes:&position_count length:sizeof(position_count) atIndex:1];
             [e setBuffer:stats offset:0 atIndex:2];
             [e setBuffer:stats offset:64 atIndex:3];
           }))));
    if (!counted) { error = "ray-traced AO diagnostics encoder unavailable"; return nil; }
    if (statistics) {
      const uint64_t traced = s.frames;
      const auto m = frame.clip_to_world;
      const auto camera = frame.camera_position;
      const auto jitter = frame.jitter_ndc;
      const bool reversed = frame.reversed_depth;
      const float radius = settings.radius;
      [commands addCompletedHandler:^(id<MTLCommandBuffer>) {
        const auto* u = static_cast<const uint32_t*>(stats.contents);
        const auto* f = static_cast<const float*>(stats.contents) + 16;
        float ao_min, ao_max;
        std::memcpy(&ao_min, &u[5], 4);
        std::memcpy(&ao_max, &u[6], 4);
        const double traced_pixels = std::max(1u, u[0]), positions_ok = std::max(1u, u[7]);
        REXLOG_INFO("gta4-metal-raytracing-ao-stats: frame={} traced={} sky={} bad-origin={} near-hits={} "
            "near-hits-under-10cm={} far-hits={} mean-near-distance={:.3f} mean-far-distance={:.2f} "
            "mean-view-distance={:.2f} radius={} ao-min={:.3f} ao-mean={:.3f} ao-max={:.3f} "
            "origin-mean=({:.1f},{:.1f},{:.1f}) captured-finite={} captured-nan={} captured-mean=({:.1f},{:.1f},{:.1f}) "
            "camera=({:.1f},{:.1f},{:.1f}) jitter=({:.5f},{:.5f}) reversed={} normal-agreement-rgb={:.3f} "
            "normal-agreement-grb={:.3f} clip-to-world-columns=[{}]",
            traced, u[0], u[1], u[2], u[3], u[10], u[4], f[9] / std::max(1u, u[3]), f[3] / std::max(1u, u[4]),
            f[4] / traced_pixels, radius, ao_min, f[5] / std::max(1u, u[9]), ao_max,
            f[0] / traced_pixels, f[1] / traced_pixels, f[2] / traced_pixels, u[7], u[8],
            f[6] / positions_ok, f[7] / positions_ok, f[8] / positions_ok, camera[0], camera[1], camera[2],
            jitter[0], jitter[1], reversed, f[10] / traced_pixels, f[11] / traced_pixels,
            fmt::format("{:.4g},{:.4g},{:.4g},{:.4g}, {:.4g},{:.4g},{:.4g},{:.4g}, {:.4g},{:.4g},{:.4g},{:.4g}, "
                        "{:.4g},{:.4g},{:.4g},{:.4g}", m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9],
                        m[10], m[11], m[12], m[13], m[14], m[15]));
      }];
    }
  }
  std::memcpy(&s.previous_clip_to_world, frame.clip_to_world.data(), sizeof(s.previous_clip_to_world));
  s.current = current;
  s.history_valid = true;
  ++s.frames;
  return s.ao;
}

bool AmbientOcclusion::Apply(id<MTLCommandBuffer> commands, id<MTLTexture> target, id<MTLTexture> ao,
                             const AoSettings& settings, std::string& error) {
  auto& s = *impl_;
  if (settings.view == AoView::kNone || !target || !ao || target.width != ao.width || target.height != ao.height ||
      target.sampleCount != 1)
    return true;
  const bool show = settings.view == AoView::kShow || settings.view == AoView::kDebug;
  id<MTLRenderPipelineState> pipeline = s.ApplyPipeline(target.pixelFormat, settings.view, error);
  if (!pipeline) return false;
  auto* pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = target;
  pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> e = [commands renderCommandEncoderWithDescriptor:pass];
  if (!e) { error = "ray-traced AO apply pass unavailable"; return false; }
  e.label = show ? @"Liberty RTAO show" : @"Liberty RTAO apply";
  [e setRenderPipelineState:pipeline];
  [e setFragmentTexture:settings.view == AoView::kDebug && s.debug ? s.debug : ao atIndex:0];
  const float strength = settings.apply_strength;
  if (!show) [e setFragmentBytes:&strength length:sizeof(strength) atIndex:0];
  [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
  [e endEncoding];
  return true;
}

void AmbientOcclusion::Reset() {
  auto& s = *impl_;
  s.raw = s.ao = s.debug = nil;
  s.history[0] = s.history[1] = s.filter[0] = s.filter[1] = nil;
  s.width = s.height = 0;
  s.history_valid = false;
  s.previous_clip_to_world = matrix_identity_float4x4;
}

}  // namespace rex::graphics::gta4_metal::raytracing
