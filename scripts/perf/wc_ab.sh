#!/usr/bin/env bash
# wc_ab.sh — write-combining A/B on a real gameplay scene.
#
# The lever is a host->DDR store-bandwidth change, so it can only show up where
# the A9 is actually emitting work. The title screen is vsync-capped at ~58 fps
# with fabric=0.0ms, which is why the first A/B attempt measured two identical
# arms; this drives to the fixed map-119 spot (the validated parallax capture
# point from scripts/perf/capture_map119.sh) instead.
#
# ARMS ARE INTERLEAVED and the order ALTERNATES (ON,OFF,OFF,ON,ON,OFF...). A
# straight A,A,A,B,B,B would let thermal drift, a background daemon, or SD-card
# state masquerade as the effect.
#
#   scripts/perf/wc_ab.sh [reps]        # default 3 per arm
#
# Env: HOST (default root@192.168.20.81), RBF (default current ship)
set -euo pipefail
HOST="${HOST:-root@192.168.20.81}"
RBF="${RBF:-Solarus_20260726.rbf}"
REPS="${1:-3}"
LOG=/media/fat/logs/Solarus/wc-boot.log
FIFO=/tmp/sol_in
MAP=119; DEST="${DEST:-from_dungeon_10}"
DOWN=0x04
OUT="$(cd "$(dirname "$0")/../.." && pwd)/docs/superpowers/data/wc-ab"
mkdir -p "$OUT"

scp -q "$(dirname "$0")/wc_launch.sh" "$HOST:/tmp/wc_launch.sh"

# One leg: launch, reach map 119, capture a standing window and a moving window.
leg() {
  local label="$1" env="$2" rep="$3" f="$OUT/${1}-rep${3}.txt"
  echo "-- leg $label rep $rep --"
  ssh "$HOST" "sh /tmp/wc_launch.sh $RBF $env" > "$f" 2>&1

  # start the save and teleport to the fixed spot
  ssh "$HOST" "printf 'sol.main.game = sol.game.load(\"save1.dat\"); sol.menu.stop_all(sol.main); sol.main:start_savegame(sol.main.game)\n' > $FIFO"
  sleep 6
  ssh "$HOST" "printf 'sol.main.game:get_hero():teleport(\"$MAP\",\"$DEST\")\n' > $FIFO"
  sleep 6
  ssh "$HOST" "printf 'print(\"CURMAP=\"..sol.main.game:get_map():get_id())\n' > $FIFO"; sleep 2

  # A leg that did not actually reach map 119 must not be averaged in as if it
  # had -- it would be a different scene entirely.
  local curmap
  curmap=$(ssh "$HOST" "grep -o 'CURMAP=[0-9]*' $LOG | tail -1" || true)
  echo "$curmap" >> "$f"
  if [ "$curmap" != "CURMAP=$MAP" ]; then
    echo "  !! did not reach map $MAP (got '$curmap') — leg discarded"
    echo "DISCARDED" >> "$f"; return 0
  fi

  sleep 8   # let the standing window settle into fresh /60fr banners
  { echo "=== STANDING ==="
    ssh "$HOST" "for b in timing a9split emitsplit cvt; do grep -E \"\\[blitter \$b\\]\" $LOG | tail -2; done"
  } >> "$f"

  { echo "=== MOVING ==="
    ssh "$HOST" "( for i in \$(seq 1 240); do busybox devmem 0x3A000008 32 $DOWN; done; busybox devmem 0x3A000008 32 0x0 ) & sleep 6; for b in timing a9split; do grep -E \"\\[blitter \$b\\]\" $LOG | tail -2; done; busybox devmem 0x3A000008 32 0x0"
  } >> "$f"

  ssh "$HOST" "kill -9 \$(pidof solarus-run) 2>/dev/null; true"
}

for r in $(seq 1 "$REPS"); do
  if [ $((r % 2)) -eq 1 ]; then
    leg wcON  ""                 "$r"
    leg wcOFF "SOLARUS_NO_WC=1"  "$r"
  else
    leg wcOFF "SOLARUS_NO_WC=1"  "$r"
    leg wcON  ""                 "$r"
  fi
done

echo
echo "===================== RESULTS ====================="
for arm in wcON wcOFF; do
  echo "--- $arm ---"
  for f in "$OUT/$arm"-rep*.txt; do
    [ -f "$f" ] || continue
    grep -q DISCARDED "$f" && { echo "  $(basename "$f"): DISCARDED"; continue; }
    printf '  %s  map=%s  %s\n' "$(basename "$f")" \
      "$(grep -o 'CURMAP=[0-9]*' "$f" | tail -1)" \
      "$(grep -m1 'ddr mapping' "$f" | sed 's/.*mapping: //')"
    awk '/=== STANDING ===/{s=1} /=== MOVING ===/{s=2}
         s==1 && /blitter timing/{print "    standing " $0}
         s==1 && /a9split/{print "    standing " $0}
         s==2 && /blitter timing/{print "    moving   " $0}' "$f" | tail -6
  done
done
echo "raw -> $OUT/"
