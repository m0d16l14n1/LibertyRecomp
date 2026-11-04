# Metal 4 in the GTA IV Metal renderer

Status 2026-11-04 (15-inch M5 MacBook Air, macOS 27.2). The renderer (`glue/rexglue-sdk-main/src/graphics/gta4_metal`)
is Metal 3 throughout. Metal 3 and Metal 4 live side by side on the same device: Metal 3 pipelines
work on Metal 4 encoders and the other way round, so Metal 4 can be adopted one part at a time.
The device summary line (`gta4-metal: device summary ... metal4=yes/no`) says whether a Mac offers it
(every Apple GPU on macOS 26+ does).

## What runs today

| Area | Today (Metal 3) | Metal 4 counterpart |
|---|---|---|
| Queue and command buffers | one `MTLCommandQueue` (`ui/metal/context.mm`), a fresh command buffer per submission, `addCompletedHandler` | `MTL4CommandQueue`, reusable `MTL4CommandBuffer` + `MTL4CommandAllocator` per frame in flight, `MTL4CommitFeedback` |
| Binding | per-draw `setVertexBuffer`/`setFragmentBuffers` of an argument buffer (Tier 2), `setVertexBytes`/`setFragmentBytes` for push constants (2 per draw), `useResources` for the textures the argument buffer names (~730 batched calls a frame) | `MTL4ArgumentTable` (GPU addresses and resource IDs), no `set*Bytes` (a per-frame bump allocator instead), `MTLResidencySet` instead of `useResource` |
| Hazards | every resource `MTLHazardTrackingModeTracked`; Metal orders encoders by the resources they declare | no tracking: explicit `MTL4` barriers (stage to stage) and queue-scoped fences |
| Copies | `MTLBlitCommandEncoder` (uploads, resolves, readbacks) | blits on `MTL4ComputeCommandEncoder` |
| Pipelines | `newRenderPipelineStateWithDescriptor:completionHandler:` with an `MTLBinaryArchive` (`PipelineStore`, `recipes-v1.bin`, a bundled seed); scene draws wait at most 4 ms a frame for a compile | `MTL4Compiler` (sync or `MTL4CompilerTask`), flexible pipelines specialised at runtime, `MTL4Archive` + `MTL4PipelineDataSetSerializer` |
| Upscaling, frame generation | `MTLFXTemporalScaler`, `MTLFXFrameInterpolator` | `MTL4FXTemporalScaler`, `MTL4FXFrameInterpolator` (need Metal 4 command buffers; same algorithms) |

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
- **Flexible pipelines** were checked against the recorded recipes: 727 recipes collapse to 624 when
  colour formats, write masks and blending are left open, 14% fewer compiles. With the archive and
  the bundled seed, first-sight compiles are already rare (0-2 frames over 4 ms per 3-minute drive,
  BACKLOG 89), so moving to `MTL4Compiler` for this alone is not worth the risk.
- **Known fault:** on macOS 27.2, `MTL4CompilerTask` (asynchronous builds) with a pipeline data set
  serializer attached faulted in another port; synchronous `MTL4Compiler` calls on a GCD queue worked.
  Any move to `MTL4Compiler` uses synchronous calls on our own queue.

## Plan, in order

1. **Residency set on the Metal 3 queue** (`[queue addResidencySet:]`, macOS 15+): the texture cache,
   buffer cache and upload arena join one `MTLResidencySet`, committed once per frame. `useResources`
   then stays only where it carries a hazard: textures written in the same command buffer (render
   targets, resolves, uploads still in flight). Needs the texture cache to know whether an upload's
   command buffer has completed. Measurable on its own (submit ms, `residency-calls=` in the stats line).
2. **Transient constant allocator**: push constants (`setVertexBytes`/`setFragmentBytes`, 2 per draw)
   move to a per-frame bump buffer bound by offset. Also a prerequisite for 3.
3. **Metal 4 command model for the title passes**: `MTL4CommandQueue`, allocators per frame in flight,
   argument tables per encoder thread, barriers instead of tracking. The hard part is the barrier
   placement for the resolve chain (28 resolves a frame, deferred resolves, BACKLOG 17): every
   writer-then-reader pair across passes needs a barrier, and a missing one is a race that shows as
   flicker. Validate with `MTL_DEBUG_LAYER=1` and shader validation on the bench routes.
4. **MetalFX on Metal 4** (`MTL4FXTemporalScaler`, `MTL4FXFrameInterpolator`) once 3 has Metal 4
   command buffers at the end of the frame.
5. **Pipelines** last, and only if first-sight compiles come back: `MTL4Compiler` (synchronous, GCD),
   flexible pipelines for the colour-format variants, `MTL4Archive`.

Each step is measured on `tools/perf/route_bench.sh pad career-street tools/perf/pads/city-drive.pad`
(GPU-bound with frame generation) and on a CPU-bound run (frame generation off, or an episode
downtown), interleaved with rests on the fanless Air.
