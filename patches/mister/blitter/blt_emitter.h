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
#include "blt_wire.h"      /* [Task 4] blt_sprite_entry_t / blt_pack_sprite_entry       */
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

    /* [residency] permanent immutable-atlas allocator over the SDRAM perm region.
     * Grow-only: blt_stage_surface_perm allocates; nothing ever frees it (whole-quest
     * assets are resident for the quest lifetime). Disjoint from sdram_alloc. */
    blt_alloc_t sdram_perm;
    int         perm_overflow;  /* set when the perm region is exhausted (loud-fatal upstream) */

    /* [#52] tile-list entry buffer (separate from ring + heap; caller-owned). */
    uint8_t *tl_buf;     /* tile-list entry buffer (VRAM region; malloc in tests) */
    size_t   tl_cap;     /* capacity in bytes                                     */
    size_t   tl_used;    /* bytes used this frame (reset in blt_begin_frame)      */

    /* [Task 3 / Stage 2] sprite-entry buffer -- its OWN region, deliberately NOT
     * tl_buf: the sprite channel shares no storage with the resident
     * tile-list machinery. Caller-owned (DDR region on hardware, malloc in tests). */
    uint8_t *sp_buf;     /* sprite-entry buffer (own region, NOT tl_buf)          */
    size_t   sp_cap;     /* capacity in bytes                                     */
    size_t   sp_used;    /* bytes used this frame (reset in blt_begin_frame)      */

    /* [Stage 3b / grid, Phase B1 Task 3] GRID_BUF region bookkeeping -- its OWN
     * DDR region (see mister_blitter_renderer.cpp OFF_GRIDBUF/GRID_BUF_BYTES),
     * shares no storage with tl_buf/sp_buf. Unlike tl_buf/sp_buf this is a
     * region-relative BYTE OFFSET, not a host pointer: grid_build.h writes cells
     * directly into the mapped GRID_BUF DDR region (or a caller-owned buffer in
     * host tests) and blt_grid_list's `cells_off` argument is already the byte
     * offset to pack into the header, so the emitter never dereferences these
     * fields itself -- they exist for bookkeeping/diagnostics, mirroring
     * tl_cap (also set-but-unread by the emitter; the value backstops future
     * bounds-checking and documents which region is bound). */
    uint32_t grid_buf_off; /* GRID_BUF region base, DDR-region-relative bytes    */
    uint32_t grid_cap;     /* GRID_BUF region capacity in bytes                  */
    size_t   grid_used;    /* bytes used this frame (reset in blt_begin_frame)   */

    int      cmd_count;  /* commands emitted this frame (excl. END until end_frame) */
    int      overflow;   /* set if a ring/heap capacity was exceeded   */
    uint32_t dropped;    /* commands lost to ring-full this frame (reset per frame).
                          * present() still submits, so this MUST be reported: a
                          * non-zero value means the frame is missing content. */
    uint32_t src_domain_fault; /* [#33/#34 src-domain] source-reading commands emitted
                          * this frame whose source resolved to the DDR3 heap while
                          * sdram_src mode is on (reset per frame, like `dropped`). The
                          * fabric hardwires SDRAM source, so such a command reads a DDR3
                          * offset out of SDRAM = garbage (the PR #142 shape). Good paths
                          * always stage their sources, so this is a tripwire that must
                          * stay 0; a non-zero value = a wrong-domain emit slipped through.
                          * Set on every source-emit path via the shared resolver:
                          * blt_cmd_apply_src for command emitters, and the renderer's
                          * per-entry sprite path (which uses blt_src_off directly). */

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

/* [#33/#34 src-domain] THE single source of truth for the SDRAM-vs-DDR3 source mux
 * that every source-PIXEL-reading emit path must use (blt_blit*, the tile-list and
 * grid headers, and the renderer's per-entry sprite path). Source atlases are staged
 * whole-quest into SDRAM (#66) and the fabric reads render source through the SDRAM
 * P_SRC path, so a resident (staged) ref must be read from ref.sdram_off; an unstaged
 * ref (or sdram_src mode off) falls back to the DDR3 heap ref.off. Pure/read-only:
 * returns the resolved byte offset and, via *use_sdram (may be NULL), whether the
 * caller must set BLT_F_SRC_SDRAM on the command/run-key. Centralizing this is the
 * structural guard against the PR #142 class (an emitter open-coding the wrong offset). */
uint32_t blt_src_off(const blt_emitter_t *e, blt_surface_ref_t ref, int *use_sdram);

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

/* Same as blt_fill, but with an explicit BLT_F_* flags byte.
 *
 * RETAINED (Stage 3b): this was originally added for the ARGB4444 plane bake
 * (BLT_F_BGCOV cleared the bake-coverage tracker — see bgplane_coverage.sv —
 * as this fill's pixel-write loop ran, instead of setting coverage bits).
 * The bake was deleted host-side in Stage 3b Phase A and BLT_F_BGCOV is now
 * RESERVED/unused (see blitter_ref.h), so this function is currently
 * callerless. It is kept deliberately as a generic emitter API (a plain
 * flags-parameterized fill is useful on its own) — do not delete it. */
int  blt_fill_flags(blt_emitter_t *e, int x, int y, int w, int h, uint16_t color,
                    uint8_t flags);

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

/* [PAL8 v1] Blit an 8bpp palette-indexed source (BLT_FMT_PAL8): identical to
 * blt_blit but the format is forced to BLT_FMT_PAL8 (not taken from s.format)
 * and `pal_id`/`base_off` are packed into the command's color field via
 * blt_pal_color (blt_wire.h) -- blt_blit has no color parameter, so PAL8's
 * palette-bank selection needs this dedicated emit path.
 *   pal_id   : CLUT bank (0..31, see PAL_CLUT_BANKS in palette_atlas.h)
 *   base_off : this surface's CLUT entries' starting slot within that bank */
int  blt_blit_pal8(blt_emitter_t *e, blt_surface_ref_t s,
                   int sx, int sy, int w, int h, int dx, int dy,
                   uint8_t blend, uint16_t key, uint8_t alpha, uint8_t flags,
                   uint8_t pal_id, uint8_t base_off);

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

/* [residency] Init BOTH SDRAM sub-allocators: perm (immutable, never freed) and
 * inter (recycled intermediates). Enables sdram_src. Supersedes blt_sdram_init. */
void blt_sdram_regions_init(blt_emitter_t *e, uint32_t perm_base, uint32_t perm_size,
                            uint32_t inter_base, uint32_t inter_size);

/* [MiSTer #33] Stage `r` into SDRAM. On first call (r->sdram_off == BLT_ALLOC_FAIL)
 * allocates a fresh SDRAM offset; on a re-stage (dirty re-upload) reuses the same
 * offset (idempotent — no leak). Emits blt_stage_to(r->off bounce -> r->sdram_off).
 * Returns 0, or -1 + e->overflow on SDRAM-full / ring-full. */
int  blt_stage_surface(blt_emitter_t *e, blt_surface_ref_t *r);

/* [residency] Stage `r` into the PERMANENT region (idempotent on re-stage). On perm
 * exhaustion sets e->perm_overflow and returns -1. Otherwise emits DDR3->SDRAM stage. */
int  blt_stage_surface_perm(blt_emitter_t *e, blt_surface_ref_t *r);

/* [MiSTer #33] Free a surface's SDRAM offset back to the allocator (on evict/dirty
 * dims change). No-op if unstaged. Mirrors blt_emitter_free for the DDR3 heap. */
void blt_sdram_free(blt_emitter_t *e, blt_surface_ref_t *r);

/* [#52] Bind the tile-list entry buffer (separate from the command ring + source heap). */
void blt_tile_list_init(blt_emitter_t *e, void *tl_buf, size_t tl_cap);

/* [#52 resident, Task 7] Emit a header-only BLT_OP_TILELIST_RES pointing at `entry_off`
 * (N 8-byte blt_tile_entry_res_t already resident in tl_buf). The fabric resolves each
 * entry's src from FRT[pattern_id][CFT[pattern_id]]. `bias_x`/`bias_y` are a signed
 * per-batch dst bias (map-coord -> screen) added to every entry's dst by the fabric;
 * carried in the header's src_x/src_y slots (informational texture-bounds fields for
 * this opcode, otherwise unused). Pass 0,0 for no bias. Same return contract as above. */
int blt_tile_list_res(blt_emitter_t *e, blt_surface_ref_t tex, uint8_t blend,
                      uint16_t key, uint8_t alpha, uint8_t flags,
                      uint32_t entry_off, int n, int16_t bias_x, int16_t bias_y,
                      uint16_t color);

/* [static tile-list] Emit a header-only BLT_OP_TILELIST pointing at `entry_off`
 * (N 12-byte blt_tile_entry_t already resident in tl_buf). bias_x/bias_y are a
 * signed per-batch dst bias (map-coord -> screen), carried in the header.
 * [PAL8] `color` carries the header colour field: for a BLT_FMT_PAL8 tex it is
 * blt_pal_color(pal_id, base_off) (the fabric latches c_color -> c_pal_id/c_base_off
 * for every entry); pass 0 for RGB565/ARGB4444 tilesets (colour field unused). */
int blt_tile_list_static(blt_emitter_t *e, blt_surface_ref_t tex, uint8_t blend,
                         uint16_t key, uint8_t alpha, uint8_t flags,
                         uint32_t entry_off, int n, int16_t bias_x, int16_t bias_y,
                         uint16_t color);

/* [#52 resident / Tier B] Emit BLT_OP_FRT_UPLOAD: tell the fabric to stream `qword_count`
 * qwords of the frame-rect table from the FRT DDR region into its frt BRAM (once/scene).
 * Returns 0, or -1 + e->overflow on ring full. */
int blt_frt_upload(blt_emitter_t *e, uint32_t qword_count);

/* [Task 3 / Stage 2] Bind the sprite-entry buffer (separate from the ring, the
 * source heap, and tl_buf -- its own DDR region, SP_BUF, see
 * mister_blitter_renderer.cpp OFF_SPBUF). */
void blt_sprite_list_init(blt_emitter_t *e, void *sp_buf, size_t sp_cap);

/* [Task 3 / Stage 2] Emit a header-only BLT_OP_SPRITELIST pointing at `entry_off`
 * (N BLT_SPRITE_ENTRY_BYTES-sized blt_sprite_entry_t already resident in sp_buf).
 * Each entry carries its own src_off (sprites, unlike tiles, don't share one
 * texture) AND its own palette word (see [Task 4b] in blt_wire.h); src_stride/
 * format/blend/key/alpha/flags are shared across the batch, so the caller must
 * start a new list when any of them changes. bias_x/bias_y are a signed
 * per-batch dst bias (map/world coord -> screen) added to every entry's dst by
 * the fabric -- same convention as blt_tile_list_static/blt_tile_list_res.
 * Returns 0, or -1 + e->overflow on ring full. */
int blt_sprite_list(blt_emitter_t *e, uint32_t src_stride, uint8_t format, uint8_t blend,
                    uint16_t key, uint8_t alpha, uint8_t flags,
                    uint32_t entry_off, int n, int16_t bias_x, int16_t bias_y);

/* [Task 4 / Stage 2] The header fields an OP_SPRITELIST batch SHARES. A change in
 * ANY of them must start a new list, because the fabric reads them once per command
 * and applies them to every entry in the batch. Lives here (pure C, no engine types)
 * so the renderer and the host test exercise the SAME comparator. */
/* [Task 4b] The palette is deliberately NOT here: it moved into the ENTRY, so a
 * sprite from a differently-paletted sheet must NOT break a run. `flags` stays --
 * BLT_F_SRC_SDRAM in particular is genuinely per-header (a staged and an un-staged
 * source cannot be read by one command). */
typedef struct {
    uint32_t src_stride;
    uint8_t  format;
    uint8_t  blend;
    uint8_t  alpha;
    uint16_t colorkey;
    uint8_t  flags;
} blt_sprite_run_key_t;

static inline int blt_sprite_run_key_differs(const blt_sprite_run_key_t *a,
                                             const blt_sprite_run_key_t *b)
{
    return a->src_stride != b->src_stride || a->format   != b->format
        || a->blend      != b->blend      || a->alpha    != b->alpha
        || a->colorkey   != b->colorkey   || a->flags    != b->flags;
}

/* [Task 4 / Stage 2] Maximum entries a channel can hold, and thus the size of the
 * parallel key array. SP_BUF (128 KiB / BLT_SPRITE_ENTRY_BYTES=24) could hold 5461
 * entries, but the channel is capped here so `keys` stays a fixed inline array (no
 * allocation on the render path); blt_sprite_channel_init clamps a larger requested
 * cap down to this. */
#define BLT_SPRITE_CHANNEL_MAX 4096

/* [Task 4 / Stage 2] Bounded ORDERED sprite accumulator. Entries are appended in
 * emission order and never reordered -- that ordering IS the Z-order argument.
 * Push returns 0 once the cap (or the byte capacity) is reached: the TAIL is
 * dropped so the earliest (lowest-Z) sprites always survive, which degrades by
 * losing the topmost sprites rather than by scrambling the scene. */
typedef struct {
    blt_emitter_t *e;      /* owns SP_BUF (sp_buf/sp_cap) AND its per-frame cursor  */
    int      cap;          /* max entries (<= BLT_SPRITE_CHANNEL_MAX) */
    int      count;        /* entries accepted into the CURRENT batch  */
    uint32_t dropped;      /* entries refused at the cap or the budget */
    blt_sprite_run_key_t keys[BLT_SPRITE_CHANNEL_MAX];
} blt_sprite_channel_t;

/* The channel does NOT take its own buffer: it writes into the emitter's SP_BUF
 * arena (bound by blt_sprite_list_init) and allocates from the emitter's per-frame
 * cursor `sp_used`. Two independent owners of one DDR region was the defect that
 * made every flush but the last read another list's entries. */
void blt_sprite_channel_init(blt_sprite_channel_t *ch, blt_emitter_t *e, int cap);
void blt_sprite_channel_reset(blt_sprite_channel_t *ch);
int  blt_sprite_channel_push(blt_sprite_channel_t *ch, const blt_sprite_run_key_t *k,
                             const blt_sprite_entry_t *e);   /* 1 = accepted, 0 = dropped */

/* [Task 4 / Stage 2] Emit the buffered batch as one BLT_OP_SPRITELIST per MAXIMAL
 * run of entries whose run keys are equal, then reset the batch. Runs are walked in
 * push order and the fabric executes the ring strictly in order, so the emitted
 * sequence paints exactly in the order the draws arrived -- that IS the Z-order
 * argument. Returns the number of OP_SPRITELIST commands emitted (0 if the batch
 * was empty). Lives in the library rather than the renderer so the host test
 * exercises the SAME flush the engine ships, not a re-implementation of it. */
int  blt_sprite_channel_flush(blt_sprite_channel_t *ch, int16_t bias_x, int16_t bias_y);

/* [PAL8 v1] Emit BLT_OP_CLUT_UPLOAD: tell the fabric to stream `qw_count` qwords
 * (== CLUT entries, one 32-bit CLUT_MAKE word per qword) from the CLUTBUF DDR
 * region into its clut BRAM (once/scene), mirroring blt_frt_upload's shape
 * exactly ({c_h,c_w} = count, no framebuffer effect). `clutbuf_off` is carried
 * in the command's src_off field for documentation/future use: the current
 * fabric FSM (blitter_top.sv S_CLUT_RD/S_CLUT_WR) reads a FIXED CLUT_BUF_QW
 * DDR region + a running index -- same fixed-region discipline as FRT_UPLOAD --
 * so this field is not yet consumed by hardware. Returns 0, or -1 + e->overflow
 * on ring full. */
int blt_emit_clut_upload(blt_emitter_t *e, uint32_t clutbuf_off, uint32_t qw_count);

/* [Stage 3b / grid, Phase B1 Task 3] Bind the GRID_BUF region (its own DDR
 * region -- see mister_blitter_renderer.cpp OFF_GRIDBUF/GRID_BUF_BYTES,
 * shares no storage with tl_buf/sp_buf). `buf_off` is the region-relative
 * byte offset of GRID_BUF's base (NOT a host pointer, unlike
 * blt_tile_list_init/blt_sprite_list_init) because grid cells are written
 * directly into that DDR region by the caller (grid_build.h + a memcpy/DMA
 * outside the emitter); the emitter only ever needs the offset to pack into
 * a BLT_OP_TILEMAP header via blt_grid_list's `cells_off` argument. */
void blt_grid_list_init(blt_emitter_t *e, uint32_t buf_off, uint32_t cap);

/* [Stage 3b / grid, Phase B1 Task 3] Emit a header-only BLT_OP_TILEMAP command
 * for a per-layer 8px cell GRID already resident at `cells_off` (a byte offset
 * into the GRID_BUF DDR region, NOT relative to the `buf_off` bound by
 * blt_grid_list_init -- see that offset's doc comment). REUSES the 32-byte
 * command header verbatim (blt_pack_cmd/blt_unpack_cmd are NOT touched), with
 * a field-mapping DELIBERATELY DIFFERENT from BLT_OP_TILELIST/_RES/SPRITELIST
 * -- read carefully, this is the field most likely to be misread:
 *   grid_w/grid_h : packed into the header as w | h<<16, but this is the grid
 *                   RECTANGLE'S DIMENSIONS IN 8px CELLS (row-major, EVERY cell
 *                   present per grid_cell.h's encoding -- including empty
 *                   ones), NOT pixels and NOT an entry count the way
 *                   BLT_OP_TILELIST/_RES/SPRITELIST use w|h<<16.
 *   cells_off     : packed into dst_x | dst_y<<16, the byte offset of the
 *                   cell array (grid_w * grid_h * 4 bytes, blt_grid_cell_t)
 *                   within the GRID_BUF DDR region.
 *   bias_x/bias_y : signed per-batch dst bias (map-coord -> screen, typically
 *                   -camera), carried in src_x/src_y -- SAME convention as
 *                   BLT_OP_TILELIST/_RES/SPRITELIST's header bias slots.
 *   tex           : shared tileset texture (src_off/src_stride/format).
 *   pal_color     : header colour field (PAL8 pal_id/base_off via
 *                   blt_pal_color, or 0 for RGB565/ARGB4444 tilesets), same
 *                   role as blt_tile_list_static/res's `color` parameter.
 * Returns 0 on success, -1 + e->overflow on ring-full, or 1 (not an error) if
 * grid_w or grid_h is 0 -- nothing to draw. */
int blt_grid_list(blt_emitter_t *e, blt_surface_ref_t tex, uint8_t blend,
                  uint16_t colorkey, uint8_t alpha, uint8_t flags,
                  uint32_t cells_off, uint16_t grid_w, uint16_t grid_h,
                  int16_t bias_x, int16_t bias_y, uint16_t pal_color);

#ifdef __cplusplus
}
#endif
#endif /* BLT_EMITTER_H */
