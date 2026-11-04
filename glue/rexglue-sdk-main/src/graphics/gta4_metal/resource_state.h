#include "material_binding.h"
#pragma once
#include "resources.h"
#include "sampler_key.h"
#include "texture_preparation.h"
#include "../gta4_native/native_reflection_registry.h"
#include "../../ui/metal/context.h"
#include "../gta4_native/core/geometry.h"
#include "../gta4_native/native_buffer_metadata.h"
#include "../gta4_native/native_texture_image_identity.h"
#include <array>
#include <list>
#include <map>
#include <tuple>
#include <rex/graphics/gta4_native/surface_view.h>
#include <unordered_set>

namespace rex::graphics::gta4_metal {
struct ResourceStore::State {
  struct Buffer;
  using ConversionKey = std::tuple<uint64_t, uint64_t, uint32_t, uint32_t, uint32_t>;
  struct Conversion {
    uint64_t declaration = 0, shader = 0;
    uint32_t stream = 0, offset = 0, stride = 0;
    id<MTLBuffer> buffer = nil;
    size_t allocated_bytes = 0;
    Buffer* owner = nullptr;
    std::list<Conversion*>::iterator recency;
    std::vector<uint64_t> corrections;
    size_t charged_bytes=0;
  };
  struct Buffer {
    uint64_t generation = 0;
    uint32_t flags = 0, address = 0, size = 0;
    size_t validation_offset = 0;
    uint64_t validated_frame = ~uint64_t{0};  // ResourceStore frame of the last passed slice
    std::vector<uint8_t> payload;
    // Stable nodes support keyed lookup and the global conversion LRU.
    std::map<ConversionKey, Conversion> vertices;
    id<MTLBuffer> indices = nil;
    std::list<uint32_t>::iterator recency;
  };
  std::shared_ptr<ui::metal::MetalContext> context;
  GuestMemory memory;
  TexturePreparation preparation;
  gta4_native::NativeVirtualResourceRegistry virtuals;
  gta4_native::NativeReflectionRegistry reflections;
  std::unordered_map<uint32_t, std::shared_ptr<SurfaceResource>> surfaces;
  // Title view relationships only: no GPU heap or emulated-memory allocation.
  // The index owns no images and entries retire with their guest name.
  std::unordered_map<gta4_native::GuestPlacementKey, std::vector<uint32_t>,
      gta4_native::GuestPlacementKeyHash> color_views;
  std::unordered_map<uint32_t, std::shared_ptr<TextureResource>> textures;
  std::list<uint32_t> texture_lru;
  uint64_t texture_evictions = 0, texture_rejections = 0, texture_idle_trims = 0;
  uint64_t frame = 0;
  void TouchTexture(TextureResource& texture) {
    texture_lru.splice(texture_lru.end(), texture_lru, texture.recency);
    texture.last_used_frame = frame;
  }
  bool ReloadableTexture(uint32_t handle, const TextureResource& texture) const {
    return !texture.gpu_produced && !virtuals.Find(handle) && !reflections.contains(handle);
  }
  void TrimIdleTextures();
  std::unordered_map<uint32_t, Buffer> buffers;
  std::unordered_map<uint32_t, uint32_t> font_ids;
  bool vector_fonts = true;
  std::list<uint32_t> buffer_lru;
  size_t buffer_capture_budget = ResourceStore::kDefaultBufferCaptureBudget;
  uint64_t buffer_evictions = 0;
  uint64_t buffer_validations = 0, buffer_validation_skips = 0, buffer_validation_mismatches = 0;
  bool buffer_validation_per_use = false;  // gta4_metal_buffer_validation_per_use, per frame
  // Reused captures already validated this frame, by handle (direct-mapped): a byte-identical
  // guest header skips the metadata decode and the map lookup. Any erase invalidates it
  // (buffer_epoch); `frame` through Buffer::validated_frame; a later Invalidate through
  // dirty_serial. One cache line per slot; 2048 slots so a frame's working set (often more
  // than 256 distinct vertex and index buffers) does not evict itself.
  struct alignas(64) BufferMemo {
    uint32_t handle = 0;
    uint64_t epoch = 0;
    uint64_t dirty_serial = 0;  // State::dirty_serial when remembered: no insert since
    Buffer* buffer = nullptr;
    std::array<uint8_t, 32> header{};
  };
  static_assert(sizeof(BufferMemo) == 64);
  static constexpr unsigned kBufferMemoBits = 11;
  std::array<BufferMemo, size_t{1} << kBufferMemoBits> buffer_memo{};
  BufferMemo& BufferMemoSlot(uint32_t handle) {
    return buffer_memo[uint32_t(handle * 0x9E3779B1u) >> (32 - kBufferMemoBits)];
  }
  uint64_t buffer_epoch = 1, buffer_memo_hits = 0;
  void TouchBuffer(Buffer& buffer) {
    buffer_lru.splice(buffer_lru.end(), buffer_lru, buffer.recency);
  }
  std::unordered_set<uint32_t> dirty;
  // Bumped by every insert into `dirty` (always through MarkDirty): a memo remembered at the
  // current serial cannot name a handle made dirty since, so its hit skips the set lookup.
  uint64_t dirty_serial = 1;
  void MarkDirty(uint32_t handle) {
    dirty.insert(handle);
    ++dirty_serial;
  }
  uint64_t surface_epoch = 1;  // ResourceStore::surface_epoch()
  std::unordered_map<SamplerKey, id<MTLSamplerState>, SamplerKeyHash> samplers;
  uint64_t next_generation = 1, serial = 0;
  uint64_t binding_epoch=1,material_hits=0,material_misses=0;
  std::array<MaterialBinding,128> material_bindings{};
  void InvalidateBindings(){
    if(++binding_epoch==0){for(auto& b:material_bindings)b.epoch=0;binding_epoch=1;}
  }
  size_t texture_budget = 0;
  size_t resident_texture_bytes = 0;
  size_t captured_buffer_bytes = 0;
  size_t resident_buffer_bytes = 0;
  // The former two conversions per captured payload could already retain
  // roughly twice the 256 MiB capture budget. Preserve that working-set scale
  // while allowing useful variants to share it across guest buffers.
  static constexpr size_t kVertexConversionBudget = 512 * 1024 * 1024;
  // Charge retained map/list bookkeeping too, so tiny buffers cannot create
  // an unbounded number of metadata nodes within the Metal-byte budget.
  static constexpr size_t kVertexConversionEntryCharge = 256;
  size_t vertex_conversion_budget = kVertexConversionBudget;
  std::list<Conversion*> vertex_conversion_lru;
  size_t vertex_conversion_bytes = 0;
  size_t vertex_conversion_budget_bytes = 0;
  uint64_t vertex_conversion_hits = 0, vertex_conversion_misses = 0;
  uint64_t vertex_conversion_evictions = 0;
  void InstallTexture(uint32_t handle, std::shared_ptr<TextureResource> value);
  void InstallSurface(uint32_t handle, std::shared_ptr<SurfaceResource> value);
  void EraseTexture(uint32_t handle);
  void EraseSurface(uint32_t handle);
  void EraseBuffer(uint32_t handle);
  void EraseBufferConversions(Buffer& buffer);
  void EraseVertexConversion(Buffer& buffer, std::map<ConversionKey, Conversion>::iterator entry);
  void TrimVertexConversions(size_t incoming_bytes);
  uint32_t scene_samples = 1;
  std::string filtering, anisotropy;
  State(std::shared_ptr<ui::metal::MetalContext> c, GuestMemory m);
  Buffer* CaptureBuffer(uint32_t handle, std::string& error);
  std::shared_ptr<TextureResource> FontTexture(uint32_t handle, uint32_t font_id,
      const xenos::xe_gpu_texture_fetch_t&, id<MTLCommandBuffer>,
      const std::function<void()>& end_render, std::string& error);
  bool AdmitTexture(size_t bytes, uint32_t handle, bool surface, std::string& error);
  std::shared_ptr<TextureResource> AllocateTexture(uint32_t handle,
      const xenos::xe_gpu_texture_fetch_t& fetch, bool render_target, std::string& error);
};
}  // namespace rex::graphics::gta4_metal
