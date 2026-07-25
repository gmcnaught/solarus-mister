#!/usr/bin/env bash
# Pacing A/B: dialog-up on map 40 (dungeon_3 auto-fires + holds a dialog headless).
# Leg B = default (no ensure_frame vblank barrier; present() 60fps cap paces).
# Leg A = SOLARUS_VSYNC_BARRIER=1 (the retired pre-Phase-2 barrier).
# Rebuild-free; reads the shipped diag banners. One engine per leg (kill+relaunch).
set -uo pipefail
HOST="${HOST:-root@192.168.20.81}"
RBF="${RBF:-Solarus_20260724.rbf}"
MAP="${MAP:-40}"; DEST="${DEST:-from_outside}"
LOG=/media/fat/logs/Solarus/stage5-boot.log
FIFO=/tmp/sol_in
OUTDIR="docs/superpowers/data/pacing-ab"; mkdir -p "$OUTDIR"

sed "s#Solarus_20260721.rbf#${RBF}#g" scripts/perf/stage5_device_launch.sh > /tmp/_pc_launch.sh
scp -q /tmp/_pc_launch.sh "$HOST:/tmp/pc_launch.sh"

run_leg() {
  VB="$1"; TAG="$2"; OUT="$OUTDIR/leg-${TAG}.txt"
  echo "===== LEG $TAG  (SOLARUS_VSYNC_BARRIER=$VB)  RBF=$RBF  map=$MAP/$DEST ====="
  ssh "$HOST" "SOLARUS_VSYNC_BARRIER=$VB SOLARUS_DRAW_PROF=1 SOLARUS_BLITTER_DIAG=1 sh /tmp/pc_launch.sh" >/dev/null 2>&1 &
  sleep 22   # boot + fabric settle
  ssh "$HOST" "printf 'sol.main.game = sol.game.load(\"save1.dat\"); sol.menu.stop_all(sol.main); sol.main:start_savegame(sol.main.game)\n' > $FIFO" 2>/dev/null || true
  sleep 8
  ssh "$HOST" "printf 'sol.main.game:get_hero():teleport(\"$MAP\",\"$DEST\")\n' > $FIFO" 2>/dev/null || true
  sleep 12
  ssh "$HOST" "printf 'print(\"CURMAP=\"..sol.main.game:get_map():get_id()..\" DLG=\"..tostring(sol.main.game:is_dialog_enabled()))\n' > $FIFO" 2>/dev/null || true
  sleep 12   # let >=3 diag windows land with the dialog up
  {
    echo "### LEG $TAG  VSYNC_BARRIER=$VB  RBF=$RBF  map=$MAP/$DEST"
    echo "--- map/dialog probe ---"
    ssh "$HOST" "grep -aoE 'CURMAP=[0-9]+ DLG=(true|false)' $LOG | tail -2" 2>/dev/null || true
    for b in "MiSTer draw" timing a9split hwperf; do
      echo "--- [$b] (last 4) ---"
      ssh "$HOST" "grep -aE \"\\[(blitter )?$b\\]|\\[$b\\]\" $LOG | tail -4" 2>/dev/null || true
    done
    echo "--- engine alive? ---"
    ssh "$HOST" "pidof solarus-run >/dev/null && echo ALIVE || echo DEAD" 2>/dev/null || true
  } | tee "$OUT"
  # busybox has NO pkill -- kill by pidof. Never leave two engines on the fabric.
  ssh "$HOST" "kill -9 \$(pidof solarus-run) 2>/dev/null; sleep 1; true" 2>/dev/null || true
  echo "captured -> $OUT"; echo
}

run_leg 0 B-freerun
run_leg 1 A-barrier
echo "=== A/B done ==="
