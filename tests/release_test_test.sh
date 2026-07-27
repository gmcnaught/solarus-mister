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

rm -rf "$TMP"
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "FAILURES: $fails"; exit 1; fi
