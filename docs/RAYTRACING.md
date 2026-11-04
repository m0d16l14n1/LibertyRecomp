# Ray tracing in the GTA IV Metal renderer

Status: stage 3. Geometry capture builds the scene every frame (stage 2). In mode `ao`, AO is traced and
denoised before the deferred lighting's global contribution and multiplied into its output. Default `off`.

Settings:
- `gta4_metal_raytracing = off | ao | shadows`. `shadows` only captures for now. It is read at startup and needs
  TAA or the MetalFX upscaler.
- `gta4_metal_raytracing_ao_view = apply | show | none`: darken the lit image; show the AO in grey instead of the
  lighting; or trace only, for timing.
- `gta4_metal_raytracing_ao_radius` (2 m), `_ao_occlusion` (0.85, AO term darkness), `_ao_strength` (0.6, share of
  the AO term applied).

Until the lighting pixel-shader override exists, AO multiplies the whole global contribution (sun, ambient
and reflection) with `_ao_strength` below 1. The override will put it on the ambient term only.

## What to trace, and why

The target is a fanless M-series Air that is already CPU-bound at 60 fps (submit 12-21 ms per
frame, GPU 13-15 ms at 1280x720 upscaled to 2560x1440 with frame generation off). Anything
ray traced has to be cheap on the GPU and close to free on the CPU.

1. **Ambient occlusion (first).** GTA IV's ambient light is flat apart from vertex-baked AO, so
   contact darkening under cars, along kerbs and in alleys is the largest visible gain per
   millisecond. Rays are short (1-3 m), so only geometry near the camera matters. We trace one
   ray per pixel at half input resolution, then denoise. Estimated GPU cost on M5: about 1 ms.
2. **Sun shadows (second).** They replace blurry, swimming cascades in the distance, but rays are
   long and need the whole view plus a sun-ward margin in the scene. They also need an override
   of the lighting pixel shader (see below). This could save the 0.9 ms shadow-map pass, but the
   net cost is roughly +1.5-3 ms. Off by default.
3. **Reflections: no.** They need material shading at hit points, which the translated title
   shaders cannot provide. GTA IV's own reflections (env maps, `refMipBlur`/`refBlend`, wet roads
   in the lighting pass) stay.

## Where it enters the frame

`deferred_lighting.fxc` does the sun, ambient and reflections in one full-screen, non-blended
pass: technique `lightShadowDirectional` (`PS_lightShadowDirectionalAmbientReflectionDry/Wet`),
or `lightNoDirectional` (`PS_lightAmbientReflectionDry/Wet`) when there is no sun. It reads
`GBufferTextureSampler0-3` and the stencil, plus `LightAmbientColor0/1`. Point and spot lights
are added afterwards as volumes. Sun shadows are cascaded, warped shadow maps
(`shadowzdir`, `shadowsmartblit`) sampled inside that pass; there is no screen-space shadow mask.

So ray tracing runs once the G-buffer is complete, just before that lighting draw:

- **AO:** if a G-buffer channel holds the per-pixel ambient scale, a full-screen multiply into
  that channel needs no shader change. Otherwise the four lighting pixel shaders get an override
  that multiplies the ambient term. To be decided from a G-buffer dump.
- **Shadows:** an override of the same pixel shaders replaces the shadow-map lookup with the
  ray-traced mask.

## Geometry

- **Capture.** `tools/metal/raytracing_capture_variants.py` makes a variant of every stock vertex
  shader. The variant runs the original translated function and writes each vertex's world
  position, from the unjittered clip position times the frame's inverse view-projection, to a
  buffer (`LibertyCaptureDraw`, buffers 6/7). The renderer draws it with rasterization disabled
  for world draws only. Skinning, wheels and foliage come out exactly as drawn, whichever
  registers hold the transforms. Vertices drawn with a remapped depth range are written as NaN,
  which a build treats as inactive.
- **Structures.** `raytracing/accel_cache.h` keeps one bottom-level structure per draw slot:
  - A slot is a geometry identity (shaders, layout, buffer generations, index range) plus the
    draw's occurrence in the frame.
  - Static slots are built once and only instanced afterwards.
  - Movers (a changed placement hash, or skinned) are recaptured and refit.
  - Topology changes rebuild.
  - Builds and refits per frame, and total bytes, have budgets with least-recently-used eviction.
  - A mover that misses the refit budget is used stale for a frame, never dropped.
- **Scene.** One instance structure is built per frame with identity transforms, because captured
  positions are already in world space. It uses indirect instance descriptors (by
  `gpuResourceID`), so no structure array travels with the build.
- **Metal 4.** Every build and refit goes through `EncodeAccelerationStructureWork`, a list of
  `AccelerationStructureOp`s. Its Metal 3 implementation uses one
  `MTLAccelerationStructureCommandEncoder`; the Metal 4 backend can route the same list to
  `MTL4ComputeCommandEncoder`. Bottom-level structures should come from one heap, so a trace pass
  makes one residency call, not one per structure.

## AO and denoising (`raytracing/shaders/rtao.metal`)

1. `rtao_trace`: half resolution, one cosine-weighted ray per pixel. Each AO pixel traces from a
   different one of its four input pixels each frame. Normals come from depth until the G-buffer
   normal encoding is confirmed (`normalMode`).
2. `rtao_temporal`: reprojects with the title's motion texture, rejects history by view distance,
   and keeps a history length per pixel.
3. `rtao_atrous`: two edge-aware passes (steps 1 and 2). Short histories are filtered harder.
4. `rtao_upsample`: depth-aware 2x2 upsample to input resolution.

`MTLFXTemporalDenoisedScaler` (macOS 26) denoises and upscales noisy *lit colour*. It needs
colour, depth, motion, diffuse and specular albedo, normals and roughness, plus the view and
projection matrices. It would replace `MTLFXTemporalScaler` rather than sit beside it. Our own
AO denoiser keeps the existing scaler and frame-generation path unchanged and also works with
MetalFX off. Trying the denoised scaler as the upscaler when ray tracing is on is a later,
measured experiment.

## Open questions (need a diagnostic run)

1. G-buffer formats and per-channel contents: the ambient-scale channel, normal encoding, depth
   format and whether depth is reversed.
2. The draws and encoders between the end of the G-buffer and the lighting draw.
3. The four lighting pixel-shader hashes.
4. World-draw count per frame and their primitive types.
5. Whether the capture projection is jittered, and where the unjittered view-projection lives.

## Tests

- `tools/tests/metal_raytracing_test.cpp`: cache keying, occurrences, budgets, eviction and
  abandoned builds.
- `tools/tests/test_raytracing_capture_variants.py`: the variant contract and refusals. Set
  `LIBERTY_METAL_SOURCES` to also run it over the generated source corpus.
