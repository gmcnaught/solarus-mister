#!/bin/sh
# wc_launch.sh — device-side single-engine launch for the write-combining A/B.
#
# Derived from scripts/perf/stage5_device_launch.sh (the validated recipe: kill the
# auto-launch machinery first so we never get the two-engine wedge, empty the .s0 so
# nothing auto-grabs a quest, hold the lua-console FIFO open so the console thread
# blocks instead of busy-polling).
#
# Differences: takes the RBF and the extra env from the caller, so the SAME script
# runs both A/B legs and the only thing that varies between them is SOLARUS_NO_WC.
#
#   sh wc_launch.sh <rbf-name> [extra env, e.g. SOLARUS_NO_WC=1]
GAMEDIR=/media/fat/games/Solarus
LOGDIR=/media/fat/logs/Solarus
FIFO=/tmp/sol_in
RBF="${1:?usage: wc_launch.sh <rbf-name> [extra-env]}"
shift
EXTRA="$*"
mkdir -p "$LOGDIR"

for p in quest_manager.sh core_watch.sh solarus_daemon.sh; do
  # shellcheck disable=SC2046  # pidof may return multiple PIDs; word-split is intended
  kill -9 $(pidof -x "$p" 2>/dev/null) 2>/dev/null
  for pid in $(ps | grep "$p" | grep -v grep | awk '{print $1}'); do kill -9 $pid 2>/dev/null; done
done
# shellcheck disable=SC2046  # pidof may return multiple PIDs; word-split is intended
kill -9 $(pidof solarus-run) 2>/dev/null
: > /media/fat/config/Solarus.s0
sleep 1

echo "load_core /media/fat/_Other/$RBF" > /dev/MiSTer_cmd
sleep 5
# shellcheck disable=SC2046  # pidof may return multiple PIDs; word-split is intended
kill -9 $(pidof solarus-run) 2>/dev/null
for pid in $(ps | grep -E 'quest_manager|core_watch|solarus_daemon' | grep -v grep | awk '{print $1}'); do kill -9 $pid 2>/dev/null; done
sleep 1

rm -rf /tmp/solarus_quest; mkdir -p /tmp/solarus_quest
ln -sf "$GAMEDIR/quests/mystery_of_solarus_dx.sol" /tmp/solarus_quest/data.solarus

rm -f "$FIFO"; mkfifo "$FIFO"
# stdout/stderr MUST be redirected: an ssh command channel stays open until every
# process holding the inherited fds exits, so a background holder with live fds
# hangs the caller's ssh forever (looks exactly like a slow launch).
setsid sh -c 'tail -f /dev/null > '"$FIFO"' 2>/dev/null' </dev/null >/dev/null 2>&1 &

: > "$LOGDIR/wc-boot.log"
cd "$GAMEDIR" || exit 1
env SDL_VIDEODRIVER=dummy LD_LIBRARY_PATH="$GAMEDIR/libs:$GAMEDIR" HOME=/media/fat/saves/Solarus \
    SOLARUS_BLITTER=1 SOLARUS_BLITTER_SINGLEBUF=1 SOLARUS_BLITTER_DIAG=1 \
    $EXTRA \
    setsid ./solarus-run -force-software-rendering -lua-console=yes /tmp/solarus_quest \
    < "$FIFO" > "$LOGDIR/wc-boot.log" 2>&1 &
sleep 12
echo "=== engine: $(pidof solarus-run || echo DEAD) ==="
grep -m1 "ddr mapping" "$LOGDIR/wc-boot.log" || echo "NO MAPPING LINE"
