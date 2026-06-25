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
};

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
};

/* ---- Source pixel formats (cmd.format) ---------------------------------- */
enum {
    BLT_FMT_RGB565   = 0, /* 16bpp, no per-pixel alpha                        */
    BLT_FMT_ARGB4444 = 1, /* 16bpp {A4,R4,G4,B4} (A in [15:12]); per-px alpha */
    /* BLT_FMT_ARGB8888 = 2  -> future                                        */
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
    uint8_t  _pad[3];      /* reserved -> 32 bytes; future tint/zoom          */
} blt_cmd_t;

/*
 *  Source surface heap. In hardware this is a DDR region the blitter's read
 *  master fetches from; in the model it is a plain host buffer. src_off in a
 *  command is a byte offset into base[0..size).
 */
typedef struct {
    const uint8_t *base;
    size_t         size;
} blt_surface_heap_t;

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

/* Convenience: RGB565 pack/blend helpers (also used by tests). */
uint16_t blt_rgb565(uint8_t r, uint8_t g, uint8_t b);
uint16_t blt_blend565(uint16_t src, uint16_t dst, uint8_t alpha);
/* Canonical channel blend: (s*a + d*(255-a) + 127)/255. Divide-free RTL form
 * (bit-exact, verified): (t + 128 + ((t+128)>>8)) >> 8, t = s*a + d*(255-a). */

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
