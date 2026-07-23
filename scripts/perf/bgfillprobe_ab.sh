#!/usr/bin/env bash
# Phase 0 attribution A/B: SAME ship RBF (Solarus_20260723.rbf) both legs, the only
# variable is SOLARUS_BGFILLPROBE. Load the core, launch ONE engine on a held FIFO,
# teleport to the map-119 parallax spot, settle, and sample the standing counters:
#   [blitter hwperf] fabric_hw/comp   [blitter timing] fps   [blitter p0] BLEND count.
# Diff fabric_hw and non-comp (= fabric_hw - comp) between the off and on legs.
#
# Usage: TAG=off              scripts/perf/bgfillprobe_ab.sh
#        TAG=on PROBE=1        scripts/perf/bgfillprobe_ab.sh
set -euo pipefail
HOST="${HOST:-root@192.168.20.81}"
TAG="${TAG:?set TAG=off|on}"; PROBE="${PROBE:-}"
MAP="${MAP:-119}"; DEST="${DEST:-from_dungeon_10}"
LOG=/media/fat/logs/Solarus/bgfillprobe-ab.log
FIFO=/tmp/sol_in
OUTDIR="docs/superpowers/data/stage5"; mkdir -p "$OUTDIR"
OUT="$OUTDIR/ab-bgfill-${TAG}-map${MAP}.txt"

# Adapt the shared launch template: pin the current ship RBF (20260723) both legs,
# repoint the log, and for the ON leg inject SOLARUS_BGFILLPROBE=1 into the engine's
# env var list (the line that already sets SOLARUS_BLITTER_DIAG=1).
LAUNCH=/tmp/_bgfill_launch.sh
SED=(-e 's#Solarus_20260721.rbf#Solarus_20260723.rbf#g'
     -e 's#stage5-boot.log#bgfillprobe-ab.log#g')
if [ -n "$PROBE" ]; then
  SED+=(-e 's#SOLARUS_BLITTER_DIAG=1 \\#SOLARUS_BLITTER_DIAG=1 SOLARUS_BGFILLPROBE=1 \\#')
fi
sed "${SED[@]}" "$(dirname "$0")/stage5_device_launch.sh" > "$LAUNCH"
scp -q "$LAUNCH" "$HOST:/tmp/bgfill_launch.sh"
ssh "$HOST" "sh /tmp/bgfill_launch.sh" >/dev/null 2>&1 &
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

# STANDING window: idle ~12s so counters stabilise, then grab the last banner samples.
sleep 12
{
  echo "### bgfill A/B TAG=$TAG PROBE=${PROBE:-0} RBF=Solarus_20260723.rbf map=$MAP ($CUR)"
  for b in timing hwperf p0 resident bgfillprobe; do
    echo "--- [blitter $b] (last 3) ---"
    ssh "$HOST" "grep -E \"\\[blitter $b\\]\" $LOG | tail -3" 2>/dev/null || true
  done
  echo "--- probe active? (count of ENABLED banner) ---"
  ssh "$HOST" "grep -c 'BGFILL PROBE ENABLED' $LOG" 2>/dev/null || true
  echo "--- engine alive? ---"
  ssh "$HOST" "pidof solarus-run >/dev/null && echo ALIVE || echo DEAD"
} | tee "$OUT"
echo "captured -> $OUT"
