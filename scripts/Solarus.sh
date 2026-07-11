#!/bin/bash
#
# MiSTer Scripts-menu launcher for the Solarus engine. Deploys to
# /media/fat/Scripts/Solarus.sh.
#
# The recommended path is auto-launch: load the branded Solarus core from the
# MiSTer console menu and our solarus_daemon (or Frontier, if installed) fires
# games/Solarus/_handler.sh -> quest_manager.sh. This Scripts launcher just makes
# sure that daemon is running, then loads the core — the daemon takes it from
# there. It does NOT launch quest_manager directly (that would double up with the
# daemon). The core idles with no game until a quest is picked from the OSD.
#
GAMEDIR=/media/fat/games/Solarus
# Latest branded Solarus RBF. Override with RBF=/path.
# Selection convention (MUST match deploy.py, which picks sorted(glob)[-1]):
# lexicographically-last filename. Names are Solarus_YYYYMMDD.rbf, so the plain
# name sort IS chronological and is stable regardless of upload/mtime order —
# `ls -t` (mtime) could disagree with deploy.py after an out-of-order re-push.
# shellcheck disable=SC2012  # name-sort of Solarus_YYYYMMDD.rbf is the intended pick; busybox find lacks sortable -printf
RBF="${RBF:-$(ls -1 /media/fat/_Other/Solarus_*.rbf 2>/dev/null | sort | tail -1)}"

export GAMEDIR
cd "$GAMEDIR" || { echo "dir not found: $GAMEDIR"; sleep 3; exit 1; }

# Clear any stale engine/manager so the daemon starts a fresh one on core load.
# busybox: no pkill, and pidof has no -x (won't match a script) -> match scripts
# in ps with a [x]-style grep; solarus-run is a real binary so pidof finds it.
# shellcheck disable=SC2009  # busybox has no reliable pgrep; the [x]-grep matches script names ps shows
for p in $(ps -o pid,args 2>/dev/null | grep '[q]uest_manager.sh' | awk '{print $1}'); do
  kill -9 "$p" 2>/dev/null
done
# Guard the empty case: a bare `kill -9` (pidof output empty) would error on the
# no-fallback device. The split of $sol_pids is intentional (pidof can return >1).
sol_pids=$(pidof solarus-run)
# shellcheck disable=SC2086  # intentional word-split: pidof may return multiple pids
[ -n "$sol_pids" ] && kill -9 $sol_pids 2>/dev/null
sleep 1

# Ensure our core-load daemon is running (provides auto-launch without Frontier;
# defers to Frontier's Master_Daemon when that is installed). On first run it
# self-registers into user-startup.sh, so it persists across reboot after this.
# shellcheck disable=SC2009  # busybox has no reliable pgrep; [x]-grep on ps args is the device idiom
if ! ps -o pid,args 2>/dev/null | grep -q '[s]olarus_daemon.sh'; then
  echo "Starting Solarus core-load daemon."
  setsid bash "$GAMEDIR/solarus_daemon.sh" >/dev/null 2>&1 &
fi

# Load the branded Solarus FPGA core (320x240 native DDR video + controller
# passthrough to DDR for our input bridge). The CORENAME change makes the daemon
# spawn _handler.sh -> quest_manager.sh.
if [ -n "$RBF" ] && [ -e "$RBF" ]; then
  echo "Loading FPGA core: $RBF"
  echo "load_core $RBF" > /dev/MiSTer_cmd
  sleep 3
else
  echo "WARNING: no Solarus RBF found in /media/fat/_Other/Solarus_*.rbf —"
  echo "         video/input will not display. Install the core first."
fi

echo "Solarus core loaded. Pick a quest from the OSD (Load Quest) to play."
echo "(log: /media/fat/logs/Solarus/Solarus.log)"
