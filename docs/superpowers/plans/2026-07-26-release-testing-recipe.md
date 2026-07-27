# Release Testing Recipe Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a four-gate, mostly-scripted procedure that validates a release candidate zip against master on real hardware before the release is published.

**Architecture:** `release.yml` gains a `BUILD-INFO.txt` manifest written into the zip. `scripts/release_test.sh` is a thin CLI dispatcher over pure shell functions in `scripts/lib/release_check.sh`, which emit TSV result rows so the host suite can assert on them without a device or network. Provenance is a *staleness* check driven by git pathspecs derived from each build workflow's own `on.push.paths` list, parsed by `scripts/lib/wf_pathspec.py`.

**Tech Stack:** POSIX `sh` (device is busybox 1.33.1), Python 3 (host + CI runner; **no third-party modules — PyYAML is NOT available**), `git`, `gh` CLI, `ssh`/`scp`.

**Spec:** `docs/superpowers/specs/2026-07-26-release-testing-recipe-design.md`

## Global Constraints

- **Device is busybox 1.33.1.** No `pkill`. `pidof` has no `-x` (won't match a script) — match script names with a `[x]`-style `ps | grep`. Device has `/usr/bin/unzip` and `/usr/bin/sha256sum`.
- **Device FAT rules.** Cannot overwrite an open executable in place. Cannot chown. Is **case-insensitive** (`games/solarus` == `games/Solarus`). Cannot store symlinks — `libsolarus.so.1` and `libsolarus.so.1.6.5` must both be real files.
- **Never run two engines.** Two `solarus-run` processes on the fabric wedge the host. Kill the daemon *and* `quest_manager.sh` before any scripted launch.
- **Device logs go to `/media/fat/logs`**, never `/tmp`.
- **Detached launch** must be `setsid ... >LOG 2>&1 </dev/null &` — stdin off the tty — so the engine survives SSH disconnect.
- **Host script portability:** must run on macOS. Do **not** use `readelf`, `pkill`, GNU-only `sed -i`, or `grep -P`.
- **Result row format is fixed:** `STATUS<TAB>GATE<TAB>CHECK<TAB>DETAIL`, `STATUS` ∈ {`PASS`,`FAIL`}. Every check emits exactly one row.
- **Default device host:** `192.168.20.81`, user `root`, key-authed.
- **Never assert visual correctness from a script.** Gate 3 is human-judged.

---

### Task 1: BUILD-INFO.txt manifest in the release zip

**Files:**
- Modify: `.github/workflows/release.yml` (new step after "Download engine artifact", ~line 100; extend "Sanity gate", ~line 129)
- Test: `tests/release_manifest_test.sh` (create)

**Interfaces:**
- Produces: a `BUILD-INFO.txt` at the zip root with exactly these 11 keys, one `key=value` per line, no spaces around `=`:
  `tag`, `commit`, `built_utc`, `rbf_run_id`, `rbf_head_sha`, `rbf_file`, `engine_run_id`, `engine_head_sha`, `sha256_rbf`, `sha256_solarus_run`, `sha256_libsolarus`.
- Produces: the two `Download …` steps must now export their resolved run id so a later step can read it — `echo "rid=$RID" >> "$GITHUB_OUTPUT"` with step ids `rbf` and `engine`.

- [ ] **Step 1: Write the failing test**

This test does not run CI. It extracts the manifest-writing shell body from the workflow, runs it against a synthetic tree, and asserts the output shape. Create `tests/release_manifest_test.sh`:

```sh
#!/bin/sh
# Host test for the BUILD-INFO.txt manifest written by .github/workflows/release.yml.
# Runs the same key list + emission shape against a synthetic staging tree.
set -u
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
ROOT="$HERE/.."
TMP=$(mktemp -d)
fails=0
ok()  { echo "  PASS $1"; }
bad() { echo "  FAIL $1"; fails=$((fails+1)); }

echo "== release_manifest (BUILD-INFO.txt shape) =="

# Synthetic staging tree mirroring release.yml's $S layout.
S="$TMP/_stage"
mkdir -p "$S/_Other" "$S/games/Solarus/libs"
printf 'rbfbytes'    > "$S/_Other/Solarus_20260726.rbf"
printf 'enginebytes' > "$S/games/Solarus/solarus-run"
printf 'libbytes'    > "$S/games/Solarus/libs/libsolarus.so.1.6.5"

# The manifest body, byte-identical to the workflow step (see release.yml
# "Write BUILD-INFO manifest"). Inputs arrive as env vars there; same here.
TAG=v9.9.9-rc1 COMMIT=$(printf 'c%039d' 1) \
RBF_RID=111 RBF_SHA=$(printf 'r%039d' 1) \
ENG_RID=222 ENG_SHA=$(printf 'e%039d' 1) \
BUILT_UTC=2026-07-26T00:00:00Z \
sh "$ROOT/.github/workflows/build-info.sh" "$S" > "$TMP/out.log" 2>&1 \
  || bad "manifest script exited non-zero"

M="$S/BUILD-INFO.txt"
[ -f "$M" ] && ok "T1 manifest written" || bad "T1 manifest missing"

for k in tag commit built_utc rbf_run_id rbf_head_sha rbf_file \
         engine_run_id engine_head_sha sha256_rbf sha256_solarus_run \
         sha256_libsolarus; do
  v=$(sed -n "s/^$k=//p" "$M")
  [ -n "$v" ] && ok "T2 $k present" || bad "T2 $k missing/empty"
done

n=$(wc -l < "$M" | tr -d ' ')
[ "$n" = "11" ] && ok "T3 exactly 11 lines" || bad "T3 line count $n != 11"

[ "$(sed -n 's/^rbf_file=//p' "$M")" = "Solarus_20260726.rbf" ] \
  && ok "T4 rbf_file is the basename" || bad "T4 rbf_file wrong"

want=$(printf 'enginebytes' | shasum -a 256 | awk '{print $1}')
[ "$(sed -n 's/^sha256_solarus_run=//p' "$M")" = "$want" ] \
  && ok "T5 engine sha256 correct" || bad "T5 engine sha256 wrong"

# A second RBF must fail loudly rather than pick one arbitrarily.
printf 'x' > "$S/_Other/Solarus_20260727.rbf"
TAG=v9.9.9-rc1 COMMIT=x RBF_RID=1 RBF_SHA=x ENG_RID=2 ENG_SHA=x \
BUILT_UTC=z sh "$ROOT/.github/workflows/build-info.sh" "$S" >/dev/null 2>&1 \
  && bad "T6 two RBFs accepted" || ok "T6 two RBFs rejected"

rm -rf "$TMP"
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "FAILURES: $fails"; exit 1; fi
```

- [ ] **Step 2: Run it to verify it fails**

Run: `sh tests/release_manifest_test.sh`
Expected: FAIL — `.github/workflows/build-info.sh: No such file or directory`, non-zero exit.

- [ ] **Step 3: Create the manifest script**

Extracting the body to a real script (rather than inlining it in YAML) is what makes it testable. Create `.github/workflows/build-info.sh`:

```sh
#!/bin/sh
# Write BUILD-INFO.txt into a staged SD-mirror tree.
#
# Usage: build-info.sh <stage-dir>
# Inputs via env: TAG COMMIT BUILT_UTC RBF_RID RBF_SHA ENG_RID ENG_SHA
#
# Called by .github/workflows/release.yml and exercised by
# tests/release_manifest_test.sh, so the shipped manifest and the tested
# manifest are the same code.
set -eu
S="${1:?usage: build-info.sh <stage-dir>}"

: "${TAG:?}" "${COMMIT:?}" "${BUILT_UTC:?}" "${RBF_RID:?}" "${RBF_SHA:?}"
: "${ENG_RID:?}" "${ENG_SHA:?}"

n=$(find "$S/_Other" -maxdepth 1 -type f -name 'Solarus_*.rbf' | wc -l | tr -d ' ')
[ "$n" = "1" ] || { echo "ERROR: expected exactly 1 RBF, found $n" >&2; exit 1; }
RBF=$(find "$S/_Other" -maxdepth 1 -type f -name 'Solarus_*.rbf')

# shasum is present on both macOS and ubuntu-latest; sha256sum is not on macOS.
sha() { shasum -a 256 "$1" | awk '{print $1}'; }

{
  echo "tag=$TAG"
  echo "commit=$COMMIT"
  echo "built_utc=$BUILT_UTC"
  echo "rbf_run_id=$RBF_RID"
  echo "rbf_head_sha=$RBF_SHA"
  echo "rbf_file=$(basename "$RBF")"
  echo "engine_run_id=$ENG_RID"
  echo "engine_head_sha=$ENG_SHA"
  echo "sha256_rbf=$(sha "$RBF")"
  echo "sha256_solarus_run=$(sha "$S/games/Solarus/solarus-run")"
  echo "sha256_libsolarus=$(sha "$S/games/Solarus/libs/libsolarus.so.1.6.5")"
} > "$S/BUILD-INFO.txt"

echo "BUILD-INFO.txt:"; cat "$S/BUILD-INFO.txt"
```

Then `chmod +x .github/workflows/build-info.sh`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `sh tests/release_manifest_test.sh`
Expected: `ALL PASS`, exit 0.

- [ ] **Step 5: Wire it into release.yml**

In `.github/workflows/release.yml`, give the two download steps ids and export their run ids. Change the RBF step header from `- name: Download RBF artifact` to:

```yaml
      - name: Download RBF artifact
        id: rbf
```

and append to that step's `run:` block, after `ls -la _dl/rbf`:

```bash
          echo "rid=$RID" >> "$GITHUB_OUTPUT"
          echo "sha=$(gh run view "$RID" --json headSha -q .headSha)" >> "$GITHUB_OUTPUT"
```

Do the same for the engine step (`id: engine`, appended after `ls -la _dl/engine _dl/engine/libs`).

Then insert a new step immediately **after** "Assemble SD-mirror tree" and **before** "Sanity gate":

```yaml
      - name: Write BUILD-INFO manifest
        env:
          TAG: ${{ steps.tag.outputs.tag }}
          COMMIT: ${{ github.sha }}
          RBF_RID: ${{ steps.rbf.outputs.rid }}
          RBF_SHA: ${{ steps.rbf.outputs.sha }}
          ENG_RID: ${{ steps.engine.outputs.rid }}
          ENG_SHA: ${{ steps.engine.outputs.sha }}
        run: |
          set -euo pipefail
          BUILT_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
            sh .github/workflows/build-info.sh _stage
```

- [ ] **Step 6: Extend the sanity gate**

In the "Sanity gate" step, insert before the final `echo "Sanity gate passed: …"`:

```bash
          M="$S/BUILD-INFO.txt"
          [ -f "$M" ] || { echo "ERROR: BUILD-INFO.txt missing" >&2; exit 1; }
          for k in tag commit built_utc rbf_run_id rbf_head_sha rbf_file \
                   engine_run_id engine_head_sha sha256_rbf \
                   sha256_solarus_run sha256_libsolarus; do
            v=$(sed -n "s/^$k=//p" "$M")
            [ -n "$v" ] || { echo "ERROR: BUILD-INFO.txt key '$k' missing/empty" >&2; exit 1; }
          done
          echo "BUILD-INFO.txt: 11/11 keys present"
```

- [ ] **Step 7: Register the test and run the suite**

Add to `tests/run_tests.sh`, after the `sh tests/solarus_daemon_test.sh` line:

```bash
sh tests/release_manifest_test.sh
```

Run: `bash tests/run_tests.sh`
Expected: ends with `All host tests passed.`

- [ ] **Step 8: Commit**

```bash
git add .github/workflows/release.yml .github/workflows/build-info.sh \
        tests/release_manifest_test.sh tests/run_tests.sh
git commit -m "feat(release): write BUILD-INFO.txt manifest into the release zip

Records tag, tagged commit, both artifact run-ids + their headSha, the RBF
filename, and sha256 of the three payload files. Extracted to a standalone
script so the shipped manifest and the tested manifest are the same code."
```

---

### Task 2: Gate 1 — manifest, structure, and provenance

This task ships **all of Gate 1** in four commits (A–D). It is one task, not
three, because a driver committed before its gate functions exist would leave
`release_test.sh gate1` dying with `gate1: not found` — every commit must work.
The commits are ordered so that never happens: the library lands first, and the
driver lands **last**, complete.

- **A** — result-row plumbing + manifest parsing (Steps 1–7)
- **B** — structural checks (Steps 8–12)
- **C** — provenance: pathspec parser + staleness (Steps 13–21)
- **D** — the `release_test.sh` driver, with `gate1` fully wired (Steps 22–25)

**Files:**
- Create: `scripts/lib/release_check.sh`
- Create: `scripts/lib/wf_pathspec.py`
- Create: `scripts/release_test.sh`
- Create: `tests/release_test_test.sh`
- Modify: `.gitignore`
- Modify: `tests/run_tests.sh`

---

#### Part A — result-row plumbing + manifest parsing

**Interfaces:**
- Consumes: the 11-key `BUILD-INFO.txt` from Task 1.
- Produces (sourced by later tasks and by the test):
  - `rc_pass GATE CHECK [DETAIL]` / `rc_fail GATE CHECK [DETAIL]` — print one TSV row.
  - `rc_get MANIFEST KEY` → value on stdout, CR-stripped, empty if absent.
  - `rc_manifest_check MANIFEST` → one row per key issue, or a single PASS row `manifest keys`.
  - `RC_KEYS` — space-separated list of the 11 key names.
- Produces: `scripts/release_test.sh <gate1|gate2|gate4|all> …`, exiting non-zero if any emitted row is `FAIL`.

- [ ] **Step 1: Write the failing test**

Create `tests/release_test_test.sh`:

```sh
#!/bin/sh
# Host test for scripts/lib/release_check.sh — the pure, device-free half of
# the release-test gates. No network, no SSH, no gh.
set -u
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
ROOT="$HERE/.."
. "$ROOT/scripts/lib/release_check.sh"
TMP=$(mktemp -d)
fails=0
ok()  { echo "  PASS $1"; }
bad() { echo "  FAIL $1"; fails=$((fails+1)); }
# rows_fail <file> -> 0 if any FAIL row present
rows_fail() { grep -q '^FAIL' "$1"; }

echo "== release_check (release-test gate logic) =="

mkmanifest() {  # <path> [key-to-omit]
  omit="${2:-}"
  : > "$1"
  for k in $RC_KEYS; do
    [ "$k" = "$omit" ] && continue
    echo "$k=val_$k" >> "$1"
  done
}

# --- rc_get ---------------------------------------------------------------
mkmanifest "$TMP/m.txt"
[ "$(rc_get "$TMP/m.txt" tag)" = "val_tag" ] \
  && ok "T1 rc_get reads a key" || bad "T1 rc_get wrong"
[ -z "$(rc_get "$TMP/m.txt" nosuch)" ] \
  && ok "T2 rc_get empty for absent key" || bad "T2 rc_get not empty"

# CRLF tolerance: a manifest round-tripped through a FAT/Windows path.
mkmanifest "$TMP/crlf.txt"
awk '{printf "%s\r\n", $0}' "$TMP/crlf.txt" > "$TMP/crlf2.txt"
[ "$(rc_get "$TMP/crlf2.txt" commit)" = "val_commit" ] \
  && ok "T3 rc_get strips CR" || bad "T3 rc_get kept CR"

# --- rc_manifest_check ----------------------------------------------------
rc_manifest_check "$TMP/m.txt" > "$TMP/r1"
rows_fail "$TMP/r1" && bad "T4 complete manifest failed" || ok "T4 complete manifest passes"

mkmanifest "$TMP/miss.txt" engine_head_sha
rc_manifest_check "$TMP/miss.txt" > "$TMP/r2"
rows_fail "$TMP/r2" && ok "T5 missing key detected" || bad "T5 missing key not detected"
grep -q 'engine_head_sha' "$TMP/r2" \
  && ok "T5b names the missing key" || bad "T5b does not name the key"

mkmanifest "$TMP/empty.txt"
sed 's/^tag=.*/tag=/' "$TMP/empty.txt" > "$TMP/empty2.txt"
rc_manifest_check "$TMP/empty2.txt" > "$TMP/r3"
rows_fail "$TMP/r3" && ok "T6 empty value detected" || bad "T6 empty value not detected"

rc_manifest_check "$TMP/does-not-exist.txt" > "$TMP/r4" 2>/dev/null
rows_fail "$TMP/r4" && ok "T7 absent manifest is a FAIL row" || bad "T7 absent manifest not failed"

# --- row format -----------------------------------------------------------
rc_pass gate1 somecheck "detail here" > "$TMP/r5"
[ "$(awk -F'\t' 'NR==1{print NF}' "$TMP/r5")" = "4" ] \
  && ok "T8 row has 4 tab fields" || bad "T8 row field count wrong"
[ "$(awk -F'\t' 'NR==1{print $1}' "$TMP/r5")" = "PASS" ] \
  && ok "T8b status field first" || bad "T8b status field wrong"

rm -rf "$TMP"
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "FAILURES: $fails"; exit 1; fi
```

- [ ] **Step 2: Run it to verify it fails**

Run: `sh tests/release_test_test.sh`
Expected: FAIL — `scripts/lib/release_check.sh: No such file or directory`.

- [ ] **Step 3: Write the library**

Create `scripts/lib/release_check.sh`:

```sh
# Pure helpers for the release-test gates. Sourced, never executed.
#
# Every check emits exactly one TSV row on stdout:
#   STATUS<TAB>GATE<TAB>CHECK<TAB>DETAIL
# so the driver can tee them to results.tsv and the host test can assert on
# them without a device, a network, or gh.

RC_KEYS="tag commit built_utc rbf_run_id rbf_head_sha rbf_file engine_run_id engine_head_sha sha256_rbf sha256_solarus_run sha256_libsolarus"

rc_pass() { printf 'PASS\t%s\t%s\t%s\n' "$1" "$2" "${3:-}"; }
rc_fail() { printf 'FAIL\t%s\t%s\t%s\n' "$1" "$2" "${3:-}"; }

# rc_get <manifest> <key> -> value on stdout ('' if absent)
# tr strips CR first: a manifest that has been through FAT or a Windows editor
# would otherwise yield values with a trailing \r that compare unequal.
rc_get() {
    [ -f "$1" ] || return 0
    tr -d '\r' < "$1" | sed -n "s/^$2=//p" | head -1
}

# rc_manifest_check <manifest> -> rows
rc_manifest_check() {
    _m="$1"
    if [ ! -f "$_m" ]; then
        rc_fail gate1 "manifest present" "no BUILD-INFO.txt at $_m"
        return 0
    fi
    _bad=""
    for _k in $RC_KEYS; do
        [ -n "$(rc_get "$_m" "$_k")" ] || _bad="$_bad $_k"
    done
    if [ -n "$_bad" ]; then
        rc_fail gate1 "manifest keys" "missing/empty:$_bad"
    else
        rc_pass gate1 "manifest keys" "11/11 present"
    fi
}
```

The driver that consumes these helpers is **not** created here — it lands in
Part D, complete, so no commit ever ships a CLI with dangling calls.

- [ ] **Step 4: Ignore the work directory**

Append to `.gitignore`, under the existing "Scratch, build output" group:

```
# release_test.sh working state (downloaded RC zip, extracted tree, results)
_rc/
```

- [ ] **Step 5: Register the test and run it**

Add to `tests/run_tests.sh`, after the `sh tests/release_manifest_test.sh` line:

```bash
sh tests/release_test_test.sh
```

Run: `sh tests/release_test_test.sh`
Expected: `ALL PASS`, exit 0.

- [ ] **Step 6: Commit (A)**

```bash
git add scripts/lib/release_check.sh tests/release_test_test.sh \
        tests/run_tests.sh .gitignore
git commit -m "feat(release): release-check library — result rows + manifest parsing

Pure gate logic emitting TSV result rows, so the host suite can assert on it
with no device, network, or gh."
```

---

#### Part B — structural checks

**Interfaces:**
- Consumes: `rc_pass` / `rc_fail` / `rc_get` from Part A.
- Produces: `rc_structure_check <extracted-root> <manifest>` → one row per structural check.

Steps restart at 1 within each Part.

- [ ] **Step 1: Write the failing test**

Insert into `tests/release_test_test.sh`, immediately before the `rm -rf "$TMP"` line:

```sh
# --- rc_structure_check ---------------------------------------------------
mktree() {  # <root>
  r="$1"
  mkdir -p "$r/_Other" "$r/games/Solarus/libs" "$r/Scripts" "$r/docs/Solarus"
  printf '\177ELF' > "$r/_Other/Solarus_20260726.rbf"
  printf '\177ELF' > "$r/games/Solarus/solarus-run"; chmod +x "$r/games/Solarus/solarus-run"
  i=0; while [ $i -lt 22 ]; do printf 'x' > "$r/games/Solarus/libs/lib$i.so.1"; i=$((i+1)); done
  printf 'x' > "$r/games/Solarus/libs/libsolarus.so.1"
  printf 'x' > "$r/games/Solarus/libs/libsolarus.so.1.6.5"
  for s in _handler.sh solarus_run.sh quest_manager.sh quest_lib.sh \
           core_watch.sh solarus_daemon.sh; do
    printf '#!/bin/sh\n' > "$r/games/Solarus/$s"; chmod +x "$r/games/Solarus/$s"
  done
  printf 'x\n' > "$r/games/Solarus/controls.cfg.default"
  printf '#!/bin/sh\n' > "$r/Scripts/Solarus.sh"; chmod +x "$r/Scripts/Solarus.sh"
  printf 'x\n' > "$r/docs/Solarus/README.md"
  mkmanifest "$r/BUILD-INFO.txt"
  sed 's|^rbf_file=.*|rbf_file=Solarus_20260726.rbf|' "$r/BUILD-INFO.txt" > "$r/bi" \
    && mv "$r/bi" "$r/BUILD-INFO.txt"
}

# Synthetic trees carry ELF MAGIC only, so the structural check needs the
# fixture relaxation. Production runs leave RC_ALLOW_FIXTURE unset.
RC_ALLOW_FIXTURE=1

G="$TMP/good"; mktree "$G"
rc_structure_check "$G" "$G/BUILD-INFO.txt" > "$TMP/s0"
rows_fail "$TMP/s0" && bad "T9 good tree failed: $(grep '^FAIL' "$TMP/s0")" \
                    || ok "T9 good tree passes"

# Each defect must fail in isolation.
B="$TMP/b1"; mktree "$B"; printf 'x' > "$B/_Other/Solarus_20260727.rbf"
rc_structure_check "$B" "$B/BUILD-INFO.txt" | grep -q '^FAIL' \
  && ok "T10 two RBFs rejected" || bad "T10 two RBFs accepted"

B="$TMP/b2"; mktree "$B"; rm "$B/games/Solarus/libs/libsolarus.so.1"
ln -s libsolarus.so.1.6.5 "$B/games/Solarus/libs/libsolarus.so.1"
rc_structure_check "$B" "$B/BUILD-INFO.txt" | grep -q '^FAIL' \
  && ok "T11 libsolarus.so.1 symlink rejected" || bad "T11 symlink accepted"

B="$TMP/b3"; mktree "$B"; rm "$B/games/Solarus/quest_lib.sh"
rc_structure_check "$B" "$B/BUILD-INFO.txt" | grep -q '^FAIL' \
  && ok "T12 missing script rejected" || bad "T12 missing script accepted"

B="$TMP/b4"; mktree "$B"; printf '#!/bin/sh\r\necho hi\r\n' > "$B/games/Solarus/core_watch.sh"
rc_structure_check "$B" "$B/BUILD-INFO.txt" | grep -q '^FAIL' \
  && ok "T13 CRLF script rejected" || bad "T13 CRLF accepted"

B="$TMP/b5"; mktree "$B"; printf 'junk' > "$B/games/Solarus/._solarus_run.sh"
rc_structure_check "$B" "$B/BUILD-INFO.txt" | grep -q '^FAIL' \
  && ok "T14 AppleDouble rejected" || bad "T14 AppleDouble accepted"

B="$TMP/b6"; mktree "$B"; rm -f "$B"/games/Solarus/libs/lib1*.so.1
rc_structure_check "$B" "$B/BUILD-INFO.txt" | grep -q '^FAIL' \
  && ok "T15 short lib closure rejected" || bad "T15 short closure accepted"

B="$TMP/b7"; mktree "$B"; chmod -x "$B/games/Solarus/solarus_run.sh"
rc_structure_check "$B" "$B/BUILD-INFO.txt" | grep -q '^FAIL' \
  && ok "T16 non-exec script rejected" || bad "T16 non-exec accepted"

B="$TMP/b8"; mktree "$B"
sed 's|^rbf_file=.*|rbf_file=Solarus_19990101.rbf|' "$B/BUILD-INFO.txt" > "$B/bi" \
  && mv "$B/bi" "$B/BUILD-INFO.txt"
rc_structure_check "$B" "$B/BUILD-INFO.txt" | grep -q '^FAIL' \
  && ok "T17 rbf_file mismatch rejected" || bad "T17 rbf_file mismatch accepted"

# Without the fixture relaxation, a magic-only "engine" must NOT pass — this
# is what stops a truncated binary sailing through a real release gate.
B="$TMP/b9"; mktree "$B"
( RC_ALLOW_FIXTURE=0; rc_structure_check "$B" "$B/BUILD-INFO.txt" ) \
  | grep -q '^FAIL.*armhf ELF' \
  && ok "T17b magic-only engine rejected without RC_ALLOW_FIXTURE" \
  || bad "T17b magic-only engine accepted without RC_ALLOW_FIXTURE"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `sh tests/release_test_test.sh`
Expected: FAIL — `rc_structure_check: not found` for T9 onward.

- [ ] **Step 3: Implement `rc_structure_check`**

Append to `scripts/lib/release_check.sh`:

```sh
RC_SCRIPTS="_handler.sh solarus_run.sh quest_manager.sh quest_lib.sh core_watch.sh solarus_daemon.sh"

# rc_structure_check <extracted-root> <manifest> -> rows
rc_structure_check() {
    _r="$1"; _m="$2"
    _g="$_r/games/Solarus"

    # Exactly one RBF. More than one means the OSD can load the wrong core
    # against this engine — a silent garbage-tile pairing, since there is no
    # engine<->RBF version handshake.
    _n=$(find "$_r/_Other" -maxdepth 1 -type f -name 'Solarus_*.rbf' 2>/dev/null | wc -l | tr -d ' ')
    if [ "$_n" = "1" ]; then rc_pass gate1 "single rbf" "$_n"
    else rc_fail gate1 "single rbf" "found $_n, expected 1"; fi

    # The RBF present is the one the manifest names.
    _want=$(rc_get "$_m" rbf_file)
    if [ -n "$_want" ] && [ -f "$_r/_Other/$_want" ]; then
        rc_pass gate1 "rbf matches manifest" "$_want"
    else
        rc_fail gate1 "rbf matches manifest" "manifest names '$_want', not present"
    fi

    # Engine is a 32-bit ARM ELF (file(1) exists on macOS and ubuntu).
    #
    # RC_ALLOW_FIXTURE=1 relaxes this to an ELF-magic check so the host test
    # can use cheap synthetic trees. It is set ONLY by tests/release_test_test.sh.
    # A real release run leaves it unset, so `file` is the only way to pass —
    # a truncated 4-byte engine must not slip through a release gate.
    if file "$_g/solarus-run" 2>/dev/null | grep -q 'ELF 32-bit.*ARM'; then
        rc_pass gate1 "engine is armhf ELF"
    elif [ "${RC_ALLOW_FIXTURE:-0}" = "1" ] \
         && head -c 4 "$_g/solarus-run" 2>/dev/null | grep -q 'ELF'; then
        rc_pass gate1 "engine is armhf ELF" "magic only (RC_ALLOW_FIXTURE)"
    else
        rc_fail gate1 "engine is armhf ELF" "not a 32-bit ARM ELF"
    fi

    # Lib closure size.
    _l=$(find "$_g/libs" -maxdepth 1 -type f -name '*.so*' 2>/dev/null | wc -l | tr -d ' ')
    if [ "$_l" -ge 20 ]; then rc_pass gate1 "lib closure" "$_l libs"
    else rc_fail gate1 "lib closure" "only $_l libs, expected >=20"; fi

    # Both libsolarus names must be REAL FILES — FAT cannot carry the symlink.
    for _n2 in libsolarus.so.1 libsolarus.so.1.6.5; do
        if [ -L "$_g/libs/$_n2" ]; then
            rc_fail gate1 "libsolarus real file" "$_n2 is a symlink (FAT cannot ship it)"
        elif [ -f "$_g/libs/$_n2" ]; then
            rc_pass gate1 "libsolarus real file" "$_n2"
        else
            rc_fail gate1 "libsolarus real file" "$_n2 missing"
        fi
    done

    # Required scripts + data files, present and executable.
    for _s in $RC_SCRIPTS; do
        if [ ! -f "$_g/$_s" ]; then rc_fail gate1 "script present" "$_s missing"
        elif [ ! -x "$_g/$_s" ]; then rc_fail gate1 "script present" "$_s not executable"
        else rc_pass gate1 "script present" "$_s"; fi
    done
    for _f in "$_g/controls.cfg.default" "$_r/Scripts/Solarus.sh" "$_r/docs/Solarus/README.md"; do
        if [ -f "$_f" ]; then rc_pass gate1 "file present" "${_f#"$_r"/}"
        else rc_fail gate1 "file present" "${_f#"$_r"/} missing"; fi
    done
    if [ -f "$_r/Scripts/Solarus.sh" ] && [ ! -x "$_r/Scripts/Solarus.sh" ]; then
        rc_fail gate1 "script present" "Scripts/Solarus.sh not executable"
    fi

    # No CRLF in any shipped shell script. awk avoids the grep -U / grep -P
    # portability split between BSD and GNU.
    _crlf=""
    for _s in $(find "$_r" -name '*.sh' -type f 2>/dev/null); do
        awk '/\r/{exit 0} END{exit 1}' "$_s" 2>/dev/null && _crlf="$_crlf ${_s#"$_r"/}"
    done
    if [ -n "$_crlf" ]; then rc_fail gate1 "no CRLF" "$_crlf"
    else rc_pass gate1 "no CRLF"; fi

    # No macOS AppleDouble cruft.
    _ad=$(find "$_r" \( -name '._*' -o -name '__MACOSX' \) 2>/dev/null | head -5)
    if [ -n "$_ad" ]; then rc_fail gate1 "no AppleDouble" "$(echo "$_ad" | tr '\n' ' ')"
    else rc_pass gate1 "no AppleDouble"; fi

    # Engine executable bit.
    if [ -x "$_g/solarus-run" ]; then rc_pass gate1 "engine executable"
    else rc_fail gate1 "engine executable" "exec bit not set"; fi
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `sh tests/release_test_test.sh`
Expected: `ALL PASS`, exit 0.

- [ ] **Step 5: Commit (B)**

```bash
git add scripts/lib/release_check.sh tests/release_test_test.sh
git commit -m "feat(release): Gate 1 structural checks

Single RBF, manifest-named RBF present, armhf ELF, >=20 libs, both
libsolarus names as real files (FAT cannot ship the symlink), required
scripts present+executable, no CRLF, no AppleDouble. Each defect is
covered by a test that fails it in isolation. The ELF check relaxes to a
magic-only test ONLY under RC_ALLOW_FIXTURE=1, which the host test sets and
a real release run never does."
```

---

#### Part C — provenance: workflow pathspecs and the staleness check

**Interfaces:**
- Consumes: `rc_pass` / `rc_fail` / `rc_get`.
- Produces: `scripts/lib/wf_pathspec.py <workflow.yml>` — prints one git pathspec per line on stdout; exits non-zero with a message on stderr if the `on.push.paths` block is missing, malformed, or empty.
- Produces: `rc_provenance_check <repo> <tag> <manifest>` → rows.

**Why a staleness check and not equality:** `build-rbf` and `build-engine-ship` are both path-filtered, so a docs-only release legitimately has artifact commits older than the tag. Equality would be false for most real releases and would train the operator to bypass the gate. See the spec's "Provenance" section.

- [ ] **Step 1: Write the failing test for the parser**

Insert into `tests/release_test_test.sh`, before the `rm -rf "$TMP"` line:

```sh
# --- wf_pathspec.py -------------------------------------------------------
WF="$ROOT/scripts/lib/wf_pathspec.py"

python3 "$WF" "$ROOT/.github/workflows/build-rbf.yml" > "$TMP/ps_rbf" 2>"$TMP/ps_err"
if [ -s "$TMP/ps_rbf" ]; then ok "T18 rbf pathspecs non-empty"
else bad "T18 rbf pathspecs empty: $(cat "$TMP/ps_err")"; fi
grep -qx 'fpga/' "$TMP/ps_rbf" \
  && ok "T19 fpga/** -> fpga/" || bad "T19 missing fpga/ pathspec"
grep -qx ':(exclude)fpga/sim/' "$TMP/ps_rbf" \
  && ok "T20 !fpga/sim/** -> exclude" || bad "T20 missing sim exclusion"

python3 "$WF" "$ROOT/.github/workflows/build-engine-ship.yml" > "$TMP/ps_eng" 2>/dev/null
grep -qx 'patches/' "$TMP/ps_eng" \
  && ok "T21 patches/** -> patches/" || bad "T21 missing patches/ pathspec"
grep -qx 'scripts/build_engine.sh' "$TMP/ps_eng" \
  && ok "T22 plain file path preserved" || bad "T22 missing build_engine.sh"

# A malformed workflow must FAIL, never yield an empty list silently — an
# empty pathspec list would make every artifact look permanently current.
printf 'name: x\non:\n  workflow_dispatch:\n' > "$TMP/bad.yml"
python3 "$WF" "$TMP/bad.yml" >/dev/null 2>&1 \
  && bad "T23 malformed workflow accepted" || ok "T23 malformed workflow rejected"

printf 'name: x\non:\n  push:\n    paths:\n' > "$TMP/empty.yml"
python3 "$WF" "$TMP/empty.yml" >/dev/null 2>&1 \
  && bad "T24 empty paths accepted" || ok "T24 empty paths rejected"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `sh tests/release_test_test.sh`
Expected: FAIL from T18 — `can't open file … wf_pathspec.py`.

- [ ] **Step 3: Write the parser**

`PyYAML is not available`, so this hand-parses the one block it needs and fails loudly on anything unexpected. Create `scripts/lib/wf_pathspec.py`:

```python
#!/usr/bin/env python3
"""Emit git pathspecs for a workflow's `on.push.paths` filter.

Used by the release-test provenance gate to ask: "did anything change between
the commit this artifact was built from and the release tag that would have
retriggered this workflow?"  Deriving the globs from the workflow itself keeps
the gate from drifting out of sync with the build triggers.

Translation to git pathspec syntax (git does the matching, so we do not have to
reimplement glob semantics):
    fpga/**            -> fpga/
    !fpga/sim/**       -> :(exclude)fpga/sim/
    scripts/build.sh   -> scripts/build.sh

Stdlib only: PyYAML is not installed on the runner or the dev host.
Any malformed / missing / empty `paths:` block exits non-zero. An empty list
must never be returned silently: it would make every artifact look permanently
up to date and the gate would pass on everything.
"""
import re
import sys


def _indent(s):
    return len(s) - len(s.lstrip(" "))


def parse(path):
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    n = len(lines)

    i = 0
    while i < n and not re.match(r"^on:\s*$", lines[i]):
        i += 1
    if i == n:
        sys.exit(f"{path}: no top-level 'on:' block")

    push = None
    i += 1
    while i < n:
        line = lines[i]
        if line.strip() and _indent(line) == 0:
            break
        if re.match(r"^\s+push:\s*$", line):
            push = i
            break
        i += 1
    if push is None:
        sys.exit(f"{path}: no 'push:' under 'on:'")

    paths = None
    push_ind = _indent(lines[push])
    i = push + 1
    while i < n:
        line = lines[i]
        if line.strip() and _indent(line) <= push_ind:
            break
        if re.match(r"^\s+paths:\s*$", line):
            paths = i
            break
        i += 1
    if paths is None:
        sys.exit(f"{path}: no 'paths:' under 'on.push'")

    out = []
    paths_ind = _indent(lines[paths])
    i = paths + 1
    while i < n:
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        if _indent(line) <= paths_ind:
            break
        m = re.match(r"^\s*-\s*(.+?)\s*$", line)
        if not m:
            break
        val = re.sub(r"\s+#.*$", "", m.group(1)).strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
            val = val[1:-1]
        if val:
            out.append(val)
        i += 1

    if not out:
        sys.exit(f"{path}: 'paths:' list is empty")
    return out


def to_pathspec(glob):
    neg = glob.startswith("!")
    if neg:
        glob = glob[1:]
    if glob.endswith("/**"):
        glob = glob[:-3] + "/"
    elif glob.endswith("/*"):
        glob = glob[:-2] + "/"
    return ":(exclude)" + glob if neg else glob


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: wf_pathspec.py <workflow.yml>")
    for glob in parse(sys.argv[1]):
        print(to_pathspec(glob))


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run the parser test to verify it passes**

Run: `sh tests/release_test_test.sh`
Expected: T18–T24 all PASS. (T25+ do not exist yet.)

- [ ] **Step 5: Write the failing test for the staleness logic**

This builds a real throwaway git repo so the logic is exercised against actual `git diff`, not a mock. Insert before `rm -rf "$TMP"`:

```sh
# --- rc_stale_files (staleness against a real repo) -----------------------
R="$TMP/repo"
mkdir -p "$R/fpga/rtl" "$R/fpga/sim" "$R/docs" "$R/.github/workflows"
cp "$ROOT/.github/workflows/build-rbf.yml" "$R/.github/workflows/"
( cd "$R" && git init -q && git config user.email t@t && git config user.name t \
  && echo a > fpga/rtl/a.sv && echo d > docs/d.md && echo s > fpga/sim/s.sv \
  && git add -A && git commit -qm base ) || bad "repo setup failed"
BASE=$(git -C "$R" rev-parse HEAD)

# docs-only change: NOT stale (this is the common real release)
( cd "$R" && echo more >> docs/d.md && git commit -qam docs )
DOCS=$(git -C "$R" rev-parse HEAD)
out=$(rc_stale_files "$R" "$BASE" "$DOCS" "$R/.github/workflows/build-rbf.yml")
[ -z "$out" ] && ok "T25 docs-only change is not stale" \
              || bad "T25 docs-only reported stale: $out"

# sim-only change: excluded by !fpga/sim/**, so NOT stale
( cd "$R" && echo more >> fpga/sim/s.sv && git commit -qam sim )
SIM=$(git -C "$R" rev-parse HEAD)
out=$(rc_stale_files "$R" "$BASE" "$SIM" "$R/.github/workflows/build-rbf.yml")
[ -z "$out" ] && ok "T26 fpga/sim change is excluded" \
              || bad "T26 sim reported stale: $out"

# rtl change: STALE — the RBF would have been rebuilt
( cd "$R" && echo more >> fpga/rtl/a.sv && git commit -qam rtl )
RTL=$(git -C "$R" rev-parse HEAD)
out=$(rc_stale_files "$R" "$BASE" "$RTL" "$R/.github/workflows/build-rbf.yml")
[ -n "$out" ] && ok "T27 fpga/rtl change is stale" \
              || bad "T27 rtl not reported stale"

# A parser break must return 2, NOT empty output. Empty would read as "nothing
# changed" and silently pass every artifact forever — the worst failure mode
# this gate has.
printf 'name: x\non:\n  workflow_dispatch:\n' > "$R/bad.yml"
out=$(rc_stale_files "$R" "$BASE" "$RTL" "$R/bad.yml"); st=$?
[ "$st" = "2" ] && [ -z "$out" ] \
  && ok "T27b unparseable workflow returns 2, not empty" \
  || bad "T27b unparseable workflow returned status=$st out='$out'"
```

- [ ] **Step 6: Run it to verify it fails**

Run: `sh tests/release_test_test.sh`
Expected: FAIL from T25 — `rc_stale_files: not found`.

- [ ] **Step 7: Implement the staleness helpers**

Append to `scripts/lib/release_check.sh`:

```sh
# rc_stale_files <repo> <from-sha> <to-sha> <workflow.yml>
# Prints the files changed between the two commits that match the workflow's
# own trigger paths. Empty output == the artifact is current w.r.t. <to-sha>.
# Returns 2 (printing nothing) if the pathspecs cannot be derived — the caller
# MUST treat that as a FAIL, never as "nothing changed", or a parser break
# would silently pass every artifact.
rc_stale_files() {
    _repo="$1"; _from="$2"; _to="$3"; _wf="$4"
    _py="${RC_WF_PATHSPEC:-$_repo/scripts/lib/wf_pathspec.py}"
    [ -f "$_py" ] || return 2
    _specs=$(python3 "$_py" "$_wf" 2>/dev/null) || return 2
    [ -n "$_specs" ] || return 2
    # Intentional word-split: one pathspec per line, none contain spaces.
    # shellcheck disable=SC2086
    git -C "$_repo" diff --name-only "$_from" "$_to" -- $_specs
}
```

The `RC_WF_PATHSPEC` fallback must be set by the sourcing script. Add near the top of `scripts/lib/release_check.sh`, right after the `RC_KEYS` line:

```sh
# Absolute path to the pathspec parser; set by the sourcing script so the
# library works from a test, from the driver, and from any cwd.
: "${RC_WF_PATHSPEC:=}"
```

And in `scripts/release_test.sh`, before the `. "$ROOT/scripts/lib/release_check.sh"` line:

```sh
RC_WF_PATHSPEC="$ROOT/scripts/lib/wf_pathspec.py"; export RC_WF_PATHSPEC
```

And in `tests/release_test_test.sh`, before the `. "$ROOT/scripts/lib/release_check.sh"` line:

```sh
RC_WF_PATHSPEC="$ROOT/scripts/lib/wf_pathspec.py"
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `sh tests/release_test_test.sh`
Expected: T25–T27 PASS, `ALL PASS`, exit 0.

- [ ] **Step 9: Implement `rc_provenance_check`**

Append to `scripts/lib/release_check.sh`:

```sh
# rc_provenance_check <repo> <tag> <manifest> -> rows
#
# Three assertions per the spec:
#   1. the manifest's `commit` is the tag's commit
#   2. the tag is an ancestor of (or equal to) origin/master
#   3. for each artifact: its head_sha is an ancestor of the tag AND no commit
#      between them touched that workflow's own trigger paths
rc_provenance_check() {
    _repo="$1"; _tag="$2"; _m="$3"

    _tagsha=$(git -C "$_repo" rev-parse --verify "${_tag}^{commit}" 2>/dev/null)
    if [ -z "$_tagsha" ]; then
        rc_fail gate1 "tag resolves" "$_tag not found (git fetch --tags?)"
        return 0
    fi
    rc_pass gate1 "tag resolves" "$_tag -> $(echo "$_tagsha" | cut -c1-12)"

    _mc=$(rc_get "$_m" commit)
    if [ "$_mc" = "$_tagsha" ]; then
        rc_pass gate1 "manifest commit == tag"
    else
        rc_fail gate1 "manifest commit == tag" \
            "manifest $(echo "$_mc" | cut -c1-12) != tag $(echo "$_tagsha" | cut -c1-12)"
    fi

    if git -C "$_repo" merge-base --is-ancestor "$_tagsha" origin/master 2>/dev/null; then
        rc_pass gate1 "tag is on master"
    else
        rc_fail gate1 "tag is on master" "tag is not an ancestor of origin/master"
    fi

    rc_artifact_check "$_repo" "$_tagsha" "$_m" rbf    .github/workflows/build-rbf.yml
    rc_artifact_check "$_repo" "$_tagsha" "$_m" engine .github/workflows/build-engine-ship.yml
}

# rc_artifact_check <repo> <tagsha> <manifest> <rbf|engine> <workflow-relpath>
rc_artifact_check() {
    _repo="$1"; _tagsha="$2"; _m="$3"; _which="$4"; _wfrel="$5"
    _sha=$(rc_get "$_m" "${_which}_head_sha")
    _wf="$_repo/$_wfrel"

    if [ -z "$_sha" ]; then
        rc_fail gate1 "$_which built from" "no ${_which}_head_sha in manifest"
        return 0
    fi
    if ! git -C "$_repo" cat-file -e "${_sha}^{commit}" 2>/dev/null; then
        rc_fail gate1 "$_which built from" "commit $_sha not in this repo (fetch?)"
        return 0
    fi
    if git -C "$_repo" merge-base --is-ancestor "$_sha" "$_tagsha" 2>/dev/null; then
        rc_pass gate1 "$_which is an ancestor" "$(echo "$_sha" | cut -c1-12)"
    else
        rc_fail gate1 "$_which is an ancestor" \
            "$(echo "$_sha" | cut -c1-12) is not an ancestor of the tag"
        return 0
    fi

    _touched=$(rc_stale_files "$_repo" "$_sha" "$_tagsha" "$_wf")
    case $? in
        2) rc_fail gate1 "$_which is current" "cannot derive pathspecs from $_wfrel"
           return 0 ;;
    esac
    if [ -z "$_touched" ]; then
        rc_pass gate1 "$_which is current" "no trigger-path change since build"
    else
        rc_fail gate1 "$_which is current" \
            "rebuild needed; changed: $(echo "$_touched" | tr '\n' ' ')"
    fi
}
```

- [ ] **Step 10: Run the full suite**

Run: `bash tests/run_tests.sh`
Expected: ends with `All host tests passed.`

- [ ] **Step 11: Commit (C)**

```bash
git add scripts/lib/wf_pathspec.py scripts/lib/release_check.sh \
        tests/release_test_test.sh
git commit -m "feat(release): Gate 1 provenance via workflow-derived staleness

Both build workflows are path-filtered, so head_sha == tag is false for most
real releases. Instead assert each artifact's commit is an ancestor of the tag
and that nothing between them touched that workflow's own on.push.paths, with
the pathspecs parsed out of the workflow YAML so they cannot drift. A parser
break returns 2, never empty output — empty would read as 'nothing changed'
and silently pass every artifact."
```

---

#### Part D — the driver

The driver lands last, with `gate1` complete, so no commit ever ships a CLI
that dispatches to an undefined function.

- [ ] **Step 1: Create `scripts/release_test.sh`**

```sh
#!/bin/sh
# Release-candidate test driver. See docs/release-testing.md.
#
#   release_test.sh gate1 <rc-tag> [--zip PATH]
#   release_test.sh gate2 <rc-tag> [--host IP] [--soak-min N]
#   release_test.sh gate4 <release-tag> --rc <rc-tag>
#   release_test.sh all   <rc-tag>     [--host IP]
#
# Exits non-zero if any check emitted a FAIL row.
set -u
ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
RC_WF_PATHSPEC="$ROOT/scripts/lib/wf_pathspec.py"; export RC_WF_PATHSPEC
. "$ROOT/scripts/lib/release_check.sh"

HOST=192.168.20.81
SOAK_MIN=10
ZIP=""
RC_TAG=""

usage() { sed -n '2,10p' "$0"; exit 2; }

CMD="${1:-}"; [ -n "$CMD" ] || usage; shift
TAG="${1:-}"; [ -n "$TAG" ] || usage; shift
while [ $# -gt 0 ]; do
    case "$1" in
        --host)     HOST="$2"; shift 2 ;;
        --soak-min) SOAK_MIN="$2"; shift 2 ;;
        --zip)      ZIP="$2"; shift 2 ;;
        --rc)       RC_TAG="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; usage ;;
    esac
done

WORK="$ROOT/_rc/$TAG"
mkdir -p "$WORK"
RESULTS="$WORK/results.tsv"

# Render the accumulated rows and set the exit status.
rc_report() {
    echo
    printf '%-6s %-8s %-34s %s\n' STATUS GATE CHECK DETAIL
    printf '%-6s %-8s %-34s %s\n' ------ ------ ---------------------------------- ------
    awk -F'\t' '{printf "%-6s %-8s %-34s %s\n", $1, $2, $3, $4}' "$RESULTS"
    _n=$(grep -c '^FAIL' "$RESULTS" 2>/dev/null || true)
    _n=${_n:-0}
    echo
    if [ "$_n" -eq 0 ]; then
        echo "ALL CHECKS PASSED ($(wc -l < "$RESULTS" | tr -d ' ') checks)"
        return 0
    fi
    echo "FAILURES: $_n"
    return 1
}

gate1() {
    echo "== Gate 1: provenance + structure =="
    if [ -n "$ZIP" ]; then
        cp "$ZIP" "$WORK/rc.zip"
    else
        echo "-- downloading $TAG asset"
        ( cd "$WORK" && rm -f ./*.zip \
          && gh release download "$TAG" --pattern '*.zip' --clobber ) \
          || { rc_fail gate1 "download asset" "gh release download failed" >> "$RESULTS"; return 0; }
        mv "$WORK"/solarus-mister-*.zip "$WORK/rc.zip" 2>/dev/null || true
    fi
    rc_pass gate1 "download asset" "$(wc -c < "$WORK/rc.zip" | tr -d ' ') bytes" >> "$RESULTS"

    rm -rf "$WORK/tree"; mkdir -p "$WORK/tree"
    unzip -q -o "$WORK/rc.zip" -d "$WORK/tree" \
      || { rc_fail gate1 "unzip" "extract failed" >> "$RESULTS"; return 0; }

    M="$WORK/tree/BUILD-INFO.txt"
    rc_manifest_check    "$M"                        >> "$RESULTS"
    rc_provenance_check  "$ROOT" "$TAG" "$M"         >> "$RESULTS"
    rc_structure_check   "$WORK/tree" "$M"           >> "$RESULTS"

    # version.txt at the tagged commit must name the shipped RBF.
    _vt=$(git -C "$ROOT" show "$TAG:version.txt" 2>/dev/null | tr -d '\r\n ')
    _rf=$(rc_get "$M" rbf_file)
    if [ "$_vt" = "$_rf" ]; then
        rc_pass gate1 "version.txt matches rbf" "$_rf" >> "$RESULTS"
    else
        rc_fail gate1 "version.txt matches rbf" "version.txt='$_vt' rbf_file='$_rf'" >> "$RESULTS"
    fi

    echo "rbf_run_id=$(rc_get "$M" rbf_run_id)"       > "$WORK/pins.env"
    echo "engine_run_id=$(rc_get "$M" engine_run_id)" >> "$WORK/pins.env"
}

case "$CMD" in
    gate1) : > "$RESULTS"; gate1 ;;
    *)     usage ;;
esac
rc_report
```

Then `chmod +x scripts/release_test.sh`.

The `gate2`, `gate4`, `all`, and `publish-cmd` arms are added by Tasks 3 and 4,
each alongside the function it dispatches to.

- [ ] **Step 2: Verify it parses and runs**

Run: `sh -n scripts/release_test.sh && sh scripts/release_test.sh; echo "exit=$?"`
Expected: no syntax error; the usage block prints; `exit=2`.

- [ ] **Step 3: Shellcheck**

Run: `shellcheck -s sh scripts/release_test.sh scripts/lib/release_check.sh`
Expected: no errors. Silence any intentional word-split with a scoped
`# shellcheck disable=SC2086` plus a one-line reason, matching the style already
used in `scripts/Solarus.sh`.

- [ ] **Step 4: Run the full suite**

Run: `bash tests/run_tests.sh`
Expected: ends with `All host tests passed.`

- [ ] **Step 5: Commit (D)**

```bash
git add scripts/release_test.sh
git commit -m "feat(release): release_test.sh driver with Gate 1 wired

Downloads the RC asset, extracts it, and runs the manifest, provenance, and
structure checks, recording the artifact run-ids as publish pins."
```

---

### Task 3: Gate 2 — install, boot, soak on the device

**Files:**
- Modify: `scripts/release_test.sh`
- Modify: `scripts/lib/release_check.sh`
- Modify: `tests/release_test_test.sh`

**Interfaces:**
- Consumes: `$WORK/rc.zip` and `$WORK/tree/BUILD-INFO.txt` from Task 2.
- Produces: `rc_fps_min <samples-file>` → the minimum per-second delta on stdout (pure; testable).
- Produces: `gate2` in the driver.

**Launch model.** Gate 2 kills the daemon and drives the engine directly with an `S0_FILE` override — deterministic, and it cannot race the daemon into a second engine. The real daemon + OSD path is exercised by the operator in Gate 3, which restarts it via `Scripts/Solarus.sh`.

- [ ] **Step 1: Write the failing test for the pure part**

Insert into `tests/release_test_test.sh`, before `rm -rf "$TMP"`:

```sh
# --- rc_fps_min -----------------------------------------------------------
printf '58\n57\n59\n56\n' > "$TMP/fps_ok"
[ "$(rc_fps_min "$TMP/fps_ok")" = "56" ] \
  && ok "T28 rc_fps_min finds the minimum" || bad "T28 rc_fps_min wrong"

printf '58\n0\n59\n' > "$TMP/fps_stall"
[ "$(rc_fps_min "$TMP/fps_stall")" = "0" ] \
  && ok "T29 rc_fps_min catches a stall" || bad "T29 stall missed"

: > "$TMP/fps_empty"
[ "$(rc_fps_min "$TMP/fps_empty")" = "-1" ] \
  && ok "T30 rc_fps_min returns -1 on no samples" || bad "T30 empty not -1"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `sh tests/release_test_test.sh`
Expected: FAIL at T28 — `rc_fps_min: not found`.

- [ ] **Step 3: Implement `rc_fps_min`**

Append to `scripts/lib/release_check.sh`:

```sh
# rc_fps_min <file-of-integers> -> minimum on stdout, or -1 if the file is
# empty. -1 (not 0) so "no samples" is distinguishable from "engine stalled".
rc_fps_min() {
    awk 'NF{ if (m=="" || $1+0 < m) m=$1+0 } END{ print (m=="" ? -1 : m) }' "$1"
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `sh tests/release_test_test.sh`
Expected: `ALL PASS`.

- [ ] **Step 5: Implement `gate2` in the driver**

Insert into `scripts/release_test.sh`, after `gate1()`:

```sh
RSH() { ssh -o ConnectTimeout=10 -o BatchMode=yes "root@$HOST" "$@"; }

gate2() {
    echo "== Gate 2: install + boot + soak on $HOST =="
    M="$WORK/tree/BUILD-INFO.txt"
    G=/media/fat/games/Solarus

    RSH true >/dev/null 2>&1 \
      || { rc_fail gate2 "device reachable" "$HOST" >> "$RESULTS"; return 0; }
    rc_pass gate2 "device reachable" "$HOST" >> "$RESULTS"

    # -- preflight: nothing of ours running. busybox has no pkill; pidof has
    #    no -x, so scripts are matched with a [x]-style ps|grep.
    echo "-- stopping engine + daemon"
    RSH 'for p in $(ps -o pid,args 2>/dev/null | grep -E "[q]uest_manager.sh|[s]olarus_daemon.sh" | awk "{print \$1}"); do kill -9 $p 2>/dev/null; done
         pids=$(pidof solarus-run); [ -n "$pids" ] && kill -9 $pids 2>/dev/null
         sleep 1; exit 0'
    left=$(RSH 'pidof solarus-run | wc -w' | tr -d ' ')
    if [ "${left:-1}" = "0" ]; then rc_pass gate2 "no engine running" >> "$RESULTS"
    else rc_fail gate2 "no engine running" "$left still alive" >> "$RESULTS"; return 0; fi

    # -- preserve quests + controls.cfg, then WIPE.
    echo "-- preserving quests + controls.cfg, wiping install"
    RSH "rm -rf /media/fat/_rcsave && mkdir -p /media/fat/_rcsave
         cp $G/quests/*.sol /media/fat/_rcsave/ 2>/dev/null
         cp $G/controls.cfg /media/fat/_rcsave/ 2>/dev/null
         rm -rf $G
         rm -f /media/fat/_Other/Solarus_*.rbf
         rm -f /media/fat/Scripts/Solarus.sh
         rm -f /media/fat/config/Solarus.s0 /media/fat/config/Solarus_input.map
         exit 0"
    rbfleft=$(RSH 'ls /media/fat/_Other/Solarus_*.rbf 2>/dev/null | wc -l' | tr -d ' ')
    if [ "${rbfleft:-1}" = "0" ]; then rc_pass gate2 "old cores wiped" >> "$RESULTS"
    else rc_fail gate2 "old cores wiped" "$rbfleft remain" >> "$RESULTS"; fi

    # -- install from the zip, exactly as a user would.
    echo "-- uploading + extracting the RC zip"
    scp -q "$WORK/rc.zip" "root@$HOST:/media/fat/rc.zip" \
      || { rc_fail gate2 "upload zip" "scp failed" >> "$RESULTS"; return 0; }
    RSH 'unzip -q -o /media/fat/rc.zip -d /media/fat && rm -f /media/fat/rc.zip' \
      || { rc_fail gate2 "extract zip" "unzip failed" >> "$RESULTS"; return 0; }
    rc_pass gate2 "extract zip" >> "$RESULTS"
    RSH "mkdir -p $G/quests
         cp /media/fat/_rcsave/*.sol $G/quests/ 2>/dev/null
         cp /media/fat/_rcsave/controls.cfg $G/ 2>/dev/null
         chmod +x $G/*.sh $G/solarus-run /media/fat/Scripts/Solarus.sh 2>/dev/null
         rm -rf /media/fat/_rcsave; exit 0"

    # -- installed bytes match the manifest.
    RBF=$(rc_get "$M" rbf_file)
    for pair in "sha256_rbf:/media/fat/_Other/$RBF" \
                "sha256_solarus_run:$G/solarus-run" \
                "sha256_libsolarus:$G/libs/libsolarus.so.1.6.5"; do
        key=${pair%%:*}; path=${pair#*:}
        want=$(rc_get "$M" "$key")
        got=$(RSH "sha256sum '$path' 2>/dev/null | cut -d' ' -f1")
        if [ -n "$got" ] && [ "$got" = "$want" ]; then
            rc_pass gate2 "installed sha256" "$(basename "$path")" >> "$RESULTS"
        else
            rc_fail gate2 "installed sha256" "$(basename "$path"): got '$got' want '$want'" >> "$RESULTS"
        fi
    done
    n=$(RSH 'ls /media/fat/_Other/Solarus_*.rbf 2>/dev/null | wc -l' | tr -d ' ')
    if [ "$n" = "1" ]; then rc_pass gate2 "single rbf on card" >> "$RESULTS"
    else rc_fail gate2 "single rbf on card" "$n present" >> "$RESULTS"; fi

    # -- link probe + the software-only invariant.
    if RSH "cd $G && LD_LIBRARY_PATH=$G/libs:$G ./solarus-run -help >/dev/null 2>&1"; then
        rc_pass gate2 "lib closure links" >> "$RESULTS"
    else
        rc_fail gate2 "lib closure links" "solarus-run -help failed (missing/ABI-bad .so)" >> "$RESULTS"
    fi
    gl=$(RSH "cd $G && LD_LIBRARY_PATH=$G/libs:$G ldd ./solarus-run 2>/dev/null | grep -Ei 'libGL|GLEW|EGL'")
    if [ -z "$gl" ]; then rc_pass gate2 "no GL linkage" >> "$RESULTS"
    else rc_fail gate2 "no GL linkage" "$(echo "$gl" | tr '\n' ' ')" >> "$RESULTS"; fi

    # -- launch: core first, then the engine with an S0_FILE override. The
    #    daemon stays DOWN so it cannot race us into a second engine.
    QUEST=$(RSH "ls $G/quests/*.sol 2>/dev/null | head -1")
    if [ -z "$QUEST" ]; then
        rc_fail gate2 "quest available" "no .sol in $G/quests" >> "$RESULTS"; return 0
    fi
    rc_pass gate2 "quest available" "$(basename "$QUEST")" >> "$RESULTS"
    LOG="/media/fat/logs/rc-$TAG.log"
    echo "-- loading core + launching engine (log: $LOG)"
    RSH "echo 'load_core /media/fat/_Other/$RBF' > /dev/MiSTer_cmd; sleep 4
         printf '%s\n' '${QUEST#/media/fat/}' > /tmp/rc_s0
         mkdir -p /media/fat/logs
         cd $G && S0_FILE=/tmp/rc_s0 GAMEDIR=$G setsid sh $G/solarus_run.sh \
            > $LOG 2>&1 </dev/null &
         sleep 25; exit 0"
    alive=$(RSH 'pidof solarus-run | wc -w' | tr -d ' ')
    if [ "${alive:-0}" -ge 1 ]; then rc_pass gate2 "engine launched" >> "$RESULTS"
    else rc_fail gate2 "engine launched" "no solarus-run after 25s" >> "$RESULTS"; return 0; fi
    if [ "${alive:-0}" -gt 1 ]; then
        rc_fail gate2 "single engine" "$alive engines — host wedge risk" >> "$RESULTS"
    else
        rc_pass gate2 "single engine" >> "$RESULTS"
    fi

    # -- log assertions.
    for want in 'renderer active (DDR @' 'ring double-buffer ENABLED' \
                'tilemap channel ENABLED'; do
        if RSH "grep -qF '$want' $LOG"; then
            rc_pass gate2 "log has" "$want" >> "$RESULTS"
        else
            rc_fail gate2 "log has" "missing: $want" >> "$RESULTS"
        fi
    done
    for bad in 'video-region map failed' 'reverting to SDL' \
               'pass-through SDLRenderer' 'scene_too_big' 'Segmentation fault'; do
        if RSH "grep -qF '$bad' $LOG"; then
            rc_fail gate2 "log clean" "found: $bad" >> "$RESULTS"
        else
            rc_pass gate2 "log clean" "no '$bad'" >> "$RESULTS"
        fi
    done

    # -- fps floor on the title screen (~57 measured; floor 45 catches a
    #    fallback to the SDL path without flapping on scheduling noise).
    echo "-- sampling fps for 30s"
    RSH 'prev=""; i=0
         while [ $i -lt 31 ]; do
           c=$(busybox devmem 0x3A000000 2>/dev/null); f=$(( c >> 2 ))
           [ -n "$prev" ] && echo $(( f - prev ))
           prev=$f; i=$((i+1)); sleep 1
         done' > "$WORK/fps.txt"
    fmin=$(rc_fps_min "$WORK/fps.txt")
    if [ "$fmin" -ge 45 ]; then
        rc_pass gate2 "fps floor" "min ${fmin} fps (floor 45)" >> "$RESULTS"
    else
        rc_fail gate2 "fps floor" "min ${fmin} fps below floor 45" >> "$RESULTS"
    fi

    # -- soak.
    echo "-- soaking ${SOAK_MIN} min"
    RSH "sleep $((SOAK_MIN * 60))"
    still=$(RSH 'pidof solarus-run | wc -w' | tr -d ' ')
    if [ "${still:-0}" -ge 1 ]; then rc_pass gate2 "alive after soak" "${SOAK_MIN} min" >> "$RESULTS"
    else rc_fail gate2 "alive after soak" "engine died during soak" >> "$RESULTS"; fi
    a=$(RSH 'busybox devmem 0x3A000000'); sleep 2
    b=$(RSH 'busybox devmem 0x3A000000')
    if [ "$a" != "$b" ]; then rc_pass gate2 "frames advancing" >> "$RESULTS"
    else rc_fail gate2 "frames advancing" "frame counter frozen at $a" >> "$RESULTS"; fi

    echo
    echo "Gate 2 done. Engine is RUNNING for Gate 3 (operator visual gate)."
    echo "For the real user path, run on the device:  sh /media/fat/Scripts/Solarus.sh"
    echo "Device log: $LOG"
}
```

Then extend the `case` block so the new function is reachable — replace:

```sh
case "$CMD" in
    gate1) : > "$RESULTS"; gate1 ;;
    *)     usage ;;
esac
```

with:

```sh
case "$CMD" in
    gate1) : > "$RESULTS"; gate1 ;;
    gate2) gate2 ;;
    all)   : > "$RESULTS"; gate1 && gate2 ;;
    *)     usage ;;
esac
```

Note `gate2` deliberately does **not** truncate `$RESULTS`: run on its own it
appends to the rows Gate 1 already recorded for the same tag, so the report and
the sign-off cover both gates.

- [ ] **Step 6: Verify the script parses and the suite passes**

Run: `sh -n scripts/release_test.sh && bash tests/run_tests.sh`
Expected: no syntax error; suite ends `All host tests passed.`

- [ ] **Step 7: Shellcheck**

Run: `shellcheck -s sh scripts/release_test.sh scripts/lib/release_check.sh`
Expected: no errors. Silence any intentional word-split with a scoped `# shellcheck disable=SC2086` and a one-line reason, matching the style already used in `scripts/Solarus.sh`.

- [ ] **Step 8: Commit**

```bash
git add scripts/release_test.sh scripts/lib/release_check.sh tests/release_test_test.sh
git commit -m "feat(release): Gate 2 — wipe-then-extract install, boot, soak

Kills engine+daemon, preserves quests/controls.cfg, wipes the install and ALL
_Other/Solarus_*.rbf (collapsing the multi-core ambiguity that can silently
pair a wrong bitstream with this engine), extracts the zip, verifies installed
sha256s against the manifest, link-probes the closure, asserts no GL linkage,
launches with an S0_FILE override (daemon stays down so it cannot race us into
a second engine), then checks the log, the fps floor, and a soak."
```

---

### Task 4: Gate 4 — post-publish identity, and the pinned publish command

**Files:**
- Modify: `scripts/release_test.sh`
- Modify: `tests/release_test_test.sh`

**Interfaces:**
- Consumes: `$WORK/tree/BUILD-INFO.txt` and `$WORK/pins.env` from Task 2.
- Produces: `rc_manifest_identical <manifest-a> <manifest-b>` → rows comparing the fields that must match.
- Produces: `gate4` and `rc_publish_cmd` in the driver.

- [ ] **Step 1: Write the failing test**

Insert into `tests/release_test_test.sh`, before `rm -rf "$TMP"`:

```sh
# --- rc_manifest_identical ------------------------------------------------
mkmanifest "$TMP/a.txt"; cp "$TMP/a.txt" "$TMP/b.txt"
rc_manifest_identical "$TMP/a.txt" "$TMP/b.txt" > "$TMP/i1"
rows_fail "$TMP/i1" && bad "T31 identical manifests failed" \
                    || ok "T31 identical manifests pass"

# The tag and built_utc MUST differ between an RC and its release — comparing
# them would make the gate impossible to pass.
sed 's/^tag=.*/tag=v9.9.9/; s/^built_utc=.*/built_utc=later/' "$TMP/a.txt" > "$TMP/c.txt"
rc_manifest_identical "$TMP/a.txt" "$TMP/c.txt" > "$TMP/i2"
rows_fail "$TMP/i2" && bad "T32 tag/built_utc difference wrongly failed" \
                    || ok "T32 tag/built_utc allowed to differ"

# A different payload must fail.
sed 's/^sha256_rbf=.*/sha256_rbf=deadbeef/' "$TMP/a.txt" > "$TMP/d.txt"
rc_manifest_identical "$TMP/a.txt" "$TMP/d.txt" | grep -q '^FAIL' \
  && ok "T33 payload sha difference rejected" || bad "T33 payload difference accepted"

# A different run-id must fail — that is a rebuild, not the tested artifact.
sed 's/^engine_run_id=.*/engine_run_id=999/' "$TMP/a.txt" > "$TMP/e.txt"
rc_manifest_identical "$TMP/a.txt" "$TMP/e.txt" | grep -q '^FAIL' \
  && ok "T34 run-id difference rejected" || bad "T34 run-id difference accepted"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `sh tests/release_test_test.sh`
Expected: FAIL at T31 — `rc_manifest_identical: not found`.

- [ ] **Step 3: Implement `rc_manifest_identical`**

Append to `scripts/lib/release_check.sh`:

```sh
# Fields that must be byte-identical between the RC and the published release.
# `tag` and `built_utc` are deliberately excluded: they always differ, and
# comparing them would make the gate unpassable.
RC_IDENTITY_KEYS="commit rbf_run_id rbf_head_sha rbf_file engine_run_id engine_head_sha sha256_rbf sha256_solarus_run sha256_libsolarus"

# rc_manifest_identical <rc-manifest> <published-manifest> -> rows
rc_manifest_identical() {
    _a="$1"; _b="$2"
    for _k in $RC_IDENTITY_KEYS; do
        _va=$(rc_get "$_a" "$_k"); _vb=$(rc_get "$_b" "$_k")
        if [ -n "$_va" ] && [ "$_va" = "$_vb" ]; then
            rc_pass gate4 "identical" "$_k"
        else
            rc_fail gate4 "identical" "$_k: rc='$_va' published='$_vb'"
        fi
    done
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `sh tests/release_test_test.sh`
Expected: `ALL PASS`.

- [ ] **Step 5: Implement `rc_publish_cmd` and `gate4`**

Insert into `scripts/release_test.sh`, after `gate2()`:

```sh
# Print the exact pinned publish command. NEVER publish by pushing the tag
# blind: release.yml would re-resolve "latest successful on master" and could
# ship binaries other than the ones that just passed Gates 1-3.
rc_publish_cmd() {
    [ -f "$WORK/pins.env" ] || { echo "(run gate1 first — no pins recorded)"; return; }
    # shellcheck disable=SC1090  # generated file, path is computed
    . "$WORK/pins.env"
    _rel=$(echo "$TAG" | sed 's/-rc[0-9]*$//')
    cat <<EOF

Publish the tested artifacts as $_rel:

  gh workflow run release.yml \\
    -f tag=$_rel \\
    -f rbf_run_id=$rbf_run_id \\
    -f engine_run_id=$engine_run_id

Then verify:  scripts/release_test.sh gate4 $_rel --rc $TAG
EOF
}

gate4() {
    echo "== Gate 4: post-publish identity =="
    RCW="$ROOT/_rc/$RC_TAG"
    if [ ! -f "$RCW/tree/BUILD-INFO.txt" ]; then
        : > "$RESULTS"
        rc_fail gate4 "rc manifest available" "no $RCW/tree/BUILD-INFO.txt — run gate1 $RC_TAG first" >> "$RESULTS"
        return 0
    fi
    : > "$RESULTS"
    rm -rf "$WORK/pub"; mkdir -p "$WORK/pub"
    ( cd "$WORK/pub" && gh release download "$TAG" --pattern '*.zip' --clobber ) \
      || { rc_fail gate4 "download published" "gh release download failed" >> "$RESULTS"; return 0; }
    rc_pass gate4 "download published" "$TAG" >> "$RESULTS"
    unzip -q -o "$WORK"/pub/*.zip -d "$WORK/pub/tree" \
      || { rc_fail gate4 "unzip published" "extract failed" >> "$RESULTS"; return 0; }

    rc_manifest_identical "$RCW/tree/BUILD-INFO.txt" "$WORK/pub/tree/BUILD-INFO.txt" >> "$RESULTS"
    rc_structure_check "$WORK/pub/tree" "$WORK/pub/tree/BUILD-INFO.txt" >> "$RESULTS"

    if [ "$(gh release view "$TAG" --json isPrerelease -q .isPrerelease)" = "false" ]; then
        rc_pass gate4 "not a prerelease" >> "$RESULTS"
    else
        rc_fail gate4 "not a prerelease" "$TAG is marked prerelease" >> "$RESULTS"
    fi
    if [ "$(gh release view --json tagName -q .tagName)" = "$TAG" ]; then
        rc_pass gate4 "marked Latest" >> "$RESULTS"
    else
        rc_fail gate4 "marked Latest" "Latest is $(gh release view --json tagName -q .tagName)" >> "$RESULTS"
    fi
}
```

Then extend the `case` block to reach the new functions. Replace:

```sh
case "$CMD" in
    gate1) : > "$RESULTS"; gate1 ;;
    gate2) gate2 ;;
    all)   : > "$RESULTS"; gate1 && gate2 ;;
    *)     usage ;;
esac
```

with:

```sh
case "$CMD" in
    gate1) : > "$RESULTS"; gate1 ;;
    gate2) gate2 ;;
    gate4) gate4 ;;
    all)   : > "$RESULTS"; gate1 && gate2; rc_report; rc=$?; rc_publish_cmd; exit "$rc" ;;
    publish-cmd) rc_publish_cmd; exit 0 ;;
    *)     usage ;;
esac
```

The `all` and `publish-cmd` arms exit inside the `case`, so the trailing
`rc_report` at the foot of the script never double-prints for them.

- [ ] **Step 6: Verify and run the suite**

Run: `sh -n scripts/release_test.sh && bash tests/run_tests.sh`
Expected: no syntax error; `All host tests passed.`

- [ ] **Step 7: Commit**

```bash
git add scripts/release_test.sh scripts/lib/release_check.sh tests/release_test_test.sh
git commit -m "feat(release): Gate 4 post-publish identity + pinned publish command

Asserts the published zip carries the same commit, run-ids, and payload
sha256s as the RC that passed the gates. tag/built_utc are excluded from the
comparison since they necessarily differ. The publish step is a pinned
workflow_dispatch, never a blind tag push, which would re-resolve 'latest
successful on master' and could ship untested binaries."
```

---

### Task 5: The operator-facing recipe and sign-off record

**Files:**
- Create: `docs/release-testing.md`
- Create: `docs/superpowers/releases/TEMPLATE-rc-test.md`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: the CLI from Tasks 2–4.

- [ ] **Step 1: Write the recipe**

Create `docs/release-testing.md`:

````markdown
# Release testing recipe

How a release candidate is validated before it is published. Design rationale
lives in `docs/superpowers/specs/2026-07-26-release-testing-recipe-design.md`.

Flow: **tag an RC from master → run three gates → publish the tested artifacts
with their run-ids pinned → verify what was published.**

## 0. Pre-tag

- [ ] `origin/master` is green and is the commit you intend to ship.
- [ ] `version.txt` names the RBF this release actually carries. Gate 1
      asserts this; fix it before tagging, not after.
- [ ] `build-rbf` and `build-engine-ship` have a successful run covering any
      change to their trigger paths (`fpga/**`; `patches/**` and the build
      scripts). If not, Gate 1 will fail with "rebuild needed" and name the
      files.

## 1. Tag the RC

```bash
git checkout master && git pull
git tag v1.1.0-rc1 && git push origin v1.1.0-rc1
```

The hyphen in the tag makes `release.yml` publish it as a pre-release
automatically. Wait for the Release workflow to finish.

## 2. Gate 1 — provenance + structure (host)

```bash
git fetch --tags
scripts/release_test.sh gate1 v1.1.0-rc1
```

Downloads the RC asset, extracts it, and checks the manifest, provenance
against master, and the tree structure. Every check prints a row; any FAIL
exits non-zero.

**Most common failure:** `<artifact> is current — rebuild needed; changed: …`.
The named files changed after the artifact was built, so the zip does not
contain them. Re-run that build workflow on master, then re-dispatch
`release.yml` for the RC tag with the new run-id pinned. Do **not** relax the
check.

## 3. Gate 2 — install + boot + soak (device)

```bash
scripts/release_test.sh gate2 v1.1.0-rc1 --host 192.168.20.81
```

**This wipes the Solarus install on the card** — `games/Solarus/`, every
`_Other/Solarus_*.rbf`, `Scripts/Solarus.sh`, and the stale
`config/Solarus.s0` + `Solarus_input.map`. Quests and `controls.cfg` are
preserved and restored. The wipe is the point: it is what makes a file missing
from the zip fail loudly instead of being masked by a leftover dev deploy, and
what collapses the multi-core ambiguity on the card.

Leaves the engine **running** for Gate 3.

## 4. Gate 3 — operator visual gate (your eyes)

Nothing here is scripted; visual correctness is not self-declared in this
project. Start the real user path first:

```bash
ssh root@192.168.20.81 'sh /media/fat/Scripts/Solarus.sh'
```

Then check, in order:

| # | Check | PASS/FAIL |
|---|---|---|
| 1 | Title screen renders clean — **garbage tiles here means the wrong RBF** | |
| 2 | OSD **Load Quest** boots each installed quest | |
| 3 | Loading bar advances during preload | |
| 4 | Overworld walk — no seams, flat frames, or garbage | |
| 5 | Dialog box renders and dismisses | |
| 6 | Save-file select and in-game menu render | |
| 7 | **Define buttons** once, then all buttons act per `controls.cfg` | |
| 8 | Quest switch and core reload without a wedge | |

Item 7 is required, not optional: the eight-name OSD rename invalidates any
prior `Solarus_input.map`, and Gate 2 deleted it. Item 1 is the pairing canary
— the engine and RBF are a matched pair with no version handshake, so a
mismatch shows up as garbage tiles rather than an error.

Any FAIL stops the release.

## 5. Publish the tested artifacts

```bash
scripts/release_test.sh publish-cmd v1.1.0-rc1
```

prints the exact pinned command:

```bash
gh workflow run release.yml \
  -f tag=v1.1.0 \
  -f rbf_run_id=<pinned> \
  -f engine_run_id=<pinned>
```

**Never publish by pushing the release tag blind.** A tag push re-resolves
"latest successful on master", so if master moved you would ship binaries
nobody tested.

## 6. Gate 4 — post-publish identity (host)

```bash
scripts/release_test.sh gate4 v1.1.0 --rc v1.1.0-rc1
```

Asserts the published zip carries the same commit, run-ids, and payload
sha256s as the RC that passed Gates 1–3, and that the release is Latest and
not a pre-release.

## 7. Record the sign-off

Copy `docs/superpowers/releases/TEMPLATE-rc-test.md` to
`docs/superpowers/releases/<tag>-rc-test.md`, paste the gate tables, fill in
the Gate 3 results and the measured fps, and commit it.
````

- [ ] **Step 2: Write the sign-off template**

Create `docs/superpowers/releases/TEMPLATE-rc-test.md`:

```markdown
# Release test — <TAG>

**RC tag:** <v1.1.0-rc1>
**Release tag:** <v1.1.0>
**Tested commit:** <40-hex>
**RBF:** <Solarus_YYYYMMDD.rbf>
**rbf_run_id / engine_run_id:** <id> / <id>
**Device:** 192.168.20.81
**Operator:** <initials>
**Date:** <YYYY-MM-DD>

## Gate 1 — provenance + structure

```
<paste the results table from scripts/release_test.sh gate1>
```

## Gate 2 — install + boot + soak

```
<paste the results table from scripts/release_test.sh gate2>
```

**Measured title fps:** min <N> (floor 45)
**Soak:** <N> min, engine alive, frames advancing

## Gate 3 — operator visual gate

| # | Check | Result | Notes |
|---|---|---|---|
| 1 | Title screen clean (pairing canary) | | |
| 2 | OSD Load Quest boots each quest | | |
| 3 | Loading bar advances | | |
| 4 | Overworld walk clean | | |
| 5 | Dialog renders and dismisses | | |
| 6 | Save-file select / in-game menu | | |
| 7 | Define buttons, then all buttons correct | | |
| 8 | Quest switch + core reload, no wedge | | |

## Gate 4 — post-publish identity

```
<paste the results table from scripts/release_test.sh gate4>
```

## Verdict

<SHIPPED / BLOCKED — and why>
```

- [ ] **Step 3: Point CLAUDE.md at the recipe**

In `CLAUDE.md`, in the "Deploy recipe" section, after the sentence ending
"Read it before deploying.", add:

```markdown
**Testing a release** — tag an RC from master, validate it with
`scripts/release_test.sh`, then publish the tested artifacts with their CI
run-ids pinned. Recipe: **`docs/release-testing.md`**. Note Gate 2 WIPES the
Solarus install on the device (quests and `controls.cfg` are preserved) — that
is deliberate, and it is what makes a packaging defect fail loudly.
```

- [ ] **Step 4: Verify the docs are consistent with the code**

Run: `grep -o 'release_test.sh [a-z-]*' docs/release-testing.md | sort -u`
Expected: only `gate1`, `gate2`, `gate4`, `publish-cmd` — every one of which is
an arm of the `case` in `scripts/release_test.sh`. Cross-check with:
`grep -n ')' scripts/release_test.sh | grep -E 'gate[124]|publish-cmd|all'`

- [ ] **Step 5: Run the full suite one more time**

Run: `bash tests/run_tests.sh`
Expected: `All host tests passed.`

- [ ] **Step 6: Commit**

```bash
git add docs/release-testing.md docs/superpowers/releases/TEMPLATE-rc-test.md CLAUDE.md
git commit -m "docs(release): release-testing recipe + sign-off template

Operator-facing walkthrough of the four gates, the pinned publish step, and
the per-release sign-off record."
```

---

## Verification before opening the PR

- [ ] `bash tests/run_tests.sh` ends with `All host tests passed.`
- [ ] `shellcheck -s sh scripts/release_test.sh scripts/lib/release_check.sh tests/release_test_test.sh tests/release_manifest_test.sh .github/workflows/build-info.sh` is clean
- [ ] `sh -n scripts/release_test.sh` parses
- [ ] `python3 scripts/lib/wf_pathspec.py .github/workflows/build-rbf.yml` prints `fpga/` and `:(exclude)fpga/sim/`
- [ ] `python3 scripts/lib/wf_pathspec.py .github/workflows/build-engine-ship.yml` prints `patches/`
- [ ] The `.github/workflows/release.yml` diff parses as YAML:
      `python3 -c "import sys;print(open('.github/workflows/release.yml').read().count('BUILD-INFO'))"` ≥ 2
- [ ] `git grep -n 'TODO\|TBD\|FIXME' -- scripts/release_test.sh scripts/lib docs/release-testing.md` is empty

**The recipe itself is not validated until it has been run end-to-end on a real
RC.** Task 5 ships the documentation; the first genuine exercise is tagging an
`-rc1` and running Gates 1–4 against it. Treat the first run as part of the
work, and record its output in `docs/superpowers/releases/`. Do not claim the
recipe works before that run exists.
````
