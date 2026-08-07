#!/bin/bash
# Apply the downstream MiSTer modifications to the Solarus 2.x engine source tree:
#   1. reset the pinned 2.x clone to pristine upstream
#   2. git am --3way the 2.x feature series (patches/series2/*.patch)
#   3. copy the whole-file MiSTer additions (patches/mister/** via apply_mister_files.sh)
#
# The 2.x sibling of scripts/apply_patch_series.sh. The two SERIES are separate
# (patches/series is authored against 1.6.5 and does not apply to 2.x), but the
# whole-file additions in patches/mister/ -- the blitter renderer, the emitter, the
# pixel converter, the DDR writers -- are SHARED VERBATIM between the two lines:
# they are engine-version-agnostic apart from one `SOLARUS_MAJOR_VERSION >= 2`
# switch in mister_blitter_renderer.cpp (the destination-surface View offset).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/patch_common.sh
SRC="${SOLARUS2_SRC_DIR:-work/solarus2}"

if [ ! -d "$SRC/.git" ]; then
  echo "Cloning Solarus $SOLARUS2_REF (pinned to $SOLARUS2_SHA)..."
  pcs_clone_pinned_at "$SRC" "$SOLARUS2_REF" "$SOLARUS2_SHA" --depth 1
fi
pcs_git_identity "$(pwd)/$SRC"
pcs_reset_clone_at "$SRC" "$SOLARUS2_REF" "$SOLARUS2_SHA"

echo "[apply2] git am --3way $(ls patches/series2/*.patch | wc -l | tr -d ' ') feature patches"
git -C "$SRC" am --3way "$(pwd)"/patches/series2/*.patch

echo "[apply2] copying whole-file MiSTer additions"
bash scripts/apply_mister_files.sh "$SRC"
echo "[apply2] OK"
