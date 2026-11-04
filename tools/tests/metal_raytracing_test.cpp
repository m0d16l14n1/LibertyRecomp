// CPU-side ray-tracing policy: acceleration-structure cache keying, budgets and eviction,
// the capture policy (geometry identity, placement, clip-to-world, triangle lists) and
// the sun-shadow policy (view, sun direction, cone, instance masks).
#include "graphics/gta4_metal/raytracing/accel_cache.h"
#include "graphics/gta4_metal/raytracing/capture_policy.h"
#include "graphics/gta4_metal/raytracing/shadow_policy.h"
#include <cmath>
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

static std::vector<uint32_t> Indices(const std::optional<TriangleList>& list) { return list ? list->indices : std::vector<uint32_t>{}; }

static void CapturePolicy() {
  namespace t = rex::graphics::gta4_native::temporal;
  {  // identity: what is drawn, not where, by whom or with which pixel shader
    t::GeometryKey a;
    a.vertex_shader = 11; a.layout = 12; a.geometry_generation = 13; a.range = 14; a.index_generation = 15;
    a.primitive = 4; a.indexed = true; a.streams[0] = {16, 0, 32};
    auto b = a;
    b.instance = 99; b.drawable = 98; b.pose = 97; b.pixel_shader = 96; b.occurrence = 3;
    CHECK(GeometryIdentityOf(a) == GeometryIdentityOf(b));
    auto c = a; c.streams[0].generation = 17;  // vertex data replaced
    CHECK(GeometryIdentityOf(a) != GeometryIdentityOf(c));
    auto d = a; d.indexed = false;
    CHECK(GeometryIdentityOf(a) != GeometryIdentityOf(d));
    auto e = a; e.base_vertex = 4;
    CHECK(GeometryIdentityOf(a) != GeometryIdentityOf(e));
  }
  {  // placement: hash of the world registers the shader reads; a0 palettes are dynamic
    std::array<uint8_t, 4096> bank{};
    const std::array<uint64_t, 4> world{0xF, 0, 0, 0}, wheel{0, 0xF, 0, 0}, skinned{0xF, 0xF, ~0ull, ~0ull};
    const auto base = PlacementOf(world, bank);
    bank[16 * 68] = 1;  // c68: not read as a world register
    CHECK(PlacementOf(world, bank).motion == base.motion);
    bank[16 * 2 + 4] = 1;  // c2 moved
    CHECK(PlacementOf(world, bank).motion != base.motion);
    const auto wheel_before = PlacementOf(wheel, bank);
    bank[16 * 65] = 1;  // matWheelTransform
    CHECK(PlacementOf(wheel, bank).motion != wheel_before.motion);
    CHECK(!base.dynamic && PlacementOf(skinned, bank).dynamic);
  }
  {  // clip-to-world: a view-space point projected and taken back lands where it started
    t::CameraMatrix projection{1.5f, 0, 0, 0, 0, 2.0f, 0, 0, 0, 0, 1.001f, 1, 0, 0, -0.1001f, 0};
    t::CameraMatrix camera_to_world{0, 0, -1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 10, 20, 30, 1};  // turned 90 degrees, moved
    const auto m = ClipToWorldColumns(projection, camera_to_world);
    CHECK(m.has_value());
    const float view[4]{1, 2, 5, 1};
    float clip[4]{}, world[4]{}, expected[4]{};
    for (int j = 0; j < 4; ++j) for (int i = 0; i < 4; ++i) clip[j] += view[i] * projection[i * 4 + j];
    for (int j = 0; j < 4; ++j) for (int i = 0; i < 4; ++i) expected[j] += view[i] * camera_to_world[i * 4 + j];
    // Columns: element (row r, column c) of the column-vector matrix is (*m)[c * 4 + r].
    for (int r = 0; r < 4; ++r) for (int c = 0; c < 4; ++c) world[r] += (*m)[c * 4 + r] * clip[c];
    for (int k = 0; k < 3; ++k) CHECK(std::fabs(world[k] / world[3] - expected[k]) < 1e-3f);
    t::CameraMatrix singular{};
    CHECK(!ClipToWorldColumns(singular, camera_to_world).has_value());
  }
  {  // triangle lists: relative to the lowest vertex, degenerates dropped, strips split at restarts
    const std::vector<uint32_t> list{10, 11, 12, 12, 12, 13, 13, 14, 15};
    auto l = BuildTriangleList(Topology::kList, 9, [&](uint32_t i) { return list[i]; }, 100, std::nullopt);
    CHECK(l && l->first_vertex == 110 && l->vertex_count == 6);
    CHECK((Indices(l) == std::vector<uint32_t>{0, 1, 2, 3, 4, 5}));
    const std::vector<uint32_t> strip{0, 1, 2, 3, 0xFFFF, 5, 6, 7, 7, 8};
    auto s = BuildTriangleList(Topology::kStrip, uint32_t(strip.size()), [&](uint32_t i) { return strip[i]; }, 0,
                               std::optional<uint32_t>(0xFFFF));
    CHECK(s && s->first_vertex == 0 && s->vertex_count == 8);  // vertex 8 is only in degenerates
    // 0-1-2, 1-2-3 | 5-6-7, (6-7-7 and 7-7-8 degenerate)
    CHECK((Indices(s) == std::vector<uint32_t>{0, 1, 2, 1, 2, 3, 5, 6, 7}));
    auto n = BuildTriangleList(Topology::kList, 6, [](uint32_t i) { return 40 + i; }, 0, std::nullopt);
    CHECK(n && n->first_vertex == 40 && (Indices(n) == std::vector<uint32_t>{0, 1, 2, 3, 4, 5}));
    auto empty = BuildTriangleList(Topology::kList, 3, [](uint32_t) { return 7u; }, 0, std::nullopt);
    CHECK(empty && empty->indices.empty());
    const std::vector<uint32_t> wide{0, 1, kMaximumCapturedVertices};
    CHECK(!BuildTriangleList(Topology::kList, 3, [&](uint32_t i) { return wide[i]; }, 0, std::nullopt));
    CHECK(!BuildTriangleList(Topology::kList, 3, [](uint32_t i) { return i; }, -1, std::nullopt));
  }
  {  // cache identity: index count or primitive change forces a rebuild
    CHECK(CacheIdentityOf(5, Topology::kList, 30).triangles == 10);
    CHECK(CacheIdentityOf(5, Topology::kStrip, 30).triangles == 28);
    CHECK(!(CacheIdentityOf(5, Topology::kList, 30) == CacheIdentityOf(5, Topology::kStrip, 30)));
    CHECK(!(CacheIdentityOf(5, Topology::kList, 30) == CacheIdentityOf(5, Topology::kList, 33)));
  }
}

static void ShadowPolicy() {
  {  // the view cvar: anything unknown keeps the default
    CHECK(ParseShadowView("combine") == ShadowView::kCombine);
    CHECK(ParseShadowView("replace") == ShadowView::kReplace);
    CHECK(ParseShadowView("show") == ShadowView::kShow);
    CHECK(ParseShadowView("none") == ShadowView::kNone);
    CHECK(ParseShadowView("") == ShadowView::kCombine && ParseShadowView("Replace") == ShadowView::kCombine);
    CHECK(ShadowViewUsesVariant(ShadowView::kCombine) && ShadowViewUsesVariant(ShadowView::kReplace));
    CHECK(!ShadowViewUsesVariant(ShadowView::kShow) && !ShadowViewUsesVariant(ShadowView::kNone));
  }
  {  // gDirectionalLight is where the light goes: rays go the other way, normalised
    const auto noon = TowardsSun({0.0f, 0.0f, -2.0f, 1.0f});
    CHECK(noon && (*noon)[0] == 0.0f && (*noon)[1] == 0.0f && (*noon)[2] == 1.0f);
    const auto low = TowardsSun({-3.0f, 0.0f, -4.0f, 0.0f});  // w (the title's own use) is ignored
    CHECK(low && std::fabs((*low)[0] - 0.6f) < 1e-6f && std::fabs((*low)[2] - 0.8f) < 1e-6f);
    CHECK(!TowardsSun({0.0f, 0.0f, 0.0f, 1.0f}));  // lightNoDirectional: no sun
    CHECK(!TowardsSun({NAN, 0.0f, -1.0f, 1.0f}) && !TowardsSun({0.0f, INFINITY, -1.0f, 1.0f}));
    CHECK(!TowardsSun({1e-6f, 0.0f, 0.0f, 1.0f}));
  }
  {  // the cone: degrees to a tangent, hard at 0, at most 5 degrees
    CHECK(ConeTangent(0.0) == 0.0f && ConeTangent(-1.0) == 0.0f && ConeTangent(NAN) == 0.0f);
    CHECK(std::fabs(ConeTangent(0.5) - 0.0087269f) < 1e-6f);
    CHECK(ConeTangent(45.0) == ConeTangent(5.0));
  }
  {  // masks: AO rays (0xFF) see everything, shadow rays skip cut-outs unless foliage is on
    CHECK(InstanceMaskOf(false) == kInstanceMaskOpaque && InstanceMaskOf(true) == kInstanceMaskAlphaTested);
    CHECK((ShadowRayMask(false) & InstanceMaskOf(false)) != 0 && (ShadowRayMask(false) & InstanceMaskOf(true)) == 0);
    CHECK((ShadowRayMask(true) & InstanceMaskOf(false)) != 0 && (ShadowRayMask(true) & InstanceMaskOf(true)) != 0);
    CHECK((0xFFu & InstanceMaskOf(true)) != 0 && (0xFFu & InstanceMaskOf(false)) != 0);
  }
}

int main() {
  CapturePolicy();
  ShadowPolicy();
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
