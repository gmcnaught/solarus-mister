#!/bin/bash
# ACCEPTANCE GATE: the tree produced by applying patches/series/*.patch must equal
# the CURRENT build_engine.sh output EXCEPT for one intentional delta: re-enabling
# SOLARUS_CULL_MARGIN, which the current build silently drops (a later
# Entities.cpp reset @848 erases PYCULL). That intended delta is pinned in
# patches/tests/expected-delta.diff; ANY other divergence fails the gate.
# Pass REGEN=1 to (re)write the reference delta instead of checking it.
# Run in-container for GNU-tool fidelity.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib/patch_common.sh
REF="${SOLARUS_REF:-v1.6}"
EXPECTED="patches/tests/expected-delta.diff"

bash scripts/capture_golden.sh /tmp/golden >/dev/null
rm -rf /tmp/series
git clone -q --depth 1 --branch "$REF" https://gitlab.com/solarus-games/solarus.git /tmp/series
pcs_git_identity /tmp/series
git -C /tmp/series am --3way "$(pwd)"/patches/series/*.patch >/dev/null
rm -rf /tmp/series_out; mkdir -p /tmp/series_out
( cd /tmp/series && git ls-files ) | while read -r f; do
  mkdir -p "/tmp/series_out/$(dirname "$f")"; cp "/tmp/series/$f" "/tmp/series_out/$f"
done

# 1) Only src/entities/Entities.cpp may differ. (diff exits 1 on any difference;
#    tolerate that so set -e/pipefail doesn't abort before we inspect the list.)
differ=$( { cd /tmp/golden && diff -rq . /tmp/series_out 2>/dev/null || true; } | awk '{print $2}' | sed 's#^\./##' | sort )
expected_file="src/entities/Entities.cpp"
if [ "$differ" != "$expected_file" ]; then
  echo "EQUIVALENCE FAILED — unexpected files differ:"; echo "$differ"; exit 1
fi

# 2) The Entities.cpp delta must be EXACTLY the pinned cull-margin re-enablement.
live=$(mktemp)
diff -u --label a/src/entities/Entities.cpp --label b/src/entities/Entities.cpp \
  /tmp/golden/src/entities/Entities.cpp /tmp/series_out/src/entities/Entities.cpp > "$live" || true
mkdir -p "$(dirname "$EXPECTED")"
if [ "${REGEN:-0}" = "1" ]; then
  cp "$live" "$EXPECTED"; echo "REGEN — wrote $EXPECTED"; exit 0
fi
if diff -u "$EXPECTED" "$live"; then
  echo "EQUIVALENCE OK — series == current build + only the intended cull-margin re-enable"
else
  echo "EQUIVALENCE FAILED — Entities.cpp delta differs from the pinned cull-margin reference"; exit 1
fi
