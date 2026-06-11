#!/bin/bash
#
# Phase 1: cross-build the Solarus 1.6.5 engine (solarus-run) for MiSTer armhf,
# software rendering only. Runs inside the solarus-armhf-build:bullseye image.
#
# Usage (from repo root):
#   docker build -f Dockerfile.solarus-build -t solarus-armhf-build:bullseye .
#   docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_engine.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

SOLARUS_REF="${SOLARUS_REF:-v1.6}"
SRC="work/solarus"
BUILD="build/armhf"

# 1. Source checkout (engine only; quests are separate).
if [ ! -d "$SRC/.git" ]; then
  echo "Cloning Solarus $SOLARUS_REF..."
  git clone --depth 1 --branch "$SOLARUS_REF" https://gitlab.com/solarus-games/solarus.git "$SRC"
fi

# 1b. Apply the MiSTer DDR video patch (task 003) into the source tree.
#     Idempotent: safe to re-run on an existing checkout.
echo "Applying MiSTer native-video patch..."
MDST="$SRC/src/graphics/sdlrenderer"
cp patches/mister/native_video_writer.c   "$MDST/"
cp patches/mister/native_video_writer.h   "$MDST/"
cp patches/mister/mister_native_video.cpp "$MDST/"
cp patches/mister/mister_native_video.h   "$MDST/"

# NOTE: use `sed > /tmp && cp` rather than `sed -i`. On Docker Desktop bind
# mounts, `sed -i` cannot create its temp file in the mounted dir ("Permission
# denied"); `cp` writes directly and works.
edit_inplace() { # edit_inplace <file> <sed-expr>
  local f="$1" expr="$2" tmp; tmp="$(mktemp /tmp/sb.XXXXXX)"
  sed "$expr" "$f" > "$tmp" && cp "$tmp" "$f"; rm -f "$tmp"
}

# Register the two new TUs with the engine library source list (once).
SRCLIST="$SRC/cmake/SolarusLibrarySources.cmake"
if ! grep -q "mister_native_video.cpp" "$SRCLIST"; then
  edit_inplace "$SRCLIST" 's#\("\${CMAKE_CURRENT_SOURCE_DIR}/src/graphics/sdlrenderer/SDLRenderer.cpp"\)#\1\n    "${CMAKE_CURRENT_SOURCE_DIR}/src/graphics/sdlrenderer/mister_native_video.cpp"\n    "${CMAKE_CURRENT_SOURCE_DIR}/src/graphics/sdlrenderer/native_video_writer.c"#'
fi

# Inject the present() hook + include into SDLRenderer.cpp (once).
SDLR="$MDST/SDLRenderer.cpp"
if ! grep -q "mister_native_video.h" "$SDLR"; then
  edit_inplace "$SDLR" 's|#include <SDL_hints.h>|#include <SDL_hints.h>\n#include "mister_native_video.h"|'
  edit_inplace "$SDLR" 's|^  SDL_RenderPresent(renderer);|  mister_present_frame(renderer);\n  SDL_RenderPresent(renderer);|'
fi

# 2. Configure. Software-only: no GUI (Qt editor), no tests, vanilla Lua 5.1
#    (LuaJIT armhf is a separate effort), GLES off. OpenGL is optional upstream;
#    we still force software rendering at runtime (-force-software-rendering).
#    MISTER_NATIVE_VIDEO enables the DDR present-hook.
cmake -S "$SRC" -B "$BUILD" \
  -DCMAKE_TOOLCHAIN_FILE="$(pwd)/cmake/arm-linux-gnueabihf.toolchain.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS=-DMISTER_NATIVE_VIDEO \
  -DCMAKE_CXX_FLAGS=-DMISTER_NATIVE_VIDEO \
  -DSOLARUS_USE_LUAJIT=OFF \
  -DSOLARUS_GUI=OFF \
  -DSOLARUS_TESTS=OFF \
  -DSOLARUS_GL_ES=OFF

# 3. Build the engine + run binary.
cmake --build "$BUILD" -j"$(nproc)"

echo ""
echo "Build done. Artifacts under $BUILD/ :"
find "$BUILD" -maxdepth 2 -name 'solarus*' -type f -perm -u+x 2>/dev/null || true
echo ""
echo "Open items to confirm after first build:"
echo "  - Does the binary link libGL/libGLEW? (ldd). If so, ship Mesa libGL armhf"
echo "    from the gmloader work, or patch out GlRenderer. GL is unused at runtime"
echo "    with -force-software-rendering but may be a load-time DT_NEEDED."
echo "  - DDR video hook (patches/) not yet applied — see CLAUDE.md Phase 3."
