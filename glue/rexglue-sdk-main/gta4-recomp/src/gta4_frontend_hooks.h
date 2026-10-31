#pragma once

#include <cstdint>
#include <filesystem>
#include <string_view>

#include "gta4_frontend_menu_policy.h"

struct PPCContext;

namespace gta4 {

// Renderer used when gpu_plugin is unset. This fork is developed on Apple Silicon, where the
// native Metal renderer is the supported path; elsewhere the Vulkan renderer stays the default.
#if defined(__APPLE__)
inline constexpr std::string_view kDefaultGpuPlugin = "gta4-metal";
#else
inline constexpr std::string_view kDefaultGpuPlugin = "gta4-native";
#endif

}  // namespace gta4

namespace gta4::frontend_menu {

void SetConfigPath(std::filesystem::path path);
void DrawSliders(PPCContext& ctx, uint8_t* base);
bool SwitchPauseTab(PPCContext& parent, uint8_t* base, policy::PauseTabDirection direction,
                    uint32_t* previous_screen = nullptr, uint32_t* target_screen = nullptr);

}  // namespace gta4::frontend_menu
