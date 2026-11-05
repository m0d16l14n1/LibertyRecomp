#pragma once

// sub_82935BD0 (audio mixer thread): the reverb effect, a Freeverb-style network (8 damped comb
// filters in parallel, then 4 allpasses in series) per enabled channel, vectorized over 4
// consecutive samples (every delay is longer than 4). This is the generated code's own sequence of
// VMX operations (the same simde primitives, the same lane order: vectors hold guest elements
// reversed, as lvx/stvx through VectorMaskL leave them), kept in locals instead of the guest
// register file and stack, so it is bit-exact by construction; gta4-audio-effects-test checks it
// against the generated original.
//
// Include after gta4_init.h (guest memory macros, simde, rex::ppc intrinsics).

#include <cstdint>
#include <cstring>
#include "gta4_audio_filter.h"

namespace gta4::audio {

// Image constants the original reads (.rdata, read once per call here).
inline constexpr uint32_t kReverbAllpassGain = 0x82000D74;    // f0 = lfs 3444(0x82000000)
inline constexpr uint32_t kReverbInputGain = 0x820A143C;      // lfs -76(0x820A1488)
inline constexpr uint32_t kReverbCombLengths = 0x820A1468;    // 8 words, -32(0x820A1488)
inline constexpr uint32_t kReverbAllpassLengths = 0x820A1488; // 4 words

struct GuestVec {
  // lvx: the aligned 16 bytes at `address`, guest elements reversed into host lanes.
  static simde__m128i Load(uint8_t* base, uint32_t address) {
    return simde_mm_shuffle_epi8(simde_mm_load_si128((simde__m128i*)REX_RAW_ADDR(address & ~0xFu)),
                                 simde_mm_load_si128((simde__m128i*)rex::ppc::VectorMaskL));
  }
  // lvlx: the bytes from `address` to its 16-byte boundary, left-justified.
  static simde__m128i LoadLeft(uint8_t* base, uint32_t address) {
    return simde_mm_shuffle_epi8(simde_mm_load_si128((simde__m128i*)REX_RAW_ADDR(address & ~0xFu)),
                                 simde_mm_load_si128((simde__m128i*)&rex::ppc::VectorMaskL[(address & 0xF) * 16]));
  }
  static void Store(uint8_t* base, uint32_t address, simde__m128i v) {
    simde_mm_store_si128((simde__m128i*)REX_RAW_ADDR(address & ~0xFu),
                         simde_mm_shuffle_epi8(v, simde_mm_load_si128((simde__m128i*)rex::ppc::VectorMaskL)));
  }
  // lvx of 16 big-endian bytes built on the host (the original builds these on its stack).
  static simde__m128i FromWords(uint32_t w0, uint32_t w1, uint32_t w2, uint32_t w3) {
    alignas(16) uint32_t words[4] = {__builtin_bswap32(w0), __builtin_bswap32(w1), __builtin_bswap32(w2),
                                     __builtin_bswap32(w3)};
    return simde_mm_shuffle_epi8(simde_mm_load_si128((simde__m128i*)words),
                                 simde_mm_load_si128((simde__m128i*)rex::ppc::VectorMaskL));
  }
  static simde__m128i Splat0(simde__m128i v) { return simde_mm_shuffle_epi32(v, 0xFF); }  // vspltw v,0
};

inline uint32_t GuestWord(uint8_t* base, uint32_t address) { return REX_LOAD_U32(address); }

// The whole of sub_82935BD0 after sub_8218FB98 (which gives `channels` and `samples`). Object
// (r3): +8/+16 per-enabled-channel pointers to the 8 comb buffer bases / 8 comb positions (in
// floats), +12 per-enabled-channel pointer to the 8 comb damping states, +20 comb feedback,
// +28 pointer to the damping vector, +36 pointer to the damping dot-product rows, +44/+48
// per-enabled-channel pointers to the 4 allpass buffer bases / positions (in floats), +56 wet,
// +60 dry, +78 channel-enable mask. Leaves the flush mode as the original does.
inline void RunReverb(PPCContext& ctx, uint8_t* base, uint32_t self, uint32_t channels, uint32_t samples) {
  using V = GuestVec;
  // Constants built on the original's stack: lfs/stfs round trips of the image values.
  ctx.fpscr.disableFlushMode();
  PPCRegister temp{};
  temp.u32 = GuestWord(base, kReverbAllpassGain);
  temp.f32 = float(double(temp.f32));
  const uint32_t allpass_gain = temp.u32;
  temp.u32 = GuestWord(base, kReverbInputGain);
  temp.f32 = float(double(temp.f32));
  const uint32_t input_gain = temp.u32;
  const simde__m128i v31 = V::FromWords(allpass_gain, allpass_gain, allpass_gain, allpass_gain);
  const simde__m128i v4 = V::FromWords(input_gain, input_gain, input_gain, input_gain);
  const simde__m128i v3 = V::FromWords(0x00010203, 0x18191A1B, 0, 0);
  const simde__m128i v2 = V::FromWords(0x04050607, 0x1C1D1E1F, 0, 0);
  const simde__m128i v30 = V::Splat0(V::LoadLeft(base, self + 60));
  const simde__m128i v29 = V::Splat0(V::LoadLeft(base, self + 56));
  const simde__m128i v10 = V::Splat0(V::LoadLeft(base, self + 20));
  const uint32_t rows = GuestWord(base, self + 36);
  const simde__m128i v9 = V::Load(base, GuestWord(base, self + 28));
  const simde__m128i v8 = V::LoadLeft(base, rows), v7 = V::LoadLeft(base, rows + 4);
  const simde__m128i v6 = V::LoadLeft(base, rows + 8), v5 = V::LoadLeft(base, rows + 12);
  uint32_t comb_length[8], allpass_length[4];
  for (int k = 0; k < 8; ++k) comb_length[k] = GuestWord(base, kReverbCombLengths + 4 * k);
  for (int k = 0; k < 4; ++k) allpass_length[k] = GuestWord(base, kReverbAllpassLengths + 4 * k);

  const uint32_t mask = REX_LOAD_U8(self + 78);
  uint32_t enabled = 0;  // r11 / 4
  for (uint32_t channel = 0; channel < channels; ++channel) {
    if (!ChannelEnabled(mask, channel)) continue;
    const uint32_t e4 = enabled * 4;
    const uint32_t block = samples + channel * 1024;
    // Comb states: each damping state splatted (lvlx + vspltw), as the original's stack copies.
    simde__m128i state[8];
    const uint32_t state_floats = GuestWord(base, GuestWord(base, self + 12) + e4);
    for (int k = 0; k < 8; ++k) state[k] = V::Splat0(V::LoadLeft(base, state_floats + 4 * k));
    alignas(16) simde__m128i sums[64];
    for (uint32_t i = 0; i < 64; ++i) {
      simde__m128i v12 = simde_mm_set1_epi32(0);
      const simde__m128i v11 = V::Load(base, block + 16 * i);
      for (uint32_t k = 0; k < 8; ++k) {
        ctx.fpscr.enableFlushMode();
        const simde__m128 v28 = simde_mm_mul_ps(simde_mm_castsi128_ps(v9), simde_mm_castsi128_ps(state[k]));
        const uint32_t positions = GuestWord(base, GuestWord(base, self + 16) + e4);
        const uint32_t buffers = GuestWord(base, GuestWord(base, self + 8) + e4);
        const uint32_t address = (GuestWord(base, positions + 4 * k) << 2) + GuestWord(base, buffers + 4 * k);
        const simde__m128 v0 = simde_mm_castsi128_ps(V::Load(base, address));
        const simde__m128 v13 = simde_mm_dp_ps(simde_mm_castsi128_ps(v8), v0, 0xFF);
        v12 = simde_mm_castps_si128(simde_mm_add_ps(simde_mm_castsi128_ps(v12), v0));
        simde__m128 v27 = simde_mm_dp_ps(simde_mm_castsi128_ps(v6), v0, 0xFF);
        const simde__m128 v26 = simde_mm_dp_ps(simde_mm_castsi128_ps(v7), v0, 0xFF);
        const simde__m128 v25 = simde_mm_dp_ps(simde_mm_castsi128_ps(v5), v0, 0xFF);
        state[k] = simde_mm_castps_si128(v13);
        const simde__m128i p27 = rex::ppc::simde_mm_perm_epi8_(simde_mm_castps_si128(v27), state[k], v2);
        const simde__m128i p0 = rex::ppc::simde_mm_perm_epi8_(simde_mm_castps_si128(v25), simde_mm_castps_si128(v26), v3);
        simde__m128 out = simde_mm_castsi128_ps(simde_mm_unpackhi_epi32(p27, p0));
        out = simde_mm_add_ps(simde_mm_mul_ps(out, simde_mm_castsi128_ps(v10)), v28);
        out = simde_mm_add_ps(simde_mm_mul_ps(simde_mm_castsi128_ps(v11), simde_mm_castsi128_ps(v4)), out);
        V::Store(base, address, simde_mm_castps_si128(out));
        const uint32_t slot = GuestWord(base, GuestWord(base, self + 16) + e4) + 4 * k;
        REX_STORE_U32(slot, (GuestWord(base, slot) + 4) % comb_length[k]);
      }
      sums[i] = v12;
    }
    // The damping states back (lfs/stfs of each stored vector's first guest element).
    ctx.fpscr.disableFlushModeUnconditional();
    const uint32_t state_out = GuestWord(base, GuestWord(base, self + 12) + e4);
    for (int k = 0; k < 8; ++k) {
      alignas(16) uint8_t bytes[16];
      simde_mm_store_si128((simde__m128i*)bytes,
                           simde_mm_shuffle_epi8(state[k], simde_mm_load_si128((simde__m128i*)rex::ppc::VectorMaskL)));
      uint32_t word;
      std::memcpy(&word, bytes, 4);
      temp.u32 = __builtin_bswap32(word);
      temp.f32 = float(double(temp.f32));
      REX_STORE_U32(state_out + 4 * k, temp.u32);
    }
    for (uint32_t i = 0; i < 64; ++i) {
      simde__m128 v0 = simde_mm_castsi128_ps(sums[i]);
      const simde__m128 v12 = simde_mm_castsi128_ps(V::Load(base, block + 16 * i));
      for (uint32_t k = 0; k < 4; ++k) {
        const uint32_t positions = GuestWord(base, GuestWord(base, self + 48) + e4);
        const uint32_t buffers = GuestWord(base, GuestWord(base, self + 44) + e4);
        const uint32_t address = (GuestWord(base, positions + 4 * k) << 2) + GuestWord(base, buffers + 4 * k);
        const simde__m128 v13 = simde_mm_castsi128_ps(V::Load(base, address));
        ctx.fpscr.enableFlushMode();
        const simde__m128 v11 = simde_mm_add_ps(simde_mm_mul_ps(v13, simde_mm_castsi128_ps(v31)), v0);
        v0 = simde_mm_sub_ps(v13, v0);
        V::Store(base, address, simde_mm_castps_si128(v11));
        const uint32_t slot = GuestWord(base, GuestWord(base, self + 48) + e4) + 4 * k;
        REX_STORE_U32(slot, (GuestWord(base, slot) + 4) % allpass_length[k]);
      }
      const simde__m128 dry = simde_mm_mul_ps(v12, simde_mm_castsi128_ps(v30));
      v0 = simde_mm_add_ps(simde_mm_mul_ps(v0, simde_mm_castsi128_ps(v29)), dry);
      V::Store(base, block + 16 * i, simde_mm_castps_si128(v0));
    }
    ++enabled;
  }
}

// The lengths the original divides by (it traps on zero): the port runs only when all are set.
inline bool ReverbLengthsValid(uint8_t* base) {
  for (int k = 0; k < 8; ++k) if (!GuestWord(base, kReverbCombLengths + 4 * k)) return false;
  for (int k = 0; k < 4; ++k) if (!GuestWord(base, kReverbAllpassLengths + 4 * k)) return false;
  return true;
}

}  // namespace gta4::audio
