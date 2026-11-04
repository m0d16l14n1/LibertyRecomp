#pragma once
// CPU-only parts of the ray-traced sun shadows (sun_shadows.h), kept free of Metal so they
// can be tested: the view cvar, the sun direction from the lighting constants, the cone of
// the soft-shadow rays and which captured instances the rays test.
#include <array>
#include <cmath>
#include <cstdint>
#include <optional>
#include <string_view>

namespace rex::graphics::gta4_metal::raytracing {

// Instance masks of captured geometry (Capture: DrawGeometry::alpha_tested). AO rays test
// every instance; shadow rays leave alpha-tested cards (foliage, fences) to the cascade,
// since the structures are opaque and a leaf card would cast a solid quad.
inline constexpr uint32_t kInstanceMaskOpaque = 1u, kInstanceMaskAlphaTested = 2u;
inline constexpr uint32_t InstanceMaskOf(bool alpha_tested) {
  return alpha_tested ? kInstanceMaskAlphaTested : kInstanceMaskOpaque;
}
inline constexpr uint32_t ShadowRayMask(bool foliage) {
  return foliage ? kInstanceMaskOpaque | kInstanceMaskAlphaTested : kInstanceMaskOpaque;
}

// gta4_metal_raytracing_shadow_view = combine | replace | show | none
// combine: the lighting variant takes min(cascade, traced): the cascade keeps casters the
//          capture does not have (off screen, foliage), the trace adds contact detail and
//          shadows past the cascade's range.
// replace: the traced visibility alone (to judge the trace; loses off-screen casters).
// show:    the traced visibility in grey over the lighting output.
// none:    trace only (cost measurement).
enum class ShadowView : uint8_t { kCombine, kReplace, kShow, kNone };
inline ShadowView ParseShadowView(std::string_view value) {
  if (value == "replace") return ShadowView::kReplace;
  if (value == "show") return ShadowView::kShow;
  if (value == "none") return ShadowView::kNone;
  return ShadowView::kCombine;
}
// Whether the lighting draw uses the shadow variant of its pixel shader.
inline constexpr bool ShadowViewUsesVariant(ShadowView view) {
  return view == ShadowView::kCombine || view == ShadowView::kReplace;
}

// gDirectionalLight (pixel c17) is the direction the sunlight travels, in the G-buffer
// normal's world space: the lighting shader takes saturate(dot(N, -gDirectionalLight.xyz)).
// Rays go the other way. No sun (zero or non-finite, e.g. lightNoDirectional at night): nullopt.
inline std::optional<std::array<float, 3>> TowardsSun(const std::array<float, 4>& directional_light) {
  const float x = -directional_light[0], y = -directional_light[1], z = -directional_light[2];
  if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z)) return std::nullopt;
  const float length = std::sqrt(x * x + y * y + z * z);
  if (!(length > 1.0e-4f)) return std::nullopt;
  return std::array<float, 3>{x / length, y / length, z / length};
}

// Tangent of the cone the shadow rays sample (the sun's apparent angular radius); 0 gives
// hard shadows. Clamped to [0, 5] degrees.
inline float ConeTangent(double degrees) {
  if (!std::isfinite(degrees) || degrees <= 0.0) return 0.0f;
  return float(std::tan(std::fmin(degrees, 5.0) * 3.14159265358979323846 / 180.0));
}

}  // namespace rex::graphics::gta4_metal::raytracing
