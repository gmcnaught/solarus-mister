#!/usr/bin/env bash
# Cross-build the on-device SDRAM round-trip self-test (issue #34) for MiSTer armhf.
# Tiny libc-only binary (no SDL/Solarus deps) -> build/armhf/sdram_selftest.
#
#   bash scripts/build_sdram_selftest.sh
#
# Then deploy + run on the device (RBF must be loaded; engine NOT required):
#   scp build/armhf/sdram_selftest root@192.168.20.81:/tmp/
#   ssh root@192.168.20.81 /tmp/sdram_selftest
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/armhf/sdram_selftest"
mkdir -p build/armhf

# scripts/docker_run.sh mounts the repo root at /src (and, from a linked git
# worktree, also bind-mounts the shared .git so git works inside the container).
bash scripts/docker_run.sh bash -lc '
  set -e
  arm-linux-gnueabihf-gcc -Wall -Wextra -O2 -static \
    -I patches/mister/sdram_selftest -I patches/mister/blitter \
    patches/mister/sdram_selftest/sdram_selftest.c \
    patches/mister/blitter/blt_emitter.c \
    patches/mister/blitter/blt_alloc.c \
    -o '"$OUT"'
'
echo "built $OUT"
file "$OUT" || true
