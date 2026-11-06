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
// One word into a key hash (splitmix64 finalizer, then an FNV-style multiply).
inline uint64_t GeometryKeyMix(uint64_t h, uint64_t v) {
  v ^= v >> 30;
  v *= 0xbf58476d1ce4e5b9ull;
  v ^= v >> 27;
  v *= 0x94d049bb133111ebull;
  h ^= v ^ (v >> 31);
  return h * 0x100000001b3ull;
}
// Every field except the owner (instance, pose) and occurrence: the part Shape and Siblings
// keep. GeometryHistory hashes it once per Record; the three it changes cost three words.
inline uint64_t GeometryKeyBodyHash(const GeometryKey& k) {
  uint64_t h = 0xcbf29ce484222325ull;
  for (uint64_t v : {k.drawable, k.vertex_shader, k.layout, k.geometry_generation, k.range})
    h = GeometryKeyMix(h, v);
  // Most of the 17 streams are unused (all zero): skip those, and tag the rest with their
  // slot so equal streams in different slots still hash apart.
  for (uint64_t slot = 0; slot < k.streams.size(); ++slot) {
    const auto& stream = k.streams[slot];
    const uint64_t layout = uint64_t(stream.offset) | uint64_t(stream.stride) << 32;
    if (!stream.generation && !layout) continue;
    h = GeometryKeyMix(h, stream.generation ^ slot << 59);
    h = GeometryKeyMix(h, layout ^ slot << 59);
  }
  h = GeometryKeyMix(h, k.pixel_shader);
  h = GeometryKeyMix(h, k.index_generation);
  h = GeometryKeyMix(h, uint64_t(uint32_t(k.base_vertex)) | uint64_t(k.primitive) << 32);
  h = GeometryKeyMix(h, uint64_t(k.restart_index) | uint64_t(k.indexed) << 32 | uint64_t(k.restart) << 33);
  return h;
}
inline size_t GeometryKeyHashOf(uint64_t body, const GeometryKey& k) {
  uint64_t h = GeometryKeyMix(body, k.instance);
  h = GeometryKeyMix(h, k.pose);
  return size_t(GeometryKeyMix(h, k.occurrence));
}
struct GeometryKeyHash {
  size_t operator()(const GeometryKey& k) const noexcept {
    return GeometryKeyHashOf(GeometryKeyBodyHash(k), k);
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
// The camera-dependent rage registers: gWorldView c4-c7, gWorldViewProj c8-c11, gViewInverse
// c12-c15. A camera turn moves them by an amount that grows with distance (clip space), so they
// rank candidates but never refuse one (kMaximumConstantStep).
inline constexpr ConstantMask kCameraRegisters{0xFFF0ull, 0, 0, 0};
struct GeometryBudget {
  std::atomic<size_t> used{0};
  size_t limit = 0;
};
struct GeometrySnapshot {
  std::vector<uint8_t> vertex, shared;
  std::array<float, 2> jitter_clip{};
  uint64_t sequence = 0;
  // Late-constant diagnostic (set_late_diagnostic): hash of the c64+ registers the draw read, and
  // over this key's unbroken chain of key matches, how many frames and how many hash changes.
  uint64_t late_hash = 0;
  uint32_t late_frames = 0, late_changes = 0;
  // The backend's GPU copy of `vertex` and `shared` made in the frame that recorded this
  // snapshot, so the next frame can bind it as the previous constants instead of uploading it
  // again (Metal: frame-ring serial, buffer, offset, GPU address). Cleared when recorded again.
  struct BackendUpload {
    uint64_t serial = 0;  // 0: none
    const void* buffer = nullptr;
    uint64_t offset = 0, gpu_address = 0;
    void* data = nullptr;
  };
  mutable BackendUpload backend_vertex{}, backend_shared{};
  std::shared_ptr<GeometryBudget> budget;
  ~GeometrySnapshot() {
    if (budget) budget->used.fetch_sub(vertex.size() + shared.size(), std::memory_order_relaxed);
  }
};
struct GeometryLookup {
  std::shared_ptr<const GeometrySnapshot> previous;
  // This frame's entry for the draw (its new snapshot, or the identical earlier draw's), valid
  // until the next frame; null when the draw was not recorded or is ambiguous.
  const GeometrySnapshot* current = nullptr;
  bool captured = false, ambiguous = false;
  bool matched_by_transform = false;  // found by the nearest-transform fallback, not the key
  // Late-constant diagnostic, for key (or sibling) matches only: the read registers past c63
  // (bones, matWheelTransform) against the matched previous draw.
  struct Late {
    bool valid = false;
    bool palette = false;     // a0-relative reads (the whole tail): a gBoneMtx palette
    bool world_late = false;  // no c0-c3 read: the world step is taken from c64-c67 (tire, some skinned)
    bool sibling = false;     // told apart from other draws of one key
    bool moved = false;       // the world registers changed
    bool changed = false;     // any read c64+ register changed
    uint32_t first = 0, last = 0, first_changed = 0;  // read c64+ range; first changed register (0 none)
    uint32_t frames = 0, changes = 0;                 // this key's chain (GeometrySnapshot::late_*)
  } late{};
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
    // `matched` serves repeats within the frame that recorded it; dropping it here lets the
    // snapshots it names (now two frames old) return to the pool.
    for (auto& [key, entry] : current_) entry.matched.reset();
    previous_shapes_.clear();
    previous_siblings_.clear();
    Recycle(previous_);
    distinct_.clear();
    claimed_.clear();
    if (continuous) {
      previous_.swap(current_);
      previous_shapes_.swap(current_shapes_);
      previous_siblings_.swap(current_siblings_);
    } else {
      current_shapes_.clear();
      current_siblings_.clear();
      Recycle(current_);
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
    return RecordInto(key, vertex, shared, jitter, reads, nullptr);
  }
  // A 4 KB vertex-bank buffer for the caller to capture into, then pass to the Record below:
  // a new entry adopts it instead of copying the bank a second time.
  std::shared_ptr<GeometrySnapshot> TakeScratch() {
    std::shared_ptr<GeometrySnapshot> scratch;
    if (!pool_.empty()) {
      scratch = std::move(pool_.back());
      pool_.pop_back();
    } else {
      scratch = std::make_shared<GeometrySnapshot>();
    }
    scratch->vertex.resize(4096);
    return scratch;
  }
  // `scratch` (from TakeScratch, filled) becomes the new entry's snapshot, or returns to the pool.
  GeometryLookup Record(GeometryKey key, std::shared_ptr<GeometrySnapshot>& scratch,
                        std::span<const uint8_t> shared, std::array<float, 2> jitter,
                        const ConstantMask& reads = kAllConstants) {
    if (!scratch) return {};
    const auto lookup = RecordInto(key, scratch->vertex, shared, jitter, reads, &scratch);
    if (scratch && scratch.use_count() == 1 && pool_.size() < kMaximumPooledSnapshots)
      pool_.push_back(std::move(scratch));
    scratch.reset();
    return lookup;
  }

 private:
  // A key with its hash: Record hashes the body once, and every map lookup after that (the
  // occurrence probe, shape, siblings, previous frame, each Nearest candidate) reuses it.
  struct HashedKey {
    GeometryKey key;
    uint64_t body = 0;
    size_t hash = 0;
    bool operator==(const HashedKey& other) const { return hash == other.hash && key == other.key; }
  };
  struct HashedKeyHash {
    size_t operator()(const HashedKey& k) const noexcept { return k.hash; }
  };
  static HashedKey Rehashed(HashedKey k) {
    k.hash = GeometryKeyHashOf(k.body, k.key);
    return k;
  }
  GeometryLookup RecordInto(const GeometryKey& raw, std::span<const uint8_t> vertex,
                            std::span<const uint8_t> shared, std::array<float, 2> jitter,
                            const ConstantMask& reads, std::shared_ptr<GeometrySnapshot>* adopt) {
    if (!sequence_ || !raw.instance || !raw.vertex_shader || !raw.geometry_generation ||
        vertex.size() != 4096 || shared.empty() || shared.size() > 2048)
      return {};
    reads_ = reads;
    world_ = WorldRegisters(reads);
    // Draws that share a key but not their constants are siblings (one car's wheels: the tire
    // shader reads matWheelTransform at c64, while the key's c0-c3 is the shared body gWorld).
    HashedKey key{raw};
    key.key.occurrence = 0;
    key.body = GeometryKeyBodyHash(key.key);
    key = Rehashed(key);
    for (auto existing = current_.find(key); existing != current_.end();
         existing = current_.find(key)) {
      const auto& stored = *existing->second.snapshot;
      const bool same = stored.vertex.size() == vertex.size() &&
                        stored.shared.size() == shared.size() && stored.jitter_clip == jitter &&
                        !std::memcmp(stored.vertex.data(), vertex.data(), vertex.size()) &&
                        !std::memcmp(stored.shared.data(), shared.data(), shared.size());
      if (!same && key.key.occurrence + 1 < kMaximumSiblings) {
        ++key.key.occurrence;
        key = Rehashed(key);
        continue;
      }
      existing->second.ambiguous |= !same;
      if (existing->second.ambiguous) return {{}, nullptr, true, true};
      // An identical repeat (another pass of the same draw) keeps the first draw's match.
      return {existing->second.matched, existing->second.snapshot.get(), true, existing->second.unclear};
    }
    if (current_.size() >= maximum_entries_) return {};
    const size_t bytes = vertex.size() + shared.size(),
                 used = budget_->used.load(std::memory_order_relaxed);
    if (used > budget_->limit || bytes > budget_->limit - used) return {};
    std::shared_ptr<GeometrySnapshot> snapshot;
    if (adopt && *adopt) {
      snapshot = std::move(*adopt);  // `vertex` already is its bank (it stays valid)
    } else {
      if (!pool_.empty()) {
        snapshot = std::move(pool_.back());
        pool_.pop_back();
      } else {
        snapshot = std::make_shared<GeometrySnapshot>();
      }
      snapshot->vertex.assign(vertex.begin(), vertex.end());
    }
    snapshot->shared.assign(shared.begin(), shared.end());
    snapshot->sequence = sequence_;
    snapshot->jitter_clip = jitter;
    snapshot->late_hash = 0;
    snapshot->late_frames = snapshot->late_changes = 0;
    snapshot->backend_vertex = snapshot->backend_shared = {};
    budget_->used.fetch_add(bytes, std::memory_order_relaxed);
    snapshot->budget = budget_;
    auto& entry = current_.emplace(key, Entry{snapshot, false, nullptr}).first->second;
    auto& shape = current_shapes_[Shape(key)];
    if (shape.size() < kMaximumShapeCandidates) shape.push_back({key, snapshot});
    if (key.key.occurrence) {
      // A sibling group exists only for keys drawn more than once with different constants;
      // the first sibling joins it now (almost every key has one draw and no group).
      auto [group, created] = current_siblings_.try_emplace(Siblings(key));
      if (created)
        if (const auto first = current_.find(Siblings(key)); first != current_.end())
          group->second.push_back({first->first, first->second.snapshot});
      group->second.push_back({key, snapshot});
    }
    GeometryLookup lookup{nullptr, snapshot.get(), true, false};
    // Every return below records what this draw matched for its repeats in this frame.
    struct Remember {
      Entry& entry; GeometryLookup& lookup;
      ~Remember() { entry.matched = lookup.previous; }
    } remember{entry, lookup};
    bool sibling_unclear = false;
    lookup.previous = PreviousSibling(key, vertex, sibling_unclear);
    if (late_diagnostic_ && !sibling_unclear)
      LateDiagnostic(lookup, *snapshot, vertex, previous_siblings_.count(Siblings(key)) != 0);
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
      if (Near(Distance(lookup.previous->vertex, vertex, false))) {
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

 public:
  void set_transform_fallback(bool enabled) { transform_fallback_ = enabled; }
  // Largest change of a rotation element of the world transform c0-c2 (.xyz in either matrix
  // layout) a match may have: 0 off. The world step bounds translation only, and rotation
  // elements change by at most 2, so a previous pose with another heading (a spawned car turned
  // into place, another object of the same model) was always accepted and gave its pixels a
  // rigid rotation in motion. 2*sin(angle/2): 0.35 is about 20 degrees per frame.
  void set_rotation_limit(float limit) { rotation_limit_ = limit; }
  void set_late_diagnostic(bool enabled) { late_diagnostic_ = enabled; }
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
  size_t pooled_snapshots() const { return pool_.size(); }

 private:
  struct Entry {
    std::shared_ptr<GeometrySnapshot> snapshot;
    bool ambiguous = false;
    std::shared_ptr<const GeometrySnapshot> matched;  // the previous draw this one continues
    bool unclear = false;  // several siblings last frame, none clearly this one
  };
  // Two-frame-old snapshots that nothing else holds go back to a pool, keeping their vector
  // storage: Record then copies into existing capacity instead of three allocations per draw.
  // A snapshot someone still holds (a lookup, an upload map, a newer entry's `matched`) is
  // simply released as before. The pool is not charged to the budget.
  void Recycle(std::unordered_map<HashedKey, Entry, HashedKeyHash>& entries) {
    for (auto& [key, entry] : entries) {
      entry.matched.reset();
      auto& snapshot = entry.snapshot;
      if (!snapshot || snapshot.use_count() != 1 || pool_.size() >= kMaximumPooledSnapshots) continue;
      if (snapshot->budget)
        snapshot->budget->used.fetch_sub(snapshot->vertex.size() + snapshot->shared.size(), std::memory_order_relaxed);
      snapshot->budget = nullptr;
      pool_.push_back(std::move(snapshot));
    }
    entries.clear();
  }
  std::shared_ptr<const GeometrySnapshot> Previous(const HashedKey& key) const {
    const auto old = previous_.find(key);
    return old == previous_.end() || old->second.ambiguous ? nullptr : old->second.snapshot;
  }
  bool PreviousAmbiguous(const HashedKey& key) const {
    const auto old = previous_.find(key);
    return old != previous_.end() && old->second.ambiguous;
  }
  // The same model and geometry without the owner: instance and pose name guest storage.
  static HashedKey Shape(HashedKey key) {
    key.key.instance = 0;
    key.key.pose = 0;
    key.key.occurrence = 0;
    return Rehashed(key);
  }
  // Every sibling of one key, whatever its occurrence.
  static HashedKey Siblings(HashedKey key) {
    key.key.occurrence = 0;
    return Rehashed(key);
  }
  // The previous frame's draw this one continues. With one draw under the key that is the
  // exact key. With several, it is the sibling nearest in the constants that told them apart
  // last frame (draw order may change; camera terms shared by all siblings are left out).
  std::shared_ptr<const GeometrySnapshot> PreviousSibling(const HashedKey& key,
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
    // Vehicle tires use c64-c67 as matWheelTransform. Rotation can advance far
    // enough in one 30 Hz frame that the full-matrix nearest match prefers a
    // different wheel whose old rotation happens to be closer. That gives the
    // wheel hundreds of pixels of false motion and frame interpolation replaces
    // it with the bumper/road. The hub translation in c67.xyz is the stable
    // sibling identity; use it before the rotating basis. An exactly equidistant
    // hub stays ambiguous instead of inventing motion.
    if (Reads(world_, 67)) {
      const auto load_float = [](std::span<const uint8_t> bytes, size_t index) {
        float value;
        std::memcpy(&value, bytes.data() + index * sizeof(float), sizeof(value));
        return value;
      };
      const GeometrySnapshot* hub_best = nullptr;
      double hub_best_sum = 0, hub_second_sum = -1;
      for (const auto& sibling : siblings) {
        const auto& old = sibling.snapshot->vertex;
        if (old.size() != vertex.size() || claimed_.count(sibling.snapshot.get()) ||
            !Near(Distance(old, vertex, false)))
          continue;
        double sum = 0;
        bool finite = true;
        for (size_t component = 0; component < 3; ++component) {
          const size_t index = 67 * 4 + component;
          const float x = load_float(old, index), y = load_float(vertex, index);
          if (!std::isfinite(x) || !std::isfinite(y)) { finite = false; break; }
          sum += double(x - y) * double(x - y);
        }
        if (!finite) continue;
        if (!hub_best || sum < hub_best_sum) {
          if (hub_best) hub_second_sum = hub_best_sum;
          hub_best = sibling.snapshot.get();
          hub_best_sum = sum;
        } else if (hub_second_sum < 0 || sum < hub_second_sum) {
          hub_second_sum = sum;
        }
      }
      if (hub_best && (hub_second_sum < 0 || hub_second_sum > 2.25 * hub_best_sum + 1e-6)) {
        ++statistics_.sibling;
        claimed_.insert(hub_best);
        for (const auto& sibling : siblings)
          if (sibling.snapshot.get() == hub_best) return sibling.snapshot;
      }
      if (hub_best) {
        ++statistics_.sibling_ambiguous;
        unclear = true;
        return nullptr;
      }
    }
    const GeometrySnapshot* best = nullptr;
    double best_sum = 0, second_sum = -1;
    for (const auto& sibling : siblings) {
      const auto& old = sibling.snapshot->vertex;
      if (old.size() != vertex.size() || claimed_.count(sibling.snapshot.get())) continue;
      if (!Near(Distance(old, vertex, false))) continue;
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
  // `all`, every read register gives sum and every read non-camera register max_any. Unread
  // registers are not compared.
  struct Difference {
    float max_world = 0;  // largest change of a world-transform element (metres for translation)
    float max_rotation = 0;  // largest change of a c0-c2 .xyz element (world transform at c0-c3 only)
    float max_any = 0;    // largest change of any finite read constant
    double sum = 0;       // squared change of every finite read constant
    uint32_t max_index = 0;  // float index of the largest change of any read constant
  };
  // Fills lookup.late and the new snapshot's late chain. Only the read c64+ registers count: the
  // rest of the tail holds whatever earlier draws left.
  void LateDiagnostic(GeometryLookup& lookup, GeometrySnapshot& snapshot,
                      std::span<const uint8_t> vertex, bool sibling) const {
    const ConstantMask late{0, reads_[1], reads_[2], reads_[3]};
    if (!(late[1] | late[2] | late[3])) return;
    const size_t registers = std::min<size_t>(vertex.size() / 16, 256);
    uint64_t hash = 0xCBF29CE484222325ull;
    uint32_t first = 0, last = 0;
    for (size_t word = 1; word < 4; ++word)
      for (uint64_t bits = late[word]; bits; bits &= bits - 1) {
        const size_t reg = word * 64 + size_t(std::countr_zero(bits));
        if (reg >= registers) break;
        if (!first) first = uint32_t(reg);
        last = uint32_t(reg);
        for (size_t b = 0; b < 16; ++b) hash = (hash ^ vertex[reg * 16 + b]) * 0x100000001B3ull;
      }
    snapshot.late_hash = hash;
    // A chain starts at a previous draw that had no late hash (diagnostic just enabled).
    if (!lookup.previous || !lookup.previous->late_hash) return;
    const auto& previous = *lookup.previous;
    auto& out = lookup.late;
    out.valid = true;
    out.palette = late[2] == ~0ull && late[3] == ~0ull;
    out.world_late = (world_[1] & late[1]) != 0;
    out.sibling = sibling;
    out.first = first;
    out.last = last;
    out.moved = Distance(previous.vertex, vertex, false).max_world > 1.0e-4f;
    out.changed = previous.late_hash != hash;
    if (out.changed && previous.vertex.size() >= registers * 16)
      for (size_t word = 1; word < 4 && !out.first_changed; ++word)
        for (uint64_t bits = late[word]; bits; bits &= bits - 1) {
          const size_t reg = word * 64 + size_t(std::countr_zero(bits));
          if (reg >= registers) break;
          if (std::memcmp(previous.vertex.data() + reg * 16, vertex.data() + reg * 16, 16)) {
            out.first_changed = uint32_t(reg);
            break;
          }
        }
    snapshot.late_frames = previous.late_frames + 1;
    snapshot.late_changes = previous.late_changes + uint32_t(out.changed);
    out.frames = snapshot.late_frames;
    out.changes = snapshot.late_changes;
  }
  Difference Distance(std::span<const uint8_t> a, std::span<const uint8_t> b, bool all) const {
    Difference d;
    const size_t registers = std::min<size_t>(std::min(a.size(), b.size()) / 16, 256);
    // Only the compared registers, in ascending order (as a scan of all 256 would visit them,
    // so ties and the double sum come out the same): world_ alone is at most four.
    for (size_t word = 0; word < 4; ++word) {
     for (uint64_t bits = all ? reads_[word] | world_[word] : world_[word]; bits; bits &= bits - 1) {
      const size_t reg = word * 64 + size_t(std::countr_zero(bits));
      if (reg >= registers) break;
      const bool world = Reads(world_, reg);
      for (size_t i = reg * 4; i < reg * 4 + 4; ++i) {
        float x, y;
        std::memcpy(&x, a.data() + i * sizeof(float), sizeof(float));
        std::memcpy(&y, b.data() + i * sizeof(float), sizeof(float));
        if (!std::isfinite(x) || !std::isfinite(y)) continue;
        const float change = std::abs(x - y);
        if (world) d.max_world = std::max(d.max_world, change);
        if (world && reg < 3 && i % 4 < 3) d.max_rotation = std::max(d.max_rotation, change);
        if (change > d.max_any && !Reads(kCameraRegisters, reg)) {
          d.max_any = change;
          d.max_index = uint32_t(i);
        }
        d.sum += double(change) * change;
      }
     }
    }
    return d;
  }
  // The previous frame's draw of the same shape whose constants moved least, if it is clearly
  // nearer than any other and moved no further than an object can in one frame.
  std::shared_ptr<const GeometrySnapshot> Nearest(const HashedKey& key,
                                                  std::span<const uint8_t> vertex) {
    const auto shape = previous_shapes_.find(Shape(key));
    if (shape == previous_shapes_.end()) { ++statistics_.none; return nullptr; }
    const GeometrySnapshot* best = nullptr;
    double best_sum = 0, second_sum = -1;
    bool any_near = false;
    for (const auto& candidate : shape->second) {
      // Another frame's object still drawn under its own key this frame is not this one.
      // The pointer and key compares go first; the two hash lookups after them.
      if (claimed_.count(candidate.snapshot.get()) || candidate.key == key ||
          current_.count(candidate.key) || PreviousAmbiguous(candidate.key))
        continue;
      // Near() reads only the world registers (at most four): test those first, so the many
      // far candidates of a common shape skip the full pass over every register the shader
      // reads. Same result as testing the full difference.
      if (!Near(Distance(candidate.snapshot->vertex, vertex, false))) {
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
  // A candidate within one frame's movement: translation, and rotation when limited.
  bool Near(const Difference& d) const {
    return d.max_world <= kMaximumWorldStep && (rotation_limit_ <= 0 || d.max_rotation <= rotation_limit_);
  }
  float rotation_limit_ = 0;
  bool late_diagnostic_ = false;
  static constexpr size_t kMaximumShapeCandidates = 32;
  static constexpr uint32_t kMaximumSiblings = 64;  // past this, the last one is ambiguous (a street of one tree model)
  static constexpr float kMaximumWorldStep = 6.0f;      // ~650 km/h at 30 fps
  static constexpr float kMaximumConstantStep = 12.0f;  // bones included, camera not
  struct Candidate {
    HashedKey key;
    std::shared_ptr<GeometrySnapshot> snapshot;
  };
  std::unordered_map<HashedKey, std::vector<Candidate>, HashedKeyHash> previous_shapes_,
      current_shapes_, previous_siblings_, current_siblings_;
  // Per previous sibling group: the vertex constants (float index) that told its draws apart.
  std::unordered_map<const std::vector<Candidate>*, std::vector<uint32_t>> distinct_;
  std::unordered_set<const GeometrySnapshot*> claimed_;
  GeometryMatchStatistics statistics_{};
  ConstantMask reads_ = kAllConstants, world_ = WorldRegisters(kAllConstants);  // this Record's draw
  bool transform_fallback_ = false;
  std::unordered_map<HashedKey, Entry, HashedKeyHash> previous_, current_;
  std::shared_ptr<GeometryBudget> budget_;
  std::vector<std::shared_ptr<GeometrySnapshot>> pool_;
  static constexpr size_t kMaximumPooledSnapshots = 4096;
  size_t maximum_entries_;
  uint64_t epoch_ = 0, view_ = 0, sequence_ = 0;
};
}  // namespace rex::graphics::gta4_native::temporal
