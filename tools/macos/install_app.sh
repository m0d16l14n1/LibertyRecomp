#!/bin/bash

# Install the verified local macOS build into /Applications. The build tree is
# intentionally separate from the installed app, so rebuilding alone does not
# update what Finder, Spotlight, or the launcher icon opens.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$script_dir/../.." && pwd)"
source_app="$repo/out/build/macos-release/LibertyRecomp/Liberty Recompiled.app"
dest_app="/Applications/Liberty Recompiled.app"
mode="install"

usage() {
  cat <<'EOF'
Usage: tools/macos/install_app.sh [--check] [--source APP]

Without options, verifies the release bundle and atomically installs it at:
  /Applications/Liberty Recompiled.app

The previous installed bundle is moved to a timestamped folder in the macOS
Trash for rollback. Game files, saves, settings, and shader caches live in
Application Support and are not changed.

Options:
  --check       Verify whether /Applications already matches the local build
  --source APP  Install or compare another Liberty Recompiled.app bundle
  -h, --help    Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      mode="check"
      shift
      ;;
    --source)
      [[ $# -ge 2 ]] || { echo "error: --source needs an app path" >&2; exit 2; }
      source_app="$2"
      shift 2
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

[[ -d "$source_app" && "$(basename "$source_app")" == "Liberty Recompiled.app" ]] || {
  echo "error: build bundle not found: $source_app" >&2
  exit 2
}

verify() {
  python3 "$repo/tools/verify_macos_bundle.py" "$1" --arch arm64
}

same_payload() {
  local left="$1" right="$2" relative
  local files=(
    "Contents/MacOS/Liberty Launcher"
    "Contents/MacOS/Liberty Recompiled"
    "Contents/MacOS/librexgpu-gta4-metal.dylib"
    "Contents/MacOS/librexruntime.dylib"
    "Contents/Resources/metal/override_temporal_shader_archive.bin"
    "Contents/Resources/metal/stock_temporal_shader_archive.bin"
  )
  for relative in "${files[@]}"; do
    [[ -f "$left/$relative" && -f "$right/$relative" ]] || return 1
    cmp -s "$left/$relative" "$right/$relative" || return 1
  done
}

verify "$source_app"

if [[ "$mode" == "check" ]]; then
  if [[ ! -d "$dest_app" ]]; then
    echo "Not installed: $dest_app"
    exit 1
  fi
  verify "$dest_app"
  if same_payload "$source_app" "$dest_app"; then
    echo "Installed app matches the local build."
    exit 0
  fi
  echo "Installed app is stale: run tools/macos/install_app.sh" >&2
  exit 1
fi

if pgrep -x "Liberty Recompiled" >/dev/null || pgrep -x "Liberty Launcher" >/dev/null; then
  echo "error: quit Liberty Recompiled and its launcher before installing" >&2
  exit 2
fi

stage_root="$(mktemp -d '/Applications/.LibertyRecomp-install.XXXXXX')"
stage_app="$stage_root/Liberty Recompiled.app"
ditto "$source_app" "$stage_app"
verify "$stage_app"

backup_app=""
if [[ -e "$dest_app" ]]; then
  backup_app="${HOME}/.Trash/Liberty Recompiled-stale-$(date +%Y%m%d-%H%M%S).app"
  [[ ! -e "$backup_app" ]] || {
    echo "error: rollback path already exists: $backup_app" >&2
    exit 2
  }
  mv "$dest_app" "$backup_app"
fi

if ! mv "$stage_app" "$dest_app"; then
  [[ -z "$backup_app" ]] || mv "$backup_app" "$dest_app"
  echo "error: install failed; previous app restored" >&2
  exit 1
fi
rmdir "$stage_root"

if ! verify "$dest_app" || ! same_payload "$source_app" "$dest_app"; then
  echo "error: installed bundle did not verify" >&2
  exit 1
fi

echo "Installed: $dest_app"
if [[ -n "$backup_app" ]]; then
  echo "Previous app moved to: $backup_app"
  echo "After testing, empty the Trash to reclaim its disk space."
fi
