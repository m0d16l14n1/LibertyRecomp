#pragma once

#include <rex/runtime.h>

namespace rex::ui {
class WindowedAppContext;
}

namespace gta4::dev_pad {

// Scripted controller input for unattended runs (gta4_pad_script / gta4_pad_pipe).
// Configure runs from OnPreSetup (adds the synthetic driver), Start from OnPostSetup.
void Configure(rex::RuntimeConfig& config);
void Start(rex::ui::WindowedAppContext* app_context);

}  // namespace gta4::dev_pad
