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
    e->overflow    = 0;        /* fresh per-frame overflow flag */
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
    if (pos + BLT_CMD_BYTES > e->ring_cap) { e->overflow = 1; return -1; }
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

int blt_blit(blt_emitter_t *e, blt_surface_ref_t s,
             int sx, int sy, int w, int h, int dx, int dy,
             uint8_t blend, uint16_t key, uint8_t alpha, uint8_t flags)
{
    if (!s.valid) { e->overflow = 1; return -1; }
    blt_cmd_t c; memset(&c, 0, sizeof(c));
    c.opcode = BLT_OP_BLIT; c.blend_mode = blend; c.flags = flags;
    c.format = s.format;            /* RGB565 or ARGB4444, per the upload */
    c.src_off = s.off; c.src_stride = s.stride;
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

void blt_end_frame(blt_emitter_t *e)
{
    blt_cmd_t end; memset(&end, 0, sizeof(end));
    end.opcode = BLT_OP_END;
    emit(e, &end);            /* END counts in cmd_count (walk-until-END) */
    e->submit_seq++;          /* doorbell: caller publishes then bumps DDR */
}
