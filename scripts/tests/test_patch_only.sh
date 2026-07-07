#!/bin/bash
# Seam test: SOLARUS_PATCH_ONLY=1 leaves a fully-patched tree and does NOT compile.
# Run in-container (the patch phase targets bullseye GNU tools).
set -euo pipefail
cd "$(dirname "$0")/../.."
rm -rf work/solarus build/armhf
SOLARUS_PATCH_ONLY=1 bash scripts/build_engine.sh
test -f work/solarus/src/core/Game.cpp
grep -q "mister_tag_camera_surface" work/solarus/src/core/Game.cpp   # a patch applied
! test -d build/armhf                                                # cmake did NOT run
echo "PATCH_ONLY seam OK"
