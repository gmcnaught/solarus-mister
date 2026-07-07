#!/bin/sh
#
# Live framerate monitor for the Solarus MiSTer core.
# Reads the FPGA frame counter from DDR (0x3A000000, control word =
# frame_counter[31:2] | active_buf[1:0]) once a second and prints the delta =
# frames actually delivered to the FPGA that second (the real on-screen fps).
#
# Run it ON the MiSTer (it uses busybox devmem) while a quest is running, e.g.
# in a second SSH session:
#   ssh root@192.168.20.81 'sh /media/fat/games/solarus/fps_monitor.sh'
#
prev=""
while true; do
  c=$(busybox devmem 0x3A000000 2>/dev/null)
  f=$(( c >> 2 ))
  if [ -n "$prev" ]; then
    echo "$(( f - prev )) fps"
  fi
  prev=$f
  sleep 1
done
