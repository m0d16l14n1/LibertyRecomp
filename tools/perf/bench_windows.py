#!/usr/bin/env python3
"""Per-window frame statistics for a bench.sh run: windows are the <name>/<name>_end marks.

usage: bench_windows.py <bench folder>   (frames.csv, frames.csv.origin, marks.csv)
"""
import csv, math, statistics, sys
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
    action_windows = ("drive", "night", "heli", "boat", "combat", "boom")
    action_bench = "all" in marks and any(name in marks for name in action_windows)
    action_failures = []
    print(f"{'window':<10} {'s':>5} {'fps':>6} {'p50ms':>6} {'p95ms':>6} {'p99ms':>6} {'>25ms':>6} "
          f"{'gpu':>5} {'gpu95':>6} {'submit':>6} {'draws':>5} {'pipes':>5} {'pwait':>6}")
    if action_bench:
        game_log = folder / "game.log"
        if game_log.exists() and "window covered: frames paced at 2 fps" in game_log.read_text(
                errors="replace"):
            action_failures.append("environment: game window was covered and throttled to 2 fps")
        for name in action_windows:
            if name not in marks or name + "_end" not in marks:
                action_failures.append(f"{name}: missing marks")
    for name, start in marks.items():
        end = marks.get(name + "_end")
        if end is None:
            continue
        rows = [f for f in frames if start <= float(f["at_ms"]) < end]
        if len(rows) < 2:
            print(f"{name:<10} no frames")
            if action_bench and name in action_windows:
                action_failures.append(f"{name}: no frames")
            continue
        iv = [float(f["interval_ms"]) for f in rows]
        gpu = [float(f["gpu_ms"]) for f in rows]
        sub = [float(f["submit_ms"]) for f in rows]
        span = (float(rows[-1]["at_ms"]) - float(rows[0]["at_ms"])) / 1000
        print(f"{name:<10} {span:5.1f} {(len(rows) - 1) / span:6.1f} {pct(iv, .5):6.1f} {pct(iv, .95):6.1f} "
              f"{pct(iv, .99):6.1f} {sum(v > 25 for v in iv):6d} {statistics.mean(gpu):5.2f} {pct(gpu, .95):6.2f} "
              f"{statistics.mean(sub):6.2f} {statistics.mean(int(f['draws']) for f in rows):5.0f} "
              f"{sum(int(f['pipelines_built']) for f in rows):5d} "
              f"{sum(float(f['pipeline_wait_ms']) for f in rows):6.1f}")

    # Scripted action benches must exercise the scene, not merely render it. Earlier broken pads
    # produced plausible FPS tables while the car sat still. New route files carry the same steady
    # clock as marks.csv, so validate each locomotion window without a fragile load-time offset.
    route_path = folder / "route.csv"
    if route_path.exists():
        route = list(csv.DictReader(open(route_path)))
        if route and "steady_ns" in route[0]:
            expected = {
                "drive": (25.0, 0.0),
                "night": (25.0, 0.0),
                "heli": (25.0, 5.0),
                "boat": (25.0, 0.0),
            }
            checked = []
            failed = []
            for name, (minimum_path, minimum_z_span) in expected.items():
                if name not in marks or name + "_end" not in marks:
                    continue
                start_ns = origin + int(marks[name] * 1e6)
                end_ns = origin + int(marks[name + "_end"] * 1e6)
                points = [(float(r["x"]), float(r["y"]), float(r["z"])) for r in route
                          if start_ns <= int(r["steady_ns"]) < end_ns]
                if len(points) < 2:
                    checked.append((name, 0.0, 0.0, 0.0, "NO DATA"))
                    failed.append(name)
                    continue
                path_m = sum(math.dist(a, b) for a, b in zip(points, points[1:]))
                net_m = math.dist(points[0], points[-1])
                z_span = max(p[2] for p in points) - min(p[2] for p in points)
                if path_m < minimum_path:
                    status = "STALLED"
                elif z_span < minimum_z_span:
                    status = "NO FLIGHT"
                else:
                    status = "ok"
                checked.append((name, path_m, net_m, z_span, status))
                if status != "ok":
                    failed.append(name)
            if checked:
                print("movement   path_m  net_m  z_span  status")
                for name, path_m, net_m, z_span, status in sorted(checked):
                    print(f"{name:<10} {path_m:7.1f} {net_m:6.1f} {z_span:7.1f}  {status}")
                if failed:
                    print("movement-check: FAILED " + ", ".join(sorted(failed)))
                    raise SystemExit(1)
                print("movement-check: passed")
    if action_failures:
        print("action-window-check: FAILED " + ", ".join(action_failures))
        raise SystemExit(1)
    if action_bench:
        print("action-window-check: passed")


if __name__ == "__main__":
    main()
