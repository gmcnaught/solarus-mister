#!/bin/bash
# Regenerate patches/series/ from the commits in work/solarus on top of the
# pinned upstream ref. Going-forward authoring workflow:
#   cd work/solarus && $EDITOR ... && git commit -am "feat: ..." && scripts/export_patches.sh
# Patch FILENAMES are taken from each commit's subject slug; the commit order is
# preserved. (The migration seeded work/solarus's commits; thereafter you evolve
# them directly and re-export.)
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="work/solarus"; REF="${SOLARUS_REF:-v1.6}"
test -d "$SRC/.git" || { echo "no $SRC clone; run a build (apply_patch_series.sh) first" >&2; exit 1; }

# Base = the pristine upstream commit the series sits on. Use the remote-tracking
# ref (stable) — the local $REF branch is advanced by `git am` during apply.
BASE=$(git -C "$SRC" rev-parse "origin/$REF")
rm -rf patches/series; mkdir -p patches/series
git -C "$SRC" format-patch "$BASE" -o "$(pwd)/patches/series" --zero-commit --no-signature >/dev/null
echo "[export] regenerated $(ls patches/series/*.patch | wc -l | tr -d ' ') patches from $SRC on $REF"
