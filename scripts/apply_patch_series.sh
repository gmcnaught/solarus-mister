#!/bin/bash
# Apply the downstream MiSTer modifications to the engine source tree:
#   1. reset the pinned clone to pristine upstream
#   2. git am --3way the reviewable feature series (patches/series/*.patch)
#   3. copy the whole-file MiSTer additions (patches/mister/** via apply_mister_files.sh)
#   4. ast-grep verification gate
# Replaces the ~2320-line inline python/sed/perl patch phase in build_engine.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/patch_common.sh
SRC="work/solarus"; REF="${SOLARUS_REF:-v1.6}"

if [ ! -d "$SRC/.git" ]; then
  echo "Cloning Solarus $REF (pinned to $SOLARUS_SHA)..."
  pcs_clone_pinned "$SRC" "$REF" --depth 1
fi
pcs_git_identity "$(pwd)/$SRC"
pcs_reset_clone "$SRC" "$REF"

echo "[apply] git am --3way $(ls patches/series/*.patch | wc -l | tr -d ' ') feature patches"
git -C "$SRC" am --3way "$(pwd)"/patches/series/*.patch

echo "[apply] copying whole-file MiSTer additions"
bash scripts/apply_mister_files.sh "$SRC"

echo "[apply] ast-grep verification gate"
bash scripts/verify_patches.sh "$SRC"
echo "[apply] OK"
