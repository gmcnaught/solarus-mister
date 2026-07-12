#!/bin/bash
# Regenerate patches/series/ from the commits in work/solarus on top of the
# pinned upstream ref. Going-forward authoring workflow:
#   cd work/solarus && $EDITOR ... && git commit -am "feat: ..." && scripts/export_patches.sh
# Patch FILENAMES are taken from each commit's subject slug; the commit order is
# preserved. (The migration seeded work/solarus's commits; thereafter you evolve
# them directly and re-export.)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/patch_common.sh
SRC="work/solarus"; REF="${SOLARUS_REF:-v1.6}"
test -d "$SRC/.git" || { echo "no $SRC clone; run a build (apply_patch_series.sh) first" >&2; exit 1; }

# Base = the pinned pristine upstream commit the series sits on (issue #98). Pin
# directly to SOLARUS_SHA rather than origin/$REF so a moved branch tip in a
# pre-existing clone can't shift the export base under us.
git -C "$SRC" cat-file -e "$SOLARUS_SHA^{commit}" 2>/dev/null || \
  git -C "$SRC" fetch --depth 1 origin "$SOLARUS_SHA" 2>/dev/null || true
BASE="$SOLARUS_SHA"
rm -rf patches/series; mkdir -p patches/series
# Pin the diff algorithm + indent heuristic explicitly (issue #90 follow-up): git's
# DEFAULT is `myers`, but an author whose global gitconfig sets diff.algorithm
# (e.g. patience) would otherwise export non-canonical hunk boundaries that then
# fail test_export_roundtrip.sh in CI (which re-exports with the defaults). Force the
# canonical form here AND in the round-trip so the two are identical everywhere.
git -C "$SRC" -c diff.algorithm=myers -c diff.indentHeuristic=true \
  format-patch "$BASE" -o "$(pwd)/patches/series" --zero-commit --no-signature >/dev/null
echo "[export] regenerated $(ls patches/series/*.patch | wc -l | tr -d ' ') patches from $SRC on $REF"
