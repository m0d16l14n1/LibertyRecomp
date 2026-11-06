#pragma once
#include <algorithm>
#include <array>
#include <atomic>
#include <bit>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <span>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace rex::graphics::gta4_native::temporal {
// Identity comes from the executed model/pose owner, not submission order. A
// geometry generation changes when its captured vertex/index data is replaced.
struct GeometryKey {
  uint64_t instance = 0, drawable = 0, pose = 0, vertex_shader = 0, layout = 0,
           geometry_generation = 0, range = 0;
  struct Stream {
    uint64_t generation = 0;
    uint32_t offset = 0, stride = 0;
    bool operator==(const Stream&) const = default;
  };
  std::array<Stream, 17> streams{};
  uint64_t pixel_shader = 0, index_generation = 0;
  int32_t base_vertex = 0;
  uint32_t primitive = 0, restart_index = 0;
  bool indexed = false, restart = false;
  // Set by GeometryHistory, not by the caller: the n-th draw this frame that has the same key
  // but different constants (the four wheels of one car share the body transform in c0-c3).
  uint32_t occurrence = 0;
  bool operator==(const GeometryKey&) const = default;
};
struct GeometryKeyHash {
  size_t operator()(const GeometryKey& k) const noexcept {
    uint64_t h = 0xcbf29ce484222325ull;
    const auto add = [&](uint64_t v) {
      v ^= v >> 30;
      v *= 0xbf58476d1ce4e5b9ull;
      v ^= v >> 27;
      v *= 0x94d049bb133111ebull;
      h ^= v ^ (v >> 31);
      h *= 0x100000001b3ull;
    };
    for (uint64_t v : {k.instance, k.drawable, k.pose, k.vertex_shader, k.layout,
                       k.geometry_generation, k.range}) add(v);
    for (const auto& stream : k.streams) {
      add(stream.generation); add(stream.offset); add(stream.stride);
    }
    add(k.pixel_shader); add(k.index_generation); add(uint32_t(k.base_vertex));
    add(k.primitive); add(k.restart_index); add(k.indexed); add(k.restart);
    add(k.occurrence);
    return size_t(h);
  }
};
// Float constants a shader may read: bit n of word n/64 is register cN (shader_archive.h).
using ConstantMask = std::array<uint64_t, 4>;
inline constexpr ConstantMask kAllConstants{~0ull, ~0ull, ~0ull, ~0ull};
// The registers that place the draw in the world, for the one-frame step check: the world
// transform c0-c3 where the shader reads it (c0-c2 for gta_trees), else the first transform-
// sized block at c64 it reads (matWheelTransform, the first bone). None: no step check.
inline ConstantMask WorldRegisters(const ConstantMask& reads) {
  if (const uint64_t world = reads[0] & 0xFull) return {world, 0, 0, 0};
  return {0, reads[1] & 0xFull, 0, 0};
}
struct GeometryBudget {
  std::atomic<size_t> used{0};
  size_t limit = 0;
};
struct GeometrySnapshot {
  std::vector<uint8_t> vertex, shared;
  std::array<float, 2> jitter_clip{};
  uint64_t sequence = 0;
  std::shared_ptr<GeometryBudget> budget;
  ~GeometrySnapshot() {
    if (budget) budget->used.fetch_sub(vertex.size() + shared.size(), std::memory_order_relaxed);
  }
};
struct GeometryLookup {
  std::shared_ptr<const GeometrySnapshot> previous;
  bool captured = false, ambiguous = false;
  bool matched_by_transform = false;  // found by the nearest-transform fallback, not the key
};
struct GeometryMatchStatistics {
  uint64_t key = 0, transform = 0, transform_ambiguous = 0, transform_far = 0, key_far = 0,
           none = 0;
  uint64_t sibling = 0, sibling_ambiguous = 0;  // draws told apart within one shared key
  // Diagnostic: per vertex-constant register, how often its change alone pushed a transform
  // candidate past kMaximumConstantStep (the largest change of that candidate).
  std::array<uint32_t, 256> far_register{};
  uint64_t far_world = 0;  // candidates refused by the world-transform step instead
};
class GeometryHistory {
 public:
  explicit GeometryHistory(size_t maximum_bytes = 64u * 1024u * 1024u,
                           size_t maximum_entries = 8192)
      : budget_(std::make_shared<GeometryBudget>()), maximum_entries_(maximum_entries) {
    budget_->limit = maximum_bytes;
  }
  bool Begin(uint64_t epoch, uint64_t view, uint64_t sequence, bool reset) {
    if (!epoch || !view || !sequence || epoch < epoch_) return false;
    if (epoch == epoch_ && view == view_ && sequence == sequence_) return !reset;
    if (epoch == epoch_ && view == view_ && sequence < sequence_) return false;
    const bool continuous = !reset && epoch == epoch_ && view == view_ && sequence_ != UINT64_MAX &&
                            sequence == sequence_ + 1;
    previous_.clear();
    previous_shapes_.clear();
    previous_siblings_.clear();
    distinct_.clear();
    claimed_.clear();
    if (continuous) {
      previous_.swap(current_);
      previous_shapes_.swap(current_shapes_);
      previous_siblings_.swap(current_siblings_);
    } else {
      current_.clear();
      current_shapes_.clear();
      current_siblings_.clear();
    }
    epoch_ = epoch;
    view_ = view;
    sequence_ = sequence;
    return true;
  }
  // `reads` is the vertex shader's float-constant read mask. Matching compares only those
  // registers: the rest of the bank holds whatever earlier draws left (forward-lighting
  // constants at c19-c31 and c64-c73 jump between light sets and once refused every entity).
  GeometryLookup Record(GeometryKey key, std::span<const uint8_t> vertex,
                        std::span<const uint8_t> shared, std::array<float, 2> jitter,
                        const ConstantMask& reads = kAllConstants) {
    if (!sequence_ || !key.instance || !key.vertex_shader || !key.geometry_generation ||
        vertex.size() != 4096 || shared.empty() || shared.size() > 2048)
      return {};
    reads_ = reads;
    world_ = WorldRegisters(reads);
    // Draws that share a key but not their constants are siblings (one car's wheels: the tire
    // shader reads matWheelTransform at c64, while the key's c0-c3 is the shared body gWorld).
    key.occurrence = 0;
    for (auto existing = current_.find(key); existing != current_.end();
         existing = current_.find(key)) {
      const auto& stored = *existing->second.snapshot;
      const bool same = stored.vertex.size() == vertex.size() &&
                        stored.shared.size() == shared.size() && stored.jitter_clip == jitter &&
                        !std::memcmp(stored.vertex.data(), vertex.data(), vertex.size()) &&
                        !std::memcmp(stored.shared.data(), shared.data(), shared.size());
      if (!same && key.occurrence + 1 < kMaximumSiblings) {
        ++key.occurrence;
        continue;
      }
      existing->second.ambiguous |= !same;
      if (existing->second.ambiguous) return {{}, true, true};
      // An identical repeat (another pass of the same draw) keeps the first draw's match.
      return {existing->second.matched, true, existing->second.unclear};
    }
    if (current_.size() >= maximum_entries_) return {};
    const size_t bytes = vertex.size() + shared.size(),
                 used = budget_->used.load(std::memory_order_relaxed);
    if (used > budget_->limit || bytes > budget_->limit - used) return {};
    auto snapshot = std::make_shared<GeometrySnapshot>();
    snapshot->vertex.assign(vertex.begin(), vertex.end());
    snapshot->shared.assign(shared.begin(), shared.end());
    snapshot->sequence = sequence_;
    snapshot->jitter_clip = jitter;
    budget_->used.fetch_add(bytes, std::memory_order_relaxed);
    snapshot->budget = budget_;
    auto& entry = current_.emplace(key, Entry{snapshot, false, nullptr}).first->second;
    auto& shape = current_shapes_[Shape(key)];
    if (shape.size() < kMaximumShapeCandidates) shape.push_back({key, snapshot});
    if (key.occurrence) {
      // A sibling group exists only for keys drawn more than once with different constants;
      // the first sibling joins it now (almost every key has one draw and no group).
      auto [group, created] = current_siblings_.try_emplace(Siblings(key));
      if (created)
        if (const auto first = current_.find(Siblings(key)); first != current_.end())
          group->second.push_back({first->first, first->second.snapshot});
      group->second.push_back({key, snapshot});
    }
    GeometryLookup lookup{nullptr, true, false};
    // Every return below records what this draw matched for its repeats in this frame.
    struct Remember {
      Entry& entry; GeometryLookup& lookup;
      ~Remember() { entry.matched = lookup.previous; }
    } remember{entry, lookup};
    bool sibling_unclear = false;
    lookup.previous = PreviousSibling(key, vertex, sibling_unclear);
    if (sibling_unclear) {
      // Siblings existed but none is clearly this draw: keep the old ambiguous outcome. Only
      // this frame's lookup is ambiguous; the entry stays matchable for the next frame.
      lookup.ambiguous = entry.unclear = true;
      return lookup;
    }
    if (!transform_fallback_) {
      statistics_.key += bool(lookup.previous);
      statistics_.none += !lookup.previous;
      return lookup;
    }
    if (lookup.previous) {
      // The key holds the guest address of the transform. Retail renders moving entities from
      // per-frame copies of their matrices, so an address can name another object next frame.
      if (Distance(lookup.previous->vertex, vertex, false).max_world <= kMaximumWorldStep) {
        ++statistics_.key;
        claimed_.insert(lookup.previous.get());
        return lookup;
      }
      ++statistics_.key_far;
      lookup.previous = nullptr;
    } else if (PreviousAmbiguous(key)) {
      ++statistics_.none;
      return lookup;
    }
    lookup.previous = Nearest(key, vertex);
    lookup.matched_by_transform = bool(lookup.previous);
    return lookup;
  }
  void set_transform_fallback(bool enabled) { transform_fallback_ = enabled; }
  GeometryMatchStatistics TakeStatistics() {
    auto taken = statistics_;
    statistics_ = {};
    return taken;
  }
  void Reset() {
    current_.clear();
    previous_.clear();
    current_shapes_.clear();
    previous_shapes_.clear();
    current_siblings_.clear();
    previous_siblings_.clear();
    distinct_.clear();
    claimed_.clear();
    epoch_ = view_ = sequence_ = 0;
  }
  size_t owned_bytes() const { return budget_->used.load(std::memory_order_relaxed); }
  size_t current_entries() const { return current_.size(); }
  size_t current_sibling_groups() const { return current_siblings_.size(); }

 private:
  struct Entry {
    std::shared_ptr<GeometrySnapshot> snapshot;
    bool ambiguous = false;
    std::shared_ptr<const GeometrySnapshot> matched;  // the previous draw this one continues
    bool unclear = false;  // several siblings last frame, none clearly this one
  };
  std::shared_ptr<const GeometrySnapshot> Previous(const GeometryKey& key) const {
    const auto old = previous_.find(key);
    return old == previous_.end() || old->second.ambiguous ? nullptr : old->second.snapshot;
  }
  bool PreviousAmbiguous(const GeometryKey& key) const {
    const auto old = previous_.find(key);
    return old != previous_.end() && old->second.ambiguous;
  }
  // The same model and geometry without the owner: instance and pose name guest storage.
  static GeometryKey Shape(GeometryKey key) {
    key.instance = 0;
    key.pose = 0;
    key.occurrence = 0;
    return key;
  }
  // Every sibling of one key, whatever its occurrence.
  static GeometryKey Siblings(GeometryKey key) {
    key.occurrence = 0;
    return key;
  }
  // The previous frame's draw this one continues. With one draw under the key that is the
  // exact key. With several, it is the sibling nearest in the constants that told them apart
  // last frame (draw order may change; camera terms shared by all siblings are left out).
  std::shared_ptr<const GeometrySnapshot> PreviousSibling(const GeometryKey& key,
                                                          std::span<const uint8_t> vertex,
                                                          bool& unclear) {
    unclear = false;
    if (previous_siblings_.empty()) return Previous(key);  // the common frame: no shared keys
    const auto group = previous_siblings_.find(Siblings(key));
    if (group == previous_siblings_.end()) return Previous(key);
    const auto& siblings = group->second;
    const auto load = [](std::span<const uint8_t> bytes, size_t i) {
      uint32_t bits;
      std::memcpy(&bits, bytes.data() + i * sizeof(float), sizeof(bits));
      return bits;
    };
    // The constants that differ between last frame's siblings, found once per group.
    auto [cached, created] = distinct_.try_emplace(&siblings);
    auto& distinct = cached->second;
    if (created) {
      const size_t floats = siblings[0].snapshot->vertex.size() / sizeof(float);
      for (size_t i = 0; i < floats; ++i) {
        if (!Reads(reads_, i / 4)) continue;  // a constant the shader never reads tells nothing
        const uint32_t first = load(siblings[0].snapshot->vertex, i);
        for (size_t s = 1; s < siblings.size(); ++s)
          if (siblings[s].snapshot->vertex.size() > i * sizeof(float) &&
              load(siblings[s].snapshot->vertex, i) != first) {
            distinct.push_back(uint32_t(i));
            break;
          }
      }
    }
    const GeometrySnapshot* best = nullptr;
    double best_sum = 0, second_sum = -1;
    for (const auto& sibling : siblings) {
      const auto& old = sibling.snapshot->vertex;
      if (old.size() != vertex.size() || claimed_.count(sibling.snapshot.get())) continue;
      if (Distance(old, vertex, false).max_world > kMaximumWorldStep) continue;
      double sum = 0;
      bool finite = true;
      for (const uint32_t i : distinct) {
        const float x = std::bit_cast<float>(load(old, i)), y = std::bit_cast<float>(load(vertex, i));
        if (!std::isfinite(x) || !std::isfinite(y)) {
          // Non-finite constants match only themselves (NaN matches NaN).
          if (!(x == y || (x != x && y != y))) { finite = false; break; }
          continue;
        }
        sum += double(x - y) * double(x - y);
      }
      if (!finite) continue;
      if (!best || sum < best_sum) {
        if (best) second_sum = best_sum;
        best = sibling.snapshot.get();
        best_sum = sum;
      } else if (second_sum < 0 || sum < second_sum) {
        second_sum = sum;
      }
    }
    if (!best || distinct.empty() || (second_sum >= 0 && second_sum <= 2.25 * best_sum + 1e-6)) {
      ++statistics_.sibling_ambiguous;
      unclear = true;
      return nullptr;
    }
    ++statistics_.sibling;
    for (const auto& sibling : siblings)
      if (sibling.snapshot.get() == best) {
        claimed_.insert(best);
        return sibling.snapshot;
      }
    return nullptr;
  }
  static bool Reads(const ConstantMask& mask, size_t reg) {
    return reg < 256 && ((mask[reg / 64] >> (reg % 64)) & 1);
  }
  // Over the current draw's read registers: world_ (WorldRegisters) gives max_world; with
  // `all`, every read register gives max_any and sum. Unread registers are not compared.
  struct Difference {
    float max_world = 0;  // largest change of a world-transform element (metres for translation)
    float max_any = 0;    // largest change of any finite read constant
    double sum = 0;       // squared change of every finite read constant
    uint32_t max_index = 0;  // float index of the largest change of any read constant
  };
  Difference Distance(std::span<const uint8_t> a, std::span<const uint8_t> b, bool all) const {
    Difference d;
    const size_t registers = std::min<size_t>(std::min(a.size(), b.size()) / 16, 256);
    for (size_t reg = 0; reg < registers; ++reg) {
      const bool world = Reads(world_, reg);
      if (!(all ? Reads(reads_, reg) || world : world)) continue;
      for (size_t i = reg * 4; i < reg * 4 + 4; ++i) {
        float x, y;
        std::memcpy(&x, a.data() + i * sizeof(float), sizeof(float));
        std::memcpy(&y, b.data() + i * sizeof(float), sizeof(float));
        if (!std::isfinite(x) || !std::isfinite(y)) continue;
        const float change = std::abs(x - y);
        if (world) d.max_world = std::max(d.max_world, change);
        if (change > d.max_any) { d.max_any = change; d.max_index = uint32_t(i); }
        d.sum += double(change) * change;
      }
    }
    return d;
  }
  // The previous frame's draw of the same shape whose constants moved least, if it is clearly
  // nearer than any other and moved no further than an object can in one frame.
  std::shared_ptr<const GeometrySnapshot> Nearest(const GeometryKey& key,
                                                  std::span<const uint8_t> vertex) {
    const auto shape = previous_shapes_.find(Shape(key));
    if (shape == previous_shapes_.end()) { ++statistics_.none; return nullptr; }
    const GeometrySnapshot* best = nullptr;
    double best_sum = 0, second_sum = -1;
    bool any_near = false;
    for (const auto& candidate : shape->second) {
      // Another frame's object still drawn under its own key this frame is not this one.
      if (candidate.key == key || current_.count(candidate.key) || PreviousAmbiguous(candidate.key) ||
          claimed_.count(candidate.snapshot.get()))
        continue;
      if (Distance(candidate.snapshot->vertex, vertex, false).max_world > kMaximumWorldStep) {
        ++statistics_.far_world;
        continue;
      }
      const auto d = Distance(candidate.snapshot->vertex, vertex, true);
      if (d.max_any > kMaximumConstantStep) {
        ++statistics_.far_register[(d.max_index / 4) % statistics_.far_register.size()];
        continue;
      }
      any_near = true;
      if (!best || d.sum < best_sum) {
        if (best) second_sum = best_sum;
        best = candidate.snapshot.get();
        best_sum = d.sum;
      } else if (second_sum < 0 || d.sum < second_sum) {
        second_sum = d.sum;
      }
    }
    if (!best) { ++(any_near ? statistics_.none : statistics_.transform_far); return nullptr; }
    if (second_sum >= 0 && second_sum <= 2.25 * best_sum + 1e-6) {
      ++statistics_.transform_ambiguous;
      return nullptr;
    }
    for (const auto& candidate : shape->second)
      if (candidate.snapshot.get() == best) {
        claimed_.insert(best);
        ++statistics_.transform;
        return candidate.snapshot;
      }
    return nullptr;
  }
  static constexpr size_t kMaximumShapeCandidates = 32;
  static constexpr uint32_t kMaximumSiblings = 64;  // past this, the last one is ambiguous (a street of one tree model)
  static constexpr float kMaximumWorldStep = 6.0f;      // ~650 km/h at 30 fps
  static constexpr float kMaximumConstantStep = 12.0f;  // camera and bones included
  struct Candidate {
    GeometryKey key;
    std::shared_ptr<GeometrySnapshot> snapshot;
  };
  std::unordered_map<GeometryKey, std::vector<Candidate>, GeometryKeyHash> previous_shapes_,
      current_shapes_, previous_siblings_, current_siblings_;
  // Per previous sibling group: the vertex constants (float index) that told its draws apart.
  std::unordered_map<const std::vector<Candidate>*, std::vector<uint32_t>> distinct_;
  std::unordered_set<const GeometrySnapshot*> claimed_;
  GeometryMatchStatistics statistics_{};
  ConstantMask reads_ = kAllConstants, world_ = WorldRegisters(kAllConstants);  // this Record's draw
  bool transform_fallback_ = false;
  std::unordered_map<GeometryKey, Entry, GeometryKeyHash> previous_, current_;
  std::shared_ptr<GeometryBudget> budget_;
  size_t maximum_entries_;
  uint64_t epoch_ = 0, view_ = 0, sequence_ = 0;
};
}  // namespace rex::graphics::gta4_native::temporal
