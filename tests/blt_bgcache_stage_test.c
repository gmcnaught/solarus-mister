/* Host unit test for the bg-cache STAGE-on-snapshot sequence — issue #19.
 *
 * Models the engine-side behaviour added in mister_blitter_renderer.cpp:
 * the background cache is composited by the FABRIC straight into DDR3
 * (C_TARGET=2 -> OFF_BGCACHE) and never passes through blt_upload, so it is
 * NOT staged by the upload() path. On the first ACTIVE frame after a snapshot,
 * the renderer must emit blt_stage(off=BGCACHE_HEAP_OFF, size=FB_W*FB_H*2)
 * BEFORE the cache->fb blt_blit_copy, so the cache->fb read at C_SRCSEL=1
 * finds the real cache in SDRAM instead of zeros (the black-background bug).
 *
 * The renderer can't be unit-tested on the host (pulls in SDL/Solarus types),
 * so we model the exact emit sequence + the one-shot flag semantics:
 *   a) staging enabled, fresh snapshot -> STAGE(BGCACHE_HEAP_OFF, 153600)
 *      then the cache->fb BLIT; staged ONCE (flag cleared) so subsequent
 *      ACTIVE frames emit only the BLIT.
 *   b) staging disabled -> no STAGE, only the cache->fb BLIT (default,
 *      shipping behavior byte-identical).
 *   c) re-snapshot re-arms the flag -> STAGE emitted again.
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
#define CACHE_SIZE ((uint32_t)(FB_W * FB_H * 2))      /* 320*240*2 = 153600 */

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
 * stage_enabled && *needs_stage -> STAGE then clear flag; then cache->fb blit. */
static void active_frame_emit(blt_emitter_t *e, blt_surface_ref_t bg,
                              int stage_enabled, int *needs_stage)
{
    blt_begin_frame(e, 0, 0, 0);
    if (stage_enabled && *needs_stage) {
        blt_stage(e, BGCACHE_HEAP_OFF, CACHE_SIZE);
        *needs_stage = 0;
    }
    blt_blit_copy(e, bg, 0, 0);
}

/* a) staging enabled: STAGE(BGCACHE_HEAP_OFF,153600) precedes the cache BLIT,
 *    staged once; the next ACTIVE frame emits only the BLIT. */
static void test_stage_on_snapshot_enabled(void)
{
    static uint8_t ring[64 * BLT_CMD_BYTES];
    static uint8_t heap[4096];
    blt_emitter_t e;
    blt_emitter_init(&e, ring, sizeof(ring), heap, sizeof(heap));
    blt_surface_ref_t bg = make_bg_handle();

    int needs_stage = 1;   /* armed at SNAPSHOT->ACTIVE transition */

    /* First ACTIVE frame after the snapshot. */
    active_frame_emit(&e, bg, /*stage_enabled=*/1, &needs_stage);

    blt_cmd_t s = ring_read(&e, 0);
    blt_cmd_t b = ring_read(&e, 1);
    CHECK(s.opcode == BLT_OP_STAGE,   "cmd[0] is STAGE");
    CHECK(s.src_off == BGCACHE_HEAP_OFF, "STAGE.src_off == BGCACHE_HEAP_OFF");
    uint32_t sz = (uint32_t)s.w | ((uint32_t)s.h << 16);
    CHECK(sz == CACHE_SIZE,           "STAGE size == 153600 (320*240*2)");
    CHECK(b.opcode == BLT_OP_BLIT,    "cmd[1] is the cache->fb BLIT");
    CHECK(b.src_off == BGCACHE_HEAP_OFF, "BLIT reads the cache region");
    CHECK(e.cmd_count == 2,           "exactly STAGE + BLIT");
    CHECK(needs_stage == 0,           "flag cleared after staging (one-shot)");

    /* Second ACTIVE frame (no new snapshot): only the BLIT, no re-STAGE. */
    blt_emitter_init(&e, ring, sizeof(ring), heap, sizeof(heap));
    active_frame_emit(&e, bg, /*stage_enabled=*/1, &needs_stage);
    blt_cmd_t only = ring_read(&e, 0);
    CHECK(only.opcode == BLT_OP_BLIT, "steady ACTIVE: cmd[0] is BLIT (no STAGE)");
    CHECK(e.cmd_count == 1,           "steady ACTIVE: exactly 1 command");
}

/* b) staging disabled: no STAGE ever — only the cache->fb BLIT (shipping path). */
static void test_no_stage_when_disabled(void)
{
    static uint8_t ring[64 * BLT_CMD_BYTES];
    static uint8_t heap[4096];
    blt_emitter_t e;
    blt_emitter_init(&e, ring, sizeof(ring), heap, sizeof(heap));
    blt_surface_ref_t bg = make_bg_handle();

    int needs_stage = 1;   /* armed, but stage disabled -> must be ignored */
    active_frame_emit(&e, bg, /*stage_enabled=*/0, &needs_stage);

    blt_cmd_t first = ring_read(&e, 0);
    CHECK(first.opcode == BLT_OP_BLIT, "disabled: cmd[0] is BLIT (no STAGE)");
    CHECK(e.cmd_count == 1,            "disabled: exactly 1 command");
    /* Flag stays armed (only the enabled path clears it) — harmless, since it
     * is only consulted when stage_enabled. */
    CHECK(needs_stage == 1,            "disabled: flag untouched");
}

/* c) re-snapshot re-arms the flag -> STAGE emitted again on the next ACTIVE. */
static void test_restage_on_resnapshot(void)
{
    static uint8_t ring[64 * BLT_CMD_BYTES];
    static uint8_t heap[4096];
    blt_emitter_t e;
    blt_surface_ref_t bg = make_bg_handle();

    int needs_stage = 1;
    blt_emitter_init(&e, ring, sizeof(ring), heap, sizeof(heap));
    active_frame_emit(&e, bg, 1, &needs_stage);   /* stages once */
    CHECK(needs_stage == 0, "first snapshot staged");

    /* A re-snapshot (e.g. scroll cache exceeded MAXSHIFT) re-arms the flag. */
    needs_stage = 1;
    blt_emitter_init(&e, ring, sizeof(ring), heap, sizeof(heap));
    active_frame_emit(&e, bg, 1, &needs_stage);
    blt_cmd_t s = ring_read(&e, 0);
    CHECK(s.opcode == BLT_OP_STAGE, "re-snapshot: STAGE emitted again");
    uint32_t sz = (uint32_t)s.w | ((uint32_t)s.h << 16);
    CHECK(sz == CACHE_SIZE,         "re-snapshot: STAGE size correct");
    CHECK(needs_stage == 0,         "re-snapshot: flag cleared again");
}

int main(void)
{
    /* sanity on the constants this fix depends on */
    CHECK(BGCACHE_HEAP_OFF == 0x00EF8000u, "BGCACHE_HEAP_OFF == 0xEF8000");
    CHECK(CACHE_SIZE == 153600u,           "cache size == 153600 bytes");

    test_stage_on_snapshot_enabled();
    test_no_stage_when_disabled();
    test_restage_on_resnapshot();

    if (failures == 0) { printf("ALL PASS\n"); return 0; }
    printf("%d FAILURE(S)\n", failures);
    return 1;
}
