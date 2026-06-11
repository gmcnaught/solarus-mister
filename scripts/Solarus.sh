#!/bin/bash
#
# MiSTer Scripts-menu launcher for the Solarus engine (software rendering → DDR).
# Copy to /media/fat/Scripts/. Runs the first quest in quests/; edit QUEST to pick
# another. Software rendering is forced via -force-software-rendering and the SDL
# dummy video driver (no X / no GPU on MiSTer).
#
GMDIR=/media/fat/games/solarus
QUEST="${QUEST:-quests/mystery_of_solarus_dx}"
# Shared FPGA core that provides the 320x240 DDR framebuffer + writes controller
# state to DDR for our input bridge. Reusing OpenBOR's RBF until a branded
# Solarus core exists (task 010). Override with RBF=/path.
RBF="${RBF:-$(ls -t /media/fat/_Other/OpenBOR_*.rbf 2>/dev/null | head -1)}"
cd "$GMDIR" || { echo "dir not found: $GMDIR"; sleep 3; exit 1; }

pkill -9 -f "solarus-run" 2>/dev/null
sleep 1

# Load the FPGA core (320x240 native video + controller passthrough to DDR).
if [ -n "$RBF" ] && [ -e "$RBF" ]; then
  echo "Loading FPGA core: $RBF"
  echo "load_core $RBF" > /dev/MiSTer_cmd
  sleep 3
else
  echo "WARNING: no FPGA core RBF found in /media/fat/_Other/OpenBOR_*.rbf — video/input will not display"
fi

export SDL_VIDEODRIVER=dummy
export LD_LIBRARY_PATH="$GMDIR/libs:$GMDIR:$LD_LIBRARY_PATH"
echo "Launching Solarus ($QUEST)... log: /tmp/solarus.log"
./solarus-run -force-software-rendering "$QUEST" 2>&1 | tee /tmp/solarus.log
