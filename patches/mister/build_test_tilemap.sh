#!/usr/bin/env bash
# Stage 3b Phase B1 Task 5: BLT_OP_TILEMAP framebuffer equivalence vs the per-tile path.
# Stage 3b Phase B1 Task 6: also builds with -DBLT_REF_COUNT_ISSUES, so this binary
# additionally prints Path A (per-tile) vs Path B (grid) blit-issue counts per scenario
# and enforces the loose Path B <= 4x Path A sanity bound. This flag is BLT_REF_COUNT_ISSUES
# ONLY here -- every other build_test_*.sh compiles blitter_ref.c without it, so the
# shipping reference model stays byte-for-byte unchanged.
set -euo pipefail
cd "$(dirname "$0")"
cc -std=c99 -Wall -Wextra -Werror -DBLT_REF_COUNT_ISSUES -I blitter \
   blitter/blitter_ref.c blitter/blt_emitter.c blitter/blt_alloc.c \
   test_tilemap.c -o /tmp/test_tilemap
/tmp/test_tilemap
echo "== tilemap OK =="
