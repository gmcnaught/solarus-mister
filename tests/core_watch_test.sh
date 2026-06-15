#!/bin/sh
# Host test for games/Solarus/core_watch.sh — the core-change exit watcher
# (productionization #3). Runs off-device: the watcher targets a PID and reads
# an overridable CORENAME file, so we drive it with a dummy process + temp file.
set -u
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
WATCH="$HERE/../games/Solarus/core_watch.sh"
TMP=$(mktemp -d)
CN="$TMP/corename"
fails=0
ok()   { echo "  PASS $1"; }
bad()  { echo "  FAIL $1"; fails=$((fails+1)); }
alive(){ kill -0 "$1" 2>/dev/null; }

# fast poll (0.2s) + miss-threshold 2 => ~0.4s to react; off-device only.
# Spawn directly in this shell (NOT via $() — a backgrounded job in command
# substitution dies when the subshell exits).
WENV="CORENAME_FILE=$CN EXPECT_CORE=Solarus POLL_SEC=0.2 MISS_THRESHOLD=2 PIDFILE=$TMP/watch.pid"

echo "== core_watch (productionization #3: core-change exit) =="

# T1: engine survives while CORENAME == Solarus
printf 'Solarus\n' > "$CN"
sleep 30 & d=$!
env $WENV TARGET_PID="$d" sh "$WATCH" >/dev/null 2>&1 & w=$!
sleep 1
alive "$d" && ok "T1 survives while core matches" || bad "T1 killed while core matched"

# T2: engine killed + watcher exits when core changes away
printf 'OtherCore\n' > "$CN"
sleep 1.5
alive "$d" && { bad "T2 engine not killed on core change"; kill -9 "$d" 2>/dev/null; } || ok "T2 engine killed on core change"
alive "$w" && { bad "T2b watcher still running"; kill -9 "$w" 2>/dev/null; } || ok "T2b watcher exited after kill"

# T3: debounce — a transient non-match (< MISS_THRESHOLD polls) must NOT kill
printf 'Solarus\n' > "$CN"; sleep 30 & d=$!
env $WENV TARGET_PID="$d" sh "$WATCH" >/dev/null 2>&1 & w=$!
sleep 0.5
printf 'OtherCore\n' > "$CN"; sleep 0.1; printf 'Solarus\n' > "$CN"
sleep 1
alive "$d" && ok "T3 debounce ignores brief transient" || bad "T3 killed on transient"
kill -9 "$d" "$w" 2>/dev/null

# T4: watcher self-exits when the engine is already gone (no orphan)
printf 'Solarus\n' > "$CN"; sleep 30 & d=$!
env $WENV TARGET_PID="$d" sh "$WATCH" >/dev/null 2>&1 & w=$!
sleep 0.4
kill -9 "$d"; sleep 1
alive "$w" && { bad "T4 watcher lingered after engine gone"; kill -9 "$w" 2>/dev/null; } || ok "T4 watcher self-exits when engine gone"

rm -rf "$TMP"
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "FAILURES: $fails"; exit 1; fi
