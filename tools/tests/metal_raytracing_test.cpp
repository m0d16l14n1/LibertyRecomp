// CPU-side ray-tracing policy: acceleration-structure cache keying, budgets and eviction.
#include "graphics/gta4_metal/raytracing/accel_cache.h"
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

using namespace rex::graphics::gta4_metal::raytracing;
static int checks = 0;
#define CHECK(x) do { ++checks; if (!(x)) { std::printf("raytracing policy failed at line %d: %s\n", __LINE__, #x); std::exit(1); } } while (0)

using Cache = AccelCache<std::string>;
static CaptureRequest Mesh(uint64_t geometry, uint64_t motion, uint32_t triangles = 100, bool dynamic = false) {
  return {{geometry, triangles, triangles * 2}, motion, dynamic};
}
// Plays the renderer's part: a build is encoded and reported with its real size.
static CaptureAction Draw(Cache& cache, const CaptureRequest& request, uint64_t bytes = 0) {
  const auto decision = cache.Request(request);
  if (decision.action == CaptureAction::kBuild)
    cache.Built(*decision.slot, bytes ? bytes : request.identity.triangles * 64ull, "blas" + std::to_string(request.identity.geometry));
  return decision.action;
}

int main() {
  std::vector<std::string> released;
  const auto release = [&](std::string& payload) { released.push_back(payload); };
  {  // static geometry: built once, then only instanced
    Cache cache;
    cache.BeginFrame(1);
    CHECK(Draw(cache, Mesh(1, 10)) == CaptureAction::kBuild);
    CHECK(cache.scene().size() == 1);
    cache.EndFrame(release);
    for (uint64_t frame = 2; frame < 5; ++frame) {
      cache.BeginFrame(frame);
      CHECK(Draw(cache, Mesh(1, 10)) == CaptureAction::kReuse);
      CHECK(cache.scene().size() == 1 && cache.scene()[0]->payload == "blas1");
      cache.EndFrame(release);
    }
    CHECK(cache.statistics().built == 1 && cache.statistics().reused == 3);
  }
  {  // movers refit; topology changes rebuild; dynamic geometry refits every frame
    Cache cache;
    cache.BeginFrame(1);
    Draw(cache, Mesh(1, 10)); Draw(cache, Mesh(2, 20, 50, true));
    cache.EndFrame(release);
    cache.BeginFrame(2);
    CHECK(Draw(cache, Mesh(1, 11)) == CaptureAction::kRefit);        // the car moved
    CHECK(Draw(cache, Mesh(2, 20, 50, true)) == CaptureAction::kRefit);  // skinned: always
    cache.EndFrame(release);
    cache.BeginFrame(3);
    CHECK(Draw(cache, Mesh(1, 11)) == CaptureAction::kReuse);        // parked again
    CHECK(Draw(cache, Mesh(2, 20, 80, true)) == CaptureAction::kBuild);  // LOD switch: new topology
    cache.EndFrame(release);
    CHECK(cache.statistics().rebuilt == 1 && cache.statistics().refit == 2);
    CHECK(cache.size() == 2);
  }
  {  // one mesh drawn twice in a frame: two slots, told apart by draw order
    Cache cache;
    cache.BeginFrame(1);
    CHECK(Draw(cache, Mesh(7, 1)) == CaptureAction::kBuild);
    CHECK(Draw(cache, Mesh(7, 2)) == CaptureAction::kBuild);
    CHECK(cache.scene().size() == 2 && cache.scene()[0] != cache.scene()[1]);
    cache.EndFrame(release);
    cache.BeginFrame(2);
    CHECK(Draw(cache, Mesh(7, 1)) == CaptureAction::kReuse && Draw(cache, Mesh(7, 2)) == CaptureAction::kReuse);
    cache.EndFrame(release);
  }
  {  // per-frame budgets: builds wait for later frames; movers go stale, never missing
    AccelBudget budget; budget.builds_per_frame = 2; budget.refits_per_frame = 1;
    Cache cache(budget);
    cache.BeginFrame(1);
    CHECK(Draw(cache, Mesh(1, 1)) == CaptureAction::kBuild);
    CHECK(Draw(cache, Mesh(2, 1)) == CaptureAction::kBuild);
    CHECK(Draw(cache, Mesh(3, 1)) == CaptureAction::kSkip);
    CHECK(cache.scene().size() == 2);
    cache.EndFrame(release);
    cache.BeginFrame(2);
    CHECK(Draw(cache, Mesh(1, 2)) == CaptureAction::kRefit);
    CHECK(Draw(cache, Mesh(2, 2)) == CaptureAction::kReuse);  // refits ran out: stale but present
    CHECK(Draw(cache, Mesh(3, 1)) == CaptureAction::kBuild);
    CHECK(cache.scene().size() == 3);
    cache.EndFrame(release);
    CHECK(cache.statistics().stale == 1 && cache.statistics().skipped_builds == 1);
    cache.BeginFrame(3);
    CHECK(Draw(cache, Mesh(2, 2)) == CaptureAction::kRefit);  // the stale one catches up next frame
    cache.EndFrame(release);
  }
  {  // byte budget: least recently used slots make room; this frame's scene is never evicted
    AccelBudget budget; budget.total_bytes = 3 * 100 * 64; budget.estimated_bytes_per_triangle = 64;
    Cache cache(budget);
    released.clear();
    for (uint64_t frame = 1; frame <= 3; ++frame) {
      cache.BeginFrame(frame);
      CHECK(Draw(cache, Mesh(frame, 1)) == CaptureAction::kBuild);
      cache.EndFrame(release);
    }
    CHECK(cache.resident_bytes() == 3 * 6400 && released.empty());
    cache.BeginFrame(4);
    CHECK(Draw(cache, Mesh(2, 1)) == CaptureAction::kReuse);
    CHECK(Draw(cache, Mesh(4, 1)) == CaptureAction::kBuild);  // evicts mesh 1, the oldest
    cache.EndFrame(release);
    CHECK(released.size() == 1 && released[0] == "blas1");
    CHECK(cache.size() == 3 && cache.resident_bytes() <= budget.total_bytes);
    cache.BeginFrame(5);
    CHECK(Draw(cache, Mesh(2, 1)) == CaptureAction::kReuse);
    CHECK(Draw(cache, Mesh(3, 1)) == CaptureAction::kReuse);
    CHECK(Draw(cache, Mesh(4, 1)) == CaptureAction::kReuse);
    CHECK(Draw(cache, Mesh(9, 1, 400)) == CaptureAction::kSkip);  // only this frame's slots remain
    CHECK(cache.statistics().skipped_bytes == 1);
    cache.EndFrame(release);
  }
  {  // real sizes replace estimates; unused slots age out; abandoned builds are retried
    AccelBudget budget; budget.retain_frames = 2;
    Cache cache(budget);
    released.clear();
    cache.BeginFrame(1);
    Draw(cache, Mesh(1, 1), 1000);
    CHECK(cache.resident_bytes() == 1000);
    auto pending = cache.Request(Mesh(2, 1));
    CHECK(pending.action == CaptureAction::kBuild);
    cache.Abandon(*pending.slot);
    CHECK(cache.size() == 1 && cache.resident_bytes() == 1000);
    cache.EndFrame(release);
    cache.BeginFrame(2);
    CHECK(Draw(cache, Mesh(2, 1)) == CaptureAction::kBuild);
    cache.EndFrame(release);
    cache.BeginFrame(4);
    cache.EndFrame(release);
    CHECK(released.size() == 1 && released[0] == "blas1" && cache.size() == 1);
    cache.Clear(release);
    CHECK(released.size() == 2 && cache.size() == 0 && cache.resident_bytes() == 0);
  }
  {  // a build requested but never reported is not instanced and is rebuilt next frame
    Cache cache;
    cache.BeginFrame(1);
    CHECK(cache.Request(Mesh(5, 1)).action == CaptureAction::kBuild);
    CHECK(cache.scene().empty());
    cache.EndFrame(release);
    cache.BeginFrame(2);
    CHECK(Draw(cache, Mesh(5, 1)) == CaptureAction::kBuild);
    CHECK(cache.scene().size() == 1);
    cache.EndFrame(release);
  }
  std::printf("raytracing policy: %d checks passed\n", checks);
}
