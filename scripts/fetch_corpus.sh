#!/bin/bash
# Clone every quest in scripts/quests.tsv at its pinned ref into deploy/quests/.
# Quest data is never committed; this script re-fetches it.
#
# Usage: scripts/fetch_corpus.sh [quest_id ...]   (default: all)
set -u
cd "$(dirname "$0")/.."

MANIFEST=scripts/quests.tsv
mkdir -p deploy/quests

want="$*"
rc=0

while IFS=$'\t' read -r id url ref version license redistributable; do
    case "$id" in ''|'#'*) continue ;; esac
    if [ -n "$want" ]; then
        case " $want " in *" $id "*) ;; *) continue ;; esac
    fi

    dest="deploy/quests/$id"
    if [ -d "$dest/data" ]; then
        echo "== $id: already present at $dest"
        continue
    fi

    echo "== $id: cloning $url at $ref"
    if git clone --depth 1 --branch "$ref" "$url" "$dest"; then
        echo "   ok -> $dest (expected solarus_version $version, $license)"
    else
        echo "   FAILED to clone $id from $url at $ref" >&2
        rc=1
    fi
done < "$MANIFEST"

exit "$rc"
