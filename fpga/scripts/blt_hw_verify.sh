#!/bin/sh
# blt_hw_verify.sh — on-device command-ring blitter smoke test + readback.
# Runs on the MiSTer (busybox). Writes a CLEAR=blue + FILL-red-rect display list,
# rings the submit doorbell, then reads back the done handshake, the diagnostic
# heartbeat (status word), and real framebuffer pixels to confirm the blitter
# composited. No ARM engine needed — pure fabric.
#
# Control block @ 0x3B000000 (qword-spaced): submit/cmd_count/target/clear/flags/
#   done_seq/status. Command ring @ 0x3B000040. Framebuffer BUF0 @ 0x3A000040.
set -e
CB=0x3B000000
RING=0x3B000040
FB0=0x3A000040

echo "== zero control block =="
for off in 0000 0008 0010 0018 0020 0028 0030; do busybox devmem 0x3B00$off 32 0; done

echo "== status BEFORE (heartbeat) =="
busybox devmem 0x3B000030 32

echo "== write display list (FILL red 64x48 @128,96 over blue CLEAR) =="
# cmd0 FILL
busybox devmem 0x3B000040 32 0x00000002   # op=FILL
busybox devmem 0x3B000044 32 0x00000000
busybox devmem 0x3B000048 32 0x00000000
busybox devmem 0x3B00004C 32 0x00300040   # h=48 w=64
busybox devmem 0x3B000050 32 0x00000000
busybox devmem 0x3B000054 32 0x00600080   # dst_y=96 dst_x=128
busybox devmem 0x3B000058 32 0x00000000
busybox devmem 0x3B00005C 32 0x0000F800   # color=red
# cmd1 END
busybox devmem 0x3B000060 32 0x00000001
busybox devmem 0x3B000064 32 0x00000000
busybox devmem 0x3B000068 32 0x00000000
busybox devmem 0x3B00006C 32 0x00000000
# control block
busybox devmem 0x3B000008 32 0x00000002   # cmd_count=2
busybox devmem 0x3B000010 32 0x00000000   # target_buf=0
busybox devmem 0x3B000018 32 0x0000001F   # clear_color=blue
busybox devmem 0x3B000020 32 0x00000001   # flags=CLEAR
busybox devmem 0x3B000028 32 0x00000000   # done_seq=0
echo "== ring doorbell (submit_seq=1) =="
busybox devmem 0x3B000000 32 0x00000001

# give the fabric a moment to walk the 2-command list
sleep 1

echo "== done_seq @0x3B000028 (expect 00000001) =="
busybox devmem 0x3B000028 32
echo "== status/heartbeat @0x3B000030 (expect ADVANCING vs before; was stuck 0x069E0000) =="
busybox devmem 0x3B000030 32
busybox devmem 0x3B000030 32
echo "== VCTRL @0x3A000000 (expect 00000004 = frame1|buf0) =="
busybox devmem 0x3A000000 32
echo "== BUF0[0] @0x3A000040 (expect blue 001F001F) =="
busybox devmem 0x3A000040 32
echo "== rect origin px (128,96) @0x3A00F140 (expect red F800F800) =="
busybox devmem 0x3A00F140 32
echo "== non-rect px (8,8) @0x3A001450 (expect blue 001F001F) =="
busybox devmem 0x3A001450 32
echo "== DONE =="
