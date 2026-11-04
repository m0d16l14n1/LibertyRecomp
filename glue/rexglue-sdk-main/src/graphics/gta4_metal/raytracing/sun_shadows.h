#pragma once
// Ray-traced sun shadows (stage 4, gta4_metal_raytracing = shadows). Once per frame, just
// before the deferred lighting's global contribution (lightShadowDirectional), from the
// same inputs as the AO (AoFrame: the frame's capture TLAS, the scene depth snapshot, the
// G-buffer normals, the motion texture):
//   rtshadow_trace   half resolution, one ray per pixel towards the sun inside its cone,
//                    tested against opaque captured instances only (foliage stays with the cascade)
//   rtao_temporal    reprojected accumulation (shorter history than the AO: moving shadows)
//   rtao_atrous      one edge-aware pass, step 1
//   rtshadow_upsample depth-aware, to an RG16Float texture at the depth's size
// The lighting shader's shadow variant (raytracing_shadow_variants.py; draw.mm binds the
// texture at fragment texture 1) combines it with the cascade factor before the sun's
// diffuse and specular. View show draws the visibility in grey instead.
#import <Metal/Metal.h>
#include "ambient_occlusion.h"
#include "shadow_policy.h"
#include <array>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>

namespace rex::graphics::gta4_metal::raytracing {

struct ShadowSettings {
  ShadowView view = ShadowView::kCombine;
  float cone_tangent = 0.0087f;  // ConeTangent(gta4_metal_raytracing_shadow_angle = 0.5)
  float max_distance = 250.0f;   // world units
  bool foliage = false;          // alpha-tested instances cast too
  uint32_t normal_mode = 1;      // gta4_metal_raytracing_ao_normals (shared with the AO)
};
ShadowSettings CurrentShadowSettings();  // the cvars; read once per frame by the caller

class SunShadows {
 public:
  SunShadows();
  ~SunShadows();
  SunShadows(const SunShadows&) = delete;
  SunShadows& operator=(const SunShadows&) = delete;

  bool Initialize(id<MTLDevice> device, std::string& error);
  bool initialized() const;

  // Outside any encoder. `towards_sun`: TowardsSun(gDirectionalLight); nullopt (no sun)
  // still runs the passes and returns an all-lit texture, so a view never reads stale shadows.
  // Returns RG16Float at the depth's size (r visibility, g replace), or nil.
  id<MTLTexture> Encode(id<MTLCommandBuffer> commands, const AoFrame& frame,
                        const std::optional<std::array<float, 3>>& towards_sun, const ShadowSettings& settings,
                        std::string& error);
  // View show: outside any encoder, its own render pass drawing the visibility in grey over
  // `target` (same size as `shadow`; otherwise nothing is drawn).
  bool Show(id<MTLCommandBuffer> commands, id<MTLTexture> target, id<MTLTexture> shadow, std::string& error);
  void Reset();  // drops history and textures (device loss, mode change)

  uint64_t traced_frames() const;
  const CpuTime& encode_time() const;  // Encode(), CPU

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace rex::graphics::gta4_metal::raytracing
