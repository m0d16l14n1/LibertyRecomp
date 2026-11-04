#pragma once
// CPU-only parts of geometry capture, kept free of Metal so they can be tested:
// the draw's geometry identity and placement, its triangle list, and the
// clip-to-world transform the capture variant applies.
#include "accel_cache.h"
#include "../../gta4_native/temporal/camera_math.h"
#include "../../gta4_native/temporal/geometry_history.h"
#include <array>
#include <cstdint>
#include <cstring>
#include <optional>
#include <span>
#include <vector>

#include <xxhash.h>

namespace rex::graphics::gta4_metal::raytracing {

// What a draw is, never where it is: the temporal GeometryKey without its owner
// (the world transform), drawable/pose scope, pixel shader or occurrence.
inline uint64_t GeometryIdentityOf(const gta4_native::temporal::GeometryKey& key) {
  std::array<uint64_t, 8 + 3 * 17> words{};
  size_t n = 0;
  for (const uint64_t v : {key.vertex_shader, key.layout, key.geometry_generation, key.range, key.index_generation,
                           uint64_t(uint32_t(key.base_vertex)), uint64_t(key.primitive) | uint64_t(key.restart) << 32 | uint64_t(key.indexed) << 33,
                           uint64_t(key.restart_index)})
    words[n++] = v;
  for (const auto& stream : key.streams) {
    words[n++] = stream.generation; words[n++] = stream.offset; words[n++] = stream.stride;
  }
  return XXH3_64bits(words.data(), n * sizeof(uint64_t));
}

struct Placement {
  uint64_t motion = 0;   // hash of the transform registers the shader reads
  bool dynamic = false;  // indexes a bone palette: positions change without the hash showing it
};
// `reads` is the vertex shader's archive v3 read mask; `bank` the draw's host-order VS bank.
inline Placement PlacementOf(const std::array<uint64_t, 4>& reads, std::span<const uint8_t, 4096> bank) {
  const auto world = gta4_native::temporal::WorldRegisters(reads);
  std::array<uint8_t, 8 * 16> registers{};
  size_t n = 0;
  for (uint32_t r = 0; r < 256 && n < 8; ++r)
    if ((world[r / 64] >> (r % 64)) & 1) std::memcpy(registers.data() + 16 * n++, bank.data() + 16 * r, 16);
  Placement placement;
  placement.motion = XXH3_64bits(registers.data(), n * 16);
  // a0-relative reads mark the whole tail of the bank (archive v3): a skinning palette.
  placement.dynamic = reads[2] == ~0ull && reads[3] == ~0ull;
  return placement;
}

// Title cameras use row vectors: clip = world * inverse(cameraToWorld) * projection.
// The capture variant computes world = M * clip with column vectors, so M is
// inverse(projection) * cameraToWorld laid out with each title row as a column.
inline std::optional<std::array<float, 16>> ClipToWorldColumns(const gta4_native::temporal::CameraMatrix& projection,
                                                               const gta4_native::temporal::CameraMatrix& camera_to_world) {
  const auto inverse = gta4_native::temporal::InverseCameraMatrix(projection);
  if (!inverse) return {};
  return gta4_native::temporal::MultiplyCameraMatrices(*inverse, camera_to_world);
}

// A triangle list for a primitive acceleration structure, relative to the first
// vertex the draw uses. Restart indices split strips; degenerate triangles (strip
// joins) are dropped. Winding is irrelevant: captured geometry is traced two-sided.
struct TriangleList {
  std::vector<uint32_t> indices;  // relative to `first_vertex`
  uint32_t first_vertex = 0;      // vertex_id of relative index 0 (includes the base vertex)
  uint32_t vertex_count = 0;
};
enum class Topology : uint8_t { kList, kStrip };
inline constexpr uint32_t kMaximumCapturedVertices = 1u << 20;

template <class Read>  // Read(i) -> the i-th index of the draw, before the base vertex
std::optional<TriangleList> BuildTriangleList(Topology topology, uint32_t count, Read&& read, int64_t base_vertex,
                                              std::optional<uint32_t> restart) {
  std::vector<uint32_t> absolute;
  absolute.reserve(topology == Topology::kList ? count : size_t(count) * 3);
  const auto emit = [&](uint32_t a, uint32_t b, uint32_t c) {
    if (a == b || b == c || a == c) return;
    absolute.insert(absolute.end(), {a, b, c});
  };
  if (topology == Topology::kList) {
    for (uint32_t i = 0; i + 2 < count; i += 3) {
      const uint32_t a = read(i), b = read(i + 1), c = read(i + 2);
      if (restart && (a == *restart || b == *restart || c == *restart)) continue;
      emit(a, b, c);
    }
  } else {
    uint32_t run = 0, previous[2]{};
    for (uint32_t i = 0; i < count; ++i) {
      const uint32_t v = read(i);
      if (restart && v == *restart) { run = 0; continue; }
      if (run >= 2) emit(previous[0], previous[1], v);
      previous[0] = previous[1]; previous[1] = v;
      ++run;
    }
  }
  if (absolute.empty()) return TriangleList{};
  uint32_t lowest = UINT32_MAX, highest = 0;
  for (const uint32_t v : absolute) { lowest = std::min(lowest, v); highest = std::max(highest, v); }
  const int64_t first = int64_t(lowest) + base_vertex;
  const uint64_t span = uint64_t(highest) - lowest + 1;
  if (first < 0 || first > int64_t(UINT32_MAX) || span > kMaximumCapturedVertices) return {};
  TriangleList list;
  list.first_vertex = uint32_t(first);
  list.vertex_count = uint32_t(span);
  list.indices.reserve(absolute.size());
  for (const uint32_t v : absolute) list.indices.push_back(v - lowest);
  return list;
}

// The cache identity, known before the list is built: `triangles` is the most the
// draw can make (a strip's real count depends on its restarts and joins), and the
// `vertices` field carries the index count and primitive, so either changing forces
// a rebuild rather than a refit.
inline GeometryIdentity CacheIdentityOf(uint64_t geometry, Topology topology, uint32_t count) {
  const uint32_t triangles = topology == Topology::kList ? count / 3 : (count > 2 ? count - 2 : 0);
  return {geometry, triangles, (count << 1) | uint32_t(topology)};
}

}  // namespace rex::graphics::gta4_metal::raytracing
