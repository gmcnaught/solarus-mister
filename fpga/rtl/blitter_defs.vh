// blitter_defs.vh — REAL hardware DDR addresses for blitter_top in the Solarus
// core (qword = phys>>3). The framebuffers + video control word stay in the proven
// 1 MiB f2h region at 0x3A000000 (the blitter is a drop-in producer on the existing
// scanout buffers). The blitter COMMAND region (ctrl/ring + source-surface heap) now
// lives in a dedicated 4 MiB region at 0x3B000000 so a full SCENE TRANSITION's
// working set (two scenes co-resident, ~1 MiB) fits without overflow — the 1 MiB
// region's pre-audio gap only afforded a 352 KiB heap, too small for heavy scenes.
// 0x3B000000..0x3B400000 was HW-verified reserved-safe (64/64 pattern words survive
// Linux + engine + video/audio activity).
//
// Layout (v3 — big heap):
//   BLTCTRL 0x3B000000 | RING 0x3B000040 | SRC heap 0x3B008000 | end 0x3B400000
//   heap = 0x3B400000 - 0x3B008000 = 0x3F8000 = ~4.06 MiB (was 352 KiB).
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
`define BLTCTRL_QW  29'h07600000          // 0x3B000000 (blitter control block)
`define RING_QW     29'h07600008          // 0x3B000040 (command ring)
`define SRC_QW      29'h07601000          // 0x3B008000 (source-surface heap, ~16 MiB)
`define MEM_QW      29'h07800000          // 0x3C000000 (region end; sim guard only —
                                          // engine heap grown to 16 MiB, issue #14)
// Off-screen BG-CACHE compose target (issue #18 anti-flicker): C_TARGET==2 routes the
// blit destination here instead of a framebuffer, and the fabric does NOT flip the
// display for that pass — so the static-bg cache is composed OFF-SCREEN (invisible),
// and every DISPLAYED frame stays a consistent full frame (cache->fb + dynamic),
// never a static-only snapshot. 0x3BF00000 = near the top of the 16 MiB region, clear
// of the bump heap (grows from 0x3B008000). Also the SRC for the cache->fb blit.
`define CACHE_QW    29'h077E0000          // 0x3BF00000 (off-screen bg-cache, 320x240)

// control-block field offsets (qwords from BLTCTRL_QW), low 32 bits used
`define C_SUBMIT    29'd0
`define C_CMDCOUNT  29'd1
`define C_TARGET    29'd2
`define C_CLEAR     29'd3
`define C_FLAGS     29'd4
`define C_DONE      29'd5
`define C_STATUS    29'd6
// Source-read path select (issue #19). bit0=1 -> route blitter SOURCE pixel reads
// through the SDRAM line controller (sdram_src_arb -> sdram_psx); 0 (DEFAULT) ->
// the proven DDR3 readcache path. Only the source read moves; control-word reads,
// the command ring, blend dst-RMW reads, ALL writes and scanout stay on DDR3.
// NOTE: 7 is the next free offset (C_STATUS=6 is the last existing field). This is
// a NEW field appended past C_STATUS — it does NOT alias any shipping control word,
// and the host writes it 0 by default so the DDR3 path is unchanged when unset.
`define C_SRCSEL    29'd7

`endif
