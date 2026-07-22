#!/usr/bin/env bash
# Stage 5 Task A — capture the atlas fetch-trace for ONE map, for the offline LRU
# hit-rate model (scripts/perf/cache_hitrate.py). Launches ONE engine with
# SOLARUS_FETCHTRACE=1, loads save1, optionally teleports to a target map, and pulls
# the LAST per-scene FETCH block. The renderer emits a "FETCH_SCENE" marker + resets
# its bounded window at every resident rebuild AND gates the trace to that ONE build
# frame (res_building) — so each block is exactly one frame's fabric fetch working set
# (static tiles + that frame's sprites), the correct unit given per-vsync P_SRC
# invalidation. Fresh launch per map so a crash-prone teleport can't lose other data.
#
# Usage:
#   MAP=119 DEST=from_dungeon_10 scripts/perf/capture_fetchtrace.sh   # teleport
#   MAP=1   DEST=from_main_room  scripts/perf/capture_fetchtrace.sh
#   MAP=start DEST=            scripts/perf/capture_fetchtrace.sh      # no teleport (save start map)
#
# Prereq: the FETCHTRACE-instrumented engine is deployed on the device.
set -euo pipefail
HOST="${HOST:-root@192.168.20.81}"
LOG=/media/fat/logs/Solarus/stage5-fetchtrace.log
FIFO=/tmp/sol_in
MAP="${MAP:-119}"; DEST="${DEST:-from_dungeon_10}"
OUTDIR="docs/superpowers/data/stage5"
OUT="$OUTDIR/fetchtrace-map${MAP}.log"
RAW="$OUTDIR/fetchtrace-map${MAP}-raw.log"
mkdir -p "$OUTDIR"

# 1) clean slate -> load core -> ONE engine on a held FIFO, FETCHTRACE on.
sed -e 's#stage5-boot.log#stage5-fetchtrace.log#g' \
    -e 's#SOLARUS_BLITTER_DIAG=1#SOLARUS_BLITTER_DIAG=1 SOLARUS_FETCHTRACE=1#' \
    "$(dirname "$0")/stage5_device_launch.sh" > /tmp/_ft_launch.sh
scp -q /tmp/_ft_launch.sh "$HOST:/tmp/fetchtrace_launch.sh"
ssh "$HOST" "sh /tmp/fetchtrace_launch.sh" >/dev/null 2>&1 &
sleep 18   # boot + fabric settle

# 2) start the game (builds the save's start map), then optionally teleport.
ssh "$HOST" "printf 'sol.main.game = sol.game.load(\"save1.dat\"); sol.menu.stop_all(sol.main); sol.main:start_savegame(sol.main.game)\n' > $FIFO"
sleep 7
if [ -n "$DEST" ] && [ "$MAP" != "start" ]; then
  ssh "$HOST" "printf 'sol.main.game:get_hero():teleport(\"$MAP\",\"$DEST\")\n' > $FIFO"
  sleep 7
fi

# 3) robust CURMAP confirmation (retry — the build-frame FETCH flood can delay the log)
CUR=""
for t in 1 2 3 4 5; do
  ssh "$HOST" "printf 'print(\"CURMAP_NOW=\"..sol.main.game:get_map():get_id())\n' > $FIFO" 2>/dev/null || true
  sleep 2
  CUR=$(ssh "$HOST" "grep -ao 'CURMAP_NOW=[0-9]*' $LOG | tail -1" 2>/dev/null || true)
  [ -n "$CUR" ] && break
done
echo "confirmed map: ${CUR:-<none>}  (requested MAP=$MAP)"
ssh "$HOST" "pidof solarus-run >/dev/null && echo 'engine: ALIVE' || echo 'engine: DEAD'"

# 4) pull the full log + isolate the LAST FETCH_SCENE block into $OUT
sleep 2
scp -q "$HOST:$LOG" "$RAW"
awk 'BEGIN{start=1} /^FETCH_SCENE/{start=NR} {L[NR]=$0} END{
       for(i=start;i<=NR;i++) if(L[i] ~ /^FETCH /) print L[i]
     }' "$RAW" > "$OUT"
echo "target-map FETCH lines: $(wc -l < "$OUT")  -> $OUT"
echo "scene markers seen: $(grep -ac '^FETCH_SCENE' "$RAW")"
echo "distinct src_off in block: $(awk '{print $2}' "$OUT" | sort -u | wc -l | tr -d ' ')"
