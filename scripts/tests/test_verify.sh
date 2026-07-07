#!/bin/bash
# The verify gate must PASS on a series-applied tree and BITE on pristine upstream.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib/patch_common.sh
REF="${SOLARUS_REF:-v1.6}"

rm -rf /tmp/vtree
git clone -q --depth 1 --branch "$REF" https://gitlab.com/solarus-games/solarus.git /tmp/vtree
pcs_git_identity /tmp/vtree
git -C /tmp/vtree am --3way "$(pwd)"/patches/series/*.patch >/dev/null
bash scripts/verify_patches.sh /tmp/vtree
echo "VERIFY PASS (patched) confirmed"

rm -rf /tmp/pristine
git clone -q --depth 1 --branch "$REF" https://gitlab.com/solarus-games/solarus.git /tmp/pristine
if bash scripts/verify_patches.sh /tmp/pristine >/dev/null 2>&1; then
  echo "VERIFY DID NOT BITE on pristine — BUG"; exit 1
else
  echo "VERIFY correctly failed on pristine"
fi
