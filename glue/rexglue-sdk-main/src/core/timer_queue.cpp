/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2022 Ben Vanik. All rights reserved.                             *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 *
 * @modified    Tom Clay, 2026 - Adapted for ReXGlue runtime
 */

#include <algorithm>
#include <forward_list>

#include <disruptorplus/blocking_wait_strategy.hpp>
#include <disruptorplus/multi_threaded_claim_strategy.hpp>
#include <disruptorplus/ring_buffer.hpp>
#include <disruptorplus/sequence_barrier.hpp>
#include <disruptorplus/spin_wait_strategy.hpp>

#include <rex/assert.h>
#include <rex/cvar.h>
#include <rex/thread.h>
#include <rex/thread/timer_queue.h>

#if defined(_WIN32)
#include <windows.h>
#endif

namespace dp = disruptorplus;

REXCVAR_DEFINE_BOOL(timer_queue_blocking_wait, true, "Kernel",
                    "Let the timer thread sleep on a condition variable until the next timer "
                    "is due or a new one is queued, instead of spinning (yielding, with a 1 ms "
                    "sleep every 20th turn). Off restores the spin wait.")
    .lifecycle(rex::cvar::Lifecycle::kHotReload);

REXCVAR_DEFINE_BOOL(timer_queue_hr_wait, false, "Kernel",
                    "On Windows, with the timer thread blocking: wait for a timer that is due within "
                    "20 ms on a high-resolution waitable timer (0.3 ms late on average, nothing "
                    "spinning) instead of the condition variable. With libc++ (the llvm-mingw builds) "
                    "a condition variable's timeout is cut down to whole milliseconds, so a timer due "
                    "in under 1 ms makes the wait return at once and the thread spin until it is due: "
                    "a whole core with the 1 ms timestamp timer. On gives that core back (the process "
                    "used 22 to 58% less CPU). With 4 logical processors it also shortened the frame "
                    "(uncapped +17 to 21% FPS, the 99th percentile 30 ms to 10-12 ms); with 16 and 8 "
                    "it made the frame 1 to 2.4% longer in the busier scenes, with or without "
                    "timer_queue_hr_spin_us. So the SDK's default is off; the MCLA host turns it on by "
                    "itself for 5 or fewer logical processors (src/mcla_app.cpp). Off is the "
                    "condition variable and its spin.")
    .lifecycle(rex::cvar::Lifecycle::kHotReload);

REXCVAR_DEFINE_INT32(timer_queue_hr_spin_us, 0, "Kernel",
                     "With timer_queue_hr_wait: how many microseconds before a timer is due the "
                     "timer thread stops sleeping and spins (with the processor's pause hint) "
                     "until it is. The high-resolution wait wakes 0.3 ms late on average, so a "
                     "timer that matters to the millisecond (the 1 ms timestamp the guest reads) is "
                     "late by that; spinning for the last part trades some of the saved CPU for "
                     "an exact wake-up. 0 sleeps all the way.")
    .range(0, 1000)
    .lifecycle(rex::cvar::Lifecycle::kHotReload);

namespace {

#if defined(_WIN32)
// One high-resolution waitable timer per waiting thread.
struct HrTimer {
  HANDLE handle = CreateWaitableTimerExW(nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
                                         TIMER_ALL_ACCESS);
  ~HrTimer() {
    if (handle) {
      CloseHandle(handle);
    }
  }
};
#endif

// The timer thread's wait for new timers: the original spin wait, or with
// timer_queue_blocking_wait a condition variable. Publishing always signals
// the blocking side, so the choice can change while the thread waits.
class TimerWaitStrategy {
 public:
  dp::sequence_t wait_until_published(dp::sequence_t sequence, size_t count,
                                      const std::atomic<dp::sequence_t>* const sequences[]) {
    return Blocking() ? blocking_.wait_until_published(sequence, count, sequences)
                      : spin_.wait_until_published(sequence, count, sequences);
  }

  template <typename Rep, typename Period>
  dp::sequence_t wait_until_published(dp::sequence_t sequence, size_t count,
                                      const std::atomic<dp::sequence_t>* const sequences[],
                                      const std::chrono::duration<Rep, Period>& timeout) {
    return Blocking() ? blocking_.wait_until_published(sequence, count, sequences, timeout)
                      : spin_.wait_until_published(sequence, count, sequences, timeout);
  }

  template <typename Clock, typename Duration>
  dp::sequence_t wait_until_published(dp::sequence_t sequence, size_t count,
                                      const std::atomic<dp::sequence_t>* const sequences[],
                                      const std::chrono::time_point<Clock, Duration>& timeout_time) {
    if (!Blocking()) {
      return spin_.wait_until_published(sequence, count, sequences, timeout_time);
    }
    // An empty queue waits until time_point::max(), which the condition
    // variable cannot convert; wake at least once a second instead (the
    // caller just waits again, and a cvar change is picked up).
    const auto now = Clock::now();
    const auto limit = std::chrono::time_point_cast<Duration>(now + std::chrono::seconds(1));
    auto deadline = timeout_time < limit ? timeout_time : limit;
#if defined(_WIN32)
    if (REXCVAR_GET(timer_queue_hr_wait)) {
      const auto remaining = std::chrono::duration_cast<std::chrono::nanoseconds>(deadline - now);
      if (remaining > std::chrono::nanoseconds::zero()) {
        if (remaining <= std::chrono::milliseconds(20)) {
          dp::sequence_t result;
          const std::chrono::nanoseconds spin(
              static_cast<int64_t>(std::clamp(REXCVAR_GET(timer_queue_hr_spin_us), 0, 1000)) * 1000);
          if (HrWait(sequence, count, sequences, remaining, spin, &result)) {
            return result;
          }
        } else {
          // Long wait: the condition variable until shortly before the deadline (it can wake a
          // tick late), then the loop comes back here for the short wait.
          deadline = std::chrono::time_point_cast<Duration>(deadline - std::chrono::milliseconds(10));
        }
      }
    }
#endif
    return blocking_.wait_until_published(sequence, count, sequences, deadline);
  }

  void signal_all_when_blocking() {
    blocking_.signal_all_when_blocking();
#if defined(_WIN32)
    SetEvent(wake_event_);
#endif
  }

 private:
  static bool Blocking() { return REXCVAR_GET(timer_queue_blocking_wait); }

#if defined(_WIN32)
  // Sleeps on the thread's high-resolution timer until `spin` before `remaining` is up, or until
  // a timer is queued (signal_all_when_blocking), then spins (pause hint) the rest of `remaining`
  // unless something was queued. False if the timer could not be made. *result is what the
  // condition variable's wait would have returned: the least-advanced sequence, which is before
  // `sequence` if nothing was published.
  bool HrWait(dp::sequence_t sequence, size_t count,
              const std::atomic<dp::sequence_t>* const sequences[],
              std::chrono::nanoseconds remaining, std::chrono::nanoseconds spin,
              dp::sequence_t* result) {
    static thread_local HrTimer timer;
    if (!timer.handle) {
      return false;
    }
    const auto end = std::chrono::steady_clock::now() + remaining;
    // The event is reset before the sequences are read: a timer queued after the read sets it
    // again, and the wait below then returns at once.
    ResetEvent(wake_event_);
    *result = dp::minimum_sequence_after(sequence, count, sequences);
    if (dp::difference(*result, sequence) >= 0) {
      return true;
    }
    if (remaining > spin) {
      LARGE_INTEGER due;
      due.QuadPart = -static_cast<LONGLONG>((remaining - spin).count() / 100);
      if (!SetWaitableTimerEx(timer.handle, &due, 0, nullptr, nullptr, nullptr, 0)) {
        return false;
      }
      const HANDLE handles[2] = {wake_event_, timer.handle};
      WaitForMultipleObjects(2, handles, FALSE, INFINITE);
      *result = dp::minimum_sequence_after(sequence, count, sequences);
      if (dp::difference(*result, sequence) >= 0) {
        return true;
      }
    }
    if (spin > std::chrono::nanoseconds::zero()) {
      // The thread is awake and the timer nearly due: wait for it without a wake-up to be late for.
      while (std::chrono::steady_clock::now() < end) {
        *result = dp::minimum_sequence_after(sequence, count, sequences);
        if (dp::difference(*result, sequence) >= 0) {
          return true;
        }
        YieldProcessor();
      }
    }
    return true;
  }

  HANDLE wake_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
#endif

  dp::spin_wait_strategy spin_;
  dp::blocking_wait_strategy blocking_;
};

}  // namespace

namespace rex::thread {

using WaitItem = TimerQueueWaitItem;

class TimerQueue {
 public:
  using clock = WaitItem::clock;
  static_assert(clock::is_steady);

 public:
  TimerQueue()
      : buffer_(kWaitCount),
        wait_strategy_(),
        claim_strategy_(kWaitCount, wait_strategy_),
        consumed_(wait_strategy_) {
    claim_strategy_.add_claim_barrier(consumed_);
    dispatch_thread_ =
        std::jthread([this](std::stop_token stop_token) { TimerThreadMain(stop_token); });
  }

  ~TimerQueue() {
    dispatch_thread_.request_stop();

    // Kick dispatch thread to check stop token
    auto wait_item = std::make_shared<WaitItem>(nullptr, nullptr, this, clock::time_point::min(),
                                                clock::duration::zero());
    wait_item->Disarm();
    QueueTimer(std::move(wait_item));

    // std::jthread auto-joins on destruction
  }

  void TimerThreadMain(std::stop_token stop_token) {
    dp::sequence_t next_sequence = 0;
    const auto comp = [](const std::shared_ptr<WaitItem>& left,
                         const std::shared_ptr<WaitItem>& right) {
      return left->due_ < right->due_;
    };

    set_current_thread_name("rex::thread::TimerQueue");

    while (!stop_token.stop_requested()) {
      {
        // Consume new wait items and add them to sorted wait queue
        dp::sequence_t available = claim_strategy_.wait_until_published(
            next_sequence, next_sequence - 1,
            wait_queue_.empty() ? clock::time_point::max() : wait_queue_.front()->due_);

        // Check for timeout
        if (available != next_sequence - 1) {
          std::forward_list<std::shared_ptr<WaitItem>> wait_items;
          do {
            wait_items.push_front(std::move(buffer_[next_sequence]));
          } while (next_sequence++ != available);

          consumed_.publish(available);

          wait_items.sort(comp);
          wait_queue_.merge(wait_items, comp);
        }
      }

      {
        // Check wait queue, invoke callbacks and reschedule
        std::forward_list<std::shared_ptr<WaitItem>> wait_items;
        while (!wait_queue_.empty() && wait_queue_.front()->due_ <= clock::now()) {
          auto wait_item = std::move(wait_queue_.front());
          wait_queue_.pop_front();

          // Ensure that it isn't disarmed
          auto state = WaitItem::State::kIdle;
          if (wait_item->state_.compare_exchange_strong(state, WaitItem::State::kInCallback,
                                                        std::memory_order_acq_rel)) {
            // Possibility to dispatch to a thread pool here
            assert_not_null(wait_item->callback_);
            wait_item->callback_(wait_item->userdata_);

            if (wait_item->interval_ != clock::duration::zero() &&
                wait_item->state_.load(std::memory_order_acquire) !=
                    WaitItem::State::kInCallbackSelfDisarmed) {
              // Item is recurring and didn't self-disarm during callback:
              wait_item->due_ += wait_item->interval_;
              wait_item->state_.store(WaitItem::State::kIdle, std::memory_order_release);
              wait_item->state_.notify_all();
              wait_items.push_front(std::move(wait_item));
            } else {
              wait_item->state_.store(WaitItem::State::kDisarmed, std::memory_order_release);
              wait_item->state_.notify_all();
            }
          } else {
            // Specifically, kInCallback is illegal here
            assert_true(WaitItem::State::kDisarmed == state);
          }
        }
        wait_items.sort(comp);
        wait_queue_.merge(wait_items, comp);
      }
    }
  }

  std::weak_ptr<WaitItem> QueueTimer(std::shared_ptr<WaitItem> wait_item) {
    auto wait_item_weak = std::weak_ptr<WaitItem>(wait_item);

    // Mitigate callback flooding
    wait_item->due_ = std::max(clock::now() - wait_item->interval_, wait_item->due_);

    auto sequence = claim_strategy_.claim_one();
    buffer_[sequence] = std::move(wait_item);
    claim_strategy_.publish(sequence);

    return wait_item_weak;
  }

  std::jthread::id dispatch_thread_id() const { return dispatch_thread_.get_id(); }

 private:
  // This ring buffer will be used to introduce timers queued by the public API
  static constexpr size_t kWaitCount = 512;
  dp::ring_buffer<std::shared_ptr<WaitItem>> buffer_;
  TimerWaitStrategy wait_strategy_;
  dp::multi_threaded_claim_strategy<TimerWaitStrategy> claim_strategy_;
  dp::sequence_barrier<TimerWaitStrategy> consumed_;

  // This is a _sorted_ (ascending due_) list of active timers managed by a
  // dedicated thread
  std::forward_list<std::shared_ptr<WaitItem>> wait_queue_;
  std::jthread dispatch_thread_;
};

rex::thread::TimerQueue timer_queue_;

void TimerQueueWaitItem::Disarm() {
  State state;

  // Special case for calling from a callback itself
  if (std::this_thread::get_id() == parent_queue_->dispatch_thread_id()) {
    state = State::kInCallback;
    if (state_.compare_exchange_strong(state, State::kInCallbackSelfDisarmed,
                                       std::memory_order_acq_rel)) {
      // If we are self disarming from the callback set this special state and
      // exit
      return;
    }
    // Normal case can handle the rest
  }

  state = State::kIdle;
  // Classes which hold WaitItems will often call Disarm() to cancel them during
  // destruction. This may lead to race conditions when the dispatch thread
  // executes a callback which accesses memory that is freed simultaneously due
  // to this. Therefore, we need to guarantee that no callbacks will be running
  // once Disarm() has returned.
  while (!state_.compare_exchange_weak(state, State::kDisarmed, std::memory_order_acq_rel)) {
    if (state == State::kDisarmed) {
      break;
    }
    if (state == State::kInCallback || state == State::kInCallbackSelfDisarmed) {
      // Wait for callback to complete - dispatch thread will notify
      state_.wait(state, std::memory_order_acquire);
    }
    state = State::kIdle;
  }
}

std::weak_ptr<WaitItem> QueueTimerOnce(std::function<void(void*)> callback, void* userdata,
                                       WaitItem::clock::time_point due) {
  return timer_queue_.QueueTimer(std::make_shared<WaitItem>(
      std::move(callback), userdata, &timer_queue_, due, WaitItem::clock::duration::zero()));
}

std::weak_ptr<WaitItem> QueueTimerRecurring(std::function<void(void*)> callback, void* userdata,
                                            WaitItem::clock::time_point due,
                                            WaitItem::clock::duration interval) {
  return timer_queue_.QueueTimer(
      std::make_shared<WaitItem>(std::move(callback), userdata, &timer_queue_, due, interval));
}

}  // namespace rex::thread
