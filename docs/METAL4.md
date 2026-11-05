# Metal 4 in the GTA IV Metal renderer

Status 2026-11-05 (15-inch M5 MacBook Air, macOS 27.2). The renderer (`glue/rexglue-sdk-main/src/graphics/gta4_metal`)
is Metal 3 throughout. Metal 3 and Metal 4 live side by side on the same device: Metal 3 pipelines
work on Metal 4 encoders and the other way round, so Metal 4 can be adopted one part at a time.
The device summary line (`gta4-metal: device summary ... metal4=yes/no`) says whether a Mac offers it
(every Apple GPU on macOS 26+ does).

## What runs today

| Area | Today (Metal 3) | Metal 4 counterpart |
|---|---|---|
| Queue and command buffers | one `MTLCommandQueue` (`ui/metal/context.mm`), a fresh command buffer per submission, `addCompletedHandler` | `MTL4CommandQueue`, reusable `MTL4CommandBuffer` + `MTL4CommandAllocator` per frame in flight, `MTL4CommitFeedback` |
| Binding | per-draw `setVertexBuffer`/`setFragmentBuffers` of an argument buffer (Tier 2), `setVertexBytes`/`setFragmentBytes` for push constants (2 per draw), `useResources` for the textures the argument buffer names (~730 batched calls a frame) | `MTL4ArgumentTable` (GPU addresses and resource IDs), no `set*Bytes` (a per-frame bump allocator instead), `MTLResidencySet` instead of `useResource` |
| Hazards | every resource `MTLHazardTrackingModeTracked`; Metal orders encoders by the resources they declare | no tracking: explicit `MTL4` barriers (stage to stage) and queue-scoped fences. `gta4_metal4_render_barrier` picks full, fragment-only or tracked render-pass barriers; copies take an encoder barrier only when they touch a resource another copy in the same encoder read or wrote |
| Copies | `MTLBlitCommandEncoder` (uploads, resolves, readbacks) | blits on `MTL4ComputeCommandEncoder`; one encoder for a batch of resolves, with dependency-free copies overlapping |
| Pipelines | `newRenderPipelineStateWithDescriptor:completionHandler:` with an `MTLBinaryArchive` (`PipelineStore`, `recipes-v1.bin`, a bundled seed); scene draws wait at most 4 ms a frame for a compile | `MTL4Compiler` (sync or `MTL4CompilerTask`), flexible pipelines specialised at runtime, `MTL4Archive` + `MTL4PipelineDataSetSerializer` |
| Upscaling, frame generation | `MTLFXTemporalScaler`, `MTLFXFrameInterpolator` | `MTL4FXTemporalScaler`, `MTL4FXFrameInterpolator` (need Metal 4 command buffers; same algorithms) |

## Switching (gta4_metal_api)

`gta4_metal_api = metal3` (default) or `metal4`. With metal4 the shared `MetalContext::queue` is a
proxy (`ui/metal/metal4_queue.mm`) that speaks the Metal 3 protocols, so every pass encodes as
before while the work runs on Metal 4: `MTL4CommandQueue`, pooled `MTL4CommandAllocator`s and
command buffers, `MTL4ArgumentTable`s (vertex, fragment, compute) fed GPU addresses and resource
IDs, a per-command-buffer transient buffer instead of `set*Bytes`, a per-command-buffer
`MTLResidencySet` holding every bound or declared resource (retained until commit feedback) or,
with `gta4_metal4_residency = persistent`, one queue-level set; new allocations join either set in
one `addAllocations:count:` call per command buffer rather than one call each, blits on
`MTL4ComputeCommandEncoder`, a queue barrier at each encoder start plus encoder barriers only
between copies that overlap and between serial dispatches, commit feedback for completion handlers,
and queue waits/signals for events and drawables (the layer's residency set joins the queue).
`gta4-metal4` reports the counters behind those choices: `barriers=`, `copy-barriers=`,
`copy-independent=`, `fragment-barriers=`, `vertex-barriers=`, `resident-adds=`,
`resident-batches=`, `evicted=` and `residency-commits=`. `gta4_metal4_pass_timing` adds GPU
milliseconds per encoder label.
MetalFX runs natively: the temporal scaler, the frame interpolator and (with
`gta4_metal_raytracing_denoiser = metalfx`) the denoised scaler are their `MTL4FX` objects, made from
the queue's `MTL4Compiler` and encoded into the open `MTL4CommandBuffer` by `EncodeMetal4`. An empty
encoder waits for earlier queue work and updates the object's own fence, and the next encoder's queue
barrier orders what reads the output. Each object has its own fence. If the device has no `MTL4FX`
interpolation, frame generation falls back to the Metal 3 hop (`EncodeMetal3`: commit, side Metal 3
queue, `MTLEvent`). Ray-tracing acceleration-structure builds no longer hop: `EncodeMetal4Compute`
opens a compute encoder in the open Metal 4 command buffer and builds, refits and instances through
`MTL4AccelerationStructureDescriptor`s (`raytracing/raytracing.mm`). So `metal3-hops` on the
`gta4-metal4` line is 0 on macOS 26+ even with ray tracing on; only the absent-`MTL4FX` fallback
hops. `gta4-metal-framegen frame= native-mtl4fx= metal3-hop=` counts frame-generation encodes by
path. The present thread's display queue (frame generation) is a plain Metal 3 queue that only
presents, so it adds no hops.
Without Metal 4 (macOS < 26 or the GPU family) the game logs it and stays on metal3.
First drive (2026-11-04): the city route renders identically to metal3, no unrecognised selectors.
`rex-metal4-proxy-copy-test` covers the copy selectors and the barrier policy; the
acceleration-structure path is covered by `rex-metal-raytracing-structures-test` on both queues.

## What the measurements say

- **CPU submission** is where Metal 4 pays off. TBoGT downtown (BACKLOG 75): render thread busy 95%,
  64% of it in our Metal submission (`State::Draw` 47%, constant uploads 9%, encoder creation 5%);
  per frame about 9,000 state calls, 8 MB of constants, 2,000 fresh constant banks, ~730
  `useResources` batches. Argument tables, residency sets and no per-draw `set*Bytes` remove most
  of the per-draw driver work. This matters when the game is CPU-bound: the episodes downtown, a
  60 fps target without frame generation, ProMotion panels.
- **GPU-bound cases gain nothing** from the command model: shaders, MetalFX and frame generation
  cost the same. The career city drive with frame generation (BACKLOG 88) is GPU-bound (scene GPU
  p50 19.6 ms, render thread 53% busy while paced), so Metal 4 would not change its frame rate.
- **Copy barriers:** dependency tracking keeps the blit-stage barriers where the resolve chain needs
  them and drops the rest. In the career city drive (`gta4_metal_api=metal4`, stats line at frame
  35,700) 137,146 copies needed 9,578 barriers (7%) while 127,568 were independent; before this
  every copy after the first in an encoder took one. `rex-metal4-proxy-copy-test` checks the policy.
- **A/B against metal3** (career city drive, MetalFX TAA 1280x720 → 2560x1440, frame generation off,
  three interleaved 180 s runs, 75 s rests, fanless Air): both are GPU-bound at 25-43 fps per
  window. City mean metal3 29.5 fps / submit 22.9 ms, metal4 31.2 fps / 22.2 ms. Thermal order
  (m3, m4, m3) and different traffic between runs put this within noise; there is no frame-rate
  regression. A CPU-bound run (an episode downtown) is still needed before the default changes.
- **Flexible pipelines** were checked against the recorded recipes: 727 recipes collapse to 624 when
  colour formats, write masks and blending are left open, 14% fewer compiles. With the archive and
  the bundled seed, first-sight compiles are already rare (0-2 frames over 4 ms per 3-minute drive,
  BACKLOG 89), so moving to `MTL4Compiler` for this alone is not worth the risk.
- **Known fault:** on macOS 27.2, `MTL4CompilerTask` (asynchronous builds) with a pipeline data set
  serializer attached faulted in another port; synchronous `MTL4Compiler` calls on a GCD queue worked.
  Any move to `MTL4Compiler` uses synchronous calls on our own queue.

## Where the plan stands

Done:

1. **Transient constant allocator**: push constants (`setVertexBytes`/`setFragmentBytes`, 2 per draw)
   go to a per-frame bump buffer bound by address. Prerequisite for 2.
2. **Metal 4 command model for the title passes**: `MTL4CommandQueue`, allocators per frame in
   flight, argument tables per encoder thread, barriers instead of tracking, one batch encoder for
   consecutive resolves, dependency-aware copy barriers, and batched residency adds. Validated with
   `MTL_DEBUG_LAYER=1` and shader validation on the GPU tests; the resolve chain (28 resolves a
   frame, deferred resolves, BACKLOG 17) is why the barrier modes exist.
3. **MetalFX on Metal 4** (`MTL4FXTemporalScaler`, `MTL4FXFrameInterpolator`,
   `MTL4FXTemporalDenoisedScaler`): done, see Switching. The denoised scaler is Metal 4 only
   (docs/RAYTRACING.md).

Next:

4. **A/B against metal3** on the career city route and a CPU-bound run, then decide whether
   `gta4_metal_api` defaults to metal4. Until then it stays metal3.
5. **Residency set on the Metal 3 queue** (`[queue addResidencySet:]`, macOS 15+): only worth doing if
   metal3 remains the default. The texture cache, buffer cache and upload arena would join one
   `MTLResidencySet`, committed once per frame; `useResources` then stays only where it carries a
   hazard (textures written in the same command buffer). Needs the texture cache to know whether an
   upload's command buffer has completed.
6. **Pipelines** last, and only if first-sight compiles come back: `MTL4Compiler` (synchronous, GCD),
   flexible pipelines for the colour-format variants, `MTL4Archive`. The known fault above rules out
   `MTL4CompilerTask` with a serializer.

Each step is measured on `tools/perf/route_bench.sh pad career-street tools/perf/pads/city-drive.pad`
(GPU-bound with frame generation) and on a CPU-bound run (frame generation off, or an episode
downtown), interleaved with rests on the fanless Air. Keep the window in front: a covered window is
paced at 2 fps and invalidates the run (BACKLOG 60).
