#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace rex::graphics::gta4_metal {

// Serialized fields are little-endian; no compiler struct layout is on disk.
// Views borrow the mapped file. Its owner must outlive the ArchiveIndex.
inline constexpr uint32_t kMetalArchiveVersion = 3;
inline constexpr size_t kMetalArchiveHeaderBytes = 64;
inline constexpr size_t kMetalArchiveRecordBytes = 128;  // v3: +256-bit constant mask
inline constexpr size_t kMetalArchiveAttributeBytes = 16;
inline constexpr size_t kMetalArchiveMaximumBytes = 256u * 1024u * 1024u;
inline constexpr uint32_t kMetalArchiveMaximumShaders = 16384;
inline constexpr uint32_t kMetalArchiveMaximumAttributes = 31;
inline constexpr uint32_t kMetalArchiveTextureMask = (uint32_t{1} << 26) - 1;

enum class MetalArchiveStage : uint32_t { kPixel, kVertex };
enum class MetalVertexScalar : uint32_t { kFloat, kSignedInteger, kUnsignedInteger };
enum MetalShaderFlags : uint32_t {
  kMetalShaderEarlyTests = 1,
  kMetalShaderLateVariant = 2,
  kMetalShaderNativeOutput = 4,
  kMetalShaderCoverage = 8,
};

struct MetalVertexAttribute {
  uint32_t index = 0;
  uint32_t semantic_location = 0;
  MetalVertexScalar scalar_type = MetalVertexScalar::kFloat;
  uint32_t components = 0;
  bool operator==(const MetalVertexAttribute&) const = default;
};

struct MetalShaderRecord {
  uint64_t hash = 0;
  MetalArchiveStage stage = MetalArchiveStage::kPixel;
  uint32_t used_texture_mask = 0;
  uint32_t specialization_constants_mask = 0;
  uint32_t output_mask = 0;
  uint32_t flags = 0;
  uint32_t attribute_count = 0;
  std::array<MetalVertexAttribute, kMetalArchiveMaximumAttributes> attributes{};
  // Bit n of word n/64: the shader may read float constant cN of its stage's bank.
  // Derived from the translated source; all ones where reads were not derived.
  std::array<uint64_t, 4> float_constant_mask{~0ull, ~0ull, ~0ull, ~0ull};  // unknown: every register
  std::string_view name;
  std::span<const std::byte> early_library;
  std::span<const std::byte> late_library;
};

using MetalArchiveDigestVerifier = std::function<bool(
    std::span<const std::byte>, std::span<const std::byte, 32>)>;
// Seeded 64-bit hash (XXH3_64bits_withSeed at runtime); chained over the archive's records.
using MetalArchiveHash = std::function<uint64_t(std::span<const std::byte>, uint64_t seed)>;

class MetalShaderArchive {
 public:
  // Validation is transactional. A failed open leaves an empty index.
  bool Open(std::span<const std::byte> bytes, const MetalArchiveDigestVerifier& digest,
            std::string& error);
  const MetalShaderRecord* Find(uint64_t hash, MetalArchiveStage stage) const noexcept;
  std::span<const MetalShaderRecord> records() const noexcept { return records_; }
  // Identity of everything that can reach a compiled pipeline: each record's hash, stage,
  // texture/specialization/output masks, flags, vertex attributes and Metal libraries. The
  // name and float_constant_mask are left out, so metadata that no pipeline sees (and the
  // archive container version) do not invalidate the pipeline binary archive keyed on it.
  uint64_t PipelineIdentity(const MetalArchiveHash& hash) const;
  void Clear() noexcept { records_.clear(); }

 private:
  std::vector<MetalShaderRecord> records_;
};

}  // namespace rex::graphics::gta4_metal
