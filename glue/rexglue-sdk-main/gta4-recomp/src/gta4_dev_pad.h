#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include <rex/runtime.h>

struct PPCContext;

namespace rex::input {
struct X_INPUT_STATE;
namespace mnk {
struct NativeInputState;
}
}  // namespace rex::input

namespace rex::ui {
class WindowedAppContext;
}

namespace gta4::dev_pad {

// Scripted controller input for unattended runs (gta4_pad_script / gta4_pad_pipe).
// Configure runs from OnPreSetup (adds the synthetic driver), Start from OnPostSetup.
void Configure(rex::RuntimeConfig& config);
void Start(rex::ui::WindowedAppContext* app_context);

// Input recording and replay for benches (gta4_input_record / gta4_input_replay). Both start
// when the first loading screen ends (the save is loaded) and use the time since then, so a
// replay at another frame rate gets the same input at the same moments: the keyboard and
// mouse sample of each poll is the recorded mouse motion over that span plus the keys held
// at its end, and the pad is served through the script pad.
struct PollContext {
  uint8_t* base = nullptr;
  bool loading = false;      // the loading screen flag (0x831D5335)
  float time_step = 0.0f;    // the gameplay time step; 0 while the world is not running
  uint32_t player_ped = 0;   // for the route (position), 0 if none
};
// Called from the native input poll (CaptureEpoch). In replay, overwrites the keyboard and
// mouse sample; while recording, writes this poll's sample and pad state.
void OnInputPoll(const PollContext& context, bool& native_valid,
                 rex::input::mnk::NativeInputState& state, bool gamepad_valid,
                 const rex::input::X_INPUT_STATE& gamepad);

// World control (gta4_dev_world.cpp): dev pad commands that call script natives from inside a
// script thread (teleport, road, car, drive, clock, weather, invincible, nowanted).
bool WorldEnabled();  // the dev pad is on: wrap WAIT and keep the native table
// From the native registration (sub_82845600): records name -> handler, wraps WAIT.
void ObserveNativeRegistration(PPCContext& ctx, uint8_t* base);
std::string WorldCommand(const std::vector<std::string>& args);

}  // namespace gta4::dev_pad
