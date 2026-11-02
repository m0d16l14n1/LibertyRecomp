# macOS plan: launcher, settings, and the next performance work

Written 2026-11-01 after the first unattended session on the Games-on-Demand + TU8 build (15-inch
MacBook Air M5, 32 GB, macOS 27.2, 60 Hz panel). It borrows what worked in the sibling MCLA port
(`mcla-recomp`: SwiftUI launcher, live-only in-game settings, MetalFX) and maps it onto this fork,
whose renderer (`gta4-metal`) already had MetalFX built in.

## Where things stand

- **Native Metal is the default and the only renderer exercised.** `gpu_plugin` defaults to
  `gta4-metal` (`gta4::kDefaultGpuPlugin`); MoltenVK (`gta4-native`) stays selectable but is not
  tested here. A launch log line `gta4-metal-temporal: enabled method=...` names the active
  temporal path.
- **MetalFX did not need porting.** Upstream's renderer already has the MetalFX temporal scaler
  and frame interpolator (`src/graphics/gta4_metal/temporal/effects.mm`), selected by
  `gta4_native_upscaler = "metalfx"` with `gta4_fsr1_quality` for its size
  (`gta4_temporal_upscaler_quality` is FSR 3.1 and DLSS only), or
  `gta4_native_anti_aliasing = "metalfx_taa"` at native size. The pause menu already offers
  MetalFX on the Upscaling row and its quality on the row below. What this session added is the
  measurement (README, *Settings and performance*) and the default that follows from it.
- **Unattended play works.** `--gta4_pad_script` / `--gta4_pad_pipe` (`gta4_dev_pad.cpp`) drive a
  synthetic controller, take screenshots of the guest output and quit; `tools/perf/bench.sh` runs
  a fixed pad script from a new game (intro cutscene, then Roman's taxi at the docks) and prints
  per-window frame statistics. See *Measuring* below.
- **Result on the M5 Air (2026-11-01):** with MetalFX Quality at the 1440-line cap, every window of
  the bench holds 61 fps (GPU about 10.4 ms in the driving circle, no frame over 25 ms). The 60 Hz
  display link is now the limit. Defaults changed this session: upscaler MetalFX Quality on macOS,
  anisotropic filtering 16x, 482-recipe pipeline seed, CPU wait fixes; and a first-launch crash
  in the pipeline archive save is fixed (BACKLOG 34–42).

## 1. Launcher (done 2026-11-02: `launcher/mac`, see its README; model: `mcla-recomp/launcher/mac`)

Built by CMake (`LIBERTY_MACOS_LAUNCHER`, on by default) into the app as `Contents/MacOS/Liberty
Launcher`, the bundle's main program; the game installs and verifies headless for it
(`--install_only=true`). Every value it writes was checked against the game's own config loader
(all settings and keybinds load with no `Config:` warning). Not done from the plan below: the last
session's fps line on Play, importing a .zip of saves, and greying restart-only rows while the game runs.

A SwiftUI app with no Xcode project, compiled by `swiftc` into `Liberty Recompiled.app` as its main
program, with the game executable beside it. MCLA's has the shape to copy:

| Page | Contents here |
|---|---|
| Play | Play button; last session's fps line from the errors log; "the game closed unexpectedly" with the log's tail after a crash |
| Game Files | What the in-game installer does today (GOD package or USA disc + TU8, checked by media ID and hashes), moved out of ImGui; Verify; episodes |
| Saves | The `saves/545407F2` profile: back up, restore, export/import .zip, new game |
| Graphics | Renderer (Metal, Vulkan via MoltenVK), resolution (with the Air cap explained), upscaler (Native / MetalFX Quality / Balanced / Performance / FSR 1), anti-aliasing, anisotropic filtering, shadows, reflections, draw distance, population |
| Display & HDR | Screen to open on (pixels, refresh, EDR headroom from `NSScreen`), fullscreen/windowed, frame limit, frame pacing (Smooth / Low Latency), HDR |
| Controls | Mouse/trackpad rows (aim toggle, aim key, look hold, sensitivities), keyboard bindings |
| Advanced | Extra command-line options, the errors log, clear the Metal pipeline cache, "suggest settings for this Mac" |

Rules carried over from MCLA:
- The launcher edits `native.toml` in place (only the top-level keys it owns change; comments and
  other keys stay), the same file the pause menu writes, so each shows what the other set.
- Restart-only settings live in the launcher; while the game runs they are greyed out.
- Suggested settings from the chip: GPU core count and `IODeviceTree:/product` (as
  `gta4_native_air_resolution_cap` already reads) choose the render size and upscaler.
- `LIBERTY_LAUNCHER_PAGE=<page>` and `LIBERTY_LAUNCHER_PLAY=1` for screenshots and tests.

## 2. In-game settings (to do; model: MCLA commit `e021d82`)

- The pause menu's Liberty page and the F4 overlay show only what changes during play
  (`kHotReload`); restart-only rows (renderer, resolution, upscaler, reflections resolution, frame
  generation) move to the launcher, or stay marked *(RESTART)* until it exists.
- On macOS hide what a Mac cannot run: FSR 3.1, DLSS and Vulkan frame generation rows.
- MetalFX frame generation (`gta4_metalfx_frame_generation`) only on displays above 60 Hz
  (ProMotion, external 120 Hz+); on the Air's 60 Hz panel it adds latency and nothing visible.
- The Upscaling row's MetalFX entry shows the render size it implies (for example
  `METALFX QUALITY (1483x959)`), as MCLA's FSR rows do.

## 3. Performance and image quality (ordered by expected value)

| # | Item | Status |
|---|---|---|
| P1 | MetalFX Quality as the Apple Silicon default (render 2/3 size, upscale to the capped output) | done: the macOS default (BACKLOG 35, README table) |
| P2 | CPU: WaitMultiple without 1 ms polling (upstream PR #501), timer queue blocking wait (MCLA) | done (BACKLOG 37): fewer wake-ups, same fps |
| P3 | Anisotropic filtering default above 1x | done: 16x, no measurable cost (BACKLOG 36) |
| P4 | Refresh the bundled pipeline recipe seed from city driving (first-run hitches: 90-150 pipelines built in the first minute) | done: 482 recipes; first launch compiles them in ~5 s, and its archive save no longer crashes (BACKLOG 38). Refresh again after longer city sessions |
| P5 | Remaining POSIX fixes from upstream (#531 lost wakeups, #538 timer clamp) | #538 done with a test (BACKLOG 43); #531 not ported: GTA IV never calls the path it fixes, and its `WaitUntil` can deadlock ping-pong `SignalAndWait` pairs (BACKLOG 44) |
| P6 | Lock-free guest atomics (MCLA `rexglue-guest-atomics-lock-free.patch`) | low value: the region check is clean (0 violations), but the global lock is barely contended here (BACKLOG 40) |
| P7 | `CAMetalDisplayLink` pacing check on ProMotion panels | to do (needs a 120 Hz display) |
| P11 | Memory: XMA decoders made on first use, drawables at the panel's density in scaled modes | done: peak footprint 2.26 → 2.08 GB on the bench route, same fps (BACKLOG 50, 51) |
| P12 | Memory: the ~1 GB of Metal textures, targets and buffers (750 MB GPU-private, 320 MB shared) | partly: textures idle for 3 min are trimmed above 512 MB (BACKLOG 55); still to break down render targets (output vs render size) and the ~730 MB of captured and index buffers |
| P8 | Above-panel output (MetalFX to 2880x1864 on the Air) costs 17-21 ms GPU: only for Pro/Max chips; the launcher's suggestion should pick it by GPU core count | to do |
| P9 | HDR / EDR on the Air's panel | the 80-vs-203 nits mismatch was a menu display bug, fixed (BACKLOG 45); whether HDR looks better than SDR on the Air's limited EDR headroom is still to judge by eye |
| P10 | Dense-traffic city benchmark route (the docks route is light) | needs a story save in Algonquin to load; open-loop driving from a new game cannot reach it reproducibly (BACKLOG 46) |

## Measuring

```bash
tools/perf/bench.sh <label> [--flags]            # one run, ~2.5 min, quits by itself
tools/perf/bench_matrix.sh <matrix.txt>          # one run per line; "rest 90" lines cool the Mac
tools/perf/pad.sh <fifo> "press a" "shot /tmp/x.png 0.5"   # drive a game started with --gta4_pad_pipe=<fifo>
sample <pid> 8 -file s.txt && tools/perf/sample_busy.py s.txt   # CPU busy share per thread
```

The bench needs a profile without a story save (it expects the new-game intro). Its windows:
`cutscene` (20 s of the intro, deterministic), `parked` (15 s in Roman's taxi), `circle` (30 s
of full-lock driving, steady camera motion for the temporal paths). Results land in
`~/Library/Application Support/LibertyRecomp/perf/bench-<date>-<label>/` with `summary.txt`.
A MacBook Air has no fan: runs back to back lose up to a third of their frame rate, so compare
interleaved runs with rests between them.
