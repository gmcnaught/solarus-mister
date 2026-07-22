#!/bin/sh
# Stage 5 device launch: clean slate -> load Solarus core -> ONE engine on a held FIFO.
GAMEDIR=/media/fat/games/Solarus
LOGDIR=/media/fat/logs/Solarus
FIFO=/tmp/sol_in
mkdir -p "$LOGDIR"

# 1) kill auto-launch machinery + any engine (avoid two-engine wedge)
for p in quest_manager.sh core_watch.sh solarus_daemon.sh; do
  # shellcheck disable=SC2046  # pidof may return multiple PIDs; word-split is intended
  kill -9 $(pidof -x "$p" 2>/dev/null) 2>/dev/null
  for pid in $(ps | grep "$p" | grep -v grep | awk '{print $1}'); do kill -9 $pid 2>/dev/null; done
done
# shellcheck disable=SC2046  # pidof may return multiple PIDs; word-split is intended
kill -9 $(pidof solarus-run) 2>/dev/null
: > /media/fat/config/Solarus.s0    # empty so nothing auto-grabs a quest
sleep 1

# 2) load the Solarus core onto the FPGA (needed for the fabric compositor)
echo "load_core /media/fat/_Other/Solarus_20260721.rbf" > /dev/MiSTer_cmd
sleep 5
# the daemon may have relaunched an engine on core-load; kill it, we run our own
# shellcheck disable=SC2046  # pidof may return multiple PIDs; word-split is intended
kill -9 $(pidof solarus-run) 2>/dev/null
for pid in $(ps | grep -E 'quest_manager|core_watch|solarus_daemon' | grep -v grep | awk '{print $1}'); do kill -9 $pid 2>/dev/null; done
sleep 1

# 3) quest dir indirection (solarus-run needs a DIRECTORY)
rm -rf /tmp/solarus_quest; mkdir -p /tmp/solarus_quest
ln -sf "$GAMEDIR/quests/mystery_of_solarus_dx.sol" /tmp/solarus_quest/data.solarus

# 4) held-open FIFO for lua-console stdin
rm -f "$FIFO"; mkfifo "$FIFO"
setsid sh -c 'tail -f /dev/null > '"$FIFO"' 2>/dev/null' </dev/null &

# 5) launch ONE engine, shipping blitter flags + DIAG, lua-console on the FIFO
: > "$LOGDIR/stage5-boot.log"
cd "$GAMEDIR" || exit 1
env SDL_VIDEODRIVER=dummy LD_LIBRARY_PATH="$GAMEDIR/libs:$GAMEDIR" HOME=/media/fat/saves/Solarus \
    SOLARUS_BLITTER=1 SOLARUS_BLITTER_SINGLEBUF=1 SOLARUS_BLITTER_DIAG=1 \
    ${SOLARUS_DRAW_PROF:+SOLARUS_DRAW_PROF=$SOLARUS_DRAW_PROF} \
    setsid ./solarus-run -force-software-rendering -lua-console=yes /tmp/solarus_quest \
    < "$FIFO" > "$LOGDIR/stage5-boot.log" 2>&1 &
echo "launched engine pid(s): $(pidof solarus-run)"
sleep 12
echo "=== after 12s: engine alive? ==="; pidof solarus-run || echo "(DEAD)"
echo "=== boot log tail ==="; tail -20 "$LOGDIR/stage5-boot.log"
