/* Host unit test for the bg-cache CHUNKED STAGE sweep — issue #19.
 *
 * Models the engine-side behaviour in mister_blitter_renderer.cpp:
 * the background cache is composited by the FABRIC straight into DDR3
 * (C_TARGET=2 -> OFF_BGCACHE) and never passes through blt_upload, so it is
 * NOT staged by the upload() path. It must be copied DDR3->SDRAM before the
 * cache->fb read at C_SRCSEL=1, else the read returns 0 (black background).
 *
 * Staging the WHOLE 153600-byte cache in ONE STAGE on a single ACTIVE frame
 * issued a huge DDR3 read burst on the same f2h bus the scanout uses for the
 * framebuffer -> scanout starvation -> the game image dropped (HW-diagnosed).
 * The fix sweeps the cache in a SMALL slice per ACTIVE frame, advancing an
 * offset cursor (bg_stage_off) until the whole cache is staged.
 *
 * The renderer can't be unit-tested on the host (pulls in SDL/Solarus types),
 * so we model the exact per-frame emit sequence + the cursor semantics:
 *   a) enabled: over ceil(CACHE_SIZE/BG_STAGE_CHUNK) frames the emitted slice
 *      STAGEs cover [0, CACHE_SIZE) contiguously, each <= BG_STAGE_CHUNK and
 *      preceding that frame's cache->fb BLIT; staging stops once covered.
 *   b) re-snapshot resets the cursor to 0 -> the sweep restarts.
 *   c) disabled -> no STAGE ever (shipping behavior byte-identical).
 *
 * These constants MUST MATCH mister_blitter_renderer.cpp.
 *
 * Build+run (from repo root):
 *   cc -Wall -Wextra -O2 -I patches/mister/blitter \
 *       tests/blt_bgcache_stage_test.c \
 *       patches/mister/blitter/blt_emitter.c \
 *       patches/mister/blitter/blt_alloc.c \
 *       -o /tmp/blt_bgcache_stage_test && /tmp/blt_bgcache_stage_test
 */
#include "blitter_ref.h"
#include "blt_emitter.h"
#include "blt_wire.h"
#include <stdio.h>
#include <stdint.h>
#include <string.h>

/* MUST MATCH mister_blitter_renderer.cpp's namespace constants. */
#define OFF_HEAP          0x00008000u
#define OFF_BGCACHE       0x00F00000u
#define BGCACHE_HEAP_OFF  (OFF_BGCACHE - OFF_HEAP)   /* heap-relative cache off */
#define FB_W 320
#define FB_H 240
#define CACHE_SIZE      ((uint32_t)(FB_W * FB_H * 2)) /* 320*240*2 = 153600 */
#define BG_STAGE_CHUNK  8192u                         /* per-frame slice */

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s (line %d)\n", msg, __LINE__); failures++; } \
} while (0)

static blt_cmd_t ring_read(const blt_emitter_t *e, int n)
{
    blt_cmd_t c; memset(&c, 0, sizeof(c));
    blt_unpack_cmd(e->ring + (size_t)n * BLT_CMD_BYTES, &c);
    return c;
}

static uint32_t stage_size(const blt_cmd_t *c)
{
    return (uint32_t)c->w | ((uint32_t)c->h << 16);
}

/* The hand-built cache source ref the renderer points bg_handle at after a
 * snapshot (off=BGCACHE_HEAP_OFF, FB_W x FB_H, RGB565). */
static blt_surface_ref_t make_bg_handle(void)
{
    blt_surface_ref_t h; memset(&h, 0, sizeof(h));
    h.off = BGCACHE_HEAP_OFF; h.stride = FB_W * 2;
    h.w = FB_W; h.h = FB_H; h.format = BLT_FMT_RGB565; h.valid = 1;
    h.size = CACHE_SIZE;
    return h;
}

/* Model one ACTIVE frame's cache emit: ensure_frame's bg_active branch.
 * if (stage_enabled && *off < CACHE_SIZE) emit one slice then advance *off;
 * then the cache->fb blit (always, after the optional slice). */
static void active_frame_emit(blt_emitter_t *e, blt_surface_ref_t bg,
                              int stage_enabled, uint32_t *off)
{
    blt_begin_frame(e, 0, 0, 0);
    if (stage_enabled && *off < CACHE_SIZE) {
        uint32_t remain = CACHE_SIZE - *off;
        uint32_t chunk  = remain < BG_STAGE_CHUNK ? remain : BG_STAGE_CHUNK;
        blt_stage(e, BGCACHE_HEAP_OFF + *off, chunk);
        *off += chunk;
    }
    blt_blit_copy(e, bg, 0, 0);
}

/* a) enabled: sweep covers [0,CACHE_SIZE) contiguously, one slice/frame, each
 *    <= BG_STAGE_CHUNK and preceding the BLIT; stops once fully staged. */
static void test_chunked_sweep_enabled(void)
{
    static uint8_t ring[64 * BLT_CMD_BYTES];
    static uint8_t heap[4096];
    blt_surface_ref_t bg = make_bg_handle();
    uint32_t off = 0;   /* reset at SNAPSHOT->ACTIVE transition */

    uint32_t expect_next = 0;     /* next contiguous src offset we expect */
    uint32_t total_staged = 0;
    int frames = 0;
    const uint32_t expect_frames = (CACHE_SIZE + BG_STAGE_CHUNK - 1) / BG_STAGE_CHUNK;

    /* Stage until the cursor reaches CACHE_SIZE (one slice per frame). */
    while (off < CACHE_SIZE) {
        blt_emitter_t e;
        blt_emitter_init(&e, ring, sizeof(ring), heap, sizeof(heap));
        active_frame_emit(&e, bg, /*stage_enabled=*/1, &off);
        frames++;

        /* exactly STAGE + BLIT this frame */
        CHECK(e.cmd_count == 2, "staging frame: STAGE + BLIT");
        blt_cmd_t s = ring_read(&e, 0);
        blt_cmd_t b = ring_read(&e, 1);
        CHECK(s.opcode == BLT_OP_STAGE, "cmd[0] is STAGE");
        CHECK(b.opcode == BLT_OP_BLIT,  "cmd[1] is the cache->fb BLIT (after STAGE)");
        CHECK(b.src_off == BGCACHE_HEAP_OFF, "BLIT reads the cache region");

        /* contiguous coverage, correct base offset */
        CHECK(s.src_off == BGCACHE_HEAP_OFF + expect_next,
              "STAGE slice is contiguous from prior slice");
        uint32_t sz = stage_size(&s);
        CHECK(sz <= BG_STAGE_CHUNK, "slice size <= BG_STAGE_CHUNK");
        CHECK(sz > 0, "slice size > 0");
        if (expect_next + BG_STAGE_CHUNK <= CACHE_SIZE)
            CHECK(sz == BG_STAGE_CHUNK, "full chunk while >= BG_STAGE_CHUNK remains");
        else
            CHECK(sz == CACHE_SIZE - expect_next, "final slice is the remainder");

        expect_next += sz;
        total_staged += sz;
        CHECK(off == expect_next, "cursor advanced by the slice size");

        if (frames > 1000) { CHECK(0, "sweep did not terminate"); break; }
    }

    CHECK(frames == (int)expect_frames, "sweep took ceil(CACHE_SIZE/CHUNK) frames");
    CHECK(expect_next == CACHE_SIZE, "slices end exactly at CACHE_SIZE (full coverage)");
    CHECK(total_staged == CACHE_SIZE, "total staged bytes == CACHE_SIZE");

    /* Next ACTIVE frame after the sweep completes: only the BLIT, no STAGE. */
    blt_emitter_t e;
    blt_emitter_init(&e, ring, sizeof(ring), heap, sizeof(heap));
    active_frame_emit(&e, bg, /*stage_enabled=*/1, &off);
    blt_cmd_t only = ring_read(&e, 0);
    CHECK(only.opcode == BLT_OP_BLIT, "post-sweep: cmd[0] is BLIT (no STAGE)");
    CHECK(e.cmd_count == 1,           "post-sweep: exactly 1 command");
    CHECK(off == CACHE_SIZE,          "post-sweep: cursor stays at CACHE_SIZE");
}

/* b) disabled: no STAGE ever — only the cache->fb BLIT (shipping path). */
static void test_no_stage_when_disabled(void)
{
    static uint8_t ring[64 * BLT_CMD_BYTES];
    static uint8_t heap[4096];
    blt_emitter_t e;
    blt_emitter_init(&e, ring, sizeof(ring), heap, sizeof(heap));
    blt_surface_ref_t bg = make_bg_handle();

    uint32_t off = 0;   /* cursor armed, but staging disabled -> must be ignored */
    active_frame_emit(&e, bg, /*stage_enabled=*/0, &off);

    blt_cmd_t first = ring_read(&e, 0);
    CHECK(first.opcode == BLT_OP_BLIT, "disabled: cmd[0] is BLIT (no STAGE)");
    CHECK(e.cmd_count == 1,            "disabled: exactly 1 command");
    CHECK(off == 0,                    "disabled: cursor untouched");
}

/* c) re-snapshot resets the cursor to 0 -> the sweep restarts from the start. */
static void test_restart_on_resnapshot(void)
{
    static uint8_t ring[64 * BLT_CMD_BYTES];
    static uint8_t heap[4096];
    blt_surface_ref_t bg = make_bg_handle();

    /* Run a few staging frames (partial sweep). */
    uint32_t off = 0;
    for (int i = 0; i < 3; ++i) {
        blt_emitter_t e;
        blt_emitter_init(&e, ring, sizeof(ring), heap, sizeof(heap));
        active_frame_emit(&e, bg, 1, &off);
    }
    CHECK(off == 3 * BG_STAGE_CHUNK, "partial sweep advanced 3 chunks");

    /* A re-snapshot (e.g. scroll cache exceeded MAXSHIFT) resets the cursor. */
    off = 0;
    blt_emitter_t e;
    blt_emitter_init(&e, ring, sizeof(ring), heap, sizeof(heap));
    active_frame_emit(&e, bg, 1, &off);
    blt_cmd_t s = ring_read(&e, 0);
    CHECK(s.opcode == BLT_OP_STAGE, "re-snapshot: STAGE emitted again");
    CHECK(s.src_off == BGCACHE_HEAP_OFF, "re-snapshot: sweep restarts at offset 0");
    CHECK(stage_size(&s) == BG_STAGE_CHUNK, "re-snapshot: first slice is a full chunk");
    CHECK(off == BG_STAGE_CHUNK, "re-snapshot: cursor advanced from 0");
}

int main(void)
{
    /* sanity on the constants this fix depends on */
    CHECK(BGCACHE_HEAP_OFF == 0x00EF8000u, "BGCACHE_HEAP_OFF == 0xEF8000");
    CHECK(CACHE_SIZE == 153600u,           "cache size == 153600 bytes");
    CHECK((BG_STAGE_CHUNK % 8u) == 0u,     "chunk is 8-byte aligned (beat granular)");

    test_chunked_sweep_enabled();
    test_no_stage_when_disabled();
    test_restart_on_resnapshot();

    if (failures == 0) { printf("ALL PASS\n"); return 0; }
    printf("%d FAILURE(S)\n", failures);
    return 1;
}
