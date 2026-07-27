#!/bin/sh
# Host test for scripts/lib/release_check.sh — the pure, device-free half of
# the release-test gates. No network, no SSH, no gh.
set -u
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
ROOT="$HERE/.."
RC_WF_PATHSPEC="$ROOT/scripts/lib/wf_pathspec.py"
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
rc_structure_check "$B" "$B/BUILD-INFO.txt" | grep -q '^FAIL.*single rbf' \
  && ok "T10 two RBFs rejected" || bad "T10 two RBFs accepted"

B="$TMP/b2"; mktree "$B"; rm "$B/games/Solarus/libs/libsolarus.so.1"
ln -s libsolarus.so.1.6.5 "$B/games/Solarus/libs/libsolarus.so.1"
rc_structure_check "$B" "$B/BUILD-INFO.txt" | grep -q '^FAIL.*libsolarus real file' \
  && ok "T11 libsolarus.so.1 symlink rejected" || bad "T11 symlink accepted"

B="$TMP/b3"; mktree "$B"; rm "$B/games/Solarus/quest_lib.sh"
rc_structure_check "$B" "$B/BUILD-INFO.txt" | grep -q '^FAIL.*script present.*missing' \
  && ok "T12 missing script rejected" || bad "T12 missing script accepted"

B="$TMP/b4"; mktree "$B"; printf '#!/bin/sh\r\necho hi\r\n' > "$B/games/Solarus/core_watch.sh"
rc_structure_check "$B" "$B/BUILD-INFO.txt" | grep -q '^FAIL.*no CRLF' \
  && ok "T13 CRLF script rejected" || bad "T13 CRLF accepted"

B="$TMP/b5"; mktree "$B"; printf 'junk' > "$B/games/Solarus/._solarus_run.sh"
rc_structure_check "$B" "$B/BUILD-INFO.txt" | grep -q '^FAIL.*no AppleDouble' \
  && ok "T14 AppleDouble rejected" || bad "T14 AppleDouble accepted"

B="$TMP/b6"; mktree "$B"; rm -f "$B"/games/Solarus/libs/lib1*.so.1
rc_structure_check "$B" "$B/BUILD-INFO.txt" | grep -q '^FAIL.*lib closure' \
  && ok "T15 short lib closure rejected" || bad "T15 short closure accepted"

B="$TMP/b7"; mktree "$B"; chmod -x "$B/games/Solarus/solarus_run.sh"
rc_structure_check "$B" "$B/BUILD-INFO.txt" | grep -q '^FAIL.*script present.*not executable' \
  && ok "T16 non-exec script rejected" || bad "T16 non-exec accepted"

B="$TMP/b8"; mktree "$B"
sed 's|^rbf_file=.*|rbf_file=Solarus_19990101.rbf|' "$B/BUILD-INFO.txt" > "$B/bi" \
  && mv "$B/bi" "$B/BUILD-INFO.txt"
rc_structure_check "$B" "$B/BUILD-INFO.txt" | grep -q '^FAIL.*rbf matches manifest' \
  && ok "T17 rbf_file mismatch rejected" || bad "T17 rbf_file mismatch accepted"

# Without the fixture relaxation, a magic-only "engine" must NOT pass — this
# is what stops a truncated binary sailing through a real release gate.
B="$TMP/b9"; mktree "$B"
( RC_ALLOW_FIXTURE=0; rc_structure_check "$B" "$B/BUILD-INFO.txt" ) \
  | grep -q '^FAIL.*armhf ELF' \
  && ok "T17b magic-only engine rejected without RC_ALLOW_FIXTURE" \
  || bad "T17b magic-only engine accepted without RC_ALLOW_FIXTURE"

# An unreadable subdirectory breaks the no-CRLF scan's enumeration partway
# through. That must surface as a FAIL, never be silently read as "no CRLF
# found" just because the (incomplete) scan happened to find none.
B="$TMP/b10"; mktree "$B"
mkdir -p "$B/games/Solarus/unreadable"
printf '#!/bin/sh\r\necho hi\r\n' > "$B/games/Solarus/unreadable/hidden.sh"
chmod 000 "$B/games/Solarus/unreadable"
rc_structure_check "$B" "$B/BUILD-INFO.txt" | grep -q '^FAIL.*no CRLF' \
  && ok "T17c CRLF-scan enumeration failure rejected, not silently passed" \
  || bad "T17c CRLF-scan enumeration failure silently passed"
chmod 755 "$B/games/Solarus/unreadable"

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

# A full-line comment inside the paths: list must NOT truncate the list —
# it must be skipped and parsing must continue to the items after it.
cat > "$TMP/comment.yml" <<'EOF'
name: x
on:
  push:
    paths:
      - 'a/**'
      # a comment line, not a list item
      - 'b/**'
EOF
python3 "$WF" "$TMP/comment.yml" > "$TMP/ps_comment" 2>"$TMP/ps_comment_err"
if grep -qx 'a/' "$TMP/ps_comment" && grep -qx 'b/' "$TMP/ps_comment"; then
  ok "T24b full-line comment in paths list does not truncate"
else
  bad "T24b comment truncated the list: out='$(cat "$TMP/ps_comment")' err='$(cat "$TMP/ps_comment_err")'"
fi

# A column-0 (zero-indent) comment inside the paths: list must ALSO not
# truncate the list. This is the original hole: the old code checked the
# indent break BEFORE the comment skip, so a comment at or below the
# paths: indent hit the indent break first and silently truncated the list
# before this line was ever reached.
cat > "$TMP/comment0.yml" <<'EOF'
name: x
on:
  push:
    paths:
      - 'a/**'
# zero-indent comment
      - 'b/**'
EOF
python3 "$WF" "$TMP/comment0.yml" > "$TMP/ps_comment0" 2>"$TMP/ps_comment0_err"
if grep -qx 'a/' "$TMP/ps_comment0" && grep -qx 'b/' "$TMP/ps_comment0"; then
  ok "T24d column-0 comment in paths list does not truncate"
else
  bad "T24d comment truncated the list: out='$(cat "$TMP/ps_comment0")' err='$(cat "$TMP/ps_comment0_err")'"
fi

# A genuinely unparseable line (not a comment, not a '- item') inside the
# paths: list must exit non-zero, never silently truncate.
cat > "$TMP/badline.yml" <<'EOF'
name: x
on:
  push:
    paths:
      - 'a/**'
      this is not a list item
EOF
python3 "$WF" "$TMP/badline.yml" >/dev/null 2>&1 \
  && bad "T24c unparseable paths-list line accepted" \
  || ok "T24c unparseable paths-list line rejected"

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

# --- rc_provenance_check / rc_artifact_check (offline, real throwaway repo) -
# These implement the substance of Gate 1's provenance assertions and had no
# direct test. Build a real repo with a resolvable tag and a local
# refs/remotes/origin/master (git tag + git update-ref — no network needed).
P="$TMP/prov"
mkdir -p "$P/.github/workflows" "$P/fpga/rtl" "$P/docs"
cp "$ROOT/.github/workflows/build-rbf.yml" "$P/.github/workflows/"
cp "$ROOT/.github/workflows/build-engine-ship.yml" "$P/.github/workflows/"
( cd "$P" && git init -q && git config user.email t@t && git config user.name t \
  && echo a > fpga/rtl/a.sv && echo d > docs/d.md \
  && git add -A && git commit -qm base ) || bad "provenance repo setup failed"
BASE=$(git -C "$P" rev-parse HEAD)

# A commit that touches an rbf trigger path (fpga/rtl/**).
( cd "$P" && echo more >> fpga/rtl/a.sv && git commit -qam fpga )
FPGACOMMIT=$(git -C "$P" rev-parse HEAD)

# The tag commit itself: docs-only, so nothing further touches either
# artifact's trigger paths between FPGACOMMIT and the tag.
( cd "$P" && echo more >> docs/d.md && git commit -qam docs )
TAGSHA=$(git -C "$P" rev-parse HEAD)
git -C "$P" tag rc-v1 "$TAGSHA"
git -C "$P" update-ref refs/remotes/origin/master "$TAGSHA"

mkmanifest "$P/BUILD-INFO.txt"
sed -e "s|^tag=.*|tag=rc-v1|" \
    -e "s|^commit=.*|commit=$TAGSHA|" \
    -e "s|^rbf_head_sha=.*|rbf_head_sha=$FPGACOMMIT|" \
    -e "s|^engine_head_sha=.*|engine_head_sha=$FPGACOMMIT|" \
    "$P/BUILD-INFO.txt" > "$P/bi" && mv "$P/bi" "$P/BUILD-INFO.txt"

out=$(rc_provenance_check "$P" rc-v1 "$P/BUILD-INFO.txt")
echo "$out" | grep -q '^FAIL' \
  && bad "T28 clean provenance has a FAIL row: $(echo "$out" | grep '^FAIL' | tr '\n' ';')" \
  || ok "T28 clean provenance is all PASS"

echo "$out" | grep -q '^PASS.*manifest commit == tag' \
  && ok "T29 assertion 1 (manifest commit == tag) passes on match" \
  || bad "T29 manifest commit == tag row missing/failed"

echo "$out" | grep -q '^PASS.*tag is on master' \
  && ok "T29b assertion 2 (tag ancestor of origin/master) passes" \
  || bad "T29b tag is on master row missing/failed"

echo "$out" | grep -q '^PASS.*rbf is an ancestor' \
  && echo "$out" | grep -q '^PASS.*rbf is current' \
  && ok "T29c assertion 3 (head_sha ancestor + no stale trigger change) passes" \
  || bad "T29c rbf ancestor/current rows missing/failed"

# Assertion 1, failing case: manifest commit does not match the tag's commit.
sed "s|^commit=.*|commit=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef|" \
  "$P/BUILD-INFO.txt" > "$P/BUILD-INFO-badcommit.txt"
rc_provenance_check "$P" rc-v1 "$P/BUILD-INFO-badcommit.txt" \
  | grep -q '^FAIL.*manifest commit == tag' \
  && ok "T30 manifest commit != tag is a FAIL" \
  || bad "T30 manifest commit mismatch not detected"

# Assertion 2, failing case: the tag is on a side branch, never merged, so it
# is not an ancestor of origin/master.
( cd "$P" && git checkout -q -b side "$BASE" && echo z > side.txt \
  && git add side.txt && git commit -qm side )
SIDESHA=$(git -C "$P" rev-parse HEAD)
git -C "$P" tag rc-side "$SIDESHA"
sed -e "s|^tag=.*|tag=rc-side|" -e "s|^commit=.*|commit=$SIDESHA|" \
    "$P/BUILD-INFO.txt" > "$P/BUILD-INFO-side.txt"
rc_provenance_check "$P" rc-side "$P/BUILD-INFO-side.txt" \
  | grep -q '^FAIL.*tag is on master' \
  && ok "T31 tag on an unmerged side branch is a FAIL" \
  || bad "T31 tag-on-side-branch not detected"

# Assertion 3, failing case a: the artifact's head_sha is not an ancestor of
# the tag at all (built off the side branch, tag is on the main line).
sed "s|^rbf_head_sha=.*|rbf_head_sha=$SIDESHA|" "$P/BUILD-INFO.txt" \
  > "$P/BUILD-INFO-badanc.txt"
rc_provenance_check "$P" rc-v1 "$P/BUILD-INFO-badanc.txt" \
  | grep -q '^FAIL.*rbf is an ancestor' \
  && ok "T32 artifact head_sha not an ancestor of the tag is a FAIL" \
  || bad "T32 non-ancestor head_sha not detected"

# Assertion 3, failing case b: head_sha IS an ancestor of the tag, but a
# commit that touched the rbf workflow's own trigger paths (the fpga/rtl
# change) sits between them — the artifact is stale and must be rebuilt.
sed "s|^rbf_head_sha=.*|rbf_head_sha=$BASE|" "$P/BUILD-INFO.txt" \
  > "$P/BUILD-INFO-stale.txt"
rc_provenance_check "$P" rc-v1 "$P/BUILD-INFO-stale.txt" \
  | grep -q '^FAIL.*rbf is current' \
  && ok "T33 stale artifact (trigger-path change since build) is a FAIL" \
  || bad "T33 stale artifact not detected"

# Assertion 3, failing case c: the workflow's own paths: list contains an
# invalid git pathspec magic. wf_pathspec.py passes such tokens through
# unchanged (it only rewrites /** and /* suffixes), so wf_pathspec.py itself
# exits 0 having printed it — but `git diff -- ':(nonsense)...'` then fails
# with status 128 and empty stdout. That lands on rc_artifact_check's `*`
# catch-all arm (a real git-diff failure), not its `2` (unparseable
# workflow) arm. Uses the existing provenance fixture, where cat-file -e and
# merge-base --is-ancestor already pass for rbf_head_sha=FPGACOMMIT.
cp "$P/.github/workflows/build-rbf.yml" "$P/.github/workflows/build-rbf.yml.orig"
cat > "$P/.github/workflows/build-rbf.yml" <<'EOF'
name: x
on:
  push:
    paths:
      - ':(nonsense)a.txt'
EOF
out=$(rc_provenance_check "$P" rc-v1 "$P/BUILD-INFO.txt")
mv "$P/.github/workflows/build-rbf.yml.orig" "$P/.github/workflows/build-rbf.yml"
echo "$out" | grep -q '^FAIL.*rbf is current.*git diff failed (status 128)' \
  && ok "T34 invalid pathspec magic in workflow hits the git-diff-failure arm" \
  || bad "T34 git-diff-failure arm not exercised: $(echo "$out" | grep 'rbf is current')"

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

rm -rf "$TMP"
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "FAILURES: $fails"; exit 1; fi
