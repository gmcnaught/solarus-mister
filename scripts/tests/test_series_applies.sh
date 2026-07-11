#!/bin/bash
# The exported series must apply cleanly onto a pristine upstream clone.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib/patch_common.sh
REF="${SOLARUS_REF:-v1.6}"
ls patches/series/*.patch >/dev/null
rm -rf /tmp/pcs_apply
pcs_clone_pinned /tmp/pcs_apply "$REF" --depth 1
pcs_git_identity /tmp/pcs_apply
git -C /tmp/pcs_apply am --3way "$(pwd)"/patches/series/*.patch
echo "SERIES APPLIES CLEAN"
