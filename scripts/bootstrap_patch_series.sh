#!/bin/bash
# One-time migration: mechanically derive patches/series/*.patch from the current
# build_engine.sh patch phase. Instruments a copy of build_engine.sh to commit at
# each feature boundary (patches/series.manifest), then git format-patch exports
# the per-feature series. Going forward the export round-trip
# (scripts/tests/test_export_roundtrip.sh) is the correctness gate: a clean apply
# must re-export byte-identically to the committed patches/series/. Run
# in-container for GNU-tool fidelity.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/patch_common.sh
SRC="work/solarus"; REF="${SOLARUS_REF:-v1.6}"
INST="scripts/.build_engine.instrumented.sh"

echo "[bootstrap] generating instrumented patch phase from manifest"
python3 - > "$INST" <<'PY'
import re
src=open("scripts/legacy/build_engine_patchphase.sh").read().splitlines()
bmap=set()
for l in open("patches/series.manifest"):
    l=l.split("#")[0].strip()
    if not l: continue
    cl=int(l.split("|",1)[0]); bmap.add(cl)
out=[]; injected=False
for i,line in enumerate(src,1):
    out.append(line)
    if (not injected) and "safe.directory" in line:
        out += ['',
          '# === [bootstrap] instrumentation ===',
          'pcs_snapshot() {  # $1 = boundary close-line; subject looked up from manifest',
          '  git -C "$SRC" add -u',
          '  if git -C "$SRC" diff --cached --quiet; then',
          '    echo "[bootstrap] WARN: no staged changes at boundary $1" >&2; exit 3',
          '  fi',
          "  local subj; subj=$(awk -F'|' -v ln=\"$1\" '$1+0==ln{sub(/^ */,\"\",$3);print $3;exit}' patches/series.manifest)",
          '  test -n "$subj" || { echo "[bootstrap] no subject for boundary $1" >&2; exit 4; }',
          '  git -C "$SRC" commit -q -m "$subj"',
          '  echo "[bootstrap] commit @$1: $subj"',
          '}',
          '# === end instrumentation ===']
        injected=True
    if i in bmap:
        out.append(f'pcs_snapshot {i}')
assert injected, "could not find safe.directory anchor to inject instrumentation"
print("\n".join(out))
PY

echo "[bootstrap] fresh clone $REF (pinned to $SOLARUS_SHA)"
rm -rf "$SRC"
pcs_clone_pinned "$SRC" "$REF" --depth 1
pcs_git_identity "$(pwd)/$SRC"
BASE=$(git -C "$SRC" rev-parse HEAD)
git -C "$SRC" checkout -q -b pcs-work           # commit onto a work branch, keep BASE clean
echo "[bootstrap] base commit $BASE"

# Run the instrumented patch phase (its clone-guard sees .git and skips re-clone).
SOLARUS_PATCH_ONLY=1 bash "$INST"

# Export via the same helper the going-forward workflow uses, so filenames
# (git-standard NNNN-<subject-slug>.patch) round-trip identically. In this fresh
# clone origin/$REF == BASE == pristine, so export_patches.sh sees the 16 commits.
echo "[bootstrap] exporting per-feature patches"
bash scripts/export_patches.sh
rm -f "$INST"
echo "[bootstrap] done."
