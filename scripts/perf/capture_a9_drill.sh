#!/usr/bin/env bash
# Stage 5 (A9 track) Phase 1 — full A9 banner drill on ONE map, STANDING + MOVING.
# Rebuild-free: the shipped engine emits every banner under SOLARUS_BLITTER_DIAG=1.
# Usage: MAP=119 DEST=from_dungeon_10 TAG=map119 scripts/perf/capture_a9_drill.sh
#        MAP=3   DEST=<pick>          TAG=map3   scripts/perf/capture_a9_drill.sh
set -euo pipefail
HOST="${HOST:-root@192.168.20.81}"
RBF="${RBF:-Solarus_20260722.rbf}"          # current ship (enlarged P_SRC cache)
MAP="${MAP:?set MAP=3|119}"; DEST="${DEST:?set DEST=<teleport destination>}"
TAG="${TAG:?set TAG=map3|map119}"
LOG=/media/fat/logs/Solarus/stage5-a9.log
FIFO=/tmp/sol_in
OUTDIR="docs/superpowers/data/stage5-a9"; mkdir -p "$OUTDIR"
OUT="$OUTDIR/drill-${TAG}.txt"
# The COMPLETE A9 drill stack (superset of stage5_ab_cache.sh).
BANNERS="timing hwperf p0 resident cvt a9split emitsplit luasplit engcpp drawcat enttype entphase entsplit movedrill"

# One engine on the fabric (RBF swapped into the shared launch script).
sed -e "s#Solarus_20260721.rbf#${RBF}#g" -e 's#stage5-boot.log#stage5-a9.log#g' \
    "$(dirname "$0")/stage5_device_launch.sh" > /tmp/_a9_launch.sh
scp -q /tmp/_a9_launch.sh "$HOST:/tmp/a9_launch.sh"
ssh "$HOST" "sh /tmp/a9_launch.sh" >/dev/null 2>&1 &
sleep 20   # boot + fabric settle

# start save + teleport to target
ssh "$HOST" "printf 'sol.main.game = sol.game.load(\"save1.dat\"); sol.menu.stop_all(sol.main); sol.main:start_savegame(sol.main.game)\n' > $FIFO"
sleep 7
ssh "$HOST" "printf 'sol.main.game:get_hero():teleport(\"$MAP\",\"$DEST\")\n' > $FIFO"
sleep 8

# confirm map
CUR=""
for _ in 1 2 3 4 5; do
  ssh "$HOST" "printf 'print(\"CURMAP_NOW=\"..sol.main.game:get_map():get_id())\n' > $FIFO" 2>/dev/null || true
  sleep 2
  CUR=$(ssh "$HOST" "grep -ao 'CURMAP_NOW=[0-9]*' $LOG | tail -1" 2>/dev/null || true)
  [ -n "$CUR" ] && break
done

grab() {  # $1 = state label; tail 5 windows/banner so >=3 clean are available
  echo "### A9 DRILL  TAG=$TAG  RBF=$RBF  map=$MAP  state=$1  ($CUR)"
  for b in $BANNERS; do
    echo "--- [blitter $b] (last 5) ---"
    ssh "$HOST" "grep -E \"\\[blitter $b\\]\" $LOG | tail -5" 2>/dev/null || true
  done
}

# STANDING: idle ~14s so counters stabilise (>=3 60-frame windows land).
sleep 14
{ grab standing; } | tee "$OUT"

# MOVING: hold DOWN (0x04 on 0x3A000008) for ~14s, then release.
ssh "$HOST" "for i in \$(seq 1 700); do busybox devmem 0x3A000008 32 0x04; sleep 0.02; done" &
sleep 14
ssh "$HOST" "busybox devmem 0x3A000008 32 0x00" || true
{ grab moving; } | tee -a "$OUT"

echo "--- engine alive? ---" | tee -a "$OUT"
ssh "$HOST" "pidof solarus-run >/dev/null && echo ALIVE || echo DEAD" | tee -a "$OUT"
echo "captured -> $OUT"
