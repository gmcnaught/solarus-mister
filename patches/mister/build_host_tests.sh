#!/usr/bin/env bash
# Run every host-buildable engine C++ unit test (issue #89). These need only a
# host toolchain (+ system SDL2 for the pixconv oracle); no armhf cross-build and
# no MiSTer device. Intended as the single entry point for a Linux CI job:
#   - build_test_pixconv.sh   : mpix RGB565/ARGB4444 bit-exactness vs SDL
#   - build_test_drawcache.sh : DRAWCACHE cache-invalidation differential (#89)
set -euo pipefail
cd "$(dirname "$0")"
bash build_test_drawcache.sh
bash build_test_pixconv.sh
echo "== all host tests passed =="
