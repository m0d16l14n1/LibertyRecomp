#include "graphics/gta4_metal/constant_range_shadow.h"
#include <cstdio>
#include <cstdlib>
#include <initializer_list>

using namespace rex::graphics::gta4_metal;
static int checks = 0;
#define CHECK(x) do { ++checks; if (!(x)) { std::printf("constant range shadow failed at line %d: %s\n", __LINE__, #x); std::exit(1); } } while (0)

static std::array<uint64_t, 4> Mask(std::initializer_list<int> registers) {
  std::array<uint64_t, 4> m{};
  for (const int r : registers) m[r / 64] |= 1ull << (r % 64);
  return m;
}
static void Put(std::array<uint8_t, 4096>& bank, int reg, uint8_t value) { bank[reg * 16] = value; }

int main() {
  {  // ranges from read masks
    const auto tire = RangeOf(Mask({4, 5, 6, 8, 9, 10, 11, 64, 65, 66, 67, 68, 69}), 256);
    CHECK(!tire.empty && tire.lo == 4 && tire.hi == 69 && tire.registers() == 66);
    std::array<uint64_t, 4> bones = Mask({3, 8});
    bones[1] = bones[2] = bones[3] = ~0ull;  // a0 indexing: c64..c255
    const auto bone = RangeOf(bones, 256);
    CHECK(bone.lo == 3 && bone.hi == 255);
    const auto ps = RangeOf({~0ull, ~0ull, ~0ull, ~0ull}, 224);  // all-ones on the 224-register pixel bank
    CHECK(ps.lo == 0 && ps.hi == 223);
    CHECK(RangeOf(Mask({}), 256).empty && RangeOf(Mask({}), 256).registers() == 0);
    CHECK(RangeOf(Mask({230, 240}), 224).empty);  // nothing inside the pixel bank
    CHECK(RangeOf(Mask({10, 230}), 224).lo == 10 && RangeOf(Mask({10, 230}), 224).hi == 10);    // c230 is outside the bank
    CHECK(RangeOf(Mask({200, 230}), 224).lo == 200 && RangeOf(Mask({200, 230}), 224).hi == 223);  // clamped, never past it
    CHECK(RangeOf(Mask({63}), 256).lo == 63 && RangeOf(Mask({63}), 256).hi == 63);
    CHECK(tire.Contains(RangeOf(Mask({8, 60}), 256)) && !tire.Contains(bone) && tire.Contains(ConstantRange{}));
  }
  const auto range = [](uint32_t lo, uint32_t hi) { return ConstantRange{lo, hi, false}; };
  {  // a miss uploads only the range; equal bytes inside it hit the last bank
    ConstantRangeShadow s;
    std::array<uint8_t, 4096> g{};
    s.Observe(0, g, range(4, 69), false);
    Put(g, 100, 7);  // outside the range: still the same upload
    s.Observe(0, g, range(4, 69), false);
    s.Observe(0, g, range(8, 11), false);  // contained
    Put(g, 9, 1);
    s.Observe(0, g, range(8, 11), false);  // changed inside: new upload
    const auto& r = s.statistics(0);
    CHECK(r.requests == 4 && r.last_hits == 2 && r.misses == 2 && r.bytes == 66 * 16 + 4 * 16);
  }
  {  // exact-range hash hits within a command buffer; Clear() forgets them
    ConstantRangeShadow s;
    std::array<uint8_t, 4096> a{}, b{};
    Put(b, 20, 3);
    s.Observe(0, a, range(0, 31), false);
    s.Observe(0, b, range(0, 31), false);
    s.Observe(0, a, range(0, 31), false);  // last bank is b: hash hit
    s.Observe(0, b, range(0, 15), false);  // c20 is outside: last-bank hit on a
    s.Observe(0, b, range(0, 31), false);  // last range is a's 0..31: hash hit for b
    CHECK(s.statistics(0).misses == 2 && s.statistics(0).hash_hits == 2 && s.statistics(0).last_hits == 1);
    s.Clear();
    s.Observe(0, a, range(0, 31), false);  // last bank (b) differs at c20; no hash entry left
    CHECK(s.statistics(0).misses == 3);
    s.Reset();
    s.Observe(0, a, range(0, 31), false);  // last bank forgotten too
    CHECK(s.statistics(0).misses == 4 && s.statistics(0).last_hits == 1);
  }
  {  // a clean skip holds only when the last range covers the new one
    ConstantRangeShadow s;
    std::array<uint8_t, 4096> g{};
    s.Observe(0, g, range(4, 11), false);
    s.Observe(0, g, range(8, 9), true);
    s.Observe(0, g, range(0, 64), true);  // wider: the clean skip would read stale c0..c3
    s.Observe(0, g, range(4, 11), true);  // now covered by 0..64
    const auto& r = s.statistics(0);
    CHECK(r.clean_hits == 2 && r.clean_uncovered == 1 && r.misses == 2);
  }
  {  // empty ranges cost nothing; banks are independent; the hash seed keeps ranges apart
    ConstantRangeShadow s;
    std::array<uint8_t, 4096> g{};
    s.Observe(1, g, ConstantRange{}, true);
    CHECK(s.statistics(1).empty == 1 && s.statistics(1).misses == 0);
    s.Observe(1, std::span(g).first(0xE00), range(0, 223), false);
    s.Observe(0, g, range(0, 223), false);  // same bytes, other bank: its own upload
    s.Observe(0, g, range(0, 15), false);
    s.Observe(0, g, range(1, 16), false);   // contained in 0..223: last-bank hit
    CHECK(s.statistics(1).misses == 1 && s.statistics(1).bytes == 0xE00);
    CHECK(s.statistics(0).misses == 1 && s.statistics(0).last_hits == 2);
    s.Observe(1, std::span(g).first(0xE00), range(200, 255), false);  // hi past the bank is clamped
    CHECK(s.statistics(1).last_hits == 1);
  }
  {  // many distinct versions grow the table without losing entries
    ConstantRangeShadow s;
    std::array<uint8_t, 4096> g{};
    for (int i = 0; i < 5000; ++i) { g[0] = uint8_t(i); g[1] = uint8_t(i >> 8); s.Observe(0, g, range(0, 0), false); }
    for (int i = 0; i < 5000; i += 7) { g[0] = uint8_t(i); g[1] = uint8_t(i >> 8); s.Observe(0, g, range(0, 0), false); }
    CHECK(s.statistics(0).misses == 5000 && s.statistics(0).hash_hits + s.statistics(0).last_hits == 715);
  }
  std::printf("constant range shadow: %d checks passed\n", checks);
}
