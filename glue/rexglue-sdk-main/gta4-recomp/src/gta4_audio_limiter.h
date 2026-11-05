#pragma once

// sub_82934F00 (audio mixer thread): the limiter effect, between its profiling-timer calls
// (sub_8286A2E8 / sub_8286A308, which the hook still makes). Two modes (+652):
//  - lookahead: per enabled channel, the peak of the last 20 input samples (|x|, the previous
//    call's last 20 kept at +12 + 80 * channel) drives an envelope (attack +644, release +648),
//    the gain above the threshold pulls it down to +608, and the output is the input delayed by
//    20 samples times that gain times +612; written through the shared scratch block, as the
//    original does;
//  - curve: per enabled channel but channel 3, 4 samples at a time, a peak envelope (+604, +600),
//    a vector power curve (log2, exponent +596, exp2, scale +616, floor) and a smoothed gain
//    (attack +588, release +592) dividing +612.
// Every operation is the generated code's (double registers rounded to float as it rounds them,
// fsel as `>= 0.0 ?`, the same simde vector primitives in the same lane order, flush-to-zero on
// for vector arithmetic and off for scalar), so it is bit-exact by construction;
// gta4-audio-limiter-test checks it against the generated original.
//
// Include after gta4_init.h.

#include <bit>
#include <cmath>
#include <cstdint>
#include <cstring>
#include "gta4_audio_reverb.h"

namespace gta4::audio {

inline constexpr uint32_t kLimiterScratch = 0x831CC480;    // r26: 1024 bytes, shared
inline constexpr uint32_t kLimiterTimer = 0x831CC888;      // r22: sub_8286A2E8 / sub_8286A308
inline constexpr uint32_t kLimiterTimerCount = 0x831CC880;
inline constexpr uint32_t kLimiterThreshold = 0x8200BA9C;  // f29
inline constexpr uint32_t kLimiterOne = 0x82000D48;        // f31, and the curve's floor
inline constexpr uint32_t kLimiterCurveMinimum = 0x820A13EC;

struct GuestFloat {
  // lfs: the float widened to double (with flush-to-zero off, as every caller here has it).
  static double Load(uint8_t* base, uint32_t address) {
    PPCRegister temp{};
    temp.u32 = REX_LOAD_U32(address);
    return double(temp.f32);
  }
  static void Store(uint8_t* base, uint32_t address, double value) {
    PPCRegister temp{};
    temp.f32 = float(value);
    REX_STORE_U32(address, temp.u32);
  }
  static double Abs(double v) { return std::bit_cast<double>(std::bit_cast<uint64_t>(v) & ~0x8000000000000000ull); }
  static double Round(double v) { return double(float(v)); }
  // fsub + fsel: the larger of `a` and |`b`| as the original's peak search keeps it.
  static double Max(double a, double b_abs) { return Round(a - b_abs) >= 0.0 ? a : b_abs; }
};

inline void RunLimiterLookahead(PPCContext& ctx, uint8_t* base, uint32_t self, uint32_t channels, uint32_t samples) {
  using F = GuestFloat;
  ctx.fpscr.disableFlushMode();
  const double f28 = F::Load(base, self + 644), f27 = F::Load(base, self + 648), f30 = F::Load(base, self + 608);
  if (!channels) return;
  const double f29 = F::Load(base, kLimiterThreshold), f31 = F::Load(base, kLimiterOne);
  const uint32_t mask = REX_LOAD_U8(self + 658);
  for (uint32_t channel = 0; channel < channels; ++channel) {
    if (!ChannelEnabled(mask, channel)) continue;
    const uint32_t r29 = 20 * channel, r28 = self + 492 + 4 * channel, r25 = self + 12 + 80 * channel;
    const uint32_t r30 = 1024 * channel + samples, r4 = kLimiterScratch - r30;
    double f11 = F::Load(base, r28), f0 = 0;
    uint32_t r6 = r30;
    int32_t r5 = 20;
    for (uint32_t n = 0; n < 256; ++n, --r5, r6 += 4) {
      const double f10 = n < 20 ? F::Load(base, (n + r29 + 3) * 4 + self) : F::Load(base, r6 - 80);
      f0 = F::Abs(F::Load(base, r6));
      uint32_t r11 = 0, r7 = n;
      const double f12 = F::Round(f0 - f11) >= 0.0 ? f28 : f27;
      // The peak of the 20-sample window: history entries, then this block's samples.
      if (r5 >= 4) {
        const uint32_t groups = ((16 - n) >> 2) + 1;
        uint32_t r9 = (n + r29 + 4) * 4 + self;
        r11 = groups * 4;
        r7 = r11 + n;
        for (uint32_t g = 0; g < groups; ++g, r9 += 16) {
          const double h0 = F::Abs(F::Load(base, r9 - 4)), h1 = F::Load(base, r9), h2 = F::Load(base, r9 + 4),
                       h3 = F::Load(base, r9 + 8);
          f0 = F::Max(f0, h0); f0 = F::Max(f0, F::Abs(h1)); f0 = F::Max(f0, F::Abs(h2)); f0 = F::Max(f0, F::Abs(h3));
        }
      }
      if (r7 < 20) {
        uint32_t r8 = (r7 + r29 + 3) * 4 + self;
        const uint32_t count = 20 - r7;
        r11 += count;
        for (uint32_t i = 0; i < count; ++i, r8 += 4) f0 = F::Max(f0, F::Abs(F::Load(base, r8)));
      }
      if (int32_t(20 - r11) >= 4) {
        const uint32_t groups = ((16 - r11) >> 2) + 1;
        uint32_t r9 = (r11 + n - 19) * 4 + r30;
        r11 += groups * 4;
        for (uint32_t g = 0; g < groups; ++g, r9 += 16) {
          const double h0 = F::Abs(F::Load(base, r9 - 4)), h1 = F::Load(base, r9), h2 = F::Load(base, r9 + 4),
                       h3 = F::Load(base, r9 + 8);
          f0 = F::Max(f0, h0); f0 = F::Max(f0, F::Abs(h1)); f0 = F::Max(f0, F::Abs(h2)); f0 = F::Max(f0, F::Abs(h3));
        }
      }
      if (r11 < 20) {
        uint32_t r9 = (r11 + n - 20) * 4 + r30;
        const uint32_t count = 20 - r11;
        for (uint32_t i = 0; i < count; ++i, r9 += 4) f0 = F::Max(f0, F::Abs(F::Load(base, r9)));
      }
      // Envelope and gain.
      const double f13 = F::Round(f31 - f12);
      const double f9 = F::Load(base, self + 612);
      f0 = F::Round(f0 * f12);
      f0 = F::Round(std::fma(f13, f11, f0));
      double gain = F::Round(f0 - f29);
      const double below = F::Round(f30 - f0);
      f11 = f0;
      gain = gain >= 0.0 ? f0 : f31;
      gain = F::Round(f30 / gain);
      const double f8 = F::Round(f31 - gain);
      gain = f8 >= 0.0 ? gain : f31;
      gain = below >= 0.0 ? f31 : gain;
      gain = F::Round(gain * f9);
      gain = F::Round(gain * f10);
      F::Store(base, r4 + r6, gain);
    }
    F::Store(base, r28, f0);
    // sub_82A11940 (memcpy): the last 20 inputs become the history; the block takes the output.
    std::memcpy(REX_RAW_ADDR(r25), REX_RAW_ADDR(r30 + 944), 80);
    std::memcpy(REX_RAW_ADDR(r30), REX_RAW_ADDR(kLimiterScratch), 1024);
  }
}

inline void RunLimiterCurve(PPCContext& ctx, uint8_t* base, uint32_t self, uint32_t channels, uint32_t samples) {
  using F = GuestFloat;
  using V = GuestVec;
  ctx.fpscr.disableFlushMode();
  PPCRegister temp{};
  temp.u32 = REX_LOAD_U32(kLimiterCurveMinimum);
  temp.f32 = float(double(temp.f32));
  const uint32_t minimum = temp.u32;
  temp.u32 = REX_LOAD_U32(kLimiterOne);
  temp.f32 = float(double(temp.f32));
  const uint32_t one = temp.u32;
  const simde__m128 v12 = simde_mm_castsi128_ps(V::Splat0(V::LoadLeft(base, self + 596)));
  const simde__m128 v1 = simde_mm_castsi128_ps(V::Splat0(V::LoadLeft(base, self + 616)));
  if (!channels) return;
  const simde__m128 v3 = simde_mm_castsi128_ps(V::FromWords(minimum, minimum, minimum, minimum));
  const simde__m128 v2 = simde_mm_castsi128_ps(V::FromWords(one, one, one, one));
  const uint32_t mask = REX_LOAD_U8(self + 658);
  for (uint32_t channel = 0; channel < channels; ++channel) {
    if (!ChannelEnabled(mask, channel) || channel == 3) continue;
    uint32_t r10 = 1024 * channel + samples;
    const uint32_t r11 = self + 540 + 4 * channel;
    // Loop invariants of the power curve (exponent v12): integer/odd exponent masks, sign bits.
    ctx.fpscr.enableFlushMode();
    simde__m128i v9 = rex::ppc::simde_mm_vctsxs(v12);
    const simde__m128i v13m = simde_mm_set1_epi32(int(0xFFFFFFFF));
    simde__m128 v8f = simde_mm_round_ps(v12, SIMDE_MM_FROUND_TO_ZERO | SIMDE_MM_FROUND_NO_EXC);
    const simde__m128i v11one = simde_mm_set1_epi32(int(0x1));
    const simde__m128i v0 = simde_mm_set1_epi32(int(0x0));
    simde__m128i v10 = simde_mm_set1_epi32(int(0xFFFFFFF7));
    PPCVRegister v0r{}, vTemp{}, v10r{}, v11r{}, v4r{};
    simde_mm_store_si128((simde__m128i*)v0r.u8, v0);
    temp.f32 = 3.0f; temp.s32 += v0r.s16[1]; vTemp.f32[3] = temp.f32;
    temp.f32 = 3.0f; temp.s32 += v0r.s16[0]; vTemp.f32[2] = temp.f32;
    vTemp.f32[1] = 0.0f; vTemp.f32[0] = 1.0f;
    v10 = simde_mm_sllv_epi32(v13m, simde_mm_and_si128(v10, simde_mm_set1_epi32(0x1F)));
    const simde__m128i v6 = simde_mm_shuffle_epi32(simde_mm_load_si128((simde__m128i*)vTemp.u32), 0x0);
    simde_mm_store_si128((simde__m128i*)v10r.u8, v10);
    simde_mm_store_si128((simde__m128i*)v11r.u8, v11one);
    for (int i = 0; i < 4; ++i) v4r.u32[i] = v10r.u32[i] >> (v11r.u8[4 * i] & 0x1F);
    const simde__m128i v4 = simde_mm_load_si128((simde__m128i*)v4r.u8);
    v9 = simde_mm_and_si128(v9, v11one);
    const simde__m128i v7 = simde_mm_castps_si128(simde_mm_cmpeq_ps(v12, v8f));
    const simde__m128i v8 = simde_mm_sllv_epi32(v13m, simde_mm_and_si128(v13m, simde_mm_set1_epi32(0x1F)));
    const simde__m128i v5 = simde_mm_sllv_epi32(v9, simde_mm_and_si128(v13m, simde_mm_set1_epi32(0x1F)));
    // Recomputed at the top of every iteration in the original, from invariants only.
    const simde__m128i v11eq = simde_mm_castps_si128(simde_mm_cmpeq_ps(v12, simde_mm_castsi128_ps(v0)));
    const simde__m128i v30gt = simde_mm_castps_si128(simde_mm_cmpgt_ps(simde_mm_castsi128_ps(v0), v12));
    for (uint32_t r9 = 64; r9 != 0; --r9, r10 += 16) {
      ctx.fpscr.disableFlushMode();
      // Peak envelope over the 4 samples (stored after each, as the original does).
      double env[4];
      double f0 = F::Abs(F::Load(base, r10));
      double f12 = F::Load(base, self + 604), f13 = F::Load(base, r11 - 24), f11 = F::Load(base, self + 600);
      f0 = F::Round(std::fma(f13, f12, f0));
      f0 = F::Round(f0 * f11);
      F::Store(base, r11 - 24, f0);
      for (uint32_t k = 1; k < 4; ++k) {
        f13 = F::Abs(F::Load(base, r10 + 4 * k));
        f12 = F::Load(base, self + 604);
        env[k - 1] = f0;
        f11 = F::Load(base, self + 600);
        f0 = F::Round(std::fma(f12, f0, f13));
        f0 = F::Round(f0 * f11);
        if (k < 3) F::Store(base, r11 - 24, f0);
      }
      const double held = F::Load(base, r11 + 0);
      env[3] = f0;
      F::Store(base, r11 - 24, f0);
      const double attack = F::Load(base, self + 592);
      double smooth = F::Load(base, r11 + 24);
      const double release = F::Load(base, self + 588);
      const double scale = F::Load(base, self + 612);
      const double x0 = F::Load(base, r10);
      uint32_t env_bits[4];
      for (int k = 0; k < 4; ++k) { temp.f32 = float(env[k]); env_bits[k] = temp.u32; }
      simde__m128 v13 = simde_mm_castsi128_ps(V::FromWords(env_bits[0], env_bits[1], env_bits[2], env_bits[3]));
      // The power curve.
      ctx.fpscr.enableFlushMode();
      v13 = simde_mm_max_ps(v13, v3);
      simde__m128i v9e = simde_mm_castps_si128(simde_mm_cmpeq_ps(v13, simde_mm_castsi128_ps(v0)));
      simde__m128i v10s = simde_mm_and_si128(simde_mm_castps_si128(v13), v8);
      simde__m128i v29 = simde_mm_castps_si128(simde_mm_cmpgt_ps(simde_mm_castsi128_ps(v0), v13));
      v13 = simde_mm_castsi128_ps(simde_mm_andnot_si128(v8, simde_mm_castps_si128(v13)));
      v10s = simde_mm_and_si128(v10s, v5);
      {
        alignas(16) float lanes[4];
        simde_mm_store_ps(lanes, v13);
        for (float& lane : lanes) lane = log2f(lane);
        v13 = simde_mm_load_ps(lanes);
      }
      simde__m128i v28 = simde_mm_or_si128(v9e, v11eq);
      v29 = simde_mm_andnot_si128(v7, v29);
      v9e = simde_mm_andnot_si128(v30gt, v9e);
      v13 = simde_mm_mul_ps(v13, v12);
      const simde__m128i v30 = simde_mm_or_si128(v29, v28);
      v28 = simde_mm_or_si128(v0, v10s);
      v9e = simde_mm_or_si128(simde_mm_andnot_si128(v9e, v4), simde_mm_and_si128(v9e, v28));
      const simde__m128i v11 = simde_mm_or_si128(simde_mm_andnot_si128(v11eq, v9e), simde_mm_and_si128(v11eq, v6));
      {
        simde__m128 x = v13;
        simde__m128 xc = simde_mm_min_ps(simde_mm_set1_ps(127.99999f), simde_mm_max_ps(simde_mm_set1_ps(-126.0f), x));
        simde__m128 n = simde_mm_round_ps(xc, SIMDE_MM_FROUND_TO_NEG_INF | SIMDE_MM_FROUND_NO_EXC);
        simde__m128 f = simde_mm_sub_ps(xc, n);
        simde__m128 p = simde_mm_set1_ps(1.8775767e-3f);
        p = simde_mm_add_ps(simde_mm_mul_ps(p, f), simde_mm_set1_ps(8.9893397e-3f));
        p = simde_mm_add_ps(simde_mm_mul_ps(p, f), simde_mm_set1_ps(5.5826318e-2f));
        p = simde_mm_add_ps(simde_mm_mul_ps(p, f), simde_mm_set1_ps(2.4015361e-1f));
        p = simde_mm_add_ps(simde_mm_mul_ps(p, f), simde_mm_set1_ps(6.9315308e-1f));
        p = simde_mm_add_ps(simde_mm_mul_ps(p, f), simde_mm_set1_ps(1.0f));
        simde__m128i exp_bits = simde_mm_slli_epi32(simde_mm_add_epi32(simde_mm_cvttps_epi32(n), simde_mm_set1_epi32(127)), 23);
        simde__m128 r = simde_mm_mul_ps(p, simde_mm_castsi128_ps(exp_bits));
        r = simde_mm_blendv_ps(r, simde_mm_setzero_ps(), simde_mm_cmplt_ps(x, simde_mm_set1_ps(-126.0f)));
        r = simde_mm_blendv_ps(r, simde_mm_castsi128_ps(simde_mm_set1_epi32(0x7F800000)), simde_mm_cmpge_ps(x, simde_mm_set1_ps(128.0f)));
        v13 = r;
      }
      v13 = simde_mm_castsi128_ps(simde_mm_or_si128(simde_mm_castps_si128(v13), v10s));
      v13 = simde_mm_castsi128_ps(simde_mm_or_si128(simde_mm_andnot_si128(v30, simde_mm_castps_si128(v13)),
                                                    simde_mm_and_si128(v30, v11)));
      v13 = simde_mm_mul_ps(v13, v1);
      v13 = simde_mm_max_ps(v13, v2);
      alignas(16) uint8_t stored[16];
      simde_mm_store_si128((simde__m128i*)stored, simde_mm_shuffle_epi8(simde_mm_castps_si128(v13),
                                                                         simde_mm_load_si128((simde__m128i*)rex::ppc::VectorMaskL)));
      ctx.fpscr.disableFlushMode();
      double g[4];
      for (int k = 0; k < 4; ++k) {
        uint32_t word;
        std::memcpy(&word, stored + 4 * k, 4);
        temp.u32 = __builtin_bswap32(word);
        g[k] = double(temp.f32);
      }
      // The smoothed gain and the output, sample by sample.
      const double f5 = F::Round(g[0] - held), f4 = F::Round(g[0] - smooth);
      const double f3 = F::Round(g[1] - g[0]), f2 = F::Round(g[2] - g[1]), f1 = F::Round(g[3] - g[2]);
      double coefficient = f5 >= 0.0 ? release : attack;
      smooth = F::Round(std::fma(coefficient, f4, smooth));
      double next = F::Round(g[1] - smooth);
      F::Store(base, r10, F::Round(F::Round(scale / smooth) * x0));
      F::Store(base, r11 + 0, g[0]);
      F::Store(base, r11 + 24, smooth);
      const double steps[3] = {f3, f2, f1};
      for (int k = 1; k < 4; ++k) {
        const double a = F::Load(base, self + 592), r = F::Load(base, self + 588);
        coefficient = steps[k - 1] >= 0.0 ? r : a;
        const double s = F::Load(base, self + 612);
        const double x = F::Load(base, r10 + 4 * k);
        smooth = F::Round(std::fma(coefficient, next, smooth));
        const double out = F::Round(s / smooth);
        if (k < 3) next = F::Round(g[k + 1] - smooth);
        F::Store(base, r10 + 4 * k, F::Round(out * x));
        if (k < 3) { F::Store(base, r11 + 24, smooth); F::Store(base, r11 + 0, g[k]); }
        else { F::Store(base, r11 + 0, g[k]); F::Store(base, r11 + 24, smooth); }
      }
    }
  }
}

// The DSP of sub_82934F00 between its timer calls.
inline void RunLimiter(PPCContext& ctx, uint8_t* base, uint32_t self, uint32_t channels, uint32_t samples) {
  if (REX_LOAD_U8(self + 652)) RunLimiterLookahead(ctx, base, self, channels, samples);
  else RunLimiterCurve(ctx, base, self, channels, samples);
}

// The whole of sub_82934F00 after sub_8218FB98: the original's frame (its callees run below it),
// its profiling timer around the DSP, and the timer's call counter, as the original does them.
inline void RunLimiterTimed(PPCContext& ctx, uint8_t* base, uint32_t self, uint32_t channels, uint32_t samples) {
  const uint32_t caller_stack = ctx.r1.u32, frame = caller_stack - 272;
  REX_STORE_U32(frame, caller_stack);
  ctx.r1.u64 = frame;
  ctx.r3.u64 = kLimiterTimer;
  ctx.lr = 0x82934F34;
  sub_8286A2E8(ctx, base);
  RunLimiter(ctx, base, self, channels, samples);
  ctx.r3.u64 = kLimiterTimer;
  ctx.lr = 0x829354F0;
  sub_8286A308(ctx, base);
  const uint32_t count = REX_LOAD_U32(kLimiterTimerCount) + 1;
  REX_STORE_U32(kLimiterTimerCount, count);
  if (count == 1) {
    ctx.r3.u64 = kLimiterTimer;
    ctx.lr = 0x82935510;
    sub_8286A338(ctx, base);
    REX_STORE_U32(kLimiterTimerCount, 0);
  }
  ctx.r1.u64 = caller_stack;
  ctx.r3.u64 = 0;
}

}  // namespace gta4::audio
