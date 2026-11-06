#!/bin/bash

set -euo pipefail

support_dir="${LIBERTY_RECOMP_SUPPORT_DIR:-${HOME}/Library/Application Support/LibertyRecomp}"
perf_dir="${support_dir}/perf"
action="dry-run"
older_than=2
all_runs=false
confirmed=false

usage() {
    cat <<'EOF'
Usage: tools/perf/cleanup_artifacts.sh [options]

Reports or cleans generated benchmark run directories under:
  ~/Library/Application Support/LibertyRecomp/perf

The default is a dry run selecting runs older than two days. The reusable
perf/routes directory, game files, saves, settings, logs, sessions, and shader
cache are never selected.

Options:
  --older-than DAYS  Select runs at least DAYS old (default: 2; minimum: 1)
  --all              Select every generated run, including recent ones
  --trash            Move selected runs to a timestamped macOS Trash folder
  --delete           Permanently delete selected runs (requires --yes)
  --yes              Confirm permanent deletion
  -h, --help         Show this help

Examples:
  tools/perf/cleanup_artifacts.sh
  tools/perf/cleanup_artifacts.sh --older-than 2 --trash
  tools/perf/cleanup_artifacts.sh --all --delete --yes
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --older-than)
            [[ $# -ge 2 ]] || { echo "error: --older-than needs a value" >&2; exit 2; }
            older_than="$2"
            shift 2
            ;;
        --all)
            all_runs=true
            shift
            ;;
        --trash)
            [[ "$action" == "dry-run" ]] || { echo "error: choose only one cleanup action" >&2; exit 2; }
            action="trash"
            shift
            ;;
        --delete)
            [[ "$action" == "dry-run" ]] || { echo "error: choose only one cleanup action" >&2; exit 2; }
            action="delete"
            shift
            ;;
        --yes)
            confirmed=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ "$older_than" =~ ^[0-9]+$ ]] && (( older_than >= 1 )) || {
    echo "error: --older-than must be an integer of at least 1" >&2
    exit 2
}

if [[ "$action" == "delete" && "$confirmed" != true ]]; then
    echo "error: permanent deletion requires --yes" >&2
    exit 2
fi

if [[ ! -d "$perf_dir" ]]; then
    echo "No benchmark directory found at: $perf_dir"
    exit 0
fi

# Resolve the directory before any mutation, then insist that the selected
# entries are immediate children. This prevents a malformed path from turning
# cleanup into a broad recursive operation.
perf_dir="$(cd "$perf_dir" && pwd -P)"
[[ -n "$perf_dir" && "$perf_dir" != "/" ]] || {
    echo "error: refusing unsafe benchmark directory: $perf_dir" >&2
    exit 2
}

candidates=()
if [[ "$all_runs" == true ]]; then
    while IFS= read -r -d '' path; do
        candidates+=("$path")
    done < <(find "$perf_dir" -mindepth 1 -maxdepth 1 -type d ! -name routes -print0)
else
    # find rounds modification age down to whole days, so +N-1 selects entries
    # whose age is at least the requested number of 24-hour periods.
    find_age=$((older_than - 1))
    while IFS= read -r -d '' path; do
        candidates+=("$path")
    done < <(find "$perf_dir" -mindepth 1 -maxdepth 1 -type d ! -name routes -mtime "+${find_age}" -print0)
fi

echo "LibertyRecomp support usage:"
du -sh "$support_dir" 2>/dev/null || true
echo "Benchmark artifacts:"
du -sh "$perf_dir" 2>/dev/null || true
echo "Protected route recordings:"
du -sh "$perf_dir/routes" 2>/dev/null || echo "0B  $perf_dir/routes (not present)"
echo

if (( ${#candidates[@]} == 0 )); then
    echo "No generated benchmark runs match the selection."
    exit 0
fi

candidate_kib=0
for path in "${candidates[@]}"; do
    [[ "$(dirname "$path")" == "$perf_dir" && "$(basename "$path")" != "routes" ]] || {
        echo "error: refusing unsafe candidate: $path" >&2
        exit 2
    }
    size_kib="$(du -sk "$path" | awk '{print $1}')"
    candidate_kib=$((candidate_kib + size_kib))
done

if [[ "$all_runs" == true ]]; then
    selection="all generated runs"
else
    selection="runs at least ${older_than} day(s) old"
fi

echo "Selected ${#candidates[@]} ${selection} ($(awk -v kib="$candidate_kib" 'BEGIN { printf "%.2f GiB", kib / 1048576 }')):"
for path in "${candidates[@]}"; do
    du -sh "$path"
done
echo

case "$action" in
    dry-run)
        echo "Dry run only; nothing changed. Add --trash or --delete --yes after reviewing this list."
        ;;
    trash)
        trash_dir="${HOME}/.Trash/LibertyRecomp-perf-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$trash_dir"
        for path in "${candidates[@]}"; do
            mv "$path" "$trash_dir/"
        done
        echo "Moved ${#candidates[@]} run(s) to: $trash_dir"
        echo "Review them there, then empty the Trash to reclaim disk space."
        ;;
    delete)
        for path in "${candidates[@]}"; do
            rm -rf -- "$path"
        done
        echo "Permanently deleted ${#candidates[@]} run(s)."
        ;;
esac
