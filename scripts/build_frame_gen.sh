#!/usr/bin/env bash
# Cross-build the on-device fabric frame generator for MiSTer armhf.
# Tiny libc-only binary (no SDL/Solarus deps) -> build/armhf/frame_gen.
#
#   bash scripts/build_frame_gen.sh
#
# Then deploy + run on the device (RBF must be loaded; engine must NOT be running):
#   scp build/armhf/frame_gen root@192.168.20.81:/tmp/
#   ssh root@192.168.20.81 /tmp/frame_gen --rate 120     # calibration (tears: expected)
#   ssh root@192.168.20.81 /tmp/frame_gen --paced        # the gate
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/armhf/frame_gen"
mkdir -p build/armhf

bash scripts/docker_run.sh bash -lc '
  set -e
  arm-linux-gnueabihf-gcc -Wall -Wextra -O2 -static \
    -I patches/mister -I patches/mister/frame_gen -I patches/mister/blitter \
    patches/mister/frame_gen/frame_gen.c \
    patches/mister/blitter/blt_emitter.c \
    patches/mister/blitter/blt_alloc.c \
    -o '"$OUT"'
'
echo "built $OUT"
file "$OUT" || true
