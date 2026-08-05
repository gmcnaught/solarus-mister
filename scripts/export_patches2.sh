#!/bin/bash
# Regenerate patches/series2/ from the commits in work/solarus2 on top of the
# pinned upstream 2.x ref. The 2.x sibling of scripts/export_patches.sh; the two
# series are INDEPENDENT (patches/series is authored against 1.6.5 and cannot
# apply to 2.x -- see docs/solarus2.md). Authoring workflow:
#   cd work/solarus2 && $EDITOR ... && git commit -am "feat: ..." && scripts/export_patches2.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/patch_common.sh
SRC="${SOLARUS2_SRC_DIR:-work/solarus2}"; REF="${SOLARUS2_REF}"
test -d "$SRC/.git" || { echo "no $SRC clone; run scripts/apply_patch_series2.sh first" >&2; exit 1; }

git -C "$SRC" cat-file -e "$SOLARUS2_SHA^{commit}" 2>/dev/null || \
  git -C "$SRC" fetch --depth 1 origin "$SOLARUS2_SHA" 2>/dev/null || true
BASE="$SOLARUS2_SHA"
rm -rf patches/series2; mkdir -p patches/series2
# Same canonical diff settings as export_patches.sh, for the same reason: a
# contributor whose gitconfig sets diff.algorithm would otherwise export hunk
# boundaries CI cannot reproduce.
git -C "$SRC" -c diff.algorithm=myers -c diff.indentHeuristic=true \
  format-patch "$BASE" -o "$(pwd)/patches/series2" --zero-commit --no-signature >/dev/null
echo "[export2] regenerated $(ls patches/series2/*.patch | wc -l | tr -d ' ') patches from $SRC on $REF"
