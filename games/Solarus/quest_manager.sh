#!/bin/sh
# quest_manager.sh — Solarus quest lifecycle manager (productionization #2).
#
# Launched on core load (by _handler.sh, and by Scripts/Solarus.sh after
# load_core). Matches the PICO-8/OpenBOR/PSX pattern: the core loads with NO
# game; a quest runs only once picked from the OSD. Polls Solarus.s0 for a NEW
# pick (detected by mtime, so a stale .s0 from a prior session is NOT auto-loaded),
# launches the engine on the selection, switches on a different pick, returns to
# idle if the engine exits, and exits (killing the engine) on a core change.
#
# Env (production defaults):
#   GAMEDIR=/media/fat/games/Solarus  QUEST_LIB=$GAMEDIR/quest_lib.sh
#   CORENAME_FILE=/tmp/CORENAME  EXPECT_CORE=Solarus
#   S0_FILE=/media/fat/config/Solarus.s0  FATROOT=/media/fat  POLL_SEC=1
#   LAUNCH_CMD= (unset -> background solarus_run.sh; set -> "$LAUNCH_CMD <quest>" for tests)
set -u
GAMEDIR="${GAMEDIR:-/media/fat/games/Solarus}"
QUEST_LIB="${QUEST_LIB:-$GAMEDIR/quest_lib.sh}"
CORENAME_FILE="${CORENAME_FILE:-/tmp/CORENAME}"
EXPECT_CORE="${EXPECT_CORE:-Solarus}"
S0_FILE="${S0_FILE:-/media/fat/config/Solarus.s0}"
FATROOT="${FATROOT:-/media/fat}"
POLL_SEC="${POLL_SEC:-1}"

# shellcheck disable=SC1090  # dynamic path (env-overridable); resolve_quest is defined in quest_lib.sh
. "$QUEST_LIB"   # provides resolve_quest

file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

launch_engine() {   # $1 = quest path; echoes the engine pid
    if [ -n "${LAUNCH_CMD:-}" ]; then
        "$LAUNCH_CMD" "$1" >/dev/null 2>&1 &
    else
        # Production: solarus_run.sh re-resolves Solarus.s0 (same pick) + exec's
        # the engine; background it so this manager keeps looping. `exec` keeps
        # the PID, so $! is the engine.
        setsid sh "$GAMEDIR/solarus_run.sh" >/dev/null 2>&1 </dev/null &
    fi
    echo $!
}

kill_engine() {     # $1 = pid
    [ -n "$1" ] || return 0
    kill -TERM "$1" 2>/dev/null
    sleep 1
    kill -9 "$1" 2>/dev/null
}

last_mtime=$(file_mtime "$S0_FILE")   # baseline: ignore the pre-existing (stale) pick
loaded=""                              # currently-loaded quest ("" = idle); kept across engine exit (for replay)
engine=""                              # engine pid ("" = none)

while :; do
    sleep "$POLL_SEC"

    # Core changed away from Solarus: tear down and exit.
    core=$(tr -d '\000\r\n ' 2>/dev/null < "$CORENAME_FILE")
    if [ "$core" != "$EXPECT_CORE" ]; then
        kill_engine "$engine"
        exit 0
    fi

    # Engine exited on its own (quest quit / crash): back to idle, do NOT auto-reload.
    if [ -n "$engine" ] && ! kill -0 "$engine" 2>/dev/null; then
        engine=""
    fi

    # A new OSD pick = a fresh write to Solarus.s0 (mtime advanced).
    cur_mtime=$(file_mtime "$S0_FILE")
    [ "$cur_mtime" = "$last_mtime" ] && continue
    last_mtime="$cur_mtime"

    sel=$(resolve_quest "$S0_FILE" "$FATROOT")
    [ -n "$sel" ] || continue          # invalid/empty pick -> stay idle / on current quest

    # (Re)launch only if it's a different quest or nothing is running.
    if [ "$sel" = "$loaded" ] && [ -n "$engine" ] && kill -0 "$engine" 2>/dev/null; then
        continue                       # re-picked the already-running quest -> no-op
    fi
    kill_engine "$engine"
    engine=$(launch_engine "$sel")
    loaded="$sel"
done
