#include "renderer_state.h"
#include "gpu_pass_timer.h"
#include "../../ui/metal/guest_output_context.h"
#include "../../ui/metal/metal4_queue.h"
#include <rex/cvar.h>
#include <rex/diagnostics/policy.h>
#include <rex/logging.h>

#include <Foundation/Foundation.h>

#include <algorithm>
#include <cstdio>
#include <vector>
#include <bit>
#include <chrono>
#include <filesystem>
#include <iterator>

REXCVAR_DECLARE(bool, gta4_temporal_late_constants_diag);  // temporal/live.mm
REXCVAR_DEFINE_BOOL(gta4_metalfx_frame_generation_half_rate, true, "GPU",
                    "MetalFX frame generation: draw real frames at half the display refresh, so every "
                    "one gets its generated midpoint and the screen shows an even rate");
REXCVAR_DEFINE_STRING(gta4_metalfx_frame_generation_dump, "", "GPU/Diagnostics",
                      "Folder for MetalFX frame generation checks: every 120th generated frame and the real "
                      "frame after it, as PPM, at most 6 pairs (empty = off)");
REXCVAR_DEFINE_UINT32(gta4_metalfx_frame_generation_dump_every, 120, "GPU/Diagnostics",
                      "Frame generation dump: every Nth generated frame (at least 2)");
REXCVAR_DEFINE_UINT32(gta4_metalfx_frame_generation_dump_max, 6, "GPU/Diagnostics",
                      "Frame generation dump: at most this many generated frames per run");
REXCVAR_DEFINE_BOOL(gta4_temporal_diagnostics, false, "GPU/Diagnostics",
                    "Log the exact temporal AA contract at startup, resets, and every 60 frames");
REXCVAR_DEFINE_STRING(gta4_temporal_snapshot, "", "GPU/Diagnostics",
                      "Folder for bounded temporal AA input/output snapshots (empty = off)");
REXCVAR_DEFINE_UINT32(gta4_temporal_snapshot_every, 120, "GPU/Diagnostics",
                      "Temporal snapshot: capture every Nth accepted frame");
REXCVAR_DEFINE_UINT32(gta4_temporal_snapshot_max, 4, "GPU/Diagnostics",
                      "Temporal snapshot: maximum captures for one output folder");
REXCVAR_DEFINE_UINT32(gta4_temporal_snapshot_start, 0, "GPU/Diagnostics",
                      "Temporal snapshot: first temporal sequence number to capture (0 = any); with "
                      "_every = 1 this captures consecutive frames, for frame-to-frame stability");

namespace rex::graphics::gta4_metal {
namespace {

bool PrepareDumpPath(const std::string& path) {
  std::error_code error;
  const auto parent = std::filesystem::path(path).parent_path();
  return parent.empty() || std::filesystem::create_directories(parent, error) ||
         std::filesystem::is_directory(parent, error);
}

// Copies a finished frame (RGBA16Float, display-perceptual) into a shared
// buffer and writes it as an 8-bit PPM once the command buffer completes.
void DumpFrameImage(id<MTLCommandBuffer> commands, id<MTLTexture> image, std::string path) {
  if (!image || image.pixelFormat != MTLPixelFormatRGBA16Float || !PrepareDumpPath(path)) return;
  const NSUInteger w = image.width, h = image.height, pitch = w * 8;
  auto buffer = [commands.device newBufferWithLength:pitch * h options:MTLResourceStorageModeShared];
  auto blit = [commands blitCommandEncoder];
  if (!buffer || !blit) { [blit endEncoding]; return; }
  blit.label = @"Liberty frame generation dump";
  [blit copyFromTexture:image sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
             sourceSize:MTLSizeMake(w, h, 1) toBuffer:buffer destinationOffset:0
        destinationBytesPerRow:pitch destinationBytesPerImage:pitch * h];
  [blit endEncoding];
  [commands addCompletedHandler:^(id<MTLCommandBuffer> done) {
    if (done.status != MTLCommandBufferStatusCompleted) return;
    std::vector<uint8_t> rgb(size_t(w) * h * 3);
    const auto* half = static_cast<const __fp16*>(buffer.contents);
    for (size_t i = 0; i < size_t(w) * h; ++i)
      for (size_t c = 0; c < 3; ++c)
        rgb[i * 3 + c] = uint8_t(std::clamp(float(half[i * 4 + c]), 0.0f, 1.0f) * 255.0f + 0.5f);
    if (FILE* f = std::fopen(path.c_str(), "wb")) {
      std::fprintf(f, "P6\n%lu %lu\n255\n", (unsigned long)w, (unsigned long)h);
      std::fwrite(rgb.data(), 1, rgb.size(), f);
      std::fclose(f);
    }
  }];
}

// Raw texel dump for offline analysis of the frame generation inputs (motion RG16Float, depth and
// history depth R32Float): "<w> <h> <bytes per texel>\n" then the rows.
void DumpRawTexture(id<MTLCommandBuffer> commands, id<MTLTexture> image, std::string path) {
  if (!image || !PrepareDumpPath(path)) return;
  NSUInteger texel = 0;
  switch (image.pixelFormat) {
    case MTLPixelFormatRG16Float: case MTLPixelFormatR32Float: texel = 4; break;
    case MTLPixelFormatR16Float: texel = 2; break;
    case MTLPixelFormatR8Unorm: texel = 1; break;
    default: return;
  }
  const NSUInteger w = image.width, h = image.height, pitch = w * texel;
  auto buffer = [commands.device newBufferWithLength:pitch * h options:MTLResourceStorageModeShared];
  auto blit = [commands blitCommandEncoder];
  if (!buffer || !blit) { [blit endEncoding]; return; }
  blit.label = @"Liberty frame generation input dump";
  [blit copyFromTexture:image sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
             sourceSize:MTLSizeMake(w, h, 1) toBuffer:buffer destinationOffset:0
        destinationBytesPerRow:pitch destinationBytesPerImage:pitch * h];
  [blit endEncoding];
  [commands addCompletedHandler:^(id<MTLCommandBuffer> done) {
    if (done.status != MTLCommandBufferStatusCompleted) return;
    if (FILE* f = std::fopen(path.c_str(), "wb")) {
      std::fprintf(f, "%lu %lu %lu\n", (unsigned long)w, (unsigned long)h, (unsigned long)texel);
      std::fwrite(buffer.contents, 1, pitch * h, f);
      std::fclose(f);
    }
  }];
}

void DumpTemporalManifest(id<MTLCommandBuffer> commands, const temporal::Live& live,
                          uint32_t submitted_frame, std::string path) {
  if (!PrepareDumpPath(path)) return;
  const auto& d = live.AntiAliasingState();
  const auto texture = [](id<MTLTexture> image) {
    return image ? fmt::format("{}x{} format={} bytes={}", image.width, image.height,
                               uint32_t(image.pixelFormat), image.allocatedSize)
                 : std::string("missing");
  };
  const std::string manifest = fmt::format(
      "frame={}\nsequence={}\nmethod={}\npath={}\naccepted={}\nencoded={}\nreset={}\n"
      "reason={}\ninput={}x{}\noutput={}x{}\nsource_jitter={},{}\neffective_jitter={},{}\n"
      "motion_scale={},{}\ndepth_reversed={}\nnear={}\nfar={}\nfov={}\naspect={}\n"
      "pre_exposure={}\nexposure={}\nexposure_texture={}\ncamera_cut={}\nadopted_camera={}\n"
      "background_history={}\ncamera_transform={}\nworld_draws={}\nhistory_draws={}\n"
      "reactive_draws={}\njittered_draws={}\nscene_color={}\nmotion={}\ndepth={}\n"
      "previous_depth={}\nreactive={}\nexposure_input={}\nreconstructed_scene={}\n",
      submitted_frame, d.sequence, d.method == temporal::Method::kMetalFx ? "metalfx" : "taa",
      d.metal4 ? "metal4" : "metal3", d.accepted, d.encoded, d.reset,
      d.reason.empty() ? "continuous" : d.reason, d.input_width, d.input_height,
      d.output_width, d.output_height, d.source_jitter[0], d.source_jitter[1],
      d.effective_jitter[0], d.effective_jitter[1], d.motion_scale[0], d.motion_scale[1],
      d.depth_reversed, d.near_plane, d.far_plane, d.field_of_view, d.aspect,
      d.pre_exposure, d.exposure, d.exposure_texture, live.metadata.camera_cut,
      live.adopted_camera, live.BackgroundHistoryValid(), live.CameraTransformValid(),
      live.world_draws, live.history_draws, live.reactive_draws, live.jittered_draws,
      texture(live.inputs.color), texture(live.inputs.motion), texture(live.inputs.depth),
      texture(live.inputs.previous_depth),
      texture(live.reactive_snapshot ? live.reactive_snapshot : live.inputs.reactive),
      texture(live.inputs.exposure), texture(live.final_scene));
  [commands addCompletedHandler:^(id<MTLCommandBuffer> done) {
    if (done.status != MTLCommandBufferStatusCompleted) return;
    if (FILE* file = std::fopen(path.c_str(), "wb")) {
      std::fwrite(manifest.data(), 1, manifest.size(), file);
      std::fclose(file);
    }
  }];
}

// A fanless Mac slows its CPU and GPU after some minutes of play; without this the log shows only
// the frame times rising. Serious and critical are warnings, so the quiet errors log has them too.
void LogThermalStateChange(uint32_t frame) {
  static NSProcessInfoThermalState last = NSProcessInfoThermalStateNominal;
  const NSProcessInfoThermalState state = NSProcessInfo.processInfo.thermalState;
  if (state == last) return;
  last = state;
  static constexpr const char* kNames[] = {"nominal", "fair", "serious", "critical"};
  const char* name = size_t(state) < std::size(kNames) ? kNames[state] : "unknown";
  if (state >= NSProcessInfoThermalStateSerious)
    REXLOG_WARN("gta4-metal: thermal state {} at frame {}; macOS is limiting CPU and GPU speed", name, frame);
  else
    REXLOG_INFO("gta4-metal: thermal state {} at frame {}", name, frame);
}

}  // namespace

bool Renderer::State::Present(const gta4_native::PresentCommand& present, std::string& error) {
  struct PresentTimer {
    State& s; uint32_t frame; std::chrono::steady_clock::time_point begin = std::chrono::steady_clock::now();
    ~PresentTimer() {
      if (s.frame_log_path.empty()) return;
      s.frame_present_ns += uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
          std::chrono::steady_clock::now() - begin).count());
      s.RecordFrameSample(frame);
    }
  } present_timer{*this, present.submitted_frame};
  gpu_pass_timer::FrameEnd();
  if (!present.frontbuffer_texture || !present.width || !present.height ||
      present.width > 16384 || present.height > 16384) {
    error = "Invalid title frontbuffer publication"; return false;
  }
  if (!Begin(error) || !MaterializePendingClears(error)) return false;
  auto source = PrepareTexture(present.frontbuffer_texture,
      std::bit_cast<xenos::xe_gpu_texture_fetch_t>(present.frontbuffer_fetch), error);
  if (!source || !source->initialized || source->image.textureType != MTLTextureType2D ||
      source->image.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) {
    if (error.empty()) error = "Title frontbuffer is not a ready color image"; return false;
  }
  ProfileRead(source,2);
  if (!SettlePendingResolves(source.get(), error)) return false;
  FireSnapshot(source->image,"present-before-aa",present.frontbuffer_texture,false,true);
  // One protected command recording contains the scene AND its mailbox copy.
  // RefreshGuestOutput invokes its writer before publishing or waiting for
  // admission. Commit there, so two slots cover two complete game frames rather
  // than a scene/copy pair. Readbacks keep their separate completion boundaries.
  EndRender();
  commands.label = [NSString stringWithFormat:@"Liberty game frame %u batch %llu",
      present.submitted_frame, submitted];
  const bool first_scene = !traced_scene && target_observations[size_t(gta4_native::RenderPhase::kSceneToGBuffer)].draws;
  const bool trace_extent = rex::diagnostics::IsEnabled(rex::diagnostics::Category::kNativeTrace) &&
      (first_scene || present.submitted_frame <= 3 || present.submitted_frame % 120 == 0);
  if (trace_extent) {
    const auto prep = resources.preparation_statistics();
    REXLOG_INFO("gta4-metal-preparation frame={} queued={} ready={} waits={} inline={} staging-allocations={} staging-reuses={} pending-bytes={} staging-bytes={} pipeline-ready={} pipeline-waits={}",
        present.submitted_frame, prep.queued, prep.ready, prep.waited, prep.inline_decodes,
        prep.staging_allocations, prep.staging_reuses, prep.pending_bytes, prep.staging_bytes,
        pipeline_ready, pipeline_waits);
    REXLOG_INFO("gta4-metal-cache frame={} pipelines-created={} pipeline-entries={} layout-definitions={} layout-reuses={} render-passes={}",
        present.submitted_frame, pipeline_creations, pipelines.size(), declaration_definitions, declaration_reuses, render_passes_created);
    REXLOG_INFO("gta4-metal-resolution point=title frame={} texture={:08X} generation={} source={}x{} logical={}x{} display={}x{} aa={} draws={}",
        present.submitted_frame, present.frontbuffer_texture, source->generation, source->image.width, source->image.height,
        present.width, present.height, present.display_width, present.display_height, uint32_t(anti_aliasing), frame_draws);
    for (size_t phase = 0; phase < target_observations.size(); ++phase) {
      const auto& item = target_observations[phase];
      if (!item.draws) continue;
      REXLOG_INFO("gta4-metal-resolution point=draw frame={} phase={} draws={} color={:08X} depth={:08X} logical={}x{} physical={}x{} depth-physical={}x{} samples={} viewport={},{},{},{} projection-scale={},{}",
          present.submitted_frame, phase, item.draws, item.color, item.depth, item.logical_width, item.logical_height,
          item.width, item.height, item.depth_width, item.depth_height, item.samples,
          item.viewport[0], item.viewport[1], item.viewport[2], item.viewport[3], environment.projection_matrix[0], environment.projection_matrix[5]);
    }
    for (size_t reason = 0; reason < pass_breaks.size(); ++reason)
      if (pass_breaks[reason]) REXLOG_INFO("gta4-metal-pass-break frame={} mask={} count={}",
          present.submitted_frame, reason, pass_breaks[reason]);
    const auto buffers = resources.buffer_cache_statistics();
    REXLOG_INFO("gta4-metal-buffer-cache frame={} captured={} entries={} evictions={} validations={} validation-skips={} validation-mismatches={}",
        present.submitted_frame, buffers.captured_bytes, buffers.entries, buffers.evictions,
        buffers.validations, buffers.validation_skips, buffers.validation_mismatches);
    if (first_scene) traced_scene = true;
  }
  auto& temporal=temporal_scene;
  const bool scene_output=temporal.active&&temporal.HasSceneOutput()&&temporal.ui_active&&temporal.final_scene;
  const bool temporal_output=scene_output&&temporal.ui_exact;
  const bool generation_enabled=temporal_output&&temporal.resolved&&temporal.frame_generation&&rex::cvar::GetFlagByName("gta4_present_mode")!="immediate";
  temporal::InterpolationOutput generated_pair;
  if(generation_enabled){
    std::string generation_error;
    // With the camera fill, every pixel without object motion gets the camera's, so
    // the coverage check (a GPU readback and a full wait for the GPU) is not needed.
    if (temporal.NeedsMotionCoverage() &&
        !rex::cvar::Query<bool>("gta4_metalfx_frame_generation_camera_motion")) {
      // Interpolation has no reactive mask: validate this frame's GPU-written
      // motion before admitting it to MetalFX history. AA-only and known
      // incomplete frames retain the normal asynchronous submission path.
      if (temporal.ValidateMotionCoverage(commands, generation_error)) {
        if (!Flush(true, error) || !Begin(error)) return false;
      } else {
        REXLOG_WARN("gta4-metal-frame-generation: frame={} coverage validation failed: {}",
                    present.submitted_frame, generation_error);
      }
    }
    if(!temporal.Generate(commands,generated_pair,generation_error))REXLOG_WARN("gta4-metal-frame-generation: frame={} skipped: {}",present.submitted_frame,generation_error);
    if(generated_pair.real&&!temporal.Compose(commands,temporal.final_scene,generated_pair.real,error))return false;
    if(generated_pair.generated&&!temporal.ComposeInPlace(commands,generated_pair.generated,error))return false;
    if(generated_pair.generated){
      static uint64_t generated_count=0,dumped=0;
      static std::string dumped_folder;
      const auto folder=rex::cvar::GetFlagByName("gta4_metalfx_frame_generation_dump");
      // A new folder (the dev pad's `set`) starts a new run of dumps, as the temporal snapshot does.
      if(folder!=dumped_folder){dumped_folder=folder;dumped=0;generated_count=0;}
      ++generated_count;
      temporal.snapshot_reactive=!folder.empty();
      const uint64_t every=std::max<uint32_t>(2,REXCVAR_GET(gta4_metalfx_frame_generation_dump_every));
      const uint64_t most=REXCVAR_GET(gta4_metalfx_frame_generation_dump_max);
      // The real frame before the generated one, so each check has both neighbours.
      if(!folder.empty()&&generated_count%every==every-1&&dumped<most)
        DumpFrameImage(commands,generated_pair.real,fmt::format("{}/framegen_{}_before.ppm",folder,present.submitted_frame+1));
      if(!folder.empty()&&generated_count%every==0&&dumped<most){
        ++dumped;
        DumpFrameImage(commands,generated_pair.generated,fmt::format("{}/framegen_{}_generated.ppm",folder,present.submitted_frame));
        DumpFrameImage(commands,generated_pair.real,fmt::format("{}/framegen_{}_real.ppm",folder,present.submitted_frame));
        DumpRawTexture(commands,temporal.inputs.motion,fmt::format("{}/framegen_{}_motion.raw",folder,present.submitted_frame));
        DumpRawTexture(commands,temporal.inputs.rigid_motion,fmt::format("{}/framegen_{}_rigid.raw",folder,present.submitted_frame));
        DumpRawTexture(commands,temporal.inputs.previous_depth,fmt::format("{}/framegen_{}_history.raw",folder,present.submitted_frame));
        DumpRawTexture(commands,temporal.inputs.depth,fmt::format("{}/framegen_{}_depth.raw",folder,present.submitted_frame));
        // Generate has already consumed this frame's live mask, and later scene
        // draws cannot occur after presentation. Dump it directly so framegen
        // captures diagnose the exact deformation/disocclusion input used.
        DumpRawTexture(commands,temporal.inputs.reactive,fmt::format("{}/framegen_{}_reactive.raw",folder,present.submitted_frame));
      }
    }
  }
  if (temporal_output && temporal.resolved) {
    static std::string snapshot_folder;
    static uint64_t snapshot_count = 0;
    const std::string folder = rex::cvar::GetFlagByName("gta4_temporal_snapshot");
    if (folder != snapshot_folder) {
      snapshot_folder = folder;
      snapshot_count = 0;
    }
    const uint64_t every = std::max<uint32_t>(1, REXCVAR_GET(gta4_temporal_snapshot_every));
    const uint64_t most = REXCVAR_GET(gta4_temporal_snapshot_max);
    const uint64_t start = REXCVAR_GET(gta4_temporal_snapshot_start);
    if (!folder.empty() && temporal.metadata.sequence >= start &&
        (temporal.metadata.sequence - start) % every == 0 && snapshot_count < most) {
      ++snapshot_count;
      const std::string prefix = fmt::format("{}/temporal_{}", folder, present.submitted_frame);
      DumpFrameImage(commands, temporal.inputs.color, prefix + "_scene.ppm");
      DumpRawTexture(commands, temporal.inputs.motion, prefix + "_motion.raw");
      DumpRawTexture(commands, temporal.inputs.depth, prefix + "_depth.raw");
      DumpRawTexture(commands, temporal.inputs.previous_depth, prefix + "_previous_depth.raw");
      DumpRawTexture(commands,
                     temporal.reactive_snapshot ? temporal.reactive_snapshot : temporal.inputs.reactive,
                     prefix + "_reactive.raw");
      DumpRawTexture(commands, temporal.inputs.exposure, prefix + "_exposure.raw");
      DumpFrameImage(commands, temporal.final_scene, prefix + "_reconstructed.ppm");
      DumpTemporalManifest(commands, temporal, present.submitted_frame, prefix + "_manifest.txt");
    }
  }
  // An unsupported affine HUD still exists in the original guest composite.
  // Preserve it through the normal final transfer at the requested extent;
  // scene jitter was removed before the composite and must not be applied here.
  const uint32_t output_width=scene_output?temporal.config.output_width:present.width;
  const uint32_t output_height=scene_output?temporal.config.output_height:present.height;
  bool published = true;
  if (presenter) {
    ui::GuestOutputProvenance provenance{};
    provenance.frame_rate_limit = rex::cvar::Query<uint32_t>("gta4_frame_limit");
    provenance.producer_backpressure = present.device != 0;
    provenance.paired_presentation=generated_pair.generated!=nil;
    // Frame generation shows each real frame with a generated midpoint, so real frames have to
    // come at most at half the refresh rate: faster, a real frame arrives while the previous
    // pair is still on screen, its generation is skipped and it goes out alone. The cadence
    // then keeps switching between pairs and single frames (35-75 long intervals per 10 s at
    // ~39 real fps on a 60 Hz panel), which reads as judder. Pace real frames to half the
    // refresh whenever generation is on, paired this frame or not.
    if(generation_enabled&&REXCVAR_GET(gta4_metalfx_frame_generation_half_rate)){
      const uint32_t refresh=presenter->DisplayRefreshRate();
      const uint32_t half=std::max(1u,(refresh?refresh:60u)/2);
      provenance.frame_rate_limit=provenance.frame_rate_limit?std::min(provenance.frame_rate_limit,half):half;
    }
    if(provenance.paired_presentation&&provenance.frame_rate_limit)provenance.frame_rate_limit=std::min(1000u,provenance.frame_rate_limit*2);
    provenance.title_present_id = present.diagnostic_present_id;
    provenance.selected_generation = source->generation;
    provenance.submitted_frame = present.submitted_frame;
    provenance.selected_texture = present.frontbuffer_texture;
    provenance.present_origin = present.diagnostic_origin;
    provenance.guest_caller = present.diagnostic_guest_caller;
    provenance.diagnostic_trace = present.diagnostic_trace != 0;
    provenance.tv_session_id = present.diagnostic_tv_session_id;
    provenance.tv_final_sequence = present.diagnostic_tv_final_sequence;
    provenance.tv_movie_sequence = present.diagnostic_tv_movie_sequence;
    provenance.tv_rect_sequence = present.diagnostic_tv_rect_sequence;
    provenance.tv_bink_sequence = present.diagnostic_tv_bink_sequence;
    provenance.tv_bink_result = present.diagnostic_tv_bink_result;
    published = presenter->RefreshGuestOutput(output_width, output_height,
        present.display_width ? present.display_width : present.width,
        present.display_height ? present.display_height : present.height,
        [&](ui::Presenter::GuestOutputRefreshContext& output) {
          auto& metal = static_cast<ui::metal::MetalGuestOutputRefreshContext&>(output);
          if (trace_extent) REXLOG_INFO("gta4-metal-resolution point=mailbox frame={} source={}x{} destination={}x{}",
              present.submitted_frame, source->image.width, source->image.height, metal.texture().width, metal.texture().height);
          // The mailbox stores filtered FP16 values even for an 8-bit guest.
          output.SetIs8bpc(false);
          if (!Begin(error)) return false;
          EndRender();
          metal.BeginWrite(commands);
          // Added output noise belongs after resampling/sharpening. The
          // presenter selects the last-pass dither variant, not this mailbox.
          const auto quality = rex::cvar::GetFlagByName("gta4_native_smaa_quality");
          bool recorded=false;
          if(temporal_output){
            recorded=generated_pair.real?temporal.CopyColor(commands,generated_pair.real,metal.texture(),error):
                temporal.Compose(commands,temporal.final_scene,metal.texture(),error);
            if(recorded&&generated_pair.generated)metal.SetGeneratedFrame(generated_pair.generated,generated_pair.real,generated_pair.lease,temporal.metadata.epoch,temporal.presentation_interval_ns);
          }else recorded=post_processing.Record(commands,source->image,metal.texture(),anti_aliasing,quality,false,error);
          if (recorded) FireSnapshot(metal.texture(),"present-after-aa",0,false,true);
          if (recorded && trace_extent) {
            const auto route = gta4_native::GetAntiAliasingRoute(anti_aliasing);
            REXLOG_INFO("gta4-metal-aa frame={} mode={} scene-samples={} smaa={} quality={} source-samples={} destination-samples={}",
                present.submitted_frame, gta4_native::AntiAliasingModeName(anti_aliasing),
                route.scene_sample_count, route.presentation_smaa, quality,
                source->image.sampleCount, metal.texture().sampleCount);
          }
          if(recorded)metal.EndWrite(commands);
          return recorded && Flush(false, error);
        }, provenance);
  } else if (!Flush(false, error)) {
    return false;
  }
  // Match the title's completed-frame acknowledgement even if its surface was
  // hidden or disconnected. Never leave the guest waiting on an invisible UI.
  if (present.device && uint64_t(present.device) + 16552 + sizeof(uint32_t) <= 0x100000000ull) {
    const uint32_t completed = __builtin_bswap32(present.submitted_frame);
    if (!memory.Write(present.device + 16552,
        {reinterpret_cast<const uint8_t*>(&completed), sizeof(completed)})) {
      error = "Cannot acknowledge the completed title frame"; published = false;
    }
  }
  if(temporal.active&&(present.submitted_frame<=6||present.submitted_frame%60==0))
    REXLOG_INFO("gta4-metal-temporal-frame frame={} input={}x{} output={}x{} world={} history={} reactive={} ui={} resolved={} ui-exact={} generated={} camera-filled={} geometry-bytes={} jittered={} composite={} composite-shader={:016X} scene-stage={} spatial-fallback={} fallback-reason={} generation-skip={} slow-skips={}",
      present.submitted_frame,temporal.config.input_width,temporal.config.input_height,output_width,output_height,temporal.world_draws,temporal.history_draws,
      temporal.reactive_draws,temporal.ui_draws,temporal.resolved,temporal.ui_exact,generated_pair.generated!=nil,temporal.camera_filled_frames,temporal.geometry.owned_bytes(),
      temporal.jittered_draws,temporal.composite_seen,temporal.composite_shader,temporal.composite_scene_stage,temporal.spatial_fallback,temporal.fallback_reason,temporal.generation_skip_reason,temporal.slow_generation_skips);
  if (temporal.active && REXCVAR_GET(gta4_temporal_diagnostics)) {
    const auto& d = temporal.AntiAliasingState();
    if (d.valid && (present.submitted_frame <= 6 || present.submitted_frame % 60 == 0 ||
                    d.reset || !d.accepted || !d.encoded)) {
      REXLOG_INFO(
          "gta4-metal-temporal-contract frame={} sequence={} method={} path={} accepted={} encoded={} reset={} reason=\"{}\" input={}x{} output={}x{} scale={:.4f}x{:.4f} source-jitter={:.6f},{:.6f} effective-jitter={:.6f},{:.6f} motion-scale={:.3f},{:.3f} depth-reversed={} near={} far={} fov={} aspect={} pre-exposure={} exposure={} exposure-texture={} camera-cut={} adopted-camera={} background-history={} camera-transform={} world={} history={} reactive={} jittered={}",
          present.submitted_frame, d.sequence,
          d.method == temporal::Method::kMetalFx ? "metalfx" : "taa",
          d.metal4 ? "metal4" : "metal3", d.accepted, d.encoded, d.reset,
          d.reason.empty() ? "continuous" : d.reason, d.input_width, d.input_height,
          d.output_width, d.output_height,
          d.input_width ? double(d.output_width) / d.input_width : 0.0,
          d.input_height ? double(d.output_height) / d.input_height : 0.0,
          d.source_jitter[0], d.source_jitter[1], d.effective_jitter[0],
          d.effective_jitter[1], d.motion_scale[0], d.motion_scale[1], d.depth_reversed,
          d.near_plane, d.far_plane, d.field_of_view, d.aspect, d.pre_exposure,
          d.exposure, d.exposure_texture, temporal.metadata.camera_cut,
          temporal.adopted_camera, temporal.BackgroundHistoryValid(),
          temporal.CameraTransformValid(), temporal.world_draws, temporal.history_draws,
          temporal.reactive_draws, temporal.jittered_draws);
    }
  }
  if(temporal.active&&present.submitted_frame%60==0&&REXCVAR_GET(gta4_temporal_late_constants_diag)){
    static constexpr const char* kKinds[]={"tire","vehicle","ped","palette","late"};
    for(size_t k=0;k<temporal.late_counters.size();++k){
      const auto& c=temporal.late_counters[k];
      if(!c.draws)continue;
      // frames-per-change: ~1 a per-frame update, ~2 a half-rate one, large a static parameter.
      REXLOG_INFO("gta4-temporal-late frame={} class={} draws={} sibling={} moved={} changed={} stale={} stale-seen-change={} "
                  "stale-never-changed={} frames-per-change={:.2f} (60 frames)",
        present.submitted_frame,kKinds[k],c.draws,c.sibling,c.moved,c.changed,c.stale,c.stale_seen,c.stale_never,
        c.chain_changes?double(c.chain_frames)/double(c.chain_changes):0.0);
    }
    temporal.late_counters={};temporal.late_samples=0;
  }
  if(temporal.active&&present.submitted_frame%60==0){
    const auto m=temporal.geometry.TakeStatistics();
    REXLOG_INFO("gta4-metal-temporal-history frame={} by-key={} by-transform={} transform-ambiguous={} transform-far={} key-far={} none={} "
                "sibling={} sibling-ambiguous={} far-world={} pooled={} far-registers={} (60 frames)",
        present.submitted_frame,m.key,m.transform,m.transform_ambiguous,m.transform_far,m.key_far,m.none,m.sibling,m.sibling_ambiguous,
        m.far_world,temporal.geometry.pooled_snapshots(),[&]{
          // The three registers that most often refused a transform match by their change.
          std::array<uint32_t,256> order{};for(uint32_t i=0;i<order.size();++i)order[i]=i;
          std::partial_sort(order.begin(),order.begin()+3,order.end(),[&](uint32_t a,uint32_t b){return m.far_register[a]>m.far_register[b];});
          std::string text;
          for(int i=0;i<3;++i)if(m.far_register[order[i]])text+=fmt::format("{}c{}:{}",text.empty()?"":",",order[i],m.far_register[order[i]]);
          return text.empty()?std::string("-"):text;
        }());
  }
  if(temporal.active&&present.submitted_frame%60==0)
    REXLOG_INFO("gta4-metal-temporal-gbuffer-frame frame={} world={} gbuffer-active={} gbuffer-before-begin={} gbuffer-other-size={} other={}x{} input={}x{}",
        present.submitted_frame,temporal.world_draws,gbuffer_active,gbuffer_inactive,gbuffer_off_extent,gbuffer_last_w,gbuffer_last_h,
        temporal.config.input_width,temporal.config.input_height);
  gbuffer_active=gbuffer_inactive=gbuffer_off_extent=0;
  if(temporal.active&&!temporal.world_draws&&temporal.gbuffer_audit.total&&temporal.gbuffer_audit_logs<40){
    ++temporal.gbuffer_audit_logs;
    const auto& a=temporal.gbuffer_audit;
    REXLOG_INFO("gta4-metal-temporal-gbuffer-audit frame={} gbuffer-draws={} world={} ui-active={} composite={} screen={} not-primary={} camera={} adopted={} camera-valid={} jitter-decided={}",
        present.submitted_frame,a.total,a.world,a.ui,a.composite,a.screen,a.not_primary,a.camera,
        temporal.adopted_camera,temporal.execution_camera_valid,temporal.jitter_decided);
  }
  temporal.End();
  pipeline_budget_used_ns = 0;
  modern.EndGuestFrame();
  FireAdvance(present.submitted_frame);
  fusion_cloud_ready = false;
  if (present.submitted_frame % 60 == 0) LogThermalStateChange(present.submitted_frame);
  if (present.submitted_frame <= 3 || present.submitted_frame % 300 == 0) {
    {  // Encode-thread CPU in Draw(), per presented frame since the last line (any API, any RT mode).
      static raytracing::CpuTime last; static uint64_t last_frame = 0;
      const uint64_t frames = present.submitted_frame - last_frame;
      if (frames) {
        // One draw in 16 is timed: the mean over the timed draws, scaled by the true count.
        const uint64_t draws = draw_cpu_time.calls - last.calls, timed = draw_cpu_time.timed - last.timed;
        const double per_draw = timed ? double(draw_cpu_time.ns - last.ns) / double(timed) : 0.0;
        const double us = per_draw * double(draws) / 1000.0 / double(frames);
        REXLOG_INFO("gta4-metal-draw-cpu frame={} draw-us={:.1f} draws={} ns-per-draw={:.0f} timed={}", present.submitted_frame, us,
            draws / frames, per_draw, timed);
      }
      last = draw_cpu_time; last_frame = present.submitted_frame;
    }
    if (const auto m4 = ui::metal::Metal4StatisticsOf(context->queue); m4.command_buffers)
      REXLOG_INFO("gta4-metal4 frame={} command-buffers={} parts={} encoders={} barriers={} transient-bytes={} resident-adds={} resident-batches={} resident-bytes={} resident-budget={} metal3-hops={} "
          "binds={} bind-hits={} fragment-barriers={} vertex-barriers={} copy-barriers={} copy-independent={} copy-merged={} evicted={} residency-commits={}",
          present.submitted_frame, m4.command_buffers, m4.parts, m4.encoders, m4.barriers, m4.transient_bytes,
          m4.resident, m4.resident_batches, m4.resident_bytes, m4.resident_budget, m4.metal3_hops, m4.binds,
          m4.bind_hits, m4.fragment_barriers, m4.vertex_barriers, m4.copy_barriers, m4.copy_independent, m4.copy_merged, m4.evicted,
          m4.residency_commits);
    if (const auto fg = temporal_scene.interpolation_counts(); fg.native || fg.hop)
      REXLOG_INFO("gta4-metal-framegen frame={} native-mtl4fx={} metal3-hop={}", present.submitted_frame, fg.native, fg.hop);
    REXLOG_INFO("gta4-metal-constant-tracking frame={} skips={} audited={} mismatches={} fallback={} delta={} delta-uploads={} "
        "delta-unchanged={} delta-groups={} last-hits={} hash-hits={} history-uploads={} history-reuses={} history-in-place={}",
        present.submitted_frame, guest_constant_skips, guest_constant_audits,
        guest_constant_mismatches, guest_constant_tracking_failed, delta_guest_constants, constant_delta_uploads,
        constant_delta_unchanged, constant_delta_groups, constant_last_hits, constant_hash_hits,
        snapshot_upload_misses, snapshot_upload_hits, snapshot_upload_reuses);
    {
      const auto buffers = resources.buffer_cache_statistics();
      REXLOG_INFO("gta4-metal-buffer-validation frame={} per-use={} validations={} skips={} mismatches={} memo-hits={} "
          "target-memo={} target-memo-hits={} target-memo-misses={}",
          present.submitted_frame, rex::cvar::Query<bool>("gta4_metal_buffer_validation_per_use"),
          buffers.validations, buffers.validation_skips, buffers.validation_mismatches, buffers.memo_hits,
          memo_targets, target_memo_hits, target_memo_misses);
    }
    if (range_constants_enabled)
      REXLOG_INFO("gta4-metal-range-constants-live frame={} vertex={} canary={} vs-uploads={} vs-bytes={} ps-uploads={} ps-bytes={} canaries={}",
          present.submitted_frame, range_constants_vertex, range_constants_canary, guest_bank_uploads[0], guest_bank_upload_bytes[0],
          guest_bank_uploads[1], guest_bank_upload_bytes[1], range_constant_canaries);
    if (shadow_range_constants) for (size_t b = 0; b < ConstantRangeShadow::kBanks; ++b) {
      const auto& r = range_constants.statistics(b);
      REXLOG_INFO("gta4-metal-range-constants frame={} bank={} full-uploads={} full-bytes={} requests={} empty={} clean-hits={} clean-uncovered={} last-hits={} hash-hits={} misses={} range-bytes={} previous-uploads={} previous-range-bytes={}",
          present.submitted_frame, b ? "ps" : "vs", guest_bank_uploads[b], guest_bank_upload_bytes[b], r.requests, r.empty,
          r.clean_hits, r.clean_uncovered, r.last_hits, r.hash_hits, r.misses, r.bytes,
          b ? 0 : previous_bank_uploads, b ? 0 : previous_bank_range_bytes);
    }
    REXLOG_INFO("gta4-metal-pipeline-lookup frame={} lookups={} memo-hits={} compiled={} ready={} waited={} wait-ms={:.1f} deferred-draws={}",
        present.submitted_frame, pipeline_lookups, pipeline_lookup_hits,
        pipeline_creations, pipeline_ready, pipeline_waits, double(pipeline_wait_ns) / 1e6, pipeline_deferred_draws);
    const auto texture_cache = resources.texture_cache_statistics();
    const auto vertex_cache = resources.vertex_conversion_statistics();
    REXLOG_INFO("gta4-metal-vertex-cache frame={} bytes={} charged={} budget={} entries={} hits={} misses={} evictions={}",
        present.submitted_frame, vertex_cache.bytes, vertex_cache.charged_bytes,
        vertex_cache.budget, vertex_cache.entries, vertex_cache.hits,
        vertex_cache.misses, vertex_cache.evictions);
    REXLOG_INFO("gta4-metal: frame={} draws={} resolves={} clears={} published={} textures={} buffers={} uploads={} resolve-reuse={} resolve-init-merges={} resolve-deferred={} resolve-executed={} resolve-dropped={} clear-folds={} clear-materialized={} state-calls={} state-skips={} residency-calls={} residency-skips={} constant-last-hits={} constant-hash-hits={} constant-upload-bytes={} texture-budget={} texture-entries={} texture-evictions={} texture-rejections={} texture-idle-trims={}",
        present.submitted_frame, frame_draws, frame_resolves, frame_clears, published,
        resources.texture_bytes(), resources.buffer_bytes(), frames.reserved_bytes(),
        resolve_skips, resolve_initializations_merged,frame_resolve_deferrals,frame_resolve_executions,frame_resolve_drops,clear_load_folds,clear_materializations,
        bindings.calls,bindings.skipped,bindings.residency_calls,bindings.residency_skipped,
        constant_last_hits,constant_hash_hits,constant_upload_bytes,
        texture_cache.budget,texture_cache.entries,texture_cache.evictions,texture_cache.rejections,
        texture_cache.idle_trims);
  }
  frame_draws = frame_resolves = frame_clears = 0;
  frame_resolve_deferrals = frame_resolve_executions = frame_resolve_drops = 0;
  target_observations = {}; pass_breaks = {}; ended_targets = {};
  if (!published && error.empty()) error = "Presenter did not accept the title output";
  return published;
}
}  // namespace rex::graphics::gta4_metal
