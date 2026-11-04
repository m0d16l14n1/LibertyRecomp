#pragma once
#include <algorithm>
#include <array>
#include <atomic>
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
    return size_t(h);
  }
};
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
    claimed_.clear();
    if (continuous) {
      previous_.swap(current_);
      previous_shapes_.swap(current_shapes_);
    } else {
      current_.clear();
      current_shapes_.clear();
    }
    epoch_ = epoch;
    view_ = view;
    sequence_ = sequence;
    return true;
  }
  GeometryLookup Record(const GeometryKey& key, std::span<const uint8_t> vertex,
                        std::span<const uint8_t> shared, std::array<float, 2> jitter) {
    if (!sequence_ || !key.instance || !key.vertex_shader || !key.geometry_generation ||
        vertex.size() != 4096 || shared.empty() || shared.size() > 2048)
      return {};
    if (auto existing = current_.find(key); existing != current_.end()) {
      const auto& stored = *existing->second.snapshot;
      const bool same = stored.vertex.size() == vertex.size() &&
                        stored.shared.size() == shared.size() && stored.jitter_clip == jitter &&
                        !std::memcmp(stored.vertex.data(), vertex.data(), vertex.size()) &&
                        !std::memcmp(stored.shared.data(), shared.data(), shared.size());
      existing->second.ambiguous |= !same;
      if (existing->second.ambiguous) return {{}, true, true};
      // An identical repeat (another pass of the same draw) keeps the first draw's match.
      return {existing->second.matched, true, false};
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
    GeometryLookup lookup{Previous(key), true, false};
    // Every return below records what this draw matched for its repeats in this frame.
    struct Remember {
      Entry& entry; GeometryLookup& lookup;
      ~Remember() { entry.matched = lookup.previous; }
    } remember{entry, lookup};
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
    claimed_.clear();
    epoch_ = view_ = sequence_ = 0;
  }
  size_t owned_bytes() const { return budget_->used.load(std::memory_order_relaxed); }
  size_t current_entries() const { return current_.size(); }

 private:
  struct Entry {
    std::shared_ptr<GeometrySnapshot> snapshot;
    bool ambiguous = false;
    std::shared_ptr<const GeometrySnapshot> matched;  // the previous draw this one continues
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
    return key;
  }
  // c0-c3 of the vertex bank is the world transform (the static fallback key hashes it); for
  // skinned models it is shared and the bone palette further up tells two bodies apart.
  struct Difference {
    float max_world = 0;  // largest change of a world-transform element (metres for translation)
    float max_any = 0;    // largest change of any finite constant
    double sum = 0;       // squared change of every finite constant
  };
  static Difference Distance(std::span<const uint8_t> a, std::span<const uint8_t> b, bool all) {
    Difference d;
    const size_t floats = std::min(a.size(), b.size()) / sizeof(float);
    for (size_t i = 0; i < (all ? floats : std::min<size_t>(floats, 16)); ++i) {
      float x, y;
      std::memcpy(&x, a.data() + i * sizeof(float), sizeof(float));
      std::memcpy(&y, b.data() + i * sizeof(float), sizeof(float));
      if (!std::isfinite(x) || !std::isfinite(y)) continue;
      const float change = std::abs(x - y);
      if (i < 16) d.max_world = std::max(d.max_world, change);
      d.max_any = std::max(d.max_any, change);
      d.sum += double(change) * change;
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
      if (Distance(candidate.snapshot->vertex, vertex, false).max_world > kMaximumWorldStep) continue;
      const auto d = Distance(candidate.snapshot->vertex, vertex, true);
      if (d.max_any > kMaximumConstantStep) continue;
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
  static constexpr float kMaximumWorldStep = 6.0f;      // ~650 km/h at 30 fps
  static constexpr float kMaximumConstantStep = 12.0f;  // camera and bones included
  struct Candidate {
    GeometryKey key;
    std::shared_ptr<GeometrySnapshot> snapshot;
  };
  std::unordered_map<GeometryKey, std::vector<Candidate>, GeometryKeyHash> previous_shapes_,
      current_shapes_;
  std::unordered_set<const GeometrySnapshot*> claimed_;
  GeometryMatchStatistics statistics_{};
  bool transform_fallback_ = false;
  std::unordered_map<GeometryKey, Entry, GeometryKeyHash> previous_, current_;
  std::shared_ptr<GeometryBudget> budget_;
  size_t maximum_entries_;
  uint64_t epoch_ = 0, view_ = 0, sequence_ = 0;
};
}  // namespace rex::graphics::gta4_native::temporal
