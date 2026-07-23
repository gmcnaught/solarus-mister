# CI release process — publish a deployable Solarus-MiSTer release to GitHub

**Date:** 2026-07-23
**Status:** Design — approved for planning

## Goal

Produce a **GitHub Release** whose single downloadable asset is a MiSTer
SD-card-mirror zip: the end user extracts it to `/media/fat/` and has a working
Solarus core (FPGA RBF + ARM engine + lib closure + launch scripts). This
replaces the current manual assembly (build RBF in CI, cross-build the engine
locally, hand-refresh `deploy/`, `./deploy.py` over SSH) with a tag-triggered,
reproducible pipeline — and gives non-developers a turnkey artifact instead of a
build-from-source path.

## Context (current state)

- **RBF** is built by `.github/workflows/build-rbf.yml` on push (self-hosted
  Windows Quartus, raetro/quartus Docker fallback) → uploads the **`solarus-rbf`**
  artifact (`_Other/Solarus_YYYYMMDD.rbf`, date-stamped).
- **Engine** (`solarus-run` + `libsolarus.so.1.6.5` + a ~29-lib `.so` closure) has
  **no ship-CI today**. Only `build-engine-gprof.yml` exists, which is `-pg`
  instrumented and explicitly *must not* be shipped. The ship engine is currently
  cross-built by hand (`scripts/build_engine.sh` in the armhf Docker image, with
  lean SDL2 + LuaJIT), and the closure assembled by `scripts/collect_runtime_libs.sh`.
- **Deploy tree / SD-mirror layout** is defined authoritatively by `deploy.py`.
  The install extracts to `/media/fat/`.
- The `sonic-mania-mister` sibling repo (`.github/workflows/build.yml`) only
  uploads workflow *artifacts* — it does **not** cut GitHub Releases. It is a
  style reference, not a template for the release step.
- `README.md` already has a "Quick Install" section that references "the release
  zip" — the zip this pipeline produces.

## Decisions (resolved during brainstorming)

| Question | Decision |
|---|---|
| Release trigger | Git tag `v*` (primary) **+** `workflow_dispatch` |
| RBF source | **Reuse** the latest successful `build-rbf` artifact (decoupled from the flaky self-hosted Quartus runner at release time) |
| Engine source | **Separate reusable** `build-engine-ship.yml` workflow uploads an artifact; the release consumes the latest successful one |
| Engine fallback | Latest artifact **+ run-id override** input (no inline rebuild) |
| Quest bundling | **Engine-only** — no bundled quest (matches repo policy; README documents where to get quests) |

## Architecture

Two new workflows. Neither modifies the existing correctness/build workflows.

### 1. `.github/workflows/build-engine-ship.yml` (new — reusable ship engine)

The missing non-gprof, shippable engine build. Mirrors the proven structure of
`build-engine-gprof.yml` but without `-pg` and with LuaJIT always on.

- **Runner:** `ubuntu-latest`, self-contained (no self-hosted dependency).
- **Triggers:**
  - `push` on the engine build inputs:
    `patches/**`, `scripts/build_engine.sh`, `scripts/build_luajit.sh`,
    `scripts/build_sdl2.sh`, `scripts/collect_runtime_libs.sh`,
    `Dockerfile.solarus-build`, `.github/workflows/build-engine-ship.yml`.
    (Keeps a fresh artifact available so a release almost always finds one.)
  - `workflow_dispatch` (manual).
- **Steps:**
  1. `docker build -f Dockerfile.solarus-build -t solarus-armhf-build:bullseye .`
  2. Cross-build **lean SDL2** (`scripts/build_sdl2.sh` in the image) — ship
     requires `work/sdl2-prefix` (no X11/Wayland/GBM/DRM/Pulse subtree).
  3. Register armhf binfmt (`tonistiigi/binfmt --install arm`) so the LuaJIT
     host tools run under qemu.
  4. Cross-build **LuaJIT** (`scripts/build_luajit.sh`).
  5. Build the engine: `SOLARUS_USE_LUAJIT=1` (ship config), **no** `SOLARUS_GPROF`.
  6. `scripts/collect_runtime_libs.sh` → populates `deploy/libs/`.
  7. Upload artifact **`solarus-engine`** containing:
     - `build/armhf/solarus-run`
     - `deploy/libs/**` (the full `.so*` closure, incl. `libsolarus.so.1.6.5`)
- **Concurrency:** `build-engine-ship-${{ github.ref }}`, cancel-in-progress.

### 2. `.github/workflows/release.yml` (new — assemble + publish)

- **Runner:** `ubuntu-latest`.
- **Triggers:**
  - `push: tags: ['v*']` (primary).
  - `workflow_dispatch` with optional inputs:
    - `rbf_run_id` — explicit `build-rbf` run to pull the RBF from (fallback if
      the latest successful run's artifact expired past GitHub's ~90-day retention).
    - `engine_run_id` — explicit `build-engine-ship` run for the engine artifact.
    - `tag` — the release tag to create/target when dispatched manually
      (ignored on tag-push, where `github.ref_name` is authoritative).
- **Permissions:** `contents: write` (create the release), `actions: read`
  (list/download artifacts from other workflows).
- **Steps:**
  1. **Checkout** at the tagged commit (committed launch scripts come from here —
     the release ships the scripts *as tagged*, not from a build artifact).
  2. **Resolve + download the RBF artifact.** If `rbf_run_id` given, use it;
     else `gh run list --workflow build-rbf.yml --branch master --status success
     --limit 1 --json databaseId -q '.[0].databaseId'`. Then
     `gh run download <id> -n solarus-rbf -D _dl/rbf`. Auth via `GITHUB_TOKEN`.
  3. **Resolve + download the engine artifact** the same way from
     `build-engine-ship.yml` (`solarus-engine` → `_dl/engine`).
  4. **Assemble the SD-mirror tree** under a clean staging root (`_stage/`),
     faithful to `deploy.py`:
     - `_Other/Solarus_YYYYMMDD.rbf`  ← `_dl/rbf/*.rbf`
     - `games/Solarus/solarus-run`    ← `_dl/engine/solarus-run`
     - `games/Solarus/libs/*.so*`     ← `_dl/engine/libs/`
     - `games/Solarus/_handler.sh`, `solarus_run.sh`, `quest_manager.sh`,
       `quest_lib.sh`, `core_watch.sh`, `solarus_daemon.sh`  ← repo checkout
     - `games/Solarus/quests/PUT-QUESTS-HERE.txt`  (empty-dir placeholder + note
       pointing at the README "Getting quests" section)
     - `Scripts/Solarus.sh`  ← `scripts/Solarus.sh`
     - `docs/Solarus/README.md`  ← repo checkout
     - **No** `diag.env` (end-user build — diagnostics are opt-in on device only).
  5. **Sanity gate (fail the release loudly):**
     - exactly one `_Other/Solarus_*.rbf`;
     - `games/Solarus/solarus-run` is an ELF (`file` / magic check) and non-empty;
     - lib count in `games/Solarus/libs` ≥ 20 (closure is ~29; guards a
       truncated/empty engine artifact);
     - every committed `.sh` present.
  6. **Normalize:** ensure `+x` on all `*.sh` and `solarus-run`; scripts are
     already LF in-repo (committed shell scripts) so no CRLF strip needed — assert
     no `\r` as a cheap guard.
  7. **Zip:** `cd _stage && zip -r ../solarus-mister-<tag>.zip .` (preserves unix
     perms; `<tag>` = the release tag). **No `-y`** — MiSTer SD cards are
     FAT/exFAT and cannot store symlinks, and `deploy/libs` may contain soname
     symlinks (`libsolarus.so` → `.so.1.6.5`); default `zip` behaviour
     dereferences symlinks into real file copies, which is exactly what FAT
     needs (mirrors how `deploy.py`'s tar-pipe lands real files device-side).
  8. **Publish:** `gh release create <tag> --title "Solarus MiSTer <tag>"
     --generate-notes --notes-file <header>` attaching `solarus-mister-<tag>.zip`.
     The notes header is a short fixed install summary (extract to `/media/fat/`,
     add a quest, run from Scripts once) prepended to the auto-generated
     commit/PR notes. If the release already exists (re-run), `gh release upload
     --clobber` the asset instead of failing.
- **Concurrency:** `release-${{ github.ref }}`, cancel-in-progress **false**
  (never cancel a half-published release).

## Data flow

```
build-rbf.yml (push)          build-engine-ship.yml (push/dispatch)
   │ solarus-rbf artifact          │ solarus-engine artifact
   │ (_Other/Solarus_*.rbf)        │ (solarus-run + deploy/libs/**)
   └──────────────┬────────────────┘
                  ▼
   release.yml  (tag v* / dispatch)
     gh run download latest-success (or run-id override)
                  ▼
     assemble _stage/  (mirror of /media/fat/, per deploy.py)
                  ▼
     sanity gate → zip → gh release create --generate-notes
                  ▼
     GitHub Release  ── asset: solarus-mister-<tag>.zip
```

## Error handling

- **Artifact expired / not found:** the `gh run list` resolve yields no id, or
  `gh run download` 404s → step fails with a clear message telling the operator
  to (a) re-run `build-rbf` / `build-engine-ship`, or (b) pass an explicit
  `*_run_id` via `workflow_dispatch`. Documented in the workflow header.
- **Truncated/empty engine or RBF:** caught by the sanity gate (ELF check, lib
  count, exactly-one-RBF) before a bad zip is ever published.
- **Re-running a release for an existing tag:** `gh release create` is guarded —
  if the release exists, upload the asset with `--clobber` rather than erroring.
- **Self-hosted Quartus runner down at release time:** irrelevant — the RBF is
  *reused*, not rebuilt. That is the whole point of the reuse decision.

## README update

`README.md` already documents install ("Quick Install", "Getting quests"). This
change adds, near the top of Quick Install, a **Download** pointer:

- Link to `https://github.com/gmcnaught/solarus-mister/releases/latest`.
- Name the asset (`solarus-mister-<version>.zip`) and state it extracts to
  `/media/fat/` (merging into the existing `_Other/`, `games/Solarus/`,
  `Scripts/` tree).
- One line noting releases are cut from `v*` tags.

Tone and structure stay consistent with the existing README; no restructuring of
the surrounding sections.

## Testing / validation

CI workflows can't be unit-tested locally in a meaningful way; validation is:

1. **Static:** `shellcheck`/`actionlint`-clean YAML (the repo already runs
   `shellcheck.yml`); the assembly shell steps pass shellcheck.
2. **Dry engine build:** trigger `build-engine-ship.yml` via `workflow_dispatch`
   on the branch; confirm it produces a `solarus-engine` artifact with
   `solarus-run` (ELF) + ~29 libs.
3. **Dry release:** push a throwaway pre-release tag (e.g. `v0.0.1-rc1`) or
   `workflow_dispatch` with explicit run-ids; confirm the zip assembles, the
   sanity gate passes, and a (pre-)release is created with the asset attached.
4. **End-to-end (operator, on HW):** download the published zip, extract to a
   MiSTer SD `/media/fat/`, add a quest, and confirm the core loads and a quest
   runs — the same acceptance already used for `deploy.py` installs.

## Out of scope (YAGNI)

- No `update_all` / MiSTer Frontier database entry (README already says manual
  install is the supported route today).
- No bundled quest data.
- No inline RBF or engine rebuild in the release workflow.
- No changes to the existing `build-rbf.yml`, gprof, or correctness workflows.
- No semantic-version automation / changelog generation beyond
  `gh --generate-notes`.
