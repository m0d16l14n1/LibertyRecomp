// sub_82936CE0 (the audio mixer's per-channel EQ): the native port (gta4::audio::RunBiquadEffect)
// against the generated original, both on the same fake guest memory, bit for bit: samples of
// every channel, the four state arrays, over random coefficients, states (zeros, denormals),
// samples, gains, channel masks, channel counts, one or two sections, bypass, flush constants.
#include "gta4_audio_filter.h"
#include "gta4_init.h"
#include <sys/mman.h>
#include <cstdio>
#include <cstring>
#include <random>
#include <vector>

extern "C" void __imp__sub_82936CE0(PPCContext& __restrict ctx, uint8_t* base);

namespace {
constexpr uint32_t kObject = 0x40001000, kBuffer = 0x40002000, kSamples = 0x40010000, kState = 0x40020000;
constexpr uint32_t kStack = 0x70000000, kZero = 0x82000A34;
uint8_t* base = nullptr;
uint8_t* At(uint32_t a) { return base + a; }
void Put32(uint32_t a, uint32_t v) { gta4::audio::StoreBe32(At(a), v); }
void PutF(uint32_t a, float f) { gta4::audio::StoreBeFloat(At(a), f); }

struct Case {
  float c[5], gain, zero;
  uint8_t mask, cascade, bypass, channels;
};
float RandomSample(std::mt19937& rng) {
  std::uniform_real_distribution<float> u(-1.0f, 1.0f);
  switch (rng() % 16) {
    case 0: return 0.0f;
    case 1: return std::ldexp(u(rng), -130);  // denormal
    case 2: return u(rng) * 32768.0f;
    default: return u(rng);
  }
}
}  // namespace

int main() {
  void* memory = mmap(nullptr, 0x100000000ull + 0x2000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
  if (memory == MAP_FAILED) { std::fprintf(stderr, "audio biquad: no guest memory\n"); return 1; }
  base = static_cast<uint8_t*>(memory);
  std::mt19937 rng(0x82936CE0u);
  std::uniform_real_distribution<float> u(-1.0f, 1.0f);
  constexpr uint32_t kChannelsMax = 10, kSampleBytes = kChannelsMax * 1024, kStateBytes = 4 * 64;
  uint64_t checks = 0, runs = 0, samples_run = 0;
  for (int iteration = 0; iteration < 4000; ++iteration) {
    Case t{};
    // Coefficients of a stable section most of the time; occasionally anything.
    for (float& v : t.c) v = u(rng);
    if (rng() % 8) { t.c[3] = u(rng) * 1.8f; t.c[4] = std::fabs(u(rng)) * 0.9f; }
    t.gain = rng() % 8 ? u(rng) * 2.0f : 1.0f;
    t.zero = rng() % 2 ? 0.0f : 1e-30f;
    t.mask = uint8_t(rng());
    t.cascade = rng() % 2;
    t.bypass = rng() % 16 == 0;
    t.channels = uint8_t(rng() % (kChannelsMax + 1));
    // Object.
    std::memset(At(kObject), 0, 76);
    for (int i = 0; i < 5; ++i) PutF(kObject + 12 + 4 * i, t.c[i]);
    for (int i = 0; i < 4; ++i) Put32(kObject + 32 + 4 * i, kState + 64 * i);
    PutF(kObject + 60, t.gain);
    At(kObject)[68] = t.bypass; At(kObject)[74] = t.mask; At(kObject)[75] = t.cascade;
    // Voice buffer (sub_8218FB98 reads +12..+23): channel count at +13, samples at +20.
    std::memset(At(kBuffer), 0, 24);
    At(kBuffer)[13] = t.channels;
    Put32(kBuffer + 20, kSamples);
    PutF(kZero, t.zero);
    for (uint32_t i = 0; i < kSampleBytes / 4; ++i) PutF(kSamples + 4 * i, RandomSample(rng));
    for (uint32_t i = 0; i < kStateBytes / 4; ++i) PutF(kState + 4 * i, rng() % 6 ? u(rng) * 0.5f : RandomSample(rng));
    std::vector<uint8_t> samples_in(At(kSamples), At(kSamples) + kSampleBytes);
    std::vector<uint8_t> state_in(At(kState), At(kState) + kStateBytes);

    PPCContext ctx{};
    ctx.r1.u64 = kStack; ctx.r3.u64 = kObject; ctx.r4.u64 = kBuffer; ctx.lr = 0x82000000;
    ctx.fpscr.disableFlushMode();
    __imp__sub_82936CE0(ctx, base);
    const uint64_t result = ctx.r3.u64;
    std::vector<uint8_t> samples_original(At(kSamples), At(kSamples) + kSampleBytes);
    std::vector<uint8_t> state_original(At(kState), At(kState) + kStateBytes);

    std::memcpy(At(kSamples), samples_in.data(), kSampleBytes);
    std::memcpy(At(kState), state_in.data(), kStateBytes);
    ctx.fpscr.disableFlushMode();
    const uint32_t ran = gta4::audio::RunBiquadEffect(At(kObject), At(kBuffer)[13], t.zero,
        [&](int i, uint32_t k) { return At(gta4::audio::LoadBe32(At(kObject + 32 + 4 * i)) + 4 * k); },
        [&](uint32_t channel) { return At(kSamples + channel * 1024); });
    ++checks;
    if (result != 0) { std::fprintf(stderr, "audio biquad: original returned %llu\n", (unsigned long long)result); return 1; }
    runs += ran != 0; samples_run += ran * 256;
    for (uint32_t i = 0; i < kSampleBytes; i += 4, ++checks)
      if (std::memcmp(At(kSamples) + i, samples_original.data() + i, 4)) {
        std::fprintf(stderr, "audio biquad: FAILED iteration %d sample %u channel %u (cascade %u mask %02X channels %u): "
                     "original %08X native %08X\n", iteration, i / 4 % 256, i / 1024, t.cascade, t.mask, t.channels,
                     gta4::audio::LoadBe32(samples_original.data() + i), gta4::audio::LoadBe32(At(kSamples) + i));
        return 1;
      }
    for (uint32_t i = 0; i < kStateBytes; i += 4, ++checks)
      if (std::memcmp(At(kState) + i, state_original.data() + i, 4)) {
        std::fprintf(stderr, "audio biquad: FAILED iteration %d state array %u entry %u: original %08X native %08X\n",
                     iteration, i / 64, i % 64 / 4, gta4::audio::LoadBe32(state_original.data() + i),
                     gta4::audio::LoadBe32(At(kState) + i));
        return 1;
      }
  }
  std::printf("audio biquad: %llu checks passed (%llu effect runs, %llu channel-samples)\n",
              (unsigned long long)checks, (unsigned long long)runs, (unsigned long long)samples_run);
  return 0;
}
