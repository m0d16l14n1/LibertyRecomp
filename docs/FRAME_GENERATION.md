# Frame generation and MetalFX denoising: where the work stands

Written 2026-11-04, before a reboot, so the work can resume. For the Metal 4 renderer in general see
`docs/METAL4.md`. For ray tracing see `docs/RAYTRACING.md`.

## Goal

The user asked for these on 2026-11-04:
- Frame interpolation and generation on Metal 3 and on Metal 4.
- MetalFX denoising and upscaling on Metal 4.
- Frame generation stays off by default.

The helper agent writes patches; the main session builds, tests and benchmarks.

## Settings

- `gta4_metalfx_frame_generation` (false): MetalFX frame interpolation, one generated frame between two
  real ones. Related settings:
  - `_half_rate` (true);
  - `_camera_motion` (true);
  - `_neighbour_motion` (true);
  - `_dump` (diagnostics).
- `gta4_metal_api = metal3 | metal4`. Under `metal4` the renderer encodes through the Metal 4 proxy
  (`src/ui/metal/metal4_queue.mm`).
- Denoiser, from the helper's patches, not applied yet: `gta4_metal_raytracing_denoiser = metalfx`. It needs
  `gta4_metal_api=metal4` and `gta4_metal_raytracing=ao`.

## Code

- `src/graphics/gta4_metal/temporal/effects.mm`, `FrameInterpolation`:
  - Configure makes the Metal 3 `MTLFXFrameInterpolator` and a ring of **2 slots**. Each slot holds:
    - `scene`: the previous real scene;
    - `real`: the real image with the UI;
    - `generated`.
  - Encode does the following:
    - snapshot blit;
    - optional UI-over pass;
    - interpolator encode;
    - UI-after pass;
    - leases `generated` and `real` to the presenter.
  - Under Metal 4 it creates an `MTL4FXFrameInterpolator` once, on the proxy's MTL4 queue, with its own
    fence (`fence4`).
    - It encodes with `rex::ui::metal::EncodeMetal4(commands, fence4, used, block)`.
    - If the native interpolator is unavailable it keeps the Metal 3 hop (`EncodeMetal3`).
  - A slot is reused only when `Available(slot.owner)` holds (the owning command buffer reports `status >=
    Completed`) and the presenter's lease has expired. Otherwise the frame is skipped with "interpolated
    pair is still in flight or leased".
- `temporal/live.mm`: calls `Encode`, then logs `TakeNotice()`. The temporal library cannot use REXLOG,
  because the temporal unit tests link it alone without spdlog. Messages go through
  `FrameInterpolation::TakeNotice()` and are logged in `live.mm`.
- `present.mm`: logs a stats line every 300 frames:
  `gta4-metal-framegen frame=N native-mtl4fx=N metal3-hop=N`.
- `src/ui/metal/metal4_queue.mm`: the proxy command buffer's `status`. It is set to Completed only in
  the MTL4 commit feedback (around line 665).

## State of the working tree (uncommitted)

The working tree holds one batch, not yet committed. A copy of the diff is in
`~/Library/Application Support/LibertyRecomp/wip-2026-11-04/working-tree.diff`.
- rt12: sampled timers, `gta4_metal_memo_targets`, CaptureBuffer handle memo (draw/renderer/resources files).
- Frame generation:
  - the helper's fg1 (native MTL4FX interpolator) and fg2 (stats line);
  - the TakeNotice build fix.
- The action bench: `tools/perf/pads/action-bench.pad`, plus the new dev pad world commands in
  `gta4-recomp/src/gta4_dev_pad.cpp` and `gta4_dev_world.cpp`:
  - `heli`, `water`, `weapon`, `peds`, `cars`, `explode`, `boom`, `where`, `native`.

**Not applied yet:** the helper's denoiser patches, `dn1-metalfx-denoiser-module.patch` and
`dn2-denoiser-hook-draw.patch`.
- They are saved in `~/Library/Application Support/LibertyRecomp/wip-2026-11-04/helper-fg/`, because `/private/tmp`
  is wiped by the reboot.
- dn1 calls `REXLOG_INFO`/`REXLOG_WARN` inside `temporal/effects.mm`. That breaks the
  `rex-metal-temporal` build in the same way fg1 did. Route those messages through a notice that `live.mm` logs.

## Measurements so far

The action pad, windowed, 2026-11-04. Both runs were taken while the Mac had 60 GB in swap, from guest-memory
objects leaked by earlier runs (fixed in b5bc41b1; a reboot clears the old ones). **Re-measure everything
after the reboot.**

| window | Metal 3, no FG (act3-m3) | Metal 4 + FG (act3-m4fg) |
| --- | --- | --- |
| drive | 48.6 fps, submit 13.1 ms | 35.3 fps, submit 19.7 ms |
| night | 46.4 | 25.0, p99 516 ms |
| heli | 54.6 | 12.8, submit 65.6 ms |
| boat | 47.3 | 18.3 |
| combat / boom | 29.2 / 30.3 | not reached: the pad stopped at `peds` (`CREATE_RANDOM_CHAR made no ped`) |

In the Metal 4 + FG run:
- `native-mtl4fx=2511 metal3-hop=0`: the native path ran.
- The frame was skipped **698 times** with "interpolated pair is still in flight or leased".
- Display windows showed `generated=0` almost throughout, and one window reported `shown-fps=0.7 not-displayed=2980`
  over 113 s.

Metal 3 + FG has not been measured in this batch.

A later Metal 3 smoke run on the same route (thr-smoke, after the threading fix) gave:
- all 43.1 fps;
- drive 57.3;
- heli 39.6;
- combat 32.2.

It also reached `peds` without an error. Swap was still full.

## Hypotheses for the Metal 4 + FG collapse, in the order to check them

1. **Slots look busy for too long.** `Available()` reads the proxy's `status`, which becomes Completed only
   when the MTL4 commit feedback arrives. With 2 slots, a GPU or feedback delay of more than a frame skips
   every other frame.
   - Log which condition fails, the owner's status or the lease.
   - Try 3 slots.
2. **Leases never expire.** The presenter holds `generated` and `real` until both are shown. If presentation
   pacing breaks down, which `not-displayed=2980` suggests, the leases pin the slots.
   - In `present.mm`, follow where generated frames are dropped, since `generated=0`.
3. **Serialisation.** EncodeMetal4 adds an empty encoder that waits on the earlier proxy encoders and
   updates `fence4`. Check in a GPU trace whether the interpolator waits on the whole frame. The submit
   time grew to 65 ms in heli.
4. Swap pressure inflated all of it. Re-measure first.

## Next steps after the reboot

1. Confirm swap is back near 0 (`sysctl vm.swapusage`).
2. Run one interleaved batch on the action pad:
   - Metal 3;
   - Metal 3 + FG;
   - Metal 4;
   - Metal 4 + FG.

   Example:
   `tools/perf/route_bench.sh pad career-street tools/perf/pads/action-bench.pad NAME --gta4_metal_api=metal4
   --gta4_metalfx_frame_generation=true --fullscreen=false`
   - Pass each setting once only: a duplicate makes CLI11 reject the command line, and the pad never runs.
   - Let the Air rest between runs.
   - Read `summary.txt`, and `game.log` for the framegen stats and the skip warnings.
   - The scripts are in `wip-2026-11-04/scripts/`: `action2.sh` runs the Metal 3 / Metal 4 + FG pair, and
     `build_m4.sh` builds and runs the unit tests.
3. Fix the slot and lease problem using the hypotheses above. Then compare Metal 3 + FG against Metal 4 + FG.
4. Apply dn1 and dn2, adapting the REXLOG calls.
   - Test with `--gta4_metal_api=metal4 --gta4_metal_raytracing=ao --gta4_metal_raytracing_denoiser=metalfx`
     and MetalFX AA.
   - Take screenshots with `gta4_metal_raytracing_ao_view=guides`.
   - Prior result from MCLA: `MTL4FXTemporalDenoisedScaler` used for its AO cost +8 ms GPU and smoothed
     textures away. Judge ours on image quality as well as cost.
5. Commit the batch in parts: rt12; the action bench and dev pad; native MTL4FX frame generation; the
   denoiser. Then do one bench pass for the whole batch (5-10 changes per bench pass, not one per patch).
