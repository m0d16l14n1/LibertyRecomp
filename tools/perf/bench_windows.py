#!/usr/bin/env python3
"""Per-window frame statistics for a bench.sh run: windows are the <name>/<name>_end marks.

usage: bench_windows.py <bench folder>   (frames.csv, frames.csv.origin, marks.csv)
"""
import csv, statistics, sys
from pathlib import Path


def pct(values, q):
    values = sorted(values)
    return values[min(len(values) - 1, int(q * len(values)))] if values else 0.0


def main():
    folder = Path(sys.argv[1])
    origin = int((folder / "frames.csv.origin").read_text().split()[0])
    marks = {}
    for row in csv.reader(open(folder / "marks.csv")):
        if len(row) == 2:
            marks[row[0]] = (int(row[1]) - origin) / 1e6
    frames = list(csv.DictReader(open(folder / "frames.csv")))
    print(f"{'window':<10} {'s':>5} {'fps':>6} {'p50ms':>6} {'p95ms':>6} {'p99ms':>6} {'>25ms':>6} "
          f"{'gpu':>5} {'gpu95':>6} {'submit':>6} {'draws':>5} {'pipes':>5}")
    for name, start in marks.items():
        end = marks.get(name + "_end")
        if end is None:
            continue
        rows = [f for f in frames if start <= float(f["at_ms"]) < end]
        if len(rows) < 2:
            print(f"{name:<10} no frames")
            continue
        iv = [float(f["interval_ms"]) for f in rows]
        gpu = [float(f["gpu_ms"]) for f in rows]
        sub = [float(f["submit_ms"]) for f in rows]
        span = (float(rows[-1]["at_ms"]) - float(rows[0]["at_ms"])) / 1000
        print(f"{name:<10} {span:5.1f} {(len(rows) - 1) / span:6.1f} {pct(iv, .5):6.1f} {pct(iv, .95):6.1f} "
              f"{pct(iv, .99):6.1f} {sum(v > 25 for v in iv):6d} {statistics.mean(gpu):5.2f} {pct(gpu, .95):6.2f} "
              f"{statistics.mean(sub):6.2f} {statistics.mean(int(f['draws']) for f in rows):5.0f} "
              f"{sum(int(f['pipelines_built']) for f in rows):5d}")


if __name__ == "__main__":
    main()
