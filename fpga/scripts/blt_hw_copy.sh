#!/bin/sh
# blt_hw_copy.sh — on-device COPY/BLIT smoke test (HW analog of tb_blitter_copy).
# Uploads a 4x2 RGB565 sprite to the source region, issues a single BLIT command
# copying it to dst (100,80), then reads back the destination pixels. Proves the
# fabric blitter's source-fetch + incremental addressing path on real hardware
# (FILL only exercises the write path; this exercises reads of a source surface).
#
# Regions: ctrl/ring @ 0x3B000000 (BLTCTRL_QW 0x0740E000); source @ 0x3B008000
# (SRC_QW 0x0740F000); framebuffer BUF0 @ 0x3A000040.
set -e

echo "== upload 4x2 source sprite @ 0x3B008000 (stride 8B) =="
# row0: red, green, blue, white
busybox devmem 0x3B008000 32 0x07E0F800   # [green | red]
busybox devmem 0x3B008004 32 0xFFFF001F   # [white | blue]
# row1: yellow, magenta, cyan, gray
busybox devmem 0x3B008008 32 0xF81FFFE0   # [magenta | yellow]
busybox devmem 0x3B00800C 32 0x841007FF   # [gray | cyan]

echo "== mark dst region green so we can see the copy land =="
busybox devmem 0x3A00C908 32 0x07E007E0   # dst (100,80)/(101,80)
busybox devmem 0x3A00C90C 32 0x07E007E0   # dst (102,80)/(103,80)
busybox devmem 0x3A00CB88 32 0x07E007E0   # dst (100,81)/(101,81)

echo "== BLIT command @ ring 0x3B000040: op=BLIT src_off=0 w=4 h=2 stride=8 dst=(100,80) =="
busybox devmem 0x3B000040 32 0x00000003   # qw0 lo: opcode=BLIT, blend=COPY
busybox devmem 0x3B000044 32 0x00000000   # qw0 hi: src_off=0
busybox devmem 0x3B000048 32 0x00000008   # qw1 lo: src_x=0 | stride=8
busybox devmem 0x3B00004C 32 0x00020004   # qw1 hi: h=2 | w=4
busybox devmem 0x3B000050 32 0x00000000   # qw2 lo: src_y=0
busybox devmem 0x3B000054 32 0x00500064   # qw2 hi: dst_y=80 | dst_x=100
busybox devmem 0x3B000058 32 0x00000000   # qw3 lo
busybox devmem 0x3B00005C 32 0x00000000   # qw3 hi
busybox devmem 0x3B000060 32 0x00000001   # cmd1 END
busybox devmem 0x3B000064 32 0x00000000
busybox devmem 0x3B000068 32 0x00000000
busybox devmem 0x3B00006C 32 0x00000000

echo "== control block + doorbell =="
busybox devmem 0x3B000008 32 0x00000002   # cmd_count=2
busybox devmem 0x3B000010 32 0x00000000   # target_buf=0
busybox devmem 0x3B000020 32 0x00000000   # flags=0 (NO clear)
busybox devmem 0x3B000028 32 0x00000000   # done_seq=0
busybox devmem 0x3B000000 32 0x00000001   # submit_seq=1 (doorbell)
sleep 1

echo "== readback =="
echo "done@28 : $(busybox devmem 0x3B000028 32)  (expect 00000001)"
echo "dst (100,80)/(101,80) @C908: $(busybox devmem 0x3A00C908 32)  (expect 07E0F800 = green|red)"
echo "dst (102,80)/(103,80) @C90C: $(busybox devmem 0x3A00C90C 32)  (expect FFFF001F = white|blue)"
echo "dst (100,81)/(101,81) @CB88: $(busybox devmem 0x3A00CB88 32)  (expect F81FFFE0 = magenta|yellow)"
echo "== DONE =="
