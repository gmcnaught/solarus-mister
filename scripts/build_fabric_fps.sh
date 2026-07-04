#!/usr/bin/env bash
# Cross-build the on-device FABRIC-ALONE fps probe for MiSTer armhf.
# Tiny libc-only binary (no SDL/Solarus deps) -> build/armhf/fabric_fps. It loads a
# tileset once and hits the fabric directly with a full-screen resident tile list,
# reading the fabric's own per-frame busy-cycle counter (C_DONE[63:32]) to report
# the compositor's fps ceiling, isolated from the engine. See the .c header.
#
#   bash scripts/build_fabric_fps.sh
#
# Then deploy + run on the device (RBF must be loaded; engine NOT required — kill
# any running solarus-run first so the ring isn't contended):
#   scp build/armhf/fabric_fps root@192.168.20.81:/tmp/
#   ssh root@192.168.20.81 'kill -9 $(pidof solarus-run) 2>/dev/null; /tmp/fabric_fps'
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="solarus-armhf-build:bullseye"
OUT="build/armhf/fabric_fps"
mkdir -p build/armhf

docker run --rm -v "$(pwd):/src" -w /src "$IMAGE" bash -lc '
  set -e
  arm-linux-gnueabihf-gcc -Wall -Wextra -O2 -static \
    -I patches/mister/fabric_fps -I patches/mister/blitter \
    patches/mister/fabric_fps/fabric_fps.c \
    patches/mister/blitter/blt_emitter.c \
    patches/mister/blitter/blt_alloc.c \
    -o '"$OUT"'
'
echo "built $OUT"
file "$OUT" || true
