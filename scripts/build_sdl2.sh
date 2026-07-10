#!/bin/bash
#
# Task 007: cross-build a LEAN SDL2 for MiSTer armhf.
# The debian libSDL2 DT_NEEDEDs X11/Wayland/GBM/DRM/Pulse — none present on MiSTer.
# This build keeps only what Solarus actually touches: video DUMMY (SDL_VIDEODRIVER=
# dummy at runtime), the software RENDER subsystem (SDLRenderer uses
# SDL_CreateSoftwareRenderer/SDL_RenderPresent), and evdev JOYSTICK. Everything
# else is cut:
#   * ARM SIMD + NEON blit asm DISABLED (do NOT re-add --enable-arm-simd/neon).
#     HW-confirmed 2026-07-10: enabling NEON makes the on-screen HUD (hearts,
#     buttons, rupee count) VANISH. The HUD draws via the renderer's "offtarget"
#     path, which is a real SDL software alpha-blend (SDL_BLENDMODE_BLEND) onto an
#     SDL render-target texture -- that routes through NEON's BlitNtoNPixelAlpha
#     asm, which produces wrong (transparent) output here. NEON's *convert*
#     routines are fine (world atlases stage correctly), so only the software
#     alpha-composited HUD breaks -- a subtle, HUD-only regression. The shipping
#     FPGA-compositor per-frame pixels bypass SDL's blitters entirely, so the lost
#     NEON win is limited to asset-load surface conversions -- not worth the HUD.
#   * AUDIO cut entirely (--disable-audio): Solarus does 100% of audio via OpenAL
#     and never passes SDL_INIT_AUDIO (verified: System.cpp SDL_Init is
#     VIDEO|JOYSTICK only). libasound still reaches the device via libopenal.
#   * haptic/sensor/power/hidapi/virtual-joystick/offscreen all off — unused,
#     smaller/faster-loading .so.
#   * static lib not built (--disable-static; the old --disable-shared
#     --enable-shared pair was contradictory and still built an unused ~2MB .a).
#
# Run inside solarus-armhf-build:bullseye (scripts/docker_run.sh handles the
# /src mount + linked-worktree .git):
#   scripts/docker_run.sh scripts/build_sdl2.sh
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
export CFLAGS="-mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard -O3"

./configure --host="$HOST" --prefix="$PREFIX" \
  --enable-shared --disable-static \
  --enable-video-dummy --enable-video-offscreen \
  --disable-video-x11 --disable-video-wayland --disable-video-kmsdrm \
  --disable-video-vulkan --disable-video-opengl --disable-video-opengles \
  --disable-video-opengles1 --disable-video-opengles2 \
  --enable-render \
  --disable-audio \
  --enable-joystick --disable-libudev \
  --disable-haptic --disable-sensor --disable-power \
  --disable-hidapi --disable-joystick-virtual \
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
