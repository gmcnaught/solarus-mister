#!/bin/sh
# Host test for games/Solarus/solarus_daemon.sh — the Frontier-independent,
# Solarus-only core-load watcher. It spawns _handler.sh when the Solarus core
# loads (unless Frontier's Master_Daemon is running), owns that child, and
# self-registers into user-startup.sh. Tested off-device via injected process
# checks (FRONTIER_CHECK / MANAGER_CHECK) + an injectable spawn command.
set -u
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
DAEMON="$HERE/../games/Solarus/solarus_daemon.sh"
TMP=$(mktemp -d)
CN="$TMP/corename"
STARTUP="$TMP/user-startup.sh"
LOG="$TMP/spawn.log"; : > "$LOG"
FUP="$TMP/frontier_up"     # exists => Frontier "running"
MUP="$TMP/manager_up"      # exists => a quest_manager "already running"
SELFP="$TMP/solarus_daemon.sh"
fails=0
ok(){  echo "  PASS $1"; }
bad(){ echo "  FAIL $1"; fails=$((fails+1)); }
spawns(){ wc -l < "$LOG" | tr -d ' '; }
alive(){ kill -0 "$1" 2>/dev/null; }

# Injected fake handler/manager child: records a spawn, then becomes a sleep.
cat > "$TMP/fake_handler.sh" <<EOF
#!/bin/sh
printf 'spawn\n' >> "$LOG"
exec sleep 30
EOF
chmod +x "$TMP/fake_handler.sh"

start(){   # launch a daemon with injected env; echo its pid
  CORENAME_FILE="$CN" EXPECT_CORE=Solarus POLL_SEC=0.2 \
  STARTUP_FILE="$STARTUP" SELF="$SELFP" \
  FRONTIER_CHECK="test -f $FUP" MANAGER_CHECK="test -f $MUP" \
  SPAWN_CMD="$TMP/fake_handler.sh" \
  sh "$DAEMON" >/dev/null 2>&1 &
  echo $!
}
# Hermetic teardown: kill the launched daemon AND any lingering daemon instance
# (so a slow spawn can't leak into the next test's shared LOG), plus its child.
cleanup(){ kill -9 "${D:-0}" 2>/dev/null; pkill -f solarus_daemon.sh 2>/dev/null; pkill -f "sleep 30" 2>/dev/null; sleep 0.4; }

echo "== solarus_daemon (Frontier-independent core-load watcher) =="

# T1 defer: Frontier "running" + Solarus -> never spawn
: > "$LOG"; touch "$FUP"; printf 'Solarus\n' > "$CN"; rm -f "$MUP"
D=$(start); sleep 1.2
[ "$(spawns)" = "0" ] && ok "T1 defers while Frontier running" || bad "T1 spawned despite Frontier"
cleanup

# T2 self-register: boot line appended once, idempotent across runs (defer so no children)
rm -f "$STARTUP"; touch "$FUP"; printf 'Solarus\n' > "$CN"
D=$(start); sleep 0.6; cleanup
n1=$(grep -cF "$SELFP" "$STARTUP" 2>/dev/null || echo 0)
D=$(start); sleep 0.6; cleanup
n2=$(grep -cF "$SELFP" "$STARTUP" 2>/dev/null || echo 0)
{ [ "$n1" = "1" ] && [ "$n2" = "1" ]; } && ok "T2 self-registers into user-startup.sh once" || bad "T2 register n1=$n1 n2=$n2"

# T3 spawn: Frontier absent + Solarus + no manager -> spawn once
: > "$LOG"; rm -f "$FUP" "$MUP"; printf 'Solarus\n' > "$CN"
D=$(start); sleep 1.2
[ "$(spawns)" = "1" ] && ok "T3 spawns handler when Frontier absent" || bad "T3 spawn count=$(spawns)"
cleanup

# T4 no double-spawn: a manager already running -> no spawn
: > "$LOG"; rm -f "$FUP"; touch "$MUP"; printf 'Solarus\n' > "$CN"
D=$(start); sleep 1.2
[ "$(spawns)" = "0" ] && ok "T4 no spawn when a manager already runs" || bad "T4 double-spawned=$(spawns)"
cleanup

# T5 respawn on child death
: > "$LOG"; rm -f "$FUP" "$MUP"; printf 'Solarus\n' > "$CN"
D=$(start); sleep 1.0
[ "$(spawns)" = "1" ] || bad "T5 setup: initial spawn=$(spawns)"
pkill -f "sleep 30" 2>/dev/null   # kill the spawned child
sleep 1.0
[ "$(spawns)" = "2" ] && ok "T5 respawns after child death" || bad "T5 respawn=$(spawns)"
cleanup

# T6 teardown on core-away: child killed when CORENAME leaves Solarus
: > "$LOG"; rm -f "$FUP" "$MUP"; printf 'Solarus\n' > "$CN"
D=$(start); sleep 1.0
child=$(pgrep -f "sleep 30" | head -1)
[ -n "$child" ] || bad "T6 setup: no child spawned"
printf 'MENU\n' > "$CN"; sleep 1.8
{ [ -n "$child" ] && ! alive "$child"; } && ok "T6 tears down child on core-away" || bad "T6 child survived core-away"
cleanup

# T7 relinquish: spawned, then Frontier appears -> our child killed (defer to Frontier)
: > "$LOG"; rm -f "$FUP" "$MUP"; printf 'Solarus\n' > "$CN"
D=$(start); sleep 1.0
child=$(pgrep -f "sleep 30" | head -1)
touch "$FUP"; sleep 1.8   # Frontier appears
{ [ -n "$child" ] && ! alive "$child"; } && ok "T7 relinquishes child when Frontier starts" || bad "T7 child survived defer"
cleanup

rm -rf "$TMP"
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "FAILURES: $fails"; exit 1; fi
