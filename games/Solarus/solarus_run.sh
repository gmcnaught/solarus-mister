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

# shellcheck disable=SC1090  # dynamic path (env-overridable); resolve_quest is defined in quest_lib.sh
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

# --- Write-combining DDR mapping (optional) --------------------------------
# The engine writes every command, every staged atlas pixel and every grid cell
# into the blitter DDR window. A /dev/mem mmap of that window is unavoidably
# Strongly-Ordered (ARM's phys_mem_access_prot() returns pgprot_noncached() for
# any pfn outside the kernel memblock, and a fabric address always is), so those
# stores cannot merge -- measured 91.2 MB/s vs 852.8 MB/s through mem_wc, which
# maps the same physical pages Normal Non-Cacheable.
#
# STRICTLY OPTIONAL. The module is built out-of-tree against one kernel's
# vermagic, so a MiSTer update makes insmod start failing on users' machines.
# That must cost frame rate, not boot: failure is ignored here, and the engine
# falls back to /dev/mem on its own (logging which mapping it got).
#
# phys_size MUST cover the engine's whole 18 MiB window (BLT_DDR_SIZE =
# 0x01200000); a shorter allowlist makes mem_wc return -EPERM and the engine
# silently takes the slow path. SOLARUS_NO_WC=1 forces the fallback for A/B.
#
# A module already loaded with the WRONG allowlist is the dangerous case, because
# it degrades SILENTLY: mem_wc returns -EPERM for the part of our window it does
# not cover, the engine's probe fails, and it falls back with no error anywhere.
# A 16 MiB allowlist is the easy mistake -- it looks right and covers the heap,
# but misses GRID_BUF. So check the loaded parameters rather than just the device
# node, and replace the module when they do not cover us.
#
# Replacement is only ever attempted HERE, before the engine starts, because that
# is the only moment we know no Solarus engine holds an fd on it.
WC_BASE=0x3B000000
WC_SIZE=0x01200000        # MUST match BLT_DDR_SIZE in mister_blitter_renderer.cpp

mem_wc_covers_us() {
    # Absent module -> not covered. Unrestricted (phys_size==0) -> covers everything.
    [ -r /sys/module/mem_wc/parameters/phys_size ] || return 1
    _sz=$(cat /sys/module/mem_wc/parameters/phys_size 2>/dev/null) || return 1
    _bs=$(cat /sys/module/mem_wc/parameters/phys_base 2>/dev/null) || return 1
    [ "$_sz" -eq 0 ] 2>/dev/null && return 0
    [ "$_bs" -le $((WC_BASE)) ] 2>/dev/null || return 1
    [ $((_bs + _sz)) -ge $((WC_BASE + WC_SIZE)) ] 2>/dev/null || return 1
    return 0
}

if [ -f "$GAMEDIR/mem_wc.ko" ] && ! mem_wc_covers_us; then
    if [ -e /dev/mem_wc ]; then
        echo "[solarus] mem_wc loaded but its allowlist does not cover" \
             "$WC_BASE+$WC_SIZE; replacing" >&2
        # NEVER `rmmod -f`. Force-unload bypasses the module refcount, which is
        # exactly what protects a running engine that holds an fd on this device.
        # A plain rmmod fails with EBUSY in that case, and that failure is the
        # correct outcome: leave the module alone and take the slow mapping.
        if ! rmmod mem_wc 2>/dev/null; then
            echo "[solarus] mem_wc is in use (another engine?); leaving it." \
                 "This launch will use the slower strongly-ordered mapping." >&2
        fi
    fi
    if [ ! -e /dev/mem_wc ]; then
        insmod "$GAMEDIR/mem_wc.ko" phys_base=$WC_BASE phys_size=$WC_SIZE 2>/dev/null || true
        if mem_wc_covers_us; then
            echo "[solarus] mem_wc loaded, window $WC_BASE+$WC_SIZE write-combining" >&2
        else
            echo "[solarus] mem_wc unavailable (kernel mismatch?); using the" \
                 "strongly-ordered mapping. This costs frame rate, not correctness." >&2
        fi
    fi
fi

# --- Optional local env overrides (diagnostics / experiments) ---------------
# Drop a shell env file at $GAMEDIR/diag.env to toggle runtime flags WITHOUT
# editing this script — e.g. a single line `SOLARUS_BLITTER_DIAG=1` enables the
# per-60-frame [blitter hwperf] / [blitter timing] attribution log (fabric vs A9
# cycles from the fabric's HW counters). `set -a` exports everything the file
# assigns; sourced after the base env so it can override.
#
# SAFETY (#91), REVISED 2026-07-19: presence of the file is now sufficient —
# diag.env is sourced whenever it exists. The end-user protection now rests on
# ABSENCE rather than on a second env var: deploy.py removes diag.env on every
# deploy unless it is run with --diag, so a shipped device simply has no file to
# source. Diagnostics remain opt-in; the opt-in moved from "set a launch var" to
# "deploy with --diag / create the file yourself".
#
# WHY THE CHANGE: the two-key scheme (file AND SOLARUS_ALLOW_DIAG_ENV=1) meant a
# validation session that created diag.env but launched without the var silently
# measured the DEFAULT path — the same class of trap as a presence-based flag
# where =0 still enables. Silent no-ops during HW validation cost real sessions.
#
# RESIDUAL RISK, stated plainly: a device carrying a stale diag.env that is NOT
# re-deployed will now auto-enable whatever it contains. Set SOLARUS_NO_DIAG_ENV=1
# in the launch env to force it off without deleting the file.
if [ "${SOLARUS_NO_DIAG_ENV:-0}" != "1" ] && [ -f "$GAMEDIR/diag.env" ]; then
    set -a
    # shellcheck disable=SC1091  # optional runtime-only file, absent by default and not in the repo
    . "$GAMEDIR/diag.env"
    set +a
    # Echo the flags a validation session actually depends on, so the log proves
    # what was in effect rather than what was intended.
    echo "Solarus: sourced diag.env — BLITTER_DIAG=${SOLARUS_BLITTER_DIAG:-unset}" >&2
elif [ -f "$GAMEDIR/diag.env" ]; then
    echo "Solarus: diag.env present but FORCED OFF by SOLARUS_NO_DIAG_ENV=1" >&2
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

# --- [test option] Solarus 2.x engine selection (SOLARUS_ENGINE) ------------
# SOLARUS_ENGINE=2 runs the STOCK Solarus 2.x test build from $GAMEDIR/v2/
# instead of the shipping 1.6.5 engine. Set it in diag.env (sourced above) and
# push the build with scripts/deploy_engine2.sh. Default 1 = shipping engine,
# so an ordinary install never sees this path.
#
# BE CLEAR ABOUT WHAT THIS DOES: the 2.x build is pristine upstream — it has NO
# MiSTer video hook, so it renders NOTHING to the screen. It boots, loads the
# OSD-picked quest and runs the game logic headless. Watch it through the log,
# not the TV. Full rationale + what a real 2.x port would need: docs/solarus2.md.
ENGINE_BIN="./solarus-run"
if [ "${SOLARUS_ENGINE:-1}" = "2" ]; then
    V2DIR="$GAMEDIR/v2"
    if [ ! -x "$V2DIR/solarus-run" ]; then
        echo "Solarus: SOLARUS_ENGINE=2 but $V2DIR/solarus-run is missing or not executable." >&2
        echo "  Deploy the 2.x test build first: scripts/deploy_engine2.sh" >&2
        exit 1
    fi
    ENGINE_BIN="$V2DIR/solarus-run"
    # v2 libs FIRST: libsolarus.so.2 only exists there, and the 2.x binary must
    # not pick up the 1.6 closure's libsolarus by accident.
    export LD_LIBRARY_PATH="$V2DIR/libs:$V2DIR:$LD_LIBRARY_PATH"
    echo "Solarus: [test option] SOLARUS_ENGINE=2 -> stock 2.x engine ($ENGINE_BIN)" >&2
    echo "Solarus: [test option] NO video output is expected from this engine." >&2
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

# [controls] Per-quest controller mapping. The engine resolves its section of
# controls.cfg from this id — the .sol basename without extension. Without it
# (SOLARUS_QUEST_ID unset/empty), mister_load_controls() passes "" as the quest id,
# so mc_load() never requests a quest section at all and every input just gets
# [default] — there is no write_dir fallback.
SOLARUS_QUEST_ID="$(basename "$QUEST_SOL")"
SOLARUS_QUEST_ID="${SOLARUS_QUEST_ID%.*}"
export SOLARUS_QUEST_ID
echo "Solarus: quest id for controls.cfg: $SOLARUS_QUEST_ID"

# [MiSTer] FPGA blitter offload. The deterministic camera-tag offload composites the
# map on the FPGA fabric (A9 freed). The old background-composite cache (SOLARUS_BGCACHE)
# was REMOVED — it diverged the double-buffer's blended layers (overworld flip); the
# single carry-forward pipeline is correct. Default ON; SOLARUS_SW=1 skips the blitter
# exports below, but the SW video-present hook itself was deleted in Stage 4
# (mister_present_frame + NativeVideoWriter_WriteFrame) — this is a disconnected
# debugging fallback only (no visible output), not a working software path.
#
# Skipped entirely for SOLARUS_ENGINE=2: the stock 2.x engine has no blitter code
# to enable, and exporting the flags there would make a log read as if the fabric
# path were live when nothing is driving it.
if [ -z "$SOLARUS_SW" ] && [ "${SOLARUS_ENGINE:-1}" != "2" ]; then
    export SOLARUS_BLITTER=1
    # [FB-in-BRAM] The compositor framebuffer now lives in on-chip BRAM (comp_fbram) as a
    # SINGLE persistent buffer: scanout reads buf 0, the compositor writes buf 0, and prior
    # frame pixels naturally persist. Single-buffer mode (a) stops the target_buf ping-pong
    # and (b) retires the SDRAM FB->FB carry-forward (the on-chip compositor no longer writes
    # the SDRAM FB, so carrying forward from it would read STALE pixels — the alternating-
    # frame dropout). Tears on motion by design; double-buffer (BRAM->BRAM copy) is follow-up.
    export SOLARUS_BLITTER_SINGLEBUF=1
fi

echo "Solarus: launching $QUEST (engine=${SOLARUS_ENGINE:-1}, blitter=${SOLARUS_BLITTER:-off})"

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
#
# ALWAYS capture for SOLARUS_ENGINE=2: that engine draws nothing, so the log is
# the only way to observe it at all. Capturing unconditionally there means a test
# run can't silently produce no evidence.
if [ -n "$SOLARUS_BLITTER_DIAG" ] || [ "${SOLARUS_ENGINE:-1}" = "2" ]; then
    DIAGLOG="${SOLARUS_DIAG_LOG:-/media/fat/logs/Solarus/Solarus.diag.log}"
    mkdir -p "$(dirname "$DIAGLOG")" 2>/dev/null
    # Probe writability before committing to the redirect. `exec >file` on a path
    # we cannot create kills this shell BEFORE the engine ever starts — tolerable
    # for an opt-in diagnostic, but the SOLARUS_ENGINE=2 capture is ALWAYS on, so
    # an unwritable log there would turn "no picture, read the log" into "nothing
    # ran at all". Degrade to an uncaptured launch and say so.
    if : >"$DIAGLOG" 2>/dev/null; then
        echo "Solarus: DIAG capture -> $DIAGLOG" >&2
        exec "$ENGINE_BIN" -force-software-rendering "$LUACONSOLE_ARG" "$QUEST" >"$DIAGLOG" 2>&1
    fi
    echo "Solarus: WARNING cannot write $DIAGLOG — launching WITHOUT capture" >&2
fi

exec "$ENGINE_BIN" -force-software-rendering "$LUACONSOLE_ARG" "$QUEST"
