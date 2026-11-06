#pragma once

#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <deque>
#include <memory>
#include <mutex>
#include <thread>
#include <array>
#include <vector>
#include <rex/system/interfaces/graphics.h>

namespace rex::ui::metal { class MetalProvider; }
namespace rex::memory { class Memory; }
namespace rex::graphics::gta4_metal {
class Renderer;

// Title commands are consumed under one owner lock. By default synchronously, on the submitting
// thread. With gta4_metal_async_submit a renderer worker consumes them in order instead: the
// submitting thread copies each command and the guest ranges it reads later (the D3D device block
// for draws, clears, resolves and texture binds; a DrawPrimitiveUP payload) and returns, so the
// title's own CPU work overlaps the translation and encoding. Present and every synchronous
// command (ExecuteTitleCommand) wait for the worker to drain, so it never runs a frame behind:
// buffers and textures the title reuses after a frame keep the console's GPU-read semantics.
class Gta4MetalGraphicsSystem final : public system::IGraphicsSystem {
 public:
  Gta4MetalGraphicsSystem();
  ~Gta4MetalGraphicsSystem() override;
  X_STATUS SetupPresentation(ui::WindowedAppContext* app_context) override;
  X_STATUS SetupGuestGpu(runtime::FunctionDispatcher* dispatcher, system::KernelState* kernel) override;
  bool has_presentation() const override;
  ui::GraphicsProvider* provider() const override;
  ui::Presenter* presenter() const override;
  uint32_t GetTitleCommandAbi(uint32_t title_id) const override;
  bool SubmitTitleCommand(uint32_t title_id, uint32_t abi, const void* command, size_t size) override;
  bool ExecuteTitleCommand(uint32_t title_id, uint32_t abi, const void* command, size_t size,
                           void* result, size_t result_size) override;
  void Shutdown() override;
  void PrepareShaderStorage(const std::filesystem::path& cache_root) override;
  void InitializeShaderStorage(const std::filesystem::path& cache_root, uint32_t title_id, bool blocking) override;
  bool BeginShaderPrecompile(std::function<void()> on_complete) override;
  ShaderPrecompileProgress GetShaderPrecompileProgress() const override;

 private:
  static constexpr size_t kDeviceChunk = 64;
  struct QueuedCommand {
    std::vector<std::byte> command;
    // The device block as a delta against the previous queued snapshot: 64-byte chunks that changed
    // (`device_mask` bit per chunk, their bytes packed in `device`). The worker applies them to its
    // own copy, so it reads one hot block instead of a fresh 22 KB copy per draw.
    std::vector<uint8_t> device, payload;
    std::array<uint64_t, 6> device_mask{};
    bool device_full = false;               // `device` is the whole block (first use, new device)
    uint32_t device_address = 0, payload_address = 0;
    // Guest object headers the device block points to (render-target and depth surfaces, vertex
    // stream and index buffers), read when the worker runs the command: the title re-targets and
    // locks those objects as soon as its call returns.
    std::vector<uint8_t> headers;
    std::vector<std::pair<uint32_t, uint32_t>> header_ranges;  // address, size, packed in `headers`
    std::vector<std::byte> trace;          // gta4_native::FireTraceContext when tracing, else empty
  };
  bool SubmitSynchronous(const void* command, size_t size, const void* trace);
  bool Enqueue(const void* command, size_t size, const void* trace,
               const void* prefix = nullptr, size_t prefix_size = 0);
  static constexpr size_t kMaximumQueuedCommands = 16384;  // back-pressure on a runaway producer
  void DrainQueue();
  void WorkerLoop();
  void StopWorker();

  std::mutex renderer_mutex_;
  memory::Memory* memory_ = nullptr;
  bool async_submit_ = false, snapshot_all_ = false;
  size_t queue_limit_ = kMaximumQueuedCommands;
  // Delta snapshots of the device block: the last block queued (producer, under queue_mutex_ order)
  // and the worker's running copy it is applied to.
  std::vector<uint8_t> producer_device_, worker_device_;
  uint32_t producer_device_address_ = 0, worker_device_address_ = 0;
  std::mutex queue_mutex_;
  std::condition_variable queue_ready_, queue_drained_, queue_space_;
  std::deque<QueuedCommand> queue_;
  std::vector<QueuedCommand> spare_;  // recycled storage
  uint64_t enqueued_ = 0, processed_ = 0;
  bool worker_stop_ = false, worker_sleeping_ = false;
  uint32_t drain_waiters_ = 0;  // a count: Present and a synchronous command can both be draining
  std::atomic<uint64_t> published_{0};  // enqueued_, readable without the lock (worker spin)
  std::thread worker_;
  std::unique_ptr<ui::metal::MetalProvider> provider_;
  std::unique_ptr<ui::Presenter> presenter_;
  std::unique_ptr<Renderer> renderer_;
  ui::WindowedAppContext* app_context_ = nullptr;
  uint64_t failures_ = 0;
  std::thread precompile_thread_;
  std::atomic<uint32_t> precompile_completed_{0}, precompile_total_{0};
  std::atomic<bool> precompile_active_{false}, precompile_cancel_{false};
};
}  // namespace rex::graphics::gta4_metal
