#!/usr/bin/env bash
# Stage 5 Task C — two-RBF cache A/B. For ONE rbf, load the core, launch ONE engine
# (FETCHTRACE OFF — normal shipping behaviour), teleport to a target map, let it settle,
# and sample the standing perf banners ([blitter hwperf]=fabric_hw/comp, [blitter timing]=
# fps/period). Run once per RBF and diff the fabric_hw / comp / fps.
#
# Usage: RBF=Solarus_20260721.rbf TAG=baseline  scripts/perf/stage5_ab_cache.sh
#        RBF=Solarus_20260722.rbf TAG=enlarged  scripts/perf/stage5_ab_cache.sh
#   MAP/DEST default to the map119 parallax spot; override for map1 etc.
set -euo pipefail
HOST="${HOST:-root@192.168.20.81}"
RBF="${RBF:?set RBF=Solarus_YYYYMMDD.rbf}"; TAG="${TAG:?set TAG=baseline|enlarged}"
MAP="${MAP:-119}"; DEST="${DEST:-from_dungeon_10}"
LOG=/media/fat/logs/Solarus/stage5-ab.log
FIFO=/tmp/sol_in
OUTDIR="docs/superpowers/data/stage5"; mkdir -p "$OUTDIR"
OUT="$OUTDIR/ab-${TAG}-map${MAP}.txt"

# Launch script = stage5_device_launch.sh with the RBF swapped in (FETCHTRACE stays OFF).
sed -e "s#Solarus_20260721.rbf#${RBF}#g" -e 's#stage5-boot.log#stage5-ab.log#g' \
    "$(dirname "$0")/stage5_device_launch.sh" > /tmp/_ab_launch.sh
scp -q /tmp/_ab_launch.sh "$HOST:/tmp/ab_launch.sh"
ssh "$HOST" "sh /tmp/ab_launch.sh" >/dev/null 2>&1 &
sleep 20   # boot + fabric settle (core load + engine)

# start save + teleport to the target map
ssh "$HOST" "printf 'sol.main.game = sol.game.load(\"save1.dat\"); sol.menu.stop_all(sol.main); sol.main:start_savegame(sol.main.game)\n' > $FIFO"
sleep 7
ssh "$HOST" "printf 'sol.main.game:get_hero():teleport(\"$MAP\",\"$DEST\")\n' > $FIFO"
sleep 8

# confirm the map (retry)
CUR=""
for _ in 1 2 3 4 5; do
  ssh "$HOST" "printf 'print(\"CURMAP_NOW=\"..sol.main.game:get_map():get_id())\n' > $FIFO" 2>/dev/null || true
  sleep 2
  CUR=$(ssh "$HOST" "grep -ao 'CURMAP_NOW=[0-9]*' $LOG | tail -1" 2>/dev/null || true)
  [ -n "$CUR" ] && break
done

# STANDING window: let the scene run idle ~12s so the perf counters stabilise, then grab
# the last few banner samples for each metric.
sleep 12
{
  echo "### A/B leg TAG=$TAG  RBF=$RBF  map=$MAP  ($CUR)"
  for b in timing hwperf p0 comp resident engcpp a9split; do
    echo "--- [blitter $b] (last 3) ---"
    ssh "$HOST" "grep -E \"\\[blitter $b\\]\" $LOG | tail -3" 2>/dev/null || true
  done
  echo "--- engine alive? ---"
  ssh "$HOST" "pidof solarus-run >/dev/null && echo ALIVE || echo DEAD"
} | tee "$OUT"
echo "captured -> $OUT"
