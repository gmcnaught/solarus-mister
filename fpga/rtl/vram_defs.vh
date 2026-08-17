`ifndef VRAM_DEFS_VH
`define VRAM_DEFS_VH
// SDRAM framebuffer (VRAM) BYTE addresses. Scanout reads FB here; the Solarus.sv
// demux redirects the blitter's DDR FB writes here. 64MB AS4C32M16.
//   0x000000..0x3FFFFF = source-texture heap (existing #19 staging mirror)
// Framebuffer geometry comes from fb_geom.vh — do NOT respell it here. This file
// used to carry its own `FB_QWORDS as 29'd19200 while blitter_defs.vh carried an
// unsized 19200; any translation unit including both got a redefinition, harmless
// only because the two numbers happened to agree.
`include "fb_geom.vh"

`define SDRAM_FB0_BASE  27'h0400000   // FB0 (0x40000 slot; FB_W*FB_H*2 must fit)
`define SDRAM_FB1_BASE  27'h0440000   // FB1
`define SDRAM_FB_STRIDE 27'(`FB_ROW_BYTES)   // one scanline, bytes
// Blitter DDR FB qword bases (MUST MATCH blitter_defs.vh FB0_QW/FB1_QW). The demux
// decodes these and remaps to the SDRAM bases above; the reader uses the SDRAM bases.
`define FB_DDR0_QW   29'h07400008
`define FB_DDR1_QW   29'h07408008
`endif
