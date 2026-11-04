#!/usr/bin/env python3
"""Shot-to-shot stability of a still scene, per MetalFX jitter sign (tools/perf/pads/jitter-check.pad).

usage: jitter_stability.py <run folder>   (shots/jit-<round>-<sign>-<i>.png)
For every burst: the median, over edge pixels (strong local gradient in the first shot), of the
mean absolute change between consecutive shots. Lower is steadier. A moving character or
flickering light touches few edge pixels and barely moves the median.
"""
import re, sys
from collections import defaultdict
from pathlib import Path

import numpy as np
from PIL import Image


def load(path):
    return np.asarray(Image.open(path).convert("L"), dtype=np.float32)


def burst_score(paths):
    frames = [load(p) for p in paths]
    first = frames[0]
    gx = np.abs(np.diff(first, axis=1))[:-1, :]
    gy = np.abs(np.diff(first, axis=0))[:, :-1]
    edges = (gx + gy) > 24
    if edges.sum() < 100:
        return float("nan"), 0
    diffs = [np.abs(b - a)[:-1, :-1][edges] for a, b in zip(frames, frames[1:])]
    return float(np.median(np.mean(diffs, axis=0))), int(edges.sum())


def main():
    shots = Path(sys.argv[1]) / "shots"
    bursts = defaultdict(list)
    for p in sorted(shots.glob("jit-*.png")):
        m = re.match(r"jit-(\d+)-(\w\w)-(\d+)\.png", p.name)
        if m:
            bursts[(m[1], m[2])].append((int(m[3]), p))
    names = {"pp": "++", "mm": "--", "mp": "-+", "pm": "+-"}
    per_sign = defaultdict(list)
    for (rnd, sign), items in sorted(bursts.items()):
        score, n = burst_score([p for _, p in sorted(items)])
        per_sign[sign].append(score)
        print(f"round {rnd} sign {names.get(sign, sign)}: edge change {score:.2f} ({n} edge px)")
    for sign, scores in per_sign.items():
        print(f"sign {names.get(sign, sign)}: mean {np.nanmean(scores):.2f}")


if __name__ == "__main__":
    main()
