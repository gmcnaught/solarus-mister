# Engine Patch-Series Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 41 inline-Python / sed / perl in-place patch blocks in `scripts/build_engine.sh` with a reviewable **git patch series** (`patches/series/*.patch`) applied via `git am --3way`, migrated mechanically with a byte-for-byte equivalence gate.

**Architecture:** `work/solarus` is a pinned `git clone --depth 1 --branch v1.6` (1.6.5). The current build mutates it in place with brittle exact-string anchors. We (1) capture a **golden tree** = the exact patched source the current script produces; (2) mechanically bootstrap a per-feature commit series that reproduces that tree; (3) export it to `patches/series/`; (4) replace the patch phase with `reset → git am --3way → cp new files → ast-grep verify`. The equivalence gate (`git diff` == empty vs golden) is the acceptance test at every migration step.

**Tech Stack:** bash, git (`am`/`format-patch`/`apply`), python3, ast-grep (already vendored: `sgconfig.yml`, `ast-grep`/`sg` on PATH), Docker `solarus-armhf-build:bullseye` (compile only).

## Global Constraints

- **Upstream is pinned:** `SOLARUS_REF=v1.6` (version 1.6.5), never bumped. Do not change it.
- **Equivalence is the acceptance gate:** after migration, the source tree produced by the new apply path MUST be `git diff`-identical to the tree the *current* `build_engine.sh` produces. No modification may be silently dropped.
- **Do NOT touch** the 19 whole-file `cp patches/mister/*` additions or any runtime env-flag semantics (`SOLARUS_CULL_MARGIN`, `SOLARUS_IDLEPARK`, `SOLARUS_TILESTATIC`, …). Env gating stays *inside* each patch.
- **Docker bind-mount:** the container runs as root on a bind mount; `sed -i` cannot write temp files in the mount (that is *why* the current script uses `sed >tmp && cp`). `git am` writes only inside `work/solarus` and is unaffected. The patch phase must first set `git config --global user.email/user.name` and `git config --global --add safe.directory "$PWD/work/solarus"`.
- **Real compile gate is armhf gcc** in the container — `clang -fsyntax-only` is NOT sufficient (per `solarus-sdram-asset-residency-pr66` lesson). The final task MUST run the full Docker build.
- **Golden reference must be generated in-container** (GNU sed/coreutils) so BSD/GNU tool drift never pollutes it. Series *apply* verification (`git am` + `git diff`) is deterministic and may run locally.
- **Patch phase is text-only** (lines 1–2340, no compiler) — golden capture and the equivalence gate do not require compiling.

## File Structure

- `scripts/build_engine.sh` — MODIFY. Add `SOLARUS_PATCH_ONLY` early-exit + git-identity setup (Task 1); at cutover (Task 7) delete lines ~22–2340 and call `apply_patch_series.sh`.
- `scripts/lib/patch_common.sh` — CREATE. Shared helpers: `pcs_reset_clone`, `pcs_git_identity`. Sourced by apply + bootstrap.
- `scripts/apply_patch_series.sh` — CREATE (Task 5). New apply path: reset clone → `git am --3way patches/series/*.patch` → cp new files → ast-grep verify.
- `scripts/export_patches.sh` — CREATE (Task 5). Regenerate `patches/series/` from commits on top of `$SOLARUS_REF` in `work/solarus`.
- `scripts/bootstrap_patch_series.sh` — CREATE (Task 3). One-time migration harness (instrument → per-feature commits → format-patch).
- `patches/series.manifest` — CREATE (Task 2). Ordered map: block-tag → feature-id + commit subject + `boundary` flag.
- `patches/series/NNNN-<feature>.patch` — GENERATED (Task 3).
- `patches/verify/*.yml` — CREATE (Task 6). ast-grep assertion rules (post-apply lint gate).
- `patches/mister/**` — UNCHANGED (the 19 whole-file additions).

---

## Task 1: Patch-phase seam — `SOLARUS_PATCH_ONLY` exit + git identity + golden capture

Make the current script able to STOP right after patching (before cmake) and leave a fully-patched `work/solarus`, so we can capture the golden tree and later swap the phase out cleanly.

**Files:**
- Modify: `scripts/build_engine.sh` (git-identity block near top ~line 21; `SOLARUS_PATCH_ONLY` exit inserted immediately before the cmake configure at line ~2341)
- Create: `scripts/lib/patch_common.sh`
- Create: `scripts/capture_golden.sh`

**Interfaces:**
- Produces: env `SOLARUS_PATCH_ONLY` (when `=1`, build_engine.sh exits 0 after the patch phase, before cmake). `scripts/capture_golden.sh <out_dir>` — writes the patched `work/solarus` source snapshot (tracked upstream files only, new cp'd files excluded) to `<out_dir>` and prints a `git`-style tree hash.
- Consumes: nothing.

- [ ] **Step 1: Write the failing test (seam exists + stops before cmake)**

Create `scripts/tests/test_patch_only.sh`:
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# The patch phase is text-only; run it directly (no Docker) just to prove the seam.
rm -rf work/solarus
SOLARUS_PATCH_ONLY=1 bash scripts/build_engine.sh
test -f work/solarus/src/core/Game.cpp
grep -q "mister_tag_camera_surface" work/solarus/src/core/Game.cpp   # a patch applied
! test -d build/armhf                                                # cmake did NOT run
echo "PATCH_ONLY seam OK"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash scripts/tests/test_patch_only.sh`
Expected: FAIL — the script runs cmake/`nproc` and errors (or creates `build/armhf`) because `SOLARUS_PATCH_ONLY` is not honored yet.

- [ ] **Step 3: Add git identity + safe.directory near the top of build_engine.sh**

In `scripts/build_engine.sh`, immediately after the clone block (after line ~21, before `# 1b.`), insert:
```bash
# [patch-series] Deterministic git identity for in-clone commits / am / reset.
# Harmless in normal builds; required for `git am` and the bootstrap harness.
git config --global user.email  >/dev/null 2>&1 || git config --global user.email "build@solarus-mister.local"
git config --global user.name   >/dev/null 2>&1 || git config --global user.name  "solarus-mister build"
git config --global --add safe.directory "$(pwd)/$SRC" 2>/dev/null || true
```

- [ ] **Step 4: Add the `SOLARUS_PATCH_ONLY` early-exit before cmake**

In `scripts/build_engine.sh`, immediately BEFORE the `# 2. Configure.` comment at line ~2341, insert:
```bash
# [patch-series] Stop after the source-patch phase (text-only, no compile).
# Used by capture_golden.sh and the migration equivalence gate.
if [ "${SOLARUS_PATCH_ONLY:-0}" = "1" ]; then
  echo "[patch-series] SOLARUS_PATCH_ONLY=1 — patched tree ready in $SRC, skipping build."
  exit 0
fi
```

- [ ] **Step 5: Run the seam test to verify it passes**

Run: `bash scripts/tests/test_patch_only.sh`
Expected: `PATCH_ONLY seam OK`

- [ ] **Step 6: Create `scripts/lib/patch_common.sh`**

```bash
#!/bin/bash
# Shared helpers for the patch-series apply + bootstrap paths.
# shellcheck shell=bash

pcs_git_identity() {   # $1 = clone dir
  git config --global user.email >/dev/null 2>&1 || git config --global user.email "build@solarus-mister.local"
  git config --global user.name  >/dev/null 2>&1 || git config --global user.name  "solarus-mister build"
  git config --global --add safe.directory "$1" 2>/dev/null || true
}

# Reset a persistent clone to the pristine pinned upstream tip.
pcs_reset_clone() {    # $1 = clone dir, $2 = ref
  git -C "$1" am --abort 2>/dev/null || true
  git -C "$1" checkout -f "$2"
  git -C "$1" clean -fdx -e /build
  git -C "$1" reset --hard
}
```

- [ ] **Step 7: Create `scripts/capture_golden.sh`**

Excludes the files that `patches/mister/**` provides (those come from the `cp` step, not the series), so the golden tree is exactly the *upstream files as patched*.
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:?usage: capture_golden.sh <out_dir>}"
SRC="work/solarus"
rm -rf "$SRC" "$OUT"
SOLARUS_PATCH_ONLY=1 bash scripts/build_engine.sh
# Enumerate the new files that patches/mister/** injects, so we can exclude them.
find patches/mister -type f -printf '%P\n' 2>/dev/null | sed 's#^#EXCL #' > /tmp/pcs_excl.txt || true
mkdir -p "$OUT"
# Copy only tracked-upstream source, honoring .gitignore, minus the injected new files.
( cd "$SRC" && git ls-files ) | while read -r f; do
  mkdir -p "$OUT/$(dirname "$f")"; cp "$SRC/$f" "$OUT/$f"
done
( cd "$OUT" && find . -type f | sort | xargs sha1sum ) | sha1sum | awk '{print "GOLDEN " $1}'
```

- [ ] **Step 8: Capture the golden tree (in-container for GNU-tool fidelity) and record its hash**

Run:
```bash
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye \
  bash scripts/capture_golden.sh /src/golden-tree
```
Expected: prints `GOLDEN <sha1>`. Save that sha1 in the commit message — it is the migration target.

- [ ] **Step 9: Commit**

```bash
git add scripts/build_engine.sh scripts/lib/patch_common.sh scripts/capture_golden.sh scripts/tests/test_patch_only.sh
git commit -m "build: add SOLARUS_PATCH_ONLY seam + golden-tree capture

Golden sha1: <paste from Step 8>"
```

---

## Task 2: Author `patches/series.manifest` (block → feature grouping)

The 41 blocks map to N features (one patch each). Blocks accumulate into a feature by staging without committing; a `boundary` tag closes the feature with a commit. This manifest is the ONLY human-judgment artifact; the equivalence gate (Task 4) backstops it.

**Files:**
- Create: `patches/series.manifest`

**Interfaces:**
- Produces: `patches/series.manifest` — lines of `TAG | feature-id | boundary(0|1) | commit subject`. `TAG` is a heredoc tag (`PYTAG`), the perl/sed/external markers (`PERL_DRAWPROF`, `SED_L37`, `EXT_QUADTREE`, `CMAKE_SRCLIST`), in **script order**. Consumed by `bootstrap_patch_series.sh` (Task 3).

- [ ] **Step 1: Extract the ordered block list with source-line and completion message**

Run this to produce a scaffold you then annotate:
```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
python3 - scripts/build_engine.sh > /tmp/blocks.tsv <<'PY'
import sys, re
lines = open(sys.argv[1]).read().splitlines()
open_tag=None; msg=""
for i,l in enumerate(lines, 1):
    m = re.search(r"<<'(PY[A-Z0-9]+)'", l)
    if m: open_tag=m.group(1); msg=""
    pm = re.search(r'print\("([^"]+)"\)', l)
    if pm and open_tag: msg=pm.group(1)
    if open_tag and l.strip()==open_tag:            # heredoc close
        print(f"{i}\t{open_tag}\t{msg}"); open_tag=None
    if re.match(r'^\s*perl ', l):  print(f"{i}\tPERL_DRAWPROF\t(perl draw-prof body)")
    if re.match(r'^\s*python3 scripts/patch_quadtree_fat', l): print(f"{i}\tEXT_QUADTREE\t(quadtree fat-AABB)")
PY
cat /tmp/blocks.tsv
```
Expected: ~43 rows (41 PY + perl + external), in ascending line order.

- [ ] **Step 2: Write `patches/series.manifest` grouping blocks into features**

Using `/tmp/blocks.tsv` and the section comments in `build_engine.sh` (e.g. `# 1e. Perf optimizations`, `[SOLARUS_IDLEPARK]`, `[static tile-list]`), assign each TAG a `feature-id` and set `boundary=1` on the LAST tag of each feature. Preserve script order. Example (abbreviated — fill in ALL rows from Step 1):
```
# TAG            | feature-id            | boundary | subject
PYBLT1           | native-video-hook     | 0        | feat(mister): native DDR video hook + present() interception
PYBLT2           | native-video-hook     | 0        | (cont)
CMAKE_SRCLIST    | native-video-hook     | 1        | (cont) add mister sources to cmake list
PYLOOP           | mainloop-prof         | 0        | feat(mister): MainLoop pump guard + phase profiling
PERL_DRAWPROF    | mainloop-prof         | 0        | (cont) draw() phase-timing body
PYDECL           | mainloop-prof         | 1        | (cont)
PYTAG            | camera-tag            | 1        | fix(render): camera-tag + transition-hook + pre-draw camera publish
PYCULL           | cull-margin           | 1        | perf(render): SOLARUS_CULL_MARGIN draw-cull tighten
PYOPAQUE         | opaque-blits          | 0        | perf(render): opaque static-tile fast-copy blits
PYOPT/PYOPT2     | opaque-blits          | 1        | (cont Video/Game opaque)
PYNARH/PYNARCPP  | nonanim-opaque        | 1        | perf(render): NonAnimatedRegions opaque tiles
PYQT+EXT_QUADTREE| quadtree              | 1        | perf(quadtree): get_elements vector+sort + fat-AABB margin
PYME1..PYENTSPLIT| idlepark              | 1        | perf(entities): SOLARUS_IDLEPARK idle-destructible offload
PYMAPCOLL/PYMOVEOBST | move-bookkeeping  | 1        | perf(entities): map-collision + movement obstacle prune
PYSTEPS/PYSND/PYME2  | misc-instr        | 1        | chore(mister): step-count + sound instrumentation
PYTP..PYATPFI    | tilelist-anim        | 1        | feat(render): animated BLT_OP_TILELIST batching
PYTILEB..PYTILESTATIC| tilelist-static   | 1        | feat(render): static tile-list direct-from-atlas
```
NOTE: the real manifest must list EVERY tag from Step 1 exactly once, each with a boundary assignment. `feature-id` becomes the patch filename slug; ordinal (0001…) is the order of first appearance.

- [ ] **Step 3: Validate the manifest covers every block exactly once**

```bash
python3 - <<'PY'
tags_script = set()
import re
for l in open("scripts/build_engine.sh"):
    m = re.search(r"<<'(PY[A-Z0-9]+)'", l)
    if m: tags_script.add(m.group(1))
tags_script |= {"PERL_DRAWPROF","EXT_QUADTREE"}
tags_manifest=set()
for l in open("patches/series.manifest"):
    l=l.strip()
    if not l or l.startswith("#"): continue
    for t in l.split("|")[0].split("/"):        # allow "PYOPT/PYOPT2" shorthand
        t=t.strip()
        if t: tags_manifest.add(t)
missing = tags_script - tags_manifest
extra   = tags_manifest - tags_script
assert not missing, f"manifest MISSING tags: {sorted(missing)}"
assert not extra,   f"manifest has UNKNOWN tags: {sorted(extra)}"
print(f"manifest covers all {len(tags_script)} blocks exactly once")
PY
```
Expected: `manifest covers all NN blocks exactly once`. If it fails, fix the manifest and re-run.

- [ ] **Step 4: Commit**

```bash
git add patches/series.manifest
git commit -m "build: block->feature manifest for patch-series migration"
```

---

## Task 3: `bootstrap_patch_series.sh` — instrumented run → per-feature commits → `patches/series/`

Generate an instrumented copy of the patch phase that stages after every block and commits at each feature boundary, then export to `patches/series/`.

**Files:**
- Create: `scripts/bootstrap_patch_series.sh`
- Generates: `patches/series/NNNN-<feature>.patch`

**Interfaces:**
- Consumes: `patches/series.manifest` (Task 2), `SOLARUS_PATCH_ONLY` seam (Task 1), `patches/mister/**` file list.
- Produces: `patches/series/*.patch` — one per feature, ordered.

- [ ] **Step 1: Write the failing test (series exists + applies cleanly)**

Create `scripts/tests/test_series_applies.sh`:
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib/patch_common.sh
ls patches/series/*.patch >/dev/null                  # series exists
rm -rf /tmp/pcs_apply && git clone --depth 1 --branch "${SOLARUS_REF:-v1.6}" \
  https://gitlab.com/solarus-games/solarus.git /tmp/pcs_apply
pcs_git_identity /tmp/pcs_apply
git -C /tmp/pcs_apply am --3way "$(pwd)"/patches/series/*.patch
echo "SERIES APPLIES CLEAN"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash scripts/tests/test_series_applies.sh`
Expected: FAIL — `ls patches/series/*.patch` errors (no series yet).

- [ ] **Step 3: Write `scripts/bootstrap_patch_series.sh`**

The instrumentation inserts a `pcs_snapshot <TAG>` call after each heredoc terminator / perl line / external-script line. `pcs_snapshot` stages all changes and, when the manifest marks that TAG `boundary=1`, commits with the feature subject. The `patches/mister/**` files are excluded from staging (they come from `cp`, not the series).
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/patch_common.sh
SRC="work/solarus"; REF="${SOLARUS_REF:-v1.6}"

# 1. Build TAG->{'feature','boundary','subject','ord'} from the manifest.
python3 - > /tmp/pcs_manifest.py <<'PY'
import re
rows=[]; ords={}; nxt=1
for l in open("patches/series.manifest"):
    l=l.split("#")[0].strip()
    if not l: continue
    tagfield,feat,bnd,subj = [x.strip() for x in l.split("|",3)]
    if feat not in ords: ords[feat]=nxt; nxt+=1
    for t in tagfield.split("/"):
        rows.append((t.strip(), feat, bnd=="1", subj, ords[feat]))
print("MANIFEST=", {t:(f,b,s,o) for (t,f,b,s,o) in rows})
PY

# 2. Generate the instrumented patch-only script: after each block, call pcs_snapshot.
python3 - scripts/build_engine.sh > /tmp/pcs_instrumented.sh <<'PY'
import sys, re
lines=open(sys.argv[1]).read().splitlines()
out=[]
# stop the instrumented copy at the cmake seam
for i,l in enumerate(lines):
    out.append(l)
    m=re.match(r'^(PY[A-Z0-9]+)$', l.strip())
    if m: out.append(f'pcs_snapshot {m.group(1)}')
    if re.match(r'^\s*perl ', l):  out.append('pcs_snapshot PERL_DRAWPROF')
    if re.match(r'^\s*python3 scripts/patch_quadtree_fat', l): out.append('pcs_snapshot EXT_QUADTREE')
    if '# 2. Configure.' in l: break
print("\n".join(out))
PY

# 3. Define pcs_snapshot and drive the run.
cat > /tmp/pcs_prelude.sh <<'PRE'
source scripts/lib/patch_common.sh
python3 -c "exec(open('/tmp/pcs_manifest.py').read()); import json,os; open('/tmp/pcs_manifest.json','w').write(json.dumps(MANIFEST))"
MISTER_FILES=$(find patches/mister -type f -printf '%P\n' 2>/dev/null | tr '\n' '|' )
pcs_snapshot() {
  local tag="$1"
  # unstage/discard the cp'd new files so only upstream-file edits enter the series
  ( cd "$SRC" && git add -A )
  python3 - "$tag" <<'PYX'
import json,sys,subprocess,os
tag=sys.argv[1]; man=json.load(open('/tmp/pcs_manifest.json'))
src=os.environ['SRC']
if tag not in man:  # unmapped tag -> fail loudly
    raise SystemExit(f"pcs_snapshot: unmapped tag {tag}")
feat,boundary,subj,ordn = man[tag]
if boundary:
    subprocess.check_call(["git","-C",src,"commit","-m",subj])
    print(f"[bootstrap] committed feature {ordn:04d}-{feat}: {subj}")
PYX
}
PRE

# 4. Fresh clone, then run prelude + instrumented under one shell.
export SRC REF
rm -rf "$SRC"
git clone --depth 1 --branch "$REF" https://gitlab.com/solarus-games/solarus.git "$SRC"
pcs_git_identity "$(pwd)/$SRC"
SOLARUS_PATCH_ONLY=1 bash -c "cat /tmp/pcs_prelude.sh /tmp/pcs_instrumented.sh | bash"

# 5. Export per-feature commits to patches/series/ (ordered, upstream-file edits only).
rm -rf patches/series; mkdir -p patches/series
git -C "$SRC" format-patch "$REF" -o "$(pwd)/patches/series" --no-numbered-files \
  --zero-commit --no-signature
# renumber to 0001-... in commit order
python3 - <<'PY'
import os,glob
fs=sorted(glob.glob("patches/series/*.patch"))
for i,f in enumerate(fs,1):
    base=os.path.basename(f).split("-",1)[-1]
    os.rename(f, f"patches/series/{i:04d}-{base}")
print(f"exported {len(fs)} feature patches")
PY
echo "[bootstrap] done."
```

- [ ] **Step 4: Run the bootstrap**

Run (in-container for GNU-tool fidelity):
```bash
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye \
  bash scripts/bootstrap_patch_series.sh
ls -1 patches/series/
```
Expected: `patches/series/0001-*.patch … NNNN-*.patch`, one per manifest feature. If `pcs_snapshot: unmapped tag` appears, the manifest missed a tag — fix Task 2 and re-run.

- [ ] **Step 5: Run the apply test to verify it passes**

Run: `bash scripts/tests/test_series_applies.sh`
Expected: `SERIES APPLIES CLEAN`

- [ ] **Step 6: Commit**

```bash
git add scripts/bootstrap_patch_series.sh scripts/tests/test_series_applies.sh patches/series/
git commit -m "build: bootstrap patch-series from build_engine.sh (per-feature)"
```

---

## Task 4: Equivalence gate — series-applied tree == golden tree

This is the acceptance test for the migration: prove the series reproduces the current build byte-for-byte.

**Files:**
- Create: `scripts/tests/test_equivalence.sh`

**Interfaces:**
- Consumes: `patches/series/*` (Task 3), `scripts/capture_golden.sh` (Task 1), `patches/mister/**`.

- [ ] **Step 1: Write the equivalence test**

Create `scripts/tests/test_equivalence.sh`:
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib/patch_common.sh
REF="${SOLARUS_REF:-v1.6}"
# A) golden = current script output
bash scripts/capture_golden.sh /tmp/golden
# B) series-applied tree
rm -rf /tmp/series && git clone --depth 1 --branch "$REF" \
  https://gitlab.com/solarus-games/solarus.git /tmp/series
pcs_git_identity /tmp/series
git -C /tmp/series am --3way "$(pwd)"/patches/series/*.patch
# copy same upstream-file subset as capture_golden.sh
rm -rf /tmp/series_out; mkdir -p /tmp/series_out
( cd /tmp/series && git ls-files ) | while read -r f; do
  mkdir -p "/tmp/series_out/$(dirname "$f")"; cp "/tmp/series/$f" "/tmp/series_out/$f"; done
# C) diff must be empty
if diff -ru /tmp/golden /tmp/series_out; then
  echo "EQUIVALENCE OK — series reproduces current build byte-for-byte"
else
  echo "EQUIVALENCE FAILED — see diff above"; exit 1
fi
```

- [ ] **Step 2: Run it (in-container) to verify equivalence**

Run:
```bash
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye \
  bash scripts/tests/test_equivalence.sh
```
Expected: `EQUIVALENCE OK — series reproduces current build byte-for-byte`.
If it FAILS: the diff pinpoints the block whose change is missing/duplicated. Fix the manifest grouping (Task 2) or the instrumentation anchor (Task 3) and re-run Tasks 3→4. Do NOT proceed until empty.

- [ ] **Step 3: Commit**

```bash
git add scripts/tests/test_equivalence.sh
git commit -m "test: byte-for-byte equivalence gate (series == current build)"
```

---

## Task 5: New apply path — `apply_patch_series.sh` + `export_patches.sh`

**Files:**
- Create: `scripts/apply_patch_series.sh`
- Create: `scripts/export_patches.sh`

**Interfaces:**
- Produces: `scripts/apply_patch_series.sh` — resets `work/solarus`, applies the series, copies new files, runs verify. `scripts/export_patches.sh` — regenerates `patches/series/` from `work/solarus` commits (going-forward authoring).
- Consumes: `scripts/lib/patch_common.sh` (Task 1).

- [ ] **Step 1: Write `scripts/apply_patch_series.sh`**

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/patch_common.sh
SRC="work/solarus"; REF="${SOLARUS_REF:-v1.6}"

if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "$REF" https://gitlab.com/solarus-games/solarus.git "$SRC"
fi
pcs_git_identity "$(pwd)/$SRC"
pcs_reset_clone "$SRC" "$REF"

echo "[apply] git am --3way $(ls patches/series/*.patch | wc -l) feature patches"
git -C "$SRC" am --3way "$(pwd)"/patches/series/*.patch

echo "[apply] copying whole-file mister additions"
# (These are the SAME cp lines the old build_engine.sh ran; keep them verbatim here.)
scripts/apply_mister_files.sh "$SRC"     # extracted in Task 7 Step 2

echo "[apply] ast-grep verification gate"
scripts/verify_patches.sh "$SRC"         # created in Task 6
echo "[apply] OK"
```
NOTE: `apply_mister_files.sh` is the verbatim block of `cp patches/mister/*` lines lifted out of build_engine.sh in Task 7. Until then, this script is not wired into the build.

- [ ] **Step 2: Write `scripts/export_patches.sh`**

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="work/solarus"; REF="${SOLARUS_REF:-v1.6}"
test -d "$SRC/.git" || { echo "no $SRC clone; run a build first"; exit 1; }
rm -rf patches/series; mkdir -p patches/series
git -C "$SRC" format-patch "$REF" -o "$(pwd)/patches/series" --zero-commit --no-signature
python3 - <<'PY'
import os,glob
for i,f in enumerate(sorted(glob.glob("patches/series/*.patch")),1):
    base=os.path.basename(f).split("-",1)[-1]
    os.rename(f, f"patches/series/{i:04d}-{base}")
PY
echo "[export] patches/series regenerated from $SRC commits on top of $REF"
```

- [ ] **Step 3: Smoke-test export round-trips the series**

```bash
# Rebuild a committed clone from the current series, then re-export; series must be stable.
rm -rf work/solarus
git clone --depth 1 --branch v1.6 https://gitlab.com/solarus-games/solarus.git work/solarus
source scripts/lib/patch_common.sh; pcs_git_identity "$(pwd)/work/solarus"
git -C work/solarus am --3way "$(pwd)"/patches/series/*.patch
bash scripts/export_patches.sh
git diff --stat patches/series/    # expect: only cosmetic/no changes
```
Expected: no semantic changes to `patches/series/` (content-identical; ordering preserved).

- [ ] **Step 4: Commit**

```bash
git add scripts/apply_patch_series.sh scripts/export_patches.sh
git commit -m "build: apply_patch_series + export_patches helpers"
```

---

## Task 6: ast-grep verification gate

A small set of structural assertions that fail the build if a key patched construct is missing after apply. Scoped to verification only.

**Files:**
- Create: `patches/verify/camera-tag.yml`, `patches/verify/cull-margin.yml`, `patches/verify/idlepark.yml`, `patches/verify/tilelist-static.yml`
- Create: `scripts/verify_patches.sh`

**Interfaces:**
- Produces: `scripts/verify_patches.sh <src_dir>` — runs `ast-grep scan` with the `patches/verify` rules against `<src_dir>`; exit non-zero if any required construct is absent.
- Consumes: applied tree from Task 5.

- [ ] **Step 1: Write the failing test**

Create `scripts/tests/test_verify.sh`:
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# On the patched tree -> pass; on pristine upstream -> fail (proves the gate bites).
bash scripts/verify_patches.sh work/solarus && echo "VERIFY PASS (patched)"
rm -rf /tmp/pristine && git clone --depth 1 --branch v1.6 \
  https://gitlab.com/solarus-games/solarus.git /tmp/pristine
if bash scripts/verify_patches.sh /tmp/pristine; then
  echo "VERIFY DID NOT BITE on pristine — BUG"; exit 1
else
  echo "VERIFY correctly failed on pristine"
fi
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash scripts/tests/test_verify.sh`
Expected: FAIL — `scripts/verify_patches.sh` does not exist yet.

- [ ] **Step 3: Write the ast-grep rules**

`patches/verify/camera-tag.yml`:
```yaml
id: mister-camera-tag-present
language: cpp
rule:
  pattern: Solarus::mister_tag_camera_surface($$$)
```
`patches/verify/cull-margin.yml`:
```yaml
id: mister-cull-margin-present
language: cpp
rule:
  pattern: std::getenv("SOLARUS_CULL_MARGIN")
```
`patches/verify/idlepark.yml`:
```yaml
id: mister-idlepark-present
language: cpp
rule:
  pattern: std::getenv("SOLARUS_IDLEPARK")
```
`patches/verify/tilelist-static.yml`:
```yaml
id: mister-tilestatic-present
language: cpp
rule:
  pattern: std::getenv("SOLARUS_TILESTATIC")
```

- [ ] **Step 4: Write `scripts/verify_patches.sh`**

Each rule must match ≥1 time in the tree; a rule with zero matches fails the gate.
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TREE="${1:?usage: verify_patches.sh <src_dir>}"
fail=0
for rule in patches/verify/*.yml; do
  id=$(python3 -c "import sys,re;print(re.search(r'id:\s*(\S+)',open(sys.argv[1]).read()).group(1))" "$rule")
  n=$(ast-grep scan --rule "$rule" "$TREE" --json 2>/dev/null | python3 -c "import sys,json;print(len(json.load(sys.stdin)))")
  if [ "$n" -eq 0 ]; then echo "VERIFY FAIL: $id matched 0 times"; fail=1
  else echo "verify ok: $id ($n)"; fi
done
exit $fail
```

- [ ] **Step 5: Run the verify test to verify it passes**

Run: `bash scripts/tests/test_verify.sh`
Expected: `VERIFY PASS (patched)` then `VERIFY correctly failed on pristine`.

- [ ] **Step 6: Commit**

```bash
git add patches/verify/ scripts/verify_patches.sh scripts/tests/test_verify.sh
git commit -m "build: ast-grep post-apply verification gate"
```

---

## Task 7: Cutover — gut the patch phase, wire in the series, full Docker build + HW smoke

Replace the ~2320-line patch phase with the series apply, and prove the produced **binary** still works.

**Files:**
- Modify: `scripts/build_engine.sh` (delete lines ~22–2340 patch phase; call apply script)
- Create: `scripts/apply_mister_files.sh`

**Interfaces:**
- Consumes: everything from Tasks 1–6.

- [ ] **Step 1: Capture a baseline armhf binary from the CURRENT (pre-cutover) build**

```bash
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_engine.sh
cp build/armhf/libsolarus.so.1.6.5 /tmp/lib_before.so
cp build/armhf/solarus-run        /tmp/run_before
```

- [ ] **Step 2: Extract the whole-file `cp patches/mister/*` block into `scripts/apply_mister_files.sh`**

Copy the exact `cp patches/mister/...` / `cp patches/mister/blitter/...` lines (and the `SolarusLibrarySources.cmake` sources-list additions if done via `cp`, NOT the sed/python edits — those are in the series) from `build_engine.sh` into:
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${1:?usage: apply_mister_files.sh <src_dir>}"
MDST="$SRC/src/graphics/sdlrenderer"; MADST="$SRC/src/audio"
mkdir -p "$MDST/blitter"
# <<< paste the verbatim `cp patches/mister/*` lines here, with $SRC/$MDST/$MADST >>>
```

- [ ] **Step 3: Replace the patch phase in build_engine.sh**

Delete the patch-phase body (everything from `# 1b.` at line ~23 through the `SOLARUS_PATCH_ONLY` exit at line ~2340) and replace with:
```bash
# [patch-series] Apply downstream modifications as a reviewable git series.
# (Was ~2320 lines of inline python/sed/perl string-replace; see
#  docs/superpowers/specs/2026-07-06-engine-patch-series-design.md.)
scripts/apply_patch_series.sh
if [ "${SOLARUS_PATCH_ONLY:-0}" = "1" ]; then
  echo "[patch-series] SOLARUS_PATCH_ONLY=1 — patched tree ready, skipping build."
  exit 0
fi
```
Keep the clone block (lines ~17–21) and the git-identity block from Task 1, and everything from `# 2. Configure.` onward, unchanged.

- [ ] **Step 4: Equivalence re-check after cutover (source level)**

Run:
```bash
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye \
  bash scripts/tests/test_equivalence.sh
```
Expected: `EQUIVALENCE OK`. (Now the "current build" path == the series path, so this also confirms the cutover script wiring.)

- [ ] **Step 5: Full Docker build via the new path**

Run:
```bash
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_engine.sh
```
Expected: build completes; `build/armhf/{solarus-run,libsolarus.so.1.6.5}` produced. This is the **real armhf gcc gate**.

- [ ] **Step 6: Compare the produced binary against the baseline**

```bash
# .text/symbols should be equivalent; exact byte-match is not guaranteed (build paths),
# so compare symbol tables + section sizes as a strong sanity check.
diff <(nm -C /tmp/lib_before.so | sort) <(nm -C build/armhf/libsolarus.so.1.6.5 | sort) \
  && echo "SYMBOLS MATCH" || echo "WARN: symbol diff — investigate before shipping"
size /tmp/lib_before.so build/armhf/libsolarus.so.1.6.5
```
Expected: `SYMBOLS MATCH` (or a diff you can explain). Any unexpected missing symbol means a patch was dropped — return to Task 4.

- [ ] **Step 7: HW smoke test (Mystery of Solarus DX)**

Deploy and boot per the CLAUDE.md deploy recipe (refresh `deploy/libs/libsolarus.so.1.6.5` from `build/armhf` first — see `fpga-deploy-refresh-from-build-armhf`), load the Solarus core, confirm: title screen renders, overworld renders, frame counter at `0x3A000000` advances, no green/stale-atlas screen. This confirms the env-gated features (cull/idlepark/tilestatic) are live.
Expected: game boots and renders identically to the pre-cutover engine.

- [ ] **Step 8: Commit the cutover**

```bash
git add scripts/build_engine.sh scripts/apply_mister_files.sh
git commit -m "build: cut over to git patch-series; remove inline patch phase

build_engine.sh: -2300 lines of inline python/sed/perl; patches now live in
patches/series/*.patch (git am --3way) with an ast-grep verify gate.
Equivalence + full armhf build + MoSDX HW smoke all green."
```

---

## Self-Review

**Spec coverage:**
- Directory layout (series/verify/mister) → Tasks 3, 6; mister untouched → Task 7 Step 2 (verbatim cp). ✓
- Build-time apply (reset → am --3way → cp → verify) → Task 5 + Task 6, wired Task 7. ✓
- Authoring workflow (edit → commit → export) → `export_patches.sh` Task 5 + round-trip test Step 3. ✓
- One-time instrument-and-commit migration → Tasks 2–3. ✓
- Equivalence gate (`git diff` == 0) → Task 4, re-checked Task 7 Step 4. ✓
- One-patch-per-feature granularity → manifest Task 2 drives per-feature commits Task 3. ✓
- ast-grep verify-only role → Task 6. ✓
- Docker/bind-mount git identity + safe.directory → Task 1 Step 3, `pcs_git_identity`. ✓
- Shallow-clone reset semantics → `pcs_reset_clone` Task 1 Step 6. ✓
- armhf gcc as real gate → Task 7 Step 5. ✓

**Placeholder scan:** the only intentional "paste verbatim" points are Task 2 Step 2 (fill all manifest rows — the block list is generated in Step 1) and Task 7 Step 2 (lift the existing `cp` lines). Both are mechanical transcriptions with a validating check (Task 2 Step 3 asserts full coverage; Task 4 asserts equivalence). No vague error-handling placeholders.

**Type/name consistency:** `pcs_git_identity`/`pcs_reset_clone`/`pcs_snapshot` (patch_common.sh), `SOLARUS_PATCH_ONLY`, `capture_golden.sh`, `apply_patch_series.sh`, `apply_mister_files.sh`, `verify_patches.sh`, `export_patches.sh`, `patches/series.manifest`, `patches/series/NNNN-<feature>.patch`, `patches/verify/*.yml` — used consistently across tasks.

## Risks & Mitigations

- **Manifest miscount / dropped block** → Task 2 Step 3 coverage assert + Task 4 byte-equivalence gate catch it before cutover.
- **`git am --3way` fuzz differs from exact string-replace** → equivalence gate is byte-level; any drift fails Task 4.
- **BSD vs GNU tool drift in golden capture** → golden + gate run in-container (Global Constraints).
- **Instrumentation anchor misses a block** (e.g. a block with no `print`) → `pcs_snapshot` staging is `git add -A`, so its changes still land in the *next* boundary commit; the manifest coverage check + equivalence gate confirm nothing is lost, but review the per-feature diff for mis-grouping.
