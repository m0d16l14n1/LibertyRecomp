#include <catch2/catch_test_macros.hpp>

#include "graphics/gta4_metal/temporal/generation_governor.h"

using rex::graphics::gta4_metal::temporal::GenerationGovernor;
using Change = GenerationGovernor::Change;

namespace {
constexpr uint64_t kMs = 1'000'000;

// Feeds up to `seconds` of real frames, each `work_ms` of work and shown every `interval_ms`;
// stops at the first change and returns it with how many seconds in it came.
struct Run {
  Change change = Change::kNone;
  double at = -1;
};
Run Feed(GenerationGovernor& g, double work_ms, double interval_ms, double seconds,
         uint32_t refresh = 60) {
  Run run;
  for (double t = 0; t < seconds; t += interval_ms / 1000.0) {
    const Change c = g.Update(uint64_t(interval_ms * kMs), uint64_t(work_ms * kMs), refresh);
    if (c != Change::kNone) return {c, t};
  }
  return run;
}
}  // namespace

TEST_CASE("Frame generation governor stays off while real frames hold the refresh",
          "[gta4_metal][frame_generation]") {
  GenerationGovernor g;
  // 13 ms of work, shown every 16.7 ms (vsync wait): nothing to gain.
  CHECK(Feed(g, 13.0, 16.7, 10).change == Change::kNone);
  CHECK_FALSE(g.generating());
}

TEST_CASE("Frame generation governor turns on in the judder band after a second",
          "[gta4_metal][frame_generation]") {
  GenerationGovernor g;
  // 22 ms of work (about 45 fps on 60 Hz): misses vsync, and 22 + 4 fits in 33.3.
  const Run run = Feed(g, 22.0, 22.0, 5);
  CHECK(run.change == Change::kOn);
  CHECK(run.at >= 0.95);
  CHECK(run.at < 1.5);
  CHECK(g.generating());
}

TEST_CASE("Frame generation governor stays off when a pair would not fit",
          "[gta4_metal][frame_generation]") {
  GenerationGovernor g;
  // 31 ms of work (32 fps): 31 + 4 is above 1.9 refreshes, generation could not hold 30.
  CHECK(Feed(g, 31.0, 31.0, 10).change == Change::kNone);
}

TEST_CASE("Frame generation governor leaves when generating cannot hold half the refresh",
          "[gta4_metal][frame_generation]") {
  GenerationGovernor g;
  REQUIRE(Feed(g, 22.0, 22.0, 3).change == Change::kOn);
  // Now each real frame (with the interpolation) takes 38 ms: below 30 real fps.
  const Run run = Feed(g, 38.0, 38.0, 5);
  CHECK(run.change == Change::kOffSlow);
  CHECK_FALSE(g.generating());
  // The cooldown keeps it off even if the judder band returns at once.
  CHECK(Feed(g, 22.0, 22.0, 6).change == Change::kNone);
  // The failed attempt learned what generating cost (38 - 22 = 16 ms, halved with the guess):
  // 22 ms plus that no longer fits two refreshes, so the same load is not retried.
  CHECK(g.cost_ms() > 9.0);
  CHECK(Feed(g, 22.0, 22.0, 4).change == Change::kNone);
  // A lighter scene that still misses the refresh is.
  CHECK(Feed(g, 19.0, 19.0, 4).change == Change::kOn);
}

TEST_CASE("Frame generation governor leaves once real frames would fit the refresh",
          "[gta4_metal][frame_generation]") {
  GenerationGovernor g;
  REQUIRE(Feed(g, 22.0, 22.0, 3).change == Change::kOn);
  // Generating, paced to 30: 27 ms of work learns a 5 ms interpolation cost.
  CHECK(Feed(g, 27.0, 33.3, 2).change == Change::kNone);
  CHECK(g.cost_ms() > 4.0);
  CHECK(g.cost_ms() < 5.5);
  // The scene lightens: 17 ms of work, 12 without the interpolation, fits 16.7 with room.
  const Run run = Feed(g, 17.0, 33.3, 5);
  CHECK(run.change == Change::kOffFast);
  CHECK(run.at >= 1.9);
}

TEST_CASE("Frame generation governor scales with the refresh", "[gta4_metal][frame_generation]") {
  GenerationGovernor g;
  // 120 Hz: 10 ms of work (100 fps) misses 8.3 ms; 10 + 4 fits in 15.8.
  CHECK(Feed(g, 10.0, 10.0, 3, 120).change == Change::kOn);
  GenerationGovernor h;
  CHECK(Feed(h, 7.5, 8.3, 5, 120).change == Change::kNone);
}

TEST_CASE("Frame generation governor starts over after a hitch", "[gta4_metal][frame_generation]") {
  GenerationGovernor g;
  Feed(g, 22.0, 22.0, 0.8);
  // A 300 ms load hitch resets the band timer.
  g.Update(300 * kMs, 300 * kMs, 60);
  const Run run = Feed(g, 22.0, 22.0, 3);
  CHECK(run.change == Change::kOn);
  CHECK(run.at >= 0.95);
}

TEST_CASE("Frame generation governor leaves when pairs are not kept on time, and backs off",
          "[gta4_metal][frame_generation]") {
  GenerationGovernor g;
  REQUIRE(Feed(g, 22.0, 22.0, 3).change == Change::kOn);
  // Paced to 30, only every other real frame gets its midpoint.
  Run run;
  bool paired = false;
  for (double t = 0; t < 3; t += 0.0333) {
    paired = !paired;
    const Change c = g.Update(33'300'000, 26'000'000, 60, paired);
    if (c != Change::kNone) { run = {c, t}; break; }
  }
  CHECK(run.change == Change::kOffUnpaired);
  CHECK(run.at >= 1.4);
  CHECK(run.at < 1.7);
  CHECK(g.failures() == 1);
  // First failure: 8 s cooldown.
  CHECK(Feed(g, 20.0, 20.0, 7.5).change == Change::kNone);
  REQUIRE(Feed(g, 20.0, 20.0, 3).change == Change::kOn);
  for (double t = 0; t < 3; t += 0.0333)
    if (g.Update(33'300'000, 22'000'000, 60, false) != Change::kNone) break;
  CHECK(g.failures() == 2);
  // Second failure in a row: 16 s.
  CHECK(Feed(g, 20.0, 20.0, 15.5).change == Change::kNone);
  CHECK(Feed(g, 20.0, 20.0, 3).change == Change::kOn);
}
