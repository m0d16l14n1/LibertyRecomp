#include "context.h"

#include <dispatch/dispatch.h>

#include "metal_ui_library.h"
#include "metal4_queue.h"

#include <rex/cvar.h>
#include <rex/logging.h>

REXCVAR_DEFINE_STRING(gta4_metal_api, "metal3", "GPU/Metal",
    "Command API for the Metal renderer: metal3, or metal4 (MTL4 queue, argument tables, residency sets; falls back to metal3 without Metal 4)")
    .lifecycle(rex::cvar::Lifecycle::kRequiresRestart);

namespace rex::ui::metal {

std::string MetalError(NSError* error, const char* fallback) {
  const char* description = error.localizedDescription.UTF8String;
  return description ? description : fallback;
}

std::shared_ptr<MetalContext> MetalContext::Create(std::string& error) {
  @autoreleasepool {
    error.clear();
    auto context = std::make_shared<MetalContext>();
    context->device = MTLCreateSystemDefaultDevice();
    if (!context->device) {
      error = "No Metal device is available.";
      return {};
    }
    // Initial support is Apple-silicon macOS. Other renderer choices are unchanged.
    if (!context->device.hasUnifiedMemory || ![context->device supportsFamily:MTLGPUFamilyApple1]) {
      error = "The experimental Metal backend currently requires an Apple GPU.";
      return {};
    }
    if (rex::cvar::GetFlagByName("gta4_metal_api") == "metal4") {
      std::string metal4_error;
      context->queue = NewMetal4Queue(context->device, metal4_error);
      if (context->queue) REXLOG_INFO("gta4-metal: command API metal4");
      else REXLOG_WARN("gta4-metal: command API metal4 unavailable ({}); using metal3", metal4_error);
    }
    if (!context->queue) context->queue = [context->device newCommandQueue];
    if (!context->queue) {
      error = "Metal command queue creation failed.";
      return {};
    }
    context->queue.label = @"Liberty Metal";
    auto data = dispatch_data_create(kMetalUiLibrary, sizeof(kMetalUiLibrary),
                                     nullptr, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    NSError* library_error = nil;
    context->ui_library = [context->device newLibraryWithData:data error:&library_error];
    if (!context->ui_library) {
      error = MetalError(library_error, "Metal UI library loading failed.");
      return {};
    }
    context->ui_library.label = @"Liberty Metal UI";
    return context;
  }
}

}  // namespace rex::ui::metal
