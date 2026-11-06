#include <metal_stdlib>
using namespace metal;
struct DepthMotionDraw {
  float2 extent,jitter,previous_jitter;
  uint valid,reactive,ui_mode;
  float reactive_strength;
  uint padding1,padding2;
};
struct DepthMotionInput {
  float4 current [[user(LIBERTY_CURRENT_CLIP)]];
  float4 previous [[user(LIBERTY_PREVIOUS_CLIP)]];
};
struct DepthMotionOutput {
  float2 motion [[color(4)]];
  float reactive [[color(5)]];
  float previous_depth [[color(6)]];
};
// Depth-only prepasses must produce the same object motion as their color
// passes. Runs only when the original draw has no pixel shader or alpha test.
fragment DepthMotionOutput liberty_temporal_depth_motion(DepthMotionInput input [[stage_in]],
    constant DepthMotionDraw& c [[buffer(6)]]) {
  bool valid=c.valid&&all(isfinite(input.current))&&all(isfinite(input.previous))&&
      input.current.w>1.0e-6f&&input.previous.w>1.0e-6f;
  float2 velocity=valid?(input.previous.xy/input.previous.w-input.current.xy/input.current.w)*
      c.extent*float2(0.5f,-0.5f):float2(0);
  valid=valid&&all(isfinite(velocity))&&all(abs(velocity)<=65504.0f);
  const float z=valid?input.previous.z/input.previous.w:-1.0f;
  return {valid?velocity:float2(0),(!valid||c.reactive)?1.0f:0.0f,
          isfinite(z)&&z>=0&&z<=1?z:-1.0f};
}
struct BackgroundMotionConstants {
  float4x4 reprojection;
  float2 jitter,half_pixel;
  uint2 extent;
  uint reversed,accumulate_sky;  // accumulate_sky: background motion only
};
kernel void liberty_temporal_background_motion(
    texture2d<float,access::read> depth [[texture(0)]],
    texture2d<float,access::read_write> motion [[texture(1)]],
    texture2d<float,access::read_write> previous_depth [[texture(2)]],
    texture2d<float,access::write> reactive [[texture(3)]],
    constant BackgroundMotionConstants& c [[buffer(0)]],
    uint2 pixel [[thread_position_in_grid]]) {
  if(any(pixel>=c.extent))return;
  const float far_depth=c.reversed?0.0f:1.0f;
  // Only the clear-depth environment is reconstructible without object
  // identity. Never repair missing foreground geometry using camera motion.
  if(depth.read(pixel).r!=far_depth||previous_depth.read(pixel).r>=0)return;
  const float2 uv=(float2(pixel)+0.5f-c.jitter)/float2(c.extent);
  const float2 current=(uv*2-1)*float2(1,-1)-c.half_pixel;
  const float4 previous=c.reprojection*float4(current,far_depth,1);
  if(!all(isfinite(previous))||previous.w<=1.0e-6f)return;
  const float2 velocity=(previous.xy/previous.w-current)*float2(c.extent)*float2(0.5f,-0.5f);
  if(!all(isfinite(velocity))||any(abs(velocity)>65504.0f))return;
  motion.write(float4(velocity,0,0),pixel);
  previous_depth.write(float4(far_depth),pixel);
  // The sky moves with the camera alone: the scaler may accumulate it like tracked geometry.
  if(c.accumulate_sky)reactive.write(float4(0),pixel);
}
// Camera-only motion of the point at pixel/depth z (input pixels, current to previous).
float2 temporal_camera_velocity(constant BackgroundMotionConstants& c,uint2 pixel,float z){
  const float2 uv=(float2(pixel)+0.5f-c.jitter)/float2(c.extent);
  const float2 current=(uv*2-1)*float2(1,-1)-c.half_pixel;
  const float4 previous=c.reprojection*float4(current,z,1);
  float2 velocity=float2(0);
  if(all(isfinite(previous))&&previous.w>1.0e-6f)
    velocity=(previous.xy/previous.w-current)*float2(c.extent)*float2(0.5f,-0.5f);
  if(!all(isfinite(velocity))||any(abs(velocity)>65504.0f))velocity=float2(0);
  return velocity;
}
float temporal_fill_view_depth(float z,float2 planes,bool reversed){
  z=reversed?1-z:z;return planes.x*planes.y/max(planes.y-z*(planes.y-planes.x),1.0e-8f);
}
// Frame generation only, after the temporal scaler has read the motion: world pixels whose
// draw had no object history. Retail draws a car or a ped in many parts and some of them still
// have no history (refused as ambiguous, or new this frame); given the camera's motion they
// were left behind by the rest of the object in every generated frame, so the player's car
// tore and Niko shook on turns. Such a pixel first takes the motion of nearby pixels at the
// same depth that do have history, preferring ones that move unlike the camera (a moving
// object); only with none does it take the camera's motion. Sky pixels are left to the
// background kernel; history-tracked pixels keep their object motion and are only read here.
kernel void liberty_temporal_camera_motion_fill(
    texture2d<float,access::read> depth [[texture(0)]],
    texture2d<float,access::read_write> motion [[texture(1)]],
    texture2d<float,access::read> previous_depth [[texture(2)]],
    constant BackgroundMotionConstants& c [[buffer(0)]],
    texture2d<float,access::write> reactive [[texture(3)]],
    // near, far, neighbour search on (1/0), w: below 0 frame generation (camera motion when no
    // neighbour has history); 0..1 before the temporal scaler: only neighbour motion, and the
    // pixel's reactive value set to w so the scaler accumulates it like the rest of its object
    constant float4& fill [[buffer(1)]],
    // x: what frame generation writes when no neighbour has history: 0 the camera's motion,
    // 1 zero (the pixel moves with the camera: the player's car, Niko), 2 zero nearer than y
    // metres and the camera's motion beyond (static world drawn without history)
    constant float2& untracked [[buffer(2)]],
    uint2 pixel [[thread_position_in_grid]]) {
  if(any(pixel>=c.extent))return;
  const float far_depth=c.reversed?0.0f:1.0f;
  const float z=depth.read(pixel).r;
  if(previous_depth.read(pixel).r>=0||z==far_depth||!isfinite(z)||z<0||z>1)return;
  if(fill.z>0&&fill.x>0&&fill.y>fill.x){
    const float view=temporal_fill_view_depth(z,fill.xy,c.reversed);
    const float tolerance=max(0.35f,0.08f*view);
    constexpr int radii[6]={2,5,10,18,32,56};
    const int2 directions[8]={int2(1,0),int2(-1,0),int2(0,1),int2(0,-1),
                              int2(1,1),int2(-1,1),int2(1,-1),int2(-1,-1)};
    float2 sum=float2(0);float weight=0;int found=0;
    // Nearest rings first; stop after a ring that found enough of the same surface.
    for(int r=0;r<6&&found<3;++r)for(int d=0;d<8;++d){
      const int2 q=int2(pixel)+directions[d]*radii[r];
      if(any(q<0)||any(q>=int2(c.extent)))continue;
      if(previous_depth.read(uint2(q)).r<0)continue;
      const float zq=depth.read(uint2(q)).r;
      if(zq==far_depth||!isfinite(zq)||zq<0||zq>1)continue;
      if(abs(temporal_fill_view_depth(zq,fill.xy,c.reversed)-view)>tolerance)continue;
      const float2 mq=motion.read(uint2(q)).xy;
      if(!all(isfinite(mq)))continue;
      // An object moving unlike the camera (the car under the player) outweighs the static
      // world around it at the same depth (the road under the car).
      const bool moving=length(mq-temporal_camera_velocity(c,uint2(q),zq))>0.75f;
      const float w=(moving?8.0f:1.0f)/float(1+radii[r]);
      sum+=mq*w;weight+=w;++found;
    }
    if(weight>0){
      motion.write(float4(sum/weight,0,0),pixel);
      if(fill.w>=0)reactive.write(float4(fill.w),pixel);
      return;
    }
  }
  if(fill.w>=0)return;
  const bool planes=fill.x>0&&fill.y>fill.x;
  const bool zero=untracked.x>0.5f&&(untracked.x<1.5f||
      (planes&&temporal_fill_view_depth(z,fill.xy,c.reversed)<untracked.y));
  motion.write(float4(zero?float2(0):temporal_camera_velocity(c,pixel,z),0,0),pixel);
}
struct TemporalConstants {
  uint2 extent;float2 jitter;
  float near_plane,far_plane,history_weight,previous_pre_exposure;
  float current_pre_exposure;uint reset,reversed,padding;
  float previous_near_plane,previous_far_plane;float2 padding2;
};
float3 temporal_ycocg(float3 c){return float3(dot(c,float3(0.25,0.5,0.25)),0.5*(c.r-c.b),dot(c,float3(-0.25,0.5,-0.25)));}
float3 temporal_rgb(float3 c){return float3(c.x+c.y-c.z,c.x+c.z,c.x-c.y-c.z);}
float temporal_view_depth(float z,float near_plane,float far_plane,bool reversed){z=reversed?1-z:z;return near_plane*far_plane/max(far_plane-z*(far_plane-near_plane),1.0e-8f);}
bool temporal_valid_depth(float z){return isfinite(z) && z>=0 && z<=1;}
bool temporal_depth_matches(float z,float reference,float near_plane,float far_plane,bool reversed){
 if(!temporal_valid_depth(z) || !temporal_valid_depth(reference))return false;
 float expected=temporal_view_depth(reference,near_plane,far_plane,reversed);
 return abs(temporal_view_depth(z,near_plane,far_plane,reversed)-expected)<=max(0.005f,0.02f*expected);
}
float4 temporal_finite(float4 c){return select(clamp(c,0.0f,65504.0f),float4(0),!isfinite(c));}
kernel void liberty_temporal_aa(texture2d<float> color [[texture(0)]],texture2d<float> depth [[texture(1)]],
 texture2d<float> motion [[texture(2)]],texture2d<float> reactive [[texture(3)]],
 texture2d<float> history [[texture(4)]],texture2d<float> history_depth [[texture(5)]],
 texture2d<float,access::write> result [[texture(6)]],texture2d<float,access::write> result_depth [[texture(7)]],
 texture2d<float> expected_previous_depth [[texture(8)]],
 constant TemporalConstants& c [[buffer(0)]],uint2 id [[thread_position_in_grid]]) {
 if(any(id>=c.extent))return;
 constexpr sampler linear_sampler(coord::normalized,address::clamp_to_edge,filter::linear);
 constexpr sampler nearest(coord::normalized,address::clamp_to_edge,filter::nearest);
 float2 uv=(float2(id)+0.5f)/float2(c.extent),jittered=uv+c.jitter/float2(c.extent);
 float4 current=temporal_finite(color.sample(linear_sampler,jittered));
 float z=depth.sample(nearest,jittered).r;
 result_depth.write(float4(temporal_valid_depth(z)?z:-1.0f),id);
 if(c.reset || !temporal_valid_depth(z)){result.write(current,id);return;}
 float2 reference_motion=motion.sample(nearest,jittered).xy;
 float reference_previous=expected_previous_depth.sample(nearest,jittered).r;
 if(!all(isfinite(reference_motion)) || !temporal_valid_depth(reference_previous)){result.write(current,id);return;}
 // Color reconstruction covers up to four raw samples. A nearest validity
 // sample can miss a new foreground contributor completely. Validate exactly
 // the nonzero color footprint, and interpolate motion/depth only within a
 // coherent surface. The half-pixel motion bound rejects mixed moving layers.
 float2 pixel=jittered*float2(c.extent)-0.5f,part=fract(pixel);
 int2 base=int2(floor(pixel));float2 velocity=0;float prior_z=0,reactive_value=0;
 for(int y=0;y<2;++y)for(int x=0;x<2;++x){
  float weight=(x?part.x:1-part.x)*(y?part.y:1-part.y);
  if(weight<=0)continue;
  uint2 tap=uint2(clamp(base+int2(x,y),int2(0),int2(c.extent)-1));
  float tap_z=depth.read(tap).r,tap_previous=expected_previous_depth.read(tap).r;
  float2 tap_motion=motion.read(tap).xy;float tap_reactive=reactive.read(tap).r;
  if(!all(isfinite(tap_motion)) || any(abs(tap_motion-reference_motion)>0.5f) ||
     !isfinite(tap_reactive) || tap_reactive>=1 ||
     !temporal_depth_matches(tap_z,z,c.near_plane,c.far_plane,c.reversed) ||
     !temporal_depth_matches(tap_previous,reference_previous,c.previous_near_plane,c.previous_far_plane,c.reversed)){
   result.write(current,id);return;
  }
  velocity+=tap_motion*weight;prior_z+=tap_previous*weight;
  reactive_value=max(reactive_value,tap_reactive);
 }
 float2 previous_uv=uv+velocity/float2(c.extent);
 if(any(previous_uv<0) || any(previous_uv>1)){result.write(current,id);return;}
 // Compare the expected previous position of this surface with depth from
 // that same frame, including every contributor to bilinear history color.
 // Current view-space Z is deliberately not part of this comparison.
 pixel=previous_uv*float2(c.extent)-0.5f;part=fract(pixel);base=int2(floor(pixel));
 for(int y=0;y<2;++y)for(int x=0;x<2;++x){
  float weight=(x?part.x:1-part.x)*(y?part.y:1-part.y);
  if(weight<=0)continue;
  uint2 tap=uint2(clamp(base+int2(x,y),int2(0),int2(c.extent)-1));
  if(!temporal_depth_matches(history_depth.read(tap).r,prior_z,c.previous_near_plane,c.previous_far_plane,c.reversed)){
   result.write(current,id);return;
  }
 }
 float3 mean=0,second=0,lower=INFINITY,upper=-INFINITY;
 // Compute extrema after transforming each sample into YCoCg, not by
 // transforming RGB extrema: chroma coefficients include negative terms.
 for(int y=-1;y<=1;++y)for(int x=-1;x<=1;++x){
  float3 value=temporal_ycocg(temporal_finite(color.sample(linear_sampler,jittered+float2(x,y)/float2(c.extent))).rgb);
  mean+=value;second+=value*value;lower=min(lower,value);upper=max(upper,value);
 }
 mean/=9;float3 deviation=sqrt(max(second/9-mean*mean,0.0f));
 lower=max(lower,mean-1.25f*deviation);upper=min(upper,mean+1.25f*deviation);
 float3 previous=temporal_ycocg(temporal_finite(history.sample(linear_sampler,previous_uv)).rgb*c.current_pre_exposure/c.previous_pre_exposure);
 float3 center=(lower+upper)*0.5f,extent=(upper-lower)*0.5f,delta=previous-center;
 float largest=max(max(abs(delta.x)/max(extent.x,1.0e-6f),abs(delta.y)/max(extent.y,1.0e-6f)),abs(delta.z)/max(extent.z,1.0e-6f));
 previous=center+delta/max(1.0f,largest);
 float weight=c.history_weight*(1-clamp(reactive_value,0.0f,1.0f));
 weight*=mix(1.0f,0.8f,clamp(length(velocity)/8,0.0f,1.0f));
 result.write(temporal_finite(float4(mix(current.rgb,temporal_rgb(previous),weight),current.a)),id);
}

kernel void liberty_temporal_ui_over(texture2d<float,access::read> scene [[texture(0)]],
 texture2d<float,access::read> overlay [[texture(1)]],texture2d<float,access::write> result [[texture(2)]],
 uint2 id [[thread_position_in_grid]]) {
 if(id.x>=result.get_width() || id.y>=result.get_height())return;
 float4 ui=temporal_finite(overlay.read(id));ui.a=clamp(ui.a,0.0f,1.0f);
 result.write(ui+temporal_finite(scene.read(id))*(1-ui.a),id);
}

kernel void liberty_temporal_ui_over_inplace(texture2d<float,access::read_write> image [[texture(0)]],
 texture2d<float,access::read> overlay [[texture(1)]],uint2 id [[thread_position_in_grid]]) {
 if(id.x>=image.get_width() || id.y>=image.get_height())return;
 float4 ui=temporal_finite(overlay.read(id));ui.a=clamp(ui.a,0.0f,1.0f);
 image.write(ui+temporal_finite(image.read(id))*(1-ui.a),id);
}

kernel void liberty_temporal_export_depth(depth2d<float,access::read> input [[texture(0)]],
 texture2d<float,access::write> output [[texture(1)]],uint2 id [[thread_position_in_grid]]) {
 if(id.x>=output.get_width()||id.y>=output.get_height())return;
 output.write(float4(input.read(id)),id);
}
kernel void liberty_temporal_copy_color(texture2d<float> input [[texture(0)]],
 texture2d<float,access::write> output [[texture(1)]],constant float2& offset [[buffer(0)]],uint2 id [[thread_position_in_grid]]) {
 if(id.x>=output.get_width()||id.y>=output.get_height())return;
 constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
 float2 uv=(float2(id)+0.5f)/float2(output.get_width(),output.get_height())+offset/float2(input.get_width(),input.get_height());
 output.write(temporal_finite(input.sample(s,uv)),id);
}
kernel void liberty_temporal_affine_ui(texture2d<float> scene [[texture(0)]],texture2d<float> add [[texture(1)]],
 texture2d<float> transmit [[texture(2)]],texture2d<float,access::write> output [[texture(3)]],uint2 id [[thread_position_in_grid]]) {
 if(id.x>=output.get_width()||id.y>=output.get_height())return;
 constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
 float2 uv=(float2(id)+0.5f)/float2(output.get_width(),output.get_height());
 output.write(temporal_finite(float4(scene.sample(s,uv).rgb*transmit.sample(s,uv).rgb+add.sample(s,uv).rgb,1)),id);
}

kernel void liberty_temporal_affine_ui_inplace(texture2d<float,access::read_write> image [[texture(0)]],
 texture2d<float> add [[texture(1)]],texture2d<float> transmit [[texture(2)]],uint2 id [[thread_position_in_grid]]) {
 if(id.x>=image.get_width()||id.y>=image.get_height())return;
 constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
 float2 uv=(float2(id)+0.5f)/float2(image.get_width(),image.get_height());
 image.write(temporal_finite(float4(image.read(id).rgb*transmit.sample(s,uv).rgb+add.sample(s,uv).rgb,1)),id);
}

// Frame generation repair (gta4_metalfx_frame_generation_repair_px): MetalFX's interpolator has
// no reactive input, and at a motion discontinuity with a depth step (the road moving under the
// player's car, which holds still on screen) it can give the edge the wrong layer's motion and
// smear it. Where a tap within ~30 input pixels moves differently by more than `threshold` output
// pixels AND lies at another depth, the generated pixel is blended toward a half-step backward
// warp of the current real scene (scene only, no HUD), checked to stay on its own depth layer.
// Strong reactive pixels are the rigid-deformation path for wheels and skeletal peds: their body
// motion remains valid, but the two real poses cannot be meaningfully blended. Use the same crisp
// current-pose half-step warp there even away from a depth edge.
struct TemporalRepairConstants {
 float2 motion_scale;    // input-pixel motion to output pixels (output/input)
 float2 input_texel;     // 1/input size (uv per input pixel)
 float2 output_texel;    // 1/output size
 float threshold;        // output pixels of motion difference where repair starts (full at 2x)
 float near_plane,far_plane;
 uint reversed;
 float depth_step;       // relative view-depth difference that counts as another layer
 float padding;
};
kernel void liberty_temporal_framegen_repair(texture2d<float,access::read_write> generated [[texture(0)]],
 texture2d<float> scene [[texture(1)]],texture2d<float> motion [[texture(2)]],texture2d<float> depth [[texture(3)]],
 texture2d<float> reactive [[texture(4)]],
 constant TemporalRepairConstants& c [[buffer(0)]],uint2 id [[thread_position_in_grid]]) {
 if(id.x>=generated.get_width() || id.y>=generated.get_height())return;
 constexpr sampler nearest(coord::normalized,address::clamp_to_edge,filter::nearest);
 constexpr sampler linear_sampler(coord::normalized,address::clamp_to_edge,filter::linear);
 const float2 uv=(float2(id)+0.5f)*c.output_texel;
 // Ordinary transparent/light effects are intentionally bounded below 0.5. A strong value is
 // reserved for geometry whose deforming pose was made rigid for frame-generation motion.
 float weight=smoothstep(0.5f,0.9f,reactive.sample(nearest,uv).r);
 // Edge repair is off (gta4_metalfx_frame_generation_repair_px = 0, sent as threshold 65504):
 // the ring search below cannot raise the weight then ((dm - 65504) / 65504 saturates to 0),
 // so a pixel without a strong reactive value is done. The search was ~8 ms per 1440p frame.
 const bool edges=c.threshold<60000.0f;
 if(!edges && weight<=0)return;
 const float z0=depth.sample(nearest,uv).r;
 if(!temporal_valid_depth(z0))return;
 const float v0=temporal_view_depth(z0,c.near_plane,c.far_plane,c.reversed!=0);
 const float2 m0=motion.sample(nearest,uv).xy*c.motion_scale;
 const float distances[4]={2,6,14,30};
 if(edges)for(uint ring=0;ring<4;++ring)for(uint k=0;k<8;++k){
  const float angle=float(k)*0.78539816f+float(ring)*0.39269908f;
  const float2 tap=uv+float2(cos(angle),sin(angle))*distances[ring]*c.input_texel;
  const float z=depth.sample(nearest,tap).r;
  if(!temporal_valid_depth(z))continue;
  const float v=temporal_view_depth(z,c.near_plane,c.far_plane,c.reversed!=0);
  if(abs(v-v0)<=c.depth_step*min(v,v0))continue;
  const float dm=length(motion.sample(nearest,tap).xy*c.motion_scale-m0);
  // The smear reaches about half the motion difference from the edge: farther taps need more.
  if(dm*0.5f+2.0f<distances[ring]*c.motion_scale.x)continue;
  weight=max(weight,saturate((dm-c.threshold)/max(c.threshold,1.0f)));
 }
 if(weight<=0)return;
 // m points from the current position to the previous one; this pixel's content sits at the
 // midpoint, so it came from about uv - m/2 in the current image (scene only: the HUD is composed
 // over the generated image later, in present.mm).
 float2 source=uv-0.5f*m0*c.output_texel;
 const float zs=depth.sample(nearest,source).r;
 if(!temporal_valid_depth(zs) ||
    abs(temporal_view_depth(zs,c.near_plane,c.far_plane,c.reversed!=0)-v0)>c.depth_step*v0)
  source=uv;  // the warp crosses into the other layer: hold the current pixel instead
 const float4 repaired=temporal_finite(scene.sample(linear_sampler,source));
 const float4 original=temporal_finite(generated.read(id));
 generated.write(mix(original,repaired,weight),id);
}

#include "temporal_exposure.metal"
#include "temporal_motion_coverage.metal"

// Frame generation sharpening (gta4_metalfx_frame_generation_sharpen): the interpolator's
// warps soften the generated image (city drive dumps: about 0.76-0.81 of the real images'
// Laplacian detail on the car and the near road), so a display alternating real and
// generated images shimmers on textured near objects. An unsharp mask over the 4-neighbour
// cross, clamped to that neighbourhood's range so it cannot ring or halo.
// The softening grows with motion (a still pixel is the real image), so the amount ramps in
// with the pixel's motion: none at 1 output pixel, full from 9.
//
// Source clamp (gta4_metalfx_frame_generation_source_clamp): at a low base rate the interpolator
// fails around disocclusions and thin depth edges (blocks of road under a car, jagged lamp-post
// bases, smeared hydrants and ped edges) with colours found in neither real image. Each generated
// pixel is limited to the colour range of the 3x3 neighbourhoods it comes from: the previous scene
// half a motion step ahead and the current scene half a step back (motion points from the current
// pixel to its previous position). Correct interpolation is inside that range and is untouched.
// It also bounds the sharpening above to colours the real images have.
struct TemporalSharpenConstants { float amount; float source_clamp; float2 motion_scale; };
kernel void liberty_temporal_framegen_sharpen(texture2d<float,access::read> source [[texture(0)]],
 texture2d<float,access::write> output [[texture(1)]],texture2d<float> motion [[texture(2)]],
 texture2d<float> previous_scene [[texture(3)]],texture2d<float> current_scene [[texture(4)]],
 constant TemporalSharpenConstants& k [[buffer(0)]],uint2 id [[thread_position_in_grid]]) {
 const uint2 size=uint2(source.get_width(),source.get_height());
 if(any(id>=size))return;
 const uint2 last=size-1;
 const float4 c=temporal_finite(source.read(id));
 const float3 n=temporal_finite(source.read(uint2(id.x,id.y>0?id.y-1:0))).rgb;
 const float3 s=temporal_finite(source.read(uint2(id.x,min(id.y+1,last.y)))).rgb;
 const float3 w=temporal_finite(source.read(uint2(id.x>0?id.x-1:0,id.y))).rgb;
 const float3 e=temporal_finite(source.read(uint2(min(id.x+1,last.x),id.y))).rgb;
 const float3 low=min(c.rgb,min(min(n,s),min(w,e))),high=max(c.rgb,max(max(n,s),max(w,e)));
 constexpr sampler nearest(coord::normalized,address::clamp_to_edge,filter::nearest);
 const float2 m=motion.sample(nearest,(float2(id)+0.5f)/float2(size)).xy*k.motion_scale;
 const float amount=all(isfinite(m))?k.amount*saturate((length(m)-1.0f)/8.0f):0.0f;
 const float3 sharpened=c.rgb+amount*(c.rgb-0.25f*(n+s+w+e));
 float3 result=clamp(sharpened,low,high);
 if(k.source_clamp>0.5f&&all(isfinite(m))){
  constexpr sampler linear(coord::pixel,address::clamp_to_edge,filter::linear);
  const float2 q=float2(id)+0.5f,from_previous=q+0.5f*m,from_current=q-0.5f*m;
  float3 range_low=float3(INFINITY),range_high=float3(-INFINITY);
  for(int y=-1;y<=1;++y)for(int x=-1;x<=1;++x){
   const float2 o=float2(x,y);
   const float3 p=temporal_finite(previous_scene.sample(linear,from_previous+o)).rgb;
   const float3 r=temporal_finite(current_scene.sample(linear,from_current+o)).rgb;
   range_low=min(range_low,min(p,r));range_high=max(range_high,max(p,r));
  }
  result=clamp(result,range_low,range_high);
 }
 output.write(float4(result,c.a),id);
}
