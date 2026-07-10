#!/bin/bash
#
# Cross-build LuaJIT 2.1 for MiSTer armhf (arm-linux-gnueabihf), runs inside the
# solarus-armhf-build:bullseye image. Produces libluajit-5.1.so (+ headers) for
# armhf, installed into an in-tree prefix that Solarus's FindLuaJIT.cmake finds
# via LUAJIT_DIR / CMAKE_PREFIX_PATH.
#
# Usage (from repo root):
#   # one-time on the host: register the armhf qemu binfmt handler so the build
#   # container can transparently run the 32-bit ARM host tools (minilua/buildvm):
#   docker run --rm --privileged tonistiigi/binfmt --install arm
#   # then build (scripts/docker_run.sh handles the /src mount + worktree .git):
#   scripts/docker_run.sh scripts/build_luajit.sh
#
# Cross-compile mechanics (arm64 host -> armhf target):
#   LuaJIT builds host tools (minilua, buildvm) with HOST_CC, then the actual VM
#   with CROSS=<triple>-. buildvm REFUSES to run if the host pointer size differs
#   from the target ("pointer size mismatch in cross-build"). On an x86_64 host
#   you pass HOST_CC="gcc -m32" to get 32-bit host tools. Our build host is arm64
#   and gcc has no -m32, so instead we build the host tools AS 32-bit ARM with the
#   cross compiler (HOST_CC=arm-linux-gnueabihf-gcc) and run them under qemu via
#   the registered binfmt handler. Host tool pointer size (32) then matches the
#   armhf target (32) and buildvm is happy. The host tools are slow under qemu but
#   only run a handful of times during the build.
#
set -euo pipefail
cd "$(dirname "$0")/.."

LUAJIT_REF="${LUAJIT_REF:-v2.1}"        # LuaJIT stable 2.1 branch
SRC="work/LuaJIT"
PREFIX="$(pwd)/build/luajit-armhf"      # in-tree install prefix
TRIPLE="arm-linux-gnueabihf"

# MiSTer DE10-Nano: Cortex-A9, NEON, hard-float -- same flags as the engine.
ARCH_FLAGS="-mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard"

# qemu-user-static provides the armhf interpreter the binfmt handler points at.
if ! command -v qemu-arm-static >/dev/null 2>&1; then
  echo "Installing qemu-user-static (for running the 32-bit ARM host tools)..."
  apt-get update -qq >/dev/null
  apt-get install -y -qq --no-install-recommends qemu-user-static >/dev/null
fi

# Sanity: can we transparently exec an armhf binary? (Needs the host-side
# `docker run --rm --privileged tonistiigi/binfmt --install arm` to have run.)
echo 'int main(){return 0;}' | "${TRIPLE}-gcc" -x c - -o /tmp/_armcheck
if ! /tmp/_armcheck 2>/dev/null; then
  echo "ERROR: cannot transparently execute armhf binaries in this container." >&2
  echo "Run on the host first:  docker run --rm --privileged tonistiigi/binfmt --install arm" >&2
  exit 1
fi
rm -f /tmp/_armcheck

# 1. Source checkout.
if [ ! -d "$SRC/.git" ]; then
  echo "Cloning LuaJIT $LUAJIT_REF..."
  git clone --branch "$LUAJIT_REF" https://github.com/LuaJIT/LuaJIT.git "$SRC"
fi

# 2. Clean any stale objects from a previous (possibly host-arch) build.
make -C "$SRC" clean >/dev/null 2>&1 || true
rm -rf "$PREFIX"
mkdir -p "$PREFIX"

# 3. Cross-build.
#    HOST_CC : 32-bit ARM host tools (run under qemu binfmt) so buildvm's pointer
#              size matches the armhf target.
#    CROSS   : arm-linux-gnueabihf- prefix -> TARGET_CC = <CROSS>gcc.
#    TARGET_CFLAGS carries the A9/NEON/hard-float flags into the VM objects.
#    BUILDMODE=dynamic so we get the shared .so (we ship the .so, not the .a).
MAKE_ARGS=(
  CROSS="${TRIPLE}-"
  HOST_CC="${TRIPLE}-gcc -static"
  TARGET_SYS=Linux
  BUILDMODE=dynamic
)
make -C "$SRC" -j"$(nproc)" "${MAKE_ARGS[@]}" TARGET_CFLAGS="$ARCH_FLAGS" amalg

# 4. Install into the in-tree prefix (headers under include/luajit-2.1, lib +
#    pkgconfig under lib/).
make -C "$SRC" "${MAKE_ARGS[@]}" PREFIX="$PREFIX" install

echo ""
echo "=== LuaJIT armhf install ($PREFIX) ==="
find "$PREFIX" -maxdepth 3 \( -name 'libluajit*' -o -name 'luajit.h' -o -name '*.pc' \) -print

# 5. Verify the produced .so is ARM EABI5 and GLIBC <= 2.31.
SO="$(ls -1 "$PREFIX"/lib/libluajit-5.1.so.*.* 2>/dev/null | head -1 || true)"
[ -z "$SO" ] && SO="$(ls -1 "$PREFIX"/lib/libluajit-5.1.so* 2>/dev/null | head -1 || true)"
echo ""
echo "=== readelf -h (expect ARM, EABI5) ==="
"${TRIPLE}-readelf" -h "$SO" | grep -E 'Machine|Flags|Class|ABI'
echo ""
echo "=== DT_SONAME / NEEDED ==="
"${TRIPLE}-readelf" -d "$SO" | grep -E 'SONAME|NEEDED'
echo ""
echo "=== max GLIBC symbol version (must be <= 2.31) ==="
"${TRIPLE}-objdump" -T "$SO" 2>/dev/null \
  | grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' | sort -V | tail -1
