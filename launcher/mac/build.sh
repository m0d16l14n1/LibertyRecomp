#!/bin/sh
# Builds the macOS launcher (SwiftUI, no Xcode project) as a plain executable. The app's CMake build runs this
# and puts the result into Liberty Recompiled.app as its main program, with the game beside it.
#
#   sh launcher/mac/build.sh [output] [minimum macOS]   # default out/launcher-mac/liberty-launcher, 26.0
#
# Run on its own (outside the app) it looks for the game's program in LIBERTY_DIR (default: its own folder).
set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="${1:-$root/out/launcher-mac/liberty-launcher}"
minimum="${2:-26.0}"
mkdir -p "$(dirname "$out")"
xcrun swiftc -O -swift-version 5 -target "arm64-apple-macos$minimum" -parse-as-library \
  -framework SwiftUI -framework AppKit -framework IOKit \
  -o "$out" "$here"/Sources/*.swift
echo "built $out"
