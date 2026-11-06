#!/bin/bash
# Record a route in the career (you play), then replay it as a benchmark as often as needed.
#
#   tools/perf/route_bench.sh record <route> [--flags...]            # you play; quit the game to stop
#   tools/perf/route_bench.sh replay <route> [label] [--flags...]    # hands off keyboard and mouse
#   tools/perf/route_bench.sh pad <route> <file.pad> [label] [--flags...]  # a dev pad script on that save
#   tools/perf/route_bench.sh list
#
# Saves are never touched: every run gets a throwaway home (local/route-home) whose game/, dlc/ and
# shader_cache/ link to the real ones and whose saves/ and native.toml are copies. `record` snapshots
# your saves and settings into the route folder, so every replay starts from the save the route was
# recorded on, with the same settings, whatever happens to your real save later.
#
# Recording and replay start when the loading screen ends (gta4_input_record / gta4_input_replay in
# gta4_dev_pad.cpp). Inputs replay by time, so a slower or faster run gets the same input at the same
# moment; the game world is not deterministic (traffic, pedestrians), so the player can drift from
# the recorded route: route.csv and the drift line in summary.txt say by how much.
#
# Route folder: ~/Library/Application Support/LibertyRecomp/perf/routes/<route>/
#   input.rec (the recording), saves/ and native.toml (the snapshot), record/ (the recording session:
#   game.log, frames.csv, marks.csv, shots/record-*.png every 15 s), flags.txt (flags given to record)
# Replay folder: ~/Library/Application Support/LibertyRecomp/perf/route-<route>-<date>-<label>/
#   summary.txt (windows route and w0000.. every 30 s, display lines, drift, process CPU), frames.csv,
#   marks.csv, route.csv (position against the recorded one), shots/replay-*.png, game.log, stdout.log,
#   native.toml, build.txt
#
# `pad` runs a dev pad script ({out} is the run folder) from the route's saved snapshot instead of the
# recorded input: tools/perf/pads/city-drive.pad puts the player in a car in Star Junction and lets
# the game's driving AI take it around (teleport/car/drive commands, gta4_dev_world.cpp). The
# output is the same as a replay's (route.csv has the position only).
#
# Replays run windowed in the background (--background_window=true: the game never takes focus or the
# mouse, so you can keep working) unless --fullscreen=true or --background_window=false is passed.
# Keep the game window visible while a replay runs: macOS slows windows that are covered or hidden.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
app="${BENCH_APP:-$repo/out/build/macos-release/LibertyRecomp/Liberty Recompiled.app/Contents/MacOS/Liberty Recompiled}"
support="$HOME/Library/Application Support/LibertyRecomp"
routes="$support/perf/routes"
throwaway="$repo/local/route-home"
mode="${1:-}"; shift || true

wait_for_peers() {
  # One thermal-sensitive run at a time on this Mac (MCLA, FIFA 19, SpeedBreaker sessions).
  while pgrep -x mcla >/dev/null || pgrep -f mac_race_bench >/dev/null || pgrep -x fifa19 >/dev/null \
        || pgrep -f bench_quickrace >/dev/null || pgrep -x SpeedBreaker >/dev/null \
        || pgrep -x "Liberty Recompiled" >/dev/null; do
    echo "waiting for another game or bench to finish..."; sleep 20
  done
}

# The throwaway home for one run: links to the large shared folders, copies of saves and settings.
prepare_home() {  # <saves source> <native.toml source>
  local root="$throwaway/Library/Application Support/LibertyRecomp"
  rm -rf "$throwaway"
  mkdir -p "$root/logs"
  for linked in game dlc shader_cache "User Music"; do
    [ -e "$support/$linked" ] && ln -s "$support/$linked" "$root/$linked"
  done
  cp -R "$1" "$root/saves"
  [ -f "$2" ] && cp "$2" "$root/native.toml"
  return 0
}

run_game() {  # <out folder> <flags...>
  local out="$1"; shift
  git -C "$repo" log --oneline -1 > "$out/build.txt"
  git -C "$repo" status --short --untracked-files=no >> "$out/build.txt"
  # In the background (background_window) nothing takes focus; otherwise bring the game forward.
  case " $* " in
    *" --background_window=true "*) ;;
    *) ( sleep 4; osascript -e 'tell application "Liberty Recompiled" to activate' >/dev/null 2>&1 ) & ;;
  esac
  # Sample the live process instead of relying only on time(1)'s final peak. This catches the
  # gradual unified-memory growth that can otherwise make a long MetalFX session exhaust RAM.
  (
    echo "elapsed_s,rss_mb,vsz_mb,cpu_pct" > "$out/samples.csv"
    local pid=""
    for _ in $(seq 1 100); do
      pid="$(pgrep -x "Liberty Recompiled" | head -1 || true)"
      [ -n "$pid" ] && break
      sleep 0.1
    done
    [ -n "$pid" ] || exit 0
    local sample_start
    sample_start="$(date +%s)"
    while kill -0 "$pid" 2>/dev/null; do
      ps -o rss=,vsz=,%cpu= -p "$pid" | awk -v t="$(($(date +%s)-sample_start))" \
        '{printf "%d,%.1f,%.1f,%s\n", t, $1/1024, $2/1024, $3}' >> "$out/samples.csv"
      sleep 2
    done
  ) &
  local sample_job=$!
  HOME="$throwaway" caffeinate -dimsu /usr/bin/time -l "$app" --diagnostics=true \
    --diagnostics_categories="${DIAG_CATEGORIES:-logging}" --log_file="$out/game.log" \
    --gta4_metal_frame_log="$out/frames.csv" --gta4_pad_marks="$out/marks.csv" \
    --gta4_input_shots="$out/shots" "$@" > "$out/stdout.log" 2>&1 || true
  wait "$sample_job" || true
  cp "$throwaway/Library/Application Support/LibertyRecomp/native.toml" "$out/native.toml" 2>/dev/null || true
}

summarize() {  # <out folder>
  local out="$1"
  local analysis_status=0
  python3 "$here/bench_windows.py" "$out" > "$out/summary.txt" 2>&1 || analysis_status=$?
  grep -o 'gta4-metal-display shown-fps.*' "$out/game.log" | sed 's/^gta4-metal-display /display: /' \
    >> "$out/summary.txt" || true
  grep -o 'input replay: done.*' "$out/game.log" | sed 's/^input replay: /drift: /' >> "$out/summary.txt" || true
  awk '/real/ && /user/ && /sys/ {printf "process: %s s wall, %s s user, %s s sys\n", $1, $3, $5}' \
    "$out/stdout.log" >> "$out/summary.txt"
  awk -F, 'NR>1 && $2>0 {if (!samples) {first=$2; peak=$2}; if ($2>peak) peak=$2; end=$2; samples++}
    END {if (samples) printf "memory: RSS %.1f MB start, %.1f MB peak, %.1f MB end, %+.1f MB growth (%d samples)\n", first,peak,end,end-first,samples}' \
    "$out/samples.csv" >> "$out/summary.txt" 2>/dev/null || true
  cat "$out/summary.txt"
  return "$analysis_status"
}

case "$mode" in
  record)
    route="${1:?usage: route_bench.sh record <route> [--flags]}"; shift
    dir="$routes/$route"
    [ -e "$dir/input.rec" ] && { echo "route '$route' exists ($dir); pick another name" >&2; exit 1; }
    mkdir -p "$dir/record/shots"
    cp -R "$support/saves" "$dir/saves"
    cp "$support/native.toml" "$dir/native.toml" 2>/dev/null || true
    printf '%s\n' "$@" > "$dir/flags.txt"
    wait_for_peers
    prepare_home "$dir/saves" "$dir/native.toml"
    echo "recording route '$route': play, then quit the game (Cmd+Q) to stop"
    run_game "$dir/record" --gta4_input_record="$dir/input.rec" "$@"
    # Windows for the recording session itself: the whole route.
    first=$(grep -m1 '^record,' "$dir/record/marks.csv" | cut -d, -f2 || true)
    if [ -n "$first" ] && [ -s "$dir/record/frames.csv.origin" ]; then
      last=$(awk -F, 'NR>1 {t=$2} END {printf "%d", t}' "$dir/record/frames.csv")
      origin=$(cut -d' ' -f1 < "$dir/record/frames.csv.origin")
      echo "record_end,$((origin + last * 1000000))" >> "$dir/record/marks.csv"
    fi
    summarize "$dir/record"
    samples=$(grep -vc '^#' "$dir/input.rec" || true)
    seconds=$(awk '!/^#/ {t=$1} END {printf "%.1f", t / 1e6}' "$dir/input.rec")
    echo "route '$route': $samples input samples over $seconds s in $dir"
    ;;
  replay)
    route="${1:?usage: route_bench.sh replay <route> [label] [--flags]}"; shift
    label="run"
    if [ $# -gt 0 ] && [[ "$1" != --* ]]; then label="$1"; shift; fi
    dir="$routes/$route"
    [ -s "$dir/input.rec" ] || { echo "no recording for route '$route' in $dir" >&2; exit 1; }
    out="$support/perf/route-$route-$(date +%Y%m%d-%H%M%S)-$label"
    mkdir -p "$out/shots"
    wait_for_peers
    prepare_home "$dir/saves" "$dir/native.toml"
    flags=()
    while IFS= read -r flag; do [ -n "$flag" ] && flags+=("$flag"); done < "$dir/flags.txt"
    echo "replaying route '$route' -> $out (hands off the keyboard and mouse)"
    # Windowed and in the background (no focus, no mouse capture) unless told otherwise:
    # --fullscreen=true or --background_window=false.
    case " ${flags[*]-} $* " in *" --fullscreen"*) ;; *) flags=(--fullscreen=false ${flags[@]+"${flags[@]}"}) ;; esac
    case " ${flags[*]-} $* " in *" --background_window"*) ;; *) flags=(--background_window=true ${flags[@]+"${flags[@]}"}) ;; esac
    run_game "$out" ${flags[@]+"${flags[@]}"} --gta4_input_replay="$dir/input.rec" \
      --gta4_input_route="$out/route.csv" --gta4_pad_exit_on_end=true "$@"
    summarize "$out"
    ;;
  pad)
    route="${1:?usage: route_bench.sh pad <route> <file.pad> [label] [--flags]}"; shift
    pad="${1:?usage: route_bench.sh pad <route> <file.pad> [label] [--flags]}"; shift
    label="$(basename "$pad" .pad)"
    if [ $# -gt 0 ] && [[ "$1" != --* ]]; then label="$1"; shift; fi
    dir="$routes/$route"
    [ -d "$dir/saves" ] || { echo "no save snapshot for route '$route' in $dir" >&2; exit 1; }
    out="$support/perf/route-$route-$(date +%Y%m%d-%H%M%S)-$label"
    mkdir -p "$out/shots"
    sed "s|{out}|$out|g" "$pad" > "$out/run.pad"
    wait_for_peers
    prepare_home "$dir/saves" "$dir/native.toml"
    echo "running $pad on route '$route' save -> $out"
    flags=()
    case " $* " in *" --fullscreen"*) ;; *) flags+=(--fullscreen=false) ;; esac
    case " $* " in *" --background_window"*) ;; *) flags+=(--background_window=true) ;; esac
    run_game "$out" ${flags[@]+"${flags[@]}"} --gta4_pad_script="$out/run.pad" \
      --gta4_input_route="$out/route.csv" --gta4_pad_exit_on_end=true "$@"
    summarize "$out"
    ;;
  list)
    for d in "$routes"/*/; do
      [ -s "$d/input.rec" ] || continue
      printf '%-24s %s s\n' "$(basename "$d")" "$(awk '!/^#/ {t=$1} END {printf "%.1f", t / 1e6}' "$d/input.rec")"
    done
    ;;
  *)
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
