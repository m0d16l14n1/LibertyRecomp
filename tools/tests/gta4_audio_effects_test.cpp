// The native audio mixer effects against the generated originals, bit for bit, on fake guest
// memory: sub_829321A0 (4th-order filter), sub_82936CE0 (per-channel EQ), sub_82935BD0 (reverb),
// sub_82934F00 (limiter, both modes). Each case lays out a random object and its buffers in an
// arena, runs the original (extracted from the generated code with everything it calls), keeps
// the arena, restores it, runs the port through the same guest wrapper its hook uses, and compares
// the arena, the limiter's shared scratch and timer counter, the return value and the flush mode.
#include "gta4_init.h"
#include "gta4_audio_effects.h"
#include <sys/mman.h>
#include <cmath>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <functional>
#include <random>
#include <string>
#include <vector>

extern "C" void __imp__sub_829321A0(PPCContext& __restrict ctx, uint8_t* base);
extern "C" void __imp__sub_82936CE0(PPCContext& __restrict ctx, uint8_t* base);
extern "C" void __imp__sub_82935BD0(PPCContext& __restrict ctx, uint8_t* base);
extern "C" void __imp__sub_82934F00(PPCContext& __restrict ctx, uint8_t* base);

namespace {
namespace audio = gta4::audio;
constexpr uint32_t kArena = 0x40000000, kStack = 0x70000000, kPage = 0x831CC000;
uint8_t* base = nullptr;
uint32_t arena_top = kArena;
std::mt19937 rng(0x4A0D10u);
uint64_t checks = 0;

uint8_t* At(uint32_t a) { return base + a; }
void Put32(uint32_t a, uint32_t v) { audio::StoreBe32(At(a), v); }
void PutF(uint32_t a, float f) { audio::StoreBeFloat(At(a), f); }
uint32_t Alloc(uint32_t size, uint32_t align = 16, uint32_t skew = 0) {
  arena_top = (arena_top + align - 1) & ~(align - 1);
  const uint32_t a = arena_top + skew;
  arena_top += size + skew;
  std::memset(At(a), 0, size);
  return a;
}
float U(float lo, float hi) { return std::uniform_real_distribution<float>(lo, hi)(rng); }
uint32_t R(uint32_t n) { return n ? uint32_t(rng() % n) : 0; }
float Sample() {
  switch (R(16)) {
    case 0: return 0.0f;
    case 1: return std::ldexp(U(-1, 1), -130);  // denormal
    case 2: return U(-1, 1) * 32768.0f;
    case 3: return -0.0f;
    default: return U(-1, 1);
  }
}
void Samples(uint32_t a, uint32_t count) { for (uint32_t i = 0; i < count; ++i) PutF(a + 4 * i, Sample()); }
// Channels: mostly 0..10, sometimes past 64 (the channel test wraps there).
uint32_t Channels() { return R(12) ? R(11) : 64 + R(9); }
uint32_t Buffer(uint32_t channels, uint32_t& samples) {
  samples = Alloc(std::max<uint32_t>(channels, 1) * 1024);
  Samples(samples, channels * 256);
  const uint32_t buffer = Alloc(24);
  At(buffer)[13] = uint8_t(channels);
  Put32(buffer + 20, samples);
  return buffer;
}

struct Effect {
  const char* name;
  void (*original)(PPCContext&, uint8_t*);
  std::function<void(PPCContext&, uint32_t self, uint32_t buffer)> native;
};

// AUDIO_FILTER_TRACE: the filter's per-sample values around a mismatch (debugging aid).
void TraceFilter(const std::vector<uint8_t>& before, uint32_t self, uint32_t sample_index) {
  const uint8_t* object = At(self);  // coefficients as the run left them
  const uint8_t* object_before = before.data() + (self - kArena);
  audio::FilterSlot a{}, b{};
  for (int i = 0; i < 5; ++i) { a.c[i] = audio::LoadBeFloat(object + 4 + 4 * i); b.c[i] = audio::LoadBeFloat(object + 40 + 4 * i); }
  for (int i = 0; i < 4; ++i) { a.s[i] = audio::LoadBeFloat(object_before + 24 + 4 * i); b.s[i] = audio::LoadBeFloat(object_before + 60 + 4 * i); }
  const bool use_a = audio::LoadBe32(object + 80) < 23900, use_b = audio::LoadBe32(object + 76) != 0;
  const auto bits = [](float f) { uint32_t u; std::memcpy(&u, &f, 4); return u; };
  for (uint32_t i = 0; i <= sample_index; ++i) {
    float x = audio::LoadBeFloat(before.data() + 4 * i);
    const float x0 = x;
    if (use_a) x = audio::FilterStep(x, a.c, a.s);
    const float mid = x;
    if (use_b) x = audio::FilterStep(x, b.c, b.s);
    if (i + 3 >= sample_index)
      std::fprintf(stderr, "  sample %u x=%08X A->%08X B->%08X  A.s=%08X %08X %08X %08X  B.s=%08X %08X %08X %08X\n", i,
                   bits(x0), bits(mid), bits(x), bits(a.s[0]), bits(a.s[1]), bits(a.s[2]), bits(a.s[3]), bits(b.s[0]),
                   bits(b.s[1]), bits(b.s[2]), bits(b.s[3]));
  }
  std::fprintf(stderr, "  A.c=%08X %08X %08X %08X %08X use %d/%d\n", bits(a.c[0]), bits(a.c[1]), bits(a.c[2]), bits(a.c[3]),
               bits(a.c[4]), use_a, use_b);
}

// audio::SameResultWord: equal, or both NaN (counted).
uint64_t nan_matches = 0;
bool SameWord(const uint8_t* a, const uint8_t* b) {
  const uint32_t x = audio::LoadBe32(a), y = audio::LoadBe32(b);
  if (x == y) return true;
  if (!audio::SameResultWord(x, y)) return false;
  ++nan_matches;
  return true;
}

bool RunCase(const Effect& effect, uint32_t self, uint32_t buffer, int index) {
  // Past the arena top too: a stray write there must be restored between the runs and compared.
  const uint32_t size = arena_top - kArena + 0x10000;
  std::vector<uint8_t> before(At(kArena), At(kArena) + size), page_before(At(kPage), At(kPage) + 4096);
  const auto run = [&](auto&& body, uint32_t& csr) {
    PPCContext ctx{};
    ctx.fpscr.csr = ctx.fpscr.getcsr();
    ctx.fpscr.disableFlushModeUnconditional();
    ctx.r1.u64 = kStack; ctx.r3.u64 = self; ctx.r4.u64 = buffer; ctx.lr = 0x82000000;
    body(ctx);
    csr = ctx.fpscr.getcsr() & ctx.fpscr.FlushMask;
    const uint32_t cached = ctx.fpscr.csr & ctx.fpscr.FlushMask;
    ctx.fpscr.disableFlushModeUnconditional();
    if (cached != csr) { std::fprintf(stderr, "%s: flush-mode cache out of step\n", effect.name); return uint64_t(~0ull); }
    return ctx.r3.u64;
  };
  uint32_t csr_original = 0, csr_native = 0;
  const uint64_t r_original = run([&](PPCContext& ctx) { effect.original(ctx, base); }, csr_original);
  std::vector<uint8_t> original(At(kArena), At(kArena) + size), page_original(At(kPage), At(kPage) + 4096);
  std::memcpy(At(kArena), before.data(), size);
  std::memcpy(At(kPage), page_before.data(), 4096);
  const uint64_t r_native = run([&](PPCContext& ctx) {
    effect.native(ctx, self, buffer);
    ctx.r3.u64 = 0;
  }, csr_native);
  ++checks;
  if (r_original != r_native || csr_original != csr_native) {
    std::fprintf(stderr, "%s case %d: result %llx/%llx flush %x/%x\n", effect.name, index,
                 (unsigned long long)r_original, (unsigned long long)r_native, csr_original, csr_native);
    return false;
  }
  for (uint32_t i = 0; i < size; i += 4, ++checks)
    if (!SameWord(original.data() + i, At(kArena + i))) {
      std::fprintf(stderr, "%s case %d: arena %08X (object +%d) original %08X native %08X\n", effect.name, index,
                   kArena + i, int(kArena + i) - int(self), audio::LoadBe32(original.data() + i),
                   audio::LoadBe32(At(kArena + i)));
      if (std::getenv("AUDIO_FILTER_TRACE") && i < 1024) TraceFilter(before, self, i / 4);
      if (std::getenv("AUDIO_EFFECTS_DUMP"))
        for (uint32_t j = (i >= 16 ? i - 16 : 0); j < std::min(size, i + 16); j += 4)
          std::fprintf(stderr, "  %08X before %08X original %08X native %08X\n", kArena + j,
                       audio::LoadBe32(before.data() + j), audio::LoadBe32(original.data() + j),
                       audio::LoadBe32(At(kArena + j)));
      return false;
    }
  // The limiter's scratch and timer page; the timer's timebase words differ between runs.
  for (uint32_t i = 0; i < 4096; i += 4, ++checks) {
    const uint32_t a = kPage + i;
    if (a >= audio::kLimiterTimer + 16 && a < audio::kLimiterTimer + 32) continue;
    if (!SameWord(page_original.data() + i, At(a))) {
      std::fprintf(stderr, "%s case %d: page %08X original %08X native %08X\n", effect.name, index, a,
                   audio::LoadBe32(page_original.data() + i), audio::LoadBe32(At(a)));
      return false;
    }
  }
  return true;
}

void ImageConstants() {
  PutF(0x82000A34, R(3) ? 0.0f : 1e-30f);                 // flush constant
  PutF(audio::kReverbAllpassGain, R(4) ? 0.5f : U(-1, 1));
  PutF(audio::kReverbInputGain, R(4) ? 0.015f : U(-1, 1));
  PutF(audio::kLimiterOne, 1.0f);
  PutF(audio::kLimiterThreshold, U(0.01f, 1.0f));
  PutF(audio::kLimiterCurveMinimum, R(2) ? 1e-5f : U(0.0f, 0.1f));
  static const uint32_t combs[8] = {1116, 1188, 1276, 1356, 1424, 1492, 1556, 1616};
  static const uint32_t allpasses[4] = {556, 440, 340, 224};
  const uint32_t kind = R(10);
  for (int k = 0; k < 8; ++k)
    Put32(audio::kReverbCombLengths + 4 * k, kind < 7 ? combs[k] : kind < 9 ? 4 * (16 + R(400)) : 20 + R(1600));
  for (int k = 0; k < 4; ++k)
    Put32(audio::kReverbAllpassLengths + 4 * k, kind < 7 ? allpasses[k] : kind < 9 ? 4 * (8 + R(140)) : 20 + R(560));
}

// sub_829321A0
bool FilterCase(const Effect& e, int index) {
  uint32_t samples;
  const uint32_t buffer = Buffer(1, samples);
  const uint32_t self = Alloc(104);
  for (int i = 0; i < 5; ++i) { PutF(self + 4 + 4 * i, U(-1, 1)); PutF(self + 40 + 4 * i, U(-1, 1)); }
  for (int i = 0; i < 4; ++i) { PutF(self + 24 + 4 * i, R(5) ? U(-0.5f, 0.5f) : Sample()); PutF(self + 60 + 4 * i, R(5) ? U(-0.5f, 0.5f) : Sample()); }
  const uint32_t fa = R(4) ? 20 + R(23880) : 23900 + R(1000), fb = R(4) ? 20 + R(20000) : 0;
  Put32(self + 80, fa); Put32(self + 76, fb);
  Put32(self + 88, R(2) ? fa : R(24000)); Put32(self + 84, R(2) ? fb : R(24000));
  At(self)[100] = R(2); At(self)[101] = R(2);
  return RunCase(e, self, buffer, index);
}

// sub_82936CE0
bool BiquadCase(const Effect& e, int index) {
  const uint32_t channels = Channels();
  uint32_t samples;
  const uint32_t buffer = Buffer(channels, samples);
  const uint32_t self = Alloc(76);
  for (int i = 0; i < 5; ++i) PutF(self + 12 + 4 * i, U(-1, 1));
  if (R(8)) { PutF(self + 24, U(-1.8f, 1.8f)); PutF(self + 28, U(0, 0.9f)); }
  PutF(self + 60, R(8) ? U(-2, 2) : 1.0f);
  At(self)[68] = R(16) == 0; At(self)[74] = uint8_t(rng()); At(self)[75] = R(2);
  for (int i = 0; i < 4; ++i) {
    const uint32_t a = Alloc(4 * 40);
    Put32(self + 32 + 4 * i, a);
    for (int k = 0; k < 40; ++k) PutF(a + 4 * k, R(6) ? U(-0.5f, 0.5f) : Sample());
  }
  return RunCase(e, self, buffer, index);
}

// sub_82935BD0
bool ReverbCase(const Effect& e, int index) {
  const uint32_t channels = Channels();
  uint32_t samples;
  const uint32_t buffer = Buffer(channels, samples);
  const uint32_t self = Alloc(80);
  const uint8_t mask = uint8_t(rng());
  At(self)[78] = mask;
  uint32_t enabled = 0;
  for (uint32_t c = 0; c < channels; ++c) enabled += audio::ChannelEnabled(mask, c);
  PutF(self + 20, U(0.5f, 0.98f)); PutF(self + 56, U(0, 1)); PutF(self + 60, U(0, 1));
  const uint32_t damping = Alloc(16, 16, R(4) ? 0 : 4 * R(4));
  for (int i = 0; i < 4; ++i) PutF(damping + 4 * i, U(-1, 1));
  Put32(self + 28, damping);
  const uint32_t rows = Alloc(32, 16, R(3) ? 0 : 4 * R(4));
  for (int i = 0; i < 8; ++i) PutF(rows + 4 * i, U(-1, 1));
  Put32(self + 36, rows);
  uint32_t lists[6];  // +8 comb buffers, +16 comb positions, +12 states, +44/+48 allpass buffers/positions
  const uint32_t offsets[5] = {8, 16, 12, 44, 48};
  for (int i = 0; i < 5; ++i) { lists[i] = Alloc(4 * std::max<uint32_t>(enabled, 1)); Put32(self + offsets[i], lists[i]); }
  for (uint32_t c = 0; c < enabled; ++c) {
    const uint32_t comb_buffers = Alloc(32), comb_positions = Alloc(32), states = Alloc(32, 16, R(3) ? 0 : 4 * R(4));
    const uint32_t ap_buffers = Alloc(16), ap_positions = Alloc(16);
    Put32(lists[0] + 4 * c, comb_buffers); Put32(lists[1] + 4 * c, comb_positions); Put32(lists[2] + 4 * c, states);
    Put32(lists[3] + 4 * c, ap_buffers); Put32(lists[4] + 4 * c, ap_positions);
    for (int k = 0; k < 8; ++k) {
      const uint32_t length = audio::GuestWord(base, audio::kReverbCombLengths + 4 * k);
      const uint32_t b = Alloc(length * 4 + 32, 16, R(6) ? 0 : 4 * R(4));
      for (uint32_t i = 0; i < length + 4; ++i) PutF(b + 4 * i, U(-0.5f, 0.5f));
      Put32(comb_buffers + 4 * k, b);
      Put32(comb_positions + 4 * k, R(5) ? 4 * R(length / 4) : R(length));
      PutF(states + 4 * k, R(5) ? U(-0.5f, 0.5f) : Sample());
    }
    for (int k = 0; k < 4; ++k) {
      const uint32_t length = audio::GuestWord(base, audio::kReverbAllpassLengths + 4 * k);
      const uint32_t b = Alloc(length * 4 + 32, 16, R(6) ? 0 : 4 * R(4));
      for (uint32_t i = 0; i < length + 4; ++i) PutF(b + 4 * i, U(-0.5f, 0.5f));
      Put32(ap_buffers + 4 * k, b);
      Put32(ap_positions + 4 * k, R(5) ? 4 * R(length / 4) : R(length));
    }
  }
  return RunCase(e, self, buffer, index);
}

// sub_82934F00
bool LimiterCase(const Effect& e, int index) {
  const uint32_t channels = R(12) ? R(9) : 64 + R(9);
  uint32_t samples;
  const uint32_t buffer = Buffer(channels, samples);
  // 672 bytes in the game (its fields fit 6 channels); per-channel fields past that (history at
  // +12 + 80 * channel, states at +492/+516/+540/+564 + 4 * channel) stay inside the arena so the
  // snapshot covers everything the effect touches.
  const uint32_t self = Alloc(std::max<uint32_t>(672, 12 + 80 * channels + 64));
  At(self)[652] = R(2); At(self)[658] = uint8_t(rng());
  PutF(self + 644, U(0, 1)); PutF(self + 648, U(0.9f, 1)); PutF(self + 608, U(0.05f, 1.2f)); PutF(self + 612, U(0.5f, 2));
  for (uint32_t i = 12; i < 492; i += 4) PutF(self + i, Sample());
  for (uint32_t i = 492; i < 588; i += 4) PutF(self + i, R(8) ? U(0, 1.5f) : Sample());
  PutF(self + 588, U(0, 1)); PutF(self + 592, U(0, 1));
  static const float exponents[] = {0.0f, 0.5f, 1.0f, 2.0f, 3.0f, -1.0f, -0.5f, 1.5f, -2.0f};
  PutF(self + 596, R(3) ? exponents[R(9)] : U(-3, 3));
  PutF(self + 600, U(0, 1)); PutF(self + 604, U(0, 1)); PutF(self + 616, U(0.1f, 2));
  for (uint32_t i = 516; i < 588; i += 4) if (R(10) == 0) PutF(self + i, 0.0f);
  Put32(audio::kLimiterTimerCount, R(3) ? 0 : R(5));
  for (uint32_t i = 0; i < 1024; i += 4) PutF(audio::kLimiterScratch + i, Sample());
  if (std::getenv("AUDIO_EFFECTS_DUMP")) std::fprintf(stderr, "limiter case %d: mode %d channels %u mask %02X samples %08X self %08X\n", index, At(self)[652], channels, At(self)[658], samples, self);
  return RunCase(e, self, buffer, index);
}
}  // namespace

int main(int argc, char** argv) {
  void* memory = mmap(nullptr, 0x100000000ull + 0x2000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
  if (memory == MAP_FAILED) { std::fprintf(stderr, "audio effects: no guest memory\n"); return 1; }
  base = static_cast<uint8_t*>(memory);
  const int scale = argc > 1 ? std::atoi(argv[1]) : 1;
  const Effect effects[] = {
      {"filter sub_829321A0", __imp__sub_829321A0,
       [](PPCContext& ctx, uint32_t self, uint32_t buffer) { audio::RunFilterGuest(ctx, base, self, REX_LOAD_U32(buffer + 20)); }},
      {"eq sub_82936CE0", __imp__sub_82936CE0,
       [](PPCContext& ctx, uint32_t self, uint32_t buffer) {
         audio::RunBiquadGuest(ctx, base, self, REX_LOAD_U8(buffer + 13), REX_LOAD_U32(buffer + 20));
       }},
      {"reverb sub_82935BD0", __imp__sub_82935BD0,
       [](PPCContext& ctx, uint32_t self, uint32_t buffer) {
         if (!audio::ReverbLengthsValid(base)) return;
         audio::RunReverb(ctx, base, self, REX_LOAD_U8(buffer + 13), REX_LOAD_U32(buffer + 20));
       }},
      {"limiter sub_82934F00", __imp__sub_82934F00,
       [](PPCContext& ctx, uint32_t self, uint32_t buffer) {
         audio::RunLimiterTimed(ctx, base, self, REX_LOAD_U8(buffer + 13), REX_LOAD_U32(buffer + 20));
       }},
  };
  bool (*cases[])(const Effect&, int) = {FilterCase, BiquadCase, ReverbCase, LimiterCase};
  const int counts[] = {3000, 2000, 150, 1500};
  for (int e = 0; e < 4; ++e) {
    const uint64_t before = checks;
    for (int i = 0; i < counts[e] * scale; ++i) {
      arena_top = kArena;
      ImageConstants();
      if (!cases[e](effects[e], i)) { std::fprintf(stderr, "audio effects: FAILED (%s)\n", effects[e].name); return 1; }
    }
    std::printf("  %s: %d cases, %llu checks\n", effects[e].name, counts[e] * scale,
                (unsigned long long)(checks - before));
  }
  std::printf("audio effects: %llu checks passed (%llu NaN words matched as NaN)\n", (unsigned long long)checks,
              (unsigned long long)nan_matches);
  return 0;
}
