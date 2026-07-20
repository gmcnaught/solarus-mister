#!/usr/bin/env bash
# Stage 3b Phase B1 Task 5: BLT_OP_TILEMAP framebuffer equivalence vs the per-tile path.
set -euo pipefail
cd "$(dirname "$0")"
cc -std=c99 -Wall -Wextra -Werror -I blitter \
   blitter/blitter_ref.c blitter/blt_emitter.c blitter/blt_alloc.c \
   test_tilemap.c -o /tmp/test_tilemap
/tmp/test_tilemap
echo "== tilemap OK =="
