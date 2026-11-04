/**
 * @file        event_handoff_test.cpp
 * @brief       Event wake-up semantics of the POSIX/macOS wait emulation (upstream rexglue PR #531,
 *              adapted: no nested object locks, no lost wake-up when a reservation folds back)
 *
 * @license     BSD 3-Clause License
 *              See LICENSE file in the project root for full license text.
 */

#include <catch2/catch_test_macros.hpp>
#include <rex/thread.h>

#include <atomic>
#include <chrono>
#include <thread>
#include <vector>

using namespace std::chrono_literals;
using rex::thread::Event;
using rex::thread::SignalAndWait;
using rex::thread::Wait;
using rex::thread::WaitResult;

TEST_CASE("Event - a manual-reset set then reset still releases the threads already waiting",
          "[thread][event]") {
  auto event = Event::CreateManualResetEvent(false);
  std::atomic<int> released{0};
  std::vector<std::thread> waiters;
  for (int i = 0; i < 3; ++i) {
    waiters.emplace_back([&] {
      if (Wait(event.get(), false, 3000ms) == WaitResult::kSuccess) ++released;
    });
  }
  std::this_thread::sleep_for(100ms);  // all three are registered
  event->Set();
  event->Reset();  // a pulse: before any waiter has run
  for (auto& t : waiters) t.join();
  REQUIRE(released == 3);
  // A wait that starts after the reset is not released by it.
  REQUIRE(Wait(event.get(), false, 20ms) == WaitResult::kTimeout);
}

TEST_CASE("Event - an auto-reset set goes to the thread already waiting", "[thread][event]") {
  auto event = Event::CreateAutoResetEvent(false);
  std::atomic<bool> waiter_done{false};
  std::thread waiter([&] { waiter_done = Wait(event.get(), false, 3000ms) == WaitResult::kSuccess; });
  std::this_thread::sleep_for(100ms);
  event->Set();
  // The setter waits at once: on the 360 the signal already belongs to the waiter.
  REQUIRE(Wait(event.get(), false, 0ms) == WaitResult::kTimeout);
  waiter.join();
  REQUIRE(waiter_done);
}

TEST_CASE("Event - a late waiter is woken when a spare reservation folds back", "[thread][event]") {
  // W1 waits; Set reserves for W1. W2 starts waiting; a second Set is reserved too, but W2 is past
  // the boundary. When W1 takes its release the spare one becomes a plain signal, and W2 must wake.
  for (int round = 0; round < 50; ++round) {
    auto event = Event::CreateAutoResetEvent(false);
    std::atomic<int> released{0};
    const auto start = std::chrono::steady_clock::now();
    std::thread w1([&] {
      if (Wait(event.get(), false, 2000ms) == WaitResult::kSuccess) ++released;
    });
    std::this_thread::sleep_for(5ms);
    event->Set();
    std::thread w2([&] {
      if (Wait(event.get(), false, 2000ms) == WaitResult::kSuccess) ++released;
    });
    std::this_thread::sleep_for(5ms);
    event->Set();
    w1.join();
    w2.join();
    REQUIRE(released == 2);
    // A lost wake-up would only end at W2's deadline (its timeout path re-checks the signal).
    REQUIRE(std::chrono::steady_clock::now() - start < 1000ms);
  }
}

TEST_CASE("SignalAndWait - crossed pairs ping-pong without deadlock or lost wake-ups",
          "[thread][event]") {
  auto a = Event::CreateAutoResetEvent(false);
  auto b = Event::CreateAutoResetEvent(false);
  constexpr int kRounds = 5000;
  std::atomic<int> failures{0};
  std::thread other([&] {
    if (Wait(a.get(), false, 2000ms) != WaitResult::kSuccess) ++failures;
    for (int i = 1; i < kRounds; ++i) {
      // Signal b, wait on a: the mirror of the main thread.
      if (SignalAndWait(b.get(), a.get(), false, 2000ms) != WaitResult::kSuccess) {
        ++failures;
        break;
      }
    }
    b->Set();
  });
  auto start = std::chrono::steady_clock::now();
  for (int i = 0; i < kRounds; ++i) {
    if (SignalAndWait(a.get(), b.get(), false, 2000ms) != WaitResult::kSuccess) {
      ++failures;
      break;
    }
  }
  other.join();
  REQUIRE(failures == 0);
  REQUIRE(std::chrono::steady_clock::now() - start < 10s);
}
