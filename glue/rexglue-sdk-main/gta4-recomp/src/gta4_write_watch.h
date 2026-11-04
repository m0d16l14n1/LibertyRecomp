#pragma once

#include <cstdint>

namespace gta4::write_watch {

// Once per game frame on the game thread (called from CTimer::Update): (re)arms the watch the
// gta4_watch_write cvar describes and logs what it caught.
void Tick(uint8_t* base);

}  // namespace gta4::write_watch
