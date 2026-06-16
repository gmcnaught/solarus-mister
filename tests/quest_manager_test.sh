#!/bin/sh
# Host test for games/Solarus/quest_manager.sh (productionization #2).
# The manager waits for an OSD pick (a NEW write to Solarus.s0), launches the
# engine on it, switches on a different pick, returns to idle if the engine
# exits, and exits on a core change. Tested off-device via env overrides + an
# injectable launch command that logs the quest and spawns a dummy "engine".
set -u
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
MGR="$HERE/../games/Solarus/quest_manager.sh"
TMP=$(mktemp -d)
FAT="$TMP/fat"; QDIR="$FAT/games/Solarus/quests"; mkdir -p "$QDIR"
: > "$QDIR/a.sol"; : > "$QDIR/b.sol"
CN="$TMP/corename"; printf 'Solarus\n' > "$CN"
S0="$TMP/s0"
LOG="$TMP/launch.log"; : > "$LOG"
fails=0
ok()  { echo "  PASS $1"; }
bad() { echo "  FAIL $1"; fails=$((fails+1)); }
alive(){ kill -0 "$1" 2>/dev/null; }
launches(){ wc -l < "$LOG" | tr -d ' '; }
last_launch(){ tail -1 "$LOG" 2>/dev/null; }

# Injected "engine launcher": logs the quest, then becomes a long sleep (the dummy engine).
cat > "$TMP/fake_launch.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >> "$LOG"
exec sleep 30
EOF
chmod +x "$TMP/fake_launch.sh"

pick(){ sleep 1.1; printf '%s\n' "$1" > "$S0"; }   # >1s so mtime second-granularity advances

echo "== quest_manager (productionization #2: OSD quest select) =="

# Stale .s0 present at startup -> must NOT auto-load (no game until selected).
printf 'games/Solarus/quests/a.sol\n' > "$S0"
CORENAME_FILE="$CN" EXPECT_CORE=Solarus S0_FILE="$S0" FATROOT="$FAT" \
  POLL_SEC=0.2 LAUNCH_CMD="$TMP/fake_launch.sh" QUEST_LIB="$HERE/../games/Solarus/quest_lib.sh" \
  sh "$MGR" >/dev/null 2>&1 & M=$!
sleep 1
[ "$(launches)" = "0" ] && ok "T1 no auto-load of stale .s0 (idle)" || bad "T1 auto-loaded stale .s0"

# Fresh pick A -> launches A
pick games/Solarus/quests/a.sol; sleep 0.6
[ "$(launches)" = "1" ] && [ "$(last_launch)" = "$QDIR/a.sol" ] && ok "T2 launches on fresh pick A" || bad "T2 pick A not launched"

# Pick B -> switch (relaunch with B). Switch latency ~1s (graceful kill of the
# old engine before launching the new), so wait past it.
pick games/Solarus/quests/b.sol; sleep 1.6
[ "$(launches)" = "2" ] && [ "$(last_launch)" = "$QDIR/b.sol" ] && ok "T3 switch to B on new pick" || bad "T3 switch to B"

# No pick -> no further launches
sleep 1
[ "$(launches)" = "2" ] && ok "T4 idle: no relaunch without a pick" || bad "T4 spurious relaunch"

# Engine exits on its own -> return to idle, NO auto-reload
kill -9 $(pgrep -P "$M" 2>/dev/null) 2>/dev/null   # kill the dummy engine (manager's child)
pkill -f "sleep 30" 2>/dev/null
sleep 1
[ "$(launches)" = "2" ] && ok "T5 engine exit -> idle (no auto-reload)" || bad "T5 auto-reloaded after exit"

# Core change -> manager exits
printf 'OtherCore\n' > "$CN"; sleep 1.5
alive "$M" && { bad "T6 manager did not exit on core change"; kill -9 "$M" 2>/dev/null; } || ok "T6 manager exits on core change"

pkill -f "sleep 30" 2>/dev/null; kill -9 "$M" 2>/dev/null; rm -rf "$TMP"
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "FAILURES: $fails"; exit 1; fi
