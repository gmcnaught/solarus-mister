// fb_geom.vh — the ONE definition of compositor framebuffer geometry.
//
// Before this file existed the same numbers were spelled out in nine places
// (comp_fbram's FB_QWORDS, comp_pipeline's three `y*80` row-stride multiplies,
// comp_span_setup's FB_W/FB_H, fb_ddr_writer's LINE_BEATS, ddr3_scan_adapter's
// LINE_QW, openbor_video_reader's LINE_BURST/LINE_STRIDE and line buffers,
// openbor_video_timing's H_ACTIVE/V_ACTIVE, and FB_QWORDS in BOTH blitter_defs.vh
// and vram_defs.vh with DIFFERENT widths). Geometry is wire ABI — it has to match
// blitter_ref.h's BLT_FB_WIDTH/BLT_FB_HEIGHT on the host — so a missed site does not
// fail loudly, it renders garbage. Everything derives from FB_W/FB_H here.
//
// Keep FB_W a multiple of 4: a qword is 4 RGB565 pixels, and the whole datapath
// (comp_fbram's qword index, the line-granular DDR3 bursts, the scanout adapter's
// per-line burst) assumes a scanline is a whole number of qwords with every row
// base qword-aligned. 320/4 = 80 and 416/4 = 104, both exact.
`ifndef FB_GEOM_VH
`define FB_GEOM_VH

// 416 wide (was 320) so quests that declare min == max == 416x240 can render at all —
// Ocean's Heart (Solarus 1.6) and Zelda: Book of Mudora (2.0) both do, and `-quest-size`
// cannot negotiate a min == max quest down. Smaller quests are pillarboxed; see
// docs/superpowers/specs/2026-08-07-fb-416x240-widening-design.md.
`define FB_W          416
`define FB_H          240

`define FB_ROW_QW     (`FB_W / 4)           // qwords per scanline        (104)
`define FB_ROW_BYTES  (`FB_W * 2)           // bytes per scanline, RGB565 (832)
`define FB_QWORDS     (`FB_W * `FB_H / 4)   // whole framebuffer          (24960)

`endif
