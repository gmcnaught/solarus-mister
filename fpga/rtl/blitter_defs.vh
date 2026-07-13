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
// Layout (v4 — [#52] big command ring):
//   BLTCTRL 0x3B000000 | RING 0x3B000040..0x3B080000 (512 KiB, ~16382 cmds) |
//   SRC heap 0x3B080000 | bg-cache 0x3BF00000 | end 0x3C000000
//   Ring grown from 32 KiB (1022 cmds) — 8x8-tile heavy areas emit >1022 cmds/frame.
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
`define RING_QW     29'h07600008          // 0x3B000040 (command ring; [#52] spans to 0x3B080000)
`define SRC_QW      29'h07610000          // 0x3B080000 ([#52] heap base moved up 480 KiB to grow the
                                          // command ring 32 KiB->512 KiB: 8x8-tile heavy areas emit
                                          // >1022 cmds/frame and overflowed the old ring -> black.
                                          // MUST MATCH host OFF_HEAP=0x80000 in mister_blitter_renderer.cpp)
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
// Pipelined-compositor select (Spec A). Routes FILL/BLIT execution through
// comp_pipeline (per-blit, band-chunked RMW datapath) when set; 0 (DEFAULT) ->
// the legacy per-pixel FSM.
//
// IMPORTANT (memory-map correction): the command RING begins at RING_QW =
// BLTCTRL_QW + 8 (0x3B000040), so control-block qword offset 8 ALIASES the first
// ring command word — `C_PIPE = 29'd8` would read cmd0's opcode (bit0=1 for any
// BLIT) and spuriously force the pipe path on. The last free control-block qword
// before the ring is C_SRCSEL (offset 7). C_PIPE is therefore carried in a SPARE
// BIT of the C_SRCSEL control word: bit0 is srcsel, bits[15:8] are the throttle,
// and BIT 1 is the pipe-select. C_PIPE names that word; pipe_en = word[1].
`define C_PIPE      29'd7        // same word as C_SRCSEL; pipe_en = word bit 1
`define C_PIPE_BIT  1            // bit within the C_PIPE word that enables the pipe

// ── [v2 escape-elim] command-ABI mirror (values FROZEN in blitter_ref.h) ────────
// blend_mode (cmd byte 1) extends past PALPHA=3; F_COLORMOD is the next free flag.
// blitter_top.sv / comp_pipeline.sv keep these as module localparams (decode style);
// these `defines exist so the ABI values live in one shared header too.
`define BLT_BLEND_COPY        8'd0
`define BLT_BLEND_COLORKEY    8'd1
`define BLT_BLEND_CONST_ALPHA 8'd2
`define BLT_BLEND_PALPHA      8'd3
`define BLT_BLEND_ADD         8'd4   // saturating add: out = min(src+dst, chan_max)
`define BLT_BLEND_MULTIPLY    8'd5   // multiply:       out = round(src*dst / chan_max)
`define BLT_F_COLORMOD        8'h40  // _pad bytes carry RGB888 src tint (cr,cg,cb)
// ── [PAL8 v1] source-format constants (mirror blitter_ref.h) ─────────────────────
`define BLT_FMT_RGB565        8'd0
`define BLT_FMT_ARGB4444      8'd1
`define BLT_FMT_PAL8          8'd2   // 8bpp palette-indexed; CLUT lookup by pal_id
// Wire layout of the tint triple in command qword[3] (host pack / RTL decode / C
// model MUST agree): u32[6]=colorkey|alpha<<16|cb<<24, u32[7]=color|cr<<16|cg<<24.

// ── Command opcodes extension (OP_NOP..OP_STAGE live in blitter_top.sv) ────────
// OP_TILELIST and TL_BUF_BYTES are new and not declared elsewhere.
localparam [7:0] OP_TILELIST = 8'd5;   // BLT_OP_TILELIST: N-tile batch
// Tile-list VRAM buffer. The fabric (blitter_top OP_TILELIST FSM) reads N 12-byte
// {src_x,src_y,w,h,dst_x,dst_y} entries from here via the FSM bm_* master (DDR3);
// the host writes them to the SAME physical region. 512 KiB (Task 4: enlarged from
// 64 KiB so the resident list can hold a whole map's animated tiles in a later task).
localparam [31:0] TL_BUF_BYTES = 32'h0008_0000;   // 512 KiB
// ── TL_BUF byte base = 0x3BF40000 ; host OFF_TLBUF MUST match ────────────────
// Placed ABOVE the off-screen bg-cache (CACHE_QW=0x3BF00000, 320x240x2=0x25800,
// ends 0x3BF25800) and BELOW the region end (MEM_QW=0x3C000000). This is in the
// same "top of the 16 MiB blitter region" zone the bg-cache already occupies,
// which the map reserves CLEAR OF THE BUMP HEAP (heap base 0x3B080000 grows up,
// ceiling at CACHE_QW). So 0x3BF40000..0x3BFC0000 collides with NONE of: BLTCTRL,
// the 512 KiB command ring, the source heap, or the bg-cache. Single buffer: the
// submit/done handshake already serializes host writes vs fabric reads (same as
// the command ring, which is likewise single-buffered).
//   0x3BF40000 >> 3 = 0x077E8000 (qword)
`define TL_BUF_QW   29'h077E8000          // 0x3BF40000 (tile-list entry buffer base)

// ── [#52 resident / Tier B] pattern-indexed tile list (BLT_OP_TILELIST_RES) ──────
// Resident entries are 8-byte blt_tile_entry_res_t {u16 pattern_id; i16 dst_x,dst_y;
// u16 _rsvd} living in the SAME TL_BUF region (one aligned qword each). The fabric
// resolves src = FRT[pattern_id][CFT[pattern_id]] from two resident tables, both placed
// ABOVE TL_BUF (which ends at 0x3BFC0000 after Task 4's 512 KiB enlargement) and below
// the region end (0x3C000000):
//   FRT (frame-rect table)  @ 0x3BFC0000 : MAXP*MAXF qwords (8 KiB), uploaded once per
//        scene via BLT_OP_FRT_UPLOAD into frt_bram. Entry = {h,w,src_y,src_x} (LE).
//   CFT (current-frame tbl) @ 0x3BFC2000 : MAXP u16 (256 B), the A9 writes the
//        mirror-resolved final_frame_index each frame; preloaded into cft_bram at the
//        start of each TILELIST_RES command.
// MUST MATCH host BLT_MAXP/BLT_MAXF (blitter_ref.h) + OFF_FRTBUF/OFF_CFTBUF
// (mister_blitter_renderer.cpp).
localparam [7:0]  OP_TILELIST_RES = 8'd6;
localparam [7:0]  OP_FRT_UPLOAD   = 8'd7;
localparam integer MAXP = 128;            // max distinct animated patterns
localparam integer MAXF = 8;             // max frames per pattern (final idx in [0,MAXF))
//   0x3BFC0000 >> 3 = 0x077F8000 ; 0x3BFC2000 >> 3 = 0x077F8400
`define FRT_BUF_QW  29'h077F8000          // 0x3BFC0000 (frame-rect table base)
`define CFT_BUF_QW  29'h077F8400          // 0x3BFC2000 (current-frame table base)

// ── [Phase 3b] one-time WORK->SDRAM background-plane bake (fbram_to_sdram) ──────
// dst_x|dst_y<<16 (same field-reuse idiom as OP_TILELIST/OP_TILELIST_RES's header
// dst fields) = the cell's ABSOLUTE destination SDRAM qword offset (Task 1's
// bgplane_cell_plane_byte_offset(...)/8, host-side). src_x = this map's plane row
// stride in qwords (dst_stride_qw). No src/bias semantics otherwise.
localparam [7:0]  OP_BGPLANE_WRITE = 8'd8;

// ── [PAL8 v1] palette lookup table (CLUT) upload ──────────────────────────────────
// Stream a palette lookup table from DDR into the fabric's CLUT BRAM. Field mapping:
//   src_off = byte offset in DDR heap (CLUT base)
//   pal_id (u8, format field place) = palette bank ID (0..31, 5-bit; see comp_clut.vh)
//   w | h<<16 = qword count (max 256 entries / 32 qwords per palette)
// No framebuffer effect; tables are plain memory in the software reference model.
localparam [7:0]  OP_CLUT_UPLOAD   = 8'd9;
`define BLT_OP_CLUT_UPLOAD 8'd9

// ── [PAL8 v1] CLUT upload DMA source region ────────────────────────────────────
// Mirrors FRT_BUF_QW: CLUT_BANKS*CLUT_ENTRIES entries (8*256=2048), ONE 32-bit
// entry packed per 64-bit qword (high 32 bits unused/zero on the wire) -> 2048
// qwords = 16 KiB total. Placed just above CFT_BUF_QW (CFT ends at 0x3BFC2000 +
// (MAXP/4)*8 = 0x3BFC2100) with a small gap for headroom, still well below the
// region end (MEM_QW=0x3C000000). MUST match the host CLUTBUF constant
// (mister_blitter_renderer.cpp) and comp_clut.vh's CLUT_BANKS/CLUT_ENTRIES.
//   0x3BFC3000 >> 3 = 0x077F8600
`define CLUT_BUF_QW 29'h077F8600          // 0x3BFC3000 (CLUT upload DMA source base)

`endif
