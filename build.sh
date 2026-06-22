#!/usr/bin/env bash
# Build foo_out_avfoundation without Xcode.app — just CMake + Ninja + the
# Command Line Tools (`xcode-select --install`).
#
#   ./build.sh                 # Debug, ad-hoc signed, into ./build
#   ./build.sh Release         # Release build
#   BUILD_DIR=out ./build.sh   # custom build dir
#   CODESIGN_IDENTITY="Developer ID Application: ..." ./build.sh   # real signing
set -euo pipefail

CONFIG="${1:-Debug}"
BUILD_DIR="${BUILD_DIR:-build}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

# Make sure the vendored SDK submodule is present.
if [[ ! -f vendor/sdk/pfc/pfc-lite.h ]]; then
    echo "==> Fetching foobar2000 SDK submodule"
    git submodule update --init --recursive
fi

GENERATOR="Unix Makefiles"
if command -v ninja >/dev/null 2>&1; then
    GENERATOR="Ninja"
fi

echo "==> Configuring ($CONFIG, $GENERATOR)"
cmake -S . -B "$BUILD_DIR" -G "$GENERATOR" \
    -DCMAKE_BUILD_TYPE="$CONFIG" \
    -DCODESIGN_IDENTITY="$CODESIGN_IDENTITY"

echo "==> Building"
cmake --build "$BUILD_DIR" --parallel

echo "==> Done: dist/mac/foo_out_avfoundation.component"
