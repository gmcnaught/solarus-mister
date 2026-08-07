#!/usr/bin/env bash
# shot_capture.sh — load a core, run the quest, and bring back title-screen captures.
#
#   shot_capture.sh <host> <label> [<local-rbf> | --installed]
#
# Companion to shot_score.py. Together they replace sdram_selftest as the judge for
# the .62 render fault: the screenshot measures the actual symptom through the
# actual datapath, so it needs none of the on-device state that made the selftest
# return different answers for the same hardware across a power cycle
# (docs/superpowers/2026-08-06-sdram-62-investigation-handoff.md).
#
# Prints the local directory holding the captures on stdout (last line). Every
# failure path prints NO-CAPTURE and exits non-zero, so a caller can never mistake
# "the core did not load" or "the engine never started" for a render verdict.
#
# Env:
#   OUTDIR      where to put captures (default: a fresh dir under ./shots/)
#   QUEST       fatroot-relative quest path
#   WAIT_TITLE  seconds to wait after engine start before capturing (default 150).
#               The whole-quest atlas preload (~31.7 MiB) holds the "Loading..."
#               bar for well over a minute; capturing early scores the load screen,
#               not the title, on BOTH devices.
#   SHOTS       how many screenshots to take (default 3, 2s apart)
#   PRECORE     device path of a core to load and settle BEFORE the Solarus core
#               (e.g. /media/fat/_Other/MalditaCastilla_43b7321.rbf). This is the
#               init-hypothesis probe: Solarus never gates SDRAM traffic on init
#               completion and never rewrites the mode register, so it may be
#               free-riding on whatever core programmed the chip beforehand. A
#               mode register survives FPGA reconfiguration but not power-off.
#   PRECORE_WAIT seconds to let PRECORE settle (default 20)
set -uo pipefail

HOST="${1:?usage: shot_capture.sh <host> <label> [<local-rbf>|--installed]}"
LABEL="${2:?}"
RBF="${3:---installed}"

QUEST="${QUEST:-games/Solarus/quests/mystery_of_solarus_dx.sol}"
WAIT_TITLE="${WAIT_TITLE:-150}"
SHOTS="${SHOTS:-3}"
OUTDIR="${OUTDIR:-shots/${LABEL}_$(date +%Y%m%d_%H%M%S)}"

SSH="ssh -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
SHOTDIR=/media/fat/screenshots/Solarus
DEV_RBF=/media/fat/_Other/SolarusShot.rbf
DEV_LOG=/media/fat/logs/Solarus/shot_capture.log

# A failed run is the run most worth diagnosing, so pull the engine log on the way
# out too — but never turn a failure into a verdict.
fail() {
    echo "$LABEL $HOST NO-CAPTURE ($*)" >&2
    mkdir -p "$OUTDIR" 2>/dev/null \
        && scp -q "root@$HOST:$DEV_LOG" "$OUTDIR/engine.log" 2>/dev/null \
        && echo "$LABEL: engine log -> $OUTDIR/engine.log" >&2
    exit 1
}

# ---- pick the core to load -------------------------------------------------
if [ "$RBF" = "--installed" ]; then
    core_path=$($SSH "root@$HOST" 'ls /media/fat/_Other/Solarus_*.rbf 2>/dev/null' | tr -d '\r')
    [ "$(printf '%s\n' "$core_path" | grep -c .)" = 1 ] \
        || fail "expected exactly one installed _Other/Solarus_*.rbf, got: $(echo "$core_path" | tr '\n' ' ')"
else
    [ -f "$RBF" ] || fail "no such rbf: $RBF"
    scp -q "$RBF" "root@$HOST:$DEV_RBF" || fail "rbf upload failed"
    # A partial scp leaves a truncated file on FAT; verify before loading it.
    want=$(shasum -a 1 "$RBF" | cut -d' ' -f1)
    got=$($SSH "root@$HOST" "sha1sum $DEV_RBF" | cut -d' ' -f1 | tr -d '\r')
    [ "$want" = "$got" ] || fail "rbf sha1 mismatch after upload ($want != $got)"
    core_path="$DEV_RBF"
fi

echo "$LABEL $HOST: loading $core_path" >&2

# ---- load, launch, capture -------------------------------------------------
# Solarus.s0 is truncated by MiSTer on core load, so the quest pick is written
# AFTER the core is up; quest_manager.sh only relaunches on an mtime change.
$SSH "root@$HOST" "
    set -u
    kill -9 \$(pidof solarus-run) 2>/dev/null

    if [ -n '${PRECORE:-}' ]; then
        echo 'load_core ${PRECORE:-}' > /dev/MiSTer_cmd
        sleep ${PRECORE_WAIT:-20}
        echo \"PRECORE=\$(tr -d '\000\r\n ' < /tmp/CORENAME 2>/dev/null)\"
    fi

    echo 'load_core $core_path' > /dev/MiSTer_cmd

    for i in \$(seq 30); do
        sleep 1
        [ \"\$(tr -d '\000\r\n ' < /tmp/CORENAME 2>/dev/null)\" = Solarus ] && break
    done
    [ \"\$(tr -d '\000\r\n ' < /tmp/CORENAME 2>/dev/null)\" = Solarus ] \
        || { echo 'ERR core-not-loaded'; exit 1; }

    # Launch the engine DIRECTLY rather than via an OSD pick. Two reasons:
    #   1. quest_manager.sh backgrounds solarus_run.sh with >/dev/null, so a crash
    #      leaves no log and the death is undiagnosable.
    #   2. Racing quest_manager risks TWO engines on the fabric, which wedges the
    #      host (see the two-engines note in the porting docs).
    # Leaving config/Solarus.s0 empty keeps quest_manager idle; the pick goes to a
    # private .s0 passed via the S0_FILE override that solarus_run.sh honours.
    : > /media/fat/config/Solarus.s0
    # A PRECORE's userspace loader outlives the core switch: gmloader (Maldita)
    # keeps ~200 MB resident, and on a 492 MB box the Solarus engine (~243 MB RSS)
    # is then OOM-killed mid-preload. Reap it, or PRECORE legs can never produce a
    # frame — which reads as a render failure and is not one.
    kill -9 \$(pidof gmloader) 2>/dev/null
    sleep 5
    printf '%s' '$QUEST' > /tmp/shot.s0
    rm -f $DEV_LOG
    setsid env S0_FILE=/tmp/shot.s0 sh /media/fat/games/Solarus/solarus_run.sh \\
        > $DEV_LOG 2>&1 </dev/null &

    for i in \$(seq 40); do
        sleep 1
        pidof solarus-run >/dev/null 2>&1 && break
    done
    pidof solarus-run >/dev/null 2>&1 || { echo 'ERR engine-not-started'; exit 1; }

    sleep $WAIT_TITLE
    pidof solarus-run >/dev/null 2>&1 || { echo 'ERR engine-died-before-capture'; exit 1; }

    rm -f /tmp/shotlist.before
    ls $SHOTDIR > /tmp/shotlist.before 2>/dev/null || : > /tmp/shotlist.before
    for i in \$(seq $SHOTS); do
        echo screenshot > /dev/MiSTer_cmd
        sleep 2
    done
    sleep 1
    ls $SHOTDIR 2>/dev/null | grep -vxF -f /tmp/shotlist.before | sed 's/^/NEW /'
    echo 'ERR none'
" > /tmp/shot_capture.$$ 2>&1
rc=$?

new=$(sed -n 's/^NEW //p' /tmp/shot_capture.$$ | tr -d '\r')
err=$(grep -m1 '^ERR ' /tmp/shot_capture.$$ | tr -d '\r')

if [ $rc -ne 0 ] && [ -z "$new" ]; then
    cat /tmp/shot_capture.$$ >&2
    rm -f /tmp/shot_capture.$$
    fail "${err:-remote step failed}"
fi
rm -f /tmp/shot_capture.$$
[ -n "$new" ] || fail "no new screenshot appeared in $SHOTDIR"

mkdir -p "$OUTDIR"
n=0
for f in $new; do
    n=$((n + 1))
    scp -q "root@$HOST:$SHOTDIR/$f" "$OUTDIR/${LABEL}_$(printf '%02d' $n).png" \
        || fail "screenshot download failed ($f)"
done
scp -q "root@$HOST:$DEV_LOG" "$OUTDIR/engine.log" 2>/dev/null || :
echo "$LABEL $HOST: captured $n frame(s)" >&2
echo "$OUTDIR"
