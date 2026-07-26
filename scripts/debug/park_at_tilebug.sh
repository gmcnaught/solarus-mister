#!/usr/bin/env bash
# park_at_tilebug.sh — drive the deployed Solarus engine to a known "partial-tile /
# bgcolor-fill" bug location and PARK the hero there so the bug can be observed and
# diagnosed. Reuses the lua-console-over-held-FIFO teleport recipe (see
# scripts/perf/stage5_device_launch.sh + capture_map119.sh, and the memory
# "solarus-84-luaconsole-teleport-repro").
#
# The bug: some entities draw only a PORTION of their tiles; the remainder is filled
# with the tile's background colour. Predates PR #111 (base compositor / atlas / emit
# path, NOT the tilemap/sprite/overlay/GRIDOV channels). Same entity often renders
# fine elsewhere on the same map, so it is position/context specific.
#
# Usage:
#   scripts/debug/park_at_tilebug.sh list                 # show known targets
#   scripts/debug/park_at_tilebug.sh <target>             # park at a known target
#   scripts/debug/park_at_tilebug.sh custom               # use MAP/DEST/HX/HY/HL env
#
# Env overrides:
#   HOST   (default root@192.168.20.81)
#   RBF    core to load (default Solarus_20260723.rbf — current ship). Set to an
#          OLDER rbf to check whether the bug is engine- or fabric-side.
#   RELOAD_CORE=0  skip load_core (park on whatever is already running)
#   MAP DEST HX HY HL   for `custom` target (HL = hero layer)
#   EXTRA_ENV  extra "K=V K=V" passed to the engine (e.g. diag flags)
set -euo pipefail

HOST="${HOST:-root@192.168.20.81}"
RBF="${RBF:-Solarus_20260723.rbf}"
RELOAD_CORE="${RELOAD_CORE:-1}"
EXTRA_ENV="${EXTRA_ENV:-}"
GAMEDIR=/media/fat/games/Solarus
LOGDIR=/media/fat/logs/Solarus
LOG="$LOGDIR/tilebug-park.log"
FIFO=/tmp/sol_in
OUTDIR="$(cd "$(dirname "$0")/../.." && pwd)/docs/superpowers/data/tilebug"

# --- Known bug targets ------------------------------------------------------------
# fields: map | teleport-dest | hero_x | hero_y | hero_layer | description
# Hero is placed (set_position) to FRAME the buggy entity in the 320x240 view
# (camera centres on the hero).
# Framings below were CONFIRMED on-device 2026-07-23 (screenshots show the bug).
targets_table() {
cat <<'TARGETS'
dungeon3_eye|41|from_1F_ne|848|548|1|Dungeon-3 2F eye-creature statues (arrow_target switches @792,520 & 904,520): almost entirely undrawn, only their TOPS render
castle_statue|89|from_outside|608|1150|1|Castle 1F gray gargoyle statues flanking entrance: LEFT pair missing top-right + bottom-left corners; identical RIGHT pair renders CORRECTLY
map119_totem|119|from_dungeon_10|424|600|0|Map 119 dungeon-entrance area: big totem (pat 916 32x48) renders only a left sliver; skull block (pat 714, placed 32x24 = 2x h-repeat) missing its right repeat
TARGETS
}

list_targets() {
  echo "Known partial-tile-fill bug targets:"
  targets_table | while IFS='|' read -r name map dest hx hy hl desc; do
    printf '  %-14s map %-3s dest=%-16s hero=(%s,%s,L%s)\n                 %s\n' \
      "$name" "$map" "$dest" "$hx" "$hy" "$hl" "$desc"
  done
}

resolve() {
  local want="$1"
  targets_table | while IFS='|' read -r name map dest hx hy hl desc; do
    [ "$name" = "$want" ] && echo "$map|$dest|$hx|$hy|$hl|$desc"
  done
}

# --- Arg parsing ------------------------------------------------------------------
TARGET="${1:-list}"
if [ "$TARGET" = "list" ] || [ -z "$TARGET" ]; then list_targets; exit 0; fi

if [ "$TARGET" = "custom" ]; then
  MAP="${MAP:?set MAP=}"; DEST="${DEST:?set DEST=}"
  HX="${HX:?set HX=}"; HY="${HY:?set HY=}"; HL="${HL:-0}"
  DESC="custom MAP=$MAP DEST=$DEST hero=($HX,$HY,L$HL)"
else
  row="$(resolve "$TARGET")"
  [ -n "$row" ] || { echo "unknown target '$TARGET'"; echo; list_targets; exit 1; }
  IFS='|' read -r MAP DEST HX HY HL DESC <<EOF
$row
EOF
fi

echo "=== PARK: $TARGET ==="
echo "    $DESC"
echo "    RBF=$RBF  RELOAD_CORE=$RELOAD_CORE  HOST=$HOST"

# --- Device-side launcher (self-contained; own RBF param) -------------------------
DEV_LAUNCH=/tmp/tilebug_launch.sh
# shellcheck disable=SC2087  # client-side expansion INTENDED: the heredoc interpolates
# local host vars ($RBF/$RELOAD_CORE/$LOG/$EXTRA_ENV) into the device script.
ssh "$HOST" "cat > $DEV_LAUNCH" <<DEVEOF
#!/bin/sh
set -u
GAMEDIR=$GAMEDIR; LOGDIR=$LOGDIR; FIFO=$FIFO
mkdir -p "\$LOGDIR"
# 1) kill auto-launch machinery + any engine (avoid the two-engine wedge)
for p in quest_manager.sh core_watch.sh solarus_daemon.sh; do
  kill -9 \$(pidof -x "\$p" 2>/dev/null) 2>/dev/null
  for pid in \$(ps | grep "\$p" | grep -v grep | awk '{print \$1}'); do kill -9 \$pid 2>/dev/null; done
done
kill -9 \$(pidof solarus-run) 2>/dev/null
: > /media/fat/config/Solarus.s0
sleep 1
# 2) optionally load the core onto the FPGA
if [ "$RELOAD_CORE" = "1" ]; then
  echo "load_core /media/fat/_Other/$RBF" > /dev/MiSTer_cmd
  sleep 5
  kill -9 \$(pidof solarus-run) 2>/dev/null
  for pid in \$(ps | grep -E 'quest_manager|core_watch|solarus_daemon' | grep -v grep | awk '{print \$1}'); do kill -9 \$pid 2>/dev/null; done
  sleep 1
fi
# 3) quest dir indirection
rm -rf /tmp/solarus_quest; mkdir -p /tmp/solarus_quest
ln -sf "\$GAMEDIR/quests/mystery_of_solarus_dx.sol" /tmp/solarus_quest/data.solarus
# 4) held-open FIFO for lua-console stdin.
#    NOTE: the holder's stdout/stderr MUST be redirected away from this ssh session,
#    else 'tail -f' keeps the ssh stdout pipe open forever and the launching
#    'ssh sh \$DEV_LAUNCH' never returns (observed hang, 2026-07-23).
rm -f "\$FIFO"; mkfifo "\$FIFO"
setsid sh -c 'tail -f /dev/null > '"\$FIFO"' 2>/dev/null' </dev/null >/dev/null 2>&1 &
# 5) launch ONE engine, shipping blitter flags + DIAG, lua-console on the FIFO
: > "$LOG"
cd "\$GAMEDIR" || exit 1
env SDL_VIDEODRIVER=dummy LD_LIBRARY_PATH="\$GAMEDIR/libs:\$GAMEDIR" HOME=/media/fat/saves/Solarus \
    SOLARUS_BLITTER=1 SOLARUS_BLITTER_SINGLEBUF=1 SOLARUS_BLITTER_DIAG=1 $EXTRA_ENV \
    setsid ./solarus-run -force-software-rendering -lua-console=yes /tmp/solarus_quest \
    < "\$FIFO" > "$LOG" 2>&1 &
sleep 12
echo "engine alive? "; pidof solarus-run || echo "(DEAD)"
tail -8 "$LOG"
DEVEOF

echo "--- launching engine on device ---"
ssh "$HOST" "sh $DEV_LAUNCH"

# --- Start the game, teleport, and park the hero to frame the entity --------------
lua() { ssh "$HOST" "printf '%s\n' '$1' > $FIFO"; }

echo "--- starting savegame ---"
lua 'sol.main.game = sol.game.load("save1.dat"); sol.menu.stop_all(sol.main); sol.main:start_savegame(sol.main.game)'
sleep 6

echo "--- teleport to map $MAP dest $DEST ---"
lua "sol.main.game:get_hero():teleport(\"$MAP\",\"$DEST\")"
sleep 6

echo "--- set_position hero -> ($HX,$HY,L$HL) to frame the entity ---"
lua "local h=sol.main.game:get_hero(); h:set_position($HX,$HY,$HL); h:freeze()"
sleep 3

echo "--- confirm current map ---"
lua "print(\"CURMAP=\"..sol.main.game:get_map():get_id()..\" HEROXY=\"..(function() local x,y=sol.main.game:get_hero():get_position() return x..','..y end)())"
sleep 2
ssh "$HOST" "grep -oE 'CURMAP=[0-9]+ HEROXY=[0-9]+,[0-9]+' $LOG | tail -1"

# --- Capture screenshot (objective visual evidence) -------------------------------
mkdir -p "$OUTDIR"
echo "--- triggering screenshot ---"
SHOT="$(ssh "$HOST" '
  before=$(ls -t /media/fat/screenshots/Solarus/*.png 2>/dev/null | head -1)
  echo "screenshot" > /dev/MiSTer_cmd
  sleep 2
  new=$(ls -t /media/fat/screenshots/Solarus/*.png 2>/dev/null | head -1)
  [ "$new" != "$before" ] && echo "$new"
')"
if [ -n "$SHOT" ]; then
  scp -q "$HOST:$SHOT" "$OUTDIR/${TARGET}-screen.png" && echo "    screenshot -> $OUTDIR/${TARGET}-screen.png"
else
  echo "    (no new screenshot produced — trigger may need a live frame; check display)"
fi

# --- Capture diag banners + full log ----------------------------------------------
sleep 2
ssh "$HOST" "for b in timing hwperf resident cvt; do grep -E \"\\[blitter \$b\\]\" $LOG | tail -1; done" \
  > "$OUTDIR/${TARGET}-banners.txt" || true
scp -q "$HOST:$LOG" "$OUTDIR/${TARGET}-raw.log" || true

echo
echo "=== PARKED at $TARGET — engine is running, hero frozen at the bug spot. ==="
echo "    Look at the MiSTer display now to observe the partial-tile / bgcolor fill."
echo "    Diag: $OUTDIR/${TARGET}-banners.txt"
echo "    Log:  $OUTDIR/${TARGET}-raw.log"
echo "    Restore normal play: reload the Solarus core from the OSD."
