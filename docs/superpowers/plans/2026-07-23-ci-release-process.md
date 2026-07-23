# CI Release Process Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add CI that publishes a tag-triggered GitHub Release whose single asset is a MiSTer SD-mirror zip (RBF + engine + lib closure + launch scripts), extractable to `/media/fat/`.

**Architecture:** Two new GitHub Actions workflows plus a README pointer. `build-engine-ship.yml` cross-builds the shippable engine (lean SDL2 + LuaJIT, no `-pg`) and uploads a `solarus-engine` artifact. `release.yml` fires on a `v*` tag, downloads the latest successful `solarus-rbf` (from the existing `build-rbf.yml`) and `solarus-engine` artifacts, assembles the SD-mirror tree faithful to `deploy.py`, sanity-gates it, zips it, and publishes a GitHub Release. No existing workflow is modified.

**Tech Stack:** GitHub Actions YAML, `gh` CLI (built into runners), Docker armhf cross-build image (`solarus-armhf-build:bullseye`), bash. Local lint via `docker run rhysd/actionlint` (bundles shellcheck).

## Global Constraints

- **Ship engine config (verbatim):** `SOLARUS_USE_LUAJIT=1`, and **no** `SOLARUS_GPROF` — a `-pg` (mcount) build MUST NOT ship. Ship engine links **lean SDL2** (`scripts/build_sdl2.sh`, requires `work/sdl2-prefix`) and from-source **LuaJIT** (`scripts/build_luajit.sh`, needs armhf binfmt under qemu).
- **RBF source:** reuse the latest successful `solarus-rbf` artifact from `build-rbf.yml` — never rebuild the RBF in the release workflow.
- **Engine source:** the latest successful `solarus-engine` artifact from `build-engine-ship.yml` — never rebuild inline. Both artifact lookups accept an explicit `*_run_id` `workflow_dispatch` input as a retention fallback.
- **SD-mirror layout (authoritative, from `deploy.py`), extracts to `/media/fat/`:**
  - `_Other/Solarus_YYYYMMDD.rbf`
  - `games/Solarus/solarus-run`
  - `games/Solarus/libs/*.so*` (the ~29-lib closure; real files, `cp -L` in `collect_runtime_libs.sh`)
  - `games/Solarus/{_handler,solarus_run,quest_manager,quest_lib,core_watch,solarus_daemon}.sh`
  - `games/Solarus/quests/` (empty — engine-only; ship a `PUT-QUESTS-HERE.txt` placeholder)
  - `Scripts/Solarus.sh`
  - `docs/Solarus/README.md`
  - **No** `games/Solarus/diag.env` (diagnostics are opt-in on device only).
- **Zip:** `zip -r` (NO `-y`) — FAT/exFAT cannot store symlinks; default `zip` dereferences.
- **Repo:** `gmcnaught/solarus-mister`, default branch `master`.
- **Trigger:** `push: tags: ['v*']` primary; `workflow_dispatch` secondary.
- **Do not modify** `build-rbf.yml`, `build-engine-gprof.yml`, or any correctness workflow.

---

### Task 1: `build-engine-ship.yml` — shippable engine build

**Files:**
- Create: `.github/workflows/build-engine-ship.yml`

**Interfaces:**
- Consumes: repo build scripts `scripts/build_sdl2.sh`, `scripts/build_luajit.sh`, `scripts/build_engine.sh` (outputs `build/armhf/solarus-run` + `build/armhf/libsolarus.so.1.6.5`), `scripts/collect_runtime_libs.sh` (outputs `deploy/libs/*.so*`), `Dockerfile.solarus-build`.
- Produces: workflow artifact **`solarus-engine`** with a flat tree — `solarus-run` at the root and `libs/*.so*` — consumed by Task 2's release workflow.

- [ ] **Step 1: Write the workflow file**

Create `.github/workflows/build-engine-ship.yml`:

```yaml
name: Build Solarus engine (ship)

# Cross-builds the SHIPPABLE Solarus 1.6.5 engine for MiSTer armhf and uploads
# the `solarus-engine` artifact that release.yml packages into a GitHub Release.
#
# Ship config: lean SDL2 + from-source LuaJIT + engine (SOLARUS_USE_LUAJIT=1,
# NO -pg). This is the ship counterpart to build-engine-gprof.yml (which is -pg
# instrumented and MUST NOT be shipped) — a mcount check below fails the build
# if a -pg binary ever reaches this workflow.

on:
  push:
    paths:
      - 'patches/**'
      - 'scripts/build_engine.sh'
      - 'scripts/build_luajit.sh'
      - 'scripts/build_sdl2.sh'
      - 'scripts/collect_runtime_libs.sh'
      - 'Dockerfile.solarus-build'
      - '.github/workflows/build-engine-ship.yml'
  workflow_dispatch:

concurrency:
  group: build-engine-ship-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build-ship:
    runs-on: ubuntu-latest
    timeout-minutes: 90
    steps:
      - uses: actions/checkout@v4

      - name: Build the armhf cross-build image
        run: docker build -f Dockerfile.solarus-build -t solarus-armhf-build:bullseye .

      # Lean SDL2 (matches ship): build_engine.sh hard-requires work/sdl2-prefix.
      - name: Cross-build lean SDL2 (armhf)
        run: |
          docker run --rm -v "$PWD:/src" -w /src solarus-armhf-build:bullseye \
            scripts/build_sdl2.sh

      # LuaJIT host tools run under qemu — register the armhf binfmt handler.
      - name: Register armhf binfmt
        run: docker run --rm --privileged tonistiigi/binfmt --install arm

      - name: Cross-build LuaJIT (armhf)
        run: |
          docker run --rm -v "$PWD:/src" -w /src solarus-armhf-build:bullseye \
            scripts/build_luajit.sh

      - name: Build ship engine (LuaJIT, no gprof)
        run: |
          docker run --rm \
            -e SOLARUS_USE_LUAJIT=1 \
            -v "$PWD:/src" -w /src solarus-armhf-build:bullseye \
            scripts/build_engine.sh

      - name: Collect runtime lib closure
        run: |
          docker run --rm -v "$PWD:/src" -w /src solarus-armhf-build:bullseye \
            scripts/collect_runtime_libs.sh

      - name: Verify ship build (NO mcount) + closure sane
        run: |
          docker run --rm -v "$PWD:/src" -w /src solarus-armhf-build:bullseye bash -c '
            set -e
            LIB=$(ls build/armhf/libsolarus.so* | head -1)
            echo "== engine artifacts =="; ls -la build/armhf/solarus-run "$LIB"
            if arm-linux-gnueabihf-objdump -d "$LIB" | grep -q mcount; then
              echo "ERROR: mcount found — this is a -pg build and MUST NOT ship" >&2
              exit 1
            fi
            echo "OK: no mcount (ship build)"'
          n=$(ls deploy/libs/*.so* 2>/dev/null | wc -l | tr -d " ")
          echo "lib closure count: $n"
          if [ "$n" -lt 20 ]; then echo "ERROR: closure too small ($n)" >&2; exit 1; fi

      # Flatten to a clean artifact tree: solarus-run at root, libs/ beside it.
      # Docker writes these world-readable (0644), so the runner user can cp them.
      - name: Stage engine artifact tree
        run: |
          rm -rf engine-out
          mkdir -p engine-out/libs
          cp build/armhf/solarus-run engine-out/solarus-run
          cp deploy/libs/*.so* engine-out/libs/
          ls -la engine-out engine-out/libs

      - name: Upload ship engine artifact
        uses: actions/upload-artifact@v4
        with:
          name: solarus-engine
          path: engine-out
          if-no-files-found: error
```

- [ ] **Step 2: Lint the workflow (YAML expressions + embedded bash)**

Run:
```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color .github/workflows/build-engine-ship.yml
```
Expected: exits 0 with no output. (`actionlint` bundles `shellcheck`, so the `run:` bash blocks are checked too.)

If `actionlint` is unavailable via Docker, fall back to shellcheck on the extracted script bodies (best-effort) and rely on the Step 4 GitHub dry-run as the authoritative gate.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build-engine-ship.yml
git commit -m "ci: add build-engine-ship — shippable armhf engine artifact"
```

- [ ] **Step 4: GitHub dry-run (authoritative validation — requires pushing the branch)**

```bash
git push -u origin HEAD
gh workflow run build-engine-ship.yml --ref "$(git branch --show-current)"
gh run watch "$(gh run list --workflow build-engine-ship.yml --limit 1 --json databaseId -q '.[0].databaseId')"
```
Expected: run succeeds; the run's artifacts include `solarus-engine`. Verify contents:
```bash
RID=$(gh run list --workflow build-engine-ship.yml --status success --limit 1 --json databaseId -q '.[0].databaseId')
gh run download "$RID" -n solarus-engine -D /tmp/engchk
file /tmp/engchk/solarus-run   # -> ELF 32-bit ... ARM
ls /tmp/engchk/libs/*.so* | wc -l   # -> >= 20
```
Expected: `solarus-run` is an ARM ELF; ≥ 20 libs.

---

### Task 2: `release.yml` — assemble SD-mirror zip + publish GitHub Release

**Files:**
- Create: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: the `solarus-rbf` artifact from `build-rbf.yml` (contains `Solarus_YYYYMMDD.rbf`); the `solarus-engine` artifact from Task 1 (contains `solarus-run` + `libs/*.so*`); the committed launch scripts under `games/Solarus/`, `scripts/Solarus.sh`, `docs/Solarus/README.md` from the tagged checkout.
- Produces: a GitHub Release at tag `<v*>` with asset `solarus-mister-<tag>.zip`.

- [ ] **Step 1: Write the workflow file**

Create `.github/workflows/release.yml`. **Note on heredocs:** the `_notes.md` and `PUT-QUESTS-HERE.txt` heredoc bodies below are written flush at the surrounding command indentation on purpose — after YAML block-scalar de-indenting they must have NO leading spaces (4+ leading spaces would turn markdown into a code block). Preserve the exact indentation shown.

```yaml
name: Release

# Assembles a MiSTer SD-mirror zip (extract to /media/fat/) and publishes it as
# a GitHub Release.
#
# Sources:
#   RBF     — latest successful `solarus-rbf` artifact from build-rbf.yml
#   engine  — latest successful `solarus-engine` artifact from build-engine-ship.yml
#   scripts — the committed launch scripts at the tagged commit (this checkout)
#
# Trigger: push a tag `v*` (primary), or run manually. If an artifact has aged
# past GitHub's ~90-day retention, re-run build-rbf / build-engine-ship, or pass
# the explicit run-id input.

on:
  push:
    tags:
      - 'v*'
  workflow_dispatch:
    inputs:
      tag:
        description: 'Release tag to create/target (e.g. v1.0.0). Ignored on tag-push.'
        type: string
        default: ''
      rbf_run_id:
        description: 'Explicit build-rbf run id (blank = latest success on master)'
        type: string
        default: ''
      engine_run_id:
        description: 'Explicit build-engine-ship run id (blank = latest success on master)'
        type: string
        default: ''
      prerelease:
        description: 'Mark the GitHub Release as a pre-release'
        type: boolean
        default: false

permissions:
  contents: write   # create the release
  actions: read     # list/download artifacts from other workflows

concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: false

jobs:
  release:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    env:
      GH_TOKEN: ${{ github.token }}
    steps:
      - uses: actions/checkout@v4

      - name: Resolve release tag
        id: tag
        run: |
          set -euo pipefail
          if [ "${{ github.event_name }}" = "push" ]; then
            TAG="${GITHUB_REF_NAME}"
          else
            TAG="${{ github.event.inputs.tag }}"
          fi
          if [ -z "$TAG" ]; then
            echo "ERROR: no tag — push a v* tag or pass the 'tag' input" >&2
            exit 1
          fi
          echo "tag=$TAG" >> "$GITHUB_OUTPUT"
          echo "Release tag: $TAG"

      - name: Download RBF artifact
        run: |
          set -euo pipefail
          RID="${{ github.event.inputs.rbf_run_id }}"
          if [ -z "$RID" ]; then
            RID=$(gh run list --workflow build-rbf.yml --branch master \
              --status success --limit 1 --json databaseId -q '.[0].databaseId')
          fi
          if [ -z "$RID" ] || [ "$RID" = "null" ]; then
            echo "ERROR: no successful build-rbf run found; re-run build-rbf or pass rbf_run_id" >&2
            exit 1
          fi
          echo "Using build-rbf run $RID"
          rm -rf _dl/rbf && mkdir -p _dl/rbf
          gh run download "$RID" -n solarus-rbf -D _dl/rbf
          ls -la _dl/rbf

      - name: Download engine artifact
        run: |
          set -euo pipefail
          RID="${{ github.event.inputs.engine_run_id }}"
          if [ -z "$RID" ]; then
            RID=$(gh run list --workflow build-engine-ship.yml --branch master \
              --status success --limit 1 --json databaseId -q '.[0].databaseId')
          fi
          if [ -z "$RID" ] || [ "$RID" = "null" ]; then
            echo "ERROR: no successful build-engine-ship run found; re-run it or pass engine_run_id" >&2
            exit 1
          fi
          echo "Using build-engine-ship run $RID"
          rm -rf _dl/engine && mkdir -p _dl/engine
          gh run download "$RID" -n solarus-engine -D _dl/engine
          ls -la _dl/engine _dl/engine/libs

      - name: Assemble SD-mirror tree
        run: |
          set -euo pipefail
          S=_stage
          rm -rf "$S"
          mkdir -p "$S/_Other" "$S/games/Solarus/libs" "$S/games/Solarus/quests" \
                   "$S/Scripts" "$S/docs/Solarus"
          cp _dl/rbf/Solarus_*.rbf "$S/_Other/"
          cp _dl/engine/solarus-run "$S/games/Solarus/solarus-run"
          cp _dl/engine/libs/*.so* "$S/games/Solarus/libs/"
          cp games/Solarus/_handler.sh games/Solarus/solarus_run.sh \
             games/Solarus/quest_manager.sh games/Solarus/quest_lib.sh \
             games/Solarus/core_watch.sh games/Solarus/solarus_daemon.sh \
             "$S/games/Solarus/"
          cp scripts/Solarus.sh "$S/Scripts/Solarus.sh"
          cp docs/Solarus/README.md "$S/docs/Solarus/README.md"
          cat > "$S/games/Solarus/quests/PUT-QUESTS-HERE.txt" <<'EOF'
          Drop your Solarus quest files (<name>.sol) into this folder, then pick one
          from the MiSTer OSD (Load Quest). See docs/Solarus/README.md and the project
          README "Getting quests" section for where to obtain quests.
          EOF
          rm -f "$S/games/Solarus/diag.env"
          echo "Assembled tree:"; find "$S" -maxdepth 3 | sort

      - name: Sanity gate
        run: |
          set -euo pipefail
          S=_stage
          n=$(ls "$S"/_Other/Solarus_*.rbf 2>/dev/null | wc -l | tr -d ' ')
          [ "$n" = "1" ] || { echo "ERROR: expected exactly 1 RBF, found $n" >&2; exit 1; }
          file "$S/games/Solarus/solarus-run" | grep -q ELF \
            || { echo "ERROR: solarus-run is not an ELF" >&2; exit 1; }
          libs=$(ls "$S"/games/Solarus/libs/*.so* 2>/dev/null | wc -l | tr -d ' ')
          [ "$libs" -ge 20 ] || { echo "ERROR: lib closure too small ($libs)" >&2; exit 1; }
          for s in _handler.sh solarus_run.sh quest_manager.sh quest_lib.sh \
                   core_watch.sh solarus_daemon.sh; do
            [ -f "$S/games/Solarus/$s" ] || { echo "ERROR: missing $s" >&2; exit 1; }
          done
          [ -f "$S/Scripts/Solarus.sh" ] || { echo "ERROR: missing Scripts/Solarus.sh" >&2; exit 1; }
          if grep -rlU "$(printf '\r')" "$S"/games/Solarus/*.sh "$S"/Scripts/*.sh 2>/dev/null; then
            echo "ERROR: CRLF found in a shell script" >&2; exit 1
          fi
          echo "Sanity gate passed: RBF=1, engine=ELF, libs=$libs"

      - name: Normalize exec bits
        run: |
          set -euo pipefail
          S=_stage
          chmod +x "$S"/games/Solarus/*.sh "$S"/Scripts/*.sh "$S/games/Solarus/solarus-run"

      - name: Zip
        id: zip
        run: |
          set -euo pipefail
          TAG="${{ steps.tag.outputs.tag }}"
          ZIP="solarus-mister-${TAG}.zip"
          ( cd _stage && zip -r "../${ZIP}" . )
          echo "zip=${ZIP}" >> "$GITHUB_OUTPUT"
          ls -la "${ZIP}"
          unzip -l "${ZIP}" | head -40

      - name: Write release-notes header
        run: |
          cat > _notes.md <<EOF
          ## Install

          1. Extract \`${{ steps.zip.outputs.zip }}\` to the root of your MiSTer SD card (\`/media/fat/\`). It merges into \`_Other/\`, \`games/Solarus/\`, and \`Scripts/\`.
          2. Put at least one quest (\`<name>.sol\`) into \`/media/fat/games/Solarus/quests/\`.
          3. Run **Solarus** from the MiSTer **Scripts** menu once (starts the auto-launch daemon + loads the core).
          4. Pick your quest from the OSD (**Load Quest**).

          Requires a **128 MB SDRAM expansion board**. See the [README](https://github.com/gmcnaught/solarus-mister#quick-install) for details and where to get quests.

          ---
          EOF

      - name: Publish GitHub Release
        run: |
          set -euo pipefail
          TAG="${{ steps.tag.outputs.tag }}"
          ZIP="${{ steps.zip.outputs.zip }}"
          PRE=""
          [ "${{ github.event.inputs.prerelease }}" = "true" ] && PRE="--prerelease"
          if gh release view "$TAG" >/dev/null 2>&1; then
            echo "Release $TAG exists — updating asset"
            gh release upload "$TAG" "$ZIP" --clobber
          else
            # --generate-notes appends the auto commit/PR changelog after the
            # install header from --notes-file. If a gh version rejects the combo,
            # drop --generate-notes.
            gh release create "$TAG" "$ZIP" \
              --title "Solarus MiSTer $TAG" \
              --notes-file _notes.md \
              --generate-notes $PRE
          fi
```

- [ ] **Step 2: Lint the workflow**

Run:
```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color .github/workflows/release.yml
```
Expected: exits 0, no output.

- [ ] **Step 3: Static assembly dry-run (validate the packaging shell WITHOUT GitHub)**

Simulate the assemble/sanity/zip steps locally using the real repo scripts + a fake RBF and a fake engine, to catch shell bugs before pushing. Run:
```bash
mkdir -p _dl/rbf _dl/engine/libs
: > _dl/rbf/Solarus_20260101.rbf
cp "$(command -v true)" _dl/engine/solarus-run   # any ELF stands in for the engine
for i in $(seq 1 22); do : > "_dl/engine/libs/libfake$i.so.0"; done
S=_stage; rm -rf "$S"
mkdir -p "$S/_Other" "$S/games/Solarus/libs" "$S/games/Solarus/quests" "$S/Scripts" "$S/docs/Solarus"
cp _dl/rbf/Solarus_*.rbf "$S/_Other/"
cp _dl/engine/solarus-run "$S/games/Solarus/solarus-run"
cp _dl/engine/libs/*.so* "$S/games/Solarus/libs/"
cp games/Solarus/_handler.sh games/Solarus/solarus_run.sh games/Solarus/quest_manager.sh \
   games/Solarus/quest_lib.sh games/Solarus/core_watch.sh games/Solarus/solarus_daemon.sh "$S/games/Solarus/"
cp scripts/Solarus.sh "$S/Scripts/Solarus.sh"; cp docs/Solarus/README.md "$S/docs/Solarus/README.md"
# sanity gate
ls "$S"/_Other/Solarus_*.rbf | wc -l                    # expect 1
file "$S/games/Solarus/solarus-run" | grep -q ELF && echo ELF-ok
ls "$S"/games/Solarus/libs/*.so* | wc -l                # expect >= 20
( cd _stage && zip -qr ../solarus-mister-v0.0.0-dry.zip . ) && unzip -l solarus-mister-v0.0.0-dry.zip | tail -5
# cleanup
rm -rf _dl _stage solarus-mister-v0.0.0-dry.zip
```
Expected: prints `1`, `ELF-ok`, a count `>= 20`, and a zip listing. No errors. (`true` is an ELF on Linux; on macOS it is Mach-O — run this step on the Linux CI dry-run in Step 5 if the local `file` check fails on macOS.)

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: add release workflow — SD-mirror zip + GitHub Release on v* tag"
```

- [ ] **Step 5: GitHub dry-run (authoritative — needs a real RBF + engine artifact present)**

Ensure a successful `build-rbf` run and the Task 1 `build-engine-ship` run both have live artifacts, then dispatch a pre-release:
```bash
git push
gh workflow run release.yml --ref "$(git branch --show-current)" \
  -f tag=v0.0.0-rc1 -f prerelease=true
gh run watch "$(gh run list --workflow release.yml --limit 1 --json databaseId -q '.[0].databaseId')"
gh release view v0.0.0-rc1
```
Expected: the release `v0.0.0-rc1` exists, marked pre-release, with `solarus-mister-v0.0.0-rc1.zip` attached. Download + inspect:
```bash
gh release download v0.0.0-rc1 -D /tmp/reldry
unzip -l /tmp/reldry/solarus-mister-v0.0.0-rc1.zip
```
Expected: tree shows `_Other/Solarus_*.rbf`, `games/Solarus/solarus-run`, `games/Solarus/libs/*.so*` (≥20), the six `.sh` scripts, `Scripts/Solarus.sh`, `docs/Solarus/README.md`, `games/Solarus/quests/PUT-QUESTS-HERE.txt`; NO `diag.env`.

- [ ] **Step 6: Clean up the dry-run release**

```bash
gh release delete v0.0.0-rc1 --cleanup-tag --yes
```

---

### Task 3: README — Download pointer to Releases

**Files:**
- Modify: `README.md` (Quick Install section)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing (docs only).

- [ ] **Step 1: Insert the Download pointer**

Edit `README.md`. Replace:

```markdown
## Quick Install

1. Copy the contents of the release zip to the root of your MiSTer SD card
```

with:

```markdown
## Quick Install

**Download:** grab the latest `solarus-mister-<version>.zip` from the
[**Releases**](https://github.com/gmcnaught/solarus-mister/releases/latest) page.
Releases are cut automatically from `v*` git tags by CI and bundle the FPGA core,
the engine, and the launch scripts.

1. Copy the contents of the release zip to the root of your MiSTer SD card
```

- [ ] **Step 2: Verify the edit reads correctly**

Run:
```bash
sed -n '19,34p' README.md
```
Expected: the new **Download** paragraph appears immediately under `## Quick Install`, before numbered step 1, and the numbered list still starts at 1.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: point Quick Install at the GitHub Releases page"
```

---

## Self-Review

**Spec coverage:**
- `build-engine-ship.yml` (ship engine, LuaJIT, no `-pg`, lib closure, artifact) → Task 1. ✓
- `release.yml` triggers (`v*` + dispatch), artifact reuse with run-id override, SD-mirror assembly per `deploy.py`, sanity gate, zip (no `-y`), `gh release create --generate-notes` with clobber-on-rerun → Task 2. ✓
- Engine-only / `PUT-QUESTS-HERE.txt`, no `diag.env` → Task 2 assemble step. ✓
- README Download pointer → Task 3. ✓
- Existing workflows untouched → no task modifies them. ✓
- Out-of-scope items (no update_all, no bundled quest, no inline rebuild) → honored. ✓

**Placeholder scan:** No TBD/TODO; every `run:` block is complete; the exact YAML is provided in full.

**Type/name consistency:** Artifact name `solarus-engine` (produced Task 1, consumed Task 2) and `solarus-rbf` (from existing `build-rbf.yml`) match. Artifact internal layout `solarus-run` + `libs/*.so*` is produced by Task 1's stage step and consumed by Task 2's assemble step identically. Zip name `solarus-mister-<tag>.zip` is consistent between the Zip step, the notes header, and Task 3's README copy (`solarus-mister-<version>.zip`).
