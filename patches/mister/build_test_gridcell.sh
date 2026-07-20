#!/usr/bin/env bash
# Stage 3b Phase B1: 32-bit tilemap grid cell bit-layout pin.
set -euo pipefail
cd "$(dirname "$0")"
cc -std=c99 -Wall -Wextra -Werror -I . -I blitter \
   test_gridcell.c -o /tmp/test_gridcell
/tmp/test_gridcell
echo "== gridcell OK =="
