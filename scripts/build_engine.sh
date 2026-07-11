#!/bin/bash
#
# Phase 1: cross-build the Solarus 1.6.5 engine (solarus-run) for MiSTer armhf,
# software rendering only. Runs inside the solarus-armhf-build:bullseye image.
#
# Usage (from repo root OR any linked git worktree):
#   docker build -f Dockerfile.solarus-build -t solarus-armhf-build:bullseye .
#   scripts/docker_run.sh scripts/build_engine.sh
# (scripts/docker_run.sh wraps `docker run`, mounting the repo at /src and, from
#  a linked worktree, the shared .git so git works inside the container.)
#
set -euo pipefail
cd "$(dirname "$0")/.."

SOLARUS_REF="${SOLARUS_REF:-v1.6}"
SRC="work/solarus"
BUILD="${SOLARUS_BUILD_DIR:-build/armhf}"

# 1. Apply the downstream MiSTer modifications as a reviewable git patch series
#    (reset pristine -> git am --3way patches/series/*.patch -> cp whole-file
#    additions -> ast-grep verify). This REPLACES ~2300 lines of inline
#    python/sed/perl string-replace patching. Design + rationale:
#      docs/superpowers/specs/2026-07-06-engine-patch-series-design.md
#    The frozen pre-migration inline patcher is kept at
#      scripts/legacy/build_engine_patchphase.sh
#    as the bootstrap/manifest reference (scripts/bootstrap_patch_series.sh,
#    scripts/tests/test_manifest.sh). The forward correctness gate is the export
#    round-trip (scripts/tests/test_export_roundtrip.sh): a clean apply must
#    re-export byte-identically to the committed patches/series/.
bash scripts/apply_patch_series.sh

# Stop after the source-patch phase (text-only, no compile) when requested.
if [ "${SOLARUS_PATCH_ONLY:-0}" = "1" ]; then
  echo "[patch-series] SOLARUS_PATCH_ONLY=1 — patched tree ready in $SRC, skipping build."
  exit 0
fi


# 2. Configure. Software-only: no GUI (Qt editor), no tests, GLES off. OpenGL is
#    optional upstream; we still force software rendering at runtime
#    (-force-software-rendering). MISTER_NATIVE_VIDEO enables the DDR present-hook.
#
#    Lua backend (env SOLARUS_USE_LUAJIT, default ON; set =0 for vanilla Lua 5.1):
#      SOLARUS_USE_LUAJIT=1  -> link the armhf LuaJIT built by
#                               scripts/build_luajit.sh (build/luajit-armhf).
#                               Run that script first; we point FindLuaJIT.cmake
#                               at the prefix via LUAJIT_DIR + CMAKE_PREFIX_PATH.
# NOTE: -DCMAKE_C/CXX_FLAGS on the command line REPLACES the toolchain file's
# *_FLAGS_INIT, so the NEON/cpu flags must be repeated here or the software
# renderer compiles without SIMD/A9 scheduling (measured ~free 2x lever).
MISTER_ARCH_FLAGS="-mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard"

# --- Optional gprof instrumentation (SOLARUS_GPROF, default OFF) -------------
# SOLARUS_GPROF=1 builds solarus-run + libsolarus with gcc's -pg mcount
# instrumentation so a NORMAL-EXIT run of the engine drops a gmon.out (the
# standard gprof input). Post-process on the host with the matching cross gprof:
#   arm-linux-gnueabihf-gprof build/armhf/solarus-run gmon.out   (scripts/gprof_report.sh)
#
# Rules that this build must satisfy for usable profiles:
#   * -pg must be on BOTH the compile line (CMAKE_*_FLAGS) AND the link line of
#     BOTH the shared library and the run binary (CMAKE_SHARED/EXE_LINKER_FLAGS)
#     — nearly all engine code lives in libsolarus, so instrumenting only the
#     binary would profile almost nothing.
#   * LTO/IPO must be OFF: cross-TU inlining dissolves the function boundaries
#     gprof attributes samples to and can drop mcount calls entirely. We force
#     SOLARUS_LTO=OFF for a gprof build regardless of the caller's setting.
#   * -g keeps the symbol/line info gprof uses for its annotated call graph.
# Default OFF -> an ordinary ship build (no -pg cost, LTO honoured).
GPROF_C_FLAGS=""
GPROF_LINK_FLAGS=""
LTO_SETTING="${SOLARUS_LTO:-ON}"
if [ "${SOLARUS_GPROF:-0}" = "1" ] || [ "${SOLARUS_GPROF:-0}" = "ON" ]; then
  echo "SOLARUS_GPROF=1: building with -pg gprof instrumentation (LTO forced OFF)."
  GPROF_C_FLAGS="-pg -g"
  GPROF_LINK_FLAGS="-pg"
  LTO_SETTING="OFF"
fi

# Default ON (issue #26): LuaJIT is the shipped baseline — HW-validated full JIT on
# the Cortex-A9 (ARMv7/VFPv3), ~20-30% A9 win in gameplay. Requires build/luajit-armhf
# (run scripts/build_luajit.sh first); set SOLARUS_USE_LUAJIT=0 for vanilla Lua 5.1.
USE_LUAJIT="${SOLARUS_USE_LUAJIT:-1}"
LUA_CMAKE_ARGS=()
if [ "$USE_LUAJIT" = "1" ] || [ "$USE_LUAJIT" = "ON" ]; then
  LUAJIT_PREFIX="$(pwd)/build/luajit-armhf"
  if [ ! -f "$LUAJIT_PREFIX/lib/libluajit-5.1.so" ]; then
    echo "ERROR: SOLARUS_USE_LUAJIT set but $LUAJIT_PREFIX not built." >&2
    echo "       Run scripts/build_luajit.sh first." >&2
    exit 1
  fi
  echo "Building engine with LuaJIT from $LUAJIT_PREFIX"
  export LUAJIT_DIR="$LUAJIT_PREFIX"
  LUA_CMAKE_ARGS=(
    -DSOLARUS_USE_LUAJIT=ON
    -DLUAJIT_INCLUDE_DIR="$LUAJIT_PREFIX/include/luajit-2.1"
    -DLUAJIT_LIBRARY="$LUAJIT_PREFIX/lib/libluajit-5.1.so"
  )
else
  echo "Building engine with vanilla Lua 5.1 (set SOLARUS_USE_LUAJIT=1 for LuaJIT)"
  LUA_CMAKE_ARGS=(-DSOLARUS_USE_LUAJIT=OFF)
fi

# Assemble CMAKE_PREFIX_PATH so find_package() prefers our from-source builds
# over the stock :armhf packages in the image. ORDER MATTERS: the lean SDL2
# (scripts/build_sdl2.sh -> work/sdl2-prefix) must come first so find_package(SDL2)
# resolves it INSTEAD of the Dockerfile's stock libsdl2-dev:armhf, which drags in
# X11/Wayland/GBM/DRM/PulseAudio(->dbus) DT_NEEDEDs that MiSTer doesn't have (and
# which then silently fall out of the deploy closure -- see collect_runtime_libs.sh).
# If work/sdl2-prefix is absent the build still works but links stock SDL2; guard
# against that below so a skipped build_sdl2.sh step doesn't silently ship the
# heavyweight closure again.
PREFIX_PATHS=()
SDL2_PREFIX="$(pwd)/work/sdl2-prefix"
if [ -f "$SDL2_PREFIX/lib/cmake/SDL2/sdl2-config.cmake" ] || \
   ls "$SDL2_PREFIX"/lib/libSDL2-2.0.so.0.* >/dev/null 2>&1; then
  echo "Linking lean SDL2 from $SDL2_PREFIX"
  PREFIX_PATHS+=("$SDL2_PREFIX")
elif [ "${SOLARUS_ALLOW_STOCK_SDL2:-0}" != "1" ]; then
  echo "ERROR: lean SDL2 not found at $SDL2_PREFIX." >&2
  echo "       Run scripts/build_sdl2.sh first (README build order), or set" >&2
  echo "       SOLARUS_ALLOW_STOCK_SDL2=1 to deliberately link the stock" >&2
  echo "       :armhf SDL2 (pulls X11/Wayland/pulse/dbus into the deploy)." >&2
  exit 1
else
  echo "WARNING: linking STOCK :armhf SDL2 (SOLARUS_ALLOW_STOCK_SDL2=1) -- heavyweight closure."
fi
[ -n "${LUAJIT_PREFIX:-}" ] && PREFIX_PATHS+=("$LUAJIT_PREFIX")
# cmake wants a ';'-separated list.
CMAKE_PREFIX_LIST="$(IFS=';'; echo "${PREFIX_PATHS[*]}")"

cmake -S "$SRC" -B "$BUILD" \
  -DCMAKE_TOOLCHAIN_FILE="$(pwd)/cmake/arm-linux-gnueabihf.toolchain.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="-DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO $MISTER_ARCH_FLAGS $GPROF_C_FLAGS" \
  -DCMAKE_CXX_FLAGS="-DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO $MISTER_ARCH_FLAGS $GPROF_C_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$GPROF_LINK_FLAGS" \
  -DCMAKE_SHARED_LINKER_FLAGS="$GPROF_LINK_FLAGS" \
  -DCMAKE_PREFIX_PATH="$CMAKE_PREFIX_LIST" \
  "${LUA_CMAKE_ARGS[@]}" \
  -DSOLARUS_GUI=OFF \
  -DSOLARUS_TESTS=OFF \
  -DSOLARUS_GL_ES=OFF \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_POLICY_DEFAULT_CMP0069=NEW \
  -DCMAKE_INTERPROCEDURAL_OPTIMIZATION="$LTO_SETTING"   # (#26) LTO: cross-TU inlining of the template-heavy quadtree/shared_ptr/comparator. CMP0069=NEW forces it (Solarus' old cmake_minimum ignores IPO otherwise). Set SOLARUS_LTO=OFF to disable; SOLARUS_GPROF=1 forces it OFF (gprof needs intact function boundaries).

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
