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
#include "blt_alloc.h"     /* [MiSTer #14] free-list heap allocator (replaces the bump) */
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
    size_t   heap_used;  /* bytes outstanding (= blt_alloc_used); diag */
    /* [MiSTer #14] free-list allocator over the heap (offsets 0..heap_cap). Replaces
     * the old bump pointer so individual uploads can be freed on invalidate/dirty
     * (the bump leaked -> transition overflow). Edit upstreamed to mister-fpga-blitter. */
    blt_alloc_t alloc;

    /* [MiSTer #33] SDRAM-VRAM: a SECOND offset allocator over the SDRAM space, used
     * only in sdram_src mode. Decoupled from the DDR3 heap `alloc` so the whole-quest
     * atlas (> 16MB DDR3 heap) can be resident in 64MB SDRAM. Inert until blt_sdram_init. */
    blt_alloc_t sdram_alloc;
    int         sdram_src;   /* 1 = blits read sources from staged SDRAM offsets (C_SRCSEL=1) */

    /* [#52] tile-list entry buffer (separate from ring + heap; caller-owned). */
    uint8_t *tl_buf;     /* tile-list entry buffer (VRAM region; malloc in tests) */
    size_t   tl_cap;     /* capacity in bytes                                     */
    size_t   tl_used;    /* bytes used this frame (reset in blt_begin_frame)      */

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
    uint8_t  format;     /* BLT_FMT_* of the uploaded pixels           */
    int      valid;
    uint32_t size;       /* [MiSTer #14] heap bytes allocated (pass to blt_emitter_free) */
    uint32_t sdram_off;  /* [MiSTer #33] SDRAM offset of this surface, or BLT_ALLOC_FAIL if unstaged */
} blt_surface_ref_t;

/* Bind the emitter to caller-owned ring + heap buffers. */
void blt_emitter_init(blt_emitter_t *e, void *ring, size_t ring_cap,
                      void *heap, size_t heap_cap);

/* Reclaim all uploaded surfaces (invalidates every outstanding handle). */
void blt_heap_reset(blt_emitter_t *e);

/* [MiSTer #14] Free a single uploaded surface's heap block (from invalidate/dirty),
 * so its bytes are reused without a full blt_heap_reset. Pass the ref's off + size. */
void blt_emitter_free(blt_emitter_t *e, uint32_t off, uint32_t size);

/* Upload (copy) an RGB565 surface into the heap; returns a persistent handle.
 * `pitch` is the source row stride in bytes (use w*2 if packed). On overflow
 * returns a handle with .valid==0 and sets e->overflow. */
blt_surface_ref_t blt_upload(blt_emitter_t *e, const uint16_t *pixels,
                             int w, int h, int pitch);

/* Upload (copy) an ARGB4444 ({A4,R4,G4,B4}) surface into the heap, for per-pixel
 * alpha (BLT_BLEND_PALPHA) blits. Same 16bpp packing/addressing as blt_upload;
 * the returned handle carries BLT_FMT_ARGB4444 so blt_blit tags the command. */
blt_surface_ref_t blt_upload_argb4444(blt_emitter_t *e, const uint16_t *pixels,
                                      int w, int h, int pitch);

/* Begin a frame: reset the command list, choose the target buffer, optionally
 * request a hardware clear to `clear_color` before the list runs. */
void blt_begin_frame(blt_emitter_t *e, int target_buf, int clear,
                     uint16_t clear_color);

/* Emit a solid-fill rect (dst clipped + culled by the fabric). */
int  blt_fill(blt_emitter_t *e, int x, int y, int w, int h, uint16_t color);

/* Emit a blit of a sub-rect of `s` to (dx,dy). The command's source format is
 * taken from the surface handle (`s.format`).
 *   blend : BLT_BLEND_COPY | COLORKEY | CONST_ALPHA | PALPHA(ARGB4444 src)
 *            | BLT_BLEND_ADD | BLT_BLEND_MULTIPLY
 *   flags : BLT_F_HFLIP | BLT_F_VFLIP | BLT_F_COLORKEY
 *   key   : RGB565 colorkey (when keyed); alpha : 0..255 (CONST_ALPHA) */
int  blt_blit(blt_emitter_t *e, blt_surface_ref_t s,
              int sx, int sy, int w, int h, int dx, int dy,
              uint8_t blend, uint16_t key, uint8_t alpha, uint8_t flags);

/* [v2] Color-modulated blit: like blt_blit but also packs (cr,cg,cb) into the
 * command's _pad[0..2] bytes and ALWAYS sets BLT_F_COLORMOD.  Source pixels are
 * modulated per-channel by (ch * mod_ch)/255 before the blend stage.
 * The existing blt_blit is unchanged: flag clear, _pad zeroed. */
int  blt_blit_mod(blt_emitter_t *e, blt_surface_ref_t s,
                  int sx, int sy, int w, int h, int dx, int dy,
                  uint8_t blend, uint16_t key, uint8_t alpha, uint8_t flags,
                  uint8_t cr, uint8_t cg, uint8_t cb);

/* Convenience: blit the whole surface opaquely to (dx,dy). */
int  blt_blit_copy(blt_emitter_t *e, blt_surface_ref_t s, int dx, int dy);

/* [v2] Fill with an explicit blend_mode (BLT_BLEND_ADD or BLT_BLEND_MULTIPLY).
 * Emits BLT_OP_FILL with blend_mode set; existing blt_fill always emits
 * blend_mode=COPY (unchanged). */
int  blt_fill_blend(blt_emitter_t *e, int x, int y, int w, int h,
                    uint16_t color, uint8_t blend_mode);

/* [const-alpha fill] Fill a rect blended into the FB by a constant alpha:
 * out = src*a + dst*(1-a), src channel = `color`, a = alpha/255. Emits
 * BLT_OP_FILL with blend_mode=CONST_ALPHA. Used by the colored-fade overlay
 * (Surface::fill_with_color with a translucent colour) so the fade composites
 * gradually instead of writing opaque colour (the "extra black frames" fix). */
int  blt_fill_alpha(blt_emitter_t *e, int x, int y, int w, int h,
                    uint16_t color, uint8_t alpha);

/* Finish the frame: append END, latch cmd_count, bump submit_seq. After this
 * the caller publishes ring + control block to DDR and bumps the doorbell. */
void blt_end_frame(blt_emitter_t *e);

/* [MiSTer #19] Emit a STAGE command that tells the fabric to copy a source
 * surface from DDR3 into SDRAM (fast-read backing) before subsequent BLITs.
 *   off  : byte offset of the surface in the DDR source heap (-> cmd.src_off)
 *   size : byte length to copy; packed as cmd.w (low 16) | cmd.h (high 16),
 *          so the full 32-bit size round-trips through the existing wire layout
 *          (u32[3] = w | h<<16). All other cmd fields are zero for STAGE.
 * Returns 0 on success, -1 and sets e->overflow if the ring is full. */
int blt_stage(blt_emitter_t *e, uint32_t off, uint32_t size);

/* [MiSTer #32] STAGE with a SDRAM destination offset DECOUPLED from the DDR3
 * read offset (for the whole-quest atlas, larger than the 16MB DDR3 heap).
 *   ddr_off   : DDR3 source/bounce byte offset (-> cmd.src_off, read at SRC_QW+off)
 *   sdram_off : SDRAM dest byte offset (-> u32[2] = {cmd.src_x, cmd.src_stride})
 *   size      : byte length, packed cmd.w | cmd.h<<16 (like blt_stage)
 * Sets BLT_F_STAGE_DST so the fabric uses sdram_off as the write base. Returns
 * 0 / -1+overflow like blt_stage. (blt_stage == flag-off, dest==ddr_off, #19.) */
int blt_stage_to(blt_emitter_t *e, uint32_t ddr_off, uint32_t sdram_off, uint32_t size);

/* [MiSTer #33] Enable SDRAM-VRAM mode: init the SDRAM offset allocator over
 * [base, base+size) and route blit source reads to staged SDRAM offsets
 * (C_SRCSEL=1). `base` lets the caller reserve a low region (e.g. the fixed
 * bg-cache SDRAM offset) so dynamic atlas offsets never collide with it. */
void blt_sdram_init(blt_emitter_t *e, uint32_t base, uint32_t size);

/* [MiSTer #33] Stage `r` into SDRAM. On first call (r->sdram_off == BLT_ALLOC_FAIL)
 * allocates a fresh SDRAM offset; on a re-stage (dirty re-upload) reuses the same
 * offset (idempotent — no leak). Emits blt_stage_to(r->off bounce -> r->sdram_off).
 * Returns 0, or -1 + e->overflow on SDRAM-full / ring-full. */
int  blt_stage_surface(blt_emitter_t *e, blt_surface_ref_t *r);

/* [MiSTer #33] Free a surface's SDRAM offset back to the allocator (on evict/dirty
 * dims change). No-op if unstaged. Mirrors blt_emitter_free for the DDR3 heap. */
void blt_sdram_free(blt_emitter_t *e, blt_surface_ref_t *r);

/* [#52] Bind the tile-list entry buffer (separate from the command ring + source heap). */
void blt_tile_list_init(blt_emitter_t *e, void *tl_buf, size_t tl_cap);

/* [#52] Emit one BLT_OP_TILELIST: writes the N entries into tl_buf and a header command
 * into the ring. `tex` supplies the shared src_off/src_stride/format (SDRAM vs DDR3
 * mux applied like blt_blit). Returns 0, or -1 + e->overflow on ring/tl_buf full. */
int blt_tile_list(blt_emitter_t *e, blt_surface_ref_t tex, uint8_t blend,
                  uint16_t key, uint8_t alpha, uint8_t flags,
                  const blt_tile_entry_t *ents, int n);

/* [#52 resident] Emit a HEADER-ONLY BLT_OP_TILELIST pointing at `entry_off` (a byte
 * offset into tl_buf where N 12-byte blt_tile_entry_t already live). Used by the
 * resident tile list (Tier A): entries are written ONCE at scene build + patched in
 * place; this re-emits the header each frame without re-copying entries. Does NOT
 * touch tl_used. Returns 0, or -1 + e->overflow on ring full / invalid tex. */
int blt_tile_list_at(blt_emitter_t *e, blt_surface_ref_t tex, uint8_t blend,
                     uint16_t key, uint8_t alpha, uint8_t flags,
                     uint32_t entry_off, int n);

/* [#52 resident / Tier B] Emit a header-only BLT_OP_TILELIST_RES pointing at `entry_off`
 * (N 8-byte blt_tile_entry_res_t already resident in tl_buf). The fabric resolves each
 * entry's src from FRT[pattern_id][CFT[pattern_id]]. `bias_x`/`bias_y` are a signed
 * per-batch dst bias (map-coord -> screen) added to every entry's dst by the fabric;
 * carried in the header's src_x/src_y slots (informational texture-bounds fields for
 * this opcode, otherwise unused). Pass 0,0 for no bias. Same return contract as above. */
int blt_tile_list_res(blt_emitter_t *e, blt_surface_ref_t tex, uint8_t blend,
                      uint16_t key, uint8_t alpha, uint8_t flags,
                      uint32_t entry_off, int n, int16_t bias_x, int16_t bias_y);

/* [#52 resident / Tier B] Emit BLT_OP_FRT_UPLOAD: tell the fabric to stream `qword_count`
 * qwords of the frame-rect table from the FRT DDR region into its frt BRAM (once/scene).
 * Returns 0, or -1 + e->overflow on ring full. */
int blt_frt_upload(blt_emitter_t *e, uint32_t qword_count);

#ifdef __cplusplus
}
#endif
#endif /* BLT_EMITTER_H */
