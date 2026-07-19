/* VENDORED from github.com/gmcnaught/mister-fpga-blitter (host/blt_emitter.c) — do not edit here; edit upstream + re-copy. */
/*
 *  blt_emitter.c — engine-agnostic blit display-list emitter. See blt_emitter.h.
 *  GPL-3.0.
 */
#include "blt_emitter.h"
#include "blt_wire.h"
#include <string.h>

void blt_emitter_init(blt_emitter_t *e, void *ring, size_t ring_cap,
                      void *heap, size_t heap_cap)
{
    memset(e, 0, sizeof(*e));
    e->ring = (uint8_t *)ring;  e->ring_cap = ring_cap;
    e->heap = (uint8_t *)heap;  e->heap_cap = heap_cap;
    e->submit_seq = 0;
    blt_alloc_init(&e->alloc, 0u, (uint32_t)heap_cap);   /* [MiSTer #14] free-list heap */
}

void blt_heap_reset(blt_emitter_t *e) {
    blt_alloc_reset(&e->alloc);   /* [MiSTer #14] reclaim the whole heap (one free block) */
    e->heap_used = 0;
}

void blt_emitter_free(blt_emitter_t *e, uint32_t off, uint32_t size) {
    blt_free(&e->alloc, off, size);              /* [MiSTer #14] free one upload's block */
    e->heap_used = blt_alloc_used(&e->alloc);
}

/* Shared 16bpp upload core — copies a packed 16-bit/px surface into the heap and
 * tags the handle with `format`. ARGB4444 and RGB565 share identical packing,
 * stride and addressing (16bpp); only the command-time format byte differs. */
static blt_surface_ref_t upload16(blt_emitter_t *e, const uint16_t *pixels,
                                  int w, int h, int pitch, uint8_t format)
{
    blt_surface_ref_t r = (blt_surface_ref_t){0};
    /* [MiSTer #109] Reject geometry that will not fit the 16-bit wire fields.
     * blt_surface_ref_t.stride/w/h are uint16_t and the command's src_stride/w/h
     * are 16-bit, so a surface wider than 32767px (stride = w*2 > 0xFFFF) or a
     * dimension > 65535 would silently truncate/wrap and blit garbage with no
     * diagnostic. Set overflow (same escape contract as heap exhaustion, line
     * below) and return an invalid ref instead of truncating. */
    if (w < 0 || h < 0 ||
        (size_t)w > 0xFFFFu || (size_t)h > 0xFFFFu ||
        (size_t)w * 2u > 0xFFFFu) {
        e->overflow = 1;
        return r;
    }
    size_t stride = (size_t)w * 2;
    size_t need = (size_t)h * stride;
    /* [MiSTer #14] allocate from the free-list (was a bump pointer). blt_alloc keeps
     * blocks 8-byte aligned for the fabric's qword read master. On exhaustion it
     * returns BLT_ALLOC_FAIL -> set overflow (same contract as the old bump). */
    uint32_t off = blt_alloc(&e->alloc, (uint32_t)need);
    if (off == BLT_ALLOC_FAIL) { e->overflow = 1; return r; }

    const uint8_t *src = (const uint8_t *)pixels;
    for (int y = 0; y < h; y++)
        memcpy(e->heap + (size_t)off + (size_t)y * stride,
               src + (size_t)y * (size_t)pitch, stride);

    e->heap_used = blt_alloc_used(&e->alloc);
    r.off = off; r.stride = (uint16_t)stride;
    r.w = (uint16_t)w; r.h = (uint16_t)h; r.format = format; r.valid = 1;
    r.size = (uint32_t)need;   /* pass to blt_emitter_free */
    r.sdram_off = BLT_ALLOC_FAIL;   /* [MiSTer #33] unstaged until blt_stage_surface */
    return r;
}

blt_surface_ref_t blt_upload(blt_emitter_t *e, const uint16_t *pixels,
                             int w, int h, int pitch)
{
    return upload16(e, pixels, w, h, pitch, BLT_FMT_RGB565);
}

blt_surface_ref_t blt_upload_argb4444(blt_emitter_t *e, const uint16_t *pixels,
                                      int w, int h, int pitch)
{
    return upload16(e, pixels, w, h, pitch, BLT_FMT_ARGB4444);
}

void blt_begin_frame(blt_emitter_t *e, int target_buf, int clear,
                     uint16_t clear_color)
{
    e->cmd_count   = 0;
    e->tl_used     = 0;        /* reset tile-list entry buffer cursor */
    e->sp_used     = 0;        /* [Task 3] reset sprite-entry buffer cursor */
    e->overflow    = 0;        /* fresh per-frame overflow flag */
    e->dropped     = 0;        /* fresh per-frame drop counter */
    /* target_buf: 0/1 = the two display framebuffers; 2 = the OFF-SCREEN bg-cache
     * compose region (issue #18). Must NOT collapse 2 -> 1: the old `?1:0` clamped
     * the cache pass onto FB1, so the fabric never routed the blit to CACHE_QW (the
     * cache stayed zero -> black floor when standing) and the CACHE_BUILD diag
     * (gated on submitted_buf==2) never fired. Pass the cache target through. */
    e->target_buf  = (target_buf == 2) ? 2 : (target_buf ? 1 : 0);
    e->flags       = clear ? 1u : 0u;
    e->clear_color = clear_color;
}

static int emit(blt_emitter_t *e, const blt_cmd_t *c)
{
    size_t pos = (size_t)e->cmd_count * BLT_CMD_BYTES;
    if (pos + BLT_CMD_BYTES > e->ring_cap) { e->overflow = 1; e->dropped++; return -1; }
    blt_pack_cmd(c, e->ring + pos);
    e->cmd_count++;
    return 0;
}

int blt_fill(blt_emitter_t *e, int x, int y, int w, int h, uint16_t color)
{
    blt_cmd_t c; memset(&c, 0, sizeof(c));
    c.opcode = BLT_OP_FILL;
    c.dst_x = (int16_t)x; c.dst_y = (int16_t)y;
    c.w = (uint16_t)w; c.h = (uint16_t)h; c.color = color;
    return emit(e, &c);
}

/* [ARGB4444 plane bake] Same as blt_fill, but carries an explicit BLT_F_* flags
 * byte (BLT_F_BGCOV clears the bake-coverage tracker instead of setting it —
 * see bgplane_coverage.sv). blt_fill above is unchanged (flags always 0). */
int blt_fill_flags(blt_emitter_t *e, int x, int y, int w, int h, uint16_t color,
                   uint8_t flags)
{
    blt_cmd_t c; memset(&c, 0, sizeof(c));
    c.opcode = BLT_OP_FILL;
    c.flags = flags;
    c.dst_x = (int16_t)x; c.dst_y = (int16_t)y;
    c.w = (uint16_t)w; c.h = (uint16_t)h; c.color = color;
    return emit(e, &c);
}

int blt_blit(blt_emitter_t *e, blt_surface_ref_t s,
             int sx, int sy, int w, int h, int dx, int dy,
             uint8_t blend, uint16_t key, uint8_t alpha, uint8_t flags)
{
    if (!s.valid) { e->overflow = 1; return -1; }
    blt_cmd_t c; memset(&c, 0, sizeof(c));
    c.opcode = BLT_OP_BLIT; c.blend_mode = blend; c.flags = flags;
    c.format = s.format;            /* RGB565 or ARGB4444, per the upload */
    /* [MiSTer #33/#34] in SDRAM-VRAM mode a STAGED source is read from its SDRAM
     * offset; an un-staged source stays on DDR3. C_SRCSEL is only the frame-level
     * master enable, so tag THIS command with F_SRC_SDRAM (per-command mux, #34) —
     * else under global C_SRCSEL=1 the fabric would read un-staged DDR3 offsets out
     * of SDRAM (garbage/black). FILLs never reach here; framebuffer-carry blits use
     * un-staged handles -> no flag -> DDR3. */
    {
        int use_sdram = (e->sdram_src && s.sdram_off != BLT_ALLOC_FAIL);
        c.src_off = use_sdram ? s.sdram_off : s.off;
        if (use_sdram) c.flags |= BLT_F_SRC_SDRAM;
    }
    c.src_stride = s.stride;
    c.src_x = (uint16_t)sx; c.src_y = (uint16_t)sy;
    c.w = (uint16_t)w; c.h = (uint16_t)h;
    c.dst_x = (int16_t)dx; c.dst_y = (int16_t)dy;
    c.colorkey = key; c.alpha = alpha;
    return emit(e, &c);
}

int blt_blit_copy(blt_emitter_t *e, blt_surface_ref_t s, int dx, int dy)
{
    return blt_blit(e, s, 0, 0, s.w, s.h, dx, dy, BLT_BLEND_COPY, 0, 0, 0);
}

/* [PAL8 v1] blt_blit, but format is forced to BLT_FMT_PAL8 and the command's
 * color field carries pal_id/base_off (blt_blit has no color parameter to do
 * this through). */
int blt_blit_pal8(blt_emitter_t *e, blt_surface_ref_t s,
                  int sx, int sy, int w, int h, int dx, int dy,
                  uint8_t blend, uint16_t key, uint8_t alpha, uint8_t flags,
                  uint8_t pal_id, uint8_t base_off)
{
    if (!s.valid) { e->overflow = 1; return -1; }
    blt_cmd_t c; memset(&c, 0, sizeof(c));
    c.opcode = BLT_OP_BLIT; c.blend_mode = blend; c.flags = flags;
    c.format = BLT_FMT_PAL8;        /* [PAL8 v1] 8bpp palette-indexed source */
    /* [MiSTer #33/#34] same SDRAM vs DDR3 source mux as blt_blit */
    {
        int use_sdram = (e->sdram_src && s.sdram_off != BLT_ALLOC_FAIL);
        c.src_off = use_sdram ? s.sdram_off : s.off;
        if (use_sdram) c.flags |= BLT_F_SRC_SDRAM;
    }
    c.src_stride = s.stride;
    c.src_x = (uint16_t)sx; c.src_y = (uint16_t)sy;
    c.w = (uint16_t)w; c.h = (uint16_t)h;
    c.dst_x = (int16_t)dx; c.dst_y = (int16_t)dy;
    c.colorkey = key; c.alpha = alpha;
    c.color = blt_pal_color(pal_id, base_off);   /* [PAL8 v1] pal_id[11:8] | base_off[7:0] */
    return emit(e, &c);
}

/* [v2] Color-modulated blit: packs cr,cg,cb into _pad[0..2] and sets
 * BLT_F_COLORMOD so the RTL modulates source pixels before blend. */
int blt_blit_mod(blt_emitter_t *e, blt_surface_ref_t s,
                 int sx, int sy, int w, int h, int dx, int dy,
                 uint8_t blend, uint16_t key, uint8_t alpha, uint8_t flags,
                 uint8_t cr, uint8_t cg, uint8_t cb)
{
    if (!s.valid) { e->overflow = 1; return -1; }
    blt_cmd_t c; memset(&c, 0, sizeof(c));
    c.opcode = BLT_OP_BLIT; c.blend_mode = blend;
    c.flags = flags | BLT_F_COLORMOD;   /* always set COLORMOD */
    c.format = s.format;
    /* [MiSTer #33/#34] same SDRAM vs DDR3 source mux as blt_blit */
    {
        int use_sdram = (e->sdram_src && s.sdram_off != BLT_ALLOC_FAIL);
        c.src_off = use_sdram ? s.sdram_off : s.off;
        if (use_sdram) c.flags |= BLT_F_SRC_SDRAM;
    }
    c.src_stride = s.stride;
    c.src_x = (uint16_t)sx; c.src_y = (uint16_t)sy;
    c.w = (uint16_t)w; c.h = (uint16_t)h;
    c.dst_x = (int16_t)dx; c.dst_y = (int16_t)dy;
    c.colorkey = key; c.alpha = alpha;
    /* pack color modulation into the three reserved _pad bytes */
    c._pad[0] = cr; c._pad[1] = cg; c._pad[2] = cb;
    return emit(e, &c);
}

/* [v2] Fill with an explicit blend_mode (BLT_BLEND_ADD / BLT_BLEND_MULTIPLY).
 * The existing blt_fill always emits blend_mode=COPY. */
int blt_fill_blend(blt_emitter_t *e, int x, int y, int w, int h,
                   uint16_t color, uint8_t blend_mode)
{
    blt_cmd_t c; memset(&c, 0, sizeof(c));
    c.opcode = BLT_OP_FILL; c.blend_mode = blend_mode;
    c.dst_x = (int16_t)x; c.dst_y = (int16_t)y;
    c.w = (uint16_t)w; c.h = (uint16_t)h; c.color = color;
    return emit(e, &c);
}

/* [const-alpha fill] FILL blended into the FB by a constant alpha (the colored
 * fade overlay). src channel = color, blended per blt_blend565 by alpha/255. */
int blt_fill_alpha(blt_emitter_t *e, int x, int y, int w, int h,
                   uint16_t color, uint8_t alpha)
{
    blt_cmd_t c; memset(&c, 0, sizeof(c));
    c.opcode = BLT_OP_FILL; c.blend_mode = BLT_BLEND_CONST_ALPHA;
    c.dst_x = (int16_t)x; c.dst_y = (int16_t)y;
    c.w = (uint16_t)w; c.h = (uint16_t)h;
    c.color = color; c.alpha = alpha;
    return emit(e, &c);
}

void blt_end_frame(blt_emitter_t *e)
{
    blt_cmd_t end; memset(&end, 0, sizeof(end));
    end.opcode = BLT_OP_END;
    emit(e, &end);            /* END counts in cmd_count (walk-until-END) */
    e->submit_seq++;          /* doorbell: caller publishes then bumps DDR */
}

/* [MiSTer #19] BLT_OP_STAGE: queue a DDR3->SDRAM surface copy command.
 * Field layout: src_off = off (heap byte offset); size is 32-bit and packed
 * across the two uint16_t fields w (low 16) and h (high 16) — the wire word
 * u32[3] = w | h<<16 carries the full 32-bit size without touching any field
 * that FILL or BLIT use. All other cmd fields are zero (blend_mode=0=COPY,
 * format=0=RGB565, flags=0; src_stride/src_x/src_y/dst_x/dst_y/colorkey/
 * color/alpha all zero — unused for STAGE). */
int blt_stage(blt_emitter_t *e, uint32_t off, uint32_t size)
{
    blt_cmd_t c; memset(&c, 0, sizeof(c));
    c.opcode  = BLT_OP_STAGE;
    c.src_off = off;
    c.w       = (uint16_t)(size & 0xFFFFu);         /* size low  16 */
    c.h       = (uint16_t)((size >> 16) & 0xFFFFu); /* size high 16 */
    return emit(e, &c);
}

/* [MiSTer #32] STAGE with a decoupled SDRAM dest offset. ddr_off -> cmd.src_off
 * (DDR3 SRC_QW+off read/bounce base); sdram_off -> u32[2] = {src_x,src_stride};
 * BLT_F_STAGE_DST tells the fabric to use sdram_off as the SDRAM write base. */
int blt_stage_to(blt_emitter_t *e, uint32_t ddr_off, uint32_t sdram_off, uint32_t size)
{
    blt_cmd_t c; memset(&c, 0, sizeof(c));
    c.opcode     = BLT_OP_STAGE;
    c.flags      = BLT_F_STAGE_DST;
    c.src_off    = ddr_off;                                  /* DDR3 read (bounce) base    */
    c.src_stride = (uint16_t)(sdram_off & 0xFFFFu);          /* u32[2] low  = sdram[15:0]  */
    c.src_x      = (uint16_t)((sdram_off >> 16) & 0xFFFFu);  /* u32[2] high = sdram[31:16] */
    c.w          = (uint16_t)(size & 0xFFFFu);               /* size low  16               */
    c.h          = (uint16_t)((size >> 16) & 0xFFFFu);       /* size high 16               */
    return emit(e, &c);
}

/* [MiSTer #33] Enable SDRAM-VRAM mode: a SECOND offset allocator over [0, sdram_cap)
 * decoupled from the DDR3 heap; blits then read staged sources from SDRAM. */
void blt_sdram_init(blt_emitter_t *e, uint32_t base, uint32_t size)
{
    blt_alloc_init(&e->sdram_alloc, base, size);
    e->sdram_src = 1;
}

/* [residency] Two disjoint SDRAM allocators: perm (grow-only) + inter (recycled). */
void blt_sdram_regions_init(blt_emitter_t *e, uint32_t perm_base, uint32_t perm_size,
                            uint32_t inter_base, uint32_t inter_size)
{
    blt_alloc_init(&e->sdram_perm,  perm_base,  perm_size);
    blt_alloc_init(&e->sdram_alloc, inter_base, inter_size);
    e->perm_overflow = 0;
    e->sdram_src = 1;
}

/* [MiSTer #33] Stage `r` DDR3(bounce)->SDRAM. First call allocates a fresh SDRAM
 * offset; a re-stage reuses the same offset (idempotent — dirty re-uploads must not
 * leak the allocator). */
int blt_stage_surface(blt_emitter_t *e, blt_surface_ref_t *r)
{
    if (!r->valid) { e->overflow = 1; return -1; }
    if (r->sdram_off == BLT_ALLOC_FAIL) {
        uint32_t soff = blt_alloc(&e->sdram_alloc, r->size);
        if (soff == BLT_ALLOC_FAIL) { e->overflow = 1; return -1; }
        r->sdram_off = soff;
    }
    return blt_stage_to(e, r->off, r->sdram_off, r->size);
}

/* [MiSTer #33] Return a surface's SDRAM offset to the allocator (on evict). */
void blt_sdram_free(blt_emitter_t *e, blt_surface_ref_t *r)
{
    if (r->sdram_off == BLT_ALLOC_FAIL) return;
    blt_free(&e->sdram_alloc, r->sdram_off, r->size);
    r->sdram_off = BLT_ALLOC_FAIL;
}

/* [residency] Stage into the permanent region. Never freed; perm_overflow on exhaustion. */
int blt_stage_surface_perm(blt_emitter_t *e, blt_surface_ref_t *r)
{
    if (!r->valid) { e->overflow = 1; return -1; }
    if (r->sdram_off == BLT_ALLOC_FAIL) {
        uint32_t soff = blt_alloc(&e->sdram_perm, r->size);
        if (soff == BLT_ALLOC_FAIL) { e->perm_overflow = 1; return -1; }
        r->sdram_off = soff;
    }
    return blt_stage_to(e, r->off, r->sdram_off, r->size);
}

/* ─── [#52, Task 7] blt_tile_list_init / blt_tile_list_res ──────────────── */

void blt_tile_list_init(blt_emitter_t *e, void *tl_buf, size_t tl_cap)
{
    e->tl_buf  = (uint8_t *)tl_buf;
    e->tl_cap  = tl_cap;
    e->tl_used = 0;
}

/* Build + emit a tile-list header (opcode = BLT_OP_TILELIST_RES). [Task 7] The two
 * older non-resident/Tier-A tile-list emitters (one that copied entries first, one
 * that re-emitted a header-only 12-byte-entry pointer) were deleted once the resident
 * path collapsed to a single fabric-resolved emitter; blt_tile_list_res below is the
 * sole remaining caller of this helper.
 * [#52 camera-independent resident] bias_x/bias_y are a signed per-batch dst bias
 * (map-coord -> screen), carried in the header's src_x/src_y slots (informational
 * texture-bounds fields, unused by the fabric — confirmed safe to repurpose). */
static int tl_emit_header(blt_emitter_t *e, uint8_t opcode, blt_surface_ref_t tex,
                          uint8_t blend, uint16_t key, uint8_t alpha, uint8_t flags,
                          uint32_t eoff, int n, int16_t bias_x, int16_t bias_y,
                          uint16_t color)
{
    blt_cmd_t c; memset(&c, 0, sizeof(c));
    c.opcode     = opcode;
    c.blend_mode = blend;
    c.flags      = flags;
    c.format     = tex.format;
    c.color      = color;   /* [PAL8] pal_id/base_off for BLT_FMT_PAL8 tilesets; 0 otherwise */
    /* [#33/#34] same SDRAM vs DDR3 source mux as blt_blit */
    {
        int use_sdram = (e->sdram_src && tex.sdram_off != BLT_ALLOC_FAIL);
        c.src_off = use_sdram ? tex.sdram_off : tex.off;
        if (use_sdram) c.flags |= BLT_F_SRC_SDRAM;
    }
    c.src_stride = tex.stride;
    c.src_x      = (uint16_t)bias_x;                           /* [#52] signed dst bias x */
    c.src_y      = (uint16_t)bias_y;                           /* [#52] signed dst bias y */
    c.w          = (uint16_t)((unsigned)n & 0xFFFF);           /* N low  16 */
    c.h          = (uint16_t)((unsigned)n >> 16);              /* N high 16 */
    c.dst_x      = (int16_t)(eoff & 0xFFFF);                   /* entry-array byte offset low  */
    c.dst_y      = (int16_t)(eoff >> 16);                      /* entry-array byte offset high */
    c.colorkey   = key;
    c.alpha      = alpha;
    return emit(e, &c);
}

int blt_tile_list_res(blt_emitter_t *e, blt_surface_ref_t tex, uint8_t blend,
                      uint16_t key, uint8_t alpha, uint8_t flags,
                      uint32_t entry_off, int n, int16_t bias_x, int16_t bias_y,
                      uint16_t color)
{
    if (!tex.valid || n <= 0) { e->overflow = 1; return -1; }
    return tl_emit_header(e, BLT_OP_TILELIST_RES, tex, blend, key, alpha, flags,
                          entry_off, n, bias_x, bias_y, color);
}

int blt_tile_list_static(blt_emitter_t *e, blt_surface_ref_t tex, uint8_t blend,
                         uint16_t key, uint8_t alpha, uint8_t flags,
                         uint32_t entry_off, int n, int16_t bias_x, int16_t bias_y,
                         uint16_t color)
{
    if (!tex.valid || n <= 0) { e->overflow = 1; return -1; }
    return tl_emit_header(e, BLT_OP_TILELIST, tex, blend, key, alpha, flags,
                          entry_off, n, bias_x, bias_y, color);
}

/* ─── [Task 3 / Stage 2] blt_sprite_list_init / blt_sprite_list ─────────── */

void blt_sprite_list_init(blt_emitter_t *e, void *sp_buf, size_t sp_cap)
{
    e->sp_buf  = (uint8_t *)sp_buf;
    e->sp_cap  = sp_cap;
    e->sp_used = 0;
}

/* Header-only BLT_OP_SPRITELIST -- SAME header packing as BLT_OP_TILELIST
 * (see tl_emit_header above): w|h<<16 = entry count, dst_x|dst_y<<16 =
 * entry-array byte offset, src_x/src_y = signed per-batch dst bias. Unlike
 * blt_tile_list_static/res there is no shared texture handle to pull
 * src_off/src_stride/format from -- each sprite entry carries its own
 * src_off, so the caller passes src_stride/format directly. */
int blt_sprite_list(blt_emitter_t *e, uint32_t src_stride, uint8_t format, uint8_t blend,
                    uint16_t key, uint8_t alpha, uint8_t flags,
                    uint32_t entry_off, int n, int16_t bias_x, int16_t bias_y)
{
    blt_cmd_t c;
    memset(&c, 0, sizeof c);
    c.opcode     = BLT_OP_SPRITELIST;
    c.blend_mode = blend;
    c.format     = format;
    c.flags      = flags;
    c.alpha      = alpha;
    c.colorkey   = key;
    c.src_stride = (uint16_t)src_stride;
    c.src_x      = (uint16_t)bias_x;              /* header bias slots, per convention */
    c.src_y      = (uint16_t)bias_y;
    c.w          = (uint16_t)((unsigned)n & 0xFFFF);        /* w | h<<16 = entry count    */
    c.h          = (uint16_t)((unsigned)n >> 16);
    c.dst_x      = (int16_t)(entry_off & 0xFFFF); /* dst_x | dst_y<<16 = entry offset */
    c.dst_y      = (int16_t)(entry_off >> 16);
    return emit(e, &c);
}

/* ─── [Task 4 / Stage 2] bounded ordered sprite channel ─────────────────── */

void blt_sprite_channel_init(blt_sprite_channel_t *ch, blt_emitter_t *e, int cap)
{
    ch->e         = e;
    if (cap < 0) cap = 0;
    if (cap > BLT_SPRITE_CHANNEL_MAX) cap = BLT_SPRITE_CHANNEL_MAX;
    ch->cap       = cap;
    ch->count     = 0;
    ch->dropped   = 0;
}

/* DISCARD the current batch without committing it. The uncommitted entries sit
 * above e->sp_used, so dropping `count` returns their bytes to the frame arena --
 * which is exactly right for the caller that uses this (a hardware clear wipes the
 * framebuffer, so buffered sprites must vanish rather than be emitted).
 *
 * `dropped` is NOT cleared here: it is a diagnostic accumulator owned by the
 * caller's counter reset, not per-flush state. */
void blt_sprite_channel_reset(blt_sprite_channel_t *ch)
{
    ch->count = 0;
}

int blt_sprite_channel_push(blt_sprite_channel_t *ch, const blt_sprite_run_key_t *k,
                            const blt_sprite_entry_t *e)
{
    size_t off;
    if (ch->count >= ch->cap) { ch->dropped++; return 0; }
    /* The batch being accumulated occupies
     * [sp_used, sp_used + count*BLT_SPRITE_ENTRY_BYTES). sp_used is
     * only advanced when a flush COMMITS the batch, so entries already emitted this
     * frame are never written over -- the fabric consumes nothing until C_SUBMIT, so
     * every list's entries must survive intact until the frame ends. */
    off = ch->e->sp_used + (size_t)ch->count * (size_t)BLT_SPRITE_ENTRY_BYTES;
    /* Exhausting the per-frame arena drops the TAIL and counts it, exactly like the
     * entry cap above (and surfaced by the same `dropped` diag counter). Wrapping or
     * clamping here would silently paint one list's sprites from another's bytes. */
    if (off + (size_t)BLT_SPRITE_ENTRY_BYTES > ch->e->sp_cap) { ch->dropped++; return 0; }
    blt_pack_sprite_entry(ch->e->sp_buf + off, e);
    ch->keys[ch->count] = *k;
    ch->count++;
    return 1;
}

int blt_sprite_channel_flush(blt_sprite_channel_t *ch, int16_t bias_x, int16_t bias_y)
{
    /* The batch's entries start at the frame cursor's CURRENT value; each emitted
     * header carries the absolute SP_BUF offset of its OWN run. */
    uint32_t base = (uint32_t)ch->e->sp_used;
    int i = 0, runs = 0;
    if (ch->count <= 0) return 0;
    while (i < ch->count) {
        int j = i + 1;
        while (j < ch->count && !blt_sprite_run_key_differs(&ch->keys[j], &ch->keys[i]))
            ++j;
        blt_sprite_list(ch->e, ch->keys[i].src_stride, ch->keys[i].format,
                        ch->keys[i].blend, ch->keys[i].colorkey, ch->keys[i].alpha,
                        ch->keys[i].flags,
                        base + (uint32_t)i * (uint32_t)BLT_SPRITE_ENTRY_BYTES, j - i,
                        bias_x, bias_y);
        runs++;
        i = j;
    }
    /* COMMIT: the flushed bytes now belong to the frame and are off-limits to the
     * next batch, until blt_begin_frame recycles the whole arena. */
    ch->e->sp_used += (size_t)ch->count * (size_t)BLT_SPRITE_ENTRY_BYTES;
    ch->count = 0;
    return runs;
}

int blt_frt_upload(blt_emitter_t *e, uint32_t qword_count)
{
    blt_cmd_t c; memset(&c, 0, sizeof(c));
    c.opcode = BLT_OP_FRT_UPLOAD;
    c.w = (uint16_t)(qword_count & 0xFFFF);        /* count low  16 */
    c.h = (uint16_t)(qword_count >> 16);           /* count high 16 */
    return emit(e, &c);
}

int blt_bgplane_write_cell(blt_emitter_t *e, uint32_t sdram_qword_offset,
                           uint32_t dst_stride_qw, uint8_t flags)
{
    blt_cmd_t c; memset(&c, 0, sizeof(c));
    c.opcode = BLT_OP_BGPLANE_WRITE;
    c.flags  = flags;
    c.dst_x = (uint16_t)(sdram_qword_offset & 0xFFFF);      /* offset low  16 */
    c.dst_y = (uint16_t)(sdram_qword_offset >> 16);         /* offset high 16 */
    c.src_x = (uint16_t)(dst_stride_qw & 0xFFFF);           /* stride */
    return emit(e, &c);
}

/* [PAL8 v1] Emit BLT_OP_CLUT_UPLOAD; see the doc comment in blt_emitter.h.
 * Packs the qword count identically to blt_frt_upload's c.w/c.h split. */
int blt_emit_clut_upload(blt_emitter_t *e, uint32_t clutbuf_off, uint32_t qw_count)
{
    blt_cmd_t c; memset(&c, 0, sizeof(c));
    c.opcode  = BLT_OP_CLUT_UPLOAD;
    c.src_off = clutbuf_off;                       /* [doc/future] see blt_emitter.h */
    c.w = (uint16_t)(qw_count & 0xFFFF);            /* count low  16 */
    c.h = (uint16_t)(qw_count >> 16);               /* count high 16 */
    return emit(e, &c);
}

/* ══════════════════════════════════════════════════════════════════════════
 *  Self-test. Build with -DBLT_EMITTER_SELFTEST and run on the host:
 *      cc -DBLT_EMITTER_SELFTEST -I patches/mister/blitter \
 *         patches/mister/blitter/blt_emitter.c \
 *         patches/mister/blitter/blt_alloc.c \
 *         -o /tmp/blt_emit && /tmp/blt_emit
 *  Proves: blt_tile_list_res emits the correct header (opcode, src_off/stride, N,
 *  entry-byte-offset, dst bias) for the resident 8-byte tile-list entries.
 * ══════════════════════════════════════════════════════════════════════════ */
#ifdef BLT_EMITTER_SELFTEST
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>

static int g_fail = 0;
#define CHECK(cond, ...) do { if (!(cond)) { g_fail++; printf("  FAIL: "); printf(__VA_ARGS__); printf("\n"); } } while (0)

/* const-alpha FILL emission (the colored-fade overlay). A translucent rect must
 * emit BLT_OP_FILL with blend_mode=CONST_ALPHA, carrying both the fill colour and
 * the alpha, so the fabric blends it instead of writing opaque colour. */
static void test_blt_fill_alpha(void) {
    uint8_t ring[4096], heap[8192];
    blt_emitter_t e;
    blt_emitter_init(&e, ring, sizeof ring, heap, sizeof heap);
    blt_begin_frame(&e, 0, 0, 0);

    CHECK(blt_fill_alpha(&e, 50, 60, 320, 240, 0x0000, 128) == 0,
          "blt_fill_alpha returned non-zero");

    blt_cmd_t c; blt_unpack_cmd(ring, &c);
    CHECK(c.opcode     == BLT_OP_FILL,           "opcode %u exp FILL(%u)", c.opcode, BLT_OP_FILL);
    CHECK(c.blend_mode == BLT_BLEND_CONST_ALPHA, "blend %u exp CONST_ALPHA(%u)", c.blend_mode, BLT_BLEND_CONST_ALPHA);
    CHECK(c.color      == 0x0000,                "color 0x%x exp 0x0000", c.color);
    CHECK(c.alpha      == 128,                   "alpha %u exp 128", c.alpha);
    CHECK(c.dst_x      == 50,                    "dst_x %d exp 50", c.dst_x);
    CHECK(c.dst_y      == 60,                    "dst_y %d exp 60", c.dst_y);
    CHECK(c.w          == 320,                   "w %u exp 320", c.w);
    CHECK(c.h          == 240,                   "h %u exp 240", c.h);
    printf("ok test_blt_fill_alpha\n");
}

/* [#52 resident / Tier B] blt_tile_list_res emits a header-only BLT_OP_TILELIST_RES
 * pointing at resident 8-byte entries; blt_frt_upload emits BLT_OP_FRT_UPLOAD carrying
 * the frame-rect-table qword count. */
static void test_blt_tile_list_res(void) {
    uint8_t ring[4096], heap[8192], tlbuf[4096];
    blt_emitter_t e;
    blt_emitter_init(&e, ring, sizeof ring, heap, sizeof heap);
    blt_tile_list_init(&e, tlbuf, sizeof tlbuf);
    blt_begin_frame(&e, 0, 0, 0);

    blt_surface_ref_t tex = { .off=0x300, .stride=512, .w=256, .h=128,
                              .format=BLT_FMT_RGB565, .valid=1,
                              .sdram_off=BLT_ALLOC_FAIL };
    const uint32_t eoff = 0x80; const int n = 7;

    /* FRT upload header first (e.g. 1024 qwords for MAXP*MAXF). */
    CHECK(blt_frt_upload(&e, 1024) == 0, "blt_frt_upload returned non-zero");
    blt_cmd_t fu; blt_unpack_cmd(ring, &fu);
    CHECK(fu.opcode == BLT_OP_FRT_UPLOAD, "frt opcode %u exp %u", fu.opcode, BLT_OP_FRT_UPLOAD);
    uint32_t qc = (uint32_t)fu.w | ((uint32_t)fu.h << 16);
    CHECK(qc == 1024, "frt qword count %u exp 1024", qc);

    /* TILELIST_RES header (header-only, entries are resident).
     * [#52 camera-independent] bias_x=3, bias_y=-5 must land in the header's
     * src_x/src_y slots (repurposed from informational texture bounds). */
    CHECK(blt_tile_list_res(&e, tex, BLT_BLEND_COPY, 0, 255, 0, eoff, n, 3, -5, 0) == 0,
          "blt_tile_list_res returned non-zero");
    CHECK(e.tl_used == 0, "tl_used %zu exp 0 (header-only)", e.tl_used);
    blt_cmd_t c; blt_unpack_cmd(ring + BLT_CMD_BYTES, &c);   /* 2nd ring command */
    CHECK(c.opcode     == BLT_OP_TILELIST_RES, "opcode %u exp %u", c.opcode, BLT_OP_TILELIST_RES);
    CHECK(c.src_off    == 0x300,               "src_off 0x%x exp 0x300", c.src_off);
    CHECK(c.src_stride == 512,                 "src_stride %u exp 512", c.src_stride);
    CHECK(c.src_x == 3,             "bias_x (src_x) %u exp 3", c.src_x);
    CHECK(c.src_y == (uint16_t)-5,  "bias_y (src_y) %u exp %u", c.src_y, (uint16_t)-5);
    uint32_t nn = (uint32_t)c.w | ((uint32_t)c.h << 16);
    CHECK(nn == 7, "N %u exp 7", nn);
    uint32_t got = (uint32_t)(uint16_t)c.dst_x | ((uint32_t)(uint16_t)c.dst_y << 16);
    CHECK(got == eoff, "eoff %u exp %u", got, eoff);
    CHECK(c.format == BLT_FMT_RGB565, "format %u exp RGB565", c.format);
    CHECK(c.color == 0, "color %u exp 0 (non-PAL8)", c.color);
    printf("ok test_blt_tile_list_res\n");
}

/* [static tile-list] blt_tile_list_static emits a header-only BLT_OP_TILELIST
 * (12-byte direct entries) with N, entry byte-offset, and the dst bias. */
static void test_blt_tile_list_static(void) {
    blt_emitter_t e; uint8_t ring[4096]; uint8_t heap[4096]; uint8_t tlbuf[4096];
    blt_emitter_init(&e, ring, sizeof ring, heap, sizeof heap);
    blt_tile_list_init(&e, tlbuf, sizeof tlbuf);
    blt_begin_frame(&e, 0, 0, 0);
    blt_surface_ref_t tex = { .valid=1, .off=0x2000, .sdram_off=BLT_ALLOC_FAIL,
                              .stride=1024, .format=BLT_FMT_RGB565, .w=512, .h=512 };
    const uint32_t eoff = 96; const int n = 7;
    CHECK(blt_tile_list_static(&e, tex, BLT_BLEND_COPY, 0, 255, 0, eoff, n, -4, 3, 0) == 0,
          "blt_tile_list_static returned non-zero");
    blt_cmd_t c; blt_unpack_cmd(ring, &c);
    CHECK(c.opcode == BLT_OP_TILELIST, "opcode %u exp %u", c.opcode, BLT_OP_TILELIST);
    CHECK(c.src_off == 0x2000, "src_off 0x%x exp 0x2000", c.src_off);
    CHECK(c.src_stride == 1024, "src_stride %u exp 1024", c.src_stride);
    uint32_t nn = (uint32_t)c.w | ((uint32_t)c.h << 16);
    CHECK(nn == 7, "N %u exp 7", nn);
    uint32_t got = (uint32_t)(uint16_t)c.dst_x | ((uint32_t)(uint16_t)c.dst_y << 16);
    CHECK(got == eoff, "eoff %u exp %u", got, eoff);
    CHECK(c.src_x == (uint16_t)-4, "bias_x (src_x) %u exp %u", c.src_x, (uint16_t)-4);
    CHECK(c.src_y == 3, "bias_y (src_y) %u exp 3", c.src_y);
    CHECK(c.format == BLT_FMT_RGB565, "format %u exp RGB565", c.format);
    CHECK(c.color == 0, "color %u exp 0 (non-PAL8)", c.color);

    /* [PAL8 tile-list] a paletted tileset bucket: PAL8 tex + color=blt_pal_color(bank,base).
     * The fabric latches c_format + c_color(->c_pal_id/c_base_off) from this header and
     * applies them to every tile entry (proven equivalent by tb_pal8_tilelist.sv). */
    blt_surface_ref_t ptex = { .valid=1, .off=0x5000, .sdram_off=0x1234,
                               .stride=64, .format=BLT_FMT_PAL8, .w=64, .h=64 };
    const uint16_t pcolor = blt_pal_color(/*pal_id=*/5, /*base_off=*/7);
    CHECK(blt_tile_list_static(&e, ptex, BLT_BLEND_COPY, 0, 255, 0, eoff, n, 0, 0, pcolor) == 0,
          "blt_tile_list_static (PAL8) returned non-zero");
    blt_cmd_t pc; blt_unpack_cmd(ring + BLT_CMD_BYTES, &pc);   /* 2nd ring command */
    CHECK(pc.opcode == BLT_OP_TILELIST, "PAL8 opcode %u exp %u", pc.opcode, BLT_OP_TILELIST);
    CHECK(pc.format == BLT_FMT_PAL8, "PAL8 format %u exp %u", pc.format, BLT_FMT_PAL8);
    CHECK(pc.color == pcolor, "PAL8 color %u exp %u", pc.color, pcolor);
    CHECK(blt_pal_id(pc.color) == 5, "PAL8 pal_id %u exp 5", blt_pal_id(pc.color));
    CHECK(blt_base_off(pc.color) == 7, "PAL8 base_off %u exp 7", blt_base_off(pc.color));
    printf("ok test_blt_tile_list_static\n");
}

/* [PAL8 v1, Task 2.3] blt_emit_clut_upload emits a header-only BLT_OP_CLUT_UPLOAD
 * carrying the qword count in {c_h,c_w}, mirroring blt_frt_upload (see the FRT
 * check inside test_blt_tile_list_res above). */
static void test_blt_emit_clut_upload(void) {
    uint8_t ring[4096], heap[4096];
    blt_emitter_t e;
    blt_emitter_init(&e, ring, sizeof ring, heap, sizeof heap);
    blt_begin_frame(&e, 0, 0, 0);

    CHECK(blt_emit_clut_upload(&e, 0x1234, 2048) == 0,
          "blt_emit_clut_upload returned non-zero");
    blt_cmd_t c; blt_unpack_cmd(ring, &c);
    CHECK(c.opcode == BLT_OP_CLUT_UPLOAD, "opcode %u exp %u", c.opcode, BLT_OP_CLUT_UPLOAD);
    uint32_t qc = (uint32_t)c.w | ((uint32_t)c.h << 16);
    CHECK(qc == 2048, "clut qword count %u exp 2048", qc);
    CHECK(c.src_off == 0x1234, "src_off 0x%x exp 0x1234", c.src_off);
    printf("ok test_blt_emit_clut_upload\n");
}

/* [PAL8 v1, Task 2.3] blt_blit_pal8 sets format=BLT_FMT_PAL8 and packs
 * pal_id/base_off into c.color, recoverable via blt_pal_id/blt_base_off
 * (blt_wire.h) after a wire round-trip -- same accessors wire_pal8_test.c
 * exercises directly on a hand-built blt_cmd_t. */
static void test_blt_blit_pal8(void) {
    uint8_t ring[4096], heap[8192];
    blt_emitter_t e;
    blt_emitter_init(&e, ring, sizeof ring, heap, sizeof heap);
    blt_begin_frame(&e, 0, 0, 0);

    blt_surface_ref_t tex = { .off=0x400, .stride=256, .w=64, .h=64,
                              .format=BLT_FMT_RGB565, /* deliberately NOT PAL8 --
                                  blt_blit_pal8 must force the wire format,
                                  not trust the handle's upload-time format */
                              .valid=1, .sdram_off=BLT_ALLOC_FAIL };

    CHECK(blt_blit_pal8(&e, tex, 0, 0, 32, 32, 10, 20,
                        BLT_BLEND_COLORKEY, 0, 255, 0, 0x5, 0x80) == 0,
          "blt_blit_pal8 returned non-zero");
    blt_cmd_t c; blt_unpack_cmd(ring, &c);
    CHECK(c.opcode == BLT_OP_BLIT, "opcode %u exp %u", c.opcode, BLT_OP_BLIT);
    CHECK(c.format == BLT_FMT_PAL8, "format %u exp BLT_FMT_PAL8(%u)", c.format, BLT_FMT_PAL8);
    CHECK(blt_pal_id(c.color) == 0x5, "pal_id %u exp 0x5", blt_pal_id(c.color));
    CHECK(blt_base_off(c.color) == 0x80, "base_off %u exp 0x80", blt_base_off(c.color));
    printf("ok test_blt_blit_pal8\n");
}

int main(void) {
    test_blt_tile_list_res();
    test_blt_tile_list_static();
    test_blt_fill_alpha();
    test_blt_emit_clut_upload();
    test_blt_blit_pal8();

    /* Ring-overflow drops must be COUNTED, not silent. */
    {
        blt_emitter_t e2;
        static uint8_t ring2[BLT_CMD_BYTES * 4];
        blt_emitter_init(&e2, ring2, sizeof ring2, NULL, 0);
        blt_begin_frame(&e2, 0, 0, 0);
        int rc = 0;
        for (int i = 0; i < 32; i++)
            rc |= blt_fill(&e2, 0, 0, 1, 1, 0);
        if (rc == 0)          { printf("FAIL: expected overflow\n");            return 1; }
        if (e2.overflow != 1) { printf("FAIL: overflow flag not set\n");         return 1; }
        if (e2.dropped == 0)  { printf("FAIL: dropped not counted (%u)\n", e2.dropped); return 1; }
        printf("ok: ring drops counted (%u dropped)\n", e2.dropped);
    }

    if (g_fail == 0) { printf("blt_emitter self-test: PASS\n"); return 0; }
    printf("blt_emitter self-test: FAIL (%d)\n", g_fail);
    return 1;
}
#endif /* BLT_EMITTER_SELFTEST */
