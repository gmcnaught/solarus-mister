# Engine patch-series — design

**Date:** 2026-07-06
**Status:** Approved — implementation branch `refactor/engine-patch-series` off master
(PR #66 merged; counts below re-verified against master `build_engine.sh` on 2026-07-06).
**Topic:** Replace the sed/inline-Python patching of the Solarus engine with a maintainable git patch series.

## Problem

`scripts/build_engine.sh` (**2432 lines** on master) carries the downstream MiSTer
modifications to the pinned Solarus 1.6.5 engine as **41 inline Python string-replace
blocks** (each an exact `old`-string anchor + `assert old in s` + a `grep -q` idempotency
guard), **1 `sed` expression** (line 37), **1 `perl -0pi` one-liner** (line 319, MainLoop
draw-prof body), **1 external Python patch script** (`scripts/patch_quadtree_fat.py`, called
at line 946), and **19 whole-file `cp patches/mister/*` additions**. There are **56
`grep -q` idempotency guards** in total.

The 19 whole-file copies are clean and are **not** the problem. The pain is concentrated
in the 41 in-place modifications:

- Exact-text anchors are brittle and abort the build hard (`assert`) on any drift.
- Logic is buried in a 2000-line shell script — not reviewable as diffs, no commit
  messages, no per-feature history.
- Patches are order-dependent and interact, forcing per-file "reset to pristine" hacks
  (build_engine.sh lines 466, 604, 941) and `grep -q` idempotency guards throughout.
- Inconsistent reset policy: Entities/Game/Quadtree/NonAnimatedRegions ARE
  git-checkout-reset per build, but `MainLoop.cpp`/`System.cpp` are deliberately NOT
  (line ~1657) and rely on one-time grep guards instead — two different idempotency
  models in one script.
- No compiler/LSP/test feedback while authoring a change.

`work/solarus` is already a `git clone --depth 1 --branch v1.6` (version 1.6.5) at build
time, and **upstream is pinned — it never moves**. That fact drives the design. (The
shallow clone is fine: `git am` and `reset --hard` operate on the fetched tip, which is
all the series needs.)

**Tooling already present:** ast-grep is vendored/available in this repo (`sgconfig.yml`,
`ast-grep-rules.yaml`, `rules/`, and `ast-grep`/`sg` on PATH) — the verify gate below
reuses existing tooling rather than introducing a new dependency.

## Chosen approach: git patch series (edit real files → `git format-patch` → `git am`)

Maintain each downstream modification as a real commit on top of the pinned `$SOLARUS_REF`
clone. A helper exports them to `patches/series/NNNN-<feature>.patch`; `build_engine.sh`
replaces all 41 Python blocks (plus the sed, perl, and external quadtree
script) with a single `git am --3way`.

### Why this over the alternatives

- **vs. ast-grep declarative rules (Option B):** most patches are multi-line *block
  insertions* (drop an `#ifdef` block after a specific call; add a whole method), which is
  exactly what ast-grep's `fix:` is weakest at — you re-quote surrounding code and keep
  most of the brittleness while rewriting 41 rules. ast-grep's structural resilience mainly
  pays off across upstream version churn, which a pinned upstream does not have.
- **vs. vendor fork / submodule (Option C):** cleanest authoring, but adds a second repo
  to host and sync and hides the delta from this repo's reviewers. Heavier than the problem
  warrants.
- The one real weakness of unified diffs — line-number rot on upstream bumps — is
  **essentially zero** here because upstream is pinned at 1.6.5.

### Gains

- Real compiler / LSP / clangd / upstream tests while authoring.
- Every patch is a reviewable diff **with a commit message** and per-feature history.
- `git am --3way` replaces every `assert` hard-abort with a real 3-way merge that emits
  conflict markers to resolve — strictly safer than today.
- Resetting to a pristine clone each build **deletes** the entire class of `grep -q`
  idempotency guards and the three per-file "reset to pristine" hacks (lines
  466/604/941), and it unifies the two competing idempotency models (reset-based vs.
  one-time grep guards on MainLoop/System) into one: always apply to a pristine tree.

## Components

### Directory layout

```
patches/
  series/              # NEW — one patch per FEATURE, applied in order
    0001-native-video-hook.patch
    0002-camera-tag-transition-hook.patch
    0003-cull-margin.patch
    ...
    00NN-<feature>.patch
  verify/              # NEW — ast-grep assertion rules (lint gate)
    camera-tag.yml
    cull-margin.yml
    ...
  mister/              # UNCHANGED — the 19 whole-file additions (already clean)
```

**Series granularity: one patch per feature** (not per source file). Maps 1:1 to PRs and
memory entries; lets a single feature be reverted by deleting one patch; multi-file
features (e.g. IDLEPARK, which touches Entities + Destructible + Enemy) become one coherent
patch. Env-flag runtime gating (`SOLARUS_CULL_MARGIN`, `SOLARUS_IDLEPARK`, …) stays exactly
as-is **inside** each patch — orthogonal, and still how HW A/B testing works.

### Build-time apply (replaces the 41 Python blocks + sed + perl + external script)

```
1. Reset work/solarus to pristine upstream:
     git -C work/solarus am --abort 2>/dev/null || true
     git -C work/solarus checkout -f $SOLARUS_REF
     git -C work/solarus clean -fdx -e /build     # preserve any in-tree build dir
     git -C work/solarus reset --hard
2. git -C work/solarus am --3way patches/series/*.patch
3. cp patches/mister/* …            # the existing whole-file copies, UNCHANGED
4. ast-grep scan --rule-dir patches/verify   # fail the build if any assertion missing
```

### Authoring workflow (going forward)

```
cd work/solarus            # real tree: compiler, LSP, upstream tests all work
$EDITOR src/entities/Entities.cpp
git commit -am "fix: <feature>"
scripts/export_patches.sh  # regenerates patches/series/ from commits on top of $SOLARUS_REF
```

A new fix = one commit + re-export. Reverting a feature = delete one patch file.

### One-time migration — `scripts/bootstrap_patch_series.sh`

Mechanical **instrument-and-commit** (chosen over hand-curation to avoid behavioral drift
from the HW-validated build):

1. Clone pristine `$SOLARUS_REF` into a scratch tree.
2. Run the *current* patch logic, `git commit` after each block, using that block's
   existing `print(...)`/`echo` line as the commit subject.
3. `git format-patch $SOLARUS_REF` → `patches/series/`.

**Equivalence gate (acceptance):** the tree after `git am`-ing the new series must be
`git diff`-identical to the tree the legacy script produces. Migration is NOT accepted
until that diff is empty — so no modification can be silently dropped.

### ast-grep's role (deliberately scoped)

**Verification gate only, not the rewrite engine.** A handful of `patches/verify/*.yml`
rules assert the key patched constructs are present after apply (structural anchors,
resilient to formatting) — e.g. the `mister_tag_camera_surface` call exists, the
cull-margin `Rectangle` shape exists. Cheap safety where it pays off, with no cost of
re-expressing 41 insertions structurally.

## Constraints / notes

- **Docker bind-mount:** `git am` writes only inside `work/solarus` (its own clone),
  sidestepping the `sed -i` temp-file-in-mounted-dir problem entirely. The container's
  patch phase must first set `git config --global user.email/user.name` and
  `git config --global --add safe.directory <clone>`.
- **Incremental rebuild:** resetting + re-`am` touches file mtimes, so a build after any
  patch change recompiles affected files — same behavior as today (the current script also
  rewrites files). Acceptable.
- **Whole-file additions** (`patches/mister/*`) are copied after `git am`; patches are text
  edits to upstream files and do not depend on the new files being present to apply.

## Out of scope

- No change to the 19 whole-file `cp patches/mister/*` additions.
- No change to runtime env-flag gating semantics.
- No upstream version bump (still `v1.6` / 1.6.5).

## Deferred

Implementation is deferred: another agent will land changes on `master` first; rebase this
work on the updated `master` before writing the implementation plan (which will likely
touch build_engine.sh, whose patch blocks may have shifted).
