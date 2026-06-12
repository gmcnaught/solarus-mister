#!/bin/bash
#
# Solarus auto-launch handler — invoked by MiSTer's Master_Daemon (Frontier)
# when the Solarus FPGA core loads. The daemon routes a loaded core by CORENAME
# ("Solarus", from the RBF's CONF_STR setname) -> games/Solarus/_handler.sh.
#
# Modeled on MiSTer_OpenBOR_7533/games/OpenBOR/_handler.sh. The real launch
# logic lives in solarus_run.sh (shared with Scripts/Solarus.sh).

GAMEDIR="/media/fat/games/Solarus"
LOGDIR="/media/fat/logs/Solarus"

cd "$GAMEDIR" || exit 1
mkdir -p "$LOGDIR"

# Rotate the previous log.
mv -f "$LOGDIR/Solarus.log" "$LOGDIR/Solarus.prev.log" 2>/dev/null

# FPGA settle after core load.
sleep 1

export GAMEDIR
echo "Solarus handler: launching engine (CORENAME=$(cat /tmp/CORENAME 2>/dev/null))" \
    > "$LOGDIR/Solarus.log"
exec ./solarus_run.sh >> "$LOGDIR/Solarus.log" 2>&1
