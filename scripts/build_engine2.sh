#!/bin/bash
#
# TEST OPTION: cross-build the Solarus 2.x engine (solarus-run) for MiSTer armhf.
# This is the SECOND engine line, deliberately side-by-side with the shipping
# 1.6.5 build (scripts/build_engine.sh) — it replaces nothing. Read
# docs/solarus2.md before using it.
#
# By default this now builds the FABRIC engine: pinned upstream v2.1.0 plus the
# 2.x MiSTer series (patches/series2/) and the shared whole-file additions
# (patches/mister/), so the FPGA blitter renderer composites the frame exactly as
# it does on the 1.6 line. Set SOLARUS2_STOCK=1 for the original pristine build
# (no patch phase, no picture) when you want to measure or bisect against stock.
#
# Why the 2.x line has its OWN series: the 46 patches in patches/series/ are
# authored against pristine 1.6.5 and cannot apply to 2.x — src/main/Main.cpp
# moved to cli/src/main.cpp, MainLoop/Entities/Video/Game have drifted by hundreds
# of lines, Renderer::create_texture gained a `margin` arg and
# notify_target_changed() is new, and 2.x moved the camera scroll into a per-surface
# View. patches/series2/ re-derives the picture-critical hooks against that tree;
# the perf levers of the 1.6 series are deliberately NOT ported yet (their defaults
# were set by HW validation against 1.6.5 behaviour and do not transfer unmeasured).
#
# What IS shared verbatim: everything in patches/mister/ — the blitter renderer,
# the command emitter, the pixel converter, the DDR video/audio writers. They are
# engine-version-agnostic apart from one `SOLARUS_MAJOR_VERSION >= 2` switch in
# mister_blitter_renderer.cpp for the destination-surface View offset.
#
# Usage (from repo root OR any linked git worktree):
#   docker build -f Dockerfile.solarus-build -t solarus-armhf-build:bullseye .
#   scripts/docker_run.sh scripts/build_sdl2.sh       # REQUIRED, see SDL2 note below
#   scripts/docker_run.sh scripts/build_luajit.sh     # unless SOLARUS2_USE_LUAJIT=0
#   scripts/docker_run.sh scripts/build_engine2.sh
#
# Env knobs:
#   SOLARUS2_REF / SOLARUS2_SHA   upstream pin (scripts/lib/patch_common.sh)
#   SOLARUS2_SRC_DIR              source checkout   (default work/solarus2)
#   SOLARUS2_BUILD_DIR            build dir         (default build/armhf-v2)
#   SOLARUS2_USE_LUAJIT           1 (default) / 0 for vanilla Lua 5.1
#   SOLARUS2_STOCK=1              build pristine upstream (no patch phase, no picture)
#   SOLARUS2_SKIP_APPLY=1         build the already-staged tree in $SRC as-is
#   SOLARUS2_PATCH_ONLY=1         stop after the patch phase (no compile)
#
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/patch_common.sh

SRC="${SOLARUS2_SRC_DIR:-work/solarus2}"
BUILD="${SOLARUS2_BUILD_DIR:-build/armhf-v2}"

# 1. Stage the source. work/solarus (the 1.6 tree) is never touched — the two
#    lines coexist so you can rebuild either without re-cloning, and so a 2.x
#    experiment can never corrupt the tree the shipping engine is built from.
STOCK="${SOLARUS2_STOCK:-0}"
if [ "${SOLARUS2_SKIP_APPLY:-0}" = "1" ]; then
  echo "[solarus2] SOLARUS2_SKIP_APPLY=1 — using the tree already staged in $SRC."
elif [ "$STOCK" = "1" ] || [ "$STOCK" = "ON" ]; then
  echo "[solarus2] SOLARUS2_STOCK=1 — pristine upstream, NO patch phase."
  echo "[solarus2] *** This build renders NOTHING on the device (docs/solarus2.md). ***"
  if [ ! -d "$SRC/.git" ]; then
    echo "[solarus2] cloning Solarus $SOLARUS2_REF (pinned to $SOLARUS2_SHA) into $SRC..."
    pcs_clone_pinned_at "$SRC" "$SOLARUS2_REF" "$SOLARUS2_SHA" --depth 1
  else
    pcs_git_identity "$(pwd)/$SRC"
    pcs_reset_clone_at "$SRC" "$SOLARUS2_REF" "$SOLARUS2_SHA"
  fi
  # Guard what a stock build exists to guarantee. If someone hand-edits the
  # checkout, say so rather than silently shipping an unrecorded mod as "stock".
  if [ -n "$(git -C "$SRC" status --porcelain 2>/dev/null)" ]; then
    echo "WARNING: $SRC has local modifications — this is NOT a stock upstream build." >&2
    git -C "$SRC" status --short >&2 || true
  fi
else
  bash scripts/apply_patch_series2.sh
fi

if [ "${SOLARUS2_PATCH_ONLY:-0}" = "1" ]; then
  echo "[solarus2] SOLARUS2_PATCH_ONLY=1 — patched tree ready in $SRC, skipping build."
  exit 0
fi

echo "[solarus2] building $(git -C "$SRC" describe --tags --always 2>/dev/null || echo unknown)"

# 2. Configure. Same MiSTer target shape as the 1.6 build (Cortex-A9 + NEON,
#    software rendering, no GUI/tests), but with the 2.x option names.
#
#    NOTE: -DCMAKE_C/CXX_FLAGS on the command line REPLACES the toolchain file's
#    *_FLAGS_INIT, so the NEON/cpu flags must be repeated here — same trap as
#    build_engine.sh. 2.x appends its own -O3 via CMAKE_CXX_FLAGS_RELEASE, which
#    is a SEPARATE variable, so it survives.
#
#    MISTER_NATIVE_VIDEO / MISTER_NATIVE_AUDIO gate the DDR video/audio hooks and
#    the blitter renderer, exactly as in build_engine.sh — but only on the patched
#    build. A stock tree has no code behind those defines, so defining them there
#    would be a lie (and the header they include does not exist in that tree).
MISTER_ARCH_FLAGS="-mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard"
MISTER_DEFINES=""
if [ "$STOCK" != "1" ] && [ "$STOCK" != "ON" ]; then
  MISTER_DEFINES="-DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO"
fi

USE_LUAJIT="${SOLARUS2_USE_LUAJIT:-1}"
LUA_CMAKE_ARGS=()
LUAJIT_PREFIX=""
if [ "$USE_LUAJIT" = "1" ] || [ "$USE_LUAJIT" = "ON" ]; then
  LUAJIT_PREFIX="$(pwd)/build/luajit-armhf"
  if [ ! -f "$LUAJIT_PREFIX/lib/libluajit-5.1.so" ]; then
    echo "ERROR: SOLARUS2_USE_LUAJIT set but $LUAJIT_PREFIX not built." >&2
    echo "       Run scripts/build_luajit.sh first." >&2
    exit 1
  fi
  echo "[solarus2] LuaJIT from $LUAJIT_PREFIX"
  export LUAJIT_DIR="$LUAJIT_PREFIX"
  LUA_CMAKE_ARGS=(
    -DSOLARUS_USE_LUAJIT=ON
    -DLUAJIT_INCLUDE_DIR="$LUAJIT_PREFIX/include/luajit-2.1"
    -DLUAJIT_LIBRARY="$LUAJIT_PREFIX/lib/libluajit-5.1.so"
  )
else
  echo "[solarus2] vanilla Lua 5.1"
  LUA_CMAKE_ARGS=(-DSOLARUS_USE_LUAJIT=OFF)
fi

# The lean SDL2 (scripts/build_sdl2.sh) is MANDATORY here, and for a second
# reason on top of the 1.6 one (stock :armhf SDL2 drags in X11/Wayland/GBM/DRM/
# pulse DT_NEEDEDs the device does not have): Solarus 2.x requires SDL2 >= 2.0.18
# and bullseye's :armhf SDL2 is 2.0.14. Without our 2.28.5 prefix on
# CMAKE_PREFIX_PATH the configure step fails outright — which is the good
# failure, but a confusing one if you don't know why. So check it here and say so.
PREFIX_PATHS=()
SDL2_PREFIX="$(pwd)/work/sdl2-prefix"
if [ -f "$SDL2_PREFIX/lib/cmake/SDL2/sdl2-config.cmake" ] || \
   ls "$SDL2_PREFIX"/lib/libSDL2-2.0.so.0.* >/dev/null 2>&1; then
  echo "[solarus2] lean SDL2 from $SDL2_PREFIX"
  PREFIX_PATHS+=("$SDL2_PREFIX")
else
  echo "ERROR: lean SDL2 not found at $SDL2_PREFIX." >&2
  echo "       Run scripts/build_sdl2.sh first. Solarus 2.x needs SDL2 >= 2.0.18;" >&2
  echo "       the stock bullseye :armhf SDL2 is 2.0.14, so there is no usable" >&2
  echo "       fallback here (unlike the 1.6 build, which has no version floor)." >&2
  exit 1
fi
[ -n "$LUAJIT_PREFIX" ] && PREFIX_PATHS+=("$LUAJIT_PREFIX")
CMAKE_PREFIX_LIST="$(IFS=';'; echo "${PREFIX_PATHS[*]}")"

# 2.x option names differ from 1.6: SOLARUS_GUI is gone (the Qt editor lives in
# its own repo now), SOLARUS_CLI gates the solarus-run binary we actually want,
# and SOLARUS_TESTS defaults ON (it pulls in the test quests — off).
cmake -S "$SRC" -B "$BUILD" \
  -DCMAKE_TOOLCHAIN_FILE="$(pwd)/cmake/arm-linux-gnueabihf.toolchain.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="$MISTER_DEFINES $MISTER_ARCH_FLAGS" \
  -DCMAKE_CXX_FLAGS="$MISTER_DEFINES $MISTER_ARCH_FLAGS" \
  -DCMAKE_PREFIX_PATH="$CMAKE_PREFIX_LIST" \
  "${LUA_CMAKE_ARGS[@]}" \
  -DBUILD_SHARED_LIBS=ON \
  -DSOLARUS_CLI=ON \
  -DSOLARUS_TESTS=OFF \
  -DSOLARUS_GL_ES=OFF \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_POLICY_DEFAULT_CMP0069=NEW \
  -DCMAKE_INTERPROCEDURAL_OPTIMIZATION="${SOLARUS2_LTO:-ON}"

# 3. Build the engine + run binary.
cmake --build "$BUILD" -j"$(nproc)"

# 3b. Normalise where the run binary lives. 2.x builds it into $BUILD/cli/ (the
#     CLI moved to its own cmake subdirectory), where the 1.6 build put it at
#     $BUILD/solarus-run — and every downstream consumer here assumes the 1.6
#     layout: collect_runtime_libs.sh seeds its DT_NEEDED walk from
#     $SEED_DIR/solarus-run, deploy_engine2.sh scps $BUILD/solarus-run, and the CI
#     verify step stats it. Before this, all three silently degraded (the DT_NEEDED
#     loop below skipped a missing file, the closure walk seeded from libsolarus
#     alone) until CI's `ls` failed on it. Copy it up to the expected path and FAIL
#     if there is nothing to copy, rather than continuing with no run binary.
RUNBIN="$(find "$BUILD" -maxdepth 2 -type f -name 'solarus-run' -print -quit 2>/dev/null || true)"
if [ -z "$RUNBIN" ]; then
  echo "ERROR: no solarus-run produced under $BUILD (is -DSOLARUS_CLI=ON still set?)." >&2
  exit 1
fi
if [ "$RUNBIN" != "$BUILD/solarus-run" ]; then
  cp -f "$RUNBIN" "$BUILD/solarus-run"
  echo "[solarus2] staged $RUNBIN -> $BUILD/solarus-run"
fi

# 4. Report, and assert the one property that decides whether this can run on
#    MiSTer at all: no libGL/libGLEW/libEGL DT_NEEDED. 2.x ALWAYS compiles the GL
#    renderer (glrenderer/*.cpp are unconditional in SolarusLibrarySources.cmake,
#    unlike 1.6 where an absent OpenGL compiled them out), but it reaches GL
#    through the vendored `glad` loader, which resolves entry points at RUNTIME
#    via SDL_GL_GetProcAddress. find_package(OpenGL) is not REQUIRED, so with no
#    libgl-dev in the image nothing links OpenGL::GL and the binary has no GL
#    DT_NEEDED — GlRenderer is simply never constructed under
#    -force-software-rendering. If that ever stops being true this check catches it.
echo ""
echo "[solarus2] artifacts under $BUILD/ :"
find "$BUILD" -maxdepth 2 \( -name 'solarus-run' -o -name 'libsolarus.so*' \) 2>/dev/null || true

# shellcheck disable=SC2012  # fixed, simple name pattern (libsolarus.so.2.<x>.<y>); ls-glob + head is the repo idiom
LIB=$(ls "$BUILD"/libsolarus.so.2.* 2>/dev/null | head -1 || true)
[ -n "$LIB" ] || { echo "ERROR: no libsolarus.so.2.* under $BUILD." >&2; exit 1; }
CHECK=("$BUILD/solarus-run" "$LIB")
for f in "${CHECK[@]}"; do
  [ -f "$f" ] || { echo "ERROR: expected artifact $f is missing." >&2; exit 1; }
  # The trailing \. matters: `-i` plus a bare ^libGL would also match
  # libglib-2.0.so.0, which is a perfectly legitimate closure member.
  if arm-linux-gnueabihf-readelf -d "$f" 2>/dev/null \
       | awk -F'[][]' '/\(NEEDED\)/{print $2}' | grep -qiE '^lib(GL|GLEW|EGL)\.'; then
    echo "ERROR: $f has an OpenGL DT_NEEDED — MiSTer has no libGL." >&2
    arm-linux-gnueabihf-readelf -d "$f" | grep -i NEEDED >&2
    exit 1
  fi
done
echo "[solarus2] OK: no libGL/libGLEW/libEGL DT_NEEDED"
echo ""
echo "Next: scripts/collect_runtime_libs.sh (SOLARUS_BUILD_DIR=$BUILD"
echo "      SOLARUS_DEPLOY_LIBS=deploy/v2/libs), then scripts/deploy_engine2.sh."
if [ "$STOCK" = "1" ] || [ "$STOCK" = "ON" ]; then
  echo "Reminder: SOLARUS2_STOCK=1 renders NOTHING on the device — see docs/solarus2.md."
else
  echo "Built the 2.x FABRIC engine (patches/series2 + patches/mister)."
  echo "Pair it with the matching RBF, exactly as the 1.6 line does — see CLAUDE.md."
fi
