/* VENDORED from github.com/gmcnaught/mister-fpga-blitter (host/blt_emitter.h) — do not edit here; edit upstream + re-copy. */
/*
 *  blt_emitter.h — engine-agnostic host-side blit display-list emitter.
 *
 *  Builds the per-frame command ring + manages the source-surface heap + drives
 *  the submit/done handshake, per docs/blitter-protocol.md. Develops and tests
 *  against the software reference model with NO hardware; the same emitter feeds
 *  the real fabric when the ring/heap buffers point at the DDR regions.
 *
 *  Reusable by any software engine (Solarus first, then gmloader / OpenBOR) —
 *  the engine binding only translates its draw calls into these calls.
 *
 *  Memory model (matches the contract):
 *    - The caller owns the ring buffer and the source heap (in DDR on hardware,
 *      plain malloc in tests). The emitter is a bump-builder over them.
 *    - Source uploads PERSIST across frames (bump-allocated): upload a static
 *      atlas once, keep its handle, re-blit it every frame for free. Call
 *      blt_heap_reset() to reclaim (e.g. on a quest/scene change).
 *    - Only the command list resets per frame (blt_begin_frame).
 *
 *  GPL-3.0.
 */
#ifndef BLT_EMITTER_H
#define BLT_EMITTER_H

#include "blitter_ref.h"   /* blt_cmd_t, BLT_OP_*, BLT_BLEND_*, BLT_F_*, BLT_FMT_* */
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint8_t *ring;       /* command ring (>= ring_cap bytes)           */
    size_t   ring_cap;
    uint8_t *heap;       /* source-surface heap                        */
    size_t   heap_cap;
    size_t   heap_used;  /* persists across frames (bump allocator)    */

    int      cmd_count;  /* commands emitted this frame (excl. END until end_frame) */
    int      overflow;   /* set if a ring/heap capacity was exceeded   */

    /* control-block mirror (the caller copies these to the DDR control block) */
    uint32_t submit_seq;
    int      target_buf;
    uint32_t flags;      /* bit0 = CLEAR-before-list                   */
    uint16_t clear_color;
} blt_emitter_t;

/* A handle to an uploaded source surface (an offset+geometry into the heap). */
typedef struct {
    uint32_t off;        /* byte offset into the heap (= cmd.src_off)  */
    uint16_t stride;     /* row stride in bytes                        */
    uint16_t w, h;       /* surface size in pixels                     */
    int      valid;
} blt_surface_ref_t;

/* Bind the emitter to caller-owned ring + heap buffers. */
void blt_emitter_init(blt_emitter_t *e, void *ring, size_t ring_cap,
                      void *heap, size_t heap_cap);

/* Reclaim all uploaded surfaces (invalidates every outstanding handle). */
void blt_heap_reset(blt_emitter_t *e);

/* Upload (copy) an RGB565 surface into the heap; returns a persistent handle.
 * `pitch` is the source row stride in bytes (use w*2 if packed). On overflow
 * returns a handle with .valid==0 and sets e->overflow. */
blt_surface_ref_t blt_upload(blt_emitter_t *e, const uint16_t *pixels,
                             int w, int h, int pitch);

/* Begin a frame: reset the command list, choose the target buffer, optionally
 * request a hardware clear to `clear_color` before the list runs. */
void blt_begin_frame(blt_emitter_t *e, int target_buf, int clear,
                     uint16_t clear_color);

/* Emit a solid-fill rect (dst clipped + culled by the fabric). */
int  blt_fill(blt_emitter_t *e, int x, int y, int w, int h, uint16_t color);

/* Emit a blit of a sub-rect of `s` to (dx,dy).
 *   blend : BLT_BLEND_COPY | BLT_BLEND_COLORKEY | BLT_BLEND_CONST_ALPHA
 *   flags : BLT_F_HFLIP | BLT_F_VFLIP | BLT_F_COLORKEY
 *   key   : RGB565 colorkey (when keyed); alpha : 0..255 (CONST_ALPHA) */
int  blt_blit(blt_emitter_t *e, blt_surface_ref_t s,
              int sx, int sy, int w, int h, int dx, int dy,
              uint8_t blend, uint16_t key, uint8_t alpha, uint8_t flags);

/* Convenience: blit the whole surface opaquely to (dx,dy). */
int  blt_blit_copy(blt_emitter_t *e, blt_surface_ref_t s, int dx, int dy);

/* Finish the frame: append END, latch cmd_count, bump submit_seq. After this
 * the caller publishes ring + control block to DDR and bumps the doorbell. */
void blt_end_frame(blt_emitter_t *e);

#ifdef __cplusplus
}
#endif
#endif /* BLT_EMITTER_H */
