#!/bin/bash
#
# PGO training round-trip for the Solarus MiSTer cross-build.
#
# Cross-build PGO has one hard problem: the instrumented armhf engine can't run
# on the (arm64/x86) Docker build host, so the profile has to be collected on the
# real device (DE10-Nano) and copied back. This script drives that round-trip.
#
# Full workflow:
#   1. scripts/build_luajit.sh                          # once
#   2. SOLARUS_PGO=generate scripts/build_engine.sh     # instrumented binary
#   3. ./deploy.py --no-rbf                              # push it to the device
#   4. scripts/pgo_train.sh run [seconds]               # automated headless run
#        ...or play a quest manually (see `env` below), then:
#      scripts/pgo_train.sh collect                     # pull the .gcda back
#   5. SOLARUS_PGO=use scripts/build_engine.sh          # optimized binary
#   6. ./deploy.py                                       # ship it
#
# The instrumented binary bakes in $PGO_DIR (an ABSOLUTE host path that does not
# exist on the device) as its .gcda write location. GCOV_PREFIX/GCOV_PREFIX_STRIP
# redirect those writes to a device-writable dir at runtime; `collect` pulls that
# dir back and stages the files under $PGO_DIR so `SOLARUS_PGO=use` finds them.
#
# Runs on the HOST (needs ssh/scp to the device), NOT inside the build container.
set -euo pipefail
cd "$(dirname "$0")/.."

HOST="${SOLARUS_HOST:-192.168.20.81}"
USER="${SOLARUS_SSH_USER:-root}"
GAMEDIR="${SOLARUS_GAMEDIR:-/media/fat/games/Solarus}"
# Must match build_engine.sh's default (or export the same SOLARUS_PGO_DIR here).
PGO_DIR="${SOLARUS_PGO_DIR:-$(pwd)/build/pgo-profiles}"
# Device-writable scratch dir the .gcda are redirected to during the run.
DEV_PGO_DIR="${SOLARUS_DEV_PGO_DIR:-$GAMEDIR/pgo}"

# GCOV_PREFIX_STRIP must drop every leading component of $PGO_DIR so the runtime
# .gcda land flat under $DEV_PGO_DIR (from where they map straight back to
# $PGO_DIR for -fprofile-use). Count the non-empty components of the abs path.
pgo_strip() {
  local d="${PGO_DIR#/}" n=0 IFS='/'
  # shellcheck disable=SC2086
  set -- $d
  for _c in "$@"; do [ -n "$_c" ] && n=$((n + 1)); done
  echo "$n"
}
STRIP="$(pgo_strip)"

ssh_dev() { ssh "${USER}@${HOST}" "$@"; }

usage() {
  cat >&2 <<EOF
usage: scripts/pgo_train.sh <command> [args]

  env                Print the GCOV_PREFIX/GCOV_PREFIX_STRIP line to prepend to a
                     MANUAL device launch (play a quest yourself for the best,
                     most representative profile), then run: pgo_train.sh collect
  run [seconds]      Automated headless training run over SSH ($GAMEDIR engine,
                     default 90s), redirecting profiles to $DEV_PGO_DIR, then
                     collect. Repeatable / CI-friendly; covers boot + title +
                     intro but NOT controller gameplay (use \`env\` for that).
  collect            Pull *.gcda from $DEV_PGO_DIR into $PGO_DIR (merging with any
                     already there — profiles accumulate across runs).
  clean              Wipe the device profile dir AND the host $PGO_DIR.

env overrides: SOLARUS_HOST=$HOST  SOLARUS_GAMEDIR=$GAMEDIR
               SOLARUS_PGO_DIR=$PGO_DIR  SOLARUS_DEV_PGO_DIR=$DEV_PGO_DIR
EOF
  exit 2
}

cmd_env() {
  cat <<EOF
# Prepend these to your manual device launch so the instrumented engine writes
# its .gcda into a device-writable dir (they bake in a host path otherwise):
mkdir -p '$DEV_PGO_DIR'
export GCOV_PREFIX='$DEV_PGO_DIR'
export GCOV_PREFIX_STRIP=$STRIP
# ...then launch a quest normally and PLAY IT (real input exercises the hot
# update()/collision/quadtree loops PGO cares about). Quit cleanly (engine must
# reach exit / atexit for the counters to flush), then: scripts/pgo_train.sh collect
EOF
}

cmd_run() {
  local secs="${1:-90}"
  echo "PGO train: headless run on $HOST for ${secs}s (profiles -> $DEV_PGO_DIR)"
  # Resolve a quest the same way the handler does: prefer the OSD selection,
  # fall back to the first *.sol / quest dir. Reuse the shipped launch logic by
  # exporting GCOV_* into the environment solarus_run.sh inherits, then time-box
  # the run with a background kill (busybox has no `timeout` guarantee).
  ssh_dev "sh -c '
    set -e
    mkdir -p \"$DEV_PGO_DIR\"
    export GCOV_PREFIX=\"$DEV_PGO_DIR\"
    export GCOV_PREFIX_STRIP=$STRIP
    cd \"$GAMEDIR\"
    kill -9 \$(pidof solarus-run) 2>/dev/null || true
    ( ./solarus_run.sh >/tmp/solarus_pgo_train.log 2>&1 ) &
    RUNPID=\$!
    sleep $secs
    # SIGTERM first so the engine runs its shutdown/atexit (flushes .gcda), then
    # hard-kill any stragglers.
    kill -TERM \$(pidof solarus-run) 2>/dev/null || true
    sleep 3
    kill -9 \$(pidof solarus-run) 2>/dev/null || true
    wait \$RUNPID 2>/dev/null || true
    echo \"gcda on device:\" \$(find \"$DEV_PGO_DIR\" -name \"*.gcda\" | wc -l)
  '"
  cmd_collect
}

cmd_collect() {
  mkdir -p "$PGO_DIR"
  local n
  n="$(ssh_dev "find '$DEV_PGO_DIR' -name '*.gcda' 2>/dev/null | wc -l" | tr -d '[:space:]')"
  if [ "${n:-0}" = "0" ]; then
    echo "ERROR: no *.gcda in $DEV_PGO_DIR on $HOST." >&2
    echo "       Did the instrumented (SOLARUS_PGO=generate) binary run WITH" >&2
    echo "       GCOV_PREFIX set, and exit cleanly? See: scripts/pgo_train.sh env" >&2
    exit 1
  fi
  echo "Collecting $n .gcda from $HOST:$DEV_PGO_DIR -> $PGO_DIR"
  # tar over ssh preserves the (flat/mangled) filenames; extract into $PGO_DIR.
  ssh_dev "tar -C '$DEV_PGO_DIR' -cf - ." | tar -C "$PGO_DIR" -xf -
  echo "Done. $(find "$PGO_DIR" -name '*.gcda' | wc -l) .gcda now staged in $PGO_DIR."
  echo "Next: SOLARUS_PGO=use scripts/build_engine.sh"
}

cmd_clean() {
  echo "Wiping device $DEV_PGO_DIR and host $PGO_DIR"
  ssh_dev "rm -rf '$DEV_PGO_DIR'" || true
  rm -rf "$PGO_DIR"
}

case "${1:-}" in
  env)     cmd_env ;;
  run)     shift; cmd_run "$@" ;;
  collect) cmd_collect ;;
  clean)   cmd_clean ;;
  *)       usage ;;
esac
