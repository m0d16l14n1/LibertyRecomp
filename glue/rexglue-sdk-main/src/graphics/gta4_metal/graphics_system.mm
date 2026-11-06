#include "graphics_system.h"
#include "pipeline_store.h"
#include "renderer.h"

#include <rex/graphics/gta4_native/fire_escape_trace.h>
#include <rex/graphics/gta4_native/gpu_pass_origin.h>
#include <rex/graphics/gta4_native/phone_trace.h>
#include <rex/graphics/gta4_native/tv_trace.h>
#include <rex/graphics/gta4_native/title_commands.h>
#include <rex/graphics/gta4_native/temporal_commands.h>
#include <rex/logging.h>
#include <rex/system/function_dispatcher.h>
#include <rex/system/kernel_state.h>
#include <rex/ui/metal/provider.h>
#include <rex/ui/windowed_app_context.h>

#include <algorithm>
#include <bit>
#include <cstring>
#include <span>
#include <pthread.h>
#include <sys/qos.h>
#include <rex/cvar.h>
#include "resources.h"

REXCVAR_DEFINE_BOOL(gta4_metal_async_submit, false, "GPU/Metal",
    "Translate and encode title commands on a renderer worker thread instead of the game's own "
    "render thread (the game's CPU work then overlaps the renderer's). Present waits for the worker, "
    "so it never runs a frame behind. Applies on restart")
    .lifecycle(rex::cvar::Lifecycle::kRequiresRestart);
REXCVAR_DEFINE_UINT32(gta4_metal_async_queue_limit, 16384, "GPU/Diagnostics",
    "With gta4_metal_async_submit: most commands queued ahead of the renderer worker (at least 4)")
    .lifecycle(rex::cvar::Lifecycle::kRequiresRestart);
REXCVAR_DEFINE_BOOL(gta4_metal_async_snapshot_all, false, "GPU/Diagnostics",
    "With gta4_metal_async_submit: snapshot the device block for every command that names a device, "
    "not only draws, clears, resolves and texture binds (finds commands that read it indirectly)")
    .lifecycle(rex::cvar::Lifecycle::kRequiresRestart);

namespace rex::graphics::gta4_metal {
namespace {
// Diagnostic envelopes are transport metadata, not separate rendering routes.
// Limit nesting and validate every wrapper before admitting the title payload.
bool Unwrap(uint32_t& abi, const void*& data, size_t& size, gta4_native::FireTraceContext* fire = nullptr) {
  using namespace gta4_native;
  if (!data || size < sizeof(CommandHeader)) return false;
  for (unsigned depth = 0; depth < 5; ++depth) {
    if (abi == kTitleCommandAbi) return true;
    if (abi == kGpuPassEnvelopeAbi) {
      GpuPassOrigin origin{};
      if (!UnpackGpuPassEnvelope(data, size, abi, origin)) return false;
    } else if (abi == kFireTraceEnvelopeAbi) {
      FireTraceContext context{};
      if (!UnpackFireTraceEnvelope(data, size, abi, context)) return false;
      if (fire) *fire = context;
    } else if (abi == kTvTraceEnvelopeAbi) {
      TvTraceContext context{};
      if (!UnpackTvTraceEnvelope(data, size, abi, context)) return false;
    } else if (abi == kPhoneTraceEnvelopeAbi) {
      PhoneTraceContext context{};
      if (!UnpackPhoneTraceEnvelope(data, size, abi, context)) return false;
    } else {
      return false;
    }
  }
  return false;
}
}

Gta4MetalGraphicsSystem::Gta4MetalGraphicsSystem() = default;
Gta4MetalGraphicsSystem::~Gta4MetalGraphicsSystem() { Shutdown(); }

X_STATUS Gta4MetalGraphicsSystem::SetupPresentation(ui::WindowedAppContext* app_context) {
  if (presenter_) return X_STATUS_SUCCESS;
  // The producer must keep the presenter selected when it was constructed.
  if (renderer_) return X_STATUS_INVALID_PARAMETER;
  std::string error;
  if (!provider_) provider_ = ui::metal::MetalProvider::Create(error);
  if (!provider_) {
    REXLOG_ERROR("gta4-metal: {}", error);
    return X_STATUS_UNSUCCESSFUL;
  }
  auto setup = [this] { presenter_ = provider_->CreatePresenter(); };
  if (app_context && !app_context->IsInUIThread()) {
    if (!app_context->CallInUIThreadSynchronous(setup)) return X_STATUS_UNSUCCESSFUL;
  } else {
    setup();
  }
  if (!presenter_) return X_STATUS_UNSUCCESSFUL;
  app_context_ = app_context;
  REXLOG_INFO("gta4-metal: native Metal presentation initialized");
  return X_STATUS_SUCCESS;
}

X_STATUS Gta4MetalGraphicsSystem::SetupGuestGpu(runtime::FunctionDispatcher* dispatcher,
                                               system::KernelState* kernel) {
  std::lock_guard lock(renderer_mutex_);
  if (renderer_) return X_STATUS_SUCCESS;
  if (!dispatcher || !kernel || !dispatcher->memory()) return X_STATUS_INVALID_PARAMETER;
  std::string error;
  if (!provider_) provider_ = ui::metal::MetalProvider::Create(error);
  if (!provider_) {
    REXLOG_ERROR("gta4-metal: {}", error);
    return X_STATUS_UNSUCCESSFUL;
  }
  auto renderer = std::make_unique<Renderer>(provider_->context(), dispatcher->memory(), presenter_.get());
  if (!renderer->Initialize(error)) {
    REXLOG_ERROR("gta4-metal: title initialization failed: {}", error);
    return X_STATUS_UNSUCCESSFUL;
  }
  renderer_ = std::move(renderer);
  failures_ = 0;
  memory_ = dispatcher->memory();
  async_submit_ = REXCVAR_GET(gta4_metal_async_submit);
  snapshot_all_ = REXCVAR_GET(gta4_metal_async_snapshot_all);
  queue_limit_ = std::clamp<size_t>(REXCVAR_GET(gta4_metal_async_queue_limit), 4, kMaximumQueuedCommands);
  if (async_submit_) {
    worker_stop_ = false;
    worker_ = std::thread([this] { WorkerLoop(); });
    REXLOG_INFO("gta4-metal: asynchronous title submission (renderer worker thread)");
  }
  REXLOG_INFO("gta4-metal: title-command renderer connected; abi={} plugin=standalone-metal",
              gta4_native::kTitleCommandAbi);
  return X_STATUS_SUCCESS;
}

bool Gta4MetalGraphicsSystem::has_presentation() const { return presenter_ != nullptr; }
ui::GraphicsProvider* Gta4MetalGraphicsSystem::provider() const { return provider_.get(); }
ui::Presenter* Gta4MetalGraphicsSystem::presenter() const { return presenter_.get(); }
uint32_t Gta4MetalGraphicsSystem::GetTitleCommandAbi(uint32_t title_id) const {
  return title_id == gta4_native::kTitleId ? gta4_native::kTitleCommandAbi : 0;
}

bool Gta4MetalGraphicsSystem::SubmitTitleCommand(uint32_t title_id, uint32_t abi,
                                                 const void* command, size_t size) {
  gta4_native::FireTraceContext trace{};
  if (title_id != gta4_native::kTitleId || !Unwrap(abi, command, size, &trace)) return false;
  if (!renderer_) return false;
  // The game may submit from more than one host thread. Keep instance metadata
  // local to its submitting thread, and apply it together with its draw (under the
  // renderer lock, or in one push to the queue) so another submitter cannot replace
  // a mesh's temporal identity.
  struct PendingInstance {const void* owner=nullptr;gta4_native::TemporalCommand command{};};
  thread_local PendingInstance temporal;
  gta4_native::CommandHeader header{};std::memcpy(&header,command,sizeof(header));
  if(header.type==gta4_native::CommandType::kTemporalUpdate&&size==sizeof(gta4_native::TemporalCommand)){
    gta4_native::TemporalCommand value;std::memcpy(&value,command,sizeof(value));
    if(value.event==gta4_native::TemporalEvent::kInstance){temporal={this,value};return true;}
  }
  if(header.type==gta4_native::CommandType::kDeviceCreated||header.type==gta4_native::CommandType::kDeviceDestroyed)temporal={};
  const bool draw=header.type==gta4_native::CommandType::kDrawPrimitive||header.type==gta4_native::CommandType::kDrawPrimitiveUp||header.type==gta4_native::CommandType::kDrawIndexedPrimitive;
  const bool traced=trace.occurrence||trace.event;
  if(async_submit_){
    // The instance goes in the same push as its draw, so no other submitter's command lands between.
    const bool instance=draw&&temporal.owner==this;
    if(!Enqueue(command,size,traced?&trace:nullptr,instance?&temporal.command:nullptr,
                instance?sizeof(temporal.command):0))return false;
    // The frame ends here: wait until the worker has consumed it (and published it), so it never
    // runs a frame behind the title.
    if(header.type==gta4_native::CommandType::kPresent)DrainQueue();
    return true;
  }
  std::lock_guard lock(renderer_mutex_);
  if (!renderer_) return false;
  std::string error;
  if(draw&&temporal.owner==this&&!renderer_->Submit(std::as_bytes(std::span(&temporal.command,1)),error))return false;
  return SubmitSynchronous(command,size,&trace);
}

// Caller holds renderer_mutex_.
bool Gta4MetalGraphicsSystem::SubmitSynchronous(const void* command, size_t size, const void* trace) {
  std::string error;
  const bool success = renderer_->Submit({static_cast<const std::byte*>(command), size}, error,
      static_cast<const gta4_native::FireTraceContext*>(trace));
  if (!success) {
    gta4_native::CommandHeader header{};
    if (size >= sizeof(header)) std::memcpy(&header, command, sizeof(header));
    ++failures_;
    if (failures_ <= 64 || failures_ % 4096 == 0)
      REXLOG_ERROR("gta4-metal: command rejected type={} count={} reason={}",
                    uint32_t(header.type), failures_, error);
  }
  return success;
}

bool Gta4MetalGraphicsSystem::Enqueue(const void* command, size_t size, const void* trace,
                                      const void* prefix, size_t prefix_size) {
  using namespace gta4_native;
  QueuedCommand item, first;
  {
    std::unique_lock queue(queue_mutex_);
    queue_space_.wait(queue,[&]{return queue_.size()+2<=queue_limit_||worker_stop_;});
    if(worker_stop_)return false;
    if(!spare_.empty()){item=std::move(spare_.back());spare_.pop_back();}
  }
  if(prefix){
    const auto* p=static_cast<const std::byte*>(prefix);
    first.command.assign(p,p+prefix_size);
  }
  const auto* bytes=static_cast<const std::byte*>(command);
  item.command.assign(bytes,bytes+size);
  item.device.clear();item.payload.clear();item.trace.clear();
  item.device_address=item.payload_address=0;
  if(trace){
    const auto* t=static_cast<const std::byte*>(trace);
    item.trace.assign(t,t+sizeof(FireTraceContext));
  }
  // The guest ranges this command reads when the worker runs it: the D3D device block (render state,
  // constants, texture fetch, streams) for draws, clears, resolves and texture binds, and a
  // DrawPrimitiveUP payload (the title may free or rewrite it as soon as this call returns).
  CommandHeader header{};std::memcpy(&header,command,sizeof(header));
  uint32_t device=0;
  const auto device_of=[&]<class T>(){if(size>=sizeof(T)){T c;std::memcpy(&c,command,sizeof(c));device=c.device;}};
  switch(header.type){
    case CommandType::kDrawPrimitive:device_of.template operator()<DrawPrimitiveCommand>();break;
    case CommandType::kDrawIndexedPrimitive:device_of.template operator()<DrawIndexedPrimitiveCommand>();break;
    case CommandType::kDrawPrimitiveUp:{
      device_of.template operator()<DrawPrimitiveUpCommand>();
      if(size>=sizeof(DrawPrimitiveUpCommand)){
        DrawPrimitiveUpCommand c;std::memcpy(&c,command,sizeof(c));
        if(c.vertex_data&&c.vertex_data_size&&c.vertex_data_size<=4u*1024u*1024u){
          const auto payload=GuestMemory(memory_).Read(c.vertex_data,c.vertex_data_size);
          if(!payload.empty()){item.payload.assign(payload.begin(),payload.end());item.payload_address=c.vertex_data;}
        }
      }
      break;
    }
    case CommandType::kClear:device_of.template operator()<ClearCommand>();break;
    case CommandType::kResolve:device_of.template operator()<ResolveCommand>();break;
    case CommandType::kSetTexture:device_of.template operator()<SetTextureCommand>();break;
    default:
      // gta4_metal_async_snapshot_all (diagnostic): every command whose second word is a device.
      if(snapshot_all_&&size>=sizeof(CommandHeader)+sizeof(uint32_t)&&
         header.type!=CommandType::kRegisterShader&&header.type!=CommandType::kTemporalUpdate&&
         header.type!=CommandType::kQueryDeviceCapabilities&&header.type!=CommandType::kQueryTemporalUpscaler)
        std::memcpy(&device,static_cast<const std::byte*>(command)+sizeof(CommandHeader),sizeof(device));
      break;
  }
  item.headers.clear();item.header_ranges.clear();
  if(device){
    const GuestMemory memory(memory_);
    const auto block=memory.Read(device,kGuestDeviceSize);
    if(!block.empty()){
      item.device_address=device;
      const bool targets=header.type!=CommandType::kSetTexture;
      if(targets){
        const auto word=[&](size_t offset){uint32_t v;std::memcpy(&v,block.data()+offset,4);return __builtin_bswap32(v);};
        const auto add=[&](uint32_t handle,uint32_t bytes){
          if(!handle)return;
          for(const auto& r:item.header_ranges)if(r.first==handle&&r.second>=bytes)return;
          const auto h=memory.Read(handle,bytes);
          if(h.empty())return;
          item.header_ranges.emplace_back(handle,bytes);
          item.headers.insert(item.headers.end(),h.begin(),h.end());
        };
        // Device block offsets as draw.mm/resolve.mm read them (GuestWord): colour targets, depth,
        // index buffer, vertex streams.
        for(uint32_t i=0;i<kRenderTargetCount;++i)add(word(12432+i*4),44);
        add(word(12448),44);
        add(word(12428),32);
        for(uint32_t i=0;i<kVertexStreamCount;++i)add(word(12452+i*4),32);
      }
    }
  }
  {
    std::lock_guard queue(queue_mutex_);
    if(worker_stop_)return false;
    // Device delta in queue order (two submitters must not interleave their diffs).
    item.device.clear();item.device_mask.fill(0);item.device_full=false;
    if(item.device_address){
      const auto block=GuestMemory(memory_).Read(item.device_address,kGuestDeviceSize);
      if(block.empty()){
        item.device_address=0;
      }else if(producer_device_address_!=item.device_address||producer_device_.size()!=kGuestDeviceSize){
        producer_device_.assign(block.begin(),block.end());producer_device_address_=item.device_address;
        item.device.assign(block.begin(),block.end());item.device_full=true;
      }else{
        for(size_t chunk=0,at=0;at<kGuestDeviceSize;++chunk,at+=kDeviceChunk){
          const size_t n=std::min(kDeviceChunk,size_t(kGuestDeviceSize)-at);
          if(std::memcmp(producer_device_.data()+at,block.data()+at,n)){
            std::memcpy(producer_device_.data()+at,block.data()+at,n);
            item.device.insert(item.device.end(),block.begin()+at,block.begin()+at+n);
            item.device_mask[chunk/64]|=uint64_t{1}<<(chunk%64);
          }
        }
      }
    }
    if(prefix){queue_.push_back(std::move(first));++enqueued_;}
    queue_.push_back(std::move(item));
    ++enqueued_;
    published_.store(enqueued_,std::memory_order_release);
    // A wake per command (a kernel call each) cost milliseconds a frame on cheap stretches; the
    // worker spins briefly before sleeping, so most pushes find it awake.
    if(!worker_sleeping_)return true;
  }
  queue_ready_.notify_one();
  return true;
}

void Gta4MetalGraphicsSystem::DrainQueue() {
  std::unique_lock queue(queue_mutex_);
  ++drain_waiters_;
  queue_drained_.wait(queue,[&]{return processed_==enqueued_||!worker_.joinable()||worker_stop_;});
  --drain_waiters_;
}

void Gta4MetalGraphicsSystem::WorkerLoop() {
  pthread_setname_np("Liberty Metal renderer");
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
  std::deque<QueuedCommand> batch;
  uint64_t seen=0;
  for(;;){
    // Spin a little (about 50 us) for the next command before sleeping on the condition variable.
    for(int spin=0;spin<2000&&published_.load(std::memory_order_acquire)==seen;++spin){
      if(spin>200)std::this_thread::yield();
    }
    {
      std::unique_lock queue(queue_mutex_);
      if(queue_.empty()&&!worker_stop_){
        worker_sleeping_=true;
        queue_ready_.wait(queue,[&]{return !queue_.empty()||worker_stop_;});
        worker_sleeping_=false;
      }
      if(queue_.empty())return;  // stopping, nothing left
      batch.swap(queue_);        // everything queued, in order
      seen=enqueued_;
    }
    queue_space_.notify_all();
    size_t done=0;
    for(auto& item:batch){
      std::array<GuestSnapshotRange,32> ranges{};
      size_t count=0;
      if(item.device_address){
        if(item.device_full){
          worker_device_=item.device;worker_device_address_=item.device_address;
        }else if(worker_device_address_==item.device_address&&worker_device_.size()==gta4_native::kGuestDeviceSize){
          size_t from=0;
          for(size_t word=0;word<item.device_mask.size();++word)
            for(uint64_t bits=item.device_mask[word];bits;bits&=bits-1){
              const size_t at=(word*64+size_t(std::countr_zero(bits)))*kDeviceChunk;
              const size_t n=std::min(kDeviceChunk,size_t(gta4_native::kGuestDeviceSize)-at);
              std::memcpy(worker_device_.data()+at,item.device.data()+from,n);from+=n;
            }
        }
        if(worker_device_address_==item.device_address)
          ranges[count++]={item.device_address,worker_device_.data(),worker_device_.size()};
      }
      if(!item.payload.empty())ranges[count++]={item.payload_address,item.payload.data(),item.payload.size()};
      size_t offset=0;
      for(const auto& [address,bytes]:item.header_ranges){
        if(count<ranges.size())ranges[count++]={address,item.headers.data()+offset,bytes};
        offset+=bytes;
      }
      ScopedGuestSnapshots snapshots({ranges.data(),count});
      std::lock_guard lock(renderer_mutex_);
      if(renderer_)SubmitSynchronous(item.command.data(),item.command.size(),item.trace.empty()?nullptr:item.trace.data());
      ++done;
    }
    bool wake_drain=false;
    {
      std::lock_guard queue(queue_mutex_);
      processed_+=done;
      for(auto& item:batch)if(spare_.size()<kMaximumQueuedCommands)spare_.push_back(std::move(item));
      wake_drain=drain_waiters_!=0;
    }
    batch.clear();
    if(wake_drain)queue_drained_.notify_all();
  }
}

void Gta4MetalGraphicsSystem::StopWorker() {
  {
    std::lock_guard queue(queue_mutex_);
    worker_stop_=true;
  }
  queue_ready_.notify_all();queue_space_.notify_all();queue_drained_.notify_all();
  if(worker_.joinable())worker_.join();
  std::lock_guard queue(queue_mutex_);
  queue_.clear();spare_.clear();
}

bool Gta4MetalGraphicsSystem::ExecuteTitleCommand(uint32_t title_id, uint32_t abi,
    const void* command, size_t size, void* result, size_t result_size) {
  if (title_id != gta4_native::kTitleId || !result || !Unwrap(abi, command, size)) return false;
  // Synchronous commands (texture readback, queries) see everything submitted before them.
  if (async_submit_) DrainQueue();
  std::lock_guard lock(renderer_mutex_);
  if (!renderer_) return false;
  std::string error;
  const bool success = renderer_->Execute({static_cast<const std::byte*>(command), size},
      {static_cast<std::byte*>(result), result_size}, error);
  if (!success) REXLOG_ERROR("gta4-metal: synchronous command rejected: {}", error);
  return success;
}

void Gta4MetalGraphicsSystem::PrepareShaderStorage(const std::filesystem::path& cache_root) {
  // Runs before the Metal device exists (see PipelineStore::PrepareLaunch).
  PipelineStore::PrepareLaunch(cache_root, gta4_native::kTitleId);
}

void Gta4MetalGraphicsSystem::InitializeShaderStorage(const std::filesystem::path& cache_root,
                                                      uint32_t title_id, bool blocking) {
  (void)blocking;
  std::lock_guard lock(renderer_mutex_);
  if (!renderer_) return;
  std::string error;
  if (!renderer_->OpenPipelineStore(cache_root, title_id, error))
    REXLOG_WARN("gta4-metal-pipeline-cache: disabled: {}", error);
}

bool Gta4MetalGraphicsSystem::BeginShaderPrecompile(std::function<void()> on_complete) {
  size_t pending = 0;
  {
    std::lock_guard lock(renderer_mutex_);
    if (renderer_) pending = renderer_->PendingPipelineCount();
    // Recipes this build cannot compile (e.g. temporal shaders while temporal AA is off) do not
    // trigger a rebuild, so the next launch need not prepare for one either.
    if (renderer_ && !pending) renderer_->SettlePipelineStore();
  }
  if (!pending || precompile_thread_.joinable()) return false;
  precompile_completed_ = 0;
  precompile_total_ = uint32_t(pending);
  precompile_active_ = true;
  precompile_thread_ = std::thread([this, on_complete = std::move(on_complete)] {
    {
      // The title thread is still suspended; holding the producer lock keeps the renderer exclusive.
      std::lock_guard lock(renderer_mutex_);
      std::string error;
      if (renderer_ && !renderer_->PrecompilePipelines(
              [this](uint32_t done, uint32_t total) {
                precompile_completed_ = done;
                precompile_total_ = total;
                return !precompile_cancel_.load();
              },
              error))
        REXLOG_WARN("gta4-metal-pipeline-cache: precompile: {}", error);
    }
    precompile_active_ = false;
    if (on_complete) on_complete();
  });
  return true;
}

system::IGraphicsSystem::ShaderPrecompileProgress Gta4MetalGraphicsSystem::GetShaderPrecompileProgress() const {
  return {precompile_completed_.load(), precompile_total_.load(), precompile_active_.load()};
}

void Gta4MetalGraphicsSystem::Shutdown() {
  precompile_cancel_ = true;
  if (precompile_thread_.joinable()) precompile_thread_.join();
  // Wake publication waits before taking the producer lock during shutdown.
  if (presenter_) presenter_->CancelFramePacingWaits();
  StopWorker();
  {
    std::lock_guard lock(renderer_mutex_);
    renderer_.reset();
  }
  if (presenter_) {
    auto destroy = [this] { presenter_.reset(); };
    if (app_context_ && !app_context_->IsInUIThread()) {
      if (!app_context_->CallInUIThreadSynchronous(destroy)) {
        REXLOG_ERROR("gta4-metal: UI context unavailable during presentation shutdown");
        return;
      }
    } else {
      destroy();
    }
  }
  provider_.reset();
  app_context_ = nullptr;
}
}  // namespace rex::graphics::gta4_metal
