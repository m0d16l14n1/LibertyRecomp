<p align="center">
    <img src="docs/images/banner_repo.png" alt="Liberty Recompiled" width="800"/>
</p>

---

> [!CAUTION]
> This is a personal, work-in-progress fork. It is in early development and is NOT meant for public use.

**Liberty Recompiled, Games-on-Demand + TU8 and macOS edition.** This repository is a fork of
[hamishakl/LibertyRecomp](https://github.com/hamishakl/LibertyRecomp) (the PAL + macOS fork), which
itself forks [OZORDI/LibertyRecomp](https://github.com/OZORDI/LibertyRecomp), the unofficial PC port of
the Xbox 360 version of Grand Theft Auto IV created through static recompilation. This fork:

- **Runs from the Xbox 360 Games-on-Demand (GOD) package + Title Update 8.** That is the copy this
  fork is developed with (see [Game version](#game-version)). Its TU8 patches the executable into
  the **same compile as the USA disc + TU8** that upstream recompiled, so the US code in
  `generated/` runs it unchanged. The USA disc + TU8 is accepted too.
- **Keeps the macOS (Apple Silicon) and native Metal work** of the PAL fork: renderer, frame
  pacing, trackpad input, UI theme, diagnostics. The PAL fork's address remap was reversed, so
  every hook is back on US/TU8 addresses; the PAL disc is no longer supported here.
- **Is developed and tested on macOS with the native Metal renderer.** Windows and Linux are not
  built or tested here. Upstream remains the place for those platforms.

**This project does not include any game assets. You must provide the files from your own legally
acquired copy of the game to install or build Liberty Recompiled.**

The runtime is powered by a fork of the [ReXGlue SDK](https://github.com/rexglue/rexglue-sdk), which
handles PowerPC → C++ recompilation and Xenos shader translation. The development of static
recompilation tooling in this space was directly inspired by
[N64: Recompiled](https://github.com/N64Recomp/N64Recomp).

## Table of Contents

- [Game version](#game-version)
- [What is different in this fork](#what-is-different-in-this-fork)
- [Status](#status)
- [Installation](#installation)
- [Settings and performance](#settings-and-performance)
- [Mouse and trackpad](#mouse-and-trackpad)
- [Building on macOS](#building-on-macos)
- [Mod Support](#mod-support)
- [Documentation](#documentation)

## Game version

The copy in use is the Xbox 360 **Games-on-Demand** package of GTA IV, laid out as on a console
drive (`545407F2/00007000/` for the game, `545407F2/000B0000/` for the title update). Game files
are never committed; the folders are in `.gitignore`.

| | Games on Demand (this fork's target) | USA disc (upstream's target) |
|---|---|---|
| Title ID | `545407F2` | `545407F2` |
| Media ID | `0x4A53F9F6` | `0x6AC07221` |
| Base `default.xex` version | 6 (0.0.0.6) | 5 (0.0.0.5) |
| Region flags | `0x00FFFD00` (all but NTSC-J Japan) | `0x000000FF` (USA) |
| Title update | TU8 (`tu00000006_00000000`, listed as "RUS Title Update #8") | TU8 |
| Patched version | **0.0.8.6** (`0x806`) | 0.0.8.5 (`0x805`) |
| Patched image | `0x1300000`, same compile as US TU8 | `0x1300000` |

**Why the US code runs it:** with TU8 applied, all 141,148 recompiled call sites in `generated/` find
the same `bl` at the same address with the same target (`tools/xex/compare_callsites.py`, 100%, zero
drift). Without TU8 the GOD base is a different compile (5.6% match), so **TU8 is required**. The PAL
disc + TU5 is a third compile and would need its own remap (`docs/PAL-PORT.md`).

**What support means here:**
- Installer: accepts the GOD package (the `00007000/<id>` file with its `.data` folder) or the USA
  disc, each with its own TU8, verified by media ID, region, base hash, RSA signature and patch hash.
- Runtime: the US/TU8 recompilation with every hook on US addresses (`tools/xex/check_us_addresses.py`
  verifies all ~4,100 address references against `generated/`).
- Platform: macOS on Apple Silicon, `gta4-metal` renderer by default.

## What is different in this fork

| Area | OZORDI upstream | This fork |
|---|---|---|
| Game release | USA disc, Title Update 8 | **Games on Demand + TU8** (same executable as USA + TU8, which is also accepted). Builds `generated/` (`LIBERTY_RECOMP_PAL=OFF`) |
| Platforms | Windows, Linux, macOS | **macOS Apple Silicon** only (Homebrew LLVM) |
| Default renderer | `gta4-native` (Vulkan via MoltenVK) | **`gta4-metal`**, the native Metal renderer (the title default on Apple platforms); `gta4-native` stays selectable |
| Shader cache | US shaders | US cache (plus 24 unused PAL entries from the PAL fork); pipelines are recorded and precompiled into a Metal binary archive at launch |
| Installer | US media ID and TU8 hashes | A release table: USA disc + TU8 and Games on Demand + TU8 |
| UI | Green Xenia-style ImGui | GTA IV-style theme: black panels, DIN type, amber accent, across the installer, chat and overlays |
| World settings | Draw distance 3×, shadows 2×, population 1.25×, 1080p reflections | Xbox 360 parity by default (measured faster and busier on the M4); upstream values as a preset |
| Upscaling | Native-size SMAA | **MetalFX temporal upscaling (Quality)** by default on Apple Silicon: renders at 2/3 size, upscales to the output; SMAA at native size stays one setting away |
| Diagnostics | Native profiler | Per-frame Metal timing CSV, GPU pass profiler, presenter trace, stutter capture tooling, and an unattended benchmark that plays a fixed route with a scripted controller (`tools/perf/`) |
| Mouse / trackpad | Hold-RMB aim; camera re-centres after mouse look | Trackpad-aware input: mouse look holds the camera, tap-to-toggle aim on a trackpad, a keyboard aim key (Option), all in the pause-menu settings |

Address matching, remapping and the XEX/TU/GOD tooling live in `tools/xex/` (see its README).

## Status

- **Games on Demand + TU8 (2026-11-01):** installs, boots and plays on native Metal on a 15-inch
  MacBook Air M5: the new-game intro, Roman's taxi at the docks and free driving hold the 60 Hz
  panel rate (61 fps, no frame over 25 ms in the driving window) with MetalFX Quality at the Air's
  1440-line output. Measured by `tools/perf/bench.sh`, not by hand; see *Settings and performance*.
- Next steps (launcher, in-game settings, remaining performance work) are planned in
  [docs/MACOS-PLAN.md](docs/MACOS-PLAN.md).
- Inherited from the PAL fork (measured there on the PAL build): boots, plays the opening cutscene
  and free-roam on `gta4-metal`.
- Frame pacing work on 2026-10-10 removed a once-per-second main-thread stall (IOKit HID inventory),
  stopped a hidden window from dropping to 4 fps, and found that rendering at the 2× backing store
  of a scaled display mode was the main GPU cost. Dense city traffic still sits around 30 fps.
- Everything upstream lists as complete (audio, saves, input, VFS, multiplayer stubs, FusionFix
  overlays) is carried over, but only the macOS + Metal path is exercised here.

## Installation

Install directory on macOS: `~/Library/Application Support/LibertyRecomp/`
(`game/`, `saves/`, `save-backups/`, `shader_cache/`, `native.toml`, `perf/`).

### The launcher

Opening `Liberty Recompiled.app` opens its launcher (SwiftUI, `launcher/mac`), modelled on MCLA's:

| Page | What it does |
|---|---|
| Play | Checks the program, the game files and the story save; a summary of this run's settings, with the exact size the game will draw at (for example `2224×1439 · MetalFX Quality (from 1483×959)` on a 15-inch Air); Play and Quit the Game; the errors log's tail if the game crashes |
| Game Files | Installs a Games-on-Demand package or a USA disc with its TU8 through the game's own installer, without opening the game's window (`--install_only=true`), with progress; Check Files runs the game's integrity check; the episode installer |
| Saves | The story saves; dated backups of the whole saves folder, restore (what is there is backed up first), export as .zip |
| Graphics | A suggestion for this Mac's chip; renderer; upscaling (Native, MetalFX or FSR 1 at four presets) with the render size each gives; quality, effects and world settings |
| Display & HDR | Screens (panel pixels, refresh rate, EDR), full screen, aspect, the panel and Air caps, vertical sync, frame pacing, frame limit, HDR |
| Game, Controls | Intro, quick save, the episode prompt, player name; mouse, trackpad and controller rows; the keyboard controller's 20 keys, each set by pressing the key |
| Advanced | After Play (hide, stay, quit), extra options for the game, the settings file and logs, clearing the Metal shader cache, log level, reset to defaults |

It writes `native.toml`, the file the pause menu saves to, and only the lines it changes; a setting at
its default is no line at all. The game itself is `Contents/MacOS/Liberty Recompiled` and still runs on
its own (benchmarks, launch arguments). A value the game refuses, a file that is not valid TOML or a
misspelt key is reported in `logs/Liberty Recompiled-errors.log` (`Config:` lines): before this fork
they were dropped, because the file is read before logging starts.

### Game files required

You need a legal copy of GTA IV for Xbox 360, either the **Games-on-Demand** package or the **USA
disc**, plus that release's Title Update 8. The installer checks the media ID, region and hashes;
the PAL disc and other releases are rejected.

| Input | What to provide |
|---|---|
| Base game | GOD: the header file `545407F2/00007000/<id>` (keep `<id>.data/` next to it). USA: disc image (`.iso`) or extracted disc folder |
| Title Update 8 | The TU package from the console's `Content/0000000000000000/545407F2/000B0000/` (for GOD: `tu00000006_00000000`), or a bare `default.xexp`. Each release needs its own TU8 |
| Episodes | Optional: The Lost and Damned / The Ballad of Gay Tony XContent packages |

See the [Dumping Guide](docs/DUMPING-en.md) for extraction and `tools/xex/README.md` for how the
GOD package and TU were verified (`extract_god.py`, `apply_tu.py`, `compare_callsites.py`).

### Launch arguments

Every setting in `native.toml` can be passed as `--name=value`. Useful ones:

| Argument | Description |
|---|---|
| `--install` | Force reinstallation (the installer screen) |
| `--install_dlc` | Install episodes only |
| `--install_check` | Verify file integrity |
| `--gpu_plugin=gta4-metal` | Renderer (`gta4-metal`, `gta4-native`, `xenos`); restart required |
| `--resolution=1440p` | Render resolution preset; `--video_mode_width/height` for an exact size |
| `--gta4_performance_hud=true` | Apple's Metal Performance HUD (fps, GPU time, frame graph) |
| `--diagnostics=true --diagnostics_categories=logging,presenter` | Text log plus the presenter/frame-pacer trace |

## Settings and performance

- **Render resolution.** Upstream renders at the display's full backing store, which on a scaled
  retina mode ("looks like 1920×1243") is 3840×2486, more pixels than the 2880×1864 panel has. This
  fork caps the automatic size at the panel's native pixels (`gta4_native_panel_resolution_cap`,
  on by default). For more headroom, `resolution = "1440p"` in `native.toml` (the same choice as
  Settings > Resolution in game) renders at 2224×1440 at the display aspect; on the M4 that cut
  GPU time per frame from 33 ms to 20 ms.
- **MacBook Air default: 1440 lines.** With no resolution set, a MacBook Air renders at most
  1440 pixels tall at the panel's aspect (`gta4_native_air_resolution_cap`, on by default; any
  explicit `resolution` wins). On a 15-inch M5 Air (2026-10-31) that took free-roam from 33–45 fps
  (GPU 15–26 ms at 2880×1864) to a held 60 fps (GPU ~12 ms at 2224×1440).
- **Fonts on the Games-on-Demand copy.** Its font textures use a different glyph layout, so the
  port's high-resolution replacement atlases are skipped for them (the log says
  `keeping the stock texture`); otherwise every letter would be drawn as the wrong glyph.
- **Frame pacing.** The title runs one frame ahead of presentation by default
  (`present_frames_ahead = 1`): with CPU and GPU both just under a 60 Hz tick, that cut frames shown
  for two vsyncs from 24% to 8% and raised the on-screen rate from 48 to 55 fps on the same route,
  at up to one frame of latency. Settings > **Frame Pacing** switches to Low Latency.
- **Memory.** Peak footprint over the bench route went from 2.26 GB to 2.08 GB (2026-11-02, same
  fps). The audio decoder made an FFmpeg WMA Pro decoder for each of the Xbox's 320 XMA contexts at
  start (464 KB of state each, about 150 MB, none of it used: every stream opens a fresh one); they are
  now made when a context first decodes and freed when the title releases it. In a scaled display
  mode the Metal drawables were sized for the 3840x2486 backing store and then shrunk to the
  2880x1864 panel by the compositor; with `gta4_native_panel_resolution_cap` on they are now the
  panel's size (drawables 111 MB → 62 MB). What remains is mostly the guest's 512 MB, about 1 GB of
  Metal textures, targets and buffers, and MetalFX's own networks (about 130 MB). Over a long session
  the texture cache kept textures the game had stopped using (1.1 GB after 18 minutes); textures not
  bound for three minutes are now dropped once it holds more than 512 MB, and reloaded if wanted again.
- **MetalFX upscaling is the default on Apple Silicon.** `gta4_native_upscaler = "metalfx"` with
  `gta4_fsr1_quality = "quality"` (MetalFX uses FSR 1's four presets) renders at 2/3 of the output size (1483×959 for the
  Air's 2224×1440) and lets MetalFX's temporal scaler rebuild the full image; it also replaces SMAA
  as the anti-aliasing. Measured on the M5 Air (2026-11-01, driving window of the bench route, runs
  interleaved with rests because the Air has no fan):

  | Setting | Output | fps | GPU ms/frame | Frames over 25 ms |
  |---|---|---|---|---|
  | **MetalFX Quality (default)** | 2224×1440 | 61 | 10.3–10.5 | 0 |
  | SMAA, native size | 2224×1440 | 61 | ~11.5 | 0–28 (rises as the Mac warms) |
  | MetalFX TAA, native size (`gta4_native_anti_aliasing = "metalfx_taa"`) | 2224×1440 | 42 | 16.4 | 332 |
  | MetalFX Performance | 2880×1864 (panel) | 47 | 19.1 | 122 |
  | MetalFX Quality | 2880×1864 (panel) | 43 | 21.3 | 199 |
  | SMAA, native size | 2880×1864 (panel) | 36 | 25.4 | 445 |

  The last four rows ran back to back on a warm Mac, so they understate a cool one by a few fps,
  but none holds 60 on an Air; the panel-resolution rows are for Pro and Max chips. The image is clean, slightly
  softer on small text than SMAA. To go back to native-size SMAA, set `gta4_native_upscaler = "native"`
  in `native.toml` or Settings > Display > Advanced > Upscaling. The frame rate is capped by the
  60 Hz display link: `gta4_frame_limit = 0` and `--gta4_present_mode=immediate` do not lift it.
- **Anisotropic filtering is 16× by default** (was 1×). Roads and pavements at a glancing angle stay
  sharp; on the M5 Air the driving window's GPU time did not change measurably.
- **Fewer CPU wake-ups.** Waiting on several kernel objects at once polled every 1 ms (upstream
  rexglue PR #501 fixes this with a shared condition variable; ported here), and the timer queue
  spun instead of blocking (the fix from the MCLA port). Frame rate is unchanged because the GPU
  sets the pace, but the timer thread went from 11.5% to 0.7% busy and the audio worker from 3.6% to
  2.2%, which is heat a fanless Air no longer spends. `timer_queue_blocking_wait = false` restores
  the old timer queue.
- **Deferred resolves.** The Xbox 360 copies its render targets into textures 28 times a frame.
  The Metal renderer now records each copy and runs it when the texture is first read or the
  source is about to be redrawn, so a copy that is overwritten unread is dropped. The frame summary
  in the game log prints `resolve-deferred / executed / dropped`; `gta4_metal_defer_resolves = false`
  restores the immediate path. In practice the unread copies are forced anyway, because their source is
  redrawn with its old contents loaded, so this saves nothing yet; `docs/BACKLOG.md` item 17 has the
  measurements and what a real saving would take.
- **World settings default to Xbox 360 parity.** Upstream raises draw distance (3×), shadows (2×),
  population (1.25×), reflections and the streaming budget. On the M4 that ran at 34 fps with 70 ms
  spikes; parity ran at 50 fps with a flat 33 ms p99 and visibly more traffic (the raised budgets
  starved spawning). `tools/perf/play_preset.sh upstream-defaults` brings the raised values back
  for a session without touching your config.
- **Capturing a stutter.** `tools/perf/capture_stutter.sh` launches with diagnostics on and writes a
  per-frame CSV, a GPU pass CSV and the game log into one folder per session under `perf/`.
  `tools/perf/summarize_frames.py <frames.csv>` prints fps, percentiles and 5-second windows.
- **Errors log.** Even without diagnostics, warnings and errors go to
  `~/Library/Application Support/LibertyRecomp/logs/Liberty Recompiled-errors.log` (the path is
  printed at start). After a crash, look there first; `log_quiet_errors = false` turns it off.
  Its first line is a `device summary` (GPU, Apple family, 32-bit float MSAA support, memory,
  macOS version). **Black screen or hang on another Mac:** send that file. M1 (Apple family 7)
  cannot multisample 32-bit float surfaces; the renderer substitutes RG16Float there and logs it.
- **Crash or black screen at the shader loading screen.** Apple keeps its own shader cache for the
  app under `$(getconf DARWIN_USER_CACHE_DIR)/OZORDI.LibertyRecomp/com.apple.metal`; a stale entry
  there makes Metal fault while saving the rebuilt pipeline archive. The game clears that cache
  before any launch that rebuilds the archive: the first launch, the first after an update that
  ships new pipeline recipes, and the launch after a failed rebuild (the errors log says
  `cleared the host shader cache`). To do it by hand, delete that directory with the game closed.
- **First launch.** The app ships 482 pipeline recipes recorded in play (intro, docks, city
  driving, MetalFX passes); the first launch compiles them behind the loading screen (about 5 s on
  the M5) so the first drive does not stall on new pipelines.
- **Unattended runs and benchmarks.** `--gta4_pad_script=<file>` plays a scripted controller
  (press, hold, sticks, triggers, waits, screenshots of the game image, quit), and
  `--gta4_pad_pipe=<fifo>` takes the same commands live (`tools/perf/pad.sh`).
  `tools/perf/bench.sh <label> [--flags]` starts a new game, skips into the docks, drives a circle
  and prints per-window fps, percentiles and GPU time; `tools/perf/bench_matrix.sh` runs a list of
  settings with rests in between. The bench needs a profile without a story save. Details in
  [docs/MACOS-PLAN.md](docs/MACOS-PLAN.md#measuring).
- **Launch flags are not saved.** A cvar given on the command line (`--diagnostics`, `--log_file`,
  the capture script's CSV paths, `--gta4_performance_hud`) is never written to `native.toml` by the
  settings menu unless you change it there afterwards.
- **Hotkeys.** F3 debug overlay, backtick console, F4 settings, F7 achievements, Y / U text chat.

## Mouse and trackpad

The port drives the retail cameras directly with mouse displacement rather than emulating a stick.
Two things made that awkward on a MacBook trackpad and were fixed on 2026-10-10:

- **Camera no longer drifts back to centre after looking around.** The retail cameras decide
  "stick released" from the stick's dead-zone test before the mouse rotation is applied, so with a
  mouse they always re-centred as if the stick had just been let go. Recent mouse or trackpad
  motion now counts as a held stick for that decision (on foot, gameplay, aim and vehicle follow
  cameras) for `gta4_mouse_look_hold_seconds` (default 2 s). Setting: **Mouse Look Hold**.
- **Aiming without holding a secondary click.** A trackpad can't hold a two-finger click and move,
  so aim is tap-to-toggle whenever the last look input came from a trackpad
  (`gta4_trackpad_aim_toggle`, on by default), and a keyboard key aims like RMB
  (`gta4_keyboard_aim_key`, default **Option**; Tab, Caps Lock, Z, X or none). Fire stays on click
  or tap. Settings: **Trackpad Aim**, **Keyboard Aim Key**, plus the existing **Mouse Aim**
  hold/toggle for a mouse.
- **Trackpad sensitivity** defaults to 2× (`mnk_trackpad_sensitivity`; a mouse uses
  `mnk_sensitivity`), chosen by feel on a MacBook. Setting: **Trackpad Sensitivity**, 0.5×–4×.

Mouse and trackpad aim is free aim with no target lock, as on the PC release; the toggle engages
only for weapons that free-aim (fists and melee stay held lock-on). All of these are rows on the
pause menu's Liberty settings page and in the F4 overlay under GTA IV / Input.

## Building on macOS

Requirements: macOS 26 or later with Xcode and the Metal toolchain
(`xcodebuild -downloadComponent MetalToolchain`), and
`brew install cmake ninja llvm spirv-cross glslang vulkan-loader molten-vk` (the last two bundle a
Vulkan runtime for the optional `gta4-native` renderer). Tested 2026-10-31 on macOS 27.2 / Xcode 27.1.

```bash
git clone https://github.com/m0d16l14n1/LibertyRecomp.git
cd LibertyRecomp
python3 tools/setup_repo.py
cmake --preset macos-release -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0   # = your macOS major version
cmake --build --preset macos-release --target LibertyRecomp
open "out/build/macos-release/LibertyRecomp/Liberty Recompiled.app"
```

The deployment target must be at least the minimum of Homebrew's `libc++` (macOS 27 with LLVM 23 on
macOS 27); the bundle check fails with `Mach-O minimum ... exceeds app minimum` otherwise. curl is
taken from the macOS SDK, so a third-party framework with old curl headers (CryptoPro CSP) no
longer breaks the build.

Setup fetches the pinned dependencies and applies the required source patches. After pulling:

```bash
git -c submodule.recurse=false pull --ff-only
python3 tools/setup_repo.py
```

The US/TU8 recompilation in `glue/rexglue-sdk-main/gta4-recomp/generated/` is tracked, so no game
executable is needed to build. Regenerating it from the Games-on-Demand `default.xex` + TU8 reproduces it byte for
byte (`out/build/codegen` per docs/BUILDING.md, then `rexglue codegen gta4_manifest.toml` with the two
files linked as `gta4-recomp/assets/default_v8.xex` / `.xexp`).

**Experimental: register-local codegen.** `rexglue codegen gta4_fast_manifest.toml` writes
`generated_fast/` (local, not tracked) with condition/count/XER registers as C++ locals, and
`-DLIBERTY_RECOMP_FAST_CODEGEN=ON` builds from it. It needs a play test before it becomes the default
(docs/BACKLOG.md item 25). Build it in its own folder (`cmake --preset macos-release -B out/build/macos-fast
-DLIBERTY_RECOMP_FAST_CODEGEN=ON`). Every build folder writes the SDK libraries to the shared
`glue/rexglue-sdk-main/out/mac-arm64/`, so rebuild the folder you test from last. After changing hooks, run `python3 tools/xex/check_us_addresses.py`
to confirm every guest address still exists in that tree. See [docs/BUILDING.md](docs/BUILDING.md) for
presets, memory-limited builds and the `from_chars` deployment-target error.

## Mod Support

FusionFix-style file overlays are carried over from upstream: files placed under `update/` next to
the game data override base files, mirroring the game's folder structure. Only the `update:` mount is
implemented in this fork; the priority table in [docs/MOD_SUPPORT.md](docs/MOD_SUPPORT.md) is
upstream's design.

## Documentation

| Document | Description |
|---|---|
| [PAL port](docs/PAL-PORT.md) | History of the PAL fork's US → PAL port (reversed in this fork) and its lessons |
| [macOS plan](docs/MACOS-PLAN.md) | Launcher and in-game settings plan, performance backlog, how to benchmark |
| [Dev notes](docs/DEV-NOTES.md) | Map of the codebase for macOS work: boot flow, hooks, renderers, tools |
| [Building Guide](docs/BUILDING.md) | Build presets and macOS troubleshooting |
| [Dumping Guide](docs/DUMPING-en.md) | Extracting game files from an Xbox 360 |
| [XEX tools](tools/xex/README.md) | XEX extraction, title-update application, US/PAL comparison |
| [Mod Support](docs/MOD_SUPPORT.md) | FusionFix-compatible overlays |
| [Installation Architecture](docs/INSTALLATION_ARCHITECTURE.md) | Platform paths and install flow |
| [Online Multiplayer Guide](docs/ONLINE_MULTIPLAYER.md) | Online play setup (untested in this fork) |

## Performance comparison

This fork, free-roam driving on a **MacBook Air (Apple M4, 16 GB, macOS 26.6)** with the native Metal
renderer, `resolution = "1440p"` and the port's default draw-distance/population settings. The
overlay is Apple's Metal Performance HUD (`gta4_performance_hud = true`). Its resolution line is the
Metal layer the frame is presented on (the display's 3840×2486 backing store, a 2880×1864 panel in a
scaled mode), not the render size: the game renders at 2224×1440 and the presenter upscales it.

![Liberty Recompiled on Apple M4, native Metal, 30 fps](docs/images/perf_liberty_metal_m4.png)

Upstream's comparison of GTA IV on macOS by other methods, kept for reference:

| Method | Screenshot |
|--------|------------|
| **Crossover (Wine)** | ![Crossover Performance](docs/images/perf_crossover.png) |
| **Xenia (Xbox 360 Emulator)** | ![Xenia Performance](docs/images/perf_xenia.png) |
| **RPCS3 (PS3 Emulator)** | ![RPCS3 Performance](docs/images/perf_rpcs3.png) |
