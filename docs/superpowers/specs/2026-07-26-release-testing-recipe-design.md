# Release testing recipe — design

**Date:** 2026-07-26
**Status:** approved (design), not yet implemented
**Topic:** a repeatable, mostly-scripted procedure for validating a release
candidate before publishing it.

## Problem

`release.yml` has shipped two releases (v1.0.0, v1.0.1) with no defined test
procedure between "assemble the zip" and "publish it". Three specific gaps make
an untested publish risky:

1. **The zip is anonymous.** Neither `build-engine-ship` nor `build-rbf` records
   the commit it built from, and the release zip carries no manifest. Nothing in
   the published artifact says which commit, which run, or which engine/RBF pair
   it contains.
2. **The zip is not provably master.** `release.yml` resolves both artifacts as
   *latest successful run on master*, independent of the tagged commit.
3. **What you test need not be what you publish.** If master moves between the
   RC tag and the release tag, a tag-push re-resolves "latest successful" and can
   publish different binaries than the ones that passed.

Underneath all three sits an unguarded hazard the recipe can detect but not
prevent: **the engine and RBF are a matched pair with no version handshake.**
Pairing this engine with a pre-ring-dbuf bitstream yields silently garbage tiles
in either flag direction (`OFF_HEAP` moved unconditionally; see `CLAUDE.md`).
The device currently has four loadable `_Other/Solarus_*.rbf` files, so this is
not hypothetical.

## Flow

```
master ──► tag vX.Y.Z-rc1 ──► release.yml (auto --prerelease via the hyphen rule)
                                    │
                                    ▼
                         GATE 1  provenance + structure   (host,   scripted)
                         GATE 2  install + boot + soak    (device, scripted)
                         GATE 3  operator visual gate     (human eyes)
                                    │
                              all PASS
                                    ▼
              publish vX.Y.Z ── workflow_dispatch with PINNED run-ids ──►
                                    │
                                    ▼
                         GATE 4  post-publish identity    (host,   scripted)
```

Gates 1, 2 and 4 are executable and exit non-zero on any FAIL. Gate 3 is
deliberately human: this project's standing rule is that visual correctness is
never self-declared by the assistant.

## Deliverables

| File | Role |
|---|---|
| `docs/release-testing.md` | The operator-facing recipe: flow, the four gates, the visual checklist, the sign-off template |
| `scripts/release_test.sh` | Executable Gates 1, 2, 4; prints a PASS/FAIL table |
| `.github/workflows/release.yml` | New step writing `BUILD-INFO.txt` into the zip; sanity gate asserts it exists and parses |
| `tests/release_test_test.sh` | Host test of the pure checks against synthetic trees; registered in `tests/run_tests.sh` |
| `docs/superpowers/releases/<tag>-rc-test.md` | Per-release sign-off record, mirroring the `*-hw-validation.md` convention |

## BUILD-INFO.txt

Written by `release.yml` at assembly time into the zip root. Flat `key=value`,
one per line, so `sh` can parse it without tooling:

```
tag=v1.1.0-rc1
commit=<40-hex sha of the tagged commit>
built_utc=2026-07-26T22:00:00Z
rbf_run_id=<id>
rbf_head_sha=<40-hex>
rbf_file=Solarus_20260726.rbf
engine_run_id=<id>
engine_head_sha=<40-hex>
sha256_rbf=<hex>
sha256_solarus_run=<hex>
sha256_libsolarus=<hex>
```

The head shas come from `gh run view "$RID" --json headSha -q .headSha`, which
`release.yml` already has the token and `gh` to call. The zip's own sha256 is
deliberately absent (it cannot be inside itself); the release page's asset digest
covers that.

`release.yml`'s existing sanity gate gains one assertion: `BUILD-INFO.txt` exists
and contains all eleven keys with non-empty values.

## Gate 1 — provenance + structure (host)

Downloads the RC asset, extracts to `_rc/<tag>/` (gitignored), then asserts:

### Provenance — a staleness check, not an equality check

Both artifact workflows are **path-filtered**:

- `build-rbf` — `fpga/**`, excluding `fpga/sim/**`, `fpga/scripts/**`,
  `fpga/docs/**`, plus its own workflow file.
- `build-engine-ship` — `patches/**`, `scripts/build_engine.sh`,
  `scripts/build_luajit.sh`, `scripts/build_sdl2.sh`,
  `scripts/collect_runtime_libs.sh`, `Dockerfile.solarus-build`, plus its own
  workflow file.

So a release commit touching only docs or launch scripts runs neither workflow,
and `head_sha == tagged commit` is **false for most legitimate releases**.
Asserting equality would produce a rule that is routinely bypassed, which is
worse than no rule.

The correct assertion is that each artifact is *current with respect to the tag*:

1. `head_sha` is an **ancestor of** (or equal to) the tagged commit —
   `git merge-base --is-ancestor <head_sha> <tag>`.
2. `git diff --name-only <head_sha>..<tag>` touches **none** of that workflow's
   own trigger paths.
3. The tag itself is an ancestor of (or equal to) `origin/master` — catches
   tagging a side branch.

Together these mean: *no un-built input change exists between the artifact's
commit and the tag.* That is the operative meaning of "the RC is master".

To keep the two glob lists from drifting out of sync with the workflows, Gate 1
**parses `on.push.paths` out of each workflow YAML** rather than holding a copy.
Parsing is done in Python 3 (present on the host and in CI); a parse failure is a
FAIL, never a silent skip.

### Structure

- Exactly one `_Other/Solarus_*.rbf`.
- `solarus-run` is a 32-bit ARM EABI5 ELF.
- `libs/` holds ≥20 `.so*` files, including **both** `libsolarus.so.1` and
  `libsolarus.so.1.6.5` as **real files** — FAT cannot carry the build tree's
  symlink, and the release step already materialises both.
- Present: `_handler.sh`, `solarus_run.sh`, `quest_manager.sh`, `quest_lib.sh`,
  `core_watch.sh`, `solarus_daemon.sh`, `controls.cfg.default`,
  `Scripts/Solarus.sh`, `docs/Solarus/README.md`.
- No CRLF in any shipped shell script; no `._*` or `__MACOSX` AppleDouble
  entries; exec bits set on the scripts and the engine.
- `version.txt` at the tagged commit names the same RBF file as `rbf_file`.

The software-only invariant (no `libGL` / `GLEW` / `EGL` DT_NEEDED) is checked
in **Gate 2**, not here: macOS does not ship `readelf`, and the device already
has a proven `ldd` check that `deploy.py` performs on every deploy. Putting it
on the device avoids a host toolchain dependency for a release gate.

### Output

Records `rbf_run_id` and `engine_run_id` into the sign-off report. These are the
pins used at publish time.

## Gate 2 — install + boot + soak (device)

Runs over SSH against `192.168.20.81` (overridable). All device gotchas from
`CLAUDE.md` apply: busybox has no `pkill`; FAT cannot overwrite an open exe or
chown; FAT is case-insensitive.

1. **Preflight.** Assert at most one `solarus-run` alive, then
   `kill -9 $(pidof solarus-run)` plus the daemon; confirm none remain. Two
   engines on the fabric wedge the host.
2. **Preserve.** Copy `quests/*.sol` and `controls.cfg` aside on the card.
3. **Wipe.** Remove `games/Solarus/`, **all** `_Other/Solarus_*.rbf`,
   `Scripts/Solarus.sh`, `config/Solarus.s0`, `config/Solarus_input.map`.
   Wiping every RBF is what collapses the multi-core ambiguity into the single
   core under test, and what makes a file missing from the zip fail loudly
   instead of being masked by a leftover dev deploy.
4. **Extract.** `scp` the zip to the card, `unzip -o -d /media/fat` (device has
   `/usr/bin/unzip`), restore quests and `controls.cfg`.
5. **Verify installed.** Device-side `sha256sum` of `solarus-run`,
   `libsolarus.so.1.6.5`, and the RBF match `BUILD-INFO`; exactly one RBF
   present.
6. **Link probe.** `solarus-run -help` under the deploy env exits clean —
   catches a missing or ABI-incompatible `.so`. The same step asserts `ldd`
   reports no `libGL`, `GLEW`, or `EGL` DT_NEEDED (the software-only
   invariant).
7. **Launch** by the known-safe recipe: leave `Solarus.s0` empty, load the core,
   launch with the `S0_FILE` override, detached
   (`setsid … >/media/fat/logs/rc-<tag>.log 2>&1 </dev/null &`) so it survives
   SSH disconnect. Log to `/media/fat/logs`, not `/tmp`.
8. **Log asserts.**
   - Required: `renderer active (DDR @`, `ring double-buffer ENABLED`,
     `tilemap channel ENABLED`, loading-bar progression.
   - Forbidden: `video-region map failed`, `reverting to SDL`,
     `pass-through SDLRenderer`, `scene_too_big`, ring overflow, any
     dropped-command counter above zero, any segfault.
9. **fps floor.** Sample `busybox devmem 0x3A000000 >> 2` deltas for 30 s. The
   scripted leg cannot drive gameplay, so it measures the **title screen**,
   which has measured ~57 fps; the gate asserts **≥ 45 fps** — low enough not to
   flap on scheduling noise, high enough to catch a gross regression such as a
   fallback to the SDL path. The actual figure is **recorded** in the report so
   releases stay comparable over time. Gameplay fps is not gated here; it is
   covered by the per-change hw-validation records.
10. **Soak.** 10 minutes by default (`--soak-min`); engine still alive, frame
    counter still advancing, log still clean.

## Gate 3 — operator visual gate

Scripted checks assert nothing about visual correctness. Eight items, in order;
item 1 is the pairing canary:

1. Title screen renders clean — **garbage tiles here means the wrong RBF**.
2. OSD **Load Quest** boots each installed quest (MoSDX, Patched Tunics,
   ROTH SE).
3. Loading bar advances during preload.
4. Overworld walk — no seams, flat frames, or garbage.
5. Dialog box renders and dismisses.
6. Save-file select and in-game menu render.
7. **Define buttons** once — the eight-name OSD rename invalidates any prior
   `Solarus_input.map` — then all buttons act per `controls.cfg`.
8. Quest switch and core reload without a wedge.

Each is recorded PASS/FAIL with the operator's initials in the sign-off report.
Any FAIL stops the release.

## Publish step

Publishing is a `workflow_dispatch` of `release.yml` with `tag=vX.Y.Z` and
`rbf_run_id` / `engine_run_id` **pinned to the values Gate 1 recorded** — never
a blind tag push, which would re-resolve "latest successful" and could ship
untested binaries. `scripts/release_test.sh` prints the exact `gh workflow run`
command with the pins substituted, so the operator copies rather than retypes.

## Gate 4 — post-publish identity (host)

Downloads the published `vX.Y.Z` asset and asserts:

- Its `BUILD-INFO` `rbf_run_id` and `engine_run_id` equal the RC's.
- `sha256_rbf`, `sha256_solarus_run`, `sha256_libsolarus` are identical to the
  RC's — the published payload is byte-for-byte what passed Gates 2 and 3.
- Exactly one RBF.
- The release is marked Latest and is not a pre-release.

## Script interface

```
scripts/release_test.sh gate1 <rc-tag> [--zip PATH]
scripts/release_test.sh gate2 <rc-tag> [--host IP] [--soak-min N]
scripts/release_test.sh gate4 <release-tag> --rc <rc-tag>
scripts/release_test.sh all   <rc-tag>   [--host IP]
```

Working state lives in `_rc/<tag>/` (gitignored): the downloaded zip, the
extracted tree, the parsed manifest, and a `results.tsv` the report is rendered
from. Each gate prints a PASS/FAIL table and exits non-zero if any row failed.
Gates are independently runnable so a single failure can be re-checked without
repeating the whole sequence.

## Testing the recipe itself

`tests/release_test_test.sh` follows the existing shell-test pattern
(`core_watch_test.sh`, `quest_manager_test.sh`) and covers the pure, host-side
logic against synthetic trees — no device, no network:

- Manifest parse: well-formed, missing key, empty value, trailing CR.
- Structure asserts: each one made to fail in isolation (two RBFs; `libsolarus.so.1`
  a symlink rather than a real file; a missing script; a CRLF script; an
  AppleDouble entry; a short lib closure).
- Provenance logic: given a synthetic git history, an artifact commit that is
  current PASSes, one with an intervening change to its own trigger paths FAILs,
  and one with an intervening change to *unrelated* paths PASSes.
- Workflow-glob parsing: the globs extracted from the real workflow files are
  non-empty, and a malformed YAML fixture FAILs rather than silently yielding an
  empty list.

## Deliberately out of scope

- **A fabric version handshake.** Control-block offset 7 is free and could carry
  an RTL version word that the engine checks at startup, turning a silent
  garbage-tile mismatch into a loud refusal. That is a product change requiring
  an RBF rebuild and a bootstrap story for old bitstreams (which read undefined
  values). It belongs in its own issue; this recipe only *detects* mismatch, via
  Gate 2's single-RBF assertion and Gate 3's title-screen canary.
- Automating Gate 3. Visual correctness is human-judged in this project.
- Testing quest content itself; quests are user-supplied and separately licensed.

## Expected first-failure mode

The most common Gate 1 failure will be a tag pushed before
`build-rbf` / `build-engine-ship` have gone green for a commit that *did* touch
their trigger paths. The remedy is to wait for those runs, then re-dispatch
`release.yml` with the now-current run-ids pinned — not to relax the assertion.
The failure message states this explicitly.
