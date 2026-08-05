#!/bin/bash
#
# TEST OPTION: push the stock Solarus 2.x engine build to the device, INTO ITS
# OWN DIRECTORY (/media/fat/games/Solarus/v2/). Read docs/solarus2.md first.
#
# This deliberately does NOT touch anything the shipping install uses. It writes
# only under $GAMEDIR/v2/, so:
#   * the 1.6.5 engine, its libs, the RBF, quests and controls.cfg are untouched;
#   * the 2.x build is selected at launch by SOLARUS_ENGINE=2 (games/Solarus/
#     solarus_run.sh), normally set in $GAMEDIR/diag.env;
#   * "uninstalling" the experiment is `rm -rf $GAMEDIR/v2` plus dropping that
#     diag.env line — there is no shipping state to restore.
# deploy.py stays the tool for the real install; keeping the two separate is why
# a 2.x experiment cannot brick a working device.
#
# Prerequisites (in order):
#   scripts/docker_run.sh scripts/build_engine2.sh
#   SOLARUS_BUILD_DIR=build/armhf-v2 SOLARUS_DEPLOY_LIBS=deploy/v2/libs \
#     scripts/docker_run.sh scripts/collect_runtime_libs.sh
#
# Usage:
#   scripts/deploy_engine2.sh [--host 192.168.20.81]
#
# Device gotchas honoured here (see CLAUDE.md): busybox has no pkill; FAT cannot
# overwrite an open executable in place; a partial scp leaves a TRUNCATED file,
# so every artifact is uploaded to a temp name, sha1-verified there, and only
# then moved into place; FAT cannot chown, so no tar -p / ownership flags.
set -euo pipefail
cd "$(dirname "$0")/.."

HOST="${SOLARUS_HOST:-192.168.20.81}"
USER=root
GAMEDIR=/media/fat/games/Solarus
V2DIR="$GAMEDIR/v2"
SRC_BIN="${SOLARUS2_DEPLOY_BIN:-build/armhf-v2/solarus-run}"
SRC_LIBS="${SOLARUS2_DEPLOY_LIBS:-deploy/v2/libs}"
SRC_BUILD="${SOLARUS2_BUILD_DIR:-build/armhf-v2}"

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

rsh() { ssh "$USER@$HOST" "$1"; }

# --- Preflight: everything must exist BEFORE we kill the running engine ------
[ -f "$SRC_BIN" ] || { echo "MISSING: $SRC_BIN — run scripts/build_engine2.sh" >&2; exit 1; }
[ -d "$SRC_LIBS" ] || { echo "MISSING: $SRC_LIBS — run collect_runtime_libs.sh with SOLARUS_DEPLOY_LIBS=$SRC_LIBS" >&2; exit 1; }

# libsolarus.so.2* is the engine's OWN library: collect_runtime_libs.sh treats it
# as the BFS seed and never copies it, so stage it here explicitly, exactly as
# build-engine-ship.yml does for the 1.6 line. Ship it under BOTH the versioned
# name and the soname as REAL files — the destination is FAT and cannot hold the
# build tree's libsolarus.so.2 -> .so.2.1.0 symlink.
# shellcheck disable=SC2012  # fixed, simple name pattern (libsolarus.so.2.<x>.<y>); ls-glob + head is the repo idiom
LIBSOL="$(ls "$SRC_BUILD"/libsolarus.so.2.* 2>/dev/null | head -1 || true)"
[ -n "$LIBSOL" ] || { echo "MISSING: $SRC_BUILD/libsolarus.so.2.* — run scripts/build_engine2.sh" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/libs"
cp -L "$SRC_LIBS"/*.so* "$STAGE/libs/" 2>/dev/null || true
cp -L "$LIBSOL" "$STAGE/libs/$(basename "$LIBSOL")"
cp -L "$LIBSOL" "$STAGE/libs/libsolarus.so.2"
nlibs=$(find "$STAGE/libs" -maxdepth 1 -type f -name '*.so*' | wc -l | tr -d ' ')
if [ "$nlibs" -lt 20 ]; then
  echo "ERROR: lib closure looks too small ($nlibs) — did collect_runtime_libs.sh run?" >&2
  exit 1
fi
echo "== staging $nlibs libs + solarus-run for $USER@$HOST:$V2DIR =="

# --- Stop any running engine so FAT can replace the binary -------------------
# busybox: no pkill, and a bare `kill -9` with empty pidof output errors out.
# shellcheck disable=SC2016  # single quotes are the point: $p must expand on the DEVICE, not here
rsh 'p=$(pidof solarus-run); [ -n "$p" ] && kill -9 $p 2>/dev/null; sleep 1; true'
rsh "mkdir -p $V2DIR/libs"

# --- Upload the binary: temp name, sha1-verify, then swap --------------------
want=$(sha1sum "$SRC_BIN" | awk '{print $1}')
rsh "rm -f $V2DIR/solarus-run.new"
scp -q "$SRC_BIN" "$USER@$HOST:$V2DIR/solarus-run.new"
got=$(rsh "sha1sum $V2DIR/solarus-run.new 2>/dev/null" | awk '{print $1}')
if [ "$got" != "$want" ]; then
  rsh "rm -f $V2DIR/solarus-run.new"
  echo "FATAL: solarus-run failed sha1 verification ($got != $want)" >&2
  exit 1
fi
rsh "mv -f $V2DIR/solarus-run.new $V2DIR/solarus-run && chmod 755 $V2DIR/solarus-run"
echo "    solarus-run sha1 ok (${want:0:12}) -> in place"

# --- Upload the libs: stage dir, verify EVERY lib there, then swap -----------
# Same discipline as deploy.py: a FAT extract over an existing closure can leave
# a stale .so silently in place, so nothing touches the live libs/ until the
# whole staged set verifies.
RSTAGE="$V2DIR/libs/.stage"
rsh "rm -rf $RSTAGE && mkdir -p $RSTAGE"
# macOS bsdtar: drop AppleDouble/xattr cruft FAT would materialise as ._ files.
# GNU tar has neither flag, so probe instead of hardcoding — a silently-failing
# tar here would upload an EMPTY stage dir, which the sha1 loop below would then
# report as a wall of mismatches for no obvious reason.
TAR_FLAGS=()
if tar --no-mac-metadata --version >/dev/null 2>&1; then
  TAR_FLAGS=(--no-xattrs --no-mac-metadata)
fi
# busybox tar -xof on the far side: no ownership restore (FAT cannot chown).
tar "${TAR_FLAGS[@]}" -C "$STAGE/libs" -cf - . \
  | ssh "$USER@$HOST" "cd $RSTAGE && tar -xof -"
fail=0
while read -r h n; do
  rh=$(rsh "sha1sum $RSTAGE/$n 2>/dev/null" | awk '{print $1}')
  [ "$rh" = "$h" ] || { echo "  sha1 MISMATCH: $n" >&2; fail=1; }
done < <(cd "$STAGE/libs" && sha1sum ./*.so* | sed 's|\./||')
if [ "$fail" = 1 ]; then
  rsh "rm -rf $RSTAGE"   # leave whatever was there intact
  echo "FATAL: staged libs failed verification — device left untouched" >&2
  exit 1
fi
rsh "rm -f $V2DIR/libs/*.so* $V2DIR/libs/._* 2>/dev/null; mv -f $RSTAGE/*.so* $V2DIR/libs/ && rmdir $RSTAGE"
echo "    sha1 ok for all $nlibs libs -> swapped into place"

# --- Post-deploy probe: does it actually link on the device? -----------------
# `-help` exercises the full dynamic loader without needing a quest, so a missing
# or ABI-incompatible .so fails HERE rather than as a silent black launch.
echo "== loader probe: v2/solarus-run -help =="
if ! rsh "cd $V2DIR && LD_LIBRARY_PATH=$V2DIR/libs:$V2DIR ./solarus-run -help >/dev/null 2>/tmp/v2probe.err"; then
  echo "FATAL: v2/solarus-run failed to run. Device stderr:" >&2
  rsh "cat /tmp/v2probe.err" >&2 || true
  echo "  Fix the closure (collect_runtime_libs.sh) and redeploy." >&2
  exit 1
fi
echo "    OK — links and runs"

echo ""
echo "Deployed the STOCK Solarus 2.x test engine to $V2DIR."
echo "To select it at launch, add this line to $GAMEDIR/diag.env:"
echo "    SOLARUS_ENGINE=2"
echo "Then load the Solarus core and pick a quest as usual."
echo ""
echo "EXPECT NO PICTURE: this build has no MiSTer video hook. Watch the engine"
echo "through its log — SOLARUS_ENGINE=2 always captures stdout/stderr to"
echo "/media/fat/logs/Solarus/Solarus.diag.log. See docs/solarus2.md."
