#include <array>
#include <bit>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <limits>
#include <rex/graphics/gta4_native/temporal_commands.h>
#include "graphics/gta4_metal/temporal/composite_contract.h"
#include "graphics/gta4_metal/temporal/draw_policy.h"
#include "graphics/gta4_metal/temporal/geometry_history.h"
#include "graphics/gta4_metal/temporal/title_boundary.h"

namespace {
using namespace rex::graphics::gta4_native;
namespace temporal=rex::graphics::gta4_metal::temporal;
unsigned checks=0;
#define CHECK(condition) do { ++checks; if(!(condition)) { \
  std::fprintf(stderr,"temporal draw policy failed at line %d: %s\n",__LINE__,#condition); \
  std::exit(1); } } while(false)

void GeometryBindings() {
  temporal::GeometryKey base{1,2,3,4,5,6,7};
  base.streams[0]={9,16,24};base.streams[3]={10,32,48};
  base.index_generation=11;base.pixel_shader=12;base.base_vertex=-2;
  base.primitive=6;base.indexed=true;base.restart=true;base.restart_index=65535;
  std::array<uint8_t,4096> vertex{};
  std::array<uint8_t,sizeof(core::SharedConstants)> shared{};
  const auto check_change=[&](auto change){
    temporal::GeometryHistory history;
    CHECK(history.Begin(1,1,1,false));
    CHECK(history.Record(base,vertex,shared,{}).captured);
    CHECK(history.Begin(1,1,2,false));
    auto changed=base;change(changed);
    CHECK(changed!=base);
    CHECK(!history.Record(changed,vertex,shared,{}).previous);
    CHECK(history.Record(base,vertex,shared,{}).previous);
  };
  check_change([](auto& k){k.streams[0].offset=32;});
  check_change([](auto& k){k.streams[0].stride=48;});
  check_change([](auto& k){k.streams[3].offset=0;});
  check_change([](auto& k){k.streams[3].generation=21;});
  check_change([](auto& k){k.index_generation=22;});
  check_change([](auto& k){k.base_vertex=0;});
  check_change([](auto& k){k.pixel_shader=23;});
  check_change([](auto& k){k.layout=24;});
  check_change([](auto& k){k.range=25;});
  check_change([](auto& k){k.primitive=4;});
  check_change([](auto& k){k.indexed=false;});
  check_change([](auto& k){k.restart=false;});
  check_change([](auto& k){k.restart_index=65534;});
  temporal::GeometryHistory history;
  CHECK(history.Begin(1,1,1,false));
  CHECK(history.Record(base,vertex,shared,{}).captured);
  CHECK(history.Begin(1,1,2,false));
  CHECK(history.Record(base,vertex,shared,{}).previous);
  // A second draw under the key with other constants is a sibling, not a collision...
  vertex[0]=1;
  const auto sibling=history.Record(base,vertex,shared,{});
  CHECK(sibling.captured&&!sibling.ambiguous&&!sibling.previous);
  // ...and next frame a draw that no sibling constant tells apart is ambiguous.
  CHECK(history.Begin(1,1,3,false));
  const auto unclear=history.Record(base,vertex,shared,{});
  CHECK(!unclear.previous&&unclear.ambiguous);
}
// gta_vehicle_tire VS_VehicleTransformD reads matWheelTransform at c64-c67; c0-c3 still holds
// the body gWorld, so every wheel of one car shares the unscoped owner key.
void GeometrySiblings() {
  std::array<uint8_t,sizeof(core::SharedConstants)> shared{};
  const std::array<std::array<float,2>,4> hubs{{{-0.8f,1.3f},{0.8f,1.3f},{-0.8f,-1.3f},{0.8f,-1.3f}}};
  const auto bank=[&](float body,size_t wheel,float angle,float camera){
    std::array<uint8_t,4096> v{};
    const std::array<float,16> world{1,0,0,0, 0,1,0,0, 0,0,1,0, body,0,0,1};
    std::memcpy(v.data(),world.data(),sizeof(world));
    const std::array<float,4> view{1,0,0,camera};  // c8: changes for every wheel alike
    std::memcpy(v.data()+8*16,view.data(),sizeof(view));
    const float c=std::cos(angle),s=std::sin(angle);
    const std::array<float,16> spin{1,0,0,0, 0,c,-s,0, 0,s,c,0, hubs[wheel][0],hubs[wheel][1],0.35f,1};
    std::memcpy(v.data()+64*16,spin.data(),sizeof(spin));
    return v;
  };
  const auto key=[](uint64_t owner){temporal::GeometryKey k{owner,2,0,4,5,6,7};return k;};
  const auto same=[](const auto& lookup,const std::array<uint8_t,4096>& expected){
    return lookup.previous&&lookup.previous->vertex==std::vector<uint8_t>(expected.begin(),expected.end());
  };
  for(const bool fallback:{false,true}){
    temporal::GeometryHistory h; h.set_transform_fallback(fallback);
    CHECK(h.Begin(1,1,1,false));
    for(size_t w=0;w<4;++w){
      CHECK(h.Record(key(100),bank(0,w,0.1f*w,0),shared,{}).captured);
      CHECK(h.Record(key(200),bank(10,w,0.1f*w,0),shared,{}).captured);
    }
    // Four wheels of one car plus a second car of the same model, drawn in another order,
    // spun 0.4 rad, with the camera moved: each wheel continues its own previous pose.
    CHECK(h.Begin(1,1,2,false));
    for(size_t i=0;i<4;++i){
      const size_t w=3-i;
      const auto a=h.Record(key(100),bank(0.2f,w,0.1f*w+0.4f,5),shared,{});
      CHECK(!a.ambiguous&&same(a,bank(0,w,0.1f*w,0)));
      const auto b=h.Record(key(200),bank(10.2f,w,0.1f*w+0.4f,5),shared,{});
      CHECK(!b.ambiguous&&same(b,bank(10,w,0.1f*w,0)));
      // Another pass of the same wheel is a repeat, not a fifth sibling.
      CHECK(same(h.Record(key(100),bank(0.2f,w,0.1f*w+0.4f,5),shared,{}),bank(0,w,0.1f*w,0)));
    }
    const auto statistics=h.TakeStatistics();
    CHECK(statistics.sibling==8&&statistics.sibling_ambiguous==0);
    CHECK(h.Begin(1,1,3,false));  // and the frame after, from the new poses
    for(size_t w=0;w<4;++w)
      CHECK(same(h.Record(key(100),bank(0.4f,w,0.1f*w+0.8f,9),shared,{}),bank(0.2f,w,0.1f*w+0.4f,5)));
  }
  {  // a wheel half-way between two of last frame's wheels: refused, as before
    temporal::GeometryHistory h;
    CHECK(h.Begin(1,1,1,false));
    h.Record(key(100),bank(0,0,0,0),shared,{}); h.Record(key(100),bank(0,1,0,0),shared,{});
    CHECK(h.Begin(1,1,2,false));
    auto middle=bank(0,0,0,0); const float x=0; std::memcpy(middle.data()+64*16+12*4,&x,sizeof(x));
    const auto r=h.Record(key(100),middle,shared,{});
    CHECK(!r.previous&&r.ambiguous);
    CHECK(h.Record(key(100),middle,shared,{}).ambiguous);  // its repeat too
  }
  {  // a car that lost a wheel this frame: the other three still match
    temporal::GeometryHistory h;
    CHECK(h.Begin(1,1,1,false));
    for(size_t w=0;w<4;++w) h.Record(key(100),bank(0,w,0,0),shared,{});
    CHECK(h.Begin(1,1,2,false));
    for(size_t w=1;w<4;++w) CHECK(same(h.Record(key(100),bank(0,w,0.2f,1),shared,{}),bank(0,w,0,0)));
  }
  {  // keys drawn once (nearly all of them) make no sibling group; a second wheel makes one
    temporal::GeometryHistory h;
    CHECK(h.Begin(1,1,1,false));
    h.Record(key(100),bank(0,0,0,0),shared,{}); h.Record(key(200),bank(10,0,0,0),shared,{});
    h.Record(key(100),bank(0,0,0,0),shared,{});  // an identical repeat is not a sibling
    CHECK(h.current_sibling_groups()==0);
    h.Record(key(100),bank(0,1,0,0),shared,{});
    CHECK(h.current_sibling_groups()==1);
    h.Record(key(100),bank(0,2,0,0),shared,{});
    CHECK(h.current_sibling_groups()==1);
  }
  {  // a NaN where this draw has a number rules that sibling out, whatever follows it
    temporal::GeometryHistory h;
    CHECK(h.Begin(1,1,1,false));
    auto with_nan=bank(0,1,0,0); const float nan=std::numeric_limits<float>::quiet_NaN();
    std::memcpy(with_nan.data()+200*4,&nan,sizeof(nan));  // this draw has 0 here
    std::memcpy(with_nan.data()+300*4,&nan,sizeof(nan));  // a later NaN both share
    h.Record(key(100),bank(0,0,0,0),shared,{}); h.Record(key(100),with_nan,shared,{});
    CHECK(h.Begin(1,1,2,false));
    auto draw=bank(0,1,0,0); std::memcpy(draw.data()+300*4,&nan,sizeof(nan));
    const auto r=h.Record(key(100),draw,shared,{});
    CHECK(!same(r,with_nan));  // the shared NaN at 300 must not undo the mismatch at 200
    CHECK(!r.previous&&r.ambiguous);  // and the other wheel has 0 where this draw has NaN
  }
  {  // more siblings than tracked: the overflow draw is ambiguous
    temporal::GeometryHistory h;
    CHECK(h.Begin(1,1,1,false));
    for(int i=0;i<64;++i) CHECK(!h.Record(key(100),bank(float(i),0,0,0),shared,{}).ambiguous);
    CHECK(h.Record(key(100),bank(64,0,0,0),shared,{}).ambiguous);
  }
}
// Moving entities are drawn from per-frame copies of their transforms: the owner changes.
void GeometryTransformMatch() {
  std::array<uint8_t,sizeof(core::SharedConstants)> shared{};
  const auto bank=[](float x,float y){
    std::array<uint8_t,4096> v{};
    const std::array<float,16> world{1,0,0,0, 0,1,0,0, 0,0,1,0, x,y,0,1};
    std::memcpy(v.data(),world.data(),sizeof(world));
    return v;
  };
  const auto key=[](uint64_t owner){temporal::GeometryKey k{owner,2,owner,4,5,6,7};return k;};
  {  // one car, new owner address each frame, 1 m a frame: continued
    temporal::GeometryHistory h; h.set_transform_fallback(true);
    CHECK(h.Begin(1,1,1,false)); CHECK(h.Record(key(100),bank(0,0),shared,{}).captured);
    CHECK(h.Begin(1,1,2,false));
    const auto r=h.Record(key(200),bank(1,0),shared,{});
    CHECK(r.previous&&r.matched_by_transform);
    CHECK(h.Record(key(200),bank(1,0),shared,{}).previous);  // the same draw again
  }
  {  // without the fallback: no history, as before
    temporal::GeometryHistory h;
    CHECK(h.Begin(1,1,1,false)); h.Record(key(100),bank(0,0),shared,{});
    CHECK(h.Begin(1,1,2,false)); CHECK(!h.Record(key(200),bank(1,0),shared,{}).previous);
  }
  {  // two same-model cars equally near: refused
    temporal::GeometryHistory h; h.set_transform_fallback(true);
    CHECK(h.Begin(1,1,1,false)); h.Record(key(100),bank(0,0),shared,{}); h.Record(key(101),bank(2,0),shared,{});
    CHECK(h.Begin(1,1,2,false)); CHECK(!h.Record(key(200),bank(1,0),shared,{}).previous);
  }
  {  // the nearer of two is clear: taken, and not given to a second object
    temporal::GeometryHistory h; h.set_transform_fallback(true);
    CHECK(h.Begin(1,1,1,false)); h.Record(key(100),bank(0,0),shared,{}); h.Record(key(101),bank(5,0),shared,{});
    CHECK(h.Begin(1,1,2,false));
    const auto a=h.Record(key(200),bank(0.5f,0),shared,{});
    const auto origin=bank(0,0);
    CHECK(a.previous&&a.previous->vertex==std::vector<uint8_t>(origin.begin(),origin.end()));
    const auto b=h.Record(key(201),bank(0.6f,0),shared,{});
    CHECK(!b.previous||b.previous->vertex!=a.previous->vertex);
  }
  {  // too far for one frame: none
    temporal::GeometryHistory h; h.set_transform_fallback(true);
    CHECK(h.Begin(1,1,1,false)); h.Record(key(100),bank(0,0),shared,{});
    CHECK(h.Begin(1,1,2,false)); CHECK(!h.Record(key(200),bank(20,0),shared,{}).previous);
  }
  {  // a reused owner address now holding an object 30 m away: not its history
    temporal::GeometryHistory h; h.set_transform_fallback(true);
    CHECK(h.Begin(1,1,1,false)); h.Record(key(100),bank(0,0),shared,{});
    CHECK(h.Begin(1,1,2,false)); CHECK(!h.Record(key(100),bank(30,0),shared,{}).previous);
  }
  {  // a register the shader may not even read (stale c100) jumps: refused, and counted
    temporal::GeometryHistory h; h.set_transform_fallback(true);
    CHECK(h.Begin(1,1,1,false)); h.Record(key(100),bank(0,0),shared,{});
    CHECK(h.Begin(1,1,2,false));
    auto moved=bank(1,0); const float stale=50; std::memcpy(moved.data()+100*16+8,&stale,sizeof(stale));
    CHECK(!h.Record(key(200),moved,shared,{}).previous);
    const auto statistics=h.TakeStatistics();
    CHECK(statistics.far_register[100]==1&&statistics.far_world==0&&statistics.transform_far==1);
  }
  {  // still drawn under its own key: not borrowed by another owner
    temporal::GeometryHistory h; h.set_transform_fallback(true);
    CHECK(h.Begin(1,1,1,false)); h.Record(key(100),bank(0,0),shared,{});
    CHECK(h.Begin(1,1,2,false)); CHECK(h.Record(key(100),bank(0,0),shared,{}).previous);
    CHECK(!h.Record(key(300),bank(0.1f,0),shared,{}).previous);
  }
}
// Matching compares only the registers the vertex shader reads (shader archive v3 masks).
void GeometryReadMask() {
  namespace history=rex::graphics::gta4_native::temporal;
  using history::ConstantMask;
  std::array<uint8_t,sizeof(core::SharedConstants)> shared{};
  const auto mask=[](std::initializer_list<int> registers){
    ConstantMask m{}; for(const int r:registers) m[r/64]|=1ull<<(r%64); return m;
  };
  const auto put=[](std::array<uint8_t,4096>& v,int reg,int component,float value){
    std::memcpy(v.data()+reg*16+component*4,&value,sizeof(value));
  };
  const auto key=[](uint64_t owner){temporal::GeometryKey k{owner,2,owner,4,5,6,7};return k;};
  // gta_vehicle_tire VS_VehicleTransformD and gta_trees VSPropFoliageDeferred, from their sources.
  const auto tire=mask({4,5,6,8,9,10,11,64,65,66,67,68,69});
  const auto tree=mask({0,1,2,8,9,10,11,39,40,45,51});
  CHECK(history::WorldRegisters(history::kAllConstants)==(ConstantMask{0xF,0,0,0}));
  CHECK(history::WorldRegisters(tree)==(ConstantMask{0x7,0,0,0}));
  CHECK(history::WorldRegisters(tire)==(ConstantMask{0,0xF,0,0}));
  CHECK(history::WorldRegisters(mask({8,9}))==(ConstantMask{}));
  const auto wheel=[&](float x,float stale){
    std::array<uint8_t,4096> v{};
    for(int r=0;r<4;++r) put(v,64+r,r,1);   // matWheelTransform
    put(v,67,0,x);                          // hub offset
    put(v,8,3,x);                           // gWorldViewProj translation
    put(v,25,0,stale);                      // gLightFallOff left by a forward-lit draw
    return v;
  };
  for(const bool masked:{true,false}){  // new owner each frame; only the unread c25 jumps
    temporal::GeometryHistory h; h.set_transform_fallback(true);
    const auto& reads=masked?tire:history::kAllConstants;
    CHECK(h.Begin(1,1,1,false)); h.Record(key(100),wheel(0.8f,2),shared,{},reads);
    CHECK(h.Begin(1,1,2,false));
    CHECK(bool(h.Record(key(200),wheel(0.9f,60),shared,{},reads).previous)==masked);
  }
  const auto foliage=[&](float x,float stale){
    std::array<uint8_t,4096> v{};
    for(int r=0;r<3;++r) put(v,r,r,1);
    put(v,0,3,x);                // gWorld translation (row-major x)
    put(v,3,0,stale);            // c3: never read by the tree shader
    return v;
  };
  for(const bool masked:{true,false}){  // same key; the unread c3 jumps 100
    temporal::GeometryHistory h; h.set_transform_fallback(true);
    const auto& reads=masked?tree:history::kAllConstants;
    CHECK(h.Begin(1,1,1,false)); h.Record(key(100),foliage(5,0),shared,{},reads);
    CHECK(h.Begin(1,1,2,false));
    const auto r=h.Record(key(100),foliage(5,100),shared,{},reads);
    CHECK(bool(r.previous)==masked);
    const auto statistics=h.TakeStatistics();
    CHECK(statistics.key_far==(masked?0u:1u));
  }
  {  // two wheels whose unread c25 swapped between frames: told apart by the hub alone
    temporal::GeometryHistory h;
    CHECK(h.Begin(1,1,1,false));
    h.Record(key(100),wheel(-0.8f,1),shared,{},tire); h.Record(key(100),wheel(0.8f,40),shared,{},tire);
    CHECK(h.Begin(1,1,2,false));
    const auto left=h.Record(key(100),wheel(-0.8f,40),shared,{},tire);
    const auto expected=wheel(-0.8f,1);
    CHECK(left.previous&&left.previous->vertex==std::vector<uint8_t>(expected.begin(),expected.end()));
  }
  {  // the far histogram names only registers the shader reads
    temporal::GeometryHistory h; h.set_transform_fallback(true);
    CHECK(h.Begin(1,1,1,false)); h.Record(key(100),wheel(0.8f,2),shared,{},tire);
    CHECK(h.Begin(1,1,2,false));
    auto spun=wheel(0.8f,90); put(spun,68,1,40);  // a read, non-world register jumps too
    CHECK(!h.Record(key(200),spun,shared,{},tire).previous);
    auto statistics=h.TakeStatistics();
    CHECK(statistics.far_register[68]==1&&statistics.far_register[25]==0&&statistics.far_world==0);
    CHECK(h.Begin(1,1,3,false));  // a jump in the tire's world registers is refused by the world step
    auto moved=wheel(0.8f,2); put(moved,65,1,40);
    CHECK(!h.Record(key(300),moved,shared,{},tire).previous);
    statistics=h.TakeStatistics();
    CHECK(statistics.far_world==1&&statistics.far_register[65]==0);
  }
}
void MaterialSampling() {
  temporal::Configuration c{1920,1080,3840,2160,temporal::Method::kMetalFx,false};
  CHECK(temporal::MaterialMipBias(c,true)==-2.0f);
  CHECK(temporal::MaterialMipBias(c,false)==0.0f);
  c.input_width=2560;c.input_height=1440;
  CHECK(std::abs(temporal::MaterialMipBias(c,true)-(-1.5849625f))<0.00001f);
  c.input_width=c.output_width;c.input_height=c.output_height;
  CHECK(temporal::MaterialMipBias(c,true)==0.0f);
  c.method=temporal::Method::kTaa;
  CHECK(temporal::MaterialMipBias(c,true)==0.0f);
  c.input_width=0;
  CHECK(temporal::MaterialMipBias(c,true)==0.0f);
}

void CompositeScratch() {
  core::FixedFunctionState guest{};
  guest.depth_enable=guest.depth_write_enable=guest.stencil_enable=1;
  guest.alpha_test_enable=guest.alpha_to_mask_enable=guest.alpha_to_mask=1;
  guest.blend_enable=1;guest.blend_controls.fill(0x00070006u);
  guest.color_write_mask=0x1u;guest.cull_mode=2;guest.polygon_mode=1;
  guest.scissor={4,6,1200,700};guest.scissor_enable=1;
  guest.viewport_bits={std::bit_cast<uint32_t>(2.0f),std::bit_cast<uint32_t>(3.0f),
      std::bit_cast<uint32_t>(1280.0f),std::bit_cast<uint32_t>(720.0f),
      std::bit_cast<uint32_t>(0.0f),std::bit_cast<uint32_t>(1.0f)};
  const auto preserved=guest;
  const auto scratch=temporal::LinearCompositeState(guest);
  CHECK(guest==preserved);
  CHECK(!scratch.depth_enable&&!scratch.depth_write_enable&&!scratch.stencil_enable);
  CHECK(!scratch.alpha_test_enable&&!scratch.alpha_to_mask_enable&&!scratch.alpha_to_mask);
  CHECK(!scratch.blend_enable&&scratch.color_write_mask==0xFu);
  for(auto blend:scratch.blend_controls)CHECK(!IsNativeBlendControlEnabled(blend));
  CHECK(scratch.viewport_bits==guest.viewport_bits&&scratch.scissor==guest.scissor);
  CHECK(scratch.cull_mode==guest.cull_mode&&scratch.polygon_mode==guest.polygon_mode);
  const auto f6=temporal::CompositeForShader(0xF6AEB9A606561C54ull);
  CHECK(f6&&f6->scene_stage==1&&f6->filter==temporal::CompositeFilter::kStockF6);
  CHECK(!SupportsSplitPostFx(0xF6AEB9A606561C54ull));
  CHECK(!temporal::CompositeForShader(0));
  CHECK(temporal::FiniteViewport(guest)&&temporal::RasterHasArea(guest,1280,720));
  guest.scissor[2]=guest.scissor[0];CHECK(!temporal::RasterHasArea(guest,1280,720));
  guest=preserved;guest.viewport_bits[2]=std::bit_cast<uint32_t>(0.0f);
  CHECK(!temporal::RasterHasArea(guest,1280,720));
  guest=preserved;guest.viewport_bits[2]=std::bit_cast<uint32_t>(std::numeric_limits<float>::infinity());
  CHECK(!temporal::FiniteViewport(guest));
}

void ExecutionAndJitter() {
  LightingContext lighting{};
  auto primary=temporal::ClassifySceneDraw(true,false,false,true,false,false,true,lighting);
  CHECK(primary.primary&&primary.world&&primary.motion_relevant&&!primary.effect);
  auto unclassified=temporal::ClassifySceneDraw(true,false,false,false,false,false,true,lighting);
  CHECK(!unclassified.world&&unclassified.motion_relevant);
  CHECK(!temporal::ClassifySceneDraw(true,false,false,true,true,true,true,lighting).world);
  lighting.stage=RenderExecutionStage::kDeferredLighting;
  auto light=temporal::ClassifySceneDraw(true,false,false,true,true,false,true,lighting);
  CHECK(!light.world&&!light.motion_relevant);
  lighting.role=LightPassRole::kCorona;
  auto corona=temporal::ClassifySceneDraw(true,false,false,false,false,true,true,lighting);
  CHECK(corona.effect&&corona.motion_relevant&&!corona.world);
  CHECK(!temporal::ClassifySceneDraw(false,false,false,true,true,false,true,lighting).motion_relevant);
  CHECK(!temporal::ClassifySceneDraw(true,true,false,true,true,false,true,lighting).motion_relevant);
  lighting={};
  CHECK(temporal::ClassifySceneDraw(true,false,false,false,true,false,true,lighting).world);
  CHECK(!temporal::ClassifySceneDraw(true,false,false,false,true,false,false,lighting).world);
  bool decided=false,eligible=false;
  temporal::CommitPrimaryJitter(false,true,false,true,decided,eligible);
  CHECK(!decided);
  CHECK(!temporal::AdmitJitter(decided,eligible,true,true,false));
  temporal::CommitPrimaryJitter(true,true,false,true,decided,eligible);
  CHECK(decided&&!eligible);
  temporal::CommitPrimaryJitter(true,true,true,true,decided,eligible);
  CHECK(!eligible&&!temporal::AdmitJitter(decided,eligible,true,true,true));
  decided=eligible=false;
  CHECK(temporal::AdmitJitter(decided,eligible,true,true,true));
  temporal::CommitPrimaryJitter(true,true,true,true,decided,eligible);
  CHECK(temporal::AdmitJitter(decided,eligible,true,true,false));
  CHECK(!temporal::AdmitJitter(decided,eligible,true,false,true));
  core::SharedConstants shared{};shared.modern_effects.depth_range[1]=1;
  CHECK(temporal::StandardDepthViewport(shared));
  shared.modern_effects.depth_range[0]=0.25f;CHECK(!temporal::StandardDepthViewport(shared));
}

void Provenance() {
  CHECK(TemporalExecutionFlags(false,31)==0);
  for(auto phase:{14u,15u,16u,31u})CHECK(TemporalExecutionFlags(true,phase)&kTemporalSceneGeometry);
  for(auto phase:{1u,2u,3u,9u,10u,13u,17u,19u,20u,21u,23u,24u,32u,34u,35u,36u}){
    CHECK(TemporalExecutionFlags(true,phase)&kTemporalScreenSpace);
    CHECK(!(TemporalExecutionFlags(true,phase)&kTemporalSceneGeometry));
  }
  CHECK(TemporalExecutionFlags(true,999)==kTemporalExecutionAttributed);
  LightingContext lighting{};lighting.stage=RenderExecutionStage::kCompositePostFx;
  lighting.source_function=0x822D1710;lighting.occurrence_id=17;
  CHECK(TemporalCompositeExecutionFlags(lighting,false)==kTemporalCompositeExecution);
  CHECK(TemporalCompositeExecutionFlags(lighting,true)==(kTemporalCompositeExecution|kTemporalFinalCompositeExecution));
  lighting.source_function=0;CHECK(TemporalCompositeExecutionFlags(lighting,true)==0);
  lighting.source_function=0x822D1710;lighting.occurrence_id=0;CHECK(TemporalCompositeExecutionFlags(lighting,true)==0);
  lighting.occurrence_id=17;lighting.stage=RenderExecutionStage::kSceneToGBuffer;
  CHECK(TemporalCompositeExecutionFlags(lighting,true)==0);
  TemporalCommand a{};a.device=1;a.view=2;a.sequence=3;a.width=1280;a.height=720;
  a.output_width=1920;a.output_height=1080;
  auto b=a;b.time_ns=99;b.projection[0]=2;
  CHECK(SameTemporalScene(a,b));
  b.output_width=1280;CHECK(!SameTemporalScene(a,b));
  b=a;b.sequence=4;CHECK(!SameTemporalScene(a,b));
  b=a;b.view=9;CHECK(!SameTemporalScene(a,b));
}
void DeclaredBoundaries() {
  using namespace gta4::temporal_boundary;
  CHECK(DeclaresComposite(0x1000,0));
  CHECK(!DeclaresComposite(0,1));
  CHECK(!DeclaresComposite(0x1000,UINT32_MAX));
  Registry registry;
  CHECK(!registry.Find(1,1,11));
  registry.GBuffer(1,1,11,21);
  CHECK(!registry.Find(1,1,11));
  registry.Composite(1,1,21,31,true);
  CHECK(registry.Find(1,1,11).composite_phase==31);
  CHECK(!registry.Find(1,2,11));
  CHECK(!registry.Find(2,1,11));
  CHECK(!registry.Find(1,1,12));
  registry.Composite(1,2,21,31,true);
  CHECK(!registry.Find(1,2,11));
  registry.GBuffer(1,2,11,21);
  CHECK(registry.Find(1,2,11).composite_phase==31);
  registry.GBuffer(1,3,11,21);
  registry.Composite(1,3,21,31,false);
  CHECK(!registry.Find(1,3,11));
  registry.Composite(1,3,21,31,true);
  CHECK(!registry.Find(1,3,11));
  registry.GBuffer(1,4,11,21);
  registry.Composite(1,4,21,31,true);
  registry.Composite(1,4,21,32,true);
  CHECK(!registry.Find(1,4,11));
  registry.GBuffer(1,5,11,21);
  registry.Composite(1,5,21,31,true);
  registry.GBuffer(1,5,11,22);
  CHECK(!registry.Find(1,5,11));
  registry.GBuffer(1,6,11,21);
  registry.Composite(1,6,22,31,true);
  CHECK(!registry.Find(1,6,11));
  registry.Composite(1,6,21,32,true);
  CHECK(registry.Find(1,6,11).composite_phase==32);
  Registry full;
  for(uint32_t i=1;i<=129;++i){full.GBuffer(1,1,i,i);full.Composite(1,1,i,i,true);}
  CHECK(!full.Find(1,1,1));
  // An old worker observation may remove admission, but never borrows the
  // newer frame's boundary for an older frame or vice versa.
  registry.Composite(1,5,21,31,true);
  CHECK(!registry.Find(1,6,11));
  CHECK(!registry.Find(1,5,11));
}
}  // namespace
int main(){GeometryBindings();GeometrySiblings();GeometryReadMask();GeometryTransformMatch();MaterialSampling();CompositeScratch();ExecutionAndJitter();Provenance();DeclaredBoundaries();
  std::printf("temporal draw policy: %u checks passed\n",checks);return 0;}
