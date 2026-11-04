#!/bin/sh
# Builds the Vulkan loader the app bundles (Contents/Resources/vulkan/lib) for the app's minimum macOS.
#
#   sh tools/macos/build_vulkan_runtime.sh [minimum macOS]   # default 26.0, output out/vulkan-runtime
#
# Homebrew's vulkan-loader and spirv-tools bottles follow the host macOS (1.4.363 is built for 27.0), and
# tools/verify_macos_bundle.py refuses a bundle with a library newer than LSMinimumSystemVersion. The SDK's
# CMake (rexglue_find_macos_vulkan_runtime) prefers out/vulkan-runtime over Homebrew when it exists.
# MoltenVK itself is built in-tree (thirdparty/MoltenVK) and replaces any copy from the runtime root.
# Rerun cmake --preset macos-release after building this the first time.
set -e
root="$(cd "$(dirname "$0")/../.." && pwd)"
minimum="${1:-26.0}"
headers_src="$root/glue/rexglue-sdk-main/thirdparty/vulkan-headers"
version="$(git -C "$headers_src" describe --tags --abbrev=0)"   # the loader tag matching the headers
work="$root/out/vulkan-runtime-build"
prefix="$root/out/vulkan-runtime"
mkdir -p "$work"

cmake -S "$headers_src" -B "$work/headers" -G Ninja -DCMAKE_INSTALL_PREFIX="$work/headers-install" >/dev/null
cmake --install "$work/headers" >/dev/null

if [ ! -d "$work/Vulkan-Loader" ]; then
  git clone --quiet --depth 1 --branch "$version" https://github.com/KhronosGroup/Vulkan-Loader.git \
    "$work/Vulkan-Loader"
fi
# Apple clang: the loader is C, and nothing here may pull in Homebrew LLVM's libc++.
cmake -S "$work/Vulkan-Loader" -B "$work/loader" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$(xcrun --find clang)" -DCMAKE_CXX_COMPILER="$(xcrun --find clang++)" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$minimum" \
  -DVULKAN_HEADERS_INSTALL_DIR="$work/headers-install" -DCMAKE_PREFIX_PATH="$work/headers-install" \
  -DBUILD_TESTS=OFF -DCMAKE_INSTALL_PREFIX="$prefix" >/dev/null
cmake --build "$work/loader"
rm -rf "$prefix"
cmake --install "$work/loader" >/dev/null
vtool -show-build "$prefix/lib/libvulkan.1.dylib" | grep -q "minos $minimum" ||
  { echo "libvulkan.1.dylib is not built for macOS $minimum" >&2; exit 1; }
echo "built Vulkan loader $version for macOS $minimum in $prefix"
