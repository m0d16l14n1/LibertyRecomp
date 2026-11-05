/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2015 Ben Vanik. All rights reserved.                             *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 *
 * @modified    Tom Clay, 2026 - Adapted for ReXGlue runtime
 */

#include <rex/cvar.h>
#include <rex/thread/mutex.h>

REXCVAR_DEFINE_BOOL(guest_atomics_lock_free, true, "Kernel",
                    "Let the guest's atomic read-modify-write helpers (the console's Interlocked "
                    "functions: mtmsrd r13, lwarx, compare, stwcx., mtmsrd) run without the global "
                    "critical region lock. Each of them holds nothing but loads, compares, branches "
                    "and a store-conditional (a compare-and-swap here), which is atomic by itself; "
                    "the lock made every other thread that takes it (the guest's, the GPU command "
                    "thread, the kernel) wait behind them. Read once at the first use, so a change "
                    "takes effect at the next start. Off takes the lock as before.")
    .lifecycle(rex::cvar::Lifecycle::kRequiresRestart);

namespace rex::thread {

bool global_critical_region::guest_regions_lock_free() {
  static const bool lock_free = REXCVAR_GET(guest_atomics_lock_free);
  return lock_free;
}

std::recursive_mutex& global_critical_region::mutex() {
  static std::recursive_mutex global_mutex;
  return global_mutex;
}

}  // namespace rex::thread
