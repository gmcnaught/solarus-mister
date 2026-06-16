#!/bin/sh
# solarus_daemon.sh — Solarus-only, Frontier-independent core-load watcher.
#
# Provides ARM-side auto-launch for the Solarus core WITHOUT depending on
# MiSTer Frontier's Master_Daemon. It watches /tmp/CORENAME and, when the
# Solarus core loads, spawns games/Solarus/_handler.sh (-> quest_manager.sh).
# It owns that child: kills it on core change, respawns it if it dies while
# still on the Solarus core.
#
# Coexistence: if Frontier's Master_Daemon IS running, this daemon stays
# passive (Frontier owns the lifecycle) and relinquishes any child it spawned,
# so there is never a double launch. Re-checked every tick, so it self-heals if
# Frontier starts or stops. A second guard skips spawning whenever a
# quest_manager is already running (covers a startup race and fast re-entry).
#
# Boot persistence: on first run it self-registers into user-startup.sh (mirrors
# Frontier), so it starts on every boot. First start comes from scripts/Solarus.sh
# and deploy.py.
#
# We deliberately do NOT clear <core>.s0 like Frontier — quest_manager already
# ignores a stale .s0 via its mtime baseline — and we manage only Solarus.
#
# Env (production defaults; overridable for host tests):
#   GAMEDIR=/media/fat/games/Solarus  EXPECT_CORE=Solarus
#   CORENAME_FILE=/tmp/CORENAME  HANDLER=$GAMEDIR/_handler.sh
#   STARTUP_FILE=/media/fat/linux/user-startup.sh  SELF=$GAMEDIR/solarus_daemon.sh
#   POLL_SEC=1
#   FRONTIER_CHECK / MANAGER_CHECK — shell expressions (eval'd) that return 0
#     when Frontier's Master_Daemon / a quest_manager is running. Defaults are
#     busybox-safe (its pidof has no -x): ps + a [x]-style grep that won't self-match.
#   SPAWN_CMD — if set, spawned via `sh -c` instead of running $HANDLER (tests).
set -u
GAMEDIR="${GAMEDIR:-/media/fat/games/Solarus}"
EXPECT_CORE="${EXPECT_CORE:-Solarus}"
CORENAME_FILE="${CORENAME_FILE:-/tmp/CORENAME}"
HANDLER="${HANDLER:-$GAMEDIR/_handler.sh}"
STARTUP_FILE="${STARTUP_FILE:-/media/fat/linux/user-startup.sh}"
SELF="${SELF:-$GAMEDIR/solarus_daemon.sh}"
POLL_SEC="${POLL_SEC:-1}"
FRONTIER_CHECK="${FRONTIER_CHECK:-ps -o pid,args 2>/dev/null | grep -q '[M]aster_Daemon.sh'}"
MANAGER_CHECK="${MANAGER_CHECK:-ps -o pid,args 2>/dev/null | grep -q '[q]uest_manager.sh'}"

frontier_running() { eval "$FRONTIER_CHECK" >/dev/null 2>&1; }
manager_running()  { eval "$MANAGER_CHECK"  >/dev/null 2>&1; }

register_boot() {   # idempotently add ourselves to user-startup.sh (boot persistence)
    [ -n "$STARTUP_FILE" ] || return 0
    if [ ! -f "$STARTUP_FILE" ]; then
        printf '#!/bin/sh\n' > "$STARTUP_FILE" 2>/dev/null || return 0
    fi
    if ! grep -qF "$SELF" "$STARTUP_FILE" 2>/dev/null; then
        {
            printf '\n# Solarus — self-owned core-load daemon (Frontier-independent)\n'
            printf 'bash %s &\n' "$SELF"
        } >> "$STARTUP_FILE" 2>/dev/null
    fi
}

spawn_child() {     # spawn the handler (or the injected test command); track its PID
    if [ -n "${SPAWN_CMD:-}" ]; then
        sh -c "$SPAWN_CMD" >/dev/null 2>&1 &
    else
        "$HANDLER" >/dev/null 2>&1 &
    fi
    CHILD=$!
}

kill_child() {      # TERM -> grace -> KILL the child we own (engine handled by core_watch)
    [ -n "${CHILD:-}" ] || return 0
    kill -TERM "$CHILD" 2>/dev/null
    sleep 1
    kill -9 "$CHILD" 2>/dev/null
    CHILD=""
}

register_boot

CHILD=""
while :; do
    sleep "$POLL_SEC"

    # Defer to Frontier: it owns the lifecycle. Relinquish any child we spawned
    # so exactly one manager runs, then stay passive this tick.
    if frontier_running; then
        [ -n "$CHILD" ] && kill_child
        continue
    fi

    core=$(cat "$CORENAME_FILE" 2>/dev/null | tr -d '\000\r\n ')

    # Reap a child that exited on its own (crash / unexpected manager exit).
    if [ -n "$CHILD" ] && ! kill -0 "$CHILD" 2>/dev/null; then
        CHILD=""
    fi

    if [ "$core" = "$EXPECT_CORE" ]; then
        # On our core: ensure a manager runs. Guard against a double-spawn (a
        # Frontier-race manager, or one lingering from fast re-entry).
        if [ -z "$CHILD" ] && ! manager_running; then
            spawn_child
        fi
    else
        # Left our core: tear down our child (safety net — quest_manager
        # self-exits and core_watch kills the engine independently).
        [ -n "$CHILD" ] && kill_child
    fi
done
