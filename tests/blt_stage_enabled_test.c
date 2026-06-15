/* Host unit test for the "upload then stage" sequence — issue #19 Task 3.
 *
 * Models the engine-side behaviour introduced in mister_blitter_renderer.cpp:
 * after a fresh blt_upload (or blt_upload_argb4444), when staging is enabled,
 * blt_stage() must be called with {h.off, h.size} so the ring contains a
 * STAGE command BEFORE the BLIT that consumes the handle.
 *
 * The renderer itself can't be unit-tested on the host (pulls in SDL/Solarus
 * types), so we exercise the emitter directly and verify:
 *   a) staging enabled  → STAGE in ring, correct off+size, precedes any BLIT
 *   b) staging disabled → no STAGE in ring, only BLIT present
 *   c) dirty-reupload   → STAGE again (re-stage after in-place refresh)
 *
 * Build+run (from repo root):
 *   cc -Wall -Wextra -O2 -I patches/mister/blitter \
 *       tests/blt_stage_enabled_test.c \
 *       patches/mister/blitter/blt_emitter.c \
 *       patches/mister/blitter/blt_alloc.c \
 *       -o /tmp/blt_stage_enabled_test && /tmp/blt_stage_enabled_test
 */
#include "blitter_ref.h"
#include "blt_emitter.h"
#include "blt_wire.h"
#include <stdio.h>
#include <stdint.h>
#include <string.h>

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

/* Simulate a freshly-uploaded pixel buffer (16bpp, 8x4 = 64 bytes). */
static const uint16_t fake_pixels[8 * 4] = {0};

/* 1. staging enabled: after upload → ring has STAGE at cmd[0], then BLIT at cmd[1].
 *    STAGE fields: src_off == handle.off, (w | h<<16) == handle.size. */
static void test_stage_on_upload_enabled(void)
{
    static uint8_t ring[16 * BLT_CMD_BYTES];
    static uint8_t heap[4096];
    blt_emitter_t e;
    blt_emitter_init(&e, ring, sizeof(ring), heap, sizeof(heap));
    blt_begin_frame(&e, 0, 0, 0);

    /* Upload a surface — the engine would call blt_upload then blt_stage. */
    blt_surface_ref_t h = blt_upload(&e, fake_pixels, 8, 4, 8 * 2);
    CHECK(h.valid,   "upload succeeded");

    /* Simulate the renderer: stage_enabled → emit STAGE right after upload. */
    int stage_rc = blt_stage(&e, h.off, h.size);
    CHECK(stage_rc == 0, "blt_stage returned 0 (success)");

    /* Then emit the blit that uses it. */
    int blit_rc = blt_blit_copy(&e, h, 10, 20);
    CHECK(blit_rc == 0, "blt_blit_copy returned 0 (success)");

    /* Ring must be: [0]=STAGE, [1]=BLIT */
    blt_cmd_t s = ring_read(&e, 0);
    blt_cmd_t b = ring_read(&e, 1);

    CHECK(s.opcode == BLT_OP_STAGE, "cmd[0] is STAGE");
    CHECK(s.src_off == h.off,       "STAGE.src_off == handle.off");
    uint32_t decoded_size = (uint32_t)s.w | ((uint32_t)s.h << 16);
    CHECK(decoded_size == h.size,   "STAGE size (w|h<<16) == handle.size");

    CHECK(b.opcode == BLT_OP_BLIT, "cmd[1] is BLIT");
    CHECK(b.src_off == h.off,      "BLIT.src_off == handle.off");

    /* Verify ordering: STAGE before BLIT (cmd[0] < cmd[1] implicitly by position). */
    CHECK(e.cmd_count == 2, "exactly 2 commands emitted (STAGE + BLIT)");
    CHECK(e.overflow == 0,  "no overflow");
}

/* 2. staging disabled: only the BLIT is emitted, no STAGE. */
static void test_no_stage_when_disabled(void)
{
    static uint8_t ring[16 * BLT_CMD_BYTES];
    static uint8_t heap[4096];
    blt_emitter_t e;
    blt_emitter_init(&e, ring, sizeof(ring), heap, sizeof(heap));
    blt_begin_frame(&e, 0, 0, 0);

    blt_surface_ref_t h = blt_upload(&e, fake_pixels, 8, 4, 8 * 2);
    CHECK(h.valid, "upload succeeded");

    /* stage_enabled==false: renderer does NOT call blt_stage here. */

    int blit_rc = blt_blit_copy(&e, h, 0, 0);
    CHECK(blit_rc == 0, "blt_blit_copy succeeded");

    blt_cmd_t first = ring_read(&e, 0);
    CHECK(first.opcode == BLT_OP_BLIT, "cmd[0] is BLIT (no STAGE emitted)");
    CHECK(e.cmd_count == 1,            "exactly 1 command (no STAGE)");
}

/* 3. dirty re-upload (reupload_in_place path): re-stage after the in-place refresh.
 *    Simulated by: upload, emit blit, then simulate a new frame where the surface
 *    is dirty — re-copy pixels into the heap slot and emit STAGE again. */
static void test_stage_on_reupload(void)
{
    static uint8_t ring[16 * BLT_CMD_BYTES];
    static uint8_t heap[4096];
    blt_emitter_t e;
    blt_emitter_init(&e, ring, sizeof(ring), heap, sizeof(heap));

    /* Frame 0: fresh upload + stage + blit. */
    blt_begin_frame(&e, 0, 0, 0);
    blt_surface_ref_t h = blt_upload(&e, fake_pixels, 8, 4, 8 * 2);
    CHECK(h.valid, "frame0: upload valid");
    blt_stage(&e, h.off, h.size);   /* staging enabled */
    blt_blit_copy(&e, h, 0, 0);
    blt_end_frame(&e);

    /* Frame 1: surface is "dirty" → reupload_in_place + re-stage + blit. */
    blt_begin_frame(&e, 0, 0, 0);

    /* Simulate reupload_in_place: overwrite the heap slot in place (same off/size). */
    memcpy(e.heap + h.off, fake_pixels, (size_t)h.w * h.h * 2u);

    /* Then re-stage (as the renderer now does when staging is enabled). */
    int rc = blt_stage(&e, h.off, h.size);
    CHECK(rc == 0, "frame1 re-stage: returned 0");

    /* Then emit the blit. */
    blt_blit_copy(&e, h, 0, 0);

    blt_cmd_t s = ring_read(&e, 0);
    blt_cmd_t b = ring_read(&e, 1);

    CHECK(s.opcode == BLT_OP_STAGE, "frame1 cmd[0] is STAGE (re-stage)");
    CHECK(s.src_off == h.off,       "frame1 STAGE.src_off correct");
    uint32_t sz = (uint32_t)s.w | ((uint32_t)s.h << 16);
    CHECK(sz == h.size,             "frame1 STAGE size correct");
    CHECK(b.opcode == BLT_OP_BLIT, "frame1 cmd[1] is BLIT");
    CHECK(e.cmd_count == 2,        "frame1: exactly 2 commands (STAGE + BLIT)");
}

/* 4. ARGB4444 upload with staging. */
static void test_stage_argb4444(void)
{
    static uint8_t ring[16 * BLT_CMD_BYTES];
    static uint8_t heap[4096];
    blt_emitter_t e;
    blt_emitter_init(&e, ring, sizeof(ring), heap, sizeof(heap));
    blt_begin_frame(&e, 0, 0, 0);

    blt_surface_ref_t h = blt_upload_argb4444(&e, fake_pixels, 8, 4, 8 * 2);
    CHECK(h.valid,                        "argb4444 upload valid");
    CHECK(h.format == BLT_FMT_ARGB4444,  "handle format is ARGB4444");

    blt_stage(&e, h.off, h.size);   /* staging enabled */
    blt_blit(&e, h, 0, 0, 8, 4, 0, 0, BLT_BLEND_PALPHA, 0, 0, 0);

    blt_cmd_t s = ring_read(&e, 0);
    CHECK(s.opcode == BLT_OP_STAGE, "ARGB4444: STAGE emitted");
    CHECK(s.src_off == h.off,       "ARGB4444: STAGE.src_off correct");
    uint32_t sz = (uint32_t)s.w | ((uint32_t)s.h << 16);
    CHECK(sz == h.size,             "ARGB4444: STAGE size correct");
}

int main(void)
{
    test_stage_on_upload_enabled();
    test_no_stage_when_disabled();
    test_stage_on_reupload();
    test_stage_argb4444();

    if (failures == 0) { printf("ALL PASS\n"); return 0; }
    printf("%d FAILURE(S)\n", failures);
    return 1;
}
