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
TAB="$(printf '\t')"

while IFS="$TAB" read -r id url ref version license redistributable; do
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
    tmp="$dest.partial"
    rm -rf "$tmp"
    if git clone --depth 1 --branch "$ref" "$url" "$tmp"; then
        rm -rf "$dest"  # Remove any stray pre-existing $dest (safe: we checked $dest/data doesn't exist)
        if mv "$tmp" "$dest"; then
            echo "   ok -> $dest (expected solarus_version $version, $license)"
        else
            rm -rf "$tmp" "$dest"
            echo "   FAILED to install $id at $dest" >&2
            rc=1
        fi
    else
        rm -rf "$tmp"
        echo "   FAILED to clone $id from $url at $ref" >&2
        rc=1
    fi
done < "$MANIFEST"

exit "$rc"
