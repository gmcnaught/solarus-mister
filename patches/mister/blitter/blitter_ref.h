/* VENDORED from github.com/gmcnaught/mister-fpga-blitter (refmodel/blitter_ref.h) — do not edit here; edit upstream + re-copy. */
/*
 *  blitter_ref.h — Software reference model for the MiSTer fabric 2D blitter.
 *
 *  This header IS the machine-readable host<->fabric contract for the
 *  command-driven blitter (fpga-hw-blitter task #002). The C reference model
 *  in blitter_ref.c executes a command list with EXACTLY the semantics the RTL
 *  must implement, so:
 *    - the host command emitter (#006) can be developed + unit-tested with no
 *      hardware, and
 *    - RTL output can be diffed bit-exact against this golden model (#003+),
 *      the gmloader-blitter verification pattern.
 *
 *  Pixel model (v1): 320x240 RGB565 framebuffer, matching the existing
 *  native_video_writer double-buffer + openbor_video_reader scanout. The
 *  blitter is a DROP-IN PRODUCER: it composites into a framebuffer exactly as
 *  the ARM's NativeVideoWriter_WriteFrame does today, then bumps the existing
 *  video control word. The scanout reader is unchanged.
 *
 *  Design lineage: command-list-walked-until-END (Saturn VDP1), per-command
 *  rect blit with colorkey skip-write fast path + optional const-alpha blend
 *  (CV1000). See ../docs/blitter-protocol.md and the epic research doc
 *  research-mister-blitters.md.
 *
 *  Copyright (C) 2026 — GPL-3.0 (matches solarus-mister/fpga).
 */
#ifndef BLITTER_REF_H
#define BLITTER_REF_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Fixed framebuffer geometry (v1) ------------------------------------ */
#define BLT_FB_WIDTH    320
#define BLT_FB_HEIGHT   240
#define BLT_FB_PIXELS   (BLT_FB_WIDTH * BLT_FB_HEIGHT)

/* ---- Opcodes (cmd.opcode) ----------------------------------------------- */
enum {
    BLT_OP_NOP   = 0,  /* do nothing, advance to next command                */
    BLT_OP_END   = 1,  /* terminate the command list (walk-until-END)        */
    BLT_OP_FILL  = 2,  /* solid-fill dst rect with cmd.color (RGB565)        */
    BLT_OP_BLIT  = 3,  /* copy/composite src rect -> dst per blend_mode      */
    BLT_OP_STAGE = 4,  /* copy source surface DDR3->SDRAM for fast reads.    *
                         * Field mapping (other fields unused / zero):        *
                         *   src_off          = byte offset in DDR heap (off) *
                         *   w  (low 16 bits) = size[15:0]                   *
                         *   h  (high 16 bits)= size[31:16]                  *
                         * Reconstruct: size = (uint32_t)w | ((uint32_t)h<<16)*
                         * Wire: u32[1]=src_off, u32[3]=w|h<<16              *
                         * The actual DDR->SDRAM copy FSM is issued by the   *
                         * fabric when it walks this command (future task).   */
    BLT_OP_TILELIST = 5, /* batch of N tiles from one shared texture+blend.       *
                          * Header (blt_cmd_t) carries shared params; the N        *
                          * per-tile rects live in a VRAM entry array.             *
                          * Field mapping (header):                                *
                          *   src_off/src_stride = shared tileset texture base     *
                          *   src_x/src_y        = signed bias_x/bias_y (map-coord *
                          *                        -> screen) ADDED to every entry *
                          *                        dst by the fabric; entry dsts   *
                          *                        are MAP coords (camera-indep)   *
                          *   blend_mode/format/flags/alpha/colorkey = shared      *
                          *   w | h<<16          = entry count N (u32)             *
                          *   dst_x | dst_y<<16  = entry-array byte offset         *
                          * Each entry is a blt_tile_entry_t (12 bytes).           */
    BLT_OP_TILELIST_RES = 6, /* [#52 resident / Tier B] pattern-indexed tile list.    *
                          * SAME header packing as BLT_OP_TILELIST, but each entry   *
                          * is a blt_tile_entry_res_t (8 bytes) carrying a           *
                          * pattern_id instead of a resolved src rect. The fabric    *
                          * resolves src = FRT[pattern_id][CFT[pattern_id]]:         *
                          *   FRT = per-pattern frame-rect table (uploaded once per  *
                          *         scene via BLT_OP_FRT_UPLOAD; mirrored to BRAM)   *
                          *   CFT = per-pattern current-frame table (the A9 writes   *
                          *         the mirror-resolved final_frame_index each frame)*
                          * so the A9 per-frame animated-tile cost -> ~0.            *
                          * [camera-independent] src_x/src_y header slots carry a    *
                          * signed bias_x/bias_y (map-coord -> screen) ADDED to every*
                          * entry's dst by the fabric; entry dst_x/dst_y are MAP     *
                          * coords, not screen coords (the direct BLT_OP_TILELIST    *
                          * uses these same header bias slots identically).          */
    BLT_OP_FRT_UPLOAD   = 7, /* [#52 resident / Tier B] stream the frame-rect table  *
                          * from DDR (FRT region) into the fabric's frt BRAM. Header: *
                          *   w | h<<16 = qword count to copy. No framebuffer effect. *
                          * (Software ref model: tables are plain memory -> no-op.)   */
    BLT_OP_BGPLANE_WRITE = 8, /* [Phase 3b] stream comp_fbram WORK buffer to SDRAM    *
                          * background plane at a given qword offset with stride.     *
                          * Field mapping (header-only):                              *
                          *   dst_x | dst_y<<16 = target SDRAM plane qword offset     *
                          *   src_x             = plane row stride in qwords          *
                          * The caller must have already painted the cell into WORK   *
                          * buffer before emitting this (e.g. via OP_TILELIST batch). */
    BLT_OP_CLUT_UPLOAD   = 9, /* [PAL8 v1] stream the WHOLE CLUT (all 8 banks) from a  *
                          * FIXED DDR region (CLUT_BUF_QW / OFF_CLUTBUF) into the      *
                          * fabric's CLUT BRAM. The FSM (blitter_top S_CLUT_RD/WR)     *
                          * reads ONLY the qword count; it does NOT consume src_off or *
                          * a per-upload bank id (the region + layout are fixed):      *
                          *   w | h<<16       = qword count (CLUT_BANKS*CLUT_ENTRIES,  *
                          *                     one 32b entry per 64b qword)           *
                          * No framebuffer effect. (Per-bank partial upload is a       *
                          * possible future optimization; v1 uploads the full table.) */
    BLT_OP_SPRITELIST = 10, /* [Stage 2] ordered camera-surface sprite batch.        *
                          * SAME header packing as BLT_OP_TILELIST:                  *
                          *   w | h<<16        = entry count N                       *
                          *   dst_x | dst_y<<16= entry-array byte offset (in the same*
                          *                      source heap, like BLT_OP_TILELIST)  *
                          *   src_x/src_y      = signed per-batch dst bias           *
                          *   src_stride/format/blend/alpha/colorkey/flags = shared  *
                          * Each entry is a 24-byte blt_sprite_entry_t carrying its   *
                          * OWN src_off — sprites do not share one texture the way    *
                          * a tileset layer does. Entries composite in array order,   *
                          * so Z-order == emission order.                             */
};

/* [#52 resident / Tier B] resident table dimensions (host + RTL MUST agree; mirrored
 * in fpga/rtl/blitter_defs.vh). MAXP patterns x MAXF frames. */
#define BLT_MAXP  128   /* max distinct animated patterns per scene */
#define BLT_MAXF  8     /* max frames per pattern (final_frame_index in [0,MAXF)) */

/* ---- Blend modes (cmd.blend_mode), for BLT_OP_BLIT ---------------------- */
enum {
    BLT_BLEND_COPY        = 0, /* opaque copy (fast path)                     */
    BLT_BLEND_COLORKEY    = 1, /* skip src pixels == cmd.colorkey (fast path) */
    BLT_BLEND_CONST_ALPHA = 2, /* dst = src*a + dst*(1-a), a=cmd.alpha/255    */
    /* COLORKEY + CONST_ALPHA combined: set flags BLT_F_COLORKEY on a
     * CONST_ALPHA blit to also skip keyed pixels. */
    BLT_BLEND_PALPHA      = 3, /* per-pixel source-over: src is ARGB4444,
                                * dst = src*a + dst*(1-a), a = src.A4 (per px).
                                * Source MUST be BLT_FMT_ARGB4444; A4==0 pixels
                                * are skip-write (leave dst). (v2)             */
    /* [v2 escape-elim] color-mod (BLT_F_COLORMOD) is applied to the source
     * BEFORE these blends, so it composes with all of them. ADD/MULTIPLY also
     * apply to BLT_OP_FILL (src channel = cmd.color channel). */
    BLT_BLEND_ADD         = 4, /* per-channel saturating add: out = min(src+dst, chan_max)
                                * at RGB565 widths (R/B max 31, G max 63).      */
    BLT_BLEND_MULTIPLY    = 5, /* per-channel modulate: out = round(src*dst / chan_max).
                                * Golden defines the exact (divide-free) reduction. */
};

/* ---- Source pixel formats (cmd.format) ---------------------------------- */
enum {
    BLT_FMT_RGB565   = 0, /* 16bpp, no per-pixel alpha                        */
    BLT_FMT_ARGB4444 = 1, /* 16bpp {A4,R4,G4,B4} (A in [15:12]); per-px alpha */
    BLT_FMT_PAL8     = 2, /* 8bpp palette-indexed; color field = pal_id[11:8]  *
                           * | base_off[7:0] (palette selection + CLUT offset)  */
};

/* ---- Flags (cmd.flags bitfield) ----------------------------------------- */
#define BLT_F_HFLIP     0x01u  /* mirror source horizontally                  */
#define BLT_F_VFLIP     0x02u  /* mirror source vertically                    */
#define BLT_F_COLORKEY  0x04u  /* honor colorkey even in a CONST_ALPHA blit   */
#define BLT_F_STAGE_DST 0x08u  /* [#32] STAGE: u32[2] ({src_x,src_stride}) carries the SDRAM dest offset */
#define BLT_F_SRC_SDRAM 0x10u  /* [#34] BLIT: read THIS source from SDRAM (per-command mux). C_SRCSEL is a
                                * frame-level master ENABLE; this per-command flag selects DDR3 vs SDRAM
                                * for each blit, so a frame may mix staged (SDRAM) + un-staged (DDR3) sources. */
#define BLT_F_SRC_FB    0x20u  /* BLIT: source is a framebuffer written by the compositor (ch0/P_DST), read
                                * here via ch5/P_SRC — the per-frame carry-forward FB->FB copy. The fabric
                                * fires the dst-barrier (commit ch0 + invalidate ch5) before this BLIT's
                                * source fetch so the two double-buffers stay coherent (no frame divergence). */
#define BLT_F_COLORMOD  0x40u  /* [v2 escape-elim] color-mod (tint) present: _pad[0..2] = {cr,cg,cb} (u8).
                                * The source pixel is modulated per-channel BEFORE the blend:
                                * src_ch' = round(src_ch * mod_ch / 255) at the dest channel width
                                * (divide-free /255, same reduction as blt_blend565). CLEAR => no mod
                                * (true no-op; v1 zero-pad stays correct). Host sets it only when
                                * (cr,cg,cb) != (255,255,255). Orthogonal to blend_mode (composes). */
#define BLT_F_BGCOV     0x80u  /* [ARGB4444 plane bake] dual meaning by opcode: on OP_FILL,
                                * clear the bake-coverage tracker (bgplane_coverage.sv) as
                                * this fill's own pixel-write loop runs, instead of setting
                                * coverage bits; on OP_BGPLANE_WRITE, pack the streamed plane
                                * as ARGB4444 (alpha=0xF covered/0x0 uncovered) using the
                                * tracker instead of raw RGB565. See fbram_to_sdram.sv. */

/*
 *  Blit command — 32 bytes / 8x uint32. Layout is the on-wire DDR ring entry;
 *  the struct mirrors it field-for-field so the host can write commands by
 *  assignment and the RTL can parse fixed bit ranges. All offsets/strides are
 *  BYTES into the source surface heap. dst_x/dst_y are SIGNED to allow
 *  partially/fully offscreen blits (fully-offscreen -> no memory traffic,
 *  CV1000-style cull).
 */
typedef struct {
    uint8_t  opcode;       /* BLT_OP_*                                        */
    uint8_t  blend_mode;   /* BLT_BLEND_*                                     */
    uint8_t  format;       /* BLT_FMT_*                                       */
    uint8_t  flags;        /* BLT_F_*                                         */

    uint32_t src_off;      /* byte offset of src surface in the source heap   */
    uint16_t src_stride;   /* src row stride in bytes                         */
    uint16_t src_x;        /* src rect origin x (pixels)                      */
    uint16_t src_y;        /* src rect origin y (pixels)                      */
    uint16_t w;            /* blit width  (pixels)                            */
    uint16_t h;            /* blit height (pixels)                            */

    int16_t  dst_x;        /* dst origin x (signed; may be < 0)               */
    int16_t  dst_y;        /* dst origin y (signed; may be < 0)               */

    uint16_t colorkey;     /* RGB565 transparent key (COLORKEY modes)         */
    uint16_t color;        /* RGB565 fill color (FILL)                        */
    uint8_t  alpha;        /* 0..255 constant alpha (CONST_ALPHA)             */
    uint8_t  _pad[3];      /* [v2] color-mod when BLT_F_COLORMOD: _pad[0]=cr,  *
                            * _pad[1]=cg, _pad[2]=cb (RGB888 modulation). Else *
                            * reserved (zero). Keeps the command at 32 bytes.  */
} blt_cmd_t;

/*
 *  BLT_OP_TILELIST per-tile entry (12 bytes, on-wire little-endian).
 */
typedef struct {
    uint16_t src_x, src_y;   /* tile sub-rect origin in the tileset   */
    uint16_t w, h;           /* tile size (pixels)                    */
    int16_t  dst_x, dst_y;   /* signed dst origin (offscreen-cullable)*/
} blt_tile_entry_t;

/*
 *  BLT_OP_TILELIST_RES per-tile entry (8 bytes, qword-aligned, on-wire LE).
 *  Carries a pattern_id (the fabric resolves the src rect from FRT[pid][CFT[pid]])
 *  + a FIXED dst (set once at scene build; never re-walked).
 *
 *  [camera-independent] dst_x/dst_y are MAP coords (scene-build-time, camera-
 *  independent). The header's src_x/src_y slots carry a signed per-batch
 *  bias_x/bias_y (map-coord -> screen); the fabric adds it to every entry's
 *  dst: screen_dst = entry.dst + header.bias. This keeps entries stable across
 *  camera movement -- only the header bias is re-emitted per frame.
 */
typedef struct {
    uint16_t pattern_id;     /* index into the FRT/CFT tables (0..BLT_MAXP-1)        */
    int16_t  dst_x, dst_y;   /* signed dst origin, MAP coords (offscreen-cullable    *
                              * only after bias is applied)                          */
    uint16_t _rsvd;          /* 0 (pads the entry to 8 bytes / one aligned qword)   */
} blt_tile_entry_res_t;

/*
 *  Frame-rect table entry (8 bytes / one qword): the src sub-rect for one
 *  (pattern_id, final_frame_index). FRT is FRT[pid*BLT_MAXF + frame].
 */
typedef struct {
    uint16_t src_x, src_y, w, h;
} blt_frame_rect_t;

/*
 *  Source surface heap. In hardware this is a DDR region the blitter's read
 *  master fetches from; in the model it is a plain host buffer. src_off in a
 *  command is a byte offset into base[0..size).
 */
typedef struct {
    const uint8_t *base;
    size_t         size;
    /* [#52 resident / Tier B] optional resident tables for BLT_OP_TILELIST_RES. In
     * hardware these are FIXED DDR regions mirrored to fabric BRAM; in the model they
     * are plain buffers. NULL (zero-initialized) for non-resident command lists.
     *   frt: blt_frame_rect_t[BLT_MAXP*BLT_MAXF] (8 B each), FRT[pid*BLT_MAXF+frame].
     *   cft: uint16_t[BLT_MAXP] current (mirror-resolved) frame index per pattern.    */
    const uint8_t *frt;
    const uint8_t *cft;
    /* [PAL8 / Task 4b] optional CLUT mirror for BLT_FMT_PAL8 sources:
     * BLT_CLUT_BANKS*BLT_CLUT_ENTRIES 32-bit little-endian words, addressed
     * [pal_id*BLT_CLUT_ENTRIES + ((index + base_off) & 0xFF)] — exactly
     * comp_pipeline.sv's clut_rd_addr = {c_pal_id[4:0], index[7:0]+c_base_off}.
     * Word layout mirrors comp_clut.vh's CLUT_MAKE: bits[15:0] = RGB565,
     * bits[19:16] = 4-bit alpha. NULL (zero-initialized) for non-paletted
     * command lists; a PAL8 command with no CLUT bound reads as colour 0. */
    const uint8_t *clut;
} blt_surface_heap_t;

/* [PAL8] CLUT geometry, mirroring fpga/rtl/comp_clut.vh (CLUT_BANKS/CLUT_ENTRIES).
 * pal_id is 5 bits (32 banks) and the slot index is 8 bits (256 entries). */
#define BLT_CLUT_BANKS   32u
#define BLT_CLUT_ENTRIES 256u

/*
 *  Execute a command list against a 320x240 RGB565 framebuffer.
 *    fb     : BLT_FB_PIXELS uint16 framebuffer (composited in place)
 *    heap   : source surface heap (may be NULL if list has no BLIT cmds)
 *    cmds   : command array; execution stops at BLT_OP_END or after `count`
 *    count  : max commands to consider (ring size guard)
 *  Returns the number of commands executed (incl. the END).
 *
 *  Out-of-heap source reads are clamped to 0 (model safety); the RTL must
 *  likewise never read outside the source region. Fully-offscreen rects are
 *  skipped with zero writes.
 */
int blt_execute(uint16_t *fb,
                const blt_surface_heap_t *heap,
                const blt_cmd_t *cmds,
                int count);

/* [Stage 2] Execute one BLT_OP_SPRITELIST batch: `n` 24-byte blt_sprite_entry_t
 * (see blt_wire.h) packed little-endian at heap->base + entry_off — SAME
 * convention as BLT_OP_TILELIST: the entry array lives in the same source heap
 * blt_execute was given, at the header's dst_x|dst_y<<16 byte offset. `header`
 * carries the shared params (src_stride/format/blend_mode/flags/alpha/colorkey)
 * exactly as the BLT_OP_SPRITELIST command word does; only src_off/src_x/src_y/
 * w/h/dst_x/dst_y/color are overridden per entry, each from its OWN src_off
 * (sprites, unlike tiles, do not share one texture) and its OWN palette word
 * (Y-sorted sprites come from sheets with different palettes; see [Task 4b] in
 * blt_wire.h) -- the header's own color field is NOT a fallback. bias_x/bias_y are the signed
 * per-batch dst bias (map-coord -> screen) ADDED to every entry's dst — same
 * convention as BLT_OP_TILELIST/BLT_OP_TILELIST_RES. Exposed (not static) so
 * both blt_execute's BLT_OP_SPRITELIST case and host tests can call it. */
void blt_ref_sprite_list(uint16_t *fb, const blt_surface_heap_t *heap,
                         const blt_cmd_t *header, uint32_t entry_off, int n,
                         int16_t bias_x, int16_t bias_y);

/* Convenience: RGB565 pack/blend helpers (also used by tests). */
uint16_t blt_rgb565(uint8_t r, uint8_t g, uint8_t b);
uint16_t blt_blend565(uint16_t src, uint16_t dst, uint8_t alpha);
/* Canonical channel blend: (s*a + d*(255-a) + 127)/255. Divide-free RTL form
 * (bit-exact, verified): (t + 128 + ((t+128)>>8)) >> 8, t = s*a + d*(255-a). */

/* [v2 escape-elim] C-reference goldens (bodies in blitter_ref.c — Workstream C).
 * Each MUST be bit-exact to its comp_pipeline RTL stage (gated in tb_*). */
/* color-mod: modulate src565 per channel by RGB888 (cr,cg,cb). Per dest-width
 * channel: out_ch = round(src_ch * mod_ch / 255), divide-free /255 reduction
 * matching blt_blend565. (255,255,255) is an exact identity. */
uint16_t blt_tint565(uint16_t src565, uint8_t cr, uint8_t cg, uint8_t cb);
/* saturating add: out_ch = min(src_ch + dst_ch, chan_max) (R/B max 31, G max 63). */
uint16_t blt_add565(uint16_t src565, uint16_t dst565);
/* multiply: out_ch = round(src_ch * dst_ch / chan_max). C owns the exact
 * divide-free reduction; RTL must match it bit-for-bit. */
uint16_t blt_mul565(uint16_t src565, uint16_t dst565);

/* Per-pixel source-over: src16 is ARGB4444 {A4,R4,G4,B4}, dst16 is RGB565.
 * Expand A4->A8 (a8={a4,a4}) and src R4/G4/B4 to the dest channel widths
 * (R4->5b {r4,r4[3]}, G4->6b {g4,g4[3:2]}, B4->5b {b4,b4[3]}), then run the SAME
 * divide-free /255 reduction as blt_blend565 with the per-pixel alpha. A4==0
 * returns dst16 unchanged (skip-write). Bit-exact to blend4444 in blitter_top.sv. */
static inline uint16_t blt_blend4444(uint16_t src16, uint16_t dst16) {
    unsigned a4=(src16>>12)&0xF, r4=(src16>>8)&0xF, g4=(src16>>4)&0xF, b4=src16&0xF;
    if (a4==0) return dst16;
    unsigned a8=(a4<<4)|a4, na=255u-a8;
    unsigned sr=(r4<<1)|(r4>>3);            /* R4 -> 5b {r4,r4[3]} */
    unsigned sg=(g4<<2)|(g4>>2);            /* G4 -> 6b {g4,g4[3:2]} */
    unsigned sb=(b4<<1)|(b4>>3);            /* B4 -> 5b {b4,b4[3]} */
    unsigned dr=(dst16>>11)&0x1F, dg=(dst16>>5)&0x3F, db=dst16&0x1F;
    unsigned tr=sr*a8+dr*na, orr=(tr+128+((tr+128)>>8))>>8;
    unsigned tg=sg*a8+dg*na, og=(tg+128+((tg+128)>>8))>>8;
    unsigned tb=sb*a8+db*na, ob=(tb+128+((tb+128)>>8))>>8;
    return (uint16_t)(((orr&0x1F)<<11)|((og&0x3F)<<5)|(ob&0x1F));
}

#ifdef __cplusplus
}
#endif
#endif /* BLITTER_REF_H */
