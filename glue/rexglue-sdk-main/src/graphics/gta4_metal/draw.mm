#include "material_binding.h"
#include <rex/graphics/gta4_native/fusion_tone_lut.h>
#include "renderer_state.h"
#include "gpu_pass_timer.h"
#include "../gta4_native/modern_shader_options.h"
#include <rex/diagnostics/policy.h>
#include <rex/logging.h>
#include <rex/cvar.h>
#include "rectangle_geometry.h"
#include "temporal/composite_contract.h"
#include "temporal/draw_policy.h"
#include "temporal/exposure_contract.h"
#include "../gta4_native/native_shader_booleans.h"
#include "../gta4_native/native_stencil_volume_policy.h"
#include "../gta4_native/native_triangle_fan.h"
#include "../gta4_native/native_clip_control.h"
#include "../gta4_native/native_resolve_policy.h"
#include <algorithm>
#include <bit>
#include <cmath>
#include <cstring>
#include <limits>

REXCVAR_DEFINE_STRING(gta4_metal_lighting_dump, "", "GPU/Diagnostics",
    "Directory: for one frame per new value, log every deferred-lighting draw and dump raw the "
    "textures the first global-contribution draw samples, its target before and after, and the scene depth");

namespace rex::graphics::gta4_metal {
namespace {
// "<w> <h> <bytes per texel> <MTLPixelFormat>\n" then the rows, written when the GPU completes.
void DumpLightingTexture(id<MTLCommandBuffer> commands, id<MTLTexture> image, const std::string& path) {
  if (!image || image.textureType != MTLTextureType2D || image.sampleCount != 1) return;
  NSUInteger texel = 0;
  switch (image.pixelFormat) {
    case MTLPixelFormatR8Unorm: texel = 1; break;
    case MTLPixelFormatRG8Unorm: case MTLPixelFormatR16Float: case MTLPixelFormatR16Unorm: texel = 2; break;
    case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB: case MTLPixelFormatBGRA8Unorm:
    case MTLPixelFormatBGRA8Unorm_sRGB: case MTLPixelFormatRGB10A2Unorm: case MTLPixelFormatRG11B10Float:
    case MTLPixelFormatRGB9E5Float: case MTLPixelFormatR32Float: case MTLPixelFormatRG16Float:
    case MTLPixelFormatRG16Unorm: case MTLPixelFormatR32Uint: case MTLPixelFormatDepth32Float: texel = 4; break;
    case MTLPixelFormatRGBA16Float: case MTLPixelFormatRGBA16Unorm: case MTLPixelFormatRG32Float: texel = 8; break;
    case MTLPixelFormatRGBA32Float: texel = 16; break;
    default: REXLOG_INFO("gta4-metal-lighting-dump skipped {} format={}", path, uint32_t(image.pixelFormat)); return;
  }
  const NSUInteger w = image.width, h = image.height, pitch = w * texel;
  auto buffer = [commands.device newBufferWithLength:pitch * h options:MTLResourceStorageModeShared];
  auto blit = [commands blitCommandEncoder];
  if (!buffer || !blit) { [blit endEncoding]; return; }
  blit.label = @"Liberty lighting dump";
  [blit copyFromTexture:image sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
             sourceSize:MTLSizeMake(w, h, 1) toBuffer:buffer destinationOffset:0
        destinationBytesPerRow:pitch destinationBytesPerImage:pitch * h];
  [blit endEncoding];
  const uint32_t format = uint32_t(image.pixelFormat);
  const std::string file = path;
  [commands addCompletedHandler:^(id<MTLCommandBuffer> done) {
    if (done.status != MTLCommandBufferStatusCompleted) return;
    if (FILE* f = std::fopen(file.c_str(), "wb")) {
      std::fprintf(f, "%lu %lu %lu %u\n", (unsigned long)w, (unsigned long)h, (unsigned long)texel, format);
      std::fwrite(buffer.contents, 1, pitch * h, f);
      std::fclose(f);
    }
  }];
}
template<class T> T ReadCommand(std::span<const std::byte> bytes) {
  T result{}; std::memcpy(&result,bytes.data(),sizeof(result)); return result;
}
template<class T> std::span<const uint8_t> Bytes(const T& value) {
  return {reinterpret_cast<const uint8_t*>(&value),sizeof(value)};
}
// How a reactive draw (not tracked by motion: glass, decals, particles, light effects) weights the
// temporal scaler's reactive mask (temporal_shader_variants.py, liberty_reactive). Each used to write
// 1.0 wherever it rasterized, so one full-screen pass made the whole frame reactive and MetalFX
// accumulated nothing: textures shimmered with the camera jitter. Now by what reaches colour 0:
// 1 the draw replaces it, 2 its alpha (alpha blending), 3 its colour (additive), 4 colour times
// alpha (additive by alpha), 5 nothing. Nothing also for passes that are not over-draw: without a
// depth test (the AA fragment merge, the depth-effects composite; light shafts and coronas are
// `effect` and keep their weight), and unblended redraws onto existing depth that leave colour
// to the surface below (the ped material-ID pass over Niko and every ped).
template<class Fixed> uint32_t ReactiveMode(const Fixed& fixed,uint32_t requested_colors,bool effect){
  using namespace gta4_native;
  if(!(requested_colors&1u)||!(NativeColorWriteMaskForTarget(fixed.color_write_mask,0)&7u))return 5;
  if(!effect&&!fixed.depth_enable)return 5;
  if(!IsNativeBlendControlEnabled(fixed.blend_controls[0]))return fixed.depth_write_enable?1:5;
  const auto b=DecodeNativeBlendControl(fixed.blend_controls[0]);
  if(b.color_operation!=0)return 1;
  if(b.source_color==6&&b.destination_color==7)return 2;
  if(b.source_color==1&&b.destination_color==1)return 3;
  if(b.source_color==6&&b.destination_color==1)return 4;
  if(b.source_color==0&&b.destination_color==1)return 5;
  return 1;
}
}

bool Renderer::State::CaptureTargets(std::span<const uint8_t> guest,uint32_t colors,bool depth,
    Targets& target,std::string& error) {
  using namespace gta4_native;
  target={};
  for(uint32_t i=0;i<kRenderTargetCount;++i)
    color_bindings[i]=memory.Surface(GuestWord(guest,12432+i*sizeof(uint32_t)));
  depth_binding=memory.Surface(GuestWord(guest,12448));
  bool any=false,all_multisampled=true,reflection=false;
  auto inspect=[&](const SurfaceDescriptor& descriptor) {
    if(!descriptor.handle) return;
    any=true; all_multisampled&=descriptor.sample_type!=0;
    reflection|=resources.IsReflection(descriptor.handle);
  };
  for(uint32_t i=0;i<kRenderTargetCount;++i) if(colors&(1u<<i)) inspect(color_bindings[i]);
  if(depth) inspect(depth_binding);
  const uint32_t override_samples=!reflection && any && all_multisampled ?
      GetAntiAliasingRoute(anti_aliasing).scene_sample_count : 0;
  auto admit=[&](const std::shared_ptr<SurfaceResource>& image) {
    if(!image) return false;
    if(!target.width) {
      target.width=uint32_t(image->image.width); target.height=uint32_t(image->image.height);
      target.logical_width=image->descriptor.width; target.logical_height=image->descriptor.height;
      target.samples=uint32_t(image->image.sampleCount); return true;
    }
    if(target.width!=image->image.width || target.height!=image->image.height ||
        target.logical_width!=image->descriptor.width || target.logical_height!=image->descriptor.height ||
        target.samples!=image->image.sampleCount) {
      error="Title attachments have incompatible dimensions or sample counts"; return false;
    }
    return true;
  };
  for(uint32_t i=0;i<kRenderTargetCount;++i) {
    if(!(colors&(1u<<i)) || !color_bindings[i].handle) continue;
    target.colors[i]=resources.Surface(color_bindings[i],false,error,override_samples);
    if(!admit(target.colors[i])) return false;
    target.color_mask|=1u<<i;
  }
  if(depth && depth_binding.handle) {
    target.depth=resources.Surface(depth_binding,true,error,override_samples);
    if(!admit(target.depth)) return false;
  }
  if (!target.width) {
    const SurfaceDescriptor* extent = depth_binding.handle ? &depth_binding : nullptr;
    for (const auto& color : color_bindings) if (color.handle) { extent = &color; break; }
    target.width = target.logical_width = extent ? extent->width : 1;
    target.height = target.logical_height = extent ? extent->height : 1;
    target.samples = 1;
    // All write/test masks can be disabled between visible draws. Recover the
    // actual bound extent before deciding continuity, including scaled/MSAA
    // targets. This does not allocate storage or infer another resource alias.
    const auto existing = extent ? resources.FindSurface(extent->handle) : nullptr;
    if (existing && NativeProducerResolveDescriptorsEqual(existing->descriptor, *extent)) {
      target.width = uint32_t(existing->image.width);
      target.height = uint32_t(existing->image.height);
      target.samples = uint32_t(existing->image.sampleCount);
    }
  }
  // Pipeline write/test masks are not attachment bindings. Retain compatible
  // inactive attachments already in this encoder, rather than storing/loading
  // them whenever a material disables depth or color writes. The sampled texture
  // store uses separate resolved images; every resolve/upload/readback still
  // closes the encoder before introducing a sampling dependency.
  if (render && target.width && !reflection && target.width == active_targets.width &&
      target.height == active_targets.height && target.samples == active_targets.samples &&
      target.logical_width == active_targets.logical_width && target.logical_height == active_targets.logical_height) {
    const auto retained = [&](const std::shared_ptr<SurfaceResource>& previous, const SurfaceDescriptor& binding) {
      // The binding must still resolve to this exact host surface. Its guest `address` is not part
      // of that identity: GTA IV re-points it between draws (e.g. 03F30001 <-> 03FC0001) on the same
      // handle/base/format/extent, and comparing it dropped the colour attachment for every
      // colour-masked draw - a full-resolution tile store + reload, ~250-400 times per frame.
      const auto& stored = previous ? previous->descriptor : SurfaceDescriptor{};
      if (!retain_ignore_address)  // A/B switch: the original exact-descriptor comparison.
        return previous && !resources.IsReflection(binding.handle) &&
            NativeProducerResolveDescriptorsEqual(stored, binding) && resources.FindSurface(binding.handle) == previous;
      return previous && !resources.IsReflection(binding.handle) &&
          stored.handle == binding.handle && stored.flags == binding.flags && stored.base == binding.base &&
          stored.packed_dimensions == binding.packed_dimensions && stored.format == binding.format &&
          stored.width == binding.width && stored.height == binding.height &&
          stored.sample_type == binding.sample_type &&
          resources.FindSurface(binding.handle) == previous;
    };
    for (size_t i = 0; i < target.colors.size(); ++i) {
      if (!target.colors[i] && retained(active_targets.colors[i], color_bindings[i])) {
        target.colors[i] = active_targets.colors[i];
        target.color_mask |= uint32_t{1} << i;
      }
    }
    if (!target.depth && retained(active_targets.depth, depth_binding)) target.depth = active_targets.depth;
  }
  return true;
}

bool Renderer::State::PassContinues(const Targets& target) const {
  bool same = bool(render) && active_targets.depth == target.depth &&
      active_targets.width == target.width && active_targets.height == target.height &&
      active_targets.samples == target.samples &&
      active_targets.temporal_motion==target.temporal_motion&&active_targets.temporal_reactive==target.temporal_reactive&&active_targets.temporal_ui==target.temporal_ui;
  for(size_t i=0;i<target.colors.size();++i) same&=active_targets.colors[i]==target.colors[i];
  return same;
}

bool Renderer::State::BeginRender(const Targets& target,std::string& error) {
  if(PassContinues(target)) return true;
  if (gpu_pass_timer::enabled() && render) {
    uint32_t why = 0;
    for (size_t i = 0; i < target.colors.size(); ++i)
      if (active_targets.colors[i] != target.colors[i]) why |= 1u << i;
    if (active_targets.depth != target.depth) why |= 16;
    if (active_targets.width != target.width || active_targets.height != target.height ||
        active_targets.samples != target.samples) why |= 32;
    gpu_pass_timer::Count(fmt::format("target-switch mask={:02X} (1-8=color0-3 16=depth 32=size)", why));
  }
  if (rex::diagnostics::IsEnabled(rex::diagnostics::Category::kNativeTrace)) {
    size_t reason = render ? 0 : 64;
    if (render) {
      for (size_t i = 0; i < target.colors.size(); ++i)
        if (active_targets.colors[i] != target.colors[i]) reason |= size_t{1} << i;
      if (active_targets.depth != target.depth) reason |= 16;
      if (active_targets.width != target.width || active_targets.height != target.height ||
          active_targets.samples != target.samples) reason |= 32;
    }
    ++pass_breaks[reason];
    if (reason == 1 && pass_details_logged < 16) {
      ++pass_details_logged;
      const auto old = active_targets.colors[0];
      const auto next = target.colors[0];
      REXLOG_INFO("gta4-metal-pass-detail phase={} old={:08X}@{} next={:08X}@{} bound={:08X} depth={:08X} old-flags={:08X} bound-flags={:08X} extent={}x{}",
          uint32_t(Phase()), old ? old->descriptor.handle : 0, old ? old->generation : 0,
          next ? next->descriptor.handle : 0, next ? next->generation : 0,
          color_bindings[0].handle, depth_binding.handle, old ? old->descriptor.flags : 0,
          color_bindings[0].flags, target.width, target.height);
    }
  }
  EndRender();
  // Binding an attachment writes its image: pending resolves reading or writing it land first.
  for(const auto& color:target.colors) if(color&&!SettlePendingResolves(color->image,true,error)) return false;
  if(target.depth&&!SettlePendingResolves(target.depth->image,true,error)) return false;
  auto pass=[MTLRenderPassDescriptor renderPassDescriptor];
  pass.visibilityResultBuffer=sky_visibility;
  for(size_t i=0;i<target.colors.size();++i) {
    auto& color=target.colors[i]; if(!color) continue;
    pass.colorAttachments[i].texture=color->image;
    pass.colorAttachments[i].loadAction=color->pending_clear.aspects ? MTLLoadActionClear : color->initialized?MTLLoadActionLoad:MTLLoadActionClear;
    pass.colorAttachments[i].storeAction=MTLStoreActionStore;
    const auto& clear_color = color->pending_clear.color;
    pass.colorAttachments[i].clearColor=color->pending_clear.aspects
        ? MTLClearColorMake(clear_color[0],clear_color[1],clear_color[2],clear_color[3])
        : MTLClearColorMake(0,0,0,0);
  }
  if(target.depth) {
    pass.depthAttachment.texture=target.depth->image;
    pass.stencilAttachment.texture=target.depth->image;
    const auto& clear = target.depth->pending_clear;
    pass.depthAttachment.loadAction=(clear.aspects & kContentDepth) ? MTLLoadActionClear :
        target.depth->initialized?MTLLoadActionLoad:MTLLoadActionClear;
    pass.stencilAttachment.loadAction=(clear.aspects & kContentStencil) ? MTLLoadActionClear :
        target.depth->initialized?MTLLoadActionLoad:MTLLoadActionClear;
    pass.depthAttachment.storeAction=pass.stencilAttachment.storeAction=MTLStoreActionStore;
    pass.depthAttachment.clearDepth=clear.depth; pass.stencilAttachment.clearStencil=clear.stencil;
  }
  const auto extra=[&](NSUInteger index,id<MTLTexture> image){
    pass.colorAttachments[index].texture=image;pass.colorAttachments[index].loadAction=MTLLoadActionLoad;pass.colorAttachments[index].storeAction=MTLStoreActionStore;
  };
  if(target.temporal_motion||target.temporal_reactive){extra(4,temporal_scene.inputs.motion);extra(5,temporal_scene.inputs.reactive);}
  if(target.temporal_motion)extra(6,temporal_scene.inputs.previous_depth);
  if(target.temporal_ui){extra(6,temporal_scene.ui_add);extra(7,temporal_scene.ui_transmit);}
  pass.renderTargetWidth=target.width; pass.renderTargetHeight=target.height;
  pass.defaultRasterSampleCount=target.samples;
  if(gpu_pass_timer::enabled()){
    static const char* kPhase[]={"unknown","gbuffer","lights-to-screen","light-setup","light-draw","radar","composite-postfx"};
    const auto phase=uint32_t(Phase());
    gpu_pass_timer::Tag(pass,fmt::format("scene/{} {}x{}{}",phase<7?kPhase[phase]:"other",target.width,target.height,
        target.samples>1?fmt::format(" msaa{}",target.samples):std::string()));
  }
  render=[commands renderCommandEncoderWithDescriptor:pass];
  if(!render) {error="Metal render pass creation failed"; return false;}
  ++render_passes_created;
  bindings.Reset(cache_encoder_state);
  if(profile_enabled) {
    scope_profile.Begin(submitted+1,++next_scope,target.width,target.height);
    render.label=[NSString stringWithFormat:@"Liberty scene r%llu s%llu",submitted+1,next_scope];
  } else render.label=@"Liberty game draws";
  for (size_t i = 0; i < target.colors.size(); ++i) {
    const auto& color = target.colors[i];
    if (!color) continue;
    if (pass.colorAttachments[i].loadAction == MTLLoadActionClear) {
      color->content_mask |= kContentColor;
      color->content_serial = ++content_serial;
    }
    color->initialized = true;
  }
  if (target.depth) {
    uint32_t initialized = 0;
    if (pass.depthAttachment.loadAction == MTLLoadActionClear) initialized |= kContentDepth;
    if (pass.stencilAttachment.loadAction == MTLLoadActionClear) initialized |= kContentStencil;
    target.depth->content_mask |= initialized;
    if (initialized) target.depth->content_serial = ++content_serial;
    target.depth->initialized = true;
  }
  for (const auto& color : target.colors) ConsumePendingClear(color);
  ConsumePendingClear(target.depth);
  active_targets=target; return true;
}

bool Renderer::State::Draw(const gta4_native::CommandHeader& header,std::span<const std::byte> bytes,
    std::string& error) {
  using namespace gta4_native;
  raytracing::ScopedCpuTime draw_timed(draw_cpu_time);  // every mode: the off/on baseline (gta4-metal-draw-cpu)
  diagnostic_point="draw.guest-state";
  uint32_t guest_device=0,type=0,first=0,count=0,up_stride=0,up_address=0,up_size=0,restart_value=0;
  int32_t base_vertex=0;
  bool indexed=false,restart=false,up=false;
  LightingContext lighting{};
  if(header.type==CommandType::kDrawPrimitive) {
    const auto c=ReadCommand<DrawPrimitiveCommand>(bytes);
    lighting=c.lighting;
    guest_device=c.device; type=c.primitive_type; first=c.start_vertex; count=c.vertex_count;
  } else if(header.type==CommandType::kDrawPrimitiveUp) {
    const auto c=ReadCommand<DrawPrimitiveUpCommand>(bytes); up=true;
    lighting=c.lighting;
    guest_device=c.device; type=c.primitive_type; count=c.vertex_count;
    up_stride=c.stride; up_address=c.vertex_data; up_size=c.vertex_data_size;
  } else {
    const auto c=ReadCommand<DrawIndexedPrimitiveCommand>(bytes); indexed=true;
    lighting=c.lighting;
    guest_device=c.device; type=c.primitive_type; first=c.start_index; count=c.index_count;
    base_vertex=c.base_vertex; restart=c.primitive_restart_enabled; restart_value=c.primitive_restart_index;
  }
  if(!count) return true;
  if(count>16u*1024u*1024u || uint64_t(first)+count>UINT32_MAX) {error="Draw range exceeds its bound"; return false;}
  const auto guest=memory.Read(guest_device,kGuestDeviceSize);
  if(guest.empty()) {error="Unmapped guest device state"; return false;}
  auto fixed=DecodeFixedState(guest);
  const uint32_t source_first=first,source_count=count;
  const bool source_indexed=indexed;
  if(HasUnsupportedNativeUserClipPlanes(fixed.clip_control)) {error="Unsupported guest clip plane configuration"; return false;}
  const auto vdecl=declarations.find(declaration);
  if(vdecl==declarations.end()) {error="Draw has no registered vertex declaration"; return false;}
  const auto pixel=shaders.find(pixel_shader);
  const uint32_t output_mask=pixel==shaders.end()?0:pixel->second.color_output_mask;
  const uint32_t requested_colors=NativeColorTargetMaskFromWriteMask(fixed.color_write_mask)&output_mask;
  if(!Begin(error)) return false;
  Targets targets;
  diagnostic_point="draw.targets";
  if(!CaptureTargets(guest,requested_colors,fixed.depth_enable||fixed.stencil_enable,targets,error)) return false;
  if(!temporal::FiniteViewport(fixed)){error="Nonfinite viewport";return false;}
  if(!temporal::RasterHasArea(fixed,targets.logical_width,targets.logical_height)){
    modern_diagnostics.SkySkipped(diagnostic_command,pixel==shaders.end()?0:pixel->second.hash,
        uint32_t(Phase()),"empty-viewport-or-scissor");return true;
  }
  uint32_t guest_samples=targets.samples;
  for (size_t i = 0; i < targets.colors.size(); ++i) {
    if ((requested_colors & (uint32_t{1} << i)) && targets.colors[i]) {
      guest_samples = 1u << targets.colors[i]->descriptor.sample_type; break;
    }
  }
  if ((fixed.depth_enable || fixed.stencil_enable) && targets.depth)
    guest_samples = 1u << targets.depth->descriptor.sample_type;
  const auto mask=SelectNativePipelineSampleMask(fixed.sample_mask,guest_samples,targets.samples);
  if(!mask.representable) {error="Guest sample mask cannot be represented at the selected sample count"; return false;}
  if(!mask.host_mask){modern_diagnostics.SkySkipped(diagnostic_command,pixel==shaders.end()?0:pixel->second.hash,
      uint32_t(Phase()),"zero-sample-mask");return true;}
  if(mask.host_mask!=NativeActiveSampleBits(targets.samples)) {
    error="Partial fixed sample mask requires a Metal raster-mask shader variant"; return false;
  }
  if(fixed.negative_one_to_one_clip_space) {
    error="Negative-one-to-one clipping requires a Metal vertex clip-range variant"; return false;
  }
  // Start all independent texture misses before pipeline and geometry work.
  // SetTexture provides earlier lookahead; this also covers unchanged bindings
  // whose backing was dirtied and any direct guest state updates.
  if (prepare_textures) {
    const auto vertex = shaders.find(vertex_shader);
    const uint32_t used = (vertex != shaders.end() ? vertex->second.used_texture_mask : 0) |
        (pixel != shaders.end() ? pixel->second.used_texture_mask : 0);
    for (uint32_t stage = 0; stage < kTextureStageCount; ++stage) {
      if (!(used & (1u << stage))) continue;
      const uint32_t handle = GuestWord(guest, 0x30F8 + stage * sizeof(uint32_t));
      if (!handle) continue;
      xenos::xe_gpu_texture_fetch_t fetch{};
      auto* words = reinterpret_cast<uint32_t*>(&fetch);
      for (size_t word = 0; word < 6; ++word)
        words[word] = GuestWord(guest, 0x480 + stage * 0x18 + word * sizeof(uint32_t));
      resources.PrefetchTexture(handle, fetch);
    }
  }
  auto& temporal=temporal_scene;
  const bool temporal_extent=temporal.active&&targets.samples==1&&targets.width==temporal.config.input_width&&targets.height==temporal.config.input_height&&
      std::none_of(targets.colors.begin(),targets.colors.end(),[&](const auto& c){return c&&resources.IsReflection(c->descriptor.handle);})&&
      (!targets.depth||!resources.IsReflection(targets.depth->descriptor.handle));
  if(temporal.active&&fixed.depth_enable&&fixed.depth_write_enable&&requested_colors&&targets.width==temporal.config.input_width&&targets.height==temporal.config.input_height&&temporal.diagnostic_depth_draws++<6&&temporal.metadata.sequence%60==0)
    REXLOG_INFO("gta4-temporal-input-observation frame={} phase={} main={} expected-view={:X} draw-view={:X} draw-seq={} input={}x{} target={}x{} logical={}x{} samples={} colors={} depth={:X} depth-reflection={} pixel={:X}",
      temporal.metadata.sequence,uint32_t(Phase()),temporal.main_view,temporal.metadata.view,temporal.observed_view,temporal.observed_sequence,
      temporal.config.input_width,temporal.config.input_height,targets.width,targets.height,targets.logical_width,targets.logical_height,targets.samples,requested_colors,
      targets.depth?targets.depth->descriptor.handle:0,targets.depth&&resources.IsReflection(targets.depth->descriptor.handle),pixel!=shaders.end()?pixel->second.hash:0);
  // The title schedules phase markers on one thread and executes cached draws
  // on another. Classify the actual shader/resource contract, not the ambient
  // diagnostic phase stack, which may already describe the following pass.
  const auto composite_contract=pixel!=shaders.end()?temporal::CompositeForShader(pixel->second.hash):std::nullopt;
  const bool final_composite_execution=temporal.execution_composite&&temporal.execution_final_composite&&
      temporal.execution_composite_scope&&temporal.execution_composite_scope==temporal.active_composite_scope;
  const bool composite_draw=temporal_extent&&final_composite_execution&&composite_contract.has_value();
  const bool stock_composite_filter=composite_draw&&composite_contract->filter==temporal::CompositeFilter::kStockF6;
  const auto* primary_depth=targets.depth?resources.Virtual(targets.depth->descriptor.handle):nullptr;
  const auto* primary_color=targets.colors[0]?resources.Virtual(targets.colors[0]->descriptor.handle):nullptr;
  const bool registered_primary=temporal_extent&&primary_depth&&
      primary_depth->scale_domain==VirtualResourceScaleDomain::kPrimaryScene&&
      ((primary_color&&primary_color->scale_domain==VirtualResourceScaleDomain::kPrimaryScene&&(requested_colors&7u)==7u)||
       (!requested_colors&&fixed.depth_enable&&fixed.depth_write_enable&&
        (temporal.execution_scene_geometry||lighting.stage==RenderExecutionStage::kSceneToGBuffer)));
  // Main GBuffer resources have explicit title-proven ownership. The renderer
  // consumes the execution camera for that view, not a still-changing CPU
  // scheduling object captured before the queued scene starts.
  const bool primary_geometry=registered_primary&&!temporal.ui_active&&!composite_draw&&
      !temporal::IsScreenExecution(temporal.execution_screen_space,lighting);
  if(primary_geometry&&!temporal.jitter_decided)temporal.AdoptExecutionCamera();
  if(temporal.active&&temporal.metadata.sequence%60==0&&temporal.diagnostic_depth_draws==1){
    const auto& p=temporal.execution_projection;
    REXLOG_INFO("gta4-temporal-execution frame={} primary={} depth-domain={} color-domain={} camera-valid={} adopted={} p={},{},{},{},{},{}",
      temporal.metadata.sequence,registered_primary,primary_depth?int(primary_depth->scale_domain):-1,primary_color?int(primary_color->scale_domain):-1,
      temporal.execution_camera_valid,temporal.adopted_camera,p[0],p[5],p[10],p[11],p[14],p[15]);
  }
  const bool execution_camera_matches=temporal.IsExecutionCamera();
  const auto scene_policy=temporal::ClassifySceneDraw(temporal_extent,temporal.ui_active,composite_draw,
      registered_primary,temporal.execution_scene_geometry,temporal.execution_screen_space,
      execution_camera_matches,lighting);
  const bool world=scene_policy.world;
  if((requested_colors&7u)==7u&&fixed.depth_enable&&fixed.depth_write_enable){
    if(!temporal.active)++gbuffer_inactive;
    else if(!temporal_extent){++gbuffer_off_extent;gbuffer_last_w=targets.width;gbuffer_last_h=targets.height;}
    else ++gbuffer_active;
  }
  if(temporal.active&&temporal_extent&&(requested_colors&7u)==7u&&fixed.depth_enable&&fixed.depth_write_enable){
    auto& a=temporal.gbuffer_audit;++a.total;
    if(world)++a.world;
    else if(temporal.ui_active)++a.ui;
    else if(composite_draw)++a.composite;
    else if(temporal::IsScreenExecution(temporal.execution_screen_space,lighting))++a.screen;
    else if(!registered_primary)++a.not_primary;
    else ++a.camera;
  }
  bool scene_blending=false;
  for(size_t i=0;i<fixed.blend_controls.size();++i)
    if((requested_colors&(uint32_t{1}<<i))&&IsNativeBlendControlEnabled(fixed.blend_controls[i]))scene_blending=true;
  targets.temporal_motion=world&&fixed.depth_enable&&fixed.depth_write_enable&&!scene_blending;
  targets.temporal_reactive=(world||scene_policy.effect)&&!targets.temporal_motion&&requested_colors;
  // gta4_temporal_trace_vs=<hex>: how that vertex shader's draws are classified (12 per 120th frame).
  const auto traced_vertex=temporal_trace_vs?shaders.find(vertex_shader):shaders.end();
  if(traced_vertex!=shaders.end()&&traced_vertex->second.hash==temporal_trace_vs&&temporal.metadata.sequence%120==0&&temporal.diagnostic_trace++<12)
    REXLOG_INFO("gta4-temporal-trace frame={} vs={:016X} ps={:016X} extent={} samples={} size={}x{} active={} ui={} composite={} "
                "registered-primary={} screen={} camera-match={} world={} effect={} motion={} reactive={} blend={} depth={}/{} colors={:X} "
                "role={} stage={}",
      temporal.metadata.sequence,traced_vertex->second.hash,pixel!=shaders.end()?pixel->second.hash:0,temporal_extent,targets.samples,
      targets.width,targets.height,temporal.active,temporal.ui_active,composite_draw,registered_primary,
      temporal::IsScreenExecution(temporal.execution_screen_space,lighting),execution_camera_matches,world,scene_policy.effect,
      targets.temporal_motion,targets.temporal_reactive,scene_blending,fixed.depth_enable,fixed.depth_write_enable,requested_colors,
      uint32_t(lighting.role),uint32_t(lighting.stage));
  targets.temporal_jitter=world&&temporal::AdmitJitter(temporal.jitter_decided,temporal.jitter_eligible,
      temporal.metadata.jitter_applied,execution_camera_matches,scene_policy.primary);
  targets.temporal_ui=temporal_extent&&temporal.ui_active&&temporal.composite_source&&targets.colors[0]==temporal.composite_source&&requested_colors;
  uint32_t temporal_ui_mode=0;
  if(targets.temporal_ui){
    const auto b=DecodeNativeBlendControl(fixed.blend_controls[0]);
    if(!IsNativeBlendControlEnabled(fixed.blend_controls[0]))temporal_ui_mode=1;
    else if(b.color_operation==0){
      if(b.source_color==1&&b.destination_color==0)temporal_ui_mode=1;
      if(b.source_color==6&&b.destination_color==7)temporal_ui_mode=2;
      if(b.source_color==1&&b.destination_color==7)temporal_ui_mode=3;
      if(b.source_color==1&&b.destination_color==1)temporal_ui_mode=4;
      if(b.source_color==6&&b.destination_color==1)temporal_ui_mode=5;
      if(b.source_color==10&&b.destination_color==11)temporal_ui_mode=7;
      if(b.source_color==10&&b.destination_color==1)temporal_ui_mode=8;
    }
    if(!temporal_ui_mode){
      if(temporal.ui_exact&&temporal.metadata.sequence%60==0)REXLOG_INFO("gta4-temporal-ui-unsupported frame={} src={} dst={} op={} src-alpha={} dst-alpha={} alpha-op={} blend={:X} vs={:X} ps={:X}",
        temporal.metadata.sequence,b.source_color,b.destination_color,b.color_operation,b.source_alpha,b.destination_alpha,b.alpha_operation,
        fixed.blend_controls[0],shaders.find(vertex_shader)!=shaders.end()?shaders.find(vertex_shader)->second.hash:0,pixel!=shaders.end()?pixel->second.hash:0);
      temporal.ui_exact=false;targets.temporal_ui=false;
    }
  }
  // Hand the GPU what is encoded so far once the frame is big enough, at a pass break this draw
  // causes anyway, before any of its uploads (they land in the next part's arena).
  if(split_commit_draws&&!frame_split&&draws-part_first_draw>=split_commit_draws&&!PassContinues(targets)&&
     !sky_visibility&&!capture_active&&!fire_active){
    if(!CommitPart(error))return false;
  }
  diagnostic_point="draw.pipeline";
  auto* pipeline=DrawPipeline(targets,fixed,vdecl->second,up,up_stride,error);
  if(!pipeline) return false;
  auto depth_state=DepthState(fixed,bool(targets.depth),error); if(!depth_state) return false;
  diagnostic_point="draw.geometry";
  MTLPrimitiveType primitive;
  switch(type) {
    case 2:primitive=MTLPrimitiveTypeLine; break;
    case 3:primitive=MTLPrimitiveTypeLineStrip; break;
    case 4:case 5:case 13:primitive=MTLPrimitiveTypeTriangle; break;
    case 6:primitive=MTLPrimitiveTypeTriangleStrip; break;
    case 8:primitive=up?MTLPrimitiveTypeTriangle:MTLPrimitiveTypeTriangleStrip; break;
    default:error="Unsupported title primitive topology"; return false;
  }
  id<MTLBuffer> indices=nil; size_t index_offset=0; bool index32=false;
  std::vector<uint32_t> converted_indices;
  if(indexed) {
    index_buffer=GuestWord(guest,12428);
    indices=resources.IndexBuffer(index_buffer,index32,error); if(!indices) return false;
    const size_t element=index32?sizeof(uint32_t):sizeof(uint16_t);
    if((uint64_t(first)+count)>indices.length/element) {error="Index draw exceeds its captured buffer"; return false;}
    index_offset=size_t(first)*element;
  }
  const bool strip=type==3 || type==6 || type==8;
  if(type==5 || type==13 || (strip && restart)) {
    if(type==13 && count%4) {error="Incomplete guest quad list"; return false;}
    // Mapping is immutable for this captured generation; do not message Metal
    // once for every index in the same fan/strip/quad conversion.
    const auto* mapping=indexed?static_cast<const uint8_t*>(indices.contents):nullptr;
    if(indexed&&!mapping){error="Converted index buffer has no CPU mapping";return false;}
    const auto* source=indexed?mapping+index_offset:nullptr;
    auto read=[&](uint32_t index) {
      if(!indexed) return first+index;
      if(index32) {uint32_t value; std::memcpy(&value,source+size_t(index)*4,4); return value;}
      uint16_t value; std::memcpy(&value,source+size_t(index)*2,2); return uint32_t(value);
    };
    auto is_restart=[&](uint32_t index) {return indexed && restart && index==restart_value;};
    if(type==5) {
      VisitNativeTriangleFan(count,read,is_restart,[&](uint32_t a,uint32_t b,uint32_t c) {
        converted_indices.insert(converted_indices.end(),{a,b,c});
      });
    } else if(type==13) {
      converted_indices.reserve(size_t(count)/4*6);
      for(uint32_t i=0;i<count;i+=4) {
        const uint32_t a=read(i),b=read(i+1),c=read(i+2),d=read(i+3);
        converted_indices.insert(converted_indices.end(),{a,b,c,a,c,d});
      }
    } else {
      converted_indices.reserve(count);
      for(uint32_t i=0;i<count;++i) {const uint32_t value=read(i); converted_indices.push_back(is_restart(value)?UINT32_MAX:value);}
    }
    if(converted_indices.empty()) return true;
    const auto upload=Upload({reinterpret_cast<const uint8_t*>(converted_indices.data()),converted_indices.size()*sizeof(uint32_t)},false,error);
    if(!upload) return false;
    indices=upload.buffer; index_offset=upload.offset; indexed=true; index32=true;
    count=uint32_t(converted_indices.size()); first=0;
  }
  std::array<id<MTLBuffer>,kVertexStreamCount> vertices{};
  std::array<NSUInteger,kVertexStreamCount> offsets{};
  if(up) {
    if(up_size>4u*1024u*1024u || !up_stride || uint64_t(up_stride)*count>up_size) {
      // Converted fan/quad index count is not the original vertex count.
      const auto original=ReadCommand<DrawPrimitiveUpCommand>(bytes);
      if(!up_stride || uint64_t(up_stride)*original.vertex_count>up_size || up_size>4u*1024u*1024u) {
        error="Invalid UP vertex payload extent"; return false;
      }
    }
    const auto payload=memory.Read(up_address,up_size); if(payload.empty()) {error="Unmapped UP vertex payload"; return false;}
    struct Input {uint32_t location; MetalVertexScalar numeric_type;};
    std::array<Input,kMetalArchiveMaximumAttributes> input_storage{};
    if(pipeline->vertex.attribute_count>input_storage.size()){error="UP vertex metadata exceeds its bound";return false;}
    for(uint32_t i=0;i<pipeline->vertex.attribute_count;++i)
      input_storage[i]={pipeline->vertex.attributes[i].semantic_location,pipeline->vertex.attributes[i].scalar_type};
    struct Inputs {std::span<const Input> vertex_inputs;} inputs{{input_storage.data(),pipeline->vertex.attribute_count}};
    const bool rectangle = type == uint32_t(xenos::PrimitiveType::kRectangleList);
    const uint64_t expanded_size = rectangle ? uint64_t(count) * 2 * up_stride : up_size;
    if (!expanded_size || expanded_size > 4u * 1024u * 1024u || (rectangle && count % 3)) {
      error = "Invalid rectangle-list payload extent"; return false;
    }
    auto upload = frame->uploads.Allocate(context->device, size_t(expanded_size), 16);
    if (!upload) { error = "UP vertex upload budget exceeded"; return false; }
    if (rectangle) {
      // Do not read write-combined GPU uploads to synthesize the fourth corner.
      std::vector<uint8_t> host_vertices(payload.size());
      core::ConvertGuestVertexPayload(host_vertices.data(), payload.data(), payload.size(),
          vdecl->second, inputs, 0, 0, up_stride);
      if (!ExpandRectangleList(host_vertices, count, up_stride, vdecl->second.elements,
          {static_cast<uint8_t*>(upload.data), size_t(expanded_size)})) {
        error = "Rectangle-list corner reconstruction failed"; return false;
      }
      count *= 2;
    } else {
      core::ConvertGuestVertexPayload(static_cast<uint8_t*>(upload.data), payload.data(), payload.size(),
          vdecl->second, inputs, 0, 0, up_stride);
    }
    vertices[0]=upload.buffer; offsets[0]=upload.offset;
  } else {
    for(uint32_t i=0;i<kVertexStreamCount;++i) {
      if(!pipeline->strides[i]) continue;
      const uint32_t handle=GuestWord(guest,12452+i*sizeof(uint32_t));
      if(!handle) {error="Active vertex stream has no guest backing"; return false;}
      vertices[i]=resources.VertexBuffer(handle,vdecl->second,pipeline->vertex,i,streams[i].offset,pipeline->strides[i],error);
      offsets[i]=streams[i].offset;
      if(!vertices[i]) return false;
    }
  }
  std::array<std::array<uint64_t,kTextureStageCount>,5> heaps{};
  for(size_t heap=0;heap<4;++heap) heaps[heap].fill(fallback_textures[heap].gpuResourceID._impl);
  heaps[4].fill(fallback_sampler.gpuResourceID._impl);
  // Borrowed: every entry is owned for the whole draw by fallback_textures, sampled_images or
  // indirect_keep (a strong array of 38 cost a retain/release per entry and a release per slot).
  std::array<id<MTLResource> __unsafe_unretained,kTextureStageCount+12> indirect{};
  std::array<id<MTLTexture>,3> indirect_keep{};  // textures indirect still names after they leave sampled_images
  std::array<id<MTLTexture>,kTextureStageCount> sampled_images{};
  std::array<ModernTextureTrace, 3> postfx_trace_inputs{};
  const bool trace_postfx = modern_diagnostics.enabled() && pipeline->has_pixel && SupportsSplitPostFx(pipeline->pixel.hash);
  diagnostic_point="draw.textures";
  size_t indirect_count=0;
  for(auto fallback:fallback_textures) indirect[indirect_count++]=fallback;
  core::SharedConstants shared{};
  const uint32_t used=pipeline->vertex.used_texture_mask | (pipeline->has_pixel?pipeline->pixel.used_texture_mask:0);
  for(uint32_t stage=0;stage<kTextureStageCount;++stage) {
    shared.texture_2d_indices[stage]=shared.texture_2d_array_indices[stage]=stage;
    shared.texture_3d_indices[stage]=shared.texture_cube_indices[stage]=shared.sampler_indices[stage]=stage;
    if(!(used&(1u<<stage))) continue;
    const uint32_t handle=GuestWord(guest,0x30F8+stage*sizeof(uint32_t));
    diagnostic_texture_stage=stage; diagnostic_texture_handle=handle;
    xenos::xe_gpu_texture_fetch_t fetch{};
    auto* words=reinterpret_cast<uint32_t*>(&fetch);
    for(size_t word=0;word<6;++word) words[word]=GuestWord(guest,0x480+stage*0x18+word*sizeof(uint32_t));
    shared.sampler_lod_bias[stage]=float(fetch.lod_bias)/32.0f;
    if(!handle) {
      if (fire_active) FireTraceLog("metal-texture",fmt::format("capture={} draw={} stage={} handle=0 fallback=true",fire_capture,fire_draw+1,stage));
      continue;
    }
    const MaterialBinding* prepared=cache_material_bindings&&!fire_active&&!profile_enabled&&!trace_postfx
        ?resources.FindMaterialBinding(handle,fetch):nullptr;
    std::shared_ptr<TextureResource> owner;
    TextureResource* resource=nullptr;
    id<MTLTexture> image=nil;id<MTLSamplerState> sampler=nil;
    if(prepared){resource=prepared->resource;image=prepared->image;sampler=prepared->sampler;}
    else{
      owner=PrepareTexture(handle,fetch,error);if(!owner)return false;
      ProfileRead(owner,1);resource=owner.get();
      if(!SettlePendingResolves(resource,error))return false;
      image=resources.View(owner,fetch,error);sampler=resources.Sampler(fetch,error,resource);
      if(!image||!sampler)return false;
      if(cache_material_bindings)prepared=resources.RememberMaterialBinding(handle,fetch,owner,image,sampler);
    }
    // Reconstruct material detail at display resolution. Shadow/depth maps,
    // reflection targets, LUTs, vertex texture fetches, UI and postfx retain
    // their original sampling contract and the title's own bias is preserved.
    const bool scene_material=world&&targets.temporal_jitter&&(prepared?prepared->mip_levels:image.mipmapLevelCount)>1&&
        (image.textureType==MTLTextureType2D||image.textureType==MTLTextureType2DArray)&&
        !resource->gpu_produced&&!resources.Virtual(handle)&&
        pipeline->has_pixel&&(pipeline->pixel.used_texture_mask&(1u<<stage))&&
        !(pipeline->vertex.used_texture_mask&(1u<<stage));
    shared.sampler_lod_bias[stage]+=temporal::MaterialMipBias(temporal.config,scene_material);
    if (fire_active) FireTraceLog("metal-texture",fmt::format(
        "capture={} draw={} stage={} handle={:08X} generation={} serial={} initialized={} gpu-produced={} format={} extent={}x{} fallback=false fetch={:08X},{:08X},{:08X},{:08X},{:08X},{:08X}",
        fire_capture,fire_draw+1,stage,handle,resource->generation,resource->content_serial,resource->initialized,resource->gpu_produced,
        uint32_t(image.pixelFormat),image.width,image.height,words[0],words[1],words[2],words[3],words[4],words[5]));
    for(const auto& color:targets.colors) if(color && color->image==resource->image) {error="Draw samples its active color attachment"; return false;}
    if(targets.depth && targets.depth->image==resource->image) {error="Draw samples its active depth attachment"; return false;}
    const size_t heap=prepared?prepared->heap:image.textureType==MTLTextureTypeCube?3:image.textureType==MTLTextureType3D?2:image.textureType==MTLTextureType2DArray?1:0;
    heaps[heap][stage]=prepared?prepared->image_id:image.gpuResourceID._impl;
    heaps[4][stage]=prepared?prepared->sampler_id:sampler.gpuResourceID._impl;
    indirect[indirect_count++]=image;
    sampled_images[stage]=image;
    if (trace_postfx && stage < postfx_trace_inputs.size())
      postfx_trace_inputs[stage] = {handle, uint32_t(image.width), uint32_t(image.height), resource->generation, resource->initialized};
  }
  diagnostic_point="draw.modern-effects";
  const bool cloud_draw = modern.settings().enabled && pipeline->has_pixel &&
      (pipeline->variant & 2u) && IsFusionSkyShader(pipeline->pixel.hash) &&
      std::none_of(targets.colors.begin(), targets.colors.end(), [&](const auto& color) {
        return color && resources.IsReflection(color->descriptor.handle);
      });
  if (cloud_draw) {
    fusion_cloud_ready = false;
    const uint64_t bytes = uint64_t(targets.width) * targets.height * sizeof(float);
    if (bytes && bytes <= 128ull * 1024 * 1024) {
      if (!fusion_cloud_mask || fusion_cloud_mask.length != bytes)
        fusion_cloud_mask = [context->device newBufferWithLength:bytes options:MTLResourceStorageModePrivate];
      if (fusion_cloud_mask) {
        EndRender();
        auto clear = [commands blitCommandEncoder];
        if (clear) {
          [clear fillBuffer:fusion_cloud_mask range:NSMakeRange(0, bytes) value:0];
          [clear endEncoding];
          fusion_cloud_width = targets.width; fusion_cloud_height = targets.height;
          fusion_cloud_ready = true;
        }
      }
    }
  }
  if(composite_draw&&!stock_composite_filter){
    EndRender();std::string temporal_error;
    const auto exposure=temporal::ExposureForShader(pixel->second.hash);
    if(!exposure||!temporal.SetExposure(commands,sampled_images[exposure->adaptation_stage],
        std::bit_cast<float>(GuestWord(guest,exposure->exposure_guest_offset)),
        std::bit_cast<float>(GuestWord(guest,exposure->tone_guest_offset)),temporal_error)){
      error=exposure?temporal_error:"temporal composite exposure contract missing";return false;
    }
    const auto stage=composite_contract->scene_stage;
    temporal.composite_shader=pixel->second.hash;temporal.composite_scene_stage=stage;
    if(auto reconstructed=temporal.Resolve(commands,sampled_images[stage],temporal_error)){
      indirect_keep[0]=sampled_images[stage];
      sampled_images[stage]=reconstructed;heaps[0][stage]=reconstructed.gpuResourceID._impl;indirect[indirect_count++]=reconstructed;
    }else{
      // A failed allocation/encode must not silently expose a jittered scene.
      error="temporal composite output failed: "+temporal_error;return false;
    }
  }
  if (modern.settings().enabled && pipeline->has_pixel && (pipeline->variant & 2u) &&
      SupportsSplitPostFx(pipeline->pixel.hash) && Phase() == RenderPhase::kCompositePostFx) {
    SplitPostFxParameters parameters;
    for (size_t component = 0; component < 4; ++component) {
      parameters.dof_projection[component] = std::bit_cast<float>(GuestWord(guest, 0x2490 + component * sizeof(uint32_t)));
      parameters.dof_distance[component] = std::bit_cast<float>(GuestWord(guest, 0x24A0 + component * sizeof(uint32_t)));
      parameters.dof_blur[component] = std::bit_cast<float>(GuestWord(guest, 0x24B0 + component * sizeof(uint32_t)));
    }
    EndRender();
    std::string dof_error;
    const auto postfx_half_scene = resources.FindTexture(postfx_half_scene_handle);
    if (!SettlePendingResolves(postfx_half_scene.get(), error)) return false;
    auto half_scene = postfx_half_scene && postfx_half_scene->initialized
        ? postfx_half_scene->image : nil;
    if(composite_draw&&temporal.HasSceneOutput()&&temporal_upscale)half_scene=temporal.ResampleHalf(commands,half_scene,dof_error);
    auto filtered = depth_of_field.Record(context, commands, sampled_images[2], half_scene,
        sampled_images[1], sampled_images[0], parameters, dof_error);
    const bool dof_applied = filtered != nil;
    if (trace_postfx) {
      ModernDofTrace trace;
      trace.pixel = pipeline->pixel.hash; trace.phase = uint32_t(Phase());
      trace.scene = postfx_trace_inputs[2]; trace.depth = postfx_trace_inputs[1]; trace.mask = postfx_trace_inputs[0];
      trace.half_scene = {postfx_half_scene_handle, uint32_t(half_scene.width), uint32_t(half_scene.height),
          postfx_half_scene ? postfx_half_scene->generation : 0, half_scene != nil};
      trace.parameters = parameters; trace.encoded = dof_applied;
      trace.reason = dof_applied ? "FusionFix-chain-recorded" : std::string_view(dof_error);
      modern_diagnostics.Dof(trace);
    }
    if (fusion_cloud_ready) {
      auto sun_parameters = BuildSunShaftParameters(&environment, parameters.dof_projection);
      sun_parameters.cloud_mask_address = fusion_cloud_mask.gpuAddress;
      sun_parameters.cloud_width = fusion_cloud_width; sun_parameters.cloud_height = fusion_cloud_height;
      std::string sun_error;
      auto sun_result = sun_shafts.Record(context, commands, filtered ? filtered : sampled_images[2],
          sampled_images[1], fusion_cloud_mask, sun_parameters, sun_error);
      if (sun_result) filtered = sun_result;
      modern_diagnostics.Sun(pipeline->pixel.hash, sun_parameters, &environment,
          sun_result != nil && sun_parameters.valid,
          !sun_parameters.valid ? "inactive-sun-or-invalid-environment-projection" :
          sun_result ? "prepass-radial24-radial24-add-recorded" : std::string_view(sun_error));
    } else {
      modern_diagnostics.Sun(pipeline->pixel.hash, {}, &environment, false, "cloud-mask-not-produced-this-frame");
    }
    if (filtered) {
      heaps[0][2] = filtered.gpuResourceID._impl;
      indirect_keep[1] = filtered;
      indirect[indirect_count++] = filtered;
      shared.split_postfx_applied = dof_applied ? 1.0f : 0.0f;
    }
  } else if (trace_postfx) {
    modern_diagnostics.SkipPostFx(pipeline->pixel.hash, uint32_t(Phase()),
        !modern.settings().enabled ? "modern-shaders-off" :
        !(pipeline->variant & 2u) ? "replacement-not-selected" : "outside-composite-phase");
  }
  for(uint32_t i=0;i<4;++i) shared.color_output[i]=NativeColorOutput(color_bindings[i].address,targets.color_mask&(1u<<i));
  shared.booleans=PackNativeShaderBooleans(GuestWord(guest,0x2780),GuestWord(guest,0x2790));
  shared.half_pixel_offset_x=1.0f/float(targets.logical_width);
  shared.half_pixel_offset_y=-1.0f/float(targets.logical_height);
  if(scene_policy.primary&&execution_camera_matches)
    temporal.camera_half_pixel={shared.half_pixel_offset_x,shared.half_pixel_offset_y};
  shared.fragment_coordinate_scale_x=float(targets.logical_width)/float(targets.width);
  shared.fragment_coordinate_scale_y=float(targets.logical_height)/float(targets.height);
  for(size_t i=0;i<4;++i) shared.clip_plane[i]=std::bit_cast<float>(fixed.clip_plane_bits[i]);
  shared.clip_plane_enabled=(fixed.user_clip_plane_enable_mask&1u)!=0;
  shared.alpha_threshold=fixed.alpha_reference; shared.alpha_to_mask=fixed.alpha_to_mask; shared.alpha_to_mask_sample_count=targets.samples;
  if (modern.settings().enabled && !fusion_tone_lut) {
    fusion_tone_lut = [context->device newBufferWithBytes:kFusionToneLut.data()
        length:sizeof(kFusionToneLut) options:MTLResourceStorageModeShared];
    if (!fusion_tone_lut) { error = "Fusion tone LUT allocation failed"; return false; }
    fusion_tone_lut.label = @"FusionFix default tone LUT";
  }
  shared.modern_effects = BuildModernEffectConstants(modern.settings().enabled,
      fusion_tone_lut ? fusion_tone_lut.gpuAddress : 0, &environment);
  for (size_t i = 0; i < 4; ++i)
    shared.modern_effects.viewport[i] = std::bit_cast<float>(fixed.viewport_bits[i]) *
        (i % 2 == 0 ? float(targets.width) / targets.logical_width : float(targets.height) / targets.logical_height);
  shared.modern_effects.depth_range[0] = std::clamp(std::bit_cast<float>(fixed.viewport_bits[4]), 0.0f, 1.0f);
  shared.modern_effects.depth_range[1] = std::clamp(std::bit_cast<float>(fixed.viewport_bits[5]), 0.0f, 1.0f);
  shared.modern_effects.reserved = std::any_of(targets.colors.begin(), targets.colors.end(),
      [&](const auto& color) { return color && resources.IsWaterReflection(color->descriptor.handle); });
  if (cloud_draw && fusion_cloud_ready) {
    shared.modern_effects.cloud_mask_address = fusion_cloud_mask.gpuAddress;
    shared.modern_effects.cloud_mask_width = fusion_cloud_width;
    shared.modern_effects.cloud_mask_height = fusion_cloud_height;
  }
  shared.environmental_valid_fields=environment.valid_fields;
  shared.fog_parameters[0]=environment.fog_density; shared.fog_parameters[1]=environment.fog_height_falloff;
  shared.fog_parameters[2]=environment.fog_altitude_tweak; shared.fog_parameters[3]=environment.fog_power;
  std::copy(environment.camera_position.begin(),environment.camera_position.end(),shared.camera_position);
  std::copy(environment.view_inverse_matrix.begin(),environment.view_inverse_matrix.end(),shared.view_inverse_matrix);
  shared.projection_scale[0]=environment.projection_matrix[0]; shared.projection_scale[1]=environment.projection_matrix[5];
  constexpr uint64_t motion_fields = EnvironmentalFieldBit(EnvironmentalField::kTimeStepSeconds) |
      EnvironmentalFieldBit(EnvironmentalField::kDirectionalMotionBlurLength);
  shared.motion_blur_time_scale = 1.0f;
  if ((environment.valid_fields & motion_fields) == motion_fields &&
      std::isfinite(environment.time_step_seconds) && environment.time_step_seconds > 0 &&
      std::isfinite(environment.directional_motion_blur_length)) {
    const float reference = 1.0f / 30.0f;
    const float scale = reference / std::min(reference, environment.time_step_seconds);
    if (std::isfinite(scale) && scale >= 1.0f) shared.motion_blur_time_scale = scale;
  }
  temporal::DrawParameters temporal_parameters{};
  temporal_parameters.input_extent={float(targets.width),float(targets.height)};
  if(targets.temporal_jitter)temporal_parameters.jitter_clip={2*temporal.metadata.jitter[0]/targets.width,-2*temporal.metadata.jitter[1]/targets.height};
  temporal_parameters.ui_mode=temporal_ui_mode;
  temporal_parameters.reactive=targets.temporal_reactive?(temporal_reactive_weighting?ReactiveMode(fixed,requested_colors,scene_policy.effect):1u):0u;
  ui::metal::UploadSlice previous_vertex,previous_shared;
  uint64_t previous_vertex_address=0;
  bool standard_motion_depth=temporal::StandardDepthViewport(shared);
  raytracing::DrawGeometry capture_geometry;  // identity 0: this draw is not captured
  if(targets.temporal_motion){
    std::array<uint8_t,4096> captured_vertex{};
    core::CopyGuestWordsToHost(captured_vertex.data(),guest.data()+0x780,captured_vertex.size());
    std::array<uint64_t,kVertexStreamCount+3> identities{};
    for(size_t i=0;i<vertices.size();++i)identities[i]=vertices[i]?resources.CapturedBufferGeneration(GuestWord(guest,12452+i*sizeof(uint32_t))):0;
    identities[kVertexStreamCount]=source_indexed&&index_buffer?resources.CapturedBufferGeneration(index_buffer):0;
    identities[kVertexStreamCount+1]=uint32_t(base_vertex);identities[kVertexStreamCount+2]=uint64_t(source_first)<<32|source_count;
    bool captured_bindings=!source_indexed||identities[kVertexStreamCount]!=0;
    for(size_t i=0;i<vertices.size();++i)if(vertices[i]&&!identities[i])captured_bindings=false;
    const uint64_t generation=up||!captured_bindings?0:XXH3_64bits(identities.data(),sizeof(identities));
    // Exact world-transform identity is a conservative static fallback: a
    // changed transform creates a new key, rather than borrowing another pose.
    // Unscoped: the world transform registers the shader reads (c0-c2 for gta_trees, so the
    // unread c3 cannot split one tree's key). A shader reading none of c0-c3 (the deferred tire)
    // keeps all four: there they still hold the car body's gWorld, steady under camera motion,
    // and the read-mask sibling match tells that car's wheels apart.
    const auto& constant_reads=pipeline->vertex.float_constant_mask;
    uint64_t owner=temporal.instance;
    if(!owner){
      std::array<uint8_t,64> world{};
      const uint64_t read_world=constant_reads[0]&0xFull;
      for(size_t r=0;r<4;++r)if(!read_world||(read_world>>r&1))std::memcpy(world.data()+r*16,captured_vertex.data()+r*16,16);
      owner=XXH3_64bits(world.data(),world.size());
    }
    temporal::GeometryKey key{owner,temporal.drawable,temporal.pose,pipeline->vertex.hash,
      vdecl->second.identity,generation,uint64_t(source_first)<<32|source_count};
    key.pixel_shader=pipeline->has_pixel?pipeline->pixel.hash:0;
    key.index_generation=identities[kVertexStreamCount];key.base_vertex=base_vertex;
    static_assert(temporal::GeometryKey{}.streams.size()==kVertexStreamCount);
    for(size_t i=0;i<vertices.size();++i)if(vertices[i])
      key.streams[i]={identities[i],streams[i].offset,pipeline->strides[i]};
    key.primitive=type;key.indexed=source_indexed;key.restart=restart;
    key.restart_index=restart?restart_value:0;
    if(raytracing_mode!=raytracing::Mode::kOff&&generation&&pipeline->capture){
      raytracing::ScopedCpuTime timed(raytracing_prelude_time);
      capture_geometry.identity=raytracing::GeometryIdentityOf(key);
      capture_geometry.placement=raytracing::PlacementOf(constant_reads,captured_vertex);
    }
    auto history=temporal.geometry.Record(key,captured_vertex,Bytes(shared),temporal_parameters.jitter_clip,constant_reads);
    // A vertex shader reading a texture recomputes the previous position with this frame's
    // texture: exact while that texture is unchanged (vehicle damage changes rarely).
    const bool vertex_texture_history=!pipeline->vertex.used_texture_mask||temporal_vertex_texture_history;
    if(history.previous&&vertex_texture_history&&!temporal.metadata.camera_cut){
      core::SharedConstants prior_shared{};
      if(history.previous->shared.size()!=sizeof(prior_shared)){
        error="temporal shared-constant history layout changed";return false;
      }
      std::memcpy(&prior_shared,history.previous->shared.data(),sizeof(prior_shared));
      standard_motion_depth&=temporal::StandardDepthViewport(prior_shared);
      // The variant runs the same vertex function on this bank, so it reads the current shader's range.
      if(range_constants_enabled){
        const auto previous=UploadRange(SIZE_MAX,history.previous->vertex,RangeOf(pipeline->vertex.float_constant_mask,256),false,error);
        previous_vertex=previous.slice;previous_vertex_address=previous.address;
        previous_shared=Upload(history.previous->shared,false,error);
      }else if(const auto* snapshot=UploadSnapshot(history.previous,error)){
        previous_vertex=snapshot->vertex;previous_vertex_address=previous_vertex.gpu_address;previous_shared=snapshot->shared;
      }
      if(shadow_range_constants){  // the variant reads the previous bank at the current shader's offsets
        ++previous_bank_uploads;previous_bank_range_bytes+=size_t(RangeOf(pipeline->vertex.float_constant_mask,256).registers())*16;
      }
      if(!previous_vertex||!previous_shared)return false;
      temporal_parameters.valid_history=1;temporal_parameters.previous_jitter_clip=history.previous->jitter_clip;
    }
    if(history.ambiguous){temporal_parameters.valid_history=0;temporal_parameters.reactive=1;}
    const bool traced=temporal_trace_vs&&pipeline->vertex.hash==temporal_trace_vs;
    if(!temporal_parameters.valid_history&&temporal.metadata.sequence%60==0&&(traced||temporal.diagnostic_missing_motion++<12))
      REXLOG_INFO("gta4-temporal-missing-motion frame={} vs={:016X} ps={:016X} owner={:X} scoped={} drawable={:X} pose={:X} generation={:X} range={:X} reason={}",
        temporal.metadata.sequence,pipeline->vertex.hash,key.pixel_shader,owner,bool(temporal.instance),temporal.drawable,temporal.pose,generation,key.range,
        temporal.metadata.camera_cut?"camera-cut":history.ambiguous?"ambiguous-owner":
        !vertex_texture_history?"vertex-texture-history":!generation?"uncaptured-geometry":
        !history.captured?"history-budget":!history.previous?"no-previous-key":"invalid-history");
  }
  diagnostic_point="draw.constants";
  if(shadow_range_constants){  // BACKLOG 75 model; reads tracking state before Upload marks the banks copied
    const bool tracked=track_guest_constants&&!guest_constant_tracking_failed;
    range_constants.Observe(0,guest.subspan(0x780,0x1000),RangeOf(pipeline->vertex.float_constant_mask,256),tracked&&guest_constants.Clean(0));
    if(pipeline->has_pixel)range_constants.Observe(1,guest.subspan(0x1780,0xE00),RangeOf(pipeline->pixel.float_constant_mask,224),tracked&&guest_constants.Clean(1));
  }
  const auto vertex_bank=range_constants_enabled&&range_constants_vertex
      ?UploadRange(0,guest.subspan(0x780,0x1000),RangeOf(pipeline->vertex.float_constant_mask,256),true,error)
      :WholeBank(Upload(guest.subspan(0x780,0x1000),true,error),0x1000);
  // No fragment function can read this bank in a depth-only pipeline. Leave
  // its dirty observation pending so the next real fragment consumer refreshes.
  const auto pixel_bank=!pipeline->has_pixel?vertex_bank:range_constants_enabled
      ?UploadRange(1,guest.subspan(0x1780,0xE00),RangeOf(pipeline->pixel.float_constant_mask,224),true,error)
      :WholeBank(Upload(guest.subspan(0x1780,0xE00),true,error),0xE00);
  const auto& vertex_constants=vertex_bank.slice;
  const auto& pixel_constants=pixel_bank.slice;
  if(!pipeline->has_pixel)++skipped_pixel_constant_banks;
  auto shared_constants=Upload(Bytes(shared),false,error);
  auto heap_upload=Upload(Bytes(heaps),false,error);
  if(!vertex_constants || !pixel_constants || !shared_constants || !heap_upload) return false;
  std::array<float,6> viewport{};
  bool draw_encoded=false;
  auto encode_draw=[&]() -> bool {
  diagnostic_point="draw.pipeline-complete";
  // Only scene geometry, drawn again every frame, may be left out while its
  // pipeline compiles; post-processing, lights, the radar and UI always wait.
  bool pipeline_deferred=false;
  const bool may_defer=Phase()==gta4_native::RenderPhase::kSceneToGBuffer&&!fire_active;
  if (!CompletePipeline(*pipeline, error, may_defer?&pipeline_deferred:nullptr)) return false;
  if (pipeline_deferred) return true;
  FireBeforeDraw(targets,fixed,*pipeline,guest,type,count,base_vertex);
  if (fire_active) for (uint32_t stage=0; stage<sampled_images.size(); ++stage) {
    if (!sampled_images[stage]) continue;
    const auto handle=GuestWord(guest,0x30F8+stage*sizeof(uint32_t));
    FireInspect(sampled_images[stage],fmt::format("input-stage{}",stage),handle,fire_draw);
    if (FireDetailed()) FireSnapshot(sampled_images[stage],fmt::format("detail-input{}",stage),handle);
  }
  if(!BeginRender(targets,error)) return false;
  const bool trace_sky=modern_diagnostics.Sky(pipeline->vertex.hash,
      pipeline->has_pixel?pipeline->pixel.hash:0,targets.samples,pipeline->variant,
      targets.colors[0]?targets.colors[0]->descriptor.handle:0);
  std::shared_ptr<ModernSkyProbe::Capture> sky_capture;
  if(trace_sky) {
    const auto c=targets.colors[0];
    const auto context=fmt::format("trace-frame={} command={} submission={} phase={} vs={:016X} ps={:016X} "
        "variant={} target={:08X} generation={} extent={}x{} samples={}",modern_diagnostics.frame(),diagnostic_command,
        submitted,uint32_t(Phase()),pipeline->vertex.hash,pipeline->pixel.hash,pipeline->variant,
        c?c->descriptor.handle:0,c?c->generation:0,targets.width,targets.height,targets.samples);
    REXLOG_INFO("gta4-modern-exec: backend=metal event=sky-state {} primitive={} count={} cull={} "
        "color-mask={:04X} depth={}:{}:{} alpha={}:{}:{} sample-mask={:08X} "
        "viewport={},{},{},{},{},{} scissor={},{},{},{} reflection={} environment-seq={} valid={:016X}",context,
        type,count,fixed.cull_mode,fixed.color_write_mask,fixed.depth_enable,fixed.depth_write_enable,fixed.depth_function,
        fixed.alpha_test_enable,fixed.alpha_function,fixed.alpha_reference,fixed.sample_mask,
        std::bit_cast<float>(fixed.viewport_bits[0]),std::bit_cast<float>(fixed.viewport_bits[1]),
        std::bit_cast<float>(fixed.viewport_bits[2]),std::bit_cast<float>(fixed.viewport_bits[3]),
        std::bit_cast<float>(fixed.viewport_bits[4]),std::bit_cast<float>(fixed.viewport_bits[5]),
        fixed.scissor[0],fixed.scissor[1],fixed.scissor[2],fixed.scissor[3],shared.modern_effects.reserved,
        environment.source_sequence,environment.valid_fields);
    const auto depth=targets.depth;
    REXLOG_INFO("gta4-modern-exec: backend=metal event=sky-output-state command={} depth={:08X}@{} "
        "stencil={}:{}:{:02X}:{:02X} blend={}:{:08X} alpha-to-mask={:03X} clip={:08X} "
        "sky={},{},{},{} azimuth={},{},{},{} cloud-mask-bound={}",diagnostic_command,
        depth?depth->descriptor.handle:0,depth?depth->generation:0,fixed.stencil_enable,fixed.stencil_function,
        fixed.stencil_reference,fixed.stencil_mask,fixed.blend_enable,fixed.blend_controls[0],fixed.alpha_to_mask,fixed.clip_control,
        shared.modern_effects.sky_color_exposure[0],shared.modern_effects.sky_color_exposure[1],
        shared.modern_effects.sky_color_exposure[2],shared.modern_effects.sky_color_exposure[3],
        shared.modern_effects.azimuth_color_height[0],shared.modern_effects.azimuth_color_height[1],
        shared.modern_effects.azimuth_color_height[2],shared.modern_effects.azimuth_color_height[3],
        shared.modern_effects.cloud_mask_address!=0);
    const auto constants=[&](const char* bank,const BankUpload& upload,size_t first,size_t end){
      const auto* values=static_cast<const std::array<float,4>*>(upload.slice.data);
      // A range upload holds only the registers this shader reads.
      for(size_t i=std::max<size_t>(first,upload.range.lo);i<end&&i<=upload.range.hi;++i){const auto& v=values[i-upload.range.lo];
        REXLOG_INFO("gta4-modern-exec: backend=metal event=sky-constant command={} bank={} register={} "
            "value={},{},{},{} finite={}",diagnostic_command,bank,i,v[0],v[1],v[2],v[3],
            std::all_of(v.begin(),v.end(),[](float x){return std::isfinite(x);}));
      }
    };
    constants("vertex",vertex_bank,0,12); constants("vertex",vertex_bank,64,76);
    constants("pixel",pixel_bank,64,91);
    for(uint32_t stage=0;stage<sampled_images.size();++stage)if(used&(1u<<stage)){
      const auto image=sampled_images[stage];
      REXLOG_INFO("gta4-modern-exec: backend=metal event=sky-texture command={} stage={} handle={:08X} "
          "bound={} extent={}x{} format={}",diagnostic_command,stage,GuestWord(guest,0x30F8+stage*sizeof(uint32_t)),
          bool(image),image.width,image.height,uint32_t(image.pixelFormat));
    }
    if(ModernShaderGpuProbeEnabled() && c){
      EndRender(); std::string probe_error;
      sky_capture=sky_probe.Start(this->context->device,commands,c->image,context,probe_error);
      if(sky_capture)sky_visibility=sky_capture->visibility;
      else REXLOG_ERROR("gta4-modern-exec: backend=metal event=sky-probe-unavailable {} reason={}",context,probe_error);
      if(!BeginRender(targets,error))return false;
    }
  }
  // gta4_metal_lighting_dump=<dir> (diagnostics): one frame per new value.
  {
    static std::string dump_value; static uint64_t dump_sequence=~0ull;
    static bool dump_written=false; static uint32_t dump_logged=0;
    static __strong id<MTLTexture> dump_after=nil;
    const bool deferred=lighting.stage==RenderExecutionStage::kDeferredLighting;
    const std::string dump_dir=deferred?std::string(REXCVAR_GET(gta4_metal_lighting_dump)):std::string();
    if(dump_after&&deferred){
      EndRender();
      DumpLightingTexture(commands,dump_after,dump_value+"/global-target-after.raw");
      dump_after=nil;
      if(!BeginRender(targets,error))return false;
    }
    if(!dump_dir.empty()&&dump_dir!=dump_value&&deferred){
      dump_value=dump_dir; dump_sequence=temporal.metadata.sequence; dump_written=false; dump_logged=0;
    }
    if(deferred&&!dump_dir.empty()&&dump_sequence==temporal.metadata.sequence&&dump_logged<64){
      ++dump_logged;
      std::string textures,colors;
      for(uint32_t st=0;st<kTextureStageCount;++st)
        if(auto im=sampled_images[st])textures+=fmt::format(" t{}={}:{}x{}",st,uint32_t(im.pixelFormat),im.width,im.height);
      for(size_t i=0;i<targets.colors.size();++i)
        if(targets.colors[i]&&targets.colors[i]->image)
          colors+=fmt::format(" c{}={}:{}x{}",i,uint32_t(targets.colors[i]->image.pixelFormat),
                              targets.colors[i]->image.width,targets.colors[i]->image.height);
      REXLOG_INFO("gta4-metal-lighting-dump frame={} draw={} vs={:016X} {} ps={:016X} {} role={} blend={} depth-test={} "
                  "depth-write={} count={} colors:{} depth={} textures:{}",
          temporal.metadata.sequence,dump_logged,pipeline->vertex.hash,pipeline->vertex.name,
          pipeline->has_pixel?pipeline->pixel.hash:0,pipeline->has_pixel?pipeline->pixel.name:"",uint32_t(lighting.role),
          scene_blending,fixed.depth_enable,fixed.depth_write_enable,count,colors,
          targets.depth&&targets.depth->image?uint32_t(targets.depth->image.pixelFormat):0,textures);
      if(!dump_written&&lighting.role==LightPassRole::kGlobalContribution&&targets.colors[0]&&targets.colors[0]->image){
        dump_written=true;
        EndRender();
        for(uint32_t st=0;st<kTextureStageCount;++st)
          if(auto im=sampled_images[st])
            DumpLightingTexture(commands,im,fmt::format("{}/global-t{}-{}.raw",dump_dir,st,uint32_t(im.pixelFormat)));
        DumpLightingTexture(commands,targets.colors[0]->image,dump_dir+"/global-target-before.raw");
        if(temporal.CaptureDepth(commands,error)&&temporal.depth_captured)
          DumpLightingTexture(commands,temporal.inputs.depth,dump_dir+"/scene-depth.raw");
        error.clear();
        dump_after=targets.colors[0]->image;
        if(!BeginRender(targets,error))return false;
      }
    }
  }
  // Ray-traced AO / sun shadows: once per frame, just before the deferred lighting's global
  // contribution (lightShadowDirectional / lightNoDirectional), from the finished scene depth
  // and the frame's captured scene. The lighting draw's own pass is reopened afterwards.
  const bool rt_lighting=(raytracing_ao.initialized()||raytracing_shadows.initialized())&&
      lighting.stage==RenderExecutionStage::kDeferredLighting&&
      lighting.role==LightPassRole::kGlobalContribution&&targets.colors[0]&&temporal.depth_source&&
      temporal.depth_source->image&&targets.width==temporal.depth_source->image.width&&
      targets.height==temporal.depth_source->image.height;
  const bool ao_lighting=rt_lighting&&raytracing_ao.initialized();
  const bool shadow_lighting=rt_lighting&&raytracing_shadows.initialized();
  if(rt_lighting){
    ++raytracing_ao_lighting_draws;
    if(raytracing_ao_sequence!=temporal.metadata.sequence&&raytracing_capture.has_camera()){
      // The whole hook: pass split (EndRender, BeginRender), depth snapshot, scene and trace encodes.
      raytracing::ScopedCpuTime hook_timed(raytracing_hook_time);
      raytracing_ao_sequence=temporal.metadata.sequence;
      raytracing_ao_texture=nil; raytracing_shadow_texture=nil;
      const auto clip_to_world=raytracing::ClipToWorldColumns(temporal.actual_projection,temporal.actual_inverse);
      EndRender();
      std::string rt_error;
      // The scene depth attachment is resolved and cleared before the lighting: read the
      // temporal snapshot taken at that resolve (or take it now if there was none).
      const bool depth_ready=temporal.CaptureDepth(commands,rt_error)&&temporal.depth_captured&&temporal.inputs.depth;
      if(id<MTLAccelerationStructure> scene=clip_to_world&&depth_ready?raytracing_capture.EncodeScene(commands,rt_error):nil){
        raytracing::AoFrame f;
        f.scene=scene; f.structures=raytracing_capture.heap();
        f.depth=temporal.inputs.depth; f.motion=temporal.inputs.motion;
        // GBufferTextureSampler1 of the lighting draw: the world normal (normal modes gbuffer*).
        if(const auto normals=sampled_images[1];normals&&normals.pixelFormat==MTLPixelFormatRGBA8Unorm&&
           normals.width==f.depth.width&&normals.height==f.depth.height)f.normals=normals;
        f.clip_to_world=*clip_to_world;
        // actual_inverse is camera-to-world with row vectors: its last row is the camera position.
        f.camera_position={temporal.actual_inverse[12],temporal.actual_inverse[13],temporal.actual_inverse[14]};
        f.reversed_depth=temporal.config.depth_reversed; f.camera_cut=temporal.metadata.camera_cut;
        // The depth was rendered jittered (as temporal_parameters.jitter_clip): reconstruction removes it.
        if(temporal.metadata.jitter_applied)
          f.jitter_ndc={2*temporal.metadata.jitter[0]/float(f.depth.width),-2*temporal.metadata.jitter[1]/float(f.depth.height)};
        f.captured_positions=raytracing_capture.positions(f.captured_vertices);
        if(ao_lighting){
          raytracing_ao_settings=raytracing::CurrentAoSettings();
          raytracing_ao_texture=raytracing_ao.Encode(commands,f,raytracing_ao_settings,rt_error);
        }
        if(shadow_lighting&&rt_error.empty()){
          // gDirectionalLight is pixel c17 of this draw (lightShadowDirectional); lightNoDirectional
          // leaves no sun there and the trace returns all lit.
          std::array<float,4> directional_light{};
          core::CopyGuestWordsToHost(reinterpret_cast<uint8_t*>(directional_light.data()),guest.data()+0x1780+17*16,sizeof(directional_light));
          raytracing_shadow_settings=raytracing::CurrentShadowSettings();
          raytracing_shadow_texture=raytracing_shadows.Encode(commands,f,raytracing::TowardsSun(directional_light),
                                                              raytracing_shadow_settings,rt_error);
        }
      }
      if(!rt_error.empty())REXLOG_ERROR("gta4-metal-raytracing: lighting trace failed: {}",rt_error);
      if(!BeginRender(targets,error))return false;
    }
  }
  diagnostic_point="draw.encode";
  // Ambient-only AO: the lighting shader's AO variant, with this frame's AO at fragment texture 0
  // (no translated shader uses direct texture slots). Otherwise the multiply after the draw.
  id<MTLRenderPipelineState> draw_state=pipeline->state;
  bool ao_ambient=false;
  if(ao_lighting&&raytracing_ao_texture&&raytracing_ao_sequence==temporal.metadata.sequence&&
     raytracing_ao_settings.view==raytracing::AoView::kApply&&pipeline->ambient){
    if(!pipeline->ambient_state){
      std::lock_guard lock(pipeline->ambient->mutex);
      if(pipeline->ambient->complete)pipeline->ambient_state=pipeline->ambient->state;
    }
    if(pipeline->ambient_state){
      draw_state=pipeline->ambient_state; ao_ambient=true;
      [render setFragmentTexture:raytracing_ao_texture atIndex:0];
      ++raytracing_ao_ambient_draws;
    }
  }
  // Sun shadows: the lighting shader's shadow variant, this frame's shadows at fragment texture 1.
  if(shadow_lighting&&raytracing_shadow_texture&&raytracing_ao_sequence==temporal.metadata.sequence&&
     raytracing::ShadowViewUsesVariant(raytracing_shadow_settings.view)&&pipeline->sunlit&&!ao_ambient){
    if(!pipeline->sunlit_state){
      std::lock_guard lock(pipeline->sunlit->mutex);
      if(pipeline->sunlit->complete)pipeline->sunlit_state=pipeline->sunlit->state;
    }
    if(pipeline->sunlit_state){
      draw_state=pipeline->sunlit_state;
      [render setFragmentTexture:raytracing_shadow_texture atIndex:1];
      ++raytracing_shadow_draws;
    }
  }
  bindings.Pipeline(render,draw_state); bindings.Depth(render,depth_state);
  bindings.Vertex(render,default_vertex,0,30);
  for(size_t i=0;i<vertices.size();++i) if(vertices[i]) bindings.Vertex(render,vertices[i],offsets[i],9+i);
  std::array<NSUInteger,5> argument_offsets{};
  for(size_t i=0;i<argument_offsets.size();++i) argument_offsets[i]=heap_upload.offset+i*sizeof(heaps[0]);
  bindings.Arguments(render,heap_upload.buffer,argument_offsets);
  const std::array<uint64_t,3> push{vertex_bank.address,
      pixel_bank.address,shared_constants.gpu_address};
  bindings.Push(render,push);
  if(pipeline->temporal_variant){
    const std::array<uint64_t,3> prior{previous_vertex?previous_vertex_address:push[0],push[1],previous_shared?previous_shared.gpu_address:push[2]};
    [render setVertexBytes:&temporal_parameters length:sizeof(temporal_parameters) atIndex:6];
    [render setFragmentBytes:&temporal_parameters length:sizeof(temporal_parameters) atIndex:6];
    [render setVertexBytes:prior.data() length:sizeof(prior) atIndex:7];
    if(previous_vertex){const std::array<id<MTLResource>,2> r{previous_vertex.buffer,previous_shared.buffer};bindings.ReadResources(render,r.data(),r.size());}
  }
  bindings.ReadResources(render,indirect.data(),indirect_count);
  if (shared.modern_effects.cloud_mask_address)
    [render useResource:fusion_cloud_mask usage:MTLResourceUsageWrite stages:MTLRenderStageFragment];
  if (shared.modern_effects.tone_lut_address) {
    const id<MTLResource> lut_resource = fusion_tone_lut;
    bindings.ReadResources(render, &lut_resource, 1);
  }
  const std::array<id<MTLResource>,3> constant_resources{vertex_constants.buffer,pixel_constants.buffer,shared_constants.buffer};
  bindings.ReadResources(render,constant_resources.data(),constant_resources.size());
  const auto cull=DecodeNativeCullRasterState(fixed.cull_mode);
  if(!cull.valid() || !fixed.depth_bias_representable) {error="Unsupported raster or depth bias state"; return false;}
  bindings.Cull(render,cull.cull_face==NativeCullFace::kFront?MTLCullModeFront:cull.cull_face==NativeCullFace::kBack?MTLCullModeBack:MTLCullModeNone);
  bindings.Winding(render,cull.front_face_clockwise?MTLWindingClockwise:MTLWindingCounterClockwise);
  bindings.Fill(render,fixed.polygon_mode==uint32_t(NativePolygonMode::kLine)?MTLTriangleFillModeLines:MTLTriangleFillModeFill);
  const bool depth_clamp=ShouldEnableNativeDepthClampForDraw(fixed.depth_clamp_enable,Phase()==RenderPhase::kLightSetup,
      {fixed.depth_enable,fixed.depth_write_enable,fixed.stencil_enable,fixed.two_sided_stencil,fixed.cull_mode,
       bool(targets.color_mask & requested_colors),fixed.stencil_depth_fail,fixed.stencil_pass,fixed.stencil_write_mask,
       fixed.ccw_stencil_depth_fail,fixed.ccw_stencil_pass,fixed.back_stencil_write_mask});
  bindings.Clip(render,depth_clamp?MTLDepthClipModeClamp:MTLDepthClipModeClip);
  bindings.Stencil(render,fixed.stencil_reference,fixed.two_sided_stencil?fixed.back_stencil_reference:fixed.stencil_reference);
  bindings.Blend(render,fixed.blend_constants[0],fixed.blend_constants[1],fixed.blend_constants[2],fixed.blend_constants[3]);
  const float scale_x=float(targets.width)/targets.logical_width,scale_y=float(targets.height)/targets.logical_height;
  for(size_t i=0;i<viewport.size();++i) {viewport[i]=std::bit_cast<float>(fixed.viewport_bits[i]); if(!std::isfinite(viewport[i])) {error="Nonfinite viewport"; return false;}}
  if(viewport[2]<=0 || viewport[3]<=0) return true;
  bindings.Viewport(render,MTLViewport{viewport[0]*scale_x,viewport[1]*scale_y,viewport[2]*scale_x,viewport[3]*scale_y,
      std::clamp(double(viewport[4]),0.0,1.0),std::clamp(double(viewport[5]),0.0,1.0)});
  const uint32_t left=uint32_t(std::floor(std::clamp(fixed.scissor[0],0,int(targets.logical_width))*scale_x));
  const uint32_t top=uint32_t(std::floor(std::clamp(fixed.scissor[1],0,int(targets.logical_height))*scale_y));
  const uint32_t right=std::min(targets.width,uint32_t(std::ceil(std::clamp(fixed.scissor[2],0,int(targets.logical_width))*scale_x)));
  const uint32_t bottom=std::min(targets.height,uint32_t(std::ceil(std::clamp(fixed.scissor[3],0,int(targets.logical_height))*scale_y)));
  if(right<=left || bottom<=top) return true;
  bindings.Scissor(render,MTLScissorRect{left,top,right-left,bottom-top});
  bindings.Bias(render,fixed.depth_bias_enable?std::bit_cast<float>(fixed.depth_bias_bits):0,
      fixed.depth_bias_enable?std::bit_cast<float>(fixed.slope_scaled_depth_bias_bits)*std::max(scale_x,scale_y):0,0);
  if (fire_active) [render pushDebugGroup:[NSString stringWithFormat:@"Rail trace capture %llu draw %llu event %llu material %08x",
      fire_capture,fire_draw,fire_context.event,fire_context.material]];
  if(sky_capture)[render setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
  if(indexed) [render drawIndexedPrimitives:primitive indexCount:count indexType:index32?MTLIndexTypeUInt32:MTLIndexTypeUInt16
      indexBuffer:indices indexBufferOffset:index_offset instanceCount:1 baseVertex:base_vertex baseInstance:0];
  else [render drawPrimitives:primitive vertexStart:first vertexCount:count];
  draw_encoded=true;
  if (fire_active) [render popDebugGroup];
  if(capture_geometry.identity&&execution_camera_matches&&!sky_capture){
    raytracing::ScopedCpuTime site_timed(raytracing_site_time);  // Capture::Draw plus the call site
    if(!pipeline->capture_state){
      std::lock_guard lock(pipeline->capture->mutex);
      if(pipeline->capture->complete)pipeline->capture_state=pipeline->capture->state;
    }
    if(pipeline->capture_state){
      if(raytracing_sequence!=temporal.metadata.sequence){
        raytracing_capture.BeginFrame(); raytracing_sequence=temporal.metadata.sequence;
      }
      if(!raytracing_capture.has_camera())
        if(const auto m=raytracing::ClipToWorldColumns(temporal.actual_projection,temporal.actual_inverse))
          raytracing_capture.SetCamera(*m);
      auto& g=capture_geometry;
      g.primitive=primitive; g.indexed=indexed; g.index32=index32; g.indices=indices; g.index_offset=index_offset;
      g.first=indexed?0:first; g.count=count; g.base_vertex=base_vertex;
      // Cut-out surfaces (alpha test, or alpha-to-mask, which foliage uses without the test):
      // shadow rays leave them to the cascade, since the captured triangles are solid.
      g.alpha_tested=(fixed.alpha_test_enable&&fixed.alpha_function!=7)||fixed.alpha_to_mask_enable;
      // Rebinds the capture pipeline and buffers 6/7; the next draw rebinds its own
      // pipeline through `bindings`, and temporal draws set 6/7 every time.
      std::string capture_error;
      raytracing_capture.Draw(render,g,[&]{bindings.Pipeline(render,pipeline->capture_state);},capture_error);
    }
  }
  // The AO darkens what the global contribution just wrote (all of it, until the lighting
  // shader override can limit it to the ambient term). A blended contribution adds to
  // earlier light and is left alone.
  if(ao_lighting&&raytracing_ao_texture&&raytracing_ao_sequence==temporal.metadata.sequence&&
     !ao_ambient&&!scene_blending&&!sky_capture){
    EndRender();
    std::string rt_error;
    if(raytracing_ao.Apply(commands,targets.colors[0]->image,raytracing_ao_texture,raytracing_ao_settings,rt_error))
      ++raytracing_ao_applied;
    else REXLOG_ERROR("gta4-metal-raytracing: AO apply failed: {}",rt_error);
  }
  if(shadow_lighting&&raytracing_shadow_texture&&raytracing_ao_sequence==temporal.metadata.sequence&&
     raytracing_shadow_settings.view==raytracing::ShadowView::kShow&&!scene_blending&&!sky_capture){
    EndRender();
    std::string rt_error;
    if(raytracing_shadows.Show(commands,targets.colors[0]->image,raytracing_shadow_texture,rt_error))
      ++raytracing_shadow_shown;
    else REXLOG_ERROR("gta4-metal-raytracing: shadow show failed: {}",rt_error);
  }
  if(sky_capture){
    [render setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:0];
    sky_capture->queried=true; EndRender(); sky_visibility=nil;
    std::string probe_error;
    if(!sky_probe.Finish(commands,targets.colors[0]->image,sky_capture,probe_error))
      REXLOG_ERROR("gta4-modern-exec: backend=metal event=sky-probe-unavailable {} reason={}",sky_capture->context,probe_error);
  }
  return true;
  };
  if(stock_composite_filter){
    // F6's discrete GBuffer selector and five HDR taps share the original
    // input grid. Run that exact linear filter before any de-jitter/upscale;
    // only its unchanged tone/color tail may consume reconstructed HDR.
    EndRender();
    const auto stage=composite_contract->scene_stage;
    const auto scene=sampled_images[stage];
    if(!scene||scene.textureType!=MTLTextureType2D||scene.sampleCount!=1||
        scene.width!=temporal.config.input_width||scene.height!=temporal.config.input_height){
      error="stock temporal composite has no current HDR scene at its declared stage";return false;
    }
    auto filtered=temporal.FilterComposite(error);if(!filtered)return false;
    const auto original_targets=targets;auto* original_pipeline=pipeline;
    const auto original_shared=shared;const auto original_shared_constants=shared_constants;
    const auto original_depth_state=depth_state;
    const auto original_fixed=fixed;
    const auto restore=[&]{
      targets=original_targets;pipeline=original_pipeline;shared=original_shared;
      shared_constants=original_shared_constants;depth_state=original_depth_state;fixed=original_fixed;
    };
    targets={};targets.colors[0]=filtered;targets.color_mask=1;targets.samples=1;
    targets.width=temporal.config.input_width;targets.height=temporal.config.input_height;
    targets.logical_width=original_targets.logical_width;targets.logical_height=original_targets.logical_height;
    fixed=temporal::LinearCompositeState(original_fixed);
    pipeline=DrawPipeline(targets,fixed,vdecl->second,up,up_stride,error);
    depth_state=DepthState(fixed,false,error);
    if(!pipeline||!depth_state){restore();return false;}
    shared.split_postfx_applied=1.0f;
    shared.color_output={};  // Scratch HDR has identity scale and no guest clamp.
    shared.alpha_to_mask=0;
    shared.fragment_coordinate_scale_x=float(targets.logical_width)/targets.width;
    shared.fragment_coordinate_scale_y=float(targets.logical_height)/targets.height;
    shared_constants=Upload(Bytes(shared),false,error);
    if(!shared_constants||!encode_draw()){EndRender();restore();return false;}
    EndRender();
    const bool filter_encoded=draw_encoded;
    restore();draw_encoded=false;
    // A successful encoder setup may still emit no draw for an empty viewport
    // or scissor. It must not resolve cleared scratch or start the HUD domain.
    if(!filter_encoded)return true;
    const auto exposure=temporal::ExposureForShader(pixel->second.hash);
    if(!exposure||!temporal.SetExposure(commands,sampled_images[exposure->adaptation_stage],
        std::bit_cast<float>(GuestWord(guest,exposure->exposure_guest_offset)),
        std::bit_cast<float>(GuestWord(guest,exposure->tone_guest_offset)),error))return false;
    temporal.composite_shader=pixel->second.hash;temporal.composite_scene_stage=stage;
    auto reconstructed=temporal.Resolve(commands,filtered->image,error);
    if(!reconstructed)return false;
    indirect_keep[2]=sampled_images[stage];
    sampled_images[stage]=reconstructed;
    heaps[0][stage]=reconstructed.gpuResourceID._impl;
    indirect[indirect_count++]=reconstructed;
    shared.split_postfx_applied=2.0f;
    shared_constants=Upload(Bytes(shared),false,error);
    heap_upload=Upload(Bytes(heaps),false,error);
    if(!shared_constants||!heap_upload)return false;
    ++temporal.filtered_composites;
    if(temporal.filtered_composites<=4||temporal.metadata.sequence%60==0)
      REXLOG_INFO("gta4-metal-temporal-composite frame={} shader={:016X} scene-stage={} filter=stock-f6 input={}x{} filtered={}x{} output={}x{} resolved={} spatial-fallback={} jittered={}",
        temporal.metadata.sequence,temporal.composite_shader,stage,scene.width,scene.height,filtered->image.width,filtered->image.height,
        reconstructed.width,reconstructed.height,temporal.resolved,temporal.spatial_fallback,temporal.jittered_draws);
  }
  if(!encode_draw())return false;
  if(!draw_encoded)return true;
  temporal::CommitPrimaryJitter(draw_encoded,scene_policy.primary,execution_camera_matches,
      temporal.metadata.jitter_applied,temporal.jitter_decided,temporal.jitter_eligible);
  if(temporal.jitter_decided&&!temporal.jitter_eligible)temporal.metadata.jitter_applied=false;
  if(draw_encoded&&targets.temporal_jitter)++temporal.jittered_draws;
  if(draw_encoded&&targets.temporal_motion){++temporal.world_draws;if(temporal_parameters.valid_history)++temporal.history_draws;temporal.depth_source=targets.depth;temporal.depth_captured=false;}
  if(draw_encoded&&temporal.active&&!temporal.HasSceneOutput()&&fixed.depth_enable&&fixed.depth_write_enable&&
      targets.depth&&targets.depth==temporal.depth_source)temporal.depth_captured=false;
  // AA's reactive color mask is not geometric invalidity. Ordinary alpha
  // layers keep the opaque vectors below them, as does a known infinite sky.
  // A motion-writing draw with no history writes previous_depth=-1 only for
  // its visible pixels; an occluded draw must not veto the whole frame.
  const bool preserves_scene_motion=targets.temporal_reactive&&!(fixed.depth_enable&&fixed.depth_write_enable)&&
      (scene_blending||(pipeline->has_pixel&&IsFusionSkyShader(pipeline->pixel.hash)));
  if(draw_encoded&&scene_policy.motion_relevant&&(requested_colors||(fixed.depth_enable&&fixed.depth_write_enable))&&
      ((!targets.temporal_motion&&!preserves_scene_motion)||
       (targets.temporal_motion&&(!standard_motion_depth||!targets.temporal_jitter)))){
    temporal.motion_coverage_complete=false;
    if(temporal.generation_skip_reason.empty())temporal.generation_skip_reason=
        !standard_motion_depth?"nonstandard current/previous depth viewport":"scene geometry has incomplete motion history";
  }
  if(draw_encoded&&temporal.active&&final_composite_execution&&temporal_extent&&(requested_colors&1u)&&targets.colors[0])
    temporal.executed_composite_source=targets.colors[0];
  if(draw_encoded&&targets.temporal_reactive)++temporal.reactive_draws;
  // gta4_temporal_reactive_log: which draws mark the temporal scaler's reactive mask (every 300th frame).
  if(temporal_reactive_log&&draw_encoded&&targets.temporal_reactive&&temporal.metadata.sequence%300==0&&temporal.diagnostic_reactive++<120)
    REXLOG_INFO("gta4-temporal-reactive-draw frame={} vs={:016X} ps={:016X} mode={} factors={}/{}/{} world={} effect={} role={} stage={} "
                "blend={} depth-test={} depth-write={} count={} type={} colors={:X} viewport={}x{}",
      temporal.metadata.sequence,pipeline->vertex.hash,pipeline->has_pixel?pipeline->pixel.hash:0,temporal_parameters.reactive,
      uint32_t(DecodeNativeBlendControl(fixed.blend_controls[0]).source_color),uint32_t(DecodeNativeBlendControl(fixed.blend_controls[0]).destination_color),
      uint32_t(DecodeNativeBlendControl(fixed.blend_controls[0]).color_operation),world,scene_policy.effect,
      uint32_t(lighting.role),uint32_t(lighting.stage),scene_blending,fixed.depth_enable,fixed.depth_write_enable,count,
      uint32_t(type),requested_colors,std::bit_cast<float>(fixed.viewport_bits[2]),std::bit_cast<float>(fixed.viewport_bits[3]));
  if(draw_encoded&&targets.temporal_ui)++temporal.ui_draws;
  if(draw_encoded&&composite_draw&&temporal.HasSceneOutput()&&targets.colors[0]){
    temporal.composite_source=targets.colors[0];
    const auto original_targets=targets;auto* original_pipeline=pipeline;
    const auto original_depth_state=depth_state;
    const auto original_shared=shared;const auto original_shared_constants=shared_constants;
    if(temporal.config.output_width!=targets.width||temporal.config.output_height!=targets.height){
      EndRender();auto high=temporal.HighComposite(targets.colors[0]->image.pixelFormat,error);if(!high)return false;
      targets={};targets.colors[0]=high;targets.color_mask=1;targets.samples=1;targets.width=temporal.config.output_width;targets.height=temporal.config.output_height;
      targets.logical_width=original_targets.logical_width;targets.logical_height=original_targets.logical_height;
      pipeline=DrawPipeline(targets,fixed,vdecl->second,up,up_stride,error);if(!pipeline)return false;
      depth_state=DepthState(fixed,false,error);if(!depth_state)return false;
      shared.fragment_coordinate_scale_x=float(targets.logical_width)/targets.width;shared.fragment_coordinate_scale_y=float(targets.logical_height)/targets.height;
      shared_constants=Upload(Bytes(shared),false,error);if(!shared_constants||!encode_draw())return false;
      EndRender();if(!temporal.AfterComposite(commands,high->image,error))return false;
      targets=original_targets;pipeline=original_pipeline;depth_state=original_depth_state;
      shared=original_shared;shared_constants=original_shared_constants;
    }else{
      auto image=targets.colors[0]->image;EndRender();if(!temporal.AfterComposite(commands,image,error))return false;
    }
    // Begin the HUD domain at actual final-composite execution. A scheduler
    // phase marker may arrive before its deferred draw list is consumed.
    if(!temporal.StartUi(commands,error))return false;
  }

  if (modern_diagnostics.enabled()) {
    modern_diagnostics.Draw({pipeline->vertex.hash, pipeline->has_pixel ? pipeline->pixel.hash : 0,
        uint32_t(Phase()), targets.samples, targets.width, targets.height,
        bool(pipeline->variant & 1u), bool(pipeline->variant & 2u),
        shared.modern_effects.tone_lut_address != 0, shared.split_postfx_applied != 0, &environment});
    if (cloud_draw) modern_diagnostics.Cloud(pipeline->pixel.hash, fusion_cloud_ready, targets.width, targets.height);
  }
  if(profile_enabled) scope_profile.Draw({pipeline->vertex.hash,pipeline->has_pixel?pipeline->pixel.hash:0,
      pipeline->variant,uint32_t(Phase()),targets.samples},indexed?0:count,indexed?count:0);
  for (size_t i = 0; i < targets.colors.size(); ++i) {
    const auto& color = targets.colors[i];
    if (color && (requested_colors & (uint32_t{1} << i))) {
      color->content_mask |= kContentColor; color->content_serial = ++content_serial;
    }
  }
  if (targets.depth) {
    const uint32_t written = (fixed.depth_enable && fixed.depth_write_enable ? kContentDepth : 0) |
        (fixed.stencil_enable && (fixed.stencil_write_mask || fixed.back_stencil_write_mask) ? kContentStencil : 0);
    targets.depth->content_mask |= written;
    if (written) targets.depth->content_serial = ++content_serial;
  }
  if (rex::diagnostics::IsEnabled(rex::diagnostics::Category::kNativeTrace)) {
    auto& observed = target_observations[size_t(Phase())];
    ++observed.draws;
    const uint64_t area = uint64_t(targets.width) * targets.height;
    const uint64_t observed_area = uint64_t(observed.width) * observed.height;
    // Do not let a later radar/HUD draw replace an equally sized scene snapshot.
    if (area > observed_area || (area == observed_area && targets.depth && !observed.depth)) {
      observed.width = targets.width; observed.height = targets.height;
      observed.logical_width = targets.logical_width; observed.logical_height = targets.logical_height;
      observed.samples = targets.samples; observed.viewport = viewport;
      observed.color = 0;
      for (const auto& target : targets.colors) if (target) { observed.color = target->descriptor.handle; break; }
      observed.depth = targets.depth ? targets.depth->descriptor.handle : 0;
      observed.depth_width = targets.depth ? uint32_t(targets.depth->image.width) : 0;
      observed.depth_height = targets.depth ? uint32_t(targets.depth->image.height) : 0;
    }
  }
  FireAfterDraw(targets);
  ++draws; ++frame_draws; return true;
}
}  // namespace rex::graphics::gta4_metal
