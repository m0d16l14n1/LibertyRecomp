#pragma once
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace gta4::temporal_boundary {
inline constexpr uint32_t kGBufferVtable=0x82044D4C;
inline constexpr uint32_t kDrawSceneVtable=0x82013144;
inline constexpr uint32_t kViewportOffset=176;
inline constexpr uint32_t kCompositeFlagsOffset=2272;
inline constexpr uint32_t kSceneListOffset=2344;
inline constexpr uint32_t kCompositeFlag=0x1000;
constexpr bool DeclaresComposite(uint32_t flags,uint32_t scene_list) {
  return (flags&kCompositeFlag)!=0&&scene_list!=UINT32_MAX;
}
struct Decision {
  uint32_t composite_phase=0;
  const char* reason="no current boundary association";
  explicit operator bool() const { return composite_phase!=0; }
};
// Both retail update methods receive the same render-context argument. The title
// can update adjacent frames on different scheduler workers, so retain a bounded
// set of exact frame records instead of letting the latest observation erase one
// which has not reached BeginScene yet. Until this frame's GBuffer observation
// arrives, a previously exact association for the same phase may be proposed;
// DeclaredBoundary revalidates both live guest objects before admitting it. An
// exact conflict, explicit bypass, overflow, or failed revalidation fails closed.
class Registry {
 public:
  void GBuffer(uint32_t device,uint64_t sequence,uint32_t phase,uint32_t context) {
    auto* frame=Prepare(device,sequence);
    if(!frame||!phase||!context)return;
    for(auto& entry:frame->gbuffers)if(entry.phase==phase){
      entry.conflict|=entry.context!=context;return;
    }
    if(frame->gbuffers.size()>=128){frame->overflow=true;return;}
    frame->gbuffers.push_back({phase,context,false});
  }
  void Composite(uint32_t device,uint64_t sequence,uint32_t context,uint32_t phase,bool enabled) {
    auto* frame=Prepare(device,sequence);
    if(!frame||!phase||!context)return;
    for(auto& entry:frame->composites)if(entry.context==context){
      entry.conflict|=entry.phase!=phase||entry.enabled!=enabled;return;
    }
    if(frame->composites.size()>=128){frame->overflow=true;return;}
    frame->composites.push_back({phase,context,enabled,false});
  }
  Decision Find(uint32_t device,uint64_t sequence,uint32_t phase) const {
    if(!device||!sequence)
      return {0,"no current boundary association"};
    const auto frame=std::find_if(frames_.begin(),frames_.end(),[&](const auto& value){
      return value.device==device&&value.sequence==sequence;
    });
    if(frame!=frames_.end()){
      const auto g=std::find_if(frame->gbuffers.begin(),frame->gbuffers.end(),
          [&](const auto& e){return e.phase==phase;});
      // An exact observation is authoritative, including its conflicts and an
      // explicit title bypass. Only a frame that has not observed this GBuffer
      // yet may use the last verified association below.
      if(g!=frame->gbuffers.end()||frame->overflow)return Evaluate(*frame,phase);
    }
    const Frame* prior=nullptr;
    for(const auto& candidate:frames_){
      if(candidate.device!=device||candidate.sequence>=sequence||candidate.overflow)continue;
      const auto g=std::find_if(candidate.gbuffers.begin(),candidate.gbuffers.end(),
        [&](const auto& e){return e.phase==phase;});
      if(g!=candidate.gbuffers.end()&&(!prior||candidate.sequence>prior->sequence))prior=&candidate;
    }
    if(!prior)return {0,"no current boundary association"};
    auto decision=Evaluate(*prior,phase);
    if(decision)decision.reason="previous exact title boundary remains eligible";
    return decision;
  }
 private:
  struct GBufferEntry {uint32_t phase,context;bool conflict;};
  struct CompositeEntry {uint32_t phase,context;bool enabled,conflict;};
  struct Frame {
    uint32_t device=0;
    uint64_t sequence=0;
    bool overflow=false;
    std::vector<GBufferEntry> gbuffers;
    std::vector<CompositeEntry> composites;
  };
  static Decision Evaluate(const Frame& frame,uint32_t phase){
    if(frame.overflow)return {0,"boundary association limit"};
    const auto g=std::find_if(frame.gbuffers.begin(),frame.gbuffers.end(),
        [&](const auto& e){return e.phase==phase;});
    if(g==frame.gbuffers.end())return {0,"primary context was not observed this frame"};
    if(g->conflict)return {0,"ambiguous primary context"};
    const auto c=std::find_if(frame.composites.begin(),frame.composites.end(),
        [&](const auto& e){return e.context==g->context;});
    if(c==frame.composites.end())return {0,"matching composite was not declared this frame"};
    if(c->conflict)return {0,"ambiguous composite context"};
    if(!c->enabled)return {0,"title bypasses final composite"};
    return {c->phase,"same-frame title composite declared"};
  }
  static constexpr size_t kRetainedFrames=8;
  std::array<Frame,kRetainedFrames> frames_{};
  size_t cursor_=0;
  Frame* Prepare(uint32_t device,uint64_t sequence) {
    if(!device||!sequence)return nullptr;
    const auto existing=std::find_if(frames_.begin(),frames_.end(),[&](const auto& frame){
      return frame.device==device&&frame.sequence==sequence;
    });
    if(existing!=frames_.end())return &*existing;
    auto& frame=frames_[cursor_++%frames_.size()];
    frame.device=device;
    frame.sequence=sequence;
    frame.overflow=false;
    frame.gbuffers.clear();
    frame.composites.clear();
    return &frame;
  }
};
Decision DeclaredBoundary(uint8_t* base,uint32_t device,uint64_t sequence,uint32_t gbuffer_phase);
}  // namespace gta4::temporal_boundary
