#!/bin/bash
#
# Shared Solarus launch logic for MiSTer.
#
# Sourced/invoked by BOTH:
#   - games/Solarus/_handler.sh   (Master_Daemon auto-launch when the core loads)
#   - Scripts/Solarus.sh          (manual launch from the MiSTer Scripts menu)
#
# Responsibilities:
#   1. Set the SDL software-render environment + LD_LIBRARY_PATH.
#   2. Resolve the OSD-picked quest from /media/fat/config/Solarus.s0 via the
#      shared resolve_quest helper (quest_lib.sh). NO auto-load fallback: matching
#      the PICO-8/OpenBOR/PSX pattern, the core idles until a quest is selected, so
#      with no valid selection this script exits without launching the engine.
#      (quest_manager.sh only invokes this once a valid pick exists.)
#   3. For the .sol pick, set up the data.solarus indirection (solarus-run needs a
#      quest DIRECTORY containing data/, data.solarus, or data.solarus.zip — a
#      .sol IS a data.solarus archive renamed for the OSD 3-char extension filter).
#   4. exec solarus-run -force-software-rendering <quest_dir>.
#
# This script never returns on success (it exec's the engine).

GAMEDIR="${GAMEDIR:-/media/fat/games/Solarus}"
S0="${S0_FILE:-/media/fat/config/Solarus.s0}"
FATROOT="${FATROOT:-/media/fat}"
QUEST_LIB="${QUEST_LIB:-$GAMEDIR/quest_lib.sh}"
RUNDIR="/tmp/solarus_quest"

cd "$GAMEDIR" || { echo "Solarus: gamedir not found: $GAMEDIR" >&2; exit 1; }

. "$QUEST_LIB"   # provides resolve_quest

# --- Software-render + runtime-lib environment -----------------------------
# No X / no GPU on MiSTer: SDL must use the dummy video driver so Solarus takes
# its windowless SDL_CreateSoftwareRenderer(software_screen) path. Frames are
# pushed to the FPGA DDR framebuffer by our NativeVideoWriter present-hook.
export SDL_VIDEODRIVER=dummy
export LD_LIBRARY_PATH="$GAMEDIR/libs:$GAMEDIR:$LD_LIBRARY_PATH"

# Save directory: Solarus writes saves to $HOME/.solarus/<quest>/ (PhysFS user
# dir). MiSTer's default HOME=/root is on the READ-ONLY squashfs root, so saving
# aborts the engine ("Cannot open file 'save1.dat': read-only filesystem"). Point
# HOME at the MiSTer-standard per-core save dir on the writable SD card. Renderer-
# independent (affects SDL + blitter paths identically). HW-verified.
export HOME="/media/fat/saves/Solarus"
mkdir -p "$HOME/.solarus" 2>/dev/null

# --- Optional local env overrides (diagnostics / experiments) ---------------
# Drop a shell env file at $GAMEDIR/diag.env to toggle runtime flags WITHOUT
# editing this script — e.g. a single line `SOLARUS_BLITTER_DIAG=1` enables the
# per-60-frame [blitter hwperf] / [blitter timing] attribution log (fabric vs A9
# cycles from the fabric's HW counters). Absent by default → no-op, so normal
# play is unaffected. `set -a` exports everything the file assigns; sourced after
# the base env so it can override. (A persistent OSD/Scripts launch picks this up;
# an ssh-launched engine dies on disconnect, so use the device's own launch.)
if [ -f "$GAMEDIR/diag.env" ]; then
    set -a; . "$GAMEDIR/diag.env"; set +a
    echo "Solarus: sourced diag.env (SOLARUS_BLITTER_DIAG=${SOLARUS_BLITTER_DIAG:-unset})" >&2
fi

# --- Optional gprof capture (SOLARUS_GPROF=1) -------------------------------
# Only meaningful when solarus-run was built with -pg (SOLARUS_GPROF=1 in
# scripts/build_engine.sh). The -pg runtime writes its gmon.out on NORMAL exit;
# GMON_OUT_PREFIX redirects it to a per-pid file in a WRITABLE dir (the squashfs
# root is read-only, so an unset prefix would fail to write). Copy the resulting
# gmon.out.<pid> back to a host and run scripts/gprof_report.sh on it.
# NOTE: a kill -9 (busybox core-change kill) writes nothing — quit the quest via
# its in-game menu, or SIGTERM the process, so the atexit hook flushes gmon.out.
if [ "${SOLARUS_GPROF:-0}" = "1" ]; then
    GMON_DIR="${SOLARUS_GMON_DIR:-/media/fat/logs/Solarus}"
    mkdir -p "$GMON_DIR" 2>/dev/null
    export GMON_OUT_PREFIX="$GMON_DIR/gmon.out"
    echo "Solarus: SOLARUS_GPROF=1 -> gmon.out prefix ${GMON_OUT_PREFIX} (needs a -pg build; exit cleanly to flush)" >&2
fi

# --- Resolve the OSD-picked quest ------------------------------------------
# resolve_quest reads the OSD selection from Solarus.s0 (relative to /media/fat,
# CR/junk-tolerant) and echoes the resolved .sol path, or nothing if there is no
# valid selection. No fallback: idle until a quest is picked.
QUEST_SOL="$(resolve_quest "$S0" "$FATROOT")"

if [ -z "$QUEST_SOL" ]; then
    echo "Solarus: no quest selected." >&2
    echo "  Pick a .sol quest from the MiSTer OSD file browser (Load Quest)." >&2
    exit 1
fi
echo "Solarus: OSD-selected quest: $QUEST_SOL"

# solarus-run needs a quest DIRECTORY; a .sol IS a data.solarus archive (renamed
# for the OSD 3-char extension filter). Indirect via /tmp: link the .sol in as
# data.solarus and point the engine at the directory.
rm -rf "$RUNDIR"
mkdir -p "$RUNDIR"
ln -sf "$QUEST_SOL" "$RUNDIR/data.solarus"
QUEST="$RUNDIR"

# [MiSTer] FPGA blitter offload. The deterministic camera-tag offload composites the
# map on the FPGA fabric (A9 freed). The old background-composite cache (SOLARUS_BGCACHE)
# was REMOVED — it diverged the double-buffer's blended layers (overworld flip); the
# single carry-forward pipeline is correct. Default ON; set SOLARUS_SW=1 for pure software.
if [ -z "$SOLARUS_SW" ]; then
    export SOLARUS_BLITTER=1
    # [FB-in-BRAM] The compositor framebuffer now lives in on-chip BRAM (comp_fbram) as a
    # SINGLE persistent buffer: scanout reads buf 0, the compositor writes buf 0, and prior
    # frame pixels naturally persist. Single-buffer mode (a) stops the target_buf ping-pong
    # and (b) retires the SDRAM FB->FB carry-forward (the on-chip compositor no longer writes
    # the SDRAM FB, so carrying forward from it would read STALE pixels — the alternating-
    # frame dropout). Tears on motion by design; double-buffer (BRAM->BRAM copy) is follow-up.
    export SOLARUS_BLITTER_SINGLEBUF=1
fi

echo "Solarus: launching $QUEST (blitter=${SOLARUS_BLITTER:-off})"

# [MiSTer #Phase1-1d] Lua-console stdin thread: the daemon launches with
# stdin=/dev/null, so the console's getline() loop EOFs instantly and
# busy-polls MainLoop::is_exiting() -- a whole A9 core spinning for nothing
# (Phase 0 LD_PROFILE: docs/superpowers/2026-07-07-gprof-attribution.md, F1).
# HW-validated 2026-07-07 (combined Phase 1 soak) -> default ON (fix applied,
# -lua-console=no); explicit SOLARUS_LUACONSOLE=0 restores the stdin console
# (-lua-console=yes) for debugging.
LUACONSOLE_ARG="-lua-console=no"
if [ "${SOLARUS_LUACONSOLE:-1}" = "0" ]; then
    LUACONSOLE_ARG="-lua-console=yes"
fi
echo "Solarus: lua-console=${SOLARUS_LUACONSOLE:-1} (arg: $LUACONSOLE_ARG)"

# Core-change exit watcher (productionization #3): exit the engine when the user
# loads a different MiSTer core. `exec` below preserves this shell's PID ($$), so
# it becomes solarus-run's PID — pass it as the watcher's target. Detached
# (setsid) so it outlives the exec. No dependency on Frontier/Master_Daemon.
TARGET_PID=$$ setsid sh "$GAMEDIR/core_watch.sh" >/dev/null 2>&1 </dev/null &

# When diagnostics are on, CAPTURE the engine's stdout+stderr to a log — the daemon/
# handler launch path detaches us with both fds on /dev/null, so the per-60-frame
# [blitter hwperf] / [blitter timing] / [blitter a9split] lines (fprintf stderr) would
# otherwise be discarded even with SOLARUS_BLITTER_DIAG=1 set. Truncates per launch.
# DIAG off → exec unchanged (no log spam / no perf cost in normal play).
if [ -n "$SOLARUS_BLITTER_DIAG" ]; then
    DIAGLOG="${SOLARUS_DIAG_LOG:-/media/fat/logs/Solarus/Solarus.diag.log}"
    mkdir -p "$(dirname "$DIAGLOG")" 2>/dev/null
    echo "Solarus: DIAG capture -> $DIAGLOG" >&2
    exec ./solarus-run -force-software-rendering "$LUACONSOLE_ARG" "$QUEST" >"$DIAGLOG" 2>&1
fi

exec ./solarus-run -force-software-rendering "$LUACONSOLE_ARG" "$QUEST"
