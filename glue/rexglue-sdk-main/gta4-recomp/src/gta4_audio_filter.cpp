#include <algorithm>
#include <array>
#include <cstring>
#include <rex/cvar.h>
#include <rex/hook.h>
#include <rex/logging.h>
#include "gta4_init.h"
#include "gta4_audio_effects.h"
#include <vector>

REXCVAR_DEFINE_BOOL(gta4_native_audio_filter, false, "GTA IV/Performance",
    "Run the audio mixer's 4th-order filter effect (sub_829321A0, the hottest leaf of the mixer "
    "thread) natively, with the generated code's rounding");
REXCVAR_DEFINE_BOOL(gta4_native_audio_biquad, false, "GTA IV/Performance",
    "Run the audio mixer's per-channel EQ effect (sub_82936CE0) natively, with the generated "
    "code's rounding");
REXCVAR_DEFINE_BOOL(gta4_native_audio_biquad_verify, false, "GTA IV/Diagnostics",
    "Run the original per-channel EQ on the real data and the native one on copies, and compare the "
    "samples and channel state bit for bit; the game hears the original");
REXCVAR_DEFINE_BOOL(gta4_native_audio_reverb, false, "GTA IV/Performance",
    "Run the audio mixer's reverb effect (sub_82935BD0: 8 combs, 4 allpasses) natively, with the "
    "generated code's vector operations");
REXCVAR_DEFINE_BOOL(gta4_native_audio_reverb_verify, false, "GTA IV/Diagnostics",
    "Run the native reverb and the original on the same data and compare everything it writes bit for "
    "bit; the game hears the original");
REXCVAR_DEFINE_BOOL(gta4_native_audio_limiter, false, "GTA IV/Performance",
    "Run the audio mixer's limiter effect (sub_82934F00, both modes) natively, with the generated "
    "code's rounding");
REXCVAR_DEFINE_BOOL(gta4_native_audio_limiter_verify, false, "GTA IV/Diagnostics",
    "Run the native limiter and the original on the same data and compare everything it writes bit for "
    "bit; the game hears the original");
REXCVAR_DEFINE_BOOL(gta4_native_audio_filter_verify, false, "GTA IV/Diagnostics",
    "Run the original filter on the real data and the native one on a copy, and compare them bit "
    "for bit (buffer, state, coefficients, frequency cache, reset flags); the game hears the original");

namespace {
// Object layout (r3): +4 slot A (5 coefficients, 4 state), +40 slot B, +76 slot B frequency,
// +80 slot A frequency, +84/+88 the frequencies the coefficients were made for, +100/+101
// "slot was off last call" (its state restarts at zero). r4: the voice buffer object; its
// sample pointer is at +20 (sub_8218FB98).
constexpr uint32_t kObjectBytes = 104, kSampleBytes = 1024;
uint32_t Be32(const uint8_t* p) { return uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | p[3]; }
void SetBe32(uint8_t* p, uint32_t v) { p[0] = uint8_t(v >> 24); p[1] = uint8_t(v >> 16); p[2] = uint8_t(v >> 8); p[3] = uint8_t(v); }
float BeFloat(const uint8_t* p) { const uint32_t b = Be32(p); float f; std::memcpy(&f, &b, 4); return f; }
void SetBeFloat(uint8_t* p, float f) { uint32_t b; std::memcpy(&b, &f, 4); SetBe32(p, b); }
bool Contiguous(uint32_t address, uint32_t size) {
  const uint64_t end = uint64_t(address) + size;
  return end <= 0x100000000ull && !(address < 0xE0000000u && end > 0xE0000000ull);
}

struct VerifyCounters { uint64_t calls = 0, mismatched_calls = 0, logged = 0; };
VerifyCounters verify_counters;  // the mixer thread only
const char* FieldName(uint32_t offset) {
  if (offset < 4) return "header";
  if (offset < 24) return "A-coefficient";
  if (offset < 40) return "A-state";
  if (offset < 60) return "B-coefficient";
  if (offset < 76) return "B-state";
  if (offset < 84) return "frequency";
  if (offset < 92) return "frequency-cache";
  if (offset == 100 || offset == 101) return "reset-flag";
  return "other";
}
}  // namespace

REX_HOOK_RAW(sub_829321A0) {
  const bool verify = REXCVAR_GET(gta4_native_audio_filter_verify);
  const uint32_t self = ctx.r3.u32, buffer = ctx.r4.u32;
  if ((!verify && !REXCVAR_GET(gta4_native_audio_filter)) || !buffer || !Contiguous(self, kObjectBytes)) {
    __imp__sub_829321A0(ctx, base);
    return;
  }
  const uint32_t samples = REX_LOAD_U32(buffer + 20);
  if (!Contiguous(samples, kSampleBytes)) {
    __imp__sub_829321A0(ctx, base);
    return;
  }
  if (!verify) {
    gta4::audio::RunFilterGuest(ctx, base, self, samples);
    ctx.r3.u64 = 0;
    return;
  }
  // Verify: the native filter on copies taken before the original runs on the real data.
  std::array<uint8_t, kObjectBytes> object_copy;
  std::array<uint8_t, kSampleBytes> samples_copy;
  std::memcpy(object_copy.data(), REX_RAW_ADDR(self), kObjectBytes);
  std::memcpy(samples_copy.data(), REX_RAW_ADDR(samples), kSampleBytes);
  __imp__sub_829321A0(ctx, base);
  const uint64_t result = ctx.r3.u64;
  ctx.fpscr.disableFlushMode();
  gta4::audio::RunFilterEffect(object_copy.data(), samples_copy.data(), gta4::audio::ImageZero(base),
      [&](uint32_t kind, uint32_t frequency, float (&out)[5]) {
        gta4::audio::FilterCoefficients(ctx, base, self, kind, frequency, out);
      });
  ctx.r3.u64 = result;
  auto& v = verify_counters;
  ++v.calls;
  bool mismatch = false;
  const auto report = [&](const char* what, uint32_t offset, uint32_t original, uint32_t native) {
    mismatch = true;
    if (v.logged++ < 5)
      REXLOG_WARN("gta4-audio-filter-verify: mismatch call={} {} offset={} original={:08X} native={:08X}",
                  v.calls, what, offset, original, native);
  };
  const uint8_t* object = REX_RAW_ADDR(self);
  // +76/+80 (the slots' target frequencies) are inputs the game's sound thread rewrites at any
  // time; a change there between the snapshot and this check is a race, not a filter difference.
  for (uint32_t offset = 4; offset < 92; offset += 4)
    if (offset != 76 && offset != 80 &&
        !gta4::audio::SameResultWord(Be32(object + offset), Be32(object_copy.data() + offset)))
      report(FieldName(offset), offset, Be32(object + offset), Be32(object_copy.data() + offset));
  for (uint32_t offset : {100u, 101u})
    if (object[offset] != object_copy[offset]) report("reset-flag", offset, object[offset], object_copy[offset]);
  const uint8_t* real = REX_RAW_ADDR(samples);
  for (uint32_t i = 0; i < 256; ++i)
    if (!gta4::audio::SameResultWord(Be32(real + 4 * i), Be32(samples_copy.data() + 4 * i)))
      report("sample", i, Be32(real + 4 * i), Be32(samples_copy.data() + 4 * i));
  v.mismatched_calls += mismatch;
  if (v.calls % 1000 == 0)
    REXLOG_INFO("gta4-audio-filter-verify: calls={} mismatched-calls={}", v.calls, v.mismatched_calls);
}


namespace {
// Verify for the effects that write many guest regions: snapshot every region the effect writes,
// run the port, keep its result, restore the snapshot, run the original (the game hears it), and
// compare the two results word by word.
struct Region { uint32_t address, size; };

template <class Native, class Original>
void VerifyEffect(const char* tag, VerifyCounters& v, uint8_t* base, const std::vector<Region>& regions,
                  Native&& native, Original&& original) {
  size_t total = 0;
  for (const auto& r : regions) total += r.size;
  std::vector<uint8_t> before(total), ported(total);
  size_t at = 0;
  for (const auto& r : regions) { std::memcpy(before.data() + at, REX_RAW_ADDR(r.address), r.size); at += r.size; }
  native();
  at = 0;
  for (const auto& r : regions) { std::memcpy(ported.data() + at, REX_RAW_ADDR(r.address), r.size); at += r.size; }
  at = 0;
  for (const auto& r : regions) { std::memcpy(REX_RAW_ADDR(r.address), before.data() + at, r.size); at += r.size; }
  original();
  ++v.calls;
  bool mismatch = false;
  at = 0;
  for (size_t i = 0; i < regions.size(); ++i) {
    const uint8_t* real = REX_RAW_ADDR(regions[i].address);
    for (uint32_t offset = 0; offset + 4 <= regions[i].size; offset += 4) {
      const uint32_t original_word = Be32(real + offset), native_word = Be32(ported.data() + at + offset);
      if (gta4::audio::SameResultWord(original_word, native_word)) continue;
      mismatch = true;
      if (v.logged++ < 8)
        REXLOG_WARN("{}: mismatch call={} region={} address={:08X} original={:08X} native={:08X}", tag, v.calls, i,
                    regions[i].address + offset, original_word, native_word);
    }
    at += regions[i].size;
  }
  v.mismatched_calls += mismatch;
  if (v.calls % 1000 == 0) REXLOG_INFO("{}: calls={} mismatched-calls={}", tag, v.calls, v.mismatched_calls);
}

bool AllContiguous(const std::vector<Region>& regions) {
  for (const auto& r : regions) if (!Contiguous(r.address, r.size)) return false;
  return true;
}

VerifyCounters biquad_counters, reverb_counters, limiter_counters;  // the mixer thread only
}  // namespace

REX_HOOK_RAW(sub_82936CE0) {
  const bool verify = REXCVAR_GET(gta4_native_audio_biquad_verify);
  const uint32_t self = ctx.r3.u32, buffer = ctx.r4.u32;
  if ((!verify && !REXCVAR_GET(gta4_native_audio_biquad)) || !buffer || !Contiguous(self, 76) ||
      !Contiguous(buffer, 24)) {
    __imp__sub_82936CE0(ctx, base);
    return;
  }
  const uint8_t* object = REX_RAW_ADDR(self);
  const uint32_t channels = REX_LOAD_U8(buffer + 13), sample_base = REX_LOAD_U32(buffer + 20);
  uint32_t enabled = 0;
  std::vector<Region> regions;
  if (!object[68]) {
    for (uint32_t channel = 0; channel < channels; ++channel)
      if (gta4::audio::ChannelEnabled(object[74], channel)) {
        ++enabled;
        regions.push_back({sample_base + channel * kSampleBytes, kSampleBytes});
      }
  }
  uint32_t arrays[4];
  for (int i = 0; i < 4; ++i) {
    arrays[i] = gta4::audio::LoadBe32(object + 32 + 4 * i);
    if (enabled) regions.push_back({arrays[i], enabled * 4});
  }
  if (!AllContiguous(regions)) {
    __imp__sub_82936CE0(ctx, base);
    return;
  }
  const auto native = [&] { gta4::audio::RunBiquadGuest(ctx, base, self, channels, sample_base); };
  if (!verify) {
    native();
    ctx.r3.u64 = 0;
    return;
  }
  VerifyEffect("gta4-audio-biquad-verify", biquad_counters, base, regions, native,
               [&] { __imp__sub_82936CE0(ctx, base); });
}

REX_HOOK_RAW(sub_82935BD0) {
  const bool verify = REXCVAR_GET(gta4_native_audio_reverb_verify);
  const uint32_t self = ctx.r3.u32, buffer = ctx.r4.u32;
  if ((!verify && !REXCVAR_GET(gta4_native_audio_reverb)) || !buffer || !Contiguous(self, 80) ||
      !Contiguous(buffer, 24) || !gta4::audio::ReverbLengthsValid(base)) {
    __imp__sub_82935BD0(ctx, base);
    return;
  }
  const uint32_t channels = REX_LOAD_U8(buffer + 13), samples = REX_LOAD_U32(buffer + 20);
  const auto native = [&] { gta4::audio::RunReverb(ctx, base, self, channels, samples); };
  if (!verify) {
    native();
    ctx.r3.u64 = 0;
    return;
  }
  std::vector<Region> regions;
  const uint32_t mask = REX_LOAD_U8(self + 78);
  uint32_t enabled = 0;
  for (uint32_t channel = 0; channel < channels; ++channel) {
    if (!gta4::audio::ChannelEnabled(mask, channel)) continue;
    const uint32_t e4 = 4 * enabled++;
    regions.push_back({samples + channel * kSampleBytes, kSampleBytes});
    const uint32_t comb_positions = REX_LOAD_U32(REX_LOAD_U32(self + 16) + e4);
    const uint32_t comb_buffers = REX_LOAD_U32(REX_LOAD_U32(self + 8) + e4);
    const uint32_t allpass_positions = REX_LOAD_U32(REX_LOAD_U32(self + 48) + e4);
    const uint32_t allpass_buffers = REX_LOAD_U32(REX_LOAD_U32(self + 44) + e4);
    regions.push_back({comb_positions, 32});
    regions.push_back({allpass_positions, 16});
    regions.push_back({REX_LOAD_U32(REX_LOAD_U32(self + 12) + e4), 32});
    for (uint32_t k = 0; k < 8; ++k)
      regions.push_back({REX_LOAD_U32(comb_buffers + 4 * k) & ~0xFu,
                         REX_LOAD_U32(gta4::audio::kReverbCombLengths + 4 * k) * 4 + 32});
    for (uint32_t k = 0; k < 4; ++k)
      regions.push_back({REX_LOAD_U32(allpass_buffers + 4 * k) & ~0xFu,
                         REX_LOAD_U32(gta4::audio::kReverbAllpassLengths + 4 * k) * 4 + 32});
  }
  if (!AllContiguous(regions)) {
    __imp__sub_82935BD0(ctx, base);
    return;
  }
  VerifyEffect("gta4-audio-reverb-verify", reverb_counters, base, regions, native,
               [&] { __imp__sub_82935BD0(ctx, base); });
}

REX_HOOK_RAW(sub_82934F00) {
  const bool verify = REXCVAR_GET(gta4_native_audio_limiter_verify);
  const uint32_t self = ctx.r3.u32, buffer = ctx.r4.u32;
  if ((!verify && !REXCVAR_GET(gta4_native_audio_limiter)) || !buffer || !Contiguous(self, 660) ||
      !Contiguous(buffer, 24)) {
    __imp__sub_82934F00(ctx, base);
    return;
  }
  const uint32_t channels = REX_LOAD_U8(buffer + 13), samples = REX_LOAD_U32(buffer + 20);
  const bool lookahead = REX_LOAD_U8(self + 652) != 0;
  const uint32_t mask = REX_LOAD_U8(self + 658);
  std::vector<Region> regions;
  if (lookahead && channels) regions.push_back({gta4::audio::kLimiterScratch, 1024});
  for (uint32_t channel = 0; channel < channels; ++channel) {
    if (!gta4::audio::ChannelEnabled(mask, channel) || (!lookahead && channel == 3)) continue;
    regions.push_back({samples + channel * kSampleBytes, kSampleBytes});
    if (lookahead) {
      regions.push_back({self + 12 + 80 * channel, 80});
      regions.push_back({self + 492 + 4 * channel, 4});
    } else {
      for (uint32_t offset : {516u, 540u, 564u}) regions.push_back({self + offset + 4 * channel, 4});
    }
  }
  if (!AllContiguous(regions)) {
    __imp__sub_82934F00(ctx, base);
    return;
  }
  const auto native = [&] { gta4::audio::RunLimiter(ctx, base, self, channels, samples); };
  if (verify) {
    VerifyEffect("gta4-audio-limiter-verify", limiter_counters, base, regions, native,
                 [&] { __imp__sub_82934F00(ctx, base); });
    return;
  }
  gta4::audio::RunLimiterTimed(ctx, base, self, channels, samples);
}
