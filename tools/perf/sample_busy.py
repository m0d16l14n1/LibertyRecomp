#!/usr/bin/env python3
"""Busy share per thread from a macOS `sample` report: samples whose leaf frame is not a blocking call.

usage: sample <pid> 10 -file s.txt; tools/perf/sample_busy.py s.txt [top N]
"""
import re, sys

WAITS = ("__psynch_cvwait", "mach_msg2_trap", "__semwait_signal", "kevent", "__workq_kernreturn",
         "__psynch_mutexwait", "__select", "__ulock_wait", "semaphore_wait_trap", "__wait4", "read",
         "__recvfrom", "poll", "__open", "mach_wait_until", "__sigsuspend", "__psynch_rw_rdlock",
         "semaphore_timedwait_trap", "semaphore_wait_signal_trap", "__psynch_rw_wrlock")
line_re = re.compile(r"^(\s*)[+!:| ]*(\d+) (.*)$")


def main():
    lines = open(sys.argv[1], errors="replace").read().split("Call graph:")[1].split("Total number in stack")[0].splitlines()
    top = int(sys.argv[2]) if len(sys.argv) > 2 else 25
    threads, name, total, busy = [], None, 0, 0
    parsed = []
    for raw in lines:
        m = line_re.match(raw)
        if not m:
            continue
        depth = len(raw) - len(raw.lstrip(" +!:|"))
        parsed.append((depth, int(m.group(2)), m.group(3)))
    for i, (depth, count, text) in enumerate(parsed):
        if text.startswith("Thread_"):
            if name:
                threads.append((busy, total, name))
            name, total, busy = text, count, 0
            continue
        leaf = i + 1 >= len(parsed) or parsed[i + 1][0] <= depth
        if leaf and not any(w in text for w in WAITS):
            busy += count
    if name:
        threads.append((busy, total, name))
    threads.sort(reverse=True)
    for b, t, n in threads[:top]:
        print(f"{100 * b / t:5.1f}%  {n[:90]}")
    print(f"sum {sum(b / t for b, t, _ in threads):.2f} cores busy")


if __name__ == "__main__":
    main()
