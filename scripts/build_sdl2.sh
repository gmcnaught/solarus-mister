#!/bin/bash
#
# Task 007: cross-build a LEAN SDL2 for MiSTer armhf.
# The debian libSDL2 DT_NEEDEDs X11/Wayland/GBM/DRM/Pulse — none present on MiSTer.
# This build keeps only: video dummy + offscreen, audio ALSA, evdev joystick.
#
# Run inside solarus-armhf-build:bullseye:
#   docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_sdl2.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

SDL_VER="${SDL_VER:-2.28.5}"
SRC="work/SDL2-${SDL_VER}"
PREFIX="$(pwd)/work/sdl2-prefix"
HOST=arm-linux-gnueabihf

mkdir -p work
if [ ! -d "$SRC" ]; then
  echo "Cloning SDL2 release-$SDL_VER..."
  git clone --depth 1 --branch "release-${SDL_VER}" https://github.com/libsdl-org/SDL.git "$SRC"
fi

cd "$SRC"
# Cross toolchain (matches cmake/arm-linux-gnueabihf.toolchain.cmake).
export CC=${HOST}-gcc CXX=${HOST}-g++
export CFLAGS="-mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard -O2"

./configure --host="$HOST" --prefix="$PREFIX" \
  --disable-shared --enable-shared \
  --enable-video-dummy --enable-video-offscreen \
  --disable-video-x11 --disable-video-wayland --disable-video-kmsdrm \
  --disable-video-vulkan --disable-video-opengl --disable-video-opengles \
  --disable-video-opengles1 --disable-video-opengles2 \
  --enable-alsa --disable-pulseaudio --disable-sndio --disable-jack \
  --enable-joystick --disable-libudev \
  --disable-dbus --disable-ibus --disable-fcitx

make -j"$(nproc)"
make install

echo ""
echo "=== built libSDL2 DT_NEEDED (must have NO x11/wayland/gbm/drm/pulse) ==="
SO=$(ls -1 "$PREFIX"/lib/libSDL2-2.0.so.0.* 2>/dev/null | head -1)
${HOST}-readelf -d "$SO" 2>/dev/null | awk -F'[][]' '/\(NEEDED\)/{print "  "$2}'
echo ""
echo "=== max GLIBC symbol version (must be <= 2.31) ==="
${HOST}-objdump -T "$SO" 2>/dev/null | grep -oE 'GLIBC_[0-9.]+' | sort -V | tail -1
echo ""
echo "Prefix: $PREFIX  (point the engine build's CMAKE_PREFIX_PATH here)"
