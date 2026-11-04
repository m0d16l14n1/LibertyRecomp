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

// gta4_metal_raytracing_ao_view = apply | show | none
enum class AoView : uint8_t { kApply, kShow, kNone };
struct AoSettings {
  AoView view = AoView::kApply;
  float radius = 2.0f;          // world units (metres)
  float occlusion = 0.85f;      // how dark a contact hit gets in the AO term
  float apply_strength = 0.6f;  // how much of the AO term reaches the lit image
};
AoSettings CurrentAoSettings();  // the cvars; read once per frame by the caller

struct AoFrame {
  id<MTLAccelerationStructure> scene = nil;  // Capture::EncodeScene()
  id<MTLHeap> structures = nil;              // Capture::heap(): the instances' structures
  id<MTLTexture> depth = nil;                // the scene depth attachment, single sample
  id<MTLTexture> motion = nil;               // RG16Float, input pixels towards the previous frame; may be nil
  std::array<float, 16> clip_to_world{};     // ClipToWorldColumns(), unjittered
  std::array<float, 3> camera_position{};    // world
  bool reversed_depth = false;
  bool camera_cut = false;
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
  // Outside any encoder: its own render pass over `target` (loaded and stored).
  // kNone does nothing. `ao` must match the target's size; otherwise nothing is drawn.
  bool Apply(id<MTLCommandBuffer> commands, id<MTLTexture> target, id<MTLTexture> ao, const AoSettings& settings,
             std::string& error);
  void Reset();  // drops history and textures (device loss, mode change)

  uint64_t traced_frames() const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace rex::graphics::gta4_metal::raytracing
