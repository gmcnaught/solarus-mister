#!/bin/bash
# Clone every quest in scripts/quests.tsv at its pinned ref into deploy/quests/.
# Quest data is never committed; this script re-fetches it.
#
# Usage: scripts/fetch_corpus.sh [quest_id ...]   (default: all)
set -u
cd "$(dirname "$0")/.." || exit 1

MANIFEST=scripts/quests.tsv
mkdir -p deploy/quests

want="$*"
rc=0
TAB="$(printf '\t')"

# shellcheck disable=SC2034  # redistributable is a real manifest column (see
# scripts/quests.tsv / test_quests_manifest.sh); this script just doesn't
# consume it -- it only clones and version-checks.
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

    # `git clone --depth 1 --branch <ref>` only works for tags/branches -- it
    # fails for a bare commit SHA. Two quests in the manifest (no tags at all)
    # are pinned by SHA, so: skip straight to a full clone + explicit
    # `checkout --detach` when $ref looks like a hex commit SHA, and also
    # fall back to it if the shallow branch/tag clone fails for any other ref.
    looks_like_sha=0
    if [ "${#ref}" -ge 4 ] && [ "${#ref}" -le 40 ] && ! printf '%s' "$ref" | grep -qE '[^0-9a-fA-F]'; then
        looks_like_sha=1
    fi

    cloned=0
    if [ "$looks_like_sha" -eq 0 ] && git clone --depth 1 --branch "$ref" "$url" "$tmp"; then
        cloned=1
    else
        rm -rf "$tmp"
        echo "   (shallow branch/tag clone unavailable, trying full clone + checkout for $ref)"
        if git clone "$url" "$tmp" && git -C "$tmp" checkout --detach "$ref"; then
            cloned=1
        else
            rm -rf "$tmp"
            echo "   FAILED to clone $id from $url at $ref" >&2
            rc=1
        fi
    fi

    if [ "$cloned" -eq 1 ]; then
        rm -rf "$dest"  # Remove any stray pre-existing $dest (safe: we checked $dest/data doesn't exist)
        if [ -e "$dest" ]; then
            # rm -rf failed to actually remove it (e.g. a permission-denied
            # file underneath) -- if we pressed on, `mv "$tmp" "$dest"` would
            # nest $tmp INSIDE the surviving $dest and still exit 0, which is
            # the silent-false-success mode this project has already hit once.
            rm -rf "$tmp"
            echo "   FAILED to clear stray $dest before install -- leaving it untouched" >&2
            rc=1
            continue
        fi
        if mv "$tmp" "$dest"; then
            echo "   ok -> $dest (expected solarus_version $version, $license)"
            actual_ver=$(sed -n 's/.*solarus_version *= *"\([^"]*\)".*/\1/p' "$dest/data/quest.dat" | head -1)
            case "$actual_ver" in
                "$version"*) ;;
                *) echo "   VERSION MISMATCH: $id manifest expects solarus_version $version, quest.dat declares '$actual_ver'" >&2; rc=1 ;;
            esac
        else
            rm -rf "$tmp" "$dest"
            echo "   FAILED to install $id at $dest" >&2
            rc=1
        fi
    fi
done < "$MANIFEST"

exit "$rc"
