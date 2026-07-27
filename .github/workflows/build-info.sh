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

ENGINE="$S/games/Solarus/solarus-run"
LIBSOLARUS="$S/games/Solarus/libs/libsolarus.so.1.6.5"
for p in "$RBF" "$ENGINE" "$LIBSOLARUS"; do
  [ -f "$p" ] || { echo "ERROR: payload file missing: $p" >&2; exit 1; }
done

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
  echo "sha256_solarus_run=$(sha "$ENGINE")"
  echo "sha256_libsolarus=$(sha "$LIBSOLARUS")"
} > "$S/BUILD-INFO.txt"

echo "BUILD-INFO.txt:"; cat "$S/BUILD-INFO.txt"
