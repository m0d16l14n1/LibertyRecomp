#!/bin/bash
# Run bench.sh once per line of a matrix file: "<label> [--flags...]" ('#' lines are skipped);
# "rest <seconds>" pauses between runs (a fanless Mac throttles over back-to-back runs).
# usage: tools/perf/bench_matrix.sh <matrix.txt>
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
while IFS= read -r line; do
  line="${line%%#*}"; [ -z "${line// }" ] && continue
  read -r -a words <<< "$line"
  if [ "${words[0]}" = rest ]; then sleep "${words[1]}"; continue; fi
  "$here/bench.sh" "${words[@]}" 2>&1 | tail -n 5
done < "${1:?usage: bench_matrix.sh <matrix.txt>}"
