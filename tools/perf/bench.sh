#!/bin/bash
# Run one benchmark pass and print per-window frame statistics.
# usage: tools/perf/bench.sh <label> [--pad=<file.pad>] [extra --flags...]
#   tools/perf/bench.sh smaa
#   tools/perf/bench.sh metalfx-b --gta4_native_upscaler=metalfx --gta4_fsr1_quality=balanced
# Output: ~/Library/Application Support/LibertyRecomp/perf/bench-<date>-<label>/ (frames.csv, marks.csv,
# game.log, end.png, summary.txt). The default pad script needs a profile with no story save, as it
# expects the new-game intro (tools/perf/pads/dock-bench.pad).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
label="${1:?usage: bench.sh <label> [--pad=file] [--flags]}"; shift
pad="$here/pads/dock-bench.pad"
args=()
for a in "$@"; do
  case "$a" in --pad=*) pad="${a#--pad=}" ;; *) args+=("$a") ;; esac
done
app="$repo/out/build/macos-release/LibertyRecomp/Liberty Recompiled.app/Contents/MacOS/Liberty Recompiled"
out="$HOME/Library/Application Support/LibertyRecomp/perf/bench-$(date +%Y%m%d-%H%M%S)-$label"
mkdir -p "$out"
sed "s|{out}|$out|g" "$pad" > "$out/run.pad"
echo "bench $label -> $out"
( sleep 4; osascript -e 'tell application "Liberty Recompiled" to activate' >/dev/null 2>&1 ) &
caffeinate -dimsu /usr/bin/time -l "$app" --diagnostics=true --diagnostics_categories=logging \
  --log_file="$out/game.log" --gta4_metal_frame_log="$out/frames.csv" \
  --gta4_pad_script="$out/run.pad" --gta4_pad_marks="$out/marks.csv" --gta4_pad_exit_on_end=true \
  ${args[@]+"${args[@]}"} > "$out/stdout.log" 2>&1 || true
python3 "$here/bench_windows.py" "$out" > "$out/summary.txt"
# Process CPU over the whole run (from /usr/bin/time -l), for comparing CPU-side changes.
awk '/real/ && /user/ && /sys/ {printf "process: %s s wall, %s s user, %s s sys\n", $1, $3, $5}' "$out/stdout.log" >> "$out/summary.txt"
cat "$out/summary.txt"
