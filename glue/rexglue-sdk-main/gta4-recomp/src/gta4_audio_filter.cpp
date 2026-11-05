#include <algorithm>
#include <array>
#include <cstring>
#include <rex/cvar.h>
#include <rex/hook.h>
#include <rex/logging.h>
#include "gta4_init.h"
#include "gta4_audio_filter.h"

REXCVAR_DEFINE_BOOL(gta4_native_audio_filter, false, "GTA IV/Performance",
    "Run the audio mixer's 4th-order filter effect (sub_829321A0, the hottest leaf of the mixer "
    "thread) natively, with the generated code's rounding");
REXCVAR_DEFINE_BOOL(gta4_native_audio_biquad, false, "GTA IV/Performance",
    "Run the audio mixer's per-channel EQ effect (sub_82936CE0) natively, with the generated "
    "code's rounding");
REXCVAR_DEFINE_BOOL(gta4_native_audio_biquad_verify, false, "GTA IV/Diagnostics",
    "Run the original per-channel EQ on the real data and the native one on copies, and compare the "
    "samples and channel state bit for bit; the game hears the original");
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

// The whole effect on host views of the object and the samples (guest memory or a copy).
// `coefficients(kind, frequency, out)` runs sub_82932090. Returns false when nothing ran.
template <class Coefficients>
void Run(uint8_t* object, uint8_t* samples, float zero, Coefficients&& coefficients) {
  const uint32_t frequency_b = Be32(object + 76), frequency_a = Be32(object + 80);
  const bool use_a = frequency_a < 23900, use_b = frequency_b != 0;
  if (!use_a && !use_b) return;
  gta4::audio::FilterSlot a{}, b{};
  for (int i = 0; i < 5; ++i) { a.c[i] = BeFloat(object + 4 + 4 * i); b.c[i] = BeFloat(object + 40 + 4 * i); }
  for (int i = 0; i < 4; ++i) { a.s[i] = BeFloat(object + 24 + 4 * i); b.s[i] = BeFloat(object + 60 + 4 * i); }
  if (use_a && object[100]) for (float& v : a.s) v = zero;
  if (use_b && object[101]) for (float& v : b.s) v = zero;
  if (Be32(object + 88) != frequency_a) {
    coefficients(1u, frequency_a, a.c);
    for (int i = 0; i < 5; ++i) SetBeFloat(object + 4 + 4 * i, a.c[i]);
  }
  if (Be32(object + 84) != frequency_b) {
    coefficients(0u, frequency_b, b.c);
    for (int i = 0; i < 5; ++i) SetBeFloat(object + 40 + 4 * i, b.c[i]);
  }
  SetBe32(object + 88, frequency_a);
  SetBe32(object + 84, frequency_b);
  object[101] = use_b ? 0 : 1;
  object[100] = use_a ? 0 : 1;
  gta4::audio::Filter256(samples, a, use_a, b, use_b);
  for (int i = 0; i < 4; ++i) {
    SetBeFloat(object + 24 + 4 * i, gta4::audio::FlushDenormal(a.s[i], zero));
    SetBeFloat(object + 60 + 4 * i, gta4::audio::FlushDenormal(b.s[i], zero));
  }
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
  const uint32_t zero_bits = REX_LOAD_U32(0x82000A34);  // the constant the original loads into f31
  float zero;
  std::memcpy(&zero, &zero_bits, 4);
  const uint32_t caller_stack = ctx.r1.u32, frame = caller_stack - 240;
  // sub_82932090 (r4 = 1 for slot A, 0 for B) writes five coefficients to a stack area of the
  // original's frame (r1 - 240, +144 for A, +96 for B); it reads nothing else of the object.
  const auto coefficients = [&](uint32_t kind, uint32_t frequency, float (&out)[5]) {
    const uint32_t area = frame + (kind ? 144 : 96);
    REX_STORE_U32(frame, caller_stack);
    ctx.r1.u64 = frame;
    ctx.r3.u64 = self; ctx.r4.u64 = kind; ctx.r5.u64 = frequency; ctx.r6.u64 = area;
    ctx.lr = kind ? 0x82932294 : 0x829322DC;
    sub_82932090(ctx, base);
    ctx.r1.u64 = caller_stack;
    for (int i = 0; i < 5; ++i) out[i] = BeFloat(REX_RAW_ADDR(area + 4 * i));
    ctx.fpscr.disableFlushMode();
  };
  if (!verify) {
    ctx.fpscr.disableFlushMode();
    Run(REX_RAW_ADDR(self), REX_RAW_ADDR(samples), zero, coefficients);
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
  Run(object_copy.data(), samples_copy.data(), zero, coefficients);
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
    if (offset != 76 && offset != 80 && Be32(object + offset) != Be32(object_copy.data() + offset))
      report(FieldName(offset), offset, Be32(object + offset), Be32(object_copy.data() + offset));
  for (uint32_t offset : {100u, 101u})
    if (object[offset] != object_copy[offset]) report("reset-flag", offset, object[offset], object_copy[offset]);
  const uint8_t* real = REX_RAW_ADDR(samples);
  for (uint32_t i = 0; i < 256; ++i)
    if (Be32(real + 4 * i) != Be32(samples_copy.data() + 4 * i))
      report("sample", i, Be32(real + 4 * i), Be32(samples_copy.data() + 4 * i));
  v.mismatched_calls += mismatch;
  if (v.calls % 1000 == 0)
    REXLOG_INFO("gta4-audio-filter-verify: calls={} mismatched-calls={}", v.calls, v.mismatched_calls);
}

namespace {
VerifyCounters biquad_counters;  // the mixer thread only
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
  const uint32_t mask = object[74] & ((1u << std::min<uint32_t>(channels, 8)) - 1);
  const uint32_t enabled = uint32_t(__builtin_popcount(mask));
  uint32_t arrays[4];
  bool ok = Contiguous(sample_base, std::max<uint32_t>(channels, 1) * kSampleBytes);
  for (int i = 0; i < 4; ++i) {
    arrays[i] = gta4::audio::LoadBe32(object + 32 + 4 * i);
    ok = ok && Contiguous(arrays[i], std::max<uint32_t>(enabled, 1) * 4);
  }
  if (!ok) {
    __imp__sub_82936CE0(ctx, base);
    return;
  }
  const uint32_t zero_bits = REX_LOAD_U32(0x82000A34);  // the constant the original loads into f2
  float zero;
  std::memcpy(&zero, &zero_bits, 4);
  ctx.fpscr.disableFlushMode();
  if (!verify) {
    gta4::audio::RunBiquadEffect(object, channels, zero,
        [&](int i, uint32_t k) { return REX_RAW_ADDR(arrays[i] + 4 * k); },
        [&](uint32_t channel) { return REX_RAW_ADDR(sample_base + channel * kSampleBytes); });
    ctx.r3.u64 = 0;
    return;
  }
  // Verify: copies of what the effect writes (the enabled channels' samples and state).
  std::array<uint8_t, 8 * kSampleBytes> samples_copy;
  std::array<uint8_t, 4 * 8 * 4> state_copy;
  const uint32_t sample_bytes = std::min<uint32_t>(channels, 8) * kSampleBytes;
  std::memcpy(samples_copy.data(), REX_RAW_ADDR(sample_base), sample_bytes);
  for (int i = 0; i < 4; ++i) std::memcpy(state_copy.data() + i * 32, REX_RAW_ADDR(arrays[i]), enabled * 4);
  __imp__sub_82936CE0(ctx, base);
  const uint64_t result = ctx.r3.u64;
  ctx.fpscr.disableFlushMode();
  gta4::audio::RunBiquadEffect(object, channels, zero,
      [&](int i, uint32_t k) { return state_copy.data() + i * 32 + 4 * k; },
      [&](uint32_t channel) { return samples_copy.data() + channel * kSampleBytes; });
  ctx.r3.u64 = result;
  auto& v = biquad_counters;
  ++v.calls;
  bool mismatch = false;
  const auto report = [&](const char* what, uint32_t index, uint32_t original, uint32_t native) {
    mismatch = true;
    if (v.logged++ < 5)
      REXLOG_WARN("gta4-audio-biquad-verify: mismatch call={} {} index={} original={:08X} native={:08X}",
                  v.calls, what, index, original, native);
  };
  const uint8_t* real = REX_RAW_ADDR(sample_base);
  for (uint32_t i = 0; i < sample_bytes / 4; ++i)
    if (Be32(real + 4 * i) != Be32(samples_copy.data() + 4 * i))
      report("sample", i, Be32(real + 4 * i), Be32(samples_copy.data() + 4 * i));
  for (int a = 0; a < 4; ++a)
    for (uint32_t k = 0; k < enabled; ++k) {
      const uint32_t original = REX_LOAD_U32(arrays[a] + 4 * k), native = Be32(state_copy.data() + a * 32 + 4 * k);
      if (original != native) report("state", uint32_t(a) * 8 + k, original, native);
    }
  v.mismatched_calls += mismatch;
  if (v.calls % 1000 == 0)
    REXLOG_INFO("gta4-audio-biquad-verify: calls={} mismatched-calls={}", v.calls, v.mismatched_calls);
}
