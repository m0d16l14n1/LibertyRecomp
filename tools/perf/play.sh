#!/bin/bash
# One play session with full logs kept: game log, per-frame times, stdout/stderr, memory/CPU samples,
# crash reports and the settings file at exit.
# usage: tools/perf/play.sh [extra --flags...]   (e.g. --fullscreen=false)
# Output: ~/Library/Application Support/LibertyRecomp/sessions/play-<date>/
repo="$(cd "$(dirname "$0")/../.." && pwd)"
app="$repo/out/build/macos-release/LibertyRecomp/Liberty Recompiled.app/Contents/MacOS/Liberty Recompiled"
out="$HOME/Library/Application Support/LibertyRecomp/sessions/play-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"; echo "$out"
git -C "$repo" log --oneline -1 > "$out/build.txt"
touch "$out/.start"
( sleep 4; osascript -e 'tell application "Liberty Recompiled" to activate' >/dev/null 2>&1 ) &
# Every 30 s: memory footprint (RSS) and CPU of the game.
( sleep 10; echo "time,rss_mb,cpu_pct" > "$out/samples.csv"
  while pid=$(pgrep -x "Liberty Recompiled"); do
    ps -o rss=,%cpu= -p "$pid" | awk -v t="$(date +%H:%M:%S)" '{printf "%s,%d,%s\n", t, $1/1024, $2}' >> "$out/samples.csv"
    sleep 30
  done ) &
caffeinate -dimsu /usr/bin/time -l "$app" --diagnostics=true --diagnostics_categories=logging \
  --log_file="$out/game.log" --gta4_metal_frame_log="$out/frames.csv" "$@" > "$out/stdout.log" 2>&1
echo "exit status $?" >> "$out/stdout.log"
sleep 5
find "$HOME/Library/Logs/DiagnosticReports" -newer "$out/.start" -iname '*Liberty*' -exec cp {} "$out/" \; 2>/dev/null
cp "$HOME/Library/Application Support/LibertyRecomp/native.toml" "$out/" 2>/dev/null
echo "session done: $out"; tail -3 "$out/stdout.log"; ls "$out"
