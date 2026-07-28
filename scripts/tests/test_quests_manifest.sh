#!/bin/bash
# Validate scripts/quests.tsv structurally: 6 columns, no unpinned refs, no
# duplicate ids, and expected_version compatible with the 1.6.5 engine.
# Per work/solarus/src/core/MainLoop.cpp (check_version_compatibility) and
# scripts/lib/quest_survey.py's engine_compatible: "1.5 quests can be run by
# Solarus 1.6" -- the real rule is major 1, minor 5 or 6. Pure text checks --
# no network.
set -u
cd "$(dirname "$0")/../.."

MANIFEST=scripts/quests.tsv
fails=0

fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

[ -f "$MANIFEST" ] || { echo "FAIL: $MANIFEST missing"; exit 1; }

# NOTE: this loop must NOT be the left side of a pipeline. A pipeline puts the
# loop in a subshell, so every fail() increment is discarded and the test
# reports PASS no matter what the manifest contains. Ids are collected into a
# variable and de-duplicated afterwards for exactly this reason.
ids=''
lineno=0
while IFS= read -r line; do
    lineno=$((lineno + 1))
    case "$line" in ''|'#'*) continue ;; esac

    n=$(printf '%s' "$line" | awk -F'\t' '{print NF}')
    [ "$n" -eq 6 ] || fail "line $lineno: expected 6 tab-separated columns, got $n"

    ref=$(printf '%s' "$line" | cut -f3)
    case "$ref" in
        master|main|dev|develop|'') fail "line $lineno: ref '$ref' is not pinned" ;;
    esac

    ver=$(printf '%s' "$line" | cut -f4)
    case "$ver" in
        1.5*|1.6*) ;;
        *) fail "line $lineno: expected_version '$ver' is not engine-compatible (major 1, minor 5 or 6)" ;;
    esac

    ids="$ids$(printf '%s' "$line" | cut -f1)
"
done < "$MANIFEST"

dups=$(printf '%s' "$ids" | sort | uniq -d)
[ -z "$dups" ] || fail "duplicate quest_id: $(printf '%s' "$dups" | tr '\n' ' ')"

if [ "$fails" -ne 0 ]; then
    echo "FAIL ($fails)"
    exit 1
fi
echo "PASS"
