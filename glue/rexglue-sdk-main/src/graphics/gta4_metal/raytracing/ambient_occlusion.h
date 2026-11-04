#pragma once
// Ray-traced ambient occlusion (stage 3): trace, temporal accumulation, two a-trous
// passes and a depth-aware upsample (shaders/rtao.metal), then an apply pass over the
// lighting output. Runs once per frame just before the deferred lighting's global
// contribution draw (lightShadowDirectional / lightNoDirectional).
//
// Apply, until the lighting pixel-shader override exists: the AO multiplies the whole
// global contribution (sun, ambient and reflection), mixed by a strength below 1. The
// override will put it on the ambient term only.
#import <Metal/Metal.h>
#include <array>
#include <cstdint>
#include <memory>
#include <string>

namespace rex::graphics::gta4_metal::raytracing {

// gta4_metal_raytracing_ao_view = apply | multiply | show | debug | none
// apply: on the ambient term of the lighting shader (its AO variant; draw.mm binds the AO at
// fragment texture 0), or the multiply when that pipeline is not available.
// multiply: always the full-screen multiply of the whole global contribution.
// debug: r = fract(world.x / 10), g = AO ray hit within the radius, b = long-ray hit distance.
enum class AoView : uint8_t { kApply, kShow, kDebug, kNone, kMultiply };
struct AoSettings {
  AoView view = AoView::kApply;
  float radius = 2.0f;          // world units (metres)
  float occlusion = 0.85f;      // how dark a contact hit gets in the AO term
  float apply_strength = 0.6f;  // multiply apply only: how much of the AO term reaches the lit image
  uint32_t normal_mode = 0;     // gta4_metal_raytracing_ao_normals: 0 depth, 1 gbuffer, 2 gbuffer-yx
};
AoSettings CurrentAoSettings();  // the cvars; read once per frame by the caller

struct AoFrame {
  id<MTLAccelerationStructure> scene = nil;  // Capture::EncodeScene()
  id<MTLHeap> structures = nil;              // Capture::heap(): the instances' structures
  id<MTLTexture> depth = nil;                // the scene depth attachment, single sample
  id<MTLTexture> motion = nil;               // RG16Float, input pixels towards the previous frame; may be nil
  id<MTLTexture> normals = nil;              // GBufferTextureSampler1, for normal_mode 1/2; may be nil
  std::array<float, 16> clip_to_world{};     // ClipToWorldColumns(), unjittered
  std::array<float, 3> camera_position{};    // world
  std::array<float, 2> jitter_ndc{};         // projection jitter of this frame's depth, in ndc
  bool reversed_depth = false;
  bool camera_cut = false;
  // Diagnostics only: the frame's captured positions, compared with the reconstruction.
  id<MTLBuffer> captured_positions = nil;
  NSUInteger captured_vertices = 0;
};

class AmbientOcclusion {
 public:
  AmbientOcclusion();
  ~AmbientOcclusion();
  AmbientOcclusion(const AmbientOcclusion&) = delete;
  AmbientOcclusion& operator=(const AmbientOcclusion&) = delete;

  bool Initialize(id<MTLDevice> device, std::string& error);
  bool initialized() const;

  // Outside any encoder. Returns the AO at the depth's size (R16Float, 1 = open), or nil.
  id<MTLTexture> Encode(id<MTLCommandBuffer> commands, const AoFrame& frame, const AoSettings& settings,
                        std::string& error);
  // Every 300 traced frames (and the first two) Encode also runs a statistics pass and logs
  // "gta4-metal-raytracing-ao-stats" when the GPU completes it.
  // Outside any encoder: its own render pass over `target` (loaded and stored).
  // kNone does nothing. `ao` must match the target's size; otherwise nothing is drawn.
  // kDebug draws the debug texture instead of `ao`.
  bool Apply(id<MTLCommandBuffer> commands, id<MTLTexture> target, id<MTLTexture> ao, const AoSettings& settings,
             std::string& error);
  void Reset();  // drops history and textures (device loss, mode change)

  uint64_t traced_frames() const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace rex::graphics::gta4_metal::raytracing
