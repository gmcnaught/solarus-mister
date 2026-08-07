#!/usr/bin/env bash
# Cross-build the A9->blitter-DDR store bench for MiSTer armhf.
# Tiny libc-only binary (no SDL/Solarus deps) -> build/armhf/ddr_write_bench.
#
#   bash scripts/build_ddr_write_bench.sh
#
# Then run it on the device. It writes only into a 4 MiB scratch slice of the
# source heap (never the control block, ring, or doorbell), but that DOES
# clobber staged atlas pixels, so kill the engine first:
#   ssh root@192.168.20.81 'kill -9 $(pidof solarus-run) 2>/dev/null; true'
#   scp build/armhf/ddr_write_bench root@192.168.20.81:/tmp/
#   ssh root@192.168.20.81 /tmp/ddr_write_bench
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/armhf/ddr_write_bench"
mkdir -p build/armhf

bash scripts/docker_run.sh bash -lc '
  set -e
  arm-linux-gnueabihf-gcc -Wall -Wextra -O2 -static \
    patches/mister/ddr_write_bench/ddr_write_bench.c \
    -o '"$OUT"'
'
echo "built $OUT"
file "$OUT" || true
