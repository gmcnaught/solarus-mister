// blitter_defs.vh — REAL hardware DDR addresses for blitter_top in the Solarus
// core (qword = phys>>3). The blitter command region lives in the unused gap
// after the audio ring (0x3A0E0000..0x3A100000), INSIDE the already-proven 1 MiB
// f2h region (0x3A000000, mapped by native_video_writer) — no reserved-region
// risk. The framebuffer + video control word are the existing scanout buffers,
// so the blitter is a drop-in producer.
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
`define BLTCTRL_QW  29'h0741C000          // 0x3A0E0000 (blitter control block)
`define RING_QW     29'h0741C008          // 0x3A0E0040 (command ring)
`define SRC_QW      29'h0741D000          // 0x3A0E8000 (source-surface heap)
`define MEM_QW      29'h07420000          // (region end; sim guard only)

// control-block field offsets (qwords from BLTCTRL_QW), low 32 bits used
`define C_SUBMIT    29'd0
`define C_CMDCOUNT  29'd1
`define C_TARGET    29'd2
`define C_CLEAR     29'd3
`define C_FLAGS     29'd4
`define C_DONE      29'd5
`define C_STATUS    29'd6

`endif
