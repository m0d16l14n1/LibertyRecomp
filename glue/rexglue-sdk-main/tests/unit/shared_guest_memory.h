#pragma once

#include <string_view>

#include <rex/system/xmemory.h>

namespace rex::test {

// Only one guest Memory may be live in a process (Memory::active_memory_ and the global MMIO
// handler), so tests share this one instead of keeping a static instance per file. A different
// owner gets a fresh instance (the previous one is destroyed first), so each test file still sees
// its own heap state.
memory::Memory& SharedGuestMemory(std::string_view owner);

// Destroys the shared instance, for tests that construct a Runtime with its own memory.
void ReleaseSharedGuestMemory();

}  // namespace rex::test
