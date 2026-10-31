#include "shared_guest_memory.h"

#include <memory>
#include <string>

#include <catch2/catch_test_macros.hpp>

#include <rex/logging.h>

namespace rex::test {
namespace {
std::unique_ptr<memory::Memory> g_memory;
std::string g_owner;
}  // namespace

memory::Memory& SharedGuestMemory(std::string_view owner) {
  if (g_memory && g_owner == owner) return *g_memory;
  ReleaseSharedGuestMemory();
  rex::InitLogging();
  auto created = std::make_unique<memory::Memory>();
  REQUIRE(created->Initialize());
  g_memory = std::move(created);
  g_owner = owner;
  return *g_memory;
}

void ReleaseSharedGuestMemory() {
  g_memory.reset();
  g_owner.clear();
}

}  // namespace rex::test
