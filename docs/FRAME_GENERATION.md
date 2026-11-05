# Frame generation and MetalFX denoising: where the work stands

Written 2026-11-04, before a reboot, so the work can resume; updated the same evening after the
Metal 4 + FG investigation. For the Metal 4 renderer in general see
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
- Denoiser: `gta4_metal_raytracing_denoiser = native | metalfx` (default native). `metalfx` needs
  `gta4_metal_api=metal4`, `gta4_metal_raytracing=ao` and MetalFX AA; otherwise it stays native. Debug view:
  `gta4_metal_raytracing_ao_view=guides`. Details in `docs/RAYTRACING.md`.

## Code

- `src/graphics/gta4_metal/temporal/effects.mm`, `FrameInterpolation`:
  - Configure makes the Metal 3 `MTLFXFrameInterpolator` and a ring of **3 slots** (2 until the
    evening of 2026-11-04, see Findings). Each slot holds:
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
    pair is still in flight or leased: owner-status=N leased=yes|no" (N is the owner's
    `MTLCommandBufferStatus`, 3 = scheduled; `leased=yes` means the presenter still holds the pair).
- `temporal/live.mm`: calls `Encode`, then logs `TakeNotice()`. The temporal library cannot use REXLOG,
  because the temporal unit tests link it alone without spdlog. Messages go through
  `FrameInterpolation::TakeNotice()` and are logged in `live.mm`.
- `present.mm`: logs a stats line every 300 frames:
  `gta4-metal-framegen frame=N native-mtl4fx=N metal3-hop=N`.
- `src/ui/metal/metal4_queue.mm`: the proxy command buffer's `status`. It is set to Completed only in
  the MTL4 commit feedback (around line 665). `encodeWaitForEvent` now commits the open part first when it
  already has encoders, so a queue wait gates only the work after it (see Findings, 3).
- `src/ui/metal/presenter.mm`: shows a pair as generated, then real. The real image is painted only once
  the generated image's display command buffer has completed (`pending_generated_done`), and a failed
  mailbox refresh keeps its previous `ready_value` (see Findings, 4).

## State of the tree

Committed: 175b729d (rt12 per-draw CPU), e547e815 (action pad and dev pad world commands), 0cb320e5
(native MTL4FX frame interpolator, fg1 + fg2 + the TakeNotice build fix).

Uncommitted batch, to build and bench together:
- the MetalFX denoiser (`helper-fg/dn-metalfx-denoiser-rebased.patch`: dn1 + dn2 rebased, REXLOG in
  `temporal/effects.mm` routed through `AntiAliasing::TakeNotice()`);
- the FG ring at 3 slots and the skip-reason string (`temporal/effects.mm`);
- the proxy wait split (`helper-fg/m4-wait-split-proxy.patch`, `metal4_queue.mm`);
- the presenter pair pacing and ready-value fix (`helper-fg/presenter-ready-and-pair-pacing.patch`);
- the dev pad `peds` retry (`helper-fg/devpad-peds-retry.patch`, `gta4_dev_world.cpp`).

## Findings, 2026-11-04 evening

1. **The b1 bench was void.** A Virtualization.framework VM started around 20:56 and kept the GPU at
   100% (IOAccelerator Device Utilization): b1-m3 fell from 28 to 4 fps with gpu_ms at 190. Before a bench,
   check that no VM or other GPU user is running (Activity Monitor's GPU history, or
   `ioreg -l | grep "Device Utilization"`).
2. **Slots held by the GPU (hypothesis 1, confirmed on Metal 3 + FG).** The skip reasons in b1-m3fg were
   163 `owner-status=3` (scheduled, not yet completed), 33 `leased=yes` and 1 `owner-status=2`. With 2-3
   frames in flight a slot is often still running when it comes round again, so the ring is now 3 slots.
   At 4K output that is 9 RGBA16Float images, about 600 MB, inside the 1 GB per-effect budget
   (`OwnedTextureBudget`); the AA ring adds 3 more (about 200 MB).
3. **Metal 4: the mailbox wait held the whole frame (root cause of generated=0).** `present.mm` encodes
   `BeginWrite` (wait for the display queue's `display_done`) before the mailbox copy. On Metal 3 that wait
   gates only the commands after it. The proxy recorded it and issued `[MTL4CommandQueue waitForEvent:]`
   before committing the open part, so everything encoded in that part (the scene tail, the interpolator,
   the composes) waited for the display queue to paint the previous image, that is, for the next vsync.
   `render_ready` was then signalled late, the generated and the real display buffers (both waiting on it)
   were released together and presented in one refresh, and the generated drawable was always replaced:
   `generated=0`, `not-displayed=2980`, `shown-fps=0.7`. The late chain also kept both FG slots leased (one
   pair in `pending_pair`, the next in the mailbox output), hence the 698 skips. Fix: the proxy commits the
   open part before recording a wait (`m4-wait-split-proxy.patch`).
4. **Pair pacing.** Even without that wait, a slow GPU tail can release both display buffers of a pair in
   one refresh. Timed presentation is not available with `CAMetalDisplayLink`, and an earlier ready value
   for the generated image gains nothing (both come from the same submit). The presenter now holds the real
   image until the generated image's display buffer has completed, so the two are at least one refresh
   apart. Also fixed: a failed mailbox refresh no longer leaves an unsignalled `ready_value`.
5. **EncodeMetal4's empty encoder** (hypothesis 3) is correct and not the problem: its queue barrier makes
   MetalFX wait for the frame's earlier work, which it needs anyway, and later work is ordered by each
   proxy encoder's own start barrier, as for every other pass.
6. **The MetalFX temporal scaler on Metal 4** has neither problem: it encodes no event waits, its 3-slot
   ring is released by the proxy's completion handler, and the presenter never holds its images.
7. **`Flush(true)` in the FG path** (`present.mm`, after `ValidateMotionCoverage`) runs only with
   `gta4_metalfx_frame_generation_camera_motion=false`. It is the CPU wait for the motion-coverage
   readback that decides whether the frame may be interpolated. With the default (camera motion fill on)
   it never runs.
8. **Dev pad `peds`.** `CREATE_RANDOM_CHAR` makes nothing while no ped models are streamed in around the
   player, which stopped the Metal 4 + FG pad. `peds` now retries each frame, falls back to `CREATE_CHAR`
   with `M_Y_THIEF` after 2 s, and replies `ok N` after 10 s at most, so the pad never stops there.
9. **Car "tearing" under frame generation comes from low base fps, not from history matching.**
   Drive A/B, Metal 4 + FG, 20 dumps per run, scored by `tearscore.py`. The score is, per pixel, the
   generated image's distance to the closer of `before` and `real`, measured in a box over the car.
   - **Runs:**
     - r0a, limit off, 37 fps: clean. The worst car-box p99 was 45.
     - r35a, `gta4_temporal_history_rotation_limit=0.35`, 13.5 fps: frames 22016-22057 bad (p99 100-121).
     - rtq, limit off, 14 fps (with the render-thread patches): frames 14532-14562 bad in the same way.
   - **What it looks like:** a block of road carried along under the car, and a copy of the bumper
     pushed down by about 150 px at 2560x1440. That strip differs from both real frames by about 100
     levels, while they differ from each other by 14.
   - **Why:** the motion field is right (the car about 0 px, the road 40-70 px per real frame at 14
     fps), and depth is reversed and reported as such. The road just below the bumper is nearer than
     the bumper, so the interpolator gives the bumper's boundary pixels the road's motion.
   - **When it shows:** at about 37 fps the road moves about 25 px per frame and the artifact is gone.
     So it scales with the gap between real frames. Both slow runs were slow because of GPU contention
     (see below).
   - **The rotation limit** neither causes nor fixes this. It stays at 0 (off).
   - **Fix: give the interpolator the camera matrices** (`gta4_metalfx_frame_generation_camera_matrices`,
     now on by default).
     - `worldToViewMatrix`/`viewToClipMatrix` are new in macOS 27. The interpolator derives
       camera-only motion from them; until now they stayed at identity, which means "not supplied".
     - Same drive at 14-16 fps:
       - without them, 5 of 18 dumps were bad (car-box p99 65-114);
       - with them, 0 of 19 (worst p99 37).
     - The bumper copy and the dragged block are gone. A faint smear under the bumper remains.
   - **`gta4_metalfx_frame_generation_max_real_ms`** (0 = off): presents real frames only while the
     smoothed real interval is above it. It resumes below 85% of the value, and the skips are counted
     as `slow-skips=` in the `gta4-metal-temporal-frame` line. Verified: at 50 it skipped 430 frames
     of a run at about 21 fps.
   - The audit of the other interpolator inputs against `MTLFXFrameInterpolator.h` found no unit
     errors: motion scale, deltaTime, near/far, the field of view in degrees, the aspect ratio and
     the jitter are all right. The interpolator has no reactive-mask input.
   - `carmv.py` (motion magnitude in a fixed screen box) cannot see any of this: while driving, the box
     also holds the moving road.
   - WindowServer used 83-95% of the GPU (ioreg `AppUsage` `accumulatedGPUTime`) with the game closed,
     from about 22:10. The fps numbers of these runs are void.

10. **Pair pacing ("jitter").** `FramePacer::Queued` placed each slot one period after the planned
    slot. A generated image shown late therefore got a long interval, and its real image a short one,
    for example 50 ms then 16.7 ms on 60 Hz.
    - CAMetalDisplayLink drawables cannot be presented at a set time, so the only levers are which
      refresh shows which image and how the timeline advances.
    - `gta4_metalfx_frame_generation_even_pairs` (off) holds the real image as long after the
      generated one as that came after the previous real image. The hold is bounded to [h, 2h] and
      rounded to the nearest refresh.
    - Drive A/B under GPU contention, averaged over the frame-generation windows:

      | even pairs | interval sd | interval mean | shown fps |
      |---|---|---|---|
      | off | 8.0 ms | 23.6 ms | 35.6 |
      | on | 5.2 ms | 19.9 ms | 44.5 |

      The base fps differed between the runs, so this needs a clean bench before it becomes the
      default.
    - The `long=` counter (> 1.5 refreshes) counts every correct interval below 30 real fps, so watch
      the mean and sd instead.

11. **Generated frames are softer than real ones, which shimmers on near textured objects.** On a
    drive, the generated images had about 0.76-0.85 of the real images' Laplacian detail on the car
    and 0.81-0.90 on the near road; distant scenery was equal. Shown alternately, that is a
    sharpness flicker on peds, wheels and the car.
    - `gta4_metalfx_frame_generation_sharpen` (default 1.0) applies an unsharp mask to the generated
      image only, before the HUD. It is clamped to each pixel's 4-neighbour range, so it cannot ring.
      The amount ramps in with the pixel's motion: none at 1 output px, full from 9.
    - Tuned offline on the same 11 frames:

      | amount | car | road | far |
      |---|---|---|---|
      | none | 0.80 | 0.88 | 0.98 |
      | 1.0, motion-scaled | 0.86 | 1.02 | 1.06 |
      | 1.0, flat | 1.09 | 1.17 | 1.30 |

    - In game at 1.0: car 0.85, road 0.96, far 1.03; tearscore unchanged.
12. **`gta4_metalfx_frame_generation_repair_px`** (off) blends generated pixels at motion and depth
    discontinuities toward a half-step warp of the real scene. With the camera matrices on it gains
    nothing:
    - off: 0 of 18 dumps bad, average car-box p99 12.3;
    - at 16: 1 of 20 bad, average 16.4.
    It stays off.
13. **Wheel, ped and edge flicker under frame generation: interpolator colours from neither real
    image.** With frame generation on (not off, and not tied to GPU load), the generated images
    carried blocks of road under the car next to the wheels, jagged lamp-post bases, smeared hydrants
    and ped edges. Shown between clean real images they flicker. Our motion field there is right
    (smooth, under 1% untracked), and ped bones and wheel transforms update every frame (finding of
    301b286e), so these come from the interpolator at disocclusions and thin depth edges.
    - `gta4_metalfx_frame_generation_source_clamp` (default true), in the sharpen kernel: each
      generated pixel is clamped to the colour range of the 3x3 neighbourhoods it comes from, the
      previous scene half a motion step ahead and the current scene half a step back. It also bounds
      the sharpening: at 1.0 the generated images had drifted to 1.03-1.18 of the real images' detail.
    - Score (`mcscore.py`, 20 dumps of the city drive, HUD corners excluded): "foreign" pixels, more
      than 24 levels outside both sources' range there:

      | run | foreign | worst dump | mc error | detail gen/real |
      |---|---|---|---|---|
      | clamp off | 0.41% | 1.18% | 1.73 | 1.03 |
      | clamp on | 0.20% | 0.68% | 1.43 | 0.98 |

      Visually the jagged lamp post, the hydrant smear and the road blocks under the car are gone.
      Faint outlines remain where a region was hidden in one of the two real images.

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

## Hypotheses for the Metal 4 + FG collapse (status: see Findings)

Kept for the record. 1 was confirmed and fixed (3 slots); 2 was a consequence of the whole-part wait
(Findings, 3); 3 was ruled out; 4 was real but is gone after the reboot.

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

## Next steps

1. Check that the GPU is idle (no VM) and swap is near 0 (`sysctl vm.swapusage`).
2. Build the uncommitted batch and run the unit tests (`build_m4.sh`).
3. Smoke runs:
   - Metal 4 + FG on the action pad: `generated` > 0 in every `gta4-metal-display` window, `not-displayed`
     near 0, few skips, and which reason they give;
   - the denoiser guides view (`--gta4_metal_api=metal4 --gta4_metal_raytracing=ao
     --gta4_metal_raytracing_denoiser=metalfx --gta4_metal_raytracing_ao_view=guides`, MetalFX AA).
4. One interleaved bench pass on the action pad: Metal 3, Metal 3 + FG, Metal 4, Metal 4 + FG, plus the
   denoiser against native AO. Pass each setting once only (a duplicate makes CLI11 reject the command line
   and the pad never runs). Let the Air rest between runs.
   - Example: `tools/perf/route_bench.sh pad career-street tools/perf/pads/action-bench.pad NAME
     --gta4_metal_api=metal4 --gta4_metalfx_frame_generation=true --fullscreen=false`.
   - Prior result from MCLA: `MTL4FXTemporalDenoisedScaler` used for its AO cost +8 ms GPU and smoothed
     textures away. Judge ours on image quality as well as cost.
5. Commit in parts: the denoiser; the FG ring and skip reason; the proxy wait split; the presenter pacing;
   the dev pad `peds` retry.
