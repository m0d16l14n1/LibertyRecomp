#pragma once
#include "renderer.h"
#include "resources.h"
#include "guest_state.h"
#include "../gta4_native/core/geometry.h"
#include "pass_contracts.h"
#include "post_processing.h"
#include "depth_of_field.h"
#include "sun_shafts.h"
#include "modern_sky_probe.h"
#include "temporal/live.h"
#include "raytracing/capture.h"
#include "raytracing/ambient_occlusion.h"
#include "raytracing/sun_shadows.h"
#include "frame_work_qos.h"
#include "encoder_bindings.h"
#include "constant_upload_cache.h"
#include "constant_range_shadow.h"
#include "guest_constant_tracking.h"
#include "profile_records.h"
#include "render_phase_stack.h"
#include "../../ui/metal/context.h"
#include "../../ui/metal/frame_ring.h"
#include "../gta4_native/modern_shader_policy.h"
#include "../gta4_native/modern_shader_diagnostics.h"
#include <rex/graphics/gta4_native/anti_aliasing_policy.h>
#include <rex/graphics/gta4_native/fire_escape_trace.h>
#include <rex/ui/presenter.h>
#include <array>
#include <source_location>
#include <atomic>
#include <condition_variable>
#include <mutex>
#include <unordered_map>
#include <vector>
#include <xxhash.h>
#include "pipeline_lookup_memo.h"
#include "pipeline_store.h"

namespace rex::graphics::gta4_metal {
struct Renderer::State {
  struct Key {
    std::array<uint64_t,64> words{};
    bool operator==(const Key&) const = default;
  };
  struct KeyHash {
    size_t operator()(const Key& key) const { return size_t(XXH3_64bits(key.words.data(),sizeof(key.words))); }
  };
  struct Targets {
    std::array<std::shared_ptr<SurfaceResource>,gta4_native::kRenderTargetCount> colors{};
    std::shared_ptr<SurfaceResource> depth;
    uint32_t width=0,height=0,logical_width=0,logical_height=0,samples=1;
    uint32_t color_mask=0;
    bool temporal_motion=false,temporal_reactive=false,temporal_ui=false,temporal_jitter=false;
  };
  struct PipelineBuild {
    std::mutex mutex;
    std::condition_variable wake;
    id<MTLRenderPipelineState> state = nil;
    std::string error;
    bool complete = false;
  };
  struct Pipeline {
    id<MTLRenderPipelineState> state=nil;
    std::shared_ptr<PipelineBuild> build;
    ShaderMetadata vertex,pixel;
    bool has_pixel=false,temporal_variant=false;
    uint64_t variant=0;
    std::array<uint32_t,gta4_native::kVertexStreamCount> strides{};
    // Ray tracing (gta4_metal_raytracing): the geometry-capture replay of this pipeline's
    // vertex shader, compiled asynchronously; capture_state is set once it is ready.
    std::shared_ptr<PipelineBuild> capture;
    id<MTLRenderPipelineState> capture_state=nil;
    // Ray-traced AO (mode ao): this pipeline with the deferred-lighting shader's AO variant
    // (raytracing_ao_variants.py), which scales only the ambient term; set once ready.
    std::shared_ptr<PipelineBuild> ambient;
    id<MTLRenderPipelineState> ambient_state=nil;
    // Ray-traced sun shadows (mode shadows): this pipeline with the lighting shader's shadow
    // variant (raytracing_shadow_variants.py), which combines the cascade with the trace.
    std::shared_ptr<PipelineBuild> sunlit;
    id<MTLRenderPipelineState> sunlit_state=nil;
  };
  // Guest, shared and descriptor banks retain their latest exact source bytes
  // to reject unchanged values before hashing or inspecting immutable uploads.
  struct ConstantBank {
    std::array<uint8_t, 4096> source;
    const uint8_t* source_view=nullptr;
    size_t size = 0;
    ui::metal::UploadSlice upload;
  };
  std::array<ConstantBank, 4> constant_banks;
  bool cache_constant_sources = true,cache_material_bindings=true;
  // Per-frame snapshots of settings consulted per draw/texture/clear: a by-name cvar query takes
  // the registry mutex and a hash lookup, which showed up per texture stage in the profile.
  bool prepare_textures = true, fold_full_clears = true, defer_unrelated_clears = true,
       exchange_resolve_clear = true;
  GuestConstantTracking guest_constants;
  bool track_guest_constants = true, audit_guest_constants = false;
  bool guest_constant_tracking_failed = false;
  uint64_t guest_constant_skips = 0, guest_constant_audits = 0, guest_constant_mismatches = 0;
  uint64_t constant_last_hits = 0, constant_hash_hits = 0, constant_upload_bytes = 0;
  uint64_t skipped_pixel_constant_banks=0;
  // Real full-bank uploads of the VS/PS float banks, beside the range shadow's model.
  std::array<uint64_t,2> guest_bank_upload_bytes{},guest_bank_uploads{};
  uint64_t previous_bank_uploads=0,previous_bank_range_bytes=0;  // temporal history VS banks (4 KB each today)
  bool shadow_range_constants=false;  // gta4_metal_range_constants_shadow, per frame
  ConstantRangeShadow range_constants;
  // gta4_metal_range_constants: upload only [lo, hi] of a float bank and push its
  // address moved back by lo registers (shaders index constants by absolute register).
  bool range_constants_enabled=false,range_constants_vertex=true,range_constants_canary=false;
  std::array<RangeBank<ui::metal::UploadSlice>,2> range_banks;  // VS, PS; the previous bank has none
  uint64_t range_constant_canaries=0;
  struct BankUpload {
    ui::metal::UploadSlice slice;
    uint64_t address=0;        // what the shader adds 16*register to
    ConstantRange range{0,0,false};  // registers `slice` holds; slice.data is register range.lo
    explicit operator bool() const { return bool(slice); }
  };
  // `index` 0/1 = guest VS/PS bank (tracked, last-bank reuse); any other value: hash cache only.
  BankUpload UploadRange(size_t index,std::span<const uint8_t> bank,ConstantRange range,bool swap,std::string&);
  static BankUpload WholeBank(const ui::metal::UploadSlice& slice,size_t bank_bytes) {
    return {slice,slice.gpu_address,ConstantRange{0,uint32_t(bank_bytes/16)-1,false}};
  }
  std::shared_ptr<ui::metal::MetalContext> context;
  GuestMemory memory;
  ui::Presenter* presenter=nullptr;
  ResourceStore resources;
  ShaderCache stock,overrides,temporal_stock,temporal_overrides;
  ShaderCache capture_stock;  // ray-tracing capture variants of the stock vertex shaders
  ShaderCache ao_stock;       // ray-traced AO variants of the deferred-lighting pixel shaders
  bool raytracing_ao_variants=false;  // ao_stock loaded
  ShaderCache shadow_stock;   // ray-traced sun-shadow variants of the deferred-lighting pixel shaders
  bool raytracing_shadow_variants=false;  // shadow_stock loaded
  raytracing::Mode raytracing_mode=raytracing::Mode::kOff;  // read at Initialize
  raytracing::Capture raytracing_capture;
  uint64_t raytracing_sequence=~0ull;  // temporal sequence of the open capture frame
  // Ray-traced AO (mode ao): traced once per frame before the lighting's global contribution.
  raytracing::AmbientOcclusion raytracing_ao;
  raytracing::AoSettings raytracing_ao_settings;
  id<MTLTexture> raytracing_ao_texture=nil;   // this frame's AO, input size
  uint64_t raytracing_ao_sequence=~0ull;      // temporal sequence it (and the shadows) was traced for
  uint64_t raytracing_ao_lighting_draws=0,raytracing_ao_applied=0,raytracing_ao_ambient_draws=0;
  // Ray-traced sun shadows (mode shadows): traced at the same hook, from the same inputs.
  raytracing::SunShadows raytracing_shadows;
  raytracing::ShadowSettings raytracing_shadow_settings;
  id<MTLTexture> raytracing_shadow_texture=nil;  // this frame's shadows, input size, RG16Float
  uint64_t raytracing_shadow_draws=0,raytracing_shadow_shown=0;
  // CPU on the encode thread: Draw() in every mode, and the ray-tracing parts of it.
  raytracing::CpuTime draw_cpu_time,raytracing_prelude_time,raytracing_hook_time,raytracing_site_time;
  // Recipes of every built pipeline + a binary archive of their compiled forms (launch precompile).
  PipelineStore pipeline_store;
  // Opt-in per-frame timing (gta4_metal_frame_log): kept in memory and appended to the file about
  // once a second (RecordFrameSample), so the measurement adds no per-frame I/O.
  struct FrameSample {
    uint32_t frame;
    uint64_t at_ns, interval_ns, submit_ns, present_ns;
    uint32_t draws, pipelines_built, pipeline_waits, texture_waits;
    uint64_t pipeline_wait_ns, gpu_ns;
  };
  std::string frame_log_path;
  std::vector<FrameSample> frame_samples;
  uint64_t frame_submit_ns = 0, frame_present_ns = 0, frame_log_origin_ns = 0, frame_last_present_ns = 0;
  uint64_t frame_log_written_ns = 0;
  // GPU busy time summed by command-buffer completion handlers (shared: handlers may outlive State).
  std::shared_ptr<std::atomic<uint64_t>> frame_gpu_ns = std::make_shared<std::atomic<uint64_t>>(0);
  uint64_t frame_prev_gpu_ns = 0;
  uint64_t frame_prev_draws = 0, frame_prev_pipelines = 0, frame_prev_waits = 0, frame_prev_wait_ns = 0,
           frame_prev_texture_waits = 0;
  void RecordFrameSample(uint32_t frame);
  void WriteFrameLog();
  bool use_pipeline_archive = true;
  bool retain_ignore_address = true;
  temporal::Live temporal_scene;
  bool temporal_enabled=false,temporal_upscale=false,temporal_generation=false;
  PostProcessing post_processing;
  DepthOfField depth_of_field;
  SunShafts sun_shafts;
  id<MTLBuffer> fusion_tone_lut = nil;
  id<MTLBuffer> fusion_cloud_mask = nil;
  uint32_t fusion_cloud_width = 0, fusion_cloud_height = 0;
  bool fusion_cloud_ready = false;
  uint32_t postfx_half_scene_handle = 0;
  ui::metal::FrameRing frames;
  ui::metal::FrameRing::Slot* frame=nullptr;
  id<MTLCommandBuffer> commands=nil;
  id<MTLRenderCommandEncoder> render=nil;
  id<MTLLibrary> native_library=nil;
  std::array<id<MTLTexture>,4> fallback_textures{};
  id<MTLSamplerState> fallback_sampler=nil;
  id<MTLBuffer> default_vertex=nil;
  std::unordered_map<Key,Pipeline,KeyHash> pipelines;
  PipelineLookupMemo<Key, Pipeline> pipeline_lookup;
  bool cache_pipeline_lookup = true;
  uint64_t pipeline_lookups = 0, pipeline_lookup_hits = 0;
  std::unordered_map<Key,id<MTLDepthStencilState>,KeyHash> depth_states;
  std::unordered_map<std::string,id<MTLRenderPipelineState>> utility_pipelines;
  ConstantUploadCache<ui::metal::UploadSlice> constants;
  std::unordered_map<uint32_t,ShaderMetadata> shaders;
  std::unordered_map<uint32_t,VertexDeclaration> declarations;
  std::array<gta4_native::SurfaceDescriptor,gta4_native::kRenderTargetCount> color_bindings{};
  gta4_native::SurfaceDescriptor depth_binding{};
  std::array<VertexStream,gta4_native::kVertexStreamCount> streams{};
  uint32_t vertex_shader=0,pixel_shader=0,declaration=0,index_buffer=0,device=0;
  uint64_t next_declaration=1,submitted=0,draws=0,resolves=0,clears=0;
  uint64_t pipeline_creations = 0, declaration_definitions = 0, declaration_reuses = 0;
  uint64_t pipeline_ready = 0, pipeline_waits = 0, pipeline_wait_ns = 0;
  // Time this frame's draws have waited for compiling pipelines, and the scene
  // draws left out once that budget ran out (gta4_metal_pipeline_wait_budget_ms).
  uint64_t pipeline_budget_used_ns = 0, pipeline_deferred_draws = 0;
  // GBuffer-shaped draws (3 colour targets, depth write) per guest frame: while no temporal
  // frame was active, and while active but not at the temporal input size.
  uint32_t gbuffer_inactive = 0, gbuffer_off_extent = 0, gbuffer_active = 0;
  uint32_t gbuffer_last_w = 0, gbuffer_last_h = 0;
  uint64_t render_passes_created = 0;
  // Bounded diagnostics: color slots, depth, extent, or an external pass break.
  std::array<uint64_t, 128> pass_breaks{};
  uint32_t pass_details_logged = 0;
  uint64_t frame_draws=0,frame_resolves=0,frame_clears=0;
  struct TargetObservation {
    uint64_t draws = 0;
    uint32_t color = 0, depth = 0, width = 0, height = 0;
    uint32_t logical_width = 0, logical_height = 0, samples = 0;
    uint32_t depth_width = 0, depth_height = 0;
    std::array<float, 6> viewport{};
  };
  std::array<TargetObservation, size_t(gta4_native::RenderPhase::kCompositePostFx) + 1> target_observations{};
  bool traced_scene = false;
  uint64_t content_serial=0;
  uint64_t resolve_skips=0, resolve_initializations_merged=0,resolve_image_exchanges=0;
  id<MTLBuffer> readback_buffer=nil;
  std::shared_ptr<TextureResource> PrepareTexture(uint32_t handle,
      const xenos::xe_gpu_texture_fetch_t&,std::string&);
  bool ResolveClears(const gta4_native::ResolveCommand&,std::string&);
  // A resolve is recorded, not encoded, until something needs its result: the first read of the
  // destination, or a GPU write to its source or destination image. Resolves whose destination is
  // fully rewritten before anyone reads it are dropped without ever running (see docs/BACKLOG.md 17).
  // A record may outlive its command buffer: images are never recycled, and every GPU write to one
  // goes through a settle hook, so a record's source image keeps the recorded contents until the
  // hook runs it. Flush() runs only records left over from an earlier submission (bounded age); a
  // waiting Flush runs them all.
  struct PendingResolve {
    uint64_t recorded_submission = 0;
    std::shared_ptr<SurfaceResource> source;  // identity and clear state only; the image is below
    id<MTLTexture> source_image = nil;
    id<MTLTexture> target = nil;
    std::shared_ptr<TextureResource> destination;
    uint64_t subresource = 0;
    uint32_t source_handle = 0, destination_handle = 0;
    uint32_t level = 0, slice = 0, target_w = 0, target_h = 0;
    bool volume = false, depth = false, direct = false, full = false, existing = false,
         initialize_in_pass = false;
    PixelRectangle src_rect, dst_rect;
    ResolveConstants constants{};
  };
  std::vector<PendingResolve> pending_resolves;
  bool defer_resolves = true;
  uint64_t frame_resolve_deferrals = 0, frame_resolve_executions = 0, frame_resolve_drops = 0;
  bool ExecuteResolve(const PendingResolve&, std::string&);
  // writing=true: anything that reads or writes the image must land first. writing=false (a read):
  // only pending writes to the image must land.
  bool SettlePendingResolves(id<MTLTexture> image, bool writing, std::string&,
                             std::source_location caller = std::source_location::current());
  bool SettlePendingResolves(const TextureResource* destination, std::string&,
                             std::source_location caller = std::source_location::current());
  bool SettleAllPendingResolves(std::string&, std::source_location caller = std::source_location::current());
  bool SettleStalePendingResolves(std::string&, std::source_location caller = std::source_location::current());
  // Profiler only: which flush point forced the execution being encoded.
  std::source_location settle_point = std::source_location::current();
  gta4_native::ModernShaderFramePolicy modern;
  gta4_native::ModernShaderDiagnostics modern_diagnostics;
  ModernSkyProbe sky_probe;
  id<MTLBuffer> sky_visibility = nil;
  uint64_t diagnostic_command = 0;
  std::string_view diagnostic_point = "submit";
  uint32_t diagnostic_texture_stage = UINT32_MAX, diagnostic_texture_handle = 0;
  void TraceCommandFailure(std::span<const std::byte>, std::string_view);
  gta4_native::ShaderOverrideMode override_mode=gta4_native::ShaderOverrideMode::kPair;
  gta4_native::AntiAliasingMode anti_aliasing=gta4_native::AntiAliasingMode::kOff;
  gta4_native::EnvironmentalDataV2 environment{};
  RenderPhaseStack phases;
  Targets active_targets;
  EncoderBindings bindings;
  bool cache_encoder_state = true;
  bool profile_enabled = false;
  uint64_t profile_origin_ns = 0;
  uint64_t next_scope = 0;
  ScopeProfile scope_profile;
  ResolveProfile resolve_profile;
  void ProfileRead(const std::shared_ptr<TextureResource>& texture,uint32_t kind);
  void FinishScopeProfile();
  void FinishResolveProfile();
  bool ready=false;
  bool capture_attempted = false, capture_active = false;
  gta4_native::FireTraceContext fire_context{};
  bool fire_active = false, fire_hud_seen = false;
  uint64_t fire_capture = 0, fire_draw = 0, fire_snapshot = 0;
  uint64_t fire_bytes = 0, fire_draw_bytes = 0, fire_disk_bytes = 0;
  uint64_t fire_material_draws = 0;
  uint64_t fire_scan = 0;
  uint32_t fire_detail_first = 0, fire_detail_last = 0;
  uint64_t fire_detail_pixel_shader = 0;
  bool fire_detail_shader_match = false;
  id<MTLComputePipelineState> fire_scan_pipeline = nil, fire_sample_pipeline = nil;
  std::string fire_request;
  Targets fire_last_targets;
  void FireAdvance(uint32_t guest_frame);
  void FireSnapshot(id<MTLTexture>, std::string_view label, uint32_t handle = 0,
                    bool per_draw = false, bool full = false);
  void FireTargets(const Targets&, std::string_view label, bool per_draw = false);
  void FireBeforeDraw(const Targets&, const FixedState&, const Pipeline&, std::span<const uint8_t>,
                      uint32_t primitive, uint32_t count, int32_t base_vertex);
  void FireAfterDraw(const Targets&);
  void FirePhase(const gta4_native::RenderPhaseMarkerCommand&);
  void FireInspect(id<MTLTexture>, std::string_view label, uint32_t handle, uint64_t draw);
  void FireInspectTargets(const Targets&, std::string_view label);
  bool FireDetailed() const;
  FrameWorkQos frame_qos;
  bool qos_announced = false;
  std::vector<std::shared_ptr<SurfaceResource>> pending_clears;
  uint64_t clear_load_folds = 0, clear_materializations = 0;
  bool MaterializePendingClears(std::string& error, const SurfaceResource* only = nullptr);
  void ConsumePendingClear(const std::shared_ptr<SurfaceResource>& surface);


  State(std::shared_ptr<ui::metal::MetalContext>,memory::Memory*,ui::Presenter*);
  bool Begin(std::string& error);
  void EndRender(std::source_location caller = std::source_location::current());
  bool Flush(bool wait,std::string& error);
  // Commits the encoded part of the frame so the GPU starts on it while the rest is encoded
  // (gta4_metal_split_commit_draws). Only at a render-pass boundary and before any of the next
  // draw's uploads: nothing pending is settled, no submission number changes.
  bool CommitPart(std::string& error);
  bool CommitEncoded(std::string& error);
  bool PassContinues(const Targets&) const;
  uint32_t split_commit_draws=0;
  bool temporal_vertex_texture_history=true,temporal_reactive_weighting=true,temporal_reactive_log=false;
  uint64_t temporal_trace_vs=0;
  uint64_t part_first_draw=0, split_commits=0;
  bool frame_split=false;
  bool CaptureTargets(std::span<const uint8_t>,uint32_t color_mask,bool depth,Targets&,std::string&);
  bool BeginRender(const Targets&,std::string& error);
  Pipeline* DrawPipeline(const Targets&,const FixedState&,const VertexDeclaration&,bool up,uint32_t stride,std::string&);
  bool CompletePipeline(Pipeline&, std::string&, bool* deferred = nullptr);
  RecipeLibrary LibraryOf(const ShaderCache& cache) const {
    return &cache==&stock?RecipeLibrary::kStock:&cache==&overrides?RecipeLibrary::kOverride:
        &cache==&temporal_stock?RecipeLibrary::kTemporalStock:RecipeLibrary::kTemporalOverride;
  }
  ShaderCache* CacheOf(RecipeLibrary library) {
    switch(library){case RecipeLibrary::kStock:return &stock;case RecipeLibrary::kOverride:return &overrides;
      case RecipeLibrary::kTemporalStock:return &temporal_stock;case RecipeLibrary::kTemporalOverride:return &temporal_overrides;
      default:return nullptr;}
  }
  id<MTLFunction> RecipeFunctionObject(const RecipeFunction& function, std::string& error);
  // Temporal archives load only while TAA/MetalFX is active; their recipes wait until then.
  bool RecipeBuildable(const PipelineRecipe& recipe) {
    for(const auto* f:{&recipe.vertex,&recipe.fragment}){
      if(f->library==RecipeLibrary::kDepthMotion&&!temporal_enabled) return false;
      if(auto* cache=CacheOf(f->library);cache&&!cache->Identity()) return false;
    }
    return true;
  }
  id<MTLDepthStencilState> DepthState(const FixedState&,bool attachment,std::string&);
  ui::metal::UploadSlice Upload(std::span<const uint8_t>,bool swap,std::string&);
  bool Draw(const gta4_native::CommandHeader&,std::span<const std::byte>,std::string&);
  bool Clear(const gta4_native::ClearCommand&,std::string&);
  bool ClearSurface(const std::shared_ptr<SurfaceResource>&,uint32_t aspects,
      const gta4_native::ResolveRectangle&,const std::array<float,4>&,float depth,uint32_t stencil,std::string&);
  bool Resolve(const gta4_native::ResolveCommand&,std::string&);
  bool Handoff(const gta4_native::DepthSurfaceHandoffCommand&,std::string&);
  bool Present(const gta4_native::PresentCommand&,std::string&);
  bool Readback(const gta4_native::TextureLockCommand&,gta4_native::TextureLockResult&,std::string&);
  id<MTLRenderPipelineState> Utility(const char*,MTLPixelFormat,MTLPixelFormat,uint32_t,std::string&);
  bool CopyColor(id<MTLTexture>,id<MTLTexture>,std::string&);
  gta4_native::RenderPhase Phase() const {return phases.phase();}
};
}  // namespace rex::graphics::gta4_metal
