#!/usr/bin/env bash
# Blend-layer A/B: dialog-up on map 40 (dungeon_3 auto-fires + holds a dialog
# headless). Leg B = SOLARUS_BLENDLAYER=1 (fabric layer), Leg A = 0 (software
# blend into root). Rebuild-free; reads the shipped diag banners.
# One engine on the fabric per leg (kill+relaunch between legs).
set -uo pipefail
HOST="${HOST:-root@192.168.20.81}"
RBF="${RBF:-Solarus_20260724.rbf}"
MAP="${MAP:-40}"; DEST="${DEST:-from_outside}"
LOG=/media/fat/logs/Solarus/stage5-boot.log
FIFO=/tmp/sol_in
OUTDIR="docs/superpowers/data/blendlayer-ab"; mkdir -p "$OUTDIR"

# launch script with our RBF swapped in
sed "s#Solarus_20260721.rbf#${RBF}#g" scripts/perf/stage5_device_launch.sh > /tmp/_bl_launch.sh
scp -q /tmp/_bl_launch.sh "$HOST:/tmp/bl_launch.sh"

run_leg() {
  BL="$1"; TAG="$2"; OUT="$OUTDIR/leg-${TAG}.txt"
  echo "===== LEG $TAG  (SOLARUS_BLENDLAYER=$BL)  RBF=$RBF  map=$MAP/$DEST ====="
  # launch one engine with BLENDLAYER injected (env passes through to solarus-run)
  ssh "$HOST" "SOLARUS_BLENDLAYER=$BL SOLARUS_DRAW_PROF=1 sh /tmp/bl_launch.sh" >/dev/null 2>&1 &
  sleep 22   # boot + fabric settle
  # load a save + enter game
  ssh "$HOST" "printf 'sol.main.game = sol.game.load(\"save1.dat\"); sol.menu.stop_all(sol.main); sol.main:start_savegame(sol.main.game)\n' > $FIFO" 2>/dev/null || true
  sleep 8
  # teleport into the dungeon (auto-dialog fires on opening-transition-finished)
  ssh "$HOST" "printf 'sol.main.game:get_hero():teleport(\"$MAP\",\"$DEST\")\n' > $FIFO" 2>/dev/null || true
  sleep 12
  # probe map + dialog state into the log
  ssh "$HOST" "printf 'print(\"CURMAP=\"..sol.main.game:get_map():get_id()..\" DLG=\"..tostring(sol.main.game:is_dialog_enabled()))\n' > $FIFO" 2>/dev/null || true
  sleep 12   # let >=3 diag windows land with the dialog up
  {
    echo "### LEG $TAG  BLENDLAYER=$BL  RBF=$RBF  map=$MAP/$DEST"
    echo "--- map/dialog probe ---"
    ssh "$HOST" "grep -aoE 'CURMAP=[0-9]+ DLG=(true|false)' $LOG | tail -2" 2>/dev/null || true
    echo "--- flag echo (BLENDLAYER on/off line) ---"
    ssh "$HOST" "grep -aiE 'blendlayer|BLENDLAYER' $LOG | grep -aiv '^\\[blitter blendlayer\\]' | tail -3" 2>/dev/null || true
    for b in blendlayer a9split "MiSTer draw" hwperf timing; do
      echo "--- [$b] (last 4) ---"
      ssh "$HOST" "grep -aE \"\\[(blitter )?$b\\]|\\[$b\\]\" $LOG | tail -4" 2>/dev/null || true
    done
    echo "--- engine alive? ---"
    ssh "$HOST" "pidof solarus-run >/dev/null && echo ALIVE || echo DEAD" 2>/dev/null || true
  } | tee "$OUT"
  # teardown this leg's engine before the next
  ssh "$HOST" "kill -9 \$(pidof solarus-run) 2>/dev/null; sleep 1; true" 2>/dev/null || true
  echo "captured -> $OUT"; echo
}

run_leg 1 B-on
run_leg 0 A-off
echo "=== A/B done ==="
