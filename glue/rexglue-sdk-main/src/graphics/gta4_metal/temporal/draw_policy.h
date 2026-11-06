#pragma once
#include <algorithm>
#include <array>
#include <bit>
#include <cmath>
#include <cstdint>
#include <string_view>
#include <rex/graphics/gta4_native/lighting_semantics.h>
#include "../../gta4_native/core/draw_state.h"
#include "history.h"

namespace rex::graphics::gta4_metal::temporal {
// The archive expands an a0-relative vertex-constant read to the whole c128-c255
// tail.  Those shaders are skinning from a bone palette even when their filename
// is a generic gta_default / gta_normal_spec variant (notably Niko's materials).
// A name-only gta_ped test therefore misses parts of the player and lets MetalFX
// blend incompatible poses into a doubled silhouette.
//
// The rigid treatment also marks the draw fully reactive in the one mask the MetalFX temporal
// scaler reads, so the scaler stops accumulating there, and it hands the scaler motion without
// the deformation. Over Niko, peds and whole car bodies (bone-palette shaders) that is a large
// share of the frame showing raw jittered samples: the shimmer on characters and cars with frame
// generation on. `wheels_only` limits it to tires, where spinning spokes are what the
// interpolator cannot handle; peds keep their real skinned motion and accumulate normally.
constexpr bool IsRigidDeformationShader(std::string_view name,
                                        const std::array<uint64_t, 4>& reads,
                                        bool wheels_only = false) {
  if (name.find("gta_vehicle_tire") != name.npos) return true;
  if (wheels_only) return false;
  const bool bone_palette = reads[2] == ~uint64_t{0} && reads[3] == ~uint64_t{0};
  return name.find("gta_ped") != name.npos || bone_palette;
}
inline float MaterialMipBias(const Configuration& config, bool scene_material) {
  if (!scene_material || config.method != Method::kMetalFx || !ValidConfiguration(config) ||
      (config.input_width == config.output_width && config.input_height == config.output_height))
    return 0.0f;
  // Apple's temporal-upscaling recommendation: log2(render / display) - 1.
  // Select the more detailed axis when rounded render extents differ slightly.
  const float ratio = std::min(float(config.input_width) / config.output_width,
                               float(config.input_height) / config.output_height);
  return std::log2(ratio) - 1.0f;
}
// These roles add independently moving/animated light effects to scene color.
// They cannot inherit a completeness assertion from the opaque GBuffer motion.
constexpr bool IsSceneEffect(gta4_native::LightPassRole role) {
  using enum gta4_native::LightPassRole;
  return role==kShaft||role==kCorona||role==kBrightLight||role==kSmokeBoard||role==kWaterFx;
}
constexpr bool IsScreenExecution(bool executed_screen,
                                 const gta4_native::LightingContext& lighting) {
  using enum gta4_native::RenderExecutionStage;
  return executed_screen||lighting.stage==kDeferredLighting||
         lighting.stage==kRadarMap||lighting.stage==kCompositePostFx;
}
struct SceneDrawPolicy {
  bool primary = false, world = false, effect = false, motion_relevant = false;
};
constexpr bool AdmitJitter(bool decided,bool eligible,bool planned,bool camera_match,bool primary) {
  return planned&&camera_match&&(decided?eligible:primary);
}
inline void CommitPrimaryJitter(bool encoded,bool primary,bool camera_match,bool planned,
                                bool& decided,bool& eligible) {
  if(!encoded||!primary||decided)return;
  decided=true;eligible=camera_match&&planned;
}
constexpr SceneDrawPolicy ClassifySceneDraw(bool scene_extent, bool ui, bool composite,
    bool primary_gbuffer, bool executed_geometry, bool executed_screen, bool camera_match,
    const gta4_native::LightingContext& lighting) {
  if(!scene_extent||ui||composite)return {};
  const bool screen=IsScreenExecution(executed_screen,lighting);
  const bool primary=primary_gbuffer&&!screen;
  const bool world=!screen&&(primary||(executed_geometry&&camera_match));
  const bool effect=IsSceneEffect(lighting.role)&&lighting.stage==gta4_native::RenderExecutionStage::kDeferredLighting;
  // An unclassified full-size scene write cannot certify complete motion.
  // Only executed, semantically known screen/lighting work is excluded.
  return {primary,world,effect,!screen||effect};
}
inline bool StandardDepthViewport(const gta4_native::core::SharedConstants& shared) {
  return shared.modern_effects.depth_range[0]==0.0f&&shared.modern_effects.depth_range[1]==1.0f;
}
inline bool FiniteViewport(const gta4_native::core::FixedFunctionState& fixed) {
  return std::all_of(fixed.viewport_bits.begin(),fixed.viewport_bits.end(),
      [](uint32_t bits){return std::isfinite(std::bit_cast<float>(bits));});
}
inline bool RasterHasArea(const gta4_native::core::FixedFunctionState& fixed,
                          uint32_t logical_width,uint32_t logical_height) {
  return logical_width&&logical_height&&std::bit_cast<float>(fixed.viewport_bits[2])>0&&
      std::bit_cast<float>(fixed.viewport_bits[3])>0&&
      std::clamp(fixed.scissor[2],0,int(logical_width))>std::clamp(fixed.scissor[0],0,int(logical_width))&&
      std::clamp(fixed.scissor[3],0,int(logical_height))>std::clamp(fixed.scissor[1],0,int(logical_height));
}
}  // namespace rex::graphics::gta4_metal::temporal
