#pragma once
#include <algorithm>
#include <array>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <span>
#include <vector>

#include <xxhash.h>

namespace rex::graphics::gta4_metal {
// Registers [lo, hi] a shader reads from one float bank, from its archive v3 read mask.
struct ConstantRange {
  uint32_t lo = 0, hi = 0;
  bool empty = true;
  uint32_t registers() const { return empty ? 0 : hi - lo + 1; }
  bool Contains(const ConstantRange& other) const {
    return other.empty || (!empty && lo <= other.lo && other.hi <= hi);
  }
};

// The lowest and highest read register, clamped to the bank (the pixel bank has 224).
// A mask with no read register inside the bank is empty.
inline ConstantRange RangeOf(const std::array<uint64_t, 4>& mask, uint32_t bank_registers) {
  ConstantRange range;
  for (uint32_t word = 0; word < mask.size(); ++word) {
    if (!mask[word]) continue;
    const uint32_t low = word * 64 + uint32_t(std::countr_zero(mask[word]));
    if (low >= bank_registers) break;
    if (range.empty) { range.lo = low; range.empty = false; }
    range.hi = std::min(word * 64 + 63 - uint32_t(std::countl_zero(mask[word])), bank_registers - 1);
  }
  return range;
}

// Diagnostic model of range-limited constant uploads (BACKLOG 75). It counts
// what [lo, hi] uploads with exact-range cache keys and a last-bank containment
// check would send and reuse, beside the real full-bank path. It never allocates
// or binds anything the renderer uses.
class ConstantRangeShadow {
 public:
  struct Statistics {
    uint64_t requests = 0;         // banks a draw needed
    uint64_t empty = 0;            // the shader reads no register of this bank
    uint64_t clean_hits = 0;       // guest unchanged and the last range covers this one
    uint64_t clean_uncovered = 0;  // guest unchanged, but a full-bank clean skip would not cover it
    uint64_t last_hits = 0;        // the last uploaded range contains this one with equal bytes
    uint64_t hash_hits = 0;        // the same range and bytes were uploaded in this command buffer
    uint64_t misses = 0;
    uint64_t bytes = 0;            // range bytes the misses would upload
  };
  static constexpr size_t kBanks = 2;  // 0 = vertex, 1 = pixel

  // `guest` is the whole guest bank. `clean` is the real tracking state taken
  // before this draw's upload: the guest bank is unchanged since the last
  // upload of this bank, which is also the last Observe of it.
  void Observe(size_t bank, std::span<const uint8_t> guest, ConstantRange range, bool clean) {
    auto& b = banks_[bank];
    auto& s = statistics_[bank];
    ++s.requests;
    if (range.empty) { ++s.empty; return; }
    if (size_t(range.hi + 1) * 16 > guest.size()) range.hi = uint32_t(guest.size() / 16) - 1;
    const size_t offset = size_t(range.lo) * 16, size = size_t(range.registers()) * 16;
    const auto bytes = guest.subspan(offset, size);
    if (clean && b.valid) {
      if (b.range.Contains(range)) { ++s.clean_hits; return; }
      ++s.clean_uncovered;
    }
    if (b.valid && b.range.Contains(range) && !std::memcmp(b.source.data() + offset, bytes.data(), size)) {
      ++s.last_hits; return;
    }
    const uint64_t seed = uint64_t(bank) << 32 | uint64_t(range.lo) << 16 | range.hi;
    const uint64_t hash = XXH3_64bits_withSeed(bytes.data(), size, seed);
    if (Insert(hash)) { ++s.misses; s.bytes += size; }
    else ++s.hash_hits;
    // Real uploads keep the full guest snapshot; only this range of it is valid here.
    std::memcpy(b.source.data() + offset, bytes.data(), size);
    b.range = range; b.valid = true;
  }
  // With the real cache: per command buffer. Last-bank state survives, as the real one does.
  void Clear() {
    if (!used_) return;
    std::fill(table_.begin(), table_.end(), 0);
    used_ = 0;
  }
  // With the real last-bank reset at the start of a command buffer.
  void Reset() { for (auto& b : banks_) b.valid = false; Clear(); }
  const Statistics& statistics(size_t bank) const { return statistics_[bank]; }

 private:
  struct Bank {
    std::array<uint8_t, 4096> source{};
    ConstantRange range;
    bool valid = false;
  };
  // Open addressing on non-zero hashes; capacity survives Clear().
  bool Insert(uint64_t hash) {
    hash |= 1;  // 0 marks a free slot
    if ((used_ + 1) * 2 > table_.size()) Grow();
    for (size_t i = hash & (table_.size() - 1);; i = (i + 1) & (table_.size() - 1)) {
      if (table_[i] == hash) return false;
      if (!table_[i]) { table_[i] = hash; ++used_; return true; }
    }
  }
  void Grow() {
    std::vector<uint64_t> old(table_.empty() ? 2048 : table_.size() * 2, 0);
    old.swap(table_);
    used_ = 0;
    for (const uint64_t h : old)
      if (h) for (size_t i = h & (table_.size() - 1);; i = (i + 1) & (table_.size() - 1))
        if (!table_[i]) { table_[i] = h; ++used_; break; }
  }
  std::array<Bank, kBanks> banks_;
  std::array<Statistics, kBanks> statistics_;
  std::vector<uint64_t> table_;
  size_t used_ = 0;
};
// Last upload of one float bank in range mode (gta4_metal_range_constants).
// It holds the guest bytes of [lo, hi] only, at their bank offsets.
inline constexpr uint32_t kConstantCanary = 0x7FC0DEADu;  // a quiet NaN: unread registers in the canary audit
template <class Upload>
class RangeBank {
 public:
  struct Found {
    const Upload* upload = nullptr;  // holds the stored range, whose first register is `range.lo`
    ConstantRange range;
    // Every stored register was compared equal to the guest, so tracking may mark
    // the bank copied. A clean or partial hit must not: registers outside the
    // requested range were not checked, and a later clean skip would trust them.
    bool verified = false;
    explicit operator bool() const { return upload != nullptr; }
  };
  // `clean`: the guest bank is unchanged since this bank was last marked copied.
  Found Find(ConstantRange range, std::span<const uint8_t> bank, bool clean) const {
    if (!valid_ || !range_.Contains(range)) return {};
    if (clean) return {&upload_, range_, false};
    if (!Matches(range, bank)) return {};
    return {&upload_, range_, range.lo == range_.lo && range.hi == range_.hi};
  }
  // Compares `range` (inside the stored one) with the guest bank.
  bool Matches(ConstantRange range, std::span<const uint8_t> bank) const {
    const size_t offset = size_t(range.lo) * 16, size = size_t(range.registers()) * 16;
    return !std::memcmp(source_.data() + offset, bank.data() + offset, size);
  }
  void Store(ConstantRange range, std::span<const uint8_t> bank, const Upload& upload) {
    const size_t offset = size_t(range.lo) * 16, size = size_t(range.registers()) * 16;
    std::memcpy(source_.data() + offset, bank.data() + offset, size);
    range_ = range; upload_ = upload; valid_ = true;
  }
  void Reset() { valid_ = false; upload_ = {}; }
  bool valid() const { return valid_; }

 private:
  std::array<uint8_t, 4096> source_{};
  ConstantRange range_;
  Upload upload_{};
  bool valid_ = false;
};

// The range a draw uploads: the shader's read range clamped to the bank. A shader
// that reads nothing still gets one register, so its address stays inside a slice.
inline ConstantRange UploadRangeOf(ConstantRange range, size_t bank_bytes) {
  const uint32_t registers = uint32_t(bank_bytes / 16);
  if (range.empty || !registers || range.lo >= registers) return {0, 0, false};
  range.hi = std::min(range.hi, registers - 1);
  return range;
}
}  // namespace rex::graphics::gta4_metal
