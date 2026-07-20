#!/usr/bin/env bash
# Run every host-buildable engine C++ unit test (issue #89). These need only a
# host toolchain (+ system SDL2 for the pixconv oracle); no armhf cross-build and
# no MiSTer device. Intended as the single entry point for a Linux CI job:
#   - build_test_pixconv.sh   : mpix RGB565/ARGB4444 bit-exactness vs SDL
#   - build_test_drawcache.sh  : DRAWCACHE cache-invalidation differential (#89)
#   - build_test_fatfilter.sh  : fat-AABB Lua-query precise re-filter (#105)
#   - build_test_alloc_leak.sh : blt_alloc free-list saturation accounting (#109)
#   - build_test_target_lock.sh : root-target lock, engine tag vs first-wins
#   - build_test_overlay_emit.sh : Stage 1 overlay composite (last, full-screen, PALPHA)
#   - build_test_spritelist.sh : Stage 2 OP_SPRITELIST ref-model FB equivalence
#   - build_test_scrollalias.sh : Stage 3a scroll-transition offsets + routing
#   - build_test_gridcell.sh    : Stage 3b Phase B1 grid cell bit-layout pin
set -euo pipefail
cd "$(dirname "$0")"
bash build_test_drawcache.sh
bash build_test_fatfilter.sh
bash build_test_alloc_leak.sh
bash build_test_target_lock.sh
bash build_test_overlay_emit.sh
bash build_test_pixconv.sh
bash build_test_spritelist.sh
bash build_test_scrollalias.sh
bash build_test_gridcell.sh
echo "== all host tests passed =="
