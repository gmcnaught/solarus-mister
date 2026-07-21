#!/usr/bin/env bash
# Stage 3b Phase B3: grid-walk equivalence + full-cull/16-run/edge-clip gate.
# Proves blt_grid_build -> blt_ref_tilemap is pixel-identical to a per-tile
# reference blit across the three walker behaviours B1 left unpinned end-to-end.
set -euo pipefail
cd "$(dirname "$0")"
cc -std=c99 -Wall -Wextra -Werror -I . -I blitter \
   blitter/test_grid_walk_equiv.c blitter/blitter_ref.c -o /tmp/test_grid_walk_equiv
/tmp/test_grid_walk_equiv
echo "== grid_walk_equiv OK =="
