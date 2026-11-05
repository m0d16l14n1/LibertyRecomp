#include "effects.h"
#import <MetalFX/MetalFX.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cstring>
#include <limits>
#include <string>
#include <utility>

#include "pass_tags.h"
#include "../../../ui/metal/metal4_queue.h"

namespace rex::graphics::gta4_metal::temporal {
namespace {
// Sign convention of the jitter handed to MetalFX (diagnostic): the renderer offsets the
// projection by (+2jx/W, -2jy/H) for a jitter (jx, jy) in input pixels (y down), as DLSS and
// FSR 2 take it. +1 passes a component unchanged. Set from gta4_metalfx_jitter_sign (live.mm):
// this library does not link the cvar registry.
std::atomic<uint32_t> g_jitter_sign_bits{0};  // bit 0: negate x, bit 1: negate y
std::array<float, 2> MetalFxJitter(const std::array<float, 2>& jitter) {
  const uint32_t bits = g_jitter_sign_bits.load(std::memory_order_relaxed);
  return {bits & 1 ? -jitter[0] : jitter[0], bits & 2 ? -jitter[1] : jitter[1]};
}
constexpr size_t kMaximumOwnedBytes = 1024u * 1024u * 1024u;
struct FailureState {
  std::atomic<uint64_t> count{0};
};
struct LeasedImages {
  id<MTLTexture> first = nil, second = nil;
};
void ObserveFailure(id<MTLCommandBuffer> commands, const std::shared_ptr<FailureState>& state) {
  [commands addCompletedHandler:^(id<MTLCommandBuffer> completed) {
    if (completed.status == MTLCommandBufferStatusError)
      state->count.fetch_add(1, std::memory_order_release);
  }];
}
bool Available(id<MTLCommandBuffer> owner) {
  return !owner || owner.status >= MTLCommandBufferStatusCompleted;
}
bool TextureMatches(id<MTLTexture> texture, id<MTLDevice> device, MTLPixelFormat format,
                    NSUInteger width, NSUInteger height, MTLTextureUsage usage) {
  return texture && texture.device == device && texture.textureType == MTLTextureType2D &&
         texture.pixelFormat == format && texture.width == width && texture.height == height &&
         texture.sampleCount == 1 && (texture.usage & usage) == usage &&
         texture.storageMode != MTLStorageModeMemoryless &&
         texture.hazardTrackingMode == MTLHazardTrackingModeTracked;
}
size_t AllocationSize(id<MTLDevice> device, MTLPixelFormat format, NSUInteger width,
                      NSUInteger height, MTLTextureUsage usage) {
  auto descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                       width:width
                                                                      height:height
                                                                   mipmapped:NO];
  descriptor.storageMode = MTLStorageModePrivate;
  descriptor.hazardTrackingMode = MTLHazardTrackingModeTracked;
  descriptor.usage = usage;
  return [device heapTextureSizeAndAlignWithDescriptor:descriptor].size;
}
id<MTLTexture> Allocate(id<MTLDevice> device, MTLPixelFormat format, NSUInteger width,
                        NSUInteger height, MTLTextureUsage usage, NSString* label, size_t limit,
                        size_t& owned, std::string& error) {
  auto descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                       width:width
                                                                      height:height
                                                                   mipmapped:NO];
  descriptor.storageMode = MTLStorageModePrivate;
  descriptor.hazardTrackingMode = MTLHazardTrackingModeTracked;
  descriptor.usage = usage;
  const auto predicted = [device heapTextureSizeAndAlignWithDescriptor:descriptor].size;
  if (owned > limit || predicted > limit - owned) {
    error = "temporal owned-texture budget exceeded";
    return nil;
  }
  auto image = [device newTextureWithDescriptor:descriptor];
  if (!image) {
    error = "temporal texture allocation failed";
    return nil;
  }
  if (image.allocatedSize > limit - owned) {
    error = "temporal allocation exceeds its budget";
    return nil;
  }
  owned += image.allocatedSize;
  image.label = label;
  return image;
}
bool CommonInputs(id<MTLCommandBuffer> commands, const Inputs& in, const Frame& f,
                  id<MTLDevice> device, const Configuration& c, bool interpolation,
                  std::string& error) {
  if (!commands || commands.commandQueue.device != device ||
      commands.status != MTLCommandBufferStatusNotEnqueued || !commands.retainedReferences) {
    error = "temporal work requires an uncommitted retained command buffer on its device";
    return false;
  }
  const uint32_t cw = interpolation ? c.output_width : c.input_width,
                 ch = interpolation ? c.output_height : c.input_height;
  if (!TextureMatches(in.color, device, MTLPixelFormatRGBA16Float, cw, ch,
                      MTLTextureUsageShaderRead) ||
      !TextureMatches(in.depth, device, MTLPixelFormatR32Float, c.input_width, c.input_height,
                      MTLTextureUsageShaderRead) ||
      !TextureMatches(in.motion, device, MTLPixelFormatRG16Float, c.input_width, c.input_height,
                      MTLTextureUsageShaderRead) ||
      (!interpolation && !TextureMatches(in.reactive, device, MTLPixelFormatR8Unorm, c.input_width,
                                         c.input_height, MTLTextureUsageShaderRead)) ||
      (!interpolation && c.method == Method::kTaa &&
       !TextureMatches(in.previous_depth, device, MTLPixelFormatR32Float,
                       c.input_width, c.input_height, MTLTextureUsageShaderRead)) ||
      (!interpolation && c.method == Method::kMetalFx && in.exposure &&
       !TextureMatches(in.exposure, device, MTLPixelFormatR16Float, 1, 1,
                       MTLTextureUsageShaderRead))) {
    error = "temporal input device, extent, format, usage or tracking mismatch";
    return false;
  }
  if (in.color == in.depth || in.color == in.motion || in.depth == in.motion) {
    error = "temporal input aspects alias";
    return false;
  }
  if (!std::isfinite(f.aspect) || f.aspect <= 0) {
    error = "temporal projection aspect must be finite and positive";
    return false;
  }
  return true;
}
struct alignas(16) TaaConstants {
  std::array<uint32_t, 2> extent{};
  std::array<float, 2> jitter{};
  float near_plane = 0.1f, far_plane = 1000.0f, history_weight = 0.9f, previous_pre_exposure = 1;
  float current_pre_exposure = 1;
  uint32_t reset = 1, reversed = 0, padding = 0;
  float previous_near_plane = 0.1f, previous_far_plane = 1000.0f;
  std::array<float, 2> padding2{};
};
static_assert(sizeof(TaaConstants) == 4 * 16);
bool Copy(id<MTLBlitCommandEncoder> encoder, id<MTLTexture> source, id<MTLTexture> destination) {
  if (!encoder || !source || !destination || source == destination ||
      source.width != destination.width || source.height != destination.height ||
      source.pixelFormat != destination.pixelFormat)
    return false;
  [encoder copyFromTexture:source
               sourceSlice:0
               sourceLevel:0
              sourceOrigin:MTLOriginMake(0, 0, 0)
                sourceSize:MTLSizeMake(source.width, source.height, 1)
                 toTexture:destination
          destinationSlice:0
          destinationLevel:0
         destinationOrigin:MTLOriginMake(0, 0, 0)];
  return true;
}
}  // namespace
namespace {
std::atomic<ComputePassTagger> g_compute_tagger{nullptr};
std::atomic<BlitPassTagger> g_blit_tagger{nullptr};
}  // namespace
void SetMetalFxJitterSign(bool negate_x, bool negate_y) {
  g_jitter_sign_bits.store((negate_x ? 1u : 0u) | (negate_y ? 2u : 0u), std::memory_order_relaxed);
}
void SetPassTaggers(ComputePassTagger compute, BlitPassTagger blit) {
  g_compute_tagger.store(compute, std::memory_order_release);
  g_blit_tagger.store(blit, std::memory_order_release);
}
ComputePassTagger CurrentComputePassTagger() { return g_compute_tagger.load(std::memory_order_acquire); }
BlitPassTagger CurrentBlitPassTagger() { return g_blit_tagger.load(std::memory_order_acquire); }
void KeepUntilCompleted(id<MTLCommandBuffer> commands, OutputLease lease) {
  if (!commands || !lease) return;
  // Release at completion, not when a retained command-buffer/capture object
  // eventually destroys its handler. Keeping a completed command alive must
  // not pin a bounded temporal output slot indefinitely.
  auto held = std::make_shared<OutputLease>(std::move(lease));
  [commands addCompletedHandler:^(id<MTLCommandBuffer>) {
    held->reset();
  }];
}
Capabilities QueryCapabilities(id<MTLDevice> device) {
  if (!device) return {};
  return {[MTLFXTemporalScalerDescriptor supportsDevice:device] != NO,
          [MTLFXFrameInterpolatorDescriptor supportsDevice:device] != NO,
          [MTLFXTemporalScalerDescriptor supportedInputContentMinScaleForDevice:device],
          [MTLFXTemporalScalerDescriptor supportedInputContentMaxScaleForDevice:device]};
}
std::atomic<bool> g_denoiser_failed{false};
bool MetalFxDenoiserUsable(id<MTLDevice> device, uint32_t iw, uint32_t ih, uint32_t ow, uint32_t oh) {
  if (!device || !iw || !ih || g_denoiser_failed.load(std::memory_order_relaxed) ||
      ![MTLFXTemporalDenoisedScalerDescriptor supportsMetal4FX:device])
    return false;
  const float minimum = [MTLFXTemporalDenoisedScalerDescriptor supportedInputContentMinScaleForDevice:device],
              maximum = [MTLFXTemporalDenoisedScalerDescriptor supportedInputContentMaxScaleForDevice:device];
  const float sx = float(ow) / iw, sy = float(oh) / ih;
  return sx >= minimum && sy >= minimum && sx <= maximum && sy <= maximum;
}
struct AntiAliasing::State {
  struct Slot {
    id<MTLTexture> color = nil, depth = nil, exposure = nil;
    __weak id<MTLCommandBuffer> owner = nil;
    std::weak_ptr<void> lease;
  };
  id<MTLDevice> device = nil;
  id<MTLCommandQueue> queue = nil;
  Configuration config{};
  History history;
  id<MTLFXTemporalScaler> scaler = nil;
  // Metal 4 queue: the same scaler as MTL4FX, made at the first Metal 4 encode.
  MTLFXTemporalScalerDescriptor* scaler_descriptor = nil;
  id<MTL4FXTemporalScaler> scaler4 = nil;
  id<MTLFence> scaler_fence = nil;
  // Configuration::denoised: made at the first (Metal 4) encode, with neutral guides for frames
  // that bring none.
  MTLFXTemporalDenoisedScalerDescriptor* denoiser_descriptor = nil;
  id<MTL4FXTemporalDenoisedScaler> denoiser4 = nil;
  id<MTLFence> denoiser_fence = nil;
  id<MTLTexture> neutral_diffuse = nil, neutral_specular = nil, neutral_normal = nil, neutral_roughness = nil;
  bool neutral_cleared = false;
  uint64_t denoised_frames = 0, neutral_guide_frames = 0;
  id<MTLComputePipelineState> taa = nil;
  std::array<Slot, 3> slots{};
  size_t cursor = 0, previous = 0, owned = 0, limit = 0;
  std::shared_ptr<FailureState> failures = std::make_shared<FailureState>();
  uint64_t seen_failure = 0;
};
AntiAliasing::AntiAliasing() = default;
AntiAliasing::~AntiAliasing() = default;
size_t OwnedTextureBudget(id<MTLDevice> device) {
  return device ? std::min<size_t>(kMaximumOwnedBytes, device.recommendedMaxWorkingSetSize / 4)
                : 0;
}
void AntiAliasing::Reset() {
  if (state_) state_->history.Reset();
}
size_t AntiAliasing::owned_bytes() const { return state_ ? state_->owned : 0; }
std::string AntiAliasing::TakeNotice() { return std::exchange(notice_, std::string()); }
bool AntiAliasing::Configure(id<MTLDevice> device, id<MTLLibrary> library, Configuration c,
                             size_t budget, std::string& error) {
  @autoreleasepool {
    error.clear();
    budget = std::min(budget, kMaximumOwnedBytes);
    if (!device || !ValidConfiguration(c) || !budget) {
      error = "invalid temporal AA configuration";
      return false;
    }
    if (state_ && state_->device == device && state_->config == c && state_->limit == budget)
      return true;
    if (!rejected_error_.empty() && rejected_device_ == device && rejected_library_ == library &&
        rejected_config_ == c && rejected_budget_ == budget) {
      error = rejected_error_;
      return false;
    }
    // History reset does not make an unsupported configuration or an
    // insufficient history budget possible. Transient driver/allocation
    // failures remain retryable after memory pressure subsides.
    bool permanent_rejection = false;
    const bool configured = [&]() {
    auto next = std::make_unique<State>();
    next->device = device;
    next->config = c;
    next->limit = budget;
    MTLTextureUsage output_usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    if (c.denoised) {
      if (!MetalFxDenoiserUsable(device, c.input_width, c.input_height, c.output_width, c.output_height)) {
        permanent_rejection = true;
        error = "MetalFX Metal 4 denoised scaler is unsupported for this device or scale";
        return false;
      }
      auto descriptor = [MTLFXTemporalDenoisedScalerDescriptor new];
      descriptor.inputWidth = c.input_width;
      descriptor.inputHeight = c.input_height;
      descriptor.outputWidth = c.output_width;
      descriptor.outputHeight = c.output_height;
      descriptor.colorTextureFormat = MTLPixelFormatRGBA16Float;
      descriptor.depthTextureFormat = MTLPixelFormatR32Float;
      descriptor.motionTextureFormat = MTLPixelFormatRG16Float;
      descriptor.diffuseAlbedoTextureFormat = MTLPixelFormatRGBA8Unorm;
      descriptor.specularAlbedoTextureFormat = MTLPixelFormatRGBA8Unorm;
      descriptor.normalTextureFormat = MTLPixelFormatRGBA16Float;
      descriptor.roughnessTextureFormat = MTLPixelFormatR16Float;
      descriptor.outputTextureFormat = MTLPixelFormatRGBA16Float;
      descriptor.reactiveMaskTextureEnabled = YES;
      descriptor.reactiveMaskTextureFormat = MTLPixelFormatR8Unorm;
      descriptor.autoExposureEnabled = NO;
      descriptor.requiresSynchronousInitialization = YES;
      next->denoiser_descriptor = descriptor;
      // The scaler's own usage is known only once it exists (first encode): cover what MetalFX
      // outputs need, and check at encode.
      output_usage |= MTLTextureUsageRenderTarget;
      const MTLTextureUsage guide_usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
      next->neutral_diffuse = Allocate(device, MTLPixelFormatRGBA8Unorm, c.input_width, c.input_height, guide_usage,
                                       @"Liberty denoise neutral albedo", budget, next->owned, error);
      next->neutral_specular = next->neutral_diffuse ? Allocate(device, MTLPixelFormatRGBA8Unorm, c.input_width,
          c.input_height, guide_usage, @"Liberty denoise neutral specular", budget, next->owned, error) : nil;
      next->neutral_normal = next->neutral_specular ? Allocate(device, MTLPixelFormatRGBA16Float, c.input_width,
          c.input_height, guide_usage, @"Liberty denoise neutral normal", budget, next->owned, error) : nil;
      next->neutral_roughness = next->neutral_normal ? Allocate(device, MTLPixelFormatR16Float, c.input_width,
          c.input_height, guide_usage, @"Liberty denoise neutral roughness", budget, next->owned, error) : nil;
      if (!next->neutral_roughness) return false;
    } else if (c.method == Method::kMetalFx) {
      const auto caps = QueryCapabilities(device);
      const float sx = float(c.output_width) / c.input_width,
                  sy = float(c.output_height) / c.input_height;
      if (!caps.temporal || sx < caps.minimum_scale || sy < caps.minimum_scale ||
          sx > caps.maximum_scale || sy > caps.maximum_scale) {
        permanent_rejection = true;
        error = "MetalFX temporal scale is unsupported by this device";
        return false;
      }
      auto descriptor = [MTLFXTemporalScalerDescriptor new];
      descriptor.inputWidth = c.input_width;
      descriptor.inputHeight = c.input_height;
      descriptor.outputWidth = c.output_width;
      descriptor.outputHeight = c.output_height;
      descriptor.colorTextureFormat = MTLPixelFormatRGBA16Float;
      descriptor.depthTextureFormat = MTLPixelFormatR32Float;
      descriptor.motionTextureFormat = MTLPixelFormatRG16Float;
      descriptor.outputTextureFormat = MTLPixelFormatRGBA16Float;
      descriptor.reactiveMaskTextureEnabled = YES;
      descriptor.reactiveMaskTextureFormat = MTLPixelFormatR8Unorm;
      descriptor.autoExposureEnabled = NO;
      descriptor.requiresSynchronousInitialization = YES;
      next->scaler = [descriptor newTemporalScalerWithDevice:device];
      next->scaler_descriptor = descriptor;
      if (!next->scaler) {
        error = "MetalFX temporal scaler creation failed";
        return false;
      }
      output_usage |= next->scaler.outputTextureUsage;
    } else {
      if (!library || library.device != device) {
        permanent_rejection = true;
        error = "native TAA requires its compiled shader library";
        return false;
      }
      NSError* native_error = nil;
      auto function = [library newFunctionWithName:@"liberty_temporal_aa"];
      if (!function) {
        permanent_rejection = true;
        error = "native TAA entry point is missing";
        return false;
      }
      next->taa = [device newComputePipelineStateWithFunction:function error:&native_error];
      if (!next->taa) {
        error = native_error.localizedDescription.UTF8String;
        return false;
      }
    }
    size_t required = 0;
    for (size_t i = 0; i < next->slots.size(); ++i) {
      const auto add = [&](MTLPixelFormat format, NSUInteger width, NSUInteger height,
                           MTLTextureUsage usage) {
        const size_t bytes = AllocationSize(device, format, width, height, usage);
        if (!bytes || required > budget || bytes > budget - required) return false;
        required += bytes;
        return true;
      };
      if (!add(MTLPixelFormatRGBA16Float, c.output_width, c.output_height, output_usage) ||
          (c.method == Method::kTaa &&
           !add(MTLPixelFormatR32Float, c.output_width, c.output_height,
                MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite)) ||
          (c.method == Method::kMetalFx &&
           !add(MTLPixelFormatR16Float, 1, 1, MTLTextureUsageShaderRead))) {
        error = "temporal owned-texture budget cannot hold complete history";
        permanent_rejection = true;
        return false;
      }
    }
    for (auto& slot : next->slots) {
      slot.color =
          Allocate(device, MTLPixelFormatRGBA16Float, c.output_width, c.output_height, output_usage,
                   @"Liberty temporal AA history", budget, next->owned, error);
      if (!slot.color) return false;
      if (c.method == Method::kMetalFx) {
        slot.exposure = Allocate(device, MTLPixelFormatR16Float, 1, 1, MTLTextureUsageShaderRead,
                                 @"Liberty tone-map exposure hint", budget, next->owned, error);
        if (!slot.exposure) return false;
      }
      if (c.method == Method::kTaa) {
        slot.depth = Allocate(device, MTLPixelFormatR32Float, c.output_width, c.output_height,
                              MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite,
                              @"Liberty TAA history depth", budget, next->owned, error);
        if (!slot.depth) return false;
      }
    }
    state_ = std::move(next);
    return true;
    }();
    if (configured) {
      rejected_error_.clear();
      rejected_device_ = nil;
      rejected_library_ = nil;
    } else if (permanent_rejection) {
      rejected_device_ = device;
      rejected_library_ = library;
      rejected_config_ = c;
      rejected_budget_ = budget;
      rejected_error_ = error;
    }
    return configured;
  }
}
bool AntiAliasing::Encode(id<MTLCommandBuffer> commands, const Inputs& in, const Frame& frame,
                          Output& out, std::string& error) {
  @autoreleasepool {
    error.clear();
    out = {};
    if (!state_) {
      error = "temporal AA is not configured";
      return false;
    }
    auto& s = *state_;
    if (frame.color_domain != ColorDomain::kSceneLinear) {
      error = "temporal AA must precede display tone mapping";
      return false;
    }
    if (!CommonInputs(commands, in, frame, s.device, s.config, false, error)) return false;
    if (s.queue && s.queue != commands.commandQueue) {
      error = "temporal AA cannot cross command queues";
      return false;
    }
    const auto failure = s.failures->count.load(std::memory_order_acquire);
    if (failure != s.seen_failure) {
      s.history.Reset();
      s.seen_failure = failure;
    }
    const auto decision = s.history.Inspect(frame, true);
    if (!decision.accepted) {
      error = decision.reason;
      return false;
    }
    auto& slot = s.slots[s.cursor];
    if (!Available(slot.owner) || !slot.lease.expired()) {
      error = "temporal AA output is still in flight or leased";
      return false;
    }
    if (slot.color == in.color) {
      error = "temporal AA input aliases the next history output";
      return false;
    }
    const bool metal4 = rex::ui::metal::IsMetal4(commands);
    if (s.scaler && metal4 && !s.scaler4 && s.scaler_descriptor) {
      if (auto compiler = rex::ui::metal::Metal4Compiler(commands.commandQueue)) {
        s.scaler4 = [s.scaler_descriptor newTemporalScalerWithDevice:s.device compiler:compiler];
        s.scaler_fence = [s.device newFence];
        s.scaler4.fence = s.scaler_fence;
      }
      if (!s.scaler4) {
        error = "MetalFX Metal 4 temporal scaler creation failed";
        return false;
      }
    }
    if (s.denoiser_descriptor && !metal4) {
      error = "MetalFX denoised scaler needs a Metal 4 queue";
      return false;
    }
    if (s.denoiser_descriptor && !s.denoiser4) {
      if (auto compiler = rex::ui::metal::Metal4Compiler(commands.commandQueue)) {
        s.denoiser4 = [s.denoiser_descriptor newTemporalDenoisedScalerWithDevice:s.device compiler:compiler];
        s.denoiser_fence = [s.device newFence];
        s.denoiser4.fence = s.denoiser_fence;
      }
      if (!s.denoiser4) {
        g_denoiser_failed.store(true, std::memory_order_relaxed);  // Live configures the plain scaler next
        notice_ = "gta4-metal-denoiser: MTL4FX temporal denoised scaler creation failed; using the "
                  "MetalFX temporal scaler and the native ray-tracing filters";
        error = "MetalFX Metal 4 denoised scaler creation failed";
        return false;
      }
      notice_ = "gta4-metal-denoiser: MTL4FX temporal denoised scaler " + std::to_string(s.config.input_width) +
                "x" + std::to_string(s.config.input_height) + " -> " + std::to_string(s.config.output_width) + "x" +
                std::to_string(s.config.output_height);
    }
    if (s.scaler || s.denoiser4) {
      // Both scalers take the same exposure: the title's GPU hint, or the scalar uploaded here.
      id<MTLTexture> exposure_texture = in.exposure;
      if (!exposure_texture) {
      // MetalFX requires a 1x1 R16Float exposure texture. Store a half-float
      // value, not the low bytes of the float used by the title's tone mapper.
      const _Float16 exposure_value = _Float16(frame.exposure);
      if (!std::isfinite(float(exposure_value)) || exposure_value <= 0) {
        error = "MetalFX exposure is not representable as a positive finite half-float";
        return false;
      }
      // The CPU staging allocation is immutable and retained by this command,
      // never rewritten in flight.
      std::array<uint8_t, 256> exposure_bytes{};
      std::memcpy(exposure_bytes.data(), &exposure_value, sizeof(exposure_value));
      auto exposure = [s.device newBufferWithBytes:exposure_bytes.data()
                                            length:exposure_bytes.size()
                                           options:MTLResourceStorageModeShared];
      auto transfer = BlitEncoder(commands, "temporal/exposure-upload");
      if (!exposure || !transfer) {
        error = "temporal exposure upload allocation failed";
        return false;
      }
      [transfer copyFromBuffer:exposure
                  sourceOffset:0
             sourceBytesPerRow:256
           sourceBytesPerImage:256
                    sourceSize:MTLSizeMake(1, 1, 1)
                     toTexture:slot.exposure
              destinationSlice:0
              destinationLevel:0
             destinationOrigin:MTLOriginMake(0, 0, 0)];
      [transfer endEncoding];
      exposure_texture = slot.exposure;
      }
      const auto jitter = MetalFxJitter(frame.jitter);
      if (s.denoiser4) {
        id<MTL4FXTemporalDenoisedScaler> denoiser = s.denoiser4;
        if (!s.neutral_cleared) {
          // Neutral guides: grey albedo, no specular, +Z normal, fully rough.
          const auto clear = [&](id<MTLTexture> target, MTLClearColor color) {
            auto* pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = target;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            pass.colorAttachments[0].clearColor = color;
            id<MTLRenderCommandEncoder> e = [commands renderCommandEncoderWithDescriptor:pass];
            if (!e) return false;
            e.label = @"Liberty denoise neutral guide";
            [e endEncoding];
            return true;
          };
          if (!clear(s.neutral_diffuse, MTLClearColorMake(0.5, 0.5, 0.5, 1)) ||
              !clear(s.neutral_specular, MTLClearColorMake(0, 0, 0, 1)) ||
              !clear(s.neutral_normal, MTLClearColorMake(0, 0, 1, 0)) ||
              !clear(s.neutral_roughness, MTLClearColorMake(1, 1, 1, 1))) {
            error = "denoiser neutral guide clear failed";
            return false;
          }
          s.neutral_cleared = true;
        }
        const auto guide = [&](id<MTLTexture> given, id<MTLTexture> neutral, MTLPixelFormat format) {
          return TextureMatches(given, s.device, format, s.config.input_width, s.config.input_height,
                                MTLTextureUsageShaderRead) ? given : neutral;
        };
        id<MTLTexture> diffuse = guide(in.diffuse_albedo, s.neutral_diffuse, MTLPixelFormatRGBA8Unorm);
        id<MTLTexture> specular = guide(in.specular_albedo, s.neutral_specular, MTLPixelFormatRGBA8Unorm);
        id<MTLTexture> normal = guide(in.normal, s.neutral_normal, MTLPixelFormatRGBA16Float);
        id<MTLTexture> roughness = guide(in.roughness, s.neutral_roughness, MTLPixelFormatR16Float);
        if (diffuse == s.neutral_diffuse) ++s.neutral_guide_frames;
        if ((in.color.usage & denoiser.colorTextureUsage) != denoiser.colorTextureUsage ||
            (in.depth.usage & denoiser.depthTextureUsage) != denoiser.depthTextureUsage ||
            (in.motion.usage & denoiser.motionTextureUsage) != denoiser.motionTextureUsage ||
            (in.reactive.usage & denoiser.reactiveTextureUsage) != denoiser.reactiveTextureUsage ||
            (diffuse.usage & denoiser.diffuseAlbedoTextureUsage) != denoiser.diffuseAlbedoTextureUsage ||
            (specular.usage & denoiser.specularAlbedoTextureUsage) != denoiser.specularAlbedoTextureUsage ||
            (normal.usage & denoiser.normalTextureUsage) != denoiser.normalTextureUsage ||
            (roughness.usage & denoiser.roughnessTextureUsage) != denoiser.roughnessTextureUsage ||
            (slot.color.usage & denoiser.outputTextureUsage) != denoiser.outputTextureUsage) {
          error = "MetalFX denoised scaler usage contract is unmet";
          return false;
        }
        denoiser.exposureTexture = exposure_texture;
        denoiser.colorTexture = in.color;
        denoiser.depthTexture = in.depth;
        denoiser.motionTexture = in.motion;
        denoiser.reactiveMaskTexture = in.reactive;
        denoiser.diffuseAlbedoTexture = diffuse;
        denoiser.specularAlbedoTexture = specular;
        denoiser.normalTexture = normal;
        denoiser.roughnessTexture = roughness;
        denoiser.outputTexture = slot.color;
        denoiser.jitterOffsetX = jitter[0];
        denoiser.jitterOffsetY = jitter[1];
        denoiser.motionVectorScaleX = 1;
        denoiser.motionVectorScaleY = 1;
        denoiser.preExposure = frame.pre_exposure;
        denoiser.depthReversed = s.config.depth_reversed;
        denoiser.shouldResetHistory = decision.reset;
        simd_float4x4 world_to_view, view_to_clip;
        static_assert(sizeof(world_to_view) == sizeof(in.world_to_view));
        std::memcpy(&world_to_view, in.world_to_view.data(), sizeof(world_to_view));
        std::memcpy(&view_to_clip, in.view_to_clip.data(), sizeof(view_to_clip));
        denoiser.worldToViewMatrix = world_to_view;
        denoiser.viewToClipMatrix = view_to_clip;
        NSMutableArray<id<MTLResource>>* used = [NSMutableArray
            arrayWithObjects:in.color, in.depth, in.motion, slot.color, diffuse, specular, normal, roughness, nil];
        if (in.reactive) [used addObject:in.reactive];
        if (exposure_texture) [used addObject:exposure_texture];
        if (!rex::ui::metal::EncodeMetal4(commands, s.denoiser_fence, used,
                                          ^(id<MTL4CommandBuffer> cb) { [denoiser encodeToCommandBuffer:cb]; }, @"MetalFX denoiser")) {
          error = "MetalFX denoised scaler encode failed";
          return false;
        }
        ++s.denoised_frames;
        if (s.denoised_frames <= 2 || s.denoised_frames % 300 == 0)
          notice_ = "gta4-metal-denoiser frames=" + std::to_string(s.denoised_frames) +
                    " neutral-guide-frames=" + std::to_string(s.neutral_guide_frames) +
                    " reset=" + (decision.reset ? "true" : "false");
      } else {
      id<MTLFXTemporalScalerBase> scaler = metal4 ? s.scaler4 : s.scaler;
      if ((in.color.usage & scaler.colorTextureUsage) != scaler.colorTextureUsage ||
          (in.depth.usage & scaler.depthTextureUsage) != scaler.depthTextureUsage ||
          (in.motion.usage & scaler.motionTextureUsage) != scaler.motionTextureUsage ||
          (in.reactive.usage & scaler.reactiveTextureUsage) != scaler.reactiveTextureUsage) {
        error = "MetalFX temporal input usage contract is unmet";
        return false;
      }
      scaler.exposureTexture = exposure_texture;
      scaler.inputContentWidth = s.config.input_width;
      scaler.inputContentHeight = s.config.input_height;
      scaler.colorTexture = in.color;
      scaler.depthTexture = in.depth;
      scaler.motionTexture = in.motion;
      scaler.reactiveMaskTexture = in.reactive;
      scaler.outputTexture = slot.color;
      scaler.jitterOffsetX = jitter[0];
      scaler.jitterOffsetY = jitter[1];
      scaler.motionVectorScaleX = 1;
      scaler.motionVectorScaleY = 1;
      scaler.preExposure = frame.pre_exposure;
      scaler.depthReversed = s.config.depth_reversed;
      scaler.reset = decision.reset;
      // MetalFX takes a Metal 3 command buffer; on the Metal 4 queue it runs in an ordered hop.
      if (metal4) {
        NSMutableArray<id<MTLResource>>* used = [NSMutableArray arrayWithObjects:in.color, in.depth, in.motion, slot.color, nil];
        if (in.reactive) [used addObject:in.reactive];
        if (scaler.exposureTexture) [used addObject:scaler.exposureTexture];
        id<MTL4FXTemporalScaler> scaler4 = s.scaler4;
        rex::ui::metal::EncodeMetal4(commands, s.scaler_fence, used,
                                     ^(id<MTL4CommandBuffer> cb) { [scaler4 encodeToCommandBuffer:cb]; }, @"MetalFX upscaler");
      } else {
        [s.scaler encodeToCommandBuffer:commands];
      }
      }
    } else {
      TaaConstants c;
      c.extent = {s.config.input_width, s.config.input_height};
      c.jitter = frame.jitter;
      c.near_plane = frame.near_plane;
      c.far_plane = frame.far_plane;
      c.reset = decision.reset;
      c.reversed = s.config.depth_reversed;
      c.current_pre_exposure = frame.pre_exposure;
      c.previous_pre_exposure =
          decision.reset ? frame.pre_exposure : s.history.previous().pre_exposure;
      const auto& previous_frame = decision.reset ? frame : s.history.previous();
      c.previous_near_plane = previous_frame.near_plane;
      c.previous_far_plane = previous_frame.far_plane;
      auto encoder = ComputeEncoder(commands, "temporal/native-taa");
      if (!encoder) {
        error = "native TAA encoder creation failed";
        return false;
      }
      encoder.label = @"Liberty TAA reprojection and disocclusion";
      [encoder setComputePipelineState:s.taa];
      const auto& prior = s.slots[s.previous];
      std::array<id<MTLTexture>, 9> textures{in.color,
                                             in.depth,
                                             in.motion,
                                             in.reactive,
                                             decision.reset ? in.color : prior.color,
                                             decision.reset ? in.depth : prior.depth,
                                             slot.color,
                                             slot.depth,
                                             in.previous_depth};
      [encoder setTextures:textures.data() withRange:NSMakeRange(0, textures.size())];
      [encoder setBytes:&c length:sizeof(c) atIndex:0];
      const NSUInteger width = s.taa.threadExecutionWidth,
                       height = std::max<NSUInteger>(
                           1, std::min<NSUInteger>(8, s.taa.maxTotalThreadsPerThreadgroup / width));
      [encoder dispatchThreads:MTLSizeMake(s.config.input_width, s.config.input_height, 1)
          threadsPerThreadgroup:MTLSizeMake(width, height, 1)];
      [encoder endEncoding];
    }
    s.queue = commands.commandQueue;
    slot.owner = commands;
    s.previous = s.cursor;
    s.cursor = (s.cursor + 1) % s.slots.size();
    s.history.Commit(frame);
    ObserveFailure(commands, s.failures);
    auto lease = std::make_shared<LeasedImages>();
    lease->first = slot.color;
    lease->second = slot.depth;
    slot.lease = lease;
    out = {slot.color, decision.reset, std::move(lease)};
    return true;
  }
}
struct FrameInterpolation::State {
  std::string notice;  // TakeNotice()
  struct Slot {
    id<MTLTexture> scene = nil, real = nil, generated = nil;
    // gta4_metalfx_frame_generation_sharpen / _source_clamp: the interpolator writes here and the
    // sharpen pass reads it into `generated` (no copy). Made at the first sharpened frame.
    id<MTLTexture> sharpen_source = nil;
    __weak id<MTLCommandBuffer> owner = nil;
    std::weak_ptr<void> lease;
  };
  id<MTLDevice> device = nil;
  id<MTLCommandQueue> queue = nil;
  Configuration config{};
  History history;
  id<MTLFXFrameInterpolator> interpolator = nil;
  // Metal 4 queue (gta4_metal_api = metal4): the same interpolator as MTL4FX, made at the
  // first Metal 4 encode from the queue's MTL4Compiler and encoded into the MTL4 command
  // buffer (EncodeMetal4) instead of a Metal 3 hop. Its own fence: the temporal scaler's
  // EncodeMetal4 earlier in the frame is ordered by the queue barrier, not by sharing one.
  id<MTL4FXFrameInterpolator> interpolator4 = nil;
  id<MTLFence> fence4 = nil;
  uint64_t native_encodes = 0, hop_encodes = 0;
  bool native4_unavailable = false;
  id<MTLComputePipelineState> composite = nil, overlay = nil;
  id<MTLComputePipelineState> repair = nil;  // optional: nil skips the discontinuity repair
  id<MTLComputePipelineState> sharpen = nil;  // optional: nil skips the sharpening
  uint64_t sharpen_failures = 0;
  // Three: a slot is reused three frames later. With two, the frame that last wrote it was
  // often still scheduled on the GPU (2-3 frames in flight), and every other frame was skipped.
  std::array<Slot, 3> slots{};
  size_t cursor = 0, previous = 0, owned = 0, limit = 0;
  bool encoded = false, restart_instance = false;
  std::shared_ptr<FailureState> failures = std::make_shared<FailureState>();
  uint64_t seen_failure = 0;
  MTLFXFrameInterpolatorDescriptor* Describe() const {
    auto descriptor = [MTLFXFrameInterpolatorDescriptor new];
    descriptor.inputWidth = config.input_width;
    descriptor.inputHeight = config.input_height;
    descriptor.outputWidth = config.output_width;
    descriptor.outputHeight = config.output_height;
    descriptor.colorTextureFormat = descriptor.outputTextureFormat = descriptor.uiTextureFormat =
        MTLPixelFormatRGBA16Float;
    descriptor.depthTextureFormat = MTLPixelFormatR32Float;
    descriptor.motionTextureFormat = MTLPixelFormatRG16Float;
    return descriptor;
  }
  id<MTLFXFrameInterpolator> CreateInterpolator() const {
    return [Describe() newFrameInterpolatorWithDevice:device];
  }
  // nil when the device or queue has no MTL4FX interpolation; then the Metal 3 hop is used.
  id<MTL4FXFrameInterpolator> CreateInterpolator4(id<MTLCommandQueue> queue) const {
    if (![MTLFXFrameInterpolatorDescriptor supportsMetal4FX:device]) return nil;
    auto compiler = rex::ui::metal::Metal4Compiler(queue);
    return compiler ? [Describe() newFrameInterpolatorWithDevice:device compiler:compiler] : nil;
  }
};
FrameInterpolation::FrameInterpolation() = default;
FrameInterpolation::~FrameInterpolation() = default;
void FrameInterpolation::Reset() {
  if (state_) {
    state_->history.Reset();
    state_->restart_instance = state_->encoded;
  }
}
size_t FrameInterpolation::owned_bytes() const { return state_ ? state_->owned : 0; }
std::string FrameInterpolation::TakeNotice() {
  return state_ ? std::exchange(state_->notice, std::string()) : std::string();
}
FrameInterpolation::EncodeCounts FrameInterpolation::encode_counts() const {
  return state_ ? EncodeCounts{state_->native_encodes, state_->hop_encodes} : EncodeCounts{};
}
bool FrameInterpolation::Configure(id<MTLDevice> device, id<MTLLibrary> library, Configuration c,
                                   size_t budget, std::string& error) {
  @autoreleasepool {
    error.clear();
    budget = std::min(budget, kMaximumOwnedBytes);
    if (!device || !ValidConfiguration(c) || !budget || !QueryCapabilities(device).interpolation) {
      error = "unsupported MetalFX frame interpolation configuration";
      return false;
    }
    if (state_ && state_->device == device && state_->config == c && state_->limit == budget)
      return true;
    auto next = std::make_unique<State>();
    next->device = device;
    next->config = c;
    next->limit = budget;
    if (!library || library.device != device) {
      error = "UI composition shader library is unavailable";
      return false;
    }
    NSError* native_error = nil;
    auto ui_function = [library newFunctionWithName:@"liberty_temporal_ui_over"];
    if (!ui_function) {
      error = "temporal UI composition shader is unavailable";
      return false;
    }
    next->composite = [device newComputePipelineStateWithFunction:ui_function error:&native_error];
    if (!next->composite) {
      error = native_error.localizedDescription.UTF8String;
      return false;
    }
    auto overlay_function = [library newFunctionWithName:@"liberty_temporal_ui_over_inplace"];
    if (!overlay_function) {
      error = "temporal overlay shader is unavailable";
      return false;
    }
    next->overlay = [device newComputePipelineStateWithFunction:overlay_function
                                                          error:&native_error];
    if (!next->overlay) {
      error = native_error.localizedDescription.UTF8String;
      return false;
    }
    // Optional (an older metallib may lack it): without it the repair is skipped.
    if (auto repair_function = [library newFunctionWithName:@"liberty_temporal_framegen_repair"])
      next->repair = [device newComputePipelineStateWithFunction:repair_function error:nil];
    if (auto sharpen_function = [library newFunctionWithName:@"liberty_temporal_framegen_sharpen"])
      next->sharpen = [device newComputePipelineStateWithFunction:sharpen_function error:nil];
    next->interpolator = next->CreateInterpolator();
    if (!next->interpolator) {
      error = "MetalFX frame interpolator creation failed";
      return false;
    }
    for (auto& slot : next->slots) {
      slot.scene = Allocate(device, MTLPixelFormatRGBA16Float, c.output_width, c.output_height,
                            MTLTextureUsageShaderRead | next->interpolator.colorTextureUsage,
                            @"Liberty previous real scene", budget, next->owned, error);
      if (!slot.scene) return false;
      slot.real = Allocate(device, MTLPixelFormatRGBA16Float, c.output_width, c.output_height,
                           MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite,
                           @"Liberty real presentation image", budget, next->owned, error);
      if (!slot.real) return false;
      slot.generated = Allocate(device, MTLPixelFormatRGBA16Float, c.output_width, c.output_height,
                                MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite |
                                    next->interpolator.outputTextureUsage,
                                @"Liberty MetalFX generated image", budget, next->owned, error);
      if (!slot.generated) return false;
    }
    state_ = std::move(next);
    return true;
  }
}
bool FrameInterpolation::Encode(id<MTLCommandBuffer> commands, const Inputs& in, UiInput ui_input,
                                const Frame& frame, InterpolationOutput& out, std::string& error) {
  @autoreleasepool {
    error.clear();
    out = {};
    if (!state_) {
      error = "frame interpolation is not configured";
      return false;
    }
    auto& s = *state_;
    if (frame.color_domain != ColorDomain::kDisplayLinear &&
        frame.color_domain != ColorDomain::kDisplayPerceptual) {
      error = "frame interpolation must follow tone mapping";
      return false;
    }
    if ((ui_input.mode == UiMode::kNone) != (ui_input.image == nil)) {
      error = "UI composition mode disagrees with its image";
      return false;
    }
    auto ui = ui_input.image;
    if (!CommonInputs(commands, in, frame, s.device, s.config, true, error)) return false;
    if (s.queue && s.queue != commands.commandQueue) {
      error = "frame interpolation cannot cross command queues";
      return false;
    }
    const bool metal4 = rex::ui::metal::IsMetal4(commands);
    bool native4 = false;
    if (metal4 && !s.interpolator4 && !s.native4_unavailable) {
      s.interpolator4 = s.CreateInterpolator4(commands.commandQueue);
      if (s.interpolator4) {
        s.fence4 = [s.device newFence];
        s.interpolator4.fence = s.fence4;
        s.notice = "gta4-metal-framegen: native MTL4FX frame interpolator " +
                   std::to_string(s.config.input_width) + "x" + std::to_string(s.config.input_height) +
                   " -> " + std::to_string(s.config.output_width) + "x" + std::to_string(s.config.output_height);
      } else {
        s.native4_unavailable = true;  // once: keep the Metal 3 hop
        s.notice = "gta4-metal-framegen: MTL4FX frame interpolator unavailable; using the Metal 3 hop";
      }
    }
    native4 = metal4 && s.interpolator4;
    id<MTLFXFrameInterpolatorBase> fx = native4 ? (id<MTLFXFrameInterpolatorBase>)s.interpolator4
                                                : (id<MTLFXFrameInterpolatorBase>)s.interpolator;
    if (native4 && ((s.slots[s.cursor].scene.usage & fx.colorTextureUsage) != fx.colorTextureUsage ||
                    (s.slots[s.cursor].generated.usage & fx.outputTextureUsage) != fx.outputTextureUsage)) {
      error = "MTL4FX frame interpolation slot usage contract is unmet";
      return false;
    }
    if ((in.depth.usage & fx.depthTextureUsage) != fx.depthTextureUsage ||
        (in.motion.usage & fx.motionTextureUsage) != fx.motionTextureUsage ||
        (ui && !TextureMatches(ui, s.device, MTLPixelFormatRGBA16Float, s.config.output_width,
                               s.config.output_height, fx.uiTextureUsage))) {
      error = "frame interpolation input usage or UI contract is unmet";
      return false;
    }
    const auto failures = s.failures->count.load(std::memory_order_acquire);
    if (failures != s.seen_failure) {
      s.history.Reset();
      s.seen_failure = failures;
    }
    const auto decision = s.history.Inspect(frame);
    if (!decision.accepted) {
      error = decision.reason;
      return false;
    }
    auto& slot = s.slots[s.cursor];
    if (!Available(slot.owner) || !slot.lease.expired()) {
      // Which one holds the slot: the GPU (owner status 0-3: not enqueued .. scheduled) or the
      // presenter's lease on the generated and real images.
      id<MTLCommandBuffer> owner = slot.owner;
      error = "interpolated pair is still in flight or leased: owner-status=" +
              (owner ? std::to_string(int(owner.status)) : std::string("none")) +
              " leased=" + (slot.lease.expired() ? "no" : "yes");
      return false;
    }
    if (s.restart_instance || (decision.reset && s.encoded)) {
      // The reset-and-reuse GPU regression on the tested MetalFX runtime kept
      // stale scene state after a cut. Recreate only the effect at discontinuities;
      // the bounded texture ring and ordinary continuous-frame path are reused.
      if (native4) {
        auto replacement = s.CreateInterpolator4(commands.commandQueue);
        if (!replacement) {
          error = "MTL4FX history discontinuity reset failed";
          return false;
        }
        replacement.fence = s.fence4;
        s.interpolator4 = replacement;
        fx = replacement;
      } else {
        auto replacement = s.CreateInterpolator();
        if (!replacement) {
          error = "MetalFX history discontinuity reset failed";
          return false;
        }
        s.interpolator = replacement;
        fx = replacement;
      }
      s.restart_instance = false;
    }
    if (in.color == slot.scene || in.color == slot.real || in.color == slot.generated ||
        ui == slot.scene || ui == slot.real || ui == slot.generated) {
      error = "interpolation source aliases an output slot";
      return false;
    }
    auto copy = BlitEncoder(commands, "framegen/snapshot-blit");
    if (!copy) {
      error = "frame interpolation snapshot encoder failed";
      return false;
    }
    copy.label = @"Liberty immutable frame-generation inputs";
    const bool overlay = ui_input.mode == UiMode::kPremultipliedOverlay;
    // With caller_writes_real the real image is written whole afterwards: a copy here would be a
    // full-size image of traffic per real frame for nothing (2560x1440 RGBA16Float: 29 MB).
    const bool skip_real = overlay || (ui_input.mode == UiMode::kNone && ui_input.caller_writes_real);
    const bool copied =
        Copy(copy, in.color, slot.scene) && (skip_real || Copy(copy, ui ? ui : in.color, slot.real));
    [copy endEncoding];
    if (!copied) {
      error = "frame interpolation snapshot mismatch";
      return false;
    }
    if (overlay) {
      auto encoder = ComputeEncoder(commands, "framegen/ui-over");
      if (!encoder) {
        error = "temporal UI composition encoder failed";
        return false;
      }
      encoder.label = @"Liberty current UI composition";
      [encoder setComputePipelineState:s.composite];
      [encoder setTexture:slot.scene atIndex:0];
      [encoder setTexture:ui atIndex:1];
      [encoder setTexture:slot.real atIndex:2];
      const NSUInteger w = s.composite.threadExecutionWidth,
                       h = std::max<NSUInteger>(
                           1,
                           std::min<NSUInteger>(8, s.composite.maxTotalThreadsPerThreadgroup / w));
      [encoder dispatchThreads:MTLSizeMake(s.config.output_width, s.config.output_height, 1)
          threadsPerThreadgroup:MTLSizeMake(w, h, 1)];
      [encoder endEncoding];
    }
    // The sharpen pass (below) reads the interpolator's output from sharpen_source and writes
    // generated, so the interpolator writes sharpen_source directly when the pass runs.
    bool sharpen = (in.sharpen > 0 || in.source_clamp) && s.sharpen && !decision.reset;
    if (sharpen && !slot.sharpen_source) {
      std::string allocation_error;
      slot.sharpen_source = Allocate(s.device, MTLPixelFormatRGBA16Float, s.config.output_width,
                                     s.config.output_height,
                                     MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | fx.outputTextureUsage,
                                     @"Liberty generated image before sharpening", s.limit, s.owned,
                                     allocation_error);
      if (!slot.sharpen_source && s.sharpen_failures++ == 0)
        s.notice = "frame-generation sharpening off: " + allocation_error;
    }
    sharpen = sharpen && slot.sharpen_source &&
              (slot.sharpen_source.usage & fx.outputTextureUsage) == fx.outputTextureUsage;
    id<MTLTexture> interpolated = sharpen ? slot.sharpen_source : slot.generated;
    fx.colorTexture = slot.scene;
    fx.prevColorTexture = decision.reset ? slot.scene : s.slots[s.previous].scene;
    fx.depthTexture = in.depth;
    fx.motionTexture = in.motion;
    fx.outputTexture = interpolated;
    // Keep a premultiplied layer outside interpolation entirely: it is blended
    // after the midpoint has been generated, and never enters flow estimation.
    fx.uiTexture = overlay ? nil : ui;
    fx.uiTextureComposited = ui_input.mode == UiMode::kComposited;
    fx.motionVectorScaleX = float(s.config.output_width) / s.config.input_width;
    fx.motionVectorScaleY = float(s.config.output_height) / s.config.input_height;
    const auto fx_jitter = MetalFxJitter(frame.jitter);
    fx.jitterOffsetX = fx_jitter[0];
    fx.jitterOffsetY = fx_jitter[1];
    fx.deltaTime = decision.delta_seconds > 0 ? decision.delta_seconds : 1.0f / 60.0f;
    fx.nearPlane = frame.near_plane;
    fx.farPlane = frame.far_plane;
    fx.fieldOfView = frame.field_of_view;
    fx.aspectRatio = frame.aspect;
    fx.depthReversed = s.config.depth_reversed;
    fx.shouldResetHistory = decision.reset;
    if (@available(macOS 27.0, *)) {
      // The interpolator derives camera-only motion from this pair; two identity matrices mean
      // "not supplied" (the default, and what it gets with camera_matrices off).
      simd_float4x4 world_to_view = matrix_identity_float4x4, view_to_clip = matrix_identity_float4x4;
      if (in.camera_matrices) {
        std::memcpy(&world_to_view, in.world_to_view.data(), sizeof(world_to_view));
        std::memcpy(&view_to_clip, in.view_to_clip.data(), sizeof(view_to_clip));
      }
      fx.worldToViewMatrix = world_to_view;
      fx.viewToClipMatrix = view_to_clip;
    }
    if (native4) {
      // Native Metal 4: into the open MTL4 command buffer. The snapshot blit and the UI
      // composition above are earlier proxy encoders; EncodeMetal4's empty encoder waits for
      // them and updates fence4, which the interpolator waits on. The UI pass below is the
      // next proxy encoder, ordered after it by its queue barrier.
      NSMutableArray<id<MTLResource>>* used =
          [NSMutableArray arrayWithObjects:fx.colorTexture, fx.depthTexture, fx.motionTexture, fx.outputTexture, nil];
      if (fx.prevColorTexture && fx.prevColorTexture != fx.colorTexture) [used addObject:fx.prevColorTexture];
      if (fx.uiTexture) [used addObject:fx.uiTexture];
      id<MTL4FXFrameInterpolator> fx4 = s.interpolator4;
      if (!rex::ui::metal::EncodeMetal4(commands, s.fence4, used,
                                        ^(id<MTL4CommandBuffer> cb) { [fx4 encodeToCommandBuffer:cb]; }, @"MetalFX frame interpolator")) {
        s.history.Reset();
        error = "MTL4FX frame interpolation encode failed";
        return false;
      }
      ++s.native_encodes;
    } else {
      id<MTLFXFrameInterpolator> fx3 = s.interpolator;
      rex::ui::metal::EncodeMetal3(commands, ^(id<MTLCommandBuffer> m3) { [fx3 encodeToCommandBuffer:m3]; });
      ++s.hop_encodes;
    }
    // Both paths join here: the native MTL4FX encode updates fence4, which the next proxy
    // encoder waits on (as the UI pass below), and the Metal 3 hop encodes into this command
    // buffer. Same slot, same command buffer: no new lifetime; slot.owner is set below.
    if (in.repair_motion_px > 0 && s.repair && !decision.reset) {
      auto encoder = ComputeEncoder(commands, "framegen/repair");
      if (!encoder) {
        s.history.Reset();
        error = "frame-generation repair encoder failed";
        return false;
      }
      encoder.label = @"Liberty frame-generation discontinuity repair";
      struct {
        float motion_scale[2], input_texel[2], output_texel[2];
        float threshold, near_plane, far_plane;
        uint32_t reversed;
        float depth_step, padding;
      } c{{float(s.config.output_width) / s.config.input_width,
           float(s.config.output_height) / s.config.input_height},
          {1.0f / s.config.input_width, 1.0f / s.config.input_height},
          {1.0f / s.config.output_width, 1.0f / s.config.output_height},
          in.repair_motion_px, frame.near_plane, frame.far_plane,
          uint32_t(s.config.depth_reversed), 0.10f, 0};
      [encoder setComputePipelineState:s.repair];
      [encoder setTexture:interpolated atIndex:0];
      [encoder setTexture:slot.scene atIndex:1];
      [encoder setTexture:in.motion atIndex:2];
      [encoder setTexture:in.depth atIndex:3];
      [encoder setBytes:&c length:sizeof(c) atIndex:0];
      const NSUInteger w = s.repair.threadExecutionWidth,
                       h = std::max<NSUInteger>(
                           1, std::min<NSUInteger>(8, s.repair.maxTotalThreadsPerThreadgroup / w));
      [encoder dispatchThreads:MTLSizeMake(s.config.output_width, s.config.output_height, 1)
          threadsPerThreadgroup:MTLSizeMake(w, h, 1)];
      [encoder endEncoding];
    }
    // Before the UI goes on: only the interpolated scene is softened.
    if (sharpen) {
      auto encoder = ComputeEncoder(commands, "framegen/sharpen");
      if (!encoder) {
        s.history.Reset();
        error = "frame-generation sharpen encoder failed";
        return false;
      }
      encoder.label = @"Liberty frame-generation sharpening";
      const struct { float amount, source_clamp, motion_scale[2]; } k{
          std::clamp(in.sharpen, 0.0f, 2.0f), in.source_clamp ? 1.0f : 0.0f,
          {float(s.config.output_width) / s.config.input_width,
           float(s.config.output_height) / s.config.input_height}};
      [encoder setComputePipelineState:s.sharpen];
      [encoder setTexture:slot.sharpen_source atIndex:0];
      [encoder setTexture:slot.generated atIndex:1];
      [encoder setTexture:in.motion atIndex:2];
      [encoder setTexture:s.slots[s.previous].scene atIndex:3];
      [encoder setTexture:slot.scene atIndex:4];
      [encoder setBytes:&k length:sizeof(k) atIndex:0];
      const NSUInteger w = s.sharpen.threadExecutionWidth,
                       h = std::max<NSUInteger>(
                           1, std::min<NSUInteger>(8, s.sharpen.maxTotalThreadsPerThreadgroup / w));
      [encoder dispatchThreads:MTLSizeMake(s.config.output_width, s.config.output_height, 1)
          threadsPerThreadgroup:MTLSizeMake(w, h, 1)];
      [encoder endEncoding];
    }
    if (overlay && !decision.reset) {
      auto encoder = ComputeEncoder(commands, "framegen/ui-after");
      if (!encoder) {
        s.history.Reset();
        error = "generated-frame UI encoder failed";
        return false;
      }
      encoder.label = @"Liberty UI after frame interpolation";
      [encoder setComputePipelineState:s.overlay];
      [encoder setTexture:slot.generated atIndex:0];
      [encoder setTexture:ui atIndex:1];
      const NSUInteger w = s.overlay.threadExecutionWidth,
                       h = std::max<NSUInteger>(
                           1, std::min<NSUInteger>(8, s.overlay.maxTotalThreadsPerThreadgroup / w));
      [encoder dispatchThreads:MTLSizeMake(s.config.output_width, s.config.output_height, 1)
          threadsPerThreadgroup:MTLSizeMake(w, h, 1)];
      [encoder endEncoding];
    }
    s.queue = commands.commandQueue;
    slot.owner = commands;
    s.previous = s.cursor;
    s.cursor = (s.cursor + 1) % s.slots.size();
    s.history.Commit(frame);
    ObserveFailure(commands, s.failures);
    s.encoded = true;
    // Keep the effect object alive until its encoded private history work is done.
    [commands addCompletedHandler:^(id<MTLCommandBuffer>) {
      (void)fx;
    }];
    auto lease = std::make_shared<LeasedImages>();
    lease->first = slot.generated;
    lease->second = slot.real;
    slot.lease = lease;
    out = {decision.reset ? nil : slot.generated, slot.real, decision.reset, std::move(lease)};
    return true;
  }
}
}  // namespace rex::graphics::gta4_metal::temporal
