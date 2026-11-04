#pragma once
// Per-draw bottom-level acceleration structures for ray-traced AO and shadows,
// kept across frames. CPU-only decisions; the Metal objects are the `Payload`.
//
// A draw's geometry identity is what the guest drew (shaders, layout, buffer
// generations, index range), never where: the same mesh drawn twice in one frame
// gets occurrence 0 and 1. Its motion hash is what places it (the world/bone
// registers its vertex shader reads). Static geometry is captured and built once,
// and then only instanced. Movers are recaptured and refit. Builds, refits and
// bytes have per-frame and total budgets so a dense frame cannot stall.
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <unordered_map>
#include <utility>
#include <vector>

namespace rex::graphics::gta4_metal::raytracing {

struct GeometryIdentity {
  uint64_t geometry = 0;   // hash of shaders, layout, stream/index generations, range and primitive
  uint32_t triangles = 0;  // topology: a change means a rebuild, never a refit
  uint32_t vertices = 0;
  bool operator==(const GeometryIdentity&) const = default;
};

struct CaptureRequest {
  GeometryIdentity identity;
  uint64_t motion = 0;   // hash of the placement registers; equal means the positions are equal
  bool dynamic = false;  // skinned, vertex-textured or otherwise not decided by `motion`: refit every frame
};

enum class CaptureAction : uint8_t {
  kReuse,  // instance the stored structure; no capture draw
  kRefit,  // capture this frame's positions and refit in place
  kBuild,  // capture and build a new structure (an earlier one for this slot is replaced)
  kSkip,   // over budget: leave this draw out of this frame's scene
};

struct AccelBudget {
  uint32_t builds_per_frame = 16;
  uint32_t refits_per_frame = 64;
  uint64_t total_bytes = 192ull << 20;
  uint32_t retain_frames = 120;  // unused for longer than this: evicted even under budget
  // Until Built() reports the real size: bytes per triangle of a primitive structure.
  uint32_t estimated_bytes_per_triangle = 96;
};

struct AccelStatistics {
  uint64_t requests = 0, reused = 0, refit = 0, built = 0, rebuilt = 0;
  uint64_t stale = 0;           // a mover reused unrefit because refits ran out
  uint64_t skipped_builds = 0;  // new geometry left out: build budget
  uint64_t skipped_bytes = 0;   // new geometry left out: byte budget
  uint64_t evicted = 0;
  uint64_t bytes = 0;           // resident now
  uint64_t instances = 0;       // in the last frame's scene
};

template <class Payload>
class AccelCache {
 public:
  struct Slot {
    GeometryIdentity identity;
    uint32_t occurrence = 0;
    uint64_t motion = 0;
    uint64_t bytes = 0;
    uint64_t last_frame = 0;
    bool ready = false;  // Built() was reported; until then it is not instanced
    Payload payload{};
  };
  struct Decision {
    CaptureAction action = CaptureAction::kSkip;
    Slot* slot = nullptr;  // set for every action but kSkip
  };

  explicit AccelCache(AccelBudget budget = {}) : budget_(budget) {}
  void set_budget(const AccelBudget& budget) { budget_ = budget; }
  const AccelBudget& budget() const { return budget_; }

  void BeginFrame(uint64_t frame) {
    frame_ = frame;
    builds_ = refits_ = 0;
    occurrences_.clear();
    scene_.clear();
  }

  // One call per world draw this frame, in draw order.
  Decision Request(const CaptureRequest& request) {
    ++statistics_.requests;
    const uint32_t occurrence = occurrences_[request.identity.geometry]++;
    const SlotKey key{request.identity.geometry, occurrence};
    auto found = slots_.find(key);
    if (found != slots_.end()) {
      // Occurrences make each key unique within a frame, so this slot is not in the scene yet.
      Slot& slot = found->second;
      if (slot.ready && slot.identity == request.identity) {
        slot.last_frame = frame_;
        if (!request.dynamic && slot.motion == request.motion) return Use(slot, CaptureAction::kReuse);
        if (refits_ < budget_.refits_per_frame) {
          ++refits_;
          slot.motion = request.motion;
          return Use(slot, CaptureAction::kRefit);
        }
        ++statistics_.stale;
        return Use(slot, CaptureAction::kReuse);
      }
      // Topology changed (or an earlier build never completed): build again.
      if (builds_ >= budget_.builds_per_frame) { ++statistics_.skipped_builds; return {}; }
      const uint64_t estimate = Estimate(request.identity);
      if (resident_bytes_ - slot.bytes + estimate > budget_.total_bytes && !EvictFor(estimate, &slot)) {
        ++statistics_.skipped_bytes;
        return {};
      }
      ++builds_;
      ++statistics_.rebuilt;
      resident_bytes_ -= slot.bytes;
      // Earlier frames' scenes may still reference the old structure on the GPU.
      if (slot.ready) pending_release_.push_back(std::move(slot.payload));
      slot = Slot{request.identity, occurrence, request.motion, estimate, frame_, false, Payload{}};
      resident_bytes_ += estimate;
      return {CaptureAction::kBuild, &slot};
    }
    if (builds_ >= budget_.builds_per_frame) { ++statistics_.skipped_builds; return {}; }
    const uint64_t estimate = Estimate(request.identity);
    if (resident_bytes_ + estimate > budget_.total_bytes && !EvictFor(estimate, nullptr)) {
      ++statistics_.skipped_bytes;
      return {};
    }
    ++builds_;
    auto& slot = slots_[key];
    slot = Slot{request.identity, occurrence, request.motion, estimate, frame_, false, Payload{}};
    resident_bytes_ += estimate;
    return {CaptureAction::kBuild, &slot};
  }

  // After a kBuild has been encoded: its real size and object. It is instanced from now on.
  void Built(Slot& slot, uint64_t bytes, Payload payload) {
    resident_bytes_ = resident_bytes_ - slot.bytes + bytes;
    slot.bytes = bytes;
    slot.payload = std::move(payload);
    slot.ready = true;
    ++statistics_.built;
    scene_.push_back(&slot);
  }
  // A build that could not be encoded: forget it so the next frame tries again.
  // The caller keeps any payload it had already reported through Built().
  void Abandon(Slot& slot) {
    scene_.erase(std::remove(scene_.begin(), scene_.end(), &slot), scene_.end());
    for (auto it = slots_.begin(); it != slots_.end(); ++it)
      if (&it->second == &slot) { resident_bytes_ -= slot.bytes; slots_.erase(it); return; }
  }

  // Ends the frame: drops slots unused for too long, then least recently used
  // ones while over budget. `release` receives each evicted payload.
  template <class Release>
  void EndFrame(Release&& release) {
    statistics_.instances = scene_.size();
    for (auto& payload : pending_release_) release(payload);
    pending_release_.clear();
    for (auto it = slots_.begin(); it != slots_.end();) {
      if (frame_ - it->second.last_frame > budget_.retain_frames) {
        Evict(it, release);
      } else {
        ++it;
      }
    }
    while (resident_bytes_ > budget_.total_bytes) {
      auto oldest = Oldest(nullptr);
      if (oldest == slots_.end()) break;
      Evict(oldest, release);
    }
    statistics_.bytes = resident_bytes_;
  }

  // This frame's instances, in request order: each a ready structure used this frame.
  const std::vector<Slot*>& scene() const { return scene_; }
  const AccelStatistics& statistics() const { return statistics_; }
  size_t size() const { return slots_.size(); }
  uint64_t resident_bytes() const { return resident_bytes_; }

  // Releases everything (device loss, mode change).
  template <class Release>
  void Clear(Release&& release) {
    for (auto& [key, slot] : slots_) release(slot.payload);
    for (auto& payload : pending_release_) release(payload);
    pending_release_.clear();
    slots_.clear();
    scene_.clear();
    resident_bytes_ = 0;
  }

 private:
  struct SlotKey {
    uint64_t geometry;
    uint32_t occurrence;
    bool operator==(const SlotKey&) const = default;
  };
  struct SlotKeyHash {
    size_t operator()(const SlotKey& k) const noexcept {
      uint64_t h = k.geometry ^ (uint64_t(k.occurrence) * 0x9e3779b97f4a7c15ull);
      h ^= h >> 33; h *= 0xff51afd7ed558ccdull; h ^= h >> 33;
      return size_t(h);
    }
  };
  using Map = std::unordered_map<SlotKey, Slot, SlotKeyHash>;

  Decision Use(Slot& slot, CaptureAction action) {
    (action == CaptureAction::kRefit ? statistics_.refit : statistics_.reused)++;
    scene_.push_back(&slot);
    return {action, &slot};
  }
  uint64_t Estimate(const GeometryIdentity& identity) const {
    return uint64_t(std::max(identity.triangles, 1u)) * budget_.estimated_bytes_per_triangle;
  }
  typename Map::iterator Oldest(const Slot* keep) {
    auto oldest = slots_.end();
    for (auto it = slots_.begin(); it != slots_.end(); ++it) {
      if (&it->second == keep || it->second.last_frame == frame_) continue;  // in this frame's scene
      if (oldest == slots_.end() || it->second.last_frame < oldest->second.last_frame) oldest = it;
    }
    return oldest;
  }
  // Frees slots not used this frame until `bytes` fit. Payloads of slots evicted
  // here are released at EndFrame (their GPU work from earlier frames may still run).
  bool EvictFor(uint64_t bytes, const Slot* keep) {
    const uint64_t kept = keep ? keep->bytes : 0;
    while (resident_bytes_ - kept + bytes > budget_.total_bytes) {
      auto oldest = Oldest(keep);
      if (oldest == slots_.end()) return false;
      resident_bytes_ -= oldest->second.bytes;
      pending_release_.push_back(std::move(oldest->second.payload));
      slots_.erase(oldest);
      ++statistics_.evicted;
    }
    return true;
  }
  template <class Release>
  void Evict(typename Map::iterator& it, Release& release) {
    resident_bytes_ -= it->second.bytes;
    release(it->second.payload);
    it = slots_.erase(it);
    ++statistics_.evicted;
  }

  AccelBudget budget_;
  AccelStatistics statistics_;
  Map slots_;
  std::unordered_map<uint64_t, uint32_t> occurrences_;
  std::vector<Slot*> scene_;
  std::vector<Payload> pending_release_;
  uint64_t frame_ = 0;
  uint32_t builds_ = 0, refits_ = 0;
  uint64_t resident_bytes_ = 0;
};

}  // namespace rex::graphics::gta4_metal::raytracing
