#!/usr/bin/env bash
# install_release.sh — put a released engine+RBF PAIR on a device, for bisecting.
#
#   install_release.sh <host> <release-zip>
#
# The engine and the RBF are a matched pair: PR #154 moved OFF_HEAP 0x80000 ->
# 0x100000 unconditionally and the fabric's SRC_QW with it, so a mismatched pair
# fetches every atlas 512 KiB low and renders silent garbage. Bisecting therefore
# has to swap BOTH, which is what this does — never just the RBF.
#
# Quests and controls.cfg are preserved (they are user data and are not part of
# the pair). The previously-installed core is moved to .rbfbak/ rather than
# deleted, so a run can be put back; shot_capture.sh --installed also requires
# exactly one _Other/Solarus_*.rbf, which the move preserves.
set -euo pipefail

HOST="${1:?usage: install_release.sh <host> <release-zip>}"
ZIP="${2:?}"
[ -f "$ZIP" ] || { echo "no such zip: $ZIP" >&2; exit 1; }

SSH="ssh -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
GAMEDIR=/media/fat/games/Solarus
BAK=$GAMEDIR/.rbfbak

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
unzip -q "$ZIP" -d "$work"

rbf=$(ls "$work"/_Other/Solarus_*.rbf)
[ "$(printf '%s\n' "$rbf" | grep -c .)" = 1 ] || { echo "zip must hold exactly one RBF" >&2; exit 1; }
echo "installing $(basename "$rbf") + engine on $HOST" >&2

# FAT cannot overwrite an open executable in place, and a partial scp leaves a
# truncated file, so the old binaries are removed before the new ones land and
# every uploaded file is sha1-verified afterwards.
$SSH "root@$HOST" "
    set -e
    kill -9 \$(pidof solarus-run) 2>/dev/null || true
    mkdir -p $BAK
    for f in /media/fat/_Other/Solarus_*.rbf; do
        [ -e \"\$f\" ] && mv -f \"\$f\" $BAK/ || true
    done
    rm -f $GAMEDIR/solarus-run $GAMEDIR/libs/libsolarus.so.1.6.5
"

# --no-xattrs/--no-mac-metadata: macOS tar otherwise emits ._ AppleDouble files,
# which FAT keeps and the device then trips over.
# BSD tar (macOS) applies --exclude only to paths listed AFTER it, so the flags
# must precede the file list; with them trailing, tar treats them as filenames.
tar --no-xattrs --no-mac-metadata \
    --exclude 'games/Solarus/quests' --exclude 'games/Solarus/controls.cfg' \
    -C "$work" -cf - games/Solarus Scripts \
    | $SSH "root@$HOST" 'tar -xof - -C /media/fat'
scp -q "$rbf" "root@$HOST:/media/fat/_Other/$(basename "$rbf")"

fail=0
for f in "_Other/$(basename "$rbf")" games/Solarus/solarus-run \
         games/Solarus/libs/libsolarus.so.1.6.5; do
    local_f="$work/$f"
    [ -f "$local_f" ] || local_f="$work/${f#_Other/}"
    want=$(shasum -a 1 "$work/$f" 2>/dev/null | cut -d' ' -f1) || want=""
    [ -n "$want" ] || continue
    got=$($SSH "root@$HOST" "sha1sum /media/fat/$f" | cut -d' ' -f1 | tr -d '\r')
    if [ "$want" != "$got" ]; then echo "SHA1 MISMATCH: $f" >&2; fail=1; fi
done
[ $fail -eq 0 ] || { echo "install verification FAILED on $HOST" >&2; exit 1; }

echo "$HOST: installed $(basename "$rbf") + engine, sha1-verified" >&2
