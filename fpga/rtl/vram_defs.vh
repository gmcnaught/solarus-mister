`ifndef VRAM_DEFS_VH
`define VRAM_DEFS_VH
// SDRAM framebuffer (VRAM) BYTE addresses. Scanout reads FB here; the Solarus.sv
// demux redirects the blitter's DDR FB writes here. 64MB AS4C32M16.
//   0x000000..0x3FFFFF = source-texture heap (existing #19 staging mirror)
`define SDRAM_FB0_BASE  27'h0400000   // FB0  (320x240 RGB565 = 0x25800 B; 0x40000 slot)
`define SDRAM_FB1_BASE  27'h0440000   // FB1
`define SDRAM_FB_STRIDE 27'd640       // 320 px * 2 B = one scanline
// Blitter DDR FB qword bases (MUST MATCH blitter_defs.vh FB0_QW/FB1_QW). The demux
// decodes these and remaps to the SDRAM bases above; the reader uses the SDRAM bases.
`define FB_DDR0_QW   29'h07400008
`define FB_DDR1_QW   29'h07408008
`define FB_QWORDS    29'd19200        // 320*240*2/8
`endif
