#!/bin/bash
#
# MiSTer Scripts-menu launcher for the Solarus engine. Deploys to
# /media/fat/Scripts/Solarus.sh.
#
# The recommended path is auto-launch: load the branded Solarus core from the
# MiSTer console menu and games/Solarus/_handler.sh fires via Master_Daemon. This
# Scripts launcher is the manual fallback — it loads the branded Solarus FPGA core
# then runs the SAME quest lifecycle manager (games/Solarus/quest_manager.sh).
#
# Like the handler, the core idles with no game until a quest is picked from the
# MiSTer OSD (Load Quest); the manager then launches/switches the engine.
#
GAMEDIR=/media/fat/games/Solarus
# Latest branded Solarus RBF (by date in filename). Override with RBF=/path.
RBF="${RBF:-$(ls -t /media/fat/_Other/Solarus_*.rbf 2>/dev/null | head -1)}"

export GAMEDIR
cd "$GAMEDIR" || { echo "dir not found: $GAMEDIR"; sleep 3; exit 1; }

# Don't double-launch. Kill any old manager first so it doesn't fight this one,
# then any running engine. Device busybox has no pkill, and its pidof has no -x
# (won't match a script), so match quest_manager.sh in ps; the [q] trick keeps
# grep from matching itself. solarus-run is a real binary so pidof finds it.
for p in $(ps -o pid,args 2>/dev/null | grep '[q]uest_manager.sh' | awk '{print $1}'); do
  kill -9 "$p" 2>/dev/null
done
kill -9 $(pidof solarus-run) 2>/dev/null
sleep 1

# Load the branded Solarus FPGA core (320x240 native DDR video + controller
# passthrough to DDR for our input bridge).
if [ -n "$RBF" ] && [ -e "$RBF" ]; then
  echo "Loading FPGA core: $RBF"
  echo "load_core $RBF" > /dev/MiSTer_cmd
  sleep 3
else
  echo "WARNING: no Solarus RBF found in /media/fat/_Other/Solarus_*.rbf —"
  echo "         video/input will not display. Install the core first."
fi

echo "Launching Solarus quest manager... (log: /media/fat/logs/Solarus/Solarus.log)"
echo "Core idles with no game until you pick a quest from the OSD (Load Quest)."
mkdir -p /media/fat/logs/Solarus
exec ./quest_manager.sh 2>&1 | tee /media/fat/logs/Solarus/Solarus.log
