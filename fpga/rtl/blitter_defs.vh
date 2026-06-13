// blitter_defs.vh — REAL hardware DDR addresses for blitter_top in the Solarus
// core (qword = phys>>3). The blitter command region lives in the FREE GAP
// between BUF1 (~0x3A066000) and the audio ring (0x3A0D0000), INSIDE the
// already-proven 1 MiB f2h region (0x3A000000, mapped by native_video_writer) —
// no reserved-region risk. The framebuffer + video control word are the existing
// scanout buffers, so the blitter is a drop-in producer.
//
// Layout (v2-heap-alias — enlarged source heap so full-frame sources fit):
//   BLTCTRL 0x3A070000 | RING 0x3A070040 | SRC heap 0x3A078000 | end 0x3A0D0000
//   heap = 0x3A0D0000 - 0x3A078000 = 0x58000 = 352 KiB (was 96 KiB @ 0x3A0E8000).
// The pre-audio gap was HW-verified untouched by the engine (a known pattern
// survives a few seconds of video+audio) before this move.
//
// (The mister-fpga-blitter repo's sim copy uses small windowed addresses; this
//  HW copy is the source of truth for the synthesized core.)
`ifndef BLITTER_DEFS_VH
`define BLITTER_DEFS_VH

`define FB_W        320
`define FB_H        240
`define FB_QWORDS   19200                 // 320*240*2 / 8

`define FB0_QW      29'h07400008          // 0x3A000040 (BUF0, existing)
`define FB1_QW      29'h07408008          // 0x3A040040 (BUF1, existing)
`define VCTRL_QW    29'h07400000          // 0x3A000000 (video control word)
`define BLTCTRL_QW  29'h0740E000          // 0x3A070000 (blitter control block)
`define RING_QW     29'h0740E008          // 0x3A070040 (command ring)
`define SRC_QW      29'h0740F000          // 0x3A078000 (source-surface heap, 352 KiB)
`define MEM_QW      29'h0741A000          // 0x3A0D0000 (region end; sim guard only)

// control-block field offsets (qwords from BLTCTRL_QW), low 32 bits used
`define C_SUBMIT    29'd0
`define C_CMDCOUNT  29'd1
`define C_TARGET    29'd2
`define C_CLEAR     29'd3
`define C_FLAGS     29'd4
`define C_DONE      29'd5
`define C_STATUS    29'd6

`endif
