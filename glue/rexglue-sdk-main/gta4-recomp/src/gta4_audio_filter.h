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
inline float FilterMul(float a, float b) { return float(double(a) * double(b)); }
inline float FilterAdd(float a, float b) { return float(double(a) + double(b)); }

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

}  // namespace gta4::audio
