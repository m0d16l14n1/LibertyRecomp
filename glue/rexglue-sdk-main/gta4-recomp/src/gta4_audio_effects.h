#pragma once

// The native audio mixer effects as the hooks (gta4_audio_filter.cpp) run them on guest memory,
// shared with gta4-audio-effects-test, which runs each against the generated original.
// Include after gta4_init.h.

#include <cstring>
#include "gta4_audio_filter.h"
#include "gta4_audio_limiter.h"
#include "gta4_audio_reverb.h"

namespace gta4::audio {

// The constant the originals flush denormal state to (zero in the shipped image).
inline float ImageZero(uint8_t* base) {
  const uint32_t bits = REX_LOAD_U32(0x82000A34);
  float zero;
  std::memcpy(&zero, &bits, 4);
  return zero;
}

// sub_829321A0 on host views of the object and the samples (guest memory or copies). Object (r3):
// +4 slot A (5 coefficients, 4 state), +40 slot B, +76 slot B frequency, +80 slot A frequency,
// +84/+88 the frequencies the coefficients were made for, +100/+101 "slot was off last call" (its
// state restarts at zero). `coefficients(kind, frequency, out)` runs sub_82932090.
template <class Coefficients>
void RunFilterEffect(uint8_t* object, uint8_t* samples, float zero, Coefficients&& coefficients) {
  const uint32_t frequency_b = LoadBe32(object + 76), frequency_a = LoadBe32(object + 80);
  const bool use_a = frequency_a < 23900, use_b = frequency_b != 0;
  if (!use_a && !use_b) return;
  FilterSlot a{}, b{};
  for (int i = 0; i < 5; ++i) { a.c[i] = LoadBeFloat(object + 4 + 4 * i); b.c[i] = LoadBeFloat(object + 40 + 4 * i); }
  for (int i = 0; i < 4; ++i) { a.s[i] = LoadBeFloat(object + 24 + 4 * i); b.s[i] = LoadBeFloat(object + 60 + 4 * i); }
  if (use_a && object[100]) for (float& v : a.s) v = zero;
  if (use_b && object[101]) for (float& v : b.s) v = zero;
  if (LoadBe32(object + 88) != frequency_a) {
    coefficients(1u, frequency_a, a.c);
    for (int i = 0; i < 5; ++i) StoreBeFloat(object + 4 + 4 * i, a.c[i]);
  }
  if (LoadBe32(object + 84) != frequency_b) {
    coefficients(0u, frequency_b, b.c);
    for (int i = 0; i < 5; ++i) StoreBeFloat(object + 40 + 4 * i, b.c[i]);
  }
  StoreBe32(object + 88, frequency_a);
  StoreBe32(object + 84, frequency_b);
  object[101] = use_b ? 0 : 1;
  object[100] = use_a ? 0 : 1;
  Filter256(samples, a, use_a, b, use_b);
  for (int i = 0; i < 4; ++i) {
    StoreBeFloat(object + 24 + 4 * i, FlushDenormal(a.s[i], zero));
    StoreBeFloat(object + 60 + 4 * i, FlushDenormal(b.s[i], zero));
  }
}

// sub_829321A0's coefficient step: sub_82932090 (r4 = 1 for slot A, 0 for B) writes five
// coefficients to a stack area of the original's frame (r1 - 240, +144 for A, +96 for B).
inline void FilterCoefficients(PPCContext& ctx, uint8_t* base, uint32_t self, uint32_t kind, uint32_t frequency,
                               float (&out)[5]) {
  const uint32_t caller_stack = ctx.r1.u32, frame = caller_stack - 240, area = frame + (kind ? 144 : 96);
  REX_STORE_U32(frame, caller_stack);
  ctx.r1.u64 = frame;
  ctx.r3.u64 = self; ctx.r4.u64 = kind; ctx.r5.u64 = frequency; ctx.r6.u64 = area;
  ctx.lr = kind ? 0x82932294 : 0x829322DC;
  sub_82932090(ctx, base);
  ctx.r1.u64 = caller_stack;
  for (int i = 0; i < 5; ++i) out[i] = LoadBeFloat(REX_RAW_ADDR(area + 4 * i));
  ctx.fpscr.disableFlushMode();
}

inline void RunFilterGuest(PPCContext& ctx, uint8_t* base, uint32_t self, uint32_t samples) {
  ctx.fpscr.disableFlushMode();
  RunFilterEffect(REX_RAW_ADDR(self), REX_RAW_ADDR(samples), ImageZero(base),
                  [&](uint32_t kind, uint32_t frequency, float (&out)[5]) {
                    FilterCoefficients(ctx, base, self, kind, frequency, out);
                  });
}

inline void RunBiquadGuest(PPCContext& ctx, uint8_t* base, uint32_t self, uint32_t channels, uint32_t samples) {
  const uint8_t* object = REX_RAW_ADDR(self);
  uint32_t arrays[4];
  for (int i = 0; i < 4; ++i) arrays[i] = LoadBe32(object + 32 + 4 * i);
  ctx.fpscr.disableFlushMode();
  RunBiquadEffect(object, channels, ImageZero(base),
                  [&](int i, uint32_t k) { return REX_RAW_ADDR(arrays[i] + 4 * k); },
                  [&](uint32_t channel) { return REX_RAW_ADDR(samples + channel * 1024); });
}

}  // namespace gta4::audio
