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
