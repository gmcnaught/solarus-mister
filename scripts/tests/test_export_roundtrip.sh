#!/bin/bash
# FORWARD correctness gate (issue #90): the committed patches/series/*.patch must
# be exactly what a clean apply re-exports. This replaces the retired byte-for-byte
# equivalence gate (test_equivalence.sh), which compared against the FROZEN legacy
# inline patcher and only tolerated an Entities.cpp delta — it broke the moment a
# post-migration patch touched any other file (0028 LuaContext.cpp, 0032
# Renderer.h) and structurally covered under half the series.
#
# The round-trip protects EVERY current patch: apply the series onto pristine
# upstream, re-export with the SAME flags scripts/export_patches.sh uses, and
# assert the regenerated series is byte-identical to what is committed. Any
# hand-edited/stale/misordered patch, or a commit whose diff no longer matches its
# stored form, fails here. Run in-container for GNU-tool fidelity.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib/patch_common.sh
REF="${SOLARUS_REF:-v1.6}"
SRC=/tmp/pcs_roundtrip
OUT=/tmp/pcs_roundtrip_out

ls patches/series/*.patch >/dev/null

rm -rf "$SRC" "$OUT"
pcs_clone_pinned "$SRC" "$REF" -q --depth 1
pcs_git_identity "$SRC"

# Apply the committed series onto pristine upstream.
git -C "$SRC" am --3way "$(pwd)"/patches/series/*.patch >/dev/null

# Re-export from the SAME immutable base + flags as scripts/export_patches.sh so the
# output is deterministic and comparable byte-for-byte. Base off SOLARUS_SHA directly
# (not the moving origin/$REF) — once upstream v1.6 advances, cloning/format-patching
# a different tip would re-export patches that diverge from the committed series and
# fail this gate spuriously. pcs_clone_pinned already checked the pin out as the base.
BASE="$SOLARUS_SHA"
mkdir -p "$OUT"
# Pin diff.algorithm + indentHeuristic to git's canonical defaults, MATCHING
# scripts/export_patches.sh. Without this the re-export inherits the runner/author
# gitconfig; an author with a non-default diff.algorithm (e.g. patience) commits
# patches that then fail this gate on a default-config CI runner (issue #90 follow-up).
git -C "$SRC" -c diff.algorithm=myers -c diff.indentHeuristic=true \
  format-patch "$BASE" -o "$OUT" --zero-commit --no-signature >/dev/null

# Byte-identical filename set + contents. diff -rq exits 1 on any difference;
# capture it so set -e/pipefail doesn't abort before we print the offenders.
delta=$(diff -rq patches/series "$OUT" 2>/dev/null || true)
if [ -n "$delta" ]; then
  echo "EXPORT ROUND-TRIP FAILED — committed patches/series is not what a clean re-export produces:"
  echo "$delta"
  echo
  echo "Fix: rebuild work/solarus (apply_patch_series.sh), edit the commits, then"
  echo "     scripts/export_patches.sh to regenerate patches/series/ and commit the result."
  exit 1
fi

echo "EXPORT ROUND-TRIP OK — $(ls patches/series/*.patch | wc -l | tr -d ' ') patches are byte-identical to a clean re-export"
