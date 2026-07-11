#!/bin/sh
# Solarus core-change exit watcher (productionization #3).
#
# Launched DETACHED by solarus_run.sh right before it exec's the engine. Polls
# the loaded-core name (/tmp/CORENAME); when it leaves "Solarus" (a different
# MiSTer core was loaded), it terminates the engine and exits. This is "our own
# handler" — no dependency on Frontier/Master_Daemon.
#
# The engine is targeted by PID: solarus_run.sh passes TARGET_PID=$$, and since
# `exec` preserves the PID, that becomes solarus-run's PID. So we use kill, not
# pidof (exact target, and testable off-device).
#
# Env (production defaults):
#   CORENAME_FILE=/tmp/CORENAME  EXPECT_CORE=Solarus  TARGET_PID=<engine pid>
#   POLL_SEC=1  MISS_THRESHOLD=2  PIDFILE=/tmp/solarus_corewatch.pid
set -u
CORENAME_FILE="${CORENAME_FILE:-/tmp/CORENAME}"
EXPECT_CORE="${EXPECT_CORE:-Solarus}"
TARGET_PID="${TARGET_PID:-}"
POLL_SEC="${POLL_SEC:-1}"
MISS_THRESHOLD="${MISS_THRESHOLD:-2}"
PIDFILE="${PIDFILE:-/tmp/solarus_corewatch.pid}"

[ -n "$TARGET_PID" ] || exit 0          # nothing to watch

# Single-instance: kill any prior watcher, then record ours.
if [ -f "$PIDFILE" ]; then
    old=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$old" ] && [ "$old" != "$$" ] && kill -9 "$old" 2>/dev/null
fi
echo $$ > "$PIDFILE"

# Release our pidfile record — but ONLY if it still holds OUR pid. On a quest
# switch the successor watcher (B) may have already overwritten the shared
# PIDFILE with its own $$ before this exiting watcher (A) reaches its rm; an
# UNCONDITIONAL rm would then delete B's record, so the single-instance guard
# above (:27-31) can no longer find/kill B and watchers accumulate across
# repeated switches. Compare-then-delete closes that (narrow) race.
release_pidfile() {
    [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$PIDFILE" 2>/dev/null
    return 0
}

miss=0
while :; do
    sleep "$POLL_SEC"

    # Engine gone on its own (quest quit / crash / external kill): done, no orphan.
    kill -0 "$TARGET_PID" 2>/dev/null || { release_pidfile; exit 0; }

    core=$(cat "$CORENAME_FILE" 2>/dev/null | tr -d '\000\r\n ')
    if [ "$core" = "$EXPECT_CORE" ]; then
        miss=0
        continue
    fi

    # Debounce: require MISS_THRESHOLD consecutive non-matches so a transient
    # empty/half-written CORENAME during a core load doesn't trigger a false kill.
    miss=$((miss + 1))
    [ "$miss" -ge "$MISS_THRESHOLD" ] || continue

    # Core changed away from Solarus: terminate the engine (graceful, then force).
    kill -TERM "$TARGET_PID" 2>/dev/null
    sleep 1
    kill -9 "$TARGET_PID" 2>/dev/null
    release_pidfile
    exit 0
done
