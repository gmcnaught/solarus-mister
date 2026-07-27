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
