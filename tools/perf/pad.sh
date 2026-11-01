#!/bin/bash
# Send commands to a running game started with --gta4_pad_pipe=<fifo> and print the replies.
# usage: tools/perf/pad.sh <fifo> "press a" "wait 2s" "shot /tmp/a.png 0.5"
# Commands run in order and each waits for the previous (see gta4_dev_pad.cpp for the list).
set -euo pipefail
fifo="${1:?usage: pad.sh <fifo> <command>...}"; shift
out="$fifo.out"
[ -p "$fifo" ] || { echo "no FIFO at $fifo (is the game running with --gta4_pad_pipe?)" >&2; exit 1; }
touch "$out"
start=$(wc -l < "$out")
printf '%s\n' "$@" > "$fifo"
want=$((start + $#))
while [ "$(wc -l < "$out")" -lt "$want" ]; do sleep 0.2; done
tail -n +"$((start + 1))" "$out"
