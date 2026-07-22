#!/usr/bin/env bash
# Stage 5 Phase 2 — reproducible map-119 standing+moving capture (VALIDATED 2026-07-21).
# Drives the deployed engine to map 119 via the lua-console FIFO, captures the diag
# banners standing and moving. See scripts/perf/README-stage5.md for the fixed spot.
#
# Prereqs on device (192.168.20.81): correct engine deployed (sha1 8a56d13f, TILEMAPCH on),
# Solarus_20260721.rbf present, MoSDX quest + save1.dat present.
# Recipes: safe single-engine launch, lua-console teleport, joypad-inject (devmem 0x3A000008).
set -euo pipefail
HOST="${HOST:-root@192.168.20.81}"
LOG=/media/fat/logs/Solarus/stage5-boot.log
FIFO=/tmp/sol_in
MAP=119; DEST="${DEST:-from_dungeon_10}"   # FIXED map-119 spot (see README-stage5.md)
DOWN=0x04                                   # dpad DOWN for the moving window

# 1) clean slate -> load Solarus core -> ONE engine on a held FIFO (see stage5_device_launch.sh)
scp -q "$(dirname "$0")/stage5_device_launch.sh" "$HOST:/tmp/stage5_launch.sh"
ssh "$HOST" 'sh /tmp/stage5_launch.sh' >/dev/null 2>&1 &
sleep 18   # boot + fabric settle

# 2) start the game (save1) and teleport to the fixed map-119 spot
ssh "$HOST" "printf 'sol.main.game = sol.game.load(\"save1.dat\"); sol.menu.stop_all(sol.main); sol.main:start_savegame(sol.main.game)\n' > $FIFO"
sleep 6
ssh "$HOST" "printf 'sol.main.game:get_hero():teleport(\"$MAP\",\"$DEST\")\n' > $FIFO"
sleep 6
ssh "$HOST" "printf 'print(\"CURMAP=\"..sol.main.game:get_map():get_id())\n' > $FIFO"; sleep 2
ssh "$HOST" "grep -o 'CURMAP=[0-9]*' $LOG | tail -1"   # must print CURMAP=119

# 3) STANDING window: hero idle, grab latest banners
sleep 6
mkdir -p docs/superpowers/data/stage5
ssh "$HOST" "for b in timing hwperf p0 engcpp resident a9split cvt; do grep -E \"\\[blitter \$b\\]\" $LOG | tail -1; done" \
  > docs/superpowers/data/stage5/stage5-standing-window.txt

# 4) MOVING window: hold DOWN in a bg loop, capture, release
ssh "$HOST" "( for i in \$(seq 1 240); do busybox devmem 0x3A000008 32 $DOWN; done; busybox devmem 0x3A000008 32 0x0 ) & sleep 6; for b in timing hwperf p0; do grep -E \"\\[blitter \$b\\]\" $LOG | tail -1; done; busybox devmem 0x3A000008 32 0x0" \
  > docs/superpowers/data/stage5/stage5-moving-window.txt

# 5) pull the full log
scp -q "$HOST:$LOG" docs/superpowers/data/stage5/stage5-map119-raw.log
echo "captured -> docs/superpowers/data/stage5/"
