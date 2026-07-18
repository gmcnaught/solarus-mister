/* Models the Stage 1 overlay emit contract against the REAL emitter.
 * The overlay composite must be the LAST command in the frame, full-screen at
 * (0,0), PALPHA over ARGB4444 -- and must be absent when the root was never
 * painted. Mirrors Impl::emit_overlay_composite(); the renderer itself is not
 * compiled by host tests. */
#include "blitter_ref.h"
#include "blt_emitter.h"
#include "blt_wire.h"
#include <stdio.h>
#include <string.h>

static int failures = 0;
#define CHECK(c,m) do{ if(!(c)){ printf("FAIL: %s (line %d)\n", m, __LINE__); failures++; } }while(0)

#define FB_W 320
#define FB_H 240

/* Decode the nth command from the ring. */
static blt_cmd_t ring_read(const blt_emitter_t *e, int n)
{
    blt_cmd_t c;
    memset(&c, 0, sizeof(c));
    blt_unpack_cmd(e->ring + (size_t)n * BLT_CMD_BYTES, &c);
    return c;
}

/* Model of Impl::emit_overlay_composite(): composite iff the root was painted. */
static void emit_overlay_composite(blt_emitter_t *e, blt_surface_ref_t root,
                                   int overlay_enabled, int overlay_touched)
{
    if (!overlay_enabled || !overlay_touched) return;
    if (!root.valid) return;
    blt_blit(e, root, 0, 0, FB_W, FB_H, 0, 0, BLT_BLEND_PALPHA, 0, 255, 0);
}

static uint8_t ring[64 * BLT_CMD_BYTES];
static uint8_t heap[512 * 1024];
static uint16_t overlay_px[FB_W * FB_H];

/* Emit `nworld` world blits, then the overlay. Returns the emitter by pointer. */
static void run_frame(blt_emitter_t *e, int nworld, int enabled, int touched,
                      blt_surface_ref_t *out_root)
{
    blt_emitter_init(e, ring, sizeof(ring), heap, sizeof(heap));
    blt_begin_frame(e, 0, 0, 0);

    blt_surface_ref_t root =
        blt_upload_argb4444(e, overlay_px, FB_W, FB_H, FB_W * 2);
    CHECK(root.valid, "overlay upload succeeds");
    CHECK(root.format == BLT_FMT_ARGB4444, "overlay handle tagged ARGB4444");

    for (int i = 0; i < nworld; i++)
        blt_fill(e, i * 8, 0, 8, 8, 0x1234);

    emit_overlay_composite(e, root, enabled, touched);
    *out_root = root;
}

static void test_overlay_is_last(void)
{
    blt_emitter_t e; blt_surface_ref_t root;
    run_frame(&e, 3, 1, 1, &root);

    CHECK(e.cmd_count == 4, "3 world fills + 1 overlay blit");
    CHECK(e.overflow == 0,  "no ring overflow");

    for (int i = 0; i < 3; i++)
        CHECK(ring_read(&e, i).opcode == BLT_OP_FILL, "world commands come first");

    blt_cmd_t ov = ring_read(&e, e.cmd_count - 1);
    CHECK(ov.opcode     == BLT_OP_BLIT,      "overlay is the LAST command");
    CHECK(ov.blend_mode == BLT_BLEND_PALPHA, "overlay uses per-pixel alpha");
    CHECK(ov.format     == BLT_FMT_ARGB4444, "overlay source is ARGB4444");
    CHECK(ov.w == FB_W && ov.h == FB_H,      "overlay is full-screen");
    CHECK(ov.dst_x == 0 && ov.dst_y == 0,    "overlay lands at (0,0)");
    CHECK(ov.src_x == 0 && ov.src_y == 0,    "overlay reads from the surface origin");
}

static void test_absent_when_untouched(void)
{
    blt_emitter_t e; blt_surface_ref_t root;
    run_frame(&e, 3, 1, 0, &root);          /* enabled, but root never painted */
    CHECK(e.cmd_count == 3, "no overlay command when the root was not painted");
    for (int i = 0; i < e.cmd_count; i++)
        CHECK(ring_read(&e, i).opcode == BLT_OP_FILL, "only world commands present");
}

static void test_absent_when_disabled(void)
{
    blt_emitter_t e; blt_surface_ref_t root;
    run_frame(&e, 3, 0, 1, &root);          /* flag off: must be inert */
    CHECK(e.cmd_count == 3, "no overlay command when SOLARUS_OVERLAY is off");
}

int main(void)
{
    test_overlay_is_last();
    test_absent_when_untouched();
    test_absent_when_disabled();
    printf(failures ? "FAILED (%d)\n" : "ok overlay_emit (last, full-screen, PALPHA)\n", failures);
    return failures ? 1 : 0;
}
