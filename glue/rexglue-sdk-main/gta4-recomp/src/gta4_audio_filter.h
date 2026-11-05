#pragma once

#include <cmath>
#include <cstdint>

namespace gta4::audio {

// sub_829321A0 (audio mixer thread): a 4th-order filter effect, two identical transposed
// direct-form-II biquad sections in series, for each of two slots (A: active below 23900 Hz,
// B: active when its frequency is non-zero), run in place over 256 floats.
// Coefficients c0..c4 = b0, b1, b2, a1, a2; state s0, s1 (first section), s2, s3 (second).
// Every operation rounds as the generated code does: single-precision values, fused multiply-
// adds evaluated in double and rounded once to float, products and sums rounded to float.
struct FilterSlot {
  float c[5];
  float s[4];
};

#if defined(__clang__)
#pragma clang fp contract(off)
#endif
inline float FilterFma(float a, float b, float c) { return float(std::fma(double(a), double(b), double(c))); }
inline float FilterFms(float a, float b, float c) { return float(std::fma(double(a), double(b), -double(c))); }
// A product or sum of two floats evaluated in double and rounded to float equals the float
// operation (double rounding is innocuous for +, -, *, / when 53 >= 2*24 + 2), so these skip
// the conversions that sat on the recurrence's critical path. The fused forms above keep double:
// the generated code rounds their exact result to double first, then to float.
inline float FilterMul(float a, float b) { return a * b; }
inline float FilterAdd(float a, float b) { return a + b; }

inline float FilterStep(float x, const float (&c)[5], float (&s)[4]) {
  const float y = FilterFma(x, c[0], s[0]);
  const float z = FilterFma(y, c[0], s[2]);
  const float s0 = FilterAdd(FilterFms(x, c[1], FilterMul(y, c[3])), s[1]);
  const float s1 = FilterFms(x, c[2], FilterMul(y, c[4]));
  const float s2 = FilterAdd(FilterFms(y, c[1], FilterMul(z, c[3])), s[3]);
  const float s3 = FilterFms(y, c[2], FilterMul(z, c[4]));
  s[0] = s0; s[1] = s1; s[2] = s2; s[3] = s3;
  return z;
}

// `samples` are 256 big-endian floats in guest memory.
inline void Filter256(uint8_t* samples, FilterSlot& a, bool use_a, FilterSlot& b, bool use_b) {
  for (uint32_t i = 0; i < 256; ++i) {
    uint8_t* p = samples + i * 4;
    const uint32_t raw = uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | p[3];
    float x;
    __builtin_memcpy(&x, &raw, 4);
    if (use_a) x = FilterStep(x, a.c, a.s);
    if (use_b) x = FilterStep(x, b.c, b.s);
    uint32_t out;
    __builtin_memcpy(&out, &x, 4);
    p[0] = uint8_t(out >> 24); p[1] = uint8_t(out >> 16); p[2] = uint8_t(out >> 8); p[3] = uint8_t(out);
  }
}

// The state the generated code writes back: a zero exponent (zero or denormal) becomes `zero`.
inline float FlushDenormal(float v, float zero) {
  uint32_t bits;
  __builtin_memcpy(&bits, &v, 4);
  return (bits & 0x7F800000u) ? v : zero;
}

inline uint32_t LoadBe32(const uint8_t* p) {
  return uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | p[3];
}
inline void StoreBe32(uint8_t* p, uint32_t v) {
  p[0] = uint8_t(v >> 24); p[1] = uint8_t(v >> 16); p[2] = uint8_t(v >> 8); p[3] = uint8_t(v);
}
inline float LoadBeFloat(const uint8_t* p) { const uint32_t b = LoadBe32(p); float f; __builtin_memcpy(&f, &b, 4); return f; }
inline void StoreBeFloat(uint8_t* p, float f) { uint32_t b; __builtin_memcpy(&b, &f, 4); StoreBe32(p, b); }

// sub_82936CE0 (audio mixer thread): per-channel EQ effect. One channel's 256 floats in place:
// a biquad section (the same section as FilterStep's first), or two in series when `cascade`,
// then the gain. The coefficients are shared by the channels; each channel has its own state.
inline void Biquad256(uint8_t* samples, const float (&c)[5], float (&s)[4], bool cascade, float gain) {
  for (uint32_t i = 0; i < 256; ++i) {
    uint8_t* p = samples + i * 4;
    const float x = LoadBeFloat(p);
    float out;
    if (cascade) {
      out = FilterStep(x, c, s);
    } else {
      const float y = FilterFma(x, c[0], s[0]);
      const float s0 = FilterAdd(FilterFms(x, c[1], FilterMul(y, c[3])), s[1]);
      const float s1 = FilterFms(x, c[2], FilterMul(y, c[4]));
      s[0] = s0; s[1] = s1;
      out = y;
    }
    StoreBeFloat(p, FilterMul(out, gain));
  }
}

// The whole of sub_82936CE0 on host views. Object (r3): +12..+28 coefficients b0 b1 b2 a1 a2,
// +32/+36/+40/+44 guest pointers to the s0..s3 arrays (one float per enabled channel, in channel
// order), +60 gain, +68 bypass, +74 channel-enable mask, +75 two sections. The voice buffer
// (r4, through sub_8218FB98) gives the channel count at +13 and the samples at +20, 1024 bytes a
// channel. `state(i, k)` maps state array i's entry k to host memory; `samples(channel)` the same
// for a channel's block. Returns the number of channels run.
template <class State, class Samples>
uint32_t RunBiquadEffect(const uint8_t* object, uint32_t channels, float zero, State&& state, Samples&& samples) {
  if (object[68] || !channels) return 0;
  float c[5];
  for (int i = 0; i < 5; ++i) c[i] = LoadBeFloat(object + 12 + 4 * i);
  const uint32_t mask = object[74];
  const bool cascade = object[75] != 0;
  const float gain = LoadBeFloat(object + 60);
  uint32_t k = 0;
  for (uint32_t channel = 0; channel < channels && channel < 8; ++channel) {
    if (!(mask & (1u << channel))) continue;
    float s[4];
    for (int i = 0; i < 4; ++i) s[i] = LoadBeFloat(state(i, k));
    Biquad256(samples(channel), c, s, cascade, gain);
    for (int i = 0; i < 4; ++i) StoreBeFloat(state(i, k), FlushDenormal(s[i], zero));
    ++k;
  }
  return k;
}

}  // namespace gta4::audio
