#!/bin/bash
#
# MiSTer Scripts-menu launcher for the Solarus engine (software rendering → DDR).
# Copy to /media/fat/Scripts/. Runs the first quest in quests/; edit QUEST to pick
# another. Software rendering is forced via -force-software-rendering and the SDL
# dummy video driver (no X / no GPU on MiSTer).
#
GMDIR=/media/fat/games/solarus
QUEST="${QUEST:-quests/mystery_of_solarus_dx}"
cd "$GMDIR" || { echo "dir not found: $GMDIR"; sleep 3; exit 1; }

pkill -9 -f "solarus-run" 2>/dev/null
sleep 1

export SDL_VIDEODRIVER=dummy
export LD_LIBRARY_PATH="$GMDIR/libs:$GMDIR:$LD_LIBRARY_PATH"
echo "Launching Solarus ($QUEST)... log: /tmp/solarus.log"
./solarus-run -force-software-rendering "$QUEST" 2>&1 | tee /tmp/solarus.log
