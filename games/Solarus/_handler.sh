#!/bin/bash
#
# Solarus auto-launch handler — invoked by MiSTer's Master_Daemon (Frontier)
# when the Solarus FPGA core loads. The daemon routes a loaded core by CORENAME
# ("Solarus", from the RBF's CONF_STR setname) -> games/Solarus/_handler.sh.
#
# Modeled on MiSTer_OpenBOR_7533/games/OpenBOR/_handler.sh. We launch the quest
# lifecycle manager (quest_manager.sh), NOT the engine directly: the core idles
# with no game until a quest is picked from the OSD (PICO-8/OpenBOR/PSX pattern).
# The manager polls Solarus.s0, launches/switches the engine on a pick (via the
# shared solarus_run.sh), and exits on a core change.

GAMEDIR="/media/fat/games/Solarus"
LOGDIR="/media/fat/logs/Solarus"

cd "$GAMEDIR" || exit 1
mkdir -p "$LOGDIR"

# Rotate the previous log.
mv -f "$LOGDIR/Solarus.log" "$LOGDIR/Solarus.prev.log" 2>/dev/null

# FPGA settle after core load.
sleep 1

export GAMEDIR
echo "Solarus handler: launching quest manager (CORENAME=$(cat /tmp/CORENAME 2>/dev/null))" \
    > "$LOGDIR/Solarus.log"
exec ./quest_manager.sh >> "$LOGDIR/Solarus.log" 2>&1
