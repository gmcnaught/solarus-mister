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
};

/* ---- Blend modes (cmd.blend_mode), for BLT_OP_BLIT ---------------------- */
enum {
    BLT_BLEND_COPY        = 0, /* opaque copy (fast path)                     */
    BLT_BLEND_COLORKEY    = 1, /* skip src pixels == cmd.colorkey (fast path) */
    BLT_BLEND_CONST_ALPHA = 2, /* dst = src*a + dst*(1-a), a=cmd.alpha/255    */
    /* COLORKEY + CONST_ALPHA combined: set flags BLT_F_COLORKEY on a
     * CONST_ALPHA blit to also skip keyed pixels. */
};

/* ---- Source pixel formats (cmd.format) ---------------------------------- */
enum {
    BLT_FMT_RGB565 = 0, /* v1: 16bpp, no per-pixel alpha                      */
    /* BLT_FMT_ARGB1555 = 1, BLT_FMT_ARGB8888 = 2  -> future per-pixel alpha  */
};

/* ---- Flags (cmd.flags bitfield) ----------------------------------------- */
#define BLT_F_HFLIP     0x01u  /* mirror source horizontally                  */
#define BLT_F_VFLIP     0x02u  /* mirror source vertically                    */
#define BLT_F_COLORKEY  0x04u  /* honor colorkey even in a CONST_ALPHA blit   */

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

#ifdef __cplusplus
}
#endif
#endif /* BLITTER_REF_H */
