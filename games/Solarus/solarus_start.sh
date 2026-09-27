#!/bin/bash
#
# solarus_start.sh <quest.sol> -- start the Solarus engine on one quest.
#
# Run by games/Solarus/launch.sh (rendered from mister-port.toml; the shared
# mister-hybrid-platform launcher) for every quest picked from the OSD, with
# $1 = the picked .sol, resolved to an absolute path. The platform launcher has
# already done the rest: core/profile check, lock, other fabric engines stopped,
# FPGA-ready wait, mem_wc, the engine env from mister-port.toml [launch.env]
# (SDL_VIDEODRIVER, LD_LIBRARY_PATH, HOME), and after this exec's: CPU
# placement, fabric gate, core-change watchdog, quest switching.
#
# Builtins where they do the job: this runs between the pick and the engine.
# Ends in `exec`, so the engine keeps this pid (the launcher's MH_ENGINE_PID).

GAMEDIR="${MH_GAMEDIR:-/media/fat/games/Solarus}"
QUEST_SOL=$1
RUNDIR="${SOLARUS_RUNDIR:-/tmp/solarus_quest}"

cd "$GAMEDIR" || { echo "Solarus: gamedir not found: $GAMEDIR" >&2; exit 1; }
[ -f "$QUEST_SOL" ] || { echo "Solarus: quest not found: '$QUEST_SOL'" >&2; exit 1; }

# Saves: $HOME/.solarus/<quest>/ (HOME from mister-port.toml, on the SD card).
[ -d "$HOME/.solarus" ] || mkdir -p "$HOME/.solarus" 2>/dev/null

# --- Optional local env overrides (diagnostics / experiments) ---------------
# $GAMEDIR/diag.env is sourced whenever it exists (#91, revised 2026-07-19):
# deploy.py removes it on every deploy unless run with --diag, and release zips
# never carry it, so a shipped device has no file to source. `set -a` exports
# everything it assigns. SOLARUS_NO_DIAG_ENV=1 forces it off. Engine output
# (e.g. SOLARUS_BLITTER_DIAG=1's [blitter hwperf] lines) goes to the launcher
# log, /media/fat/logs/Solarus/solarus.log.
if [ "${SOLARUS_NO_DIAG_ENV:-0}" != "1" ] && [ -f "$GAMEDIR/diag.env" ]; then
    set -a
    # shellcheck disable=SC1091  # optional runtime-only file, absent by default and not in the repo
    . "$GAMEDIR/diag.env"
    set +a
    echo "Solarus: sourced diag.env -- BLITTER_DIAG=${SOLARUS_BLITTER_DIAG:-unset}" >&2
elif [ -f "$GAMEDIR/diag.env" ]; then
    echo "Solarus: diag.env present but FORCED OFF by SOLARUS_NO_DIAG_ENV=1" >&2
fi

# --- Optional gprof capture (SOLARUS_GPROF=1) -------------------------------
# Only meaningful when solarus-run was built with -pg (SOLARUS_GPROF=1 in
# scripts/build_engine.sh). gmon.out is written on NORMAL exit into a writable
# dir (the squashfs root is read-only). The launcher stops the engine with
# SIGTERM, so a core change still flushes it; see scripts/gprof_report.sh.
if [ "${SOLARUS_GPROF:-0}" = "1" ]; then
    export GMON_OUT_PREFIX="${SOLARUS_GMON_DIR:-/media/fat/logs/Solarus}/gmon.out"
    echo "Solarus: SOLARUS_GPROF=1 -> gmon.out prefix ${GMON_OUT_PREFIX} (needs a -pg build)" >&2
fi

# --- [test option] Solarus 2.x engine selection (SOLARUS_ENGINE) ------------
# SOLARUS_ENGINE=2 runs the 2.x test build from $GAMEDIR/v2/ (pushed by
# scripts/deploy_engine2.sh); default 1 = the shipping 1.6.5 engine. The 2.x
# build carries the fabric renderer; SOLARUS_ENGINE2_STOCK=1 says the v2 tree
# is a PRISTINE upstream build, which has no blitter and draws nothing, so the
# blitter exports are skipped. Full rationale: docs/solarus2.md.
ENGINE_BIN="./solarus-run"
STOCK_V2=0
if [ "${SOLARUS_ENGINE:-1}" = "2" ]; then
    V2DIR="$GAMEDIR/v2"
    if [ ! -x "$V2DIR/solarus-run" ]; then
        echo "Solarus: SOLARUS_ENGINE=2 but $V2DIR/solarus-run is missing or not executable." >&2
        echo "  Deploy the 2.x test build first: scripts/deploy_engine2.sh" >&2
        exit 1
    fi
    ENGINE_BIN="$V2DIR/solarus-run"
    # v2 libs FIRST: libsolarus.so.2 only exists there.
    export LD_LIBRARY_PATH="$V2DIR/libs:$V2DIR:$LD_LIBRARY_PATH"
    if [ "${SOLARUS_ENGINE2_STOCK:-0}" = "1" ]; then
        STOCK_V2=1
        echo "Solarus: [test option] SOLARUS_ENGINE=2 -> STOCK 2.x engine ($ENGINE_BIN); NO video output is expected" >&2
    else
        echo "Solarus: [test option] SOLARUS_ENGINE=2 -> fabric 2.x engine ($ENGINE_BIN)" >&2
    fi
fi

# solarus-run needs a quest DIRECTORY; a .sol IS a data.solarus archive (renamed
# for the OSD 3-char extension filter). Link it in as data.solarus.
[ -d "$RUNDIR" ] || mkdir -p "$RUNDIR"
ln -sfn "$QUEST_SOL" "$RUNDIR/data.solarus" || { echo "Solarus: cannot link $QUEST_SOL into $RUNDIR" >&2; exit 1; }

# [controls] controls.cfg section = the .sol basename without extension. Unset,
# every input gets [default].
SOLARUS_QUEST_ID=${QUEST_SOL##*/}
export SOLARUS_QUEST_ID="${SOLARUS_QUEST_ID%.*}"
echo "Solarus: quest $QUEST_SOL (controls.cfg id $SOLARUS_QUEST_ID)"

# [MiSTer] FPGA blitter offload, default ON. SOLARUS_SW=1 skips it: a debugging
# fallback with no visible output (the SW present hook was deleted in Stage 4).
# [FB-in-BRAM] single persistent compositor buffer (SINGLEBUF).
if [ -z "${SOLARUS_SW:-}" ] && [ "$STOCK_V2" != "1" ]; then
    export SOLARUS_BLITTER=1
    export SOLARUS_BLITTER_SINGLEBUF=1
fi

# [#Phase1-1d] stdin is not a console here: -lua-console=yes would busy-poll a
# whole A9 core on EOF. SOLARUS_LUACONSOLE=0 restores it for debugging.
LUACONSOLE_ARG="-lua-console=no"
[ "${SOLARUS_LUACONSOLE:-1}" = "0" ] && LUACONSOLE_ARG="-lua-console=yes"

# [fps-dip] The launcher moves the USB IRQ and other processes to CPU1 and the
# engine pins its render thread to CPU0 (SOLARUS_CPUISOLATE, default ON). Some
# services re-apply their own affinity, so also run the engine and every thread
# it creates at nice -10: a nice-0 task landing on CPU0 then gets ~1/9 of it.
if [ "${SOLARUS_CPUISOLATE:-1}" = "1" ]; then
    renice -n -10 -p $$ >/dev/null 2>&1 || true
fi

echo "Solarus: launching $RUNDIR (engine=${SOLARUS_ENGINE:-1}, blitter=${SOLARUS_BLITTER:-off}, $LUACONSOLE_ARG)"
exec "$ENGINE_BIN" -force-software-rendering "$LUACONSOLE_ARG" "$RUNDIR"
