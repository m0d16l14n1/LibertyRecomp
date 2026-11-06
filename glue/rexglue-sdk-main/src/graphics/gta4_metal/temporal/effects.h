#pragma once
#import <Metal/Metal.h>

#include <array>
#include <cmath>
#include <memory>
#include <string>

#include "history.h"

namespace rex::graphics::gta4_metal::temporal {
struct Inputs {
  // Linear, scene-only RGBA16Float; device depth R32Float; unjittered
  // current-to-previous RG16Float vectors in INPUT pixels; R8Unorm reactive.
  id<MTLTexture> color = nil, depth = nil, motion = nil, reactive = nil;
  // Native TAA only: expected previous device depth of the current surface,
  // R32Float at input resolution and registered to the jittered scene. -1 is
  // invalid, including unsupported nonstandard depth viewports. MetalFX ignores it.
  id<MTLTexture> previous_depth = nil;
  // Frame generation: RG16Float at input resolution, the rigid (body-only) motion of tyre pixels
  // (the draws' own motion elsewhere; 0 where nothing wrote it). The repair warps tyres with it.
  id<MTLTexture> rigid_motion = nil;
  // Optional GPU-produced 1x1 R16Float MetalFX exposure. Scalar Frame::exposure
  // remains the fallback for callers without a title exposure texture.
  id<MTLTexture> exposure = nil;
  // Denoised scaler only (Configuration::denoised), at input resolution: RGBA8Unorm diffuse and
  // specular albedo, RGBA16Float world normal, R16Float perceptual roughness. Missing guides
  // fall back to neutral ones (grey albedo, +Z normal, no specular, rough).
  id<MTLTexture> diffuse_albedo = nil, specular_albedo = nil, normal = nil, roughness = nil;
  // Column-major (simd) world-to-view and view-to-clip; the denoised scaler requires them.
  std::array<float, 16> world_to_view{}, view_to_clip{};
  // world_to_view/view_to_clip hold this frame's camera: frame interpolation passes them too
  // (gta4_metalfx_frame_generation_camera_matrices). False leaves the interpolator without them.
  bool camera_matrices = false;
  // Frame generation: output-pixel motion difference at which the discontinuity repair starts
  // (gta4_metalfx_frame_generation_repair_px; 0 off).
  float repair_motion_px = 0;
  // Frame generation: replace strongly reactive rigid wheel/ped deformation with a crisp
  // current-pose half-step warp instead of blending incompatible poses.
  bool deformation_repair = false;
  // Frame generation: unsharp amount for the generated image (gta4_metalfx_frame_generation_sharpen; 0 off).
  float sharpen = 0;
  // Frame generation: limit generated pixels to the colours of the real images they come from
  // (gta4_metalfx_frame_generation_source_clamp).
  bool source_clamp = false;
};
// Keep the lease through the LAST consumer submission. Holding it prevents
// output-slot recycling; KeepUntilCompleted transfers this duty to a command.
using OutputLease = std::shared_ptr<void>;
void KeepUntilCompleted(id<MTLCommandBuffer>, OutputLease);
struct Output {
  id<MTLTexture> color = nil;
  bool history_reset = true;
  OutputLease lease;
};
struct InterpolationOutput {
  id<MTLTexture> generated = nil, real = nil;
  bool history_reset = true;
  OutputLease lease;
};
enum class UiMode { kNone, kPremultipliedOverlay, kComposited };
struct UiInput {
  UiMode mode = UiMode::kNone;
  id<MTLTexture> image = nil;
  // kNone only: the caller overwrites every texel of the returned real image before anything
  // reads it (the HUD composition does), so the scene is not also copied there first.
  bool caller_writes_real = false;
};
struct Capabilities {
  bool temporal = false, interpolation = false;
  float minimum_scale = 1, maximum_scale = 1;
};
// The exact temporal contract presented to the AA implementation for the most
// recent Encode call. Kept CPU-only so live diagnostics and tests can inspect
// the contract without a GPU readback or changing effect behaviour.
struct AntiAliasingDiagnostic {
  bool valid = false, accepted = false, encoded = false, reset = true;
  bool metal4 = false, depth_reversed = false, exposure_texture = false;
  Method method = Method::kTaa;
  uint64_t sequence = 0;
  uint32_t input_width = 0, input_height = 0, output_width = 0, output_height = 0;
  std::array<float, 2> source_jitter{}, effective_jitter{}, motion_scale{1, 1};
  float near_plane = 0.1f, far_plane = 1000.0f, field_of_view = 60.0f, aspect = 1;
  float pre_exposure = 1, exposure = 1, delta_seconds = 0;
  std::string reason;
};
Capabilities QueryCapabilities(id<MTLDevice> device);
// MTL4FXTemporalDenoisedScaler: the device supports it on Metal 4 for this scale, and no creation
// has failed in this process (a failure latches: callers configure the plain scaler instead).
bool MetalFxDenoiserUsable(id<MTLDevice> device, uint32_t input_width, uint32_t input_height,
                           uint32_t output_width, uint32_t output_height);
// Diagnostic: negate the jitter MetalFX receives along x and/or y (gta4_metalfx_jitter_sign).
void SetMetalFxJitterSign(bool negate_x, bool negate_y);
// Includes device alignment, not just texel payload. Keeps each effect within
// a bounded share of the device's recommended working set while admitting 4K.
size_t OwnedTextureBudget(id<MTLDevice> device);
id<MTLLibrary> CreateLibrary(id<MTLDevice> device, std::string& error);
// Serialized by the title renderer. Uses its existing queue: no commit,
// waitUntilCompleted, global context, or second presentation scheduler here.
// Submit each accepted command buffer, or call Reset to abandon its history.
class AntiAliasing {
 public:
  AntiAliasing();
  ~AntiAliasing();
  AntiAliasing(const AntiAliasing&) = delete;
  AntiAliasing& operator=(const AntiAliasing&) = delete;
  bool Configure(id<MTLDevice>, id<MTLLibrary>, Configuration, size_t owned_texture_budget,
                 std::string&);
  bool Encode(id<MTLCommandBuffer>, const Inputs&, const Frame&, Output&, std::string&);
  void Reset();
  size_t owned_bytes() const;
  const AntiAliasingDiagnostic& diagnostic() const { return diagnostic_; }
  // A line for the caller to log (this library does not log): the denoised scaler's creation,
  // its creation failure, and its periodic statistics. Empty when there is none.
  std::string TakeNotice();

 private:
  struct State;
  std::unique_ptr<State> state_;
  AntiAliasingDiagnostic diagnostic_{};
  std::string notice_;
  id<MTLDevice> rejected_device_ = nil;
  id<MTLLibrary> rejected_library_ = nil;
  Configuration rejected_config_{};
  size_t rejected_budget_ = 0;
  std::string rejected_error_;
};
class FrameInterpolation {
 public:
  FrameInterpolation();
  ~FrameInterpolation();
  FrameInterpolation(const FrameInterpolation&) = delete;
  FrameInterpolation& operator=(const FrameInterpolation&) = delete;
  bool Configure(id<MTLDevice>, id<MTLLibrary>, Configuration, size_t owned_texture_budget,
                 std::string&);
  // Scene color is at output resolution; depth/motion retain input resolution.
  // UI is explicit: prefer a premultiplied overlay or draw it afterward.
  bool Encode(id<MTLCommandBuffer>, const Inputs&, UiInput, const Frame&, InterpolationOutput&,
              std::string&);
  void Reset();
  size_t owned_bytes() const;
  // Encodes on a Metal 4 queue through MTL4FX (native) and through the Metal 3 hop (Metal 3
  // queues, or a Metal 4 queue whose device has no MTL4FX interpolation).
  struct EncodeCounts { uint64_t native = 0, hop = 0; };
  EncodeCounts encode_counts() const;
  // A one-time note about the interpolator choice (native MTL4FX or the Metal 3 hop), for the
  // caller to log (this library does not link the logger); empty when there is none.
  std::string TakeNotice();

 private:
  struct State;
  std::unique_ptr<State> state_;
};
}  // namespace rex::graphics::gta4_metal::temporal
