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
#   2. Resolve the quest to run:
#        a. the quest the user picked in the MiSTer OSD file browser, written to
#           /media/fat/config/Solarus.s0 (a .sol single-file quest archive), OR
#        b. fall back to the first *.sol in games/Solarus/quests/, OR
#        c. fall back to the first quest DIRECTORY in games/Solarus/quests/.
#   3. For a .sol pick, set up the data.solarus indirection (solarus-run needs a
#      quest DIRECTORY containing data/, data.solarus, or data.solarus.zip — a
#      .sol IS a data.solarus archive renamed for the OSD 3-char extension filter).
#   4. exec solarus-run -force-software-rendering <quest_dir>.
#
# This script never returns on success (it exec's the engine).

GAMEDIR="${GAMEDIR:-/media/fat/games/Solarus}"
QUESTDIR="$GAMEDIR/quests"
S0="/media/fat/config/Solarus.s0"
RUNDIR="/tmp/solarus_quest"

cd "$GAMEDIR" || { echo "Solarus: gamedir not found: $GAMEDIR" >&2; exit 1; }

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

# --- Resolve the quest -----------------------------------------------------
QUEST=""        # final quest path passed to solarus-run (a DIRECTORY)

# (a) OSD-picked quest. MiSTer writes the selected path to Solarus.s0 but may not
# truncate trailing bytes, so cut at the first ".sol" to recover the real path.
if [ -f "$S0" ]; then
    RAW="$(tr -d '\r' < "$S0")"
    # Trim everything after the first .sol extension (inclusive of the extension).
    SEL="${RAW%%.sol*}"
    [ -n "$SEL" ] && SEL="${SEL}.sol"
    # Strip leading/trailing whitespace.
    SEL="$(echo "$SEL" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [ -n "$SEL" ] && [ -f "$SEL" ]; then
        echo "Solarus: OSD-selected quest: $SEL"
        rm -rf "$RUNDIR"
        mkdir -p "$RUNDIR"
        ln -sf "$SEL" "$RUNDIR/data.solarus"
        QUEST="$RUNDIR"
    fi
fi

# (b) Fall back to the first *.sol archive in quests/.
if [ -z "$QUEST" ]; then
    SOL="$(ls -1 "$QUESTDIR"/*.sol 2>/dev/null | head -1)"
    if [ -n "$SOL" ] && [ -f "$SOL" ]; then
        echo "Solarus: no OSD selection — defaulting to $SOL"
        rm -rf "$RUNDIR"
        mkdir -p "$RUNDIR"
        ln -sf "$SOL" "$RUNDIR/data.solarus"
        QUEST="$RUNDIR"
    fi
fi

# (c) Fall back to the first quest DIRECTORY (containing data/ or data.solarus).
if [ -z "$QUEST" ]; then
    for d in "$QUESTDIR"/*/; do
        if [ -d "${d}data" ] || [ -f "${d}data.solarus" ] || [ -f "${d}data.solarus.zip" ]; then
            QUEST="${d%/}"
            echo "Solarus: no OSD selection — defaulting to quest dir $QUEST"
            break
        fi
    done
fi

if [ -z "$QUEST" ]; then
    echo "Solarus: no quest found." >&2
    echo "  Pick a .sol quest from the MiSTer OSD file browser (Load Quest)," >&2
    echo "  or place a <name>.sol in $QUESTDIR/ and reload the core." >&2
    exit 1
fi

# [MiSTer] FPGA blitter offload + background cache. The deterministic camera-tag
# offload composites the map on the FPGA fabric (A9 freed); the bg-cache caches the
# static background (standing overworld ~45 fps vs ~20 software). Engine-only, runs on
# the current analog-safe core. Default ON; set SOLARUS_SW=1 to force pure software.
if [ -z "$SOLARUS_SW" ]; then
    export SOLARUS_BLITTER=1
    export SOLARUS_BGCACHE=1
fi

echo "Solarus: launching $QUEST (blitter=${SOLARUS_BLITTER:-off} bgcache=${SOLARUS_BGCACHE:-off})"
exec ./solarus-run -force-software-rendering "$QUEST"
