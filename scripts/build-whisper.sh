#!/bin/bash
# Builds the whisper-cli that ships inside Ata.app and prints its path.
#
# A person installing Ata should not need Homebrew, so the program is built here
# from a pinned source: statically, so it carries everything but Apple's own
# frameworks, and with the Metal shaders inside it. The result is cached by
# version, because the release script builds in a fresh worktree every time.
set -euo pipefail

VERSION="1.9.5"
SHA256="ff1a9053feb509ff9d7729703355541ae9690073a6b1c40eb692c962e0dc1720"
CACHE="${ATA_WHISPER_CACHE:-$HOME/Library/Caches/Ata-build}/whisper-$VERSION"
OUT="$CACHE/whisper-cli"

if [ -x "$OUT" ]; then
  echo "$OUT"
  exit 0
fi

command -v cmake >/dev/null || { echo "building whisper-cli needs cmake (brew install cmake)" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

{
  curl -fsSL "https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v$VERSION.tar.gz" -o "$WORK/src.tar.gz"
  echo "$SHA256  $WORK/src.tar.gz" | shasum -a 256 -c -
  tar -xzf "$WORK/src.tar.gz" -C "$WORK"

  # GGML_NATIVE stays off: a build tuned to this Mac's chip would crash on an
  # older one. armv8.4 with dotprod is what every Apple Silicon Mac has. OpenMP
  # stays off so a libomp on the build machine can't end up linked.
  cmake -S "$WORK/whisper.cpp-$VERSION" -B "$WORK/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.2 \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_NATIVE=OFF \
    -DGGML_CPU_ARM_ARCH=armv8.4-a+dotprod \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_ACCELERATE=ON \
    -DGGML_BLAS=ON \
    -DGGML_BLAS_VENDOR=Apple \
    -DGGML_OPENMP=OFF \
    -DWHISPER_BUILD_EXAMPLES=ON \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_SERVER=OFF \
    -DWHISPER_SDL2=OFF
  cmake --build "$WORK/build" --target whisper-cli --config Release -j "$(sysctl -n hw.ncpu)"
} >&2

# Anything outside Apple's own locations would be missing on someone else's Mac.
if otool -L "$WORK/build/bin/whisper-cli" | tail -n +2 | grep -vE '^\s*/(usr/lib|System/Library)/' >&2; then
  echo "whisper-cli links something that won't exist on another Mac" >&2
  exit 1
fi

mkdir -p "$CACHE"
cp "$WORK/build/bin/whisper-cli" "$OUT"
echo "$OUT"
