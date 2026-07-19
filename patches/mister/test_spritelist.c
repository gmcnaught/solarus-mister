/* Stage 2 acceptance: executing N OP_BLITs and one OP_SPRITELIST covering the
 * same sprites must produce bit-identical framebuffers. GPL-3.0.
 *
 * Adapted from the task-2 brief to the REAL blitter_ref.h API: this codebase
 * has no blt_ref_ctx_t / blt_ref_init / blt_ref_blit convenience layer -- the
 * actual reference model is blt_execute(fb, heap, cmds, count) walking a
 * blt_cmd_t command list against a blt_surface_heap_t, exactly like the
 * existing test_tilelist_equals_n_blits() self-test in blitter_ref.c. Both
 * paths below go through blt_execute (not a bespoke helper call) so the test
 * exercises the SAME opcode dispatch + header decode the fabric will. The
 * assertion itself (bit-identical fb_a vs fb_b) is unchanged from the brief. */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "blitter_ref.h"
#include "blt_wire.h"

#define TEXW 32
#define TEXH 32

static uint16_t tex[TEXW * TEXH];
static uint16_t fb_a[BLT_FB_WIDTH * BLT_FB_HEIGHT];
static uint16_t fb_b[BLT_FB_WIDTH * BLT_FB_HEIGHT];

struct spr { uint16_t sx, sy, w, h; int16_t dx, dy; };

/* Deliberately overlapping so ORDER is observable in the output. */
static const struct spr SPR[] = {
    {  0,  0, 16, 16,  10,  10 },
    {  8,  8, 16, 16,  18,  14 },
    { 16,  0,  8,  8,  20,  20 },
    {  0, 16, 16,  8,  12,  24 },
    { 16, 16, 16, 16,   0,   0 },
};
#define NSPR ((int)(sizeof SPR / sizeof SPR[0]))

/* Heap for path B: the tileset pixels followed by the packed sprite-entry
 * array -- SAME convention as BLT_OP_TILELIST's own self-test in
 * blitter_ref.c (the entry array lives inside the SAME heap blt_execute is
 * given, at the header's dst_x|dst_y<<16 byte offset). */
static uint8_t heap_b_buf[sizeof(tex) + NSPR * 16];

int main(void)
{
    for (int i = 0; i < TEXW * TEXH; i++) tex[i] = (uint16_t)(i * 7 + 1);

    /* A: N individual OP_BLITs, in order, via blt_execute. */
    blt_surface_heap_t heap_a = { (const uint8_t *)tex, sizeof tex, 0, 0 };
    memset(fb_a, 0, sizeof fb_a);
    blt_cmd_t cmds_a[NSPR + 1];
    memset(cmds_a, 0, sizeof cmds_a);
    for (int i = 0; i < NSPR; i++) {
        cmds_a[i].opcode     = BLT_OP_BLIT;
        cmds_a[i].blend_mode = BLT_BLEND_COPY;
        cmds_a[i].format     = BLT_FMT_RGB565;
        cmds_a[i].src_off    = 0;
        cmds_a[i].src_stride = TEXW * 2;
        cmds_a[i].src_x = SPR[i].sx; cmds_a[i].src_y = SPR[i].sy;
        cmds_a[i].w     = SPR[i].w;  cmds_a[i].h     = SPR[i].h;
        cmds_a[i].dst_x = SPR[i].dx; cmds_a[i].dst_y = SPR[i].dy;
    }
    cmds_a[NSPR].opcode = BLT_OP_END;
    blt_execute(fb_a, &heap_a, cmds_a, NSPR + 1);

    /* B: one OP_SPRITELIST over the same sprites, same order. */
    memcpy(heap_b_buf, tex, sizeof tex);
    uint32_t entry_off = (uint32_t)sizeof tex;
    for (int i = 0; i < NSPR; i++) {
        blt_sprite_entry_t e = { 0, SPR[i].sx, SPR[i].sy, SPR[i].w, SPR[i].h,
                                 SPR[i].dx, SPR[i].dy };
        blt_pack_sprite_entry(heap_b_buf + entry_off + (size_t)i * 16, &e);
    }
    blt_surface_heap_t heap_b = { heap_b_buf, sizeof heap_b_buf, 0, 0 };
    memset(fb_b, 0, sizeof fb_b);
    blt_cmd_t cmds_b[2];
    memset(cmds_b, 0, sizeof cmds_b);
    cmds_b[0].opcode     = BLT_OP_SPRITELIST;
    cmds_b[0].blend_mode = BLT_BLEND_COPY;
    cmds_b[0].format     = BLT_FMT_RGB565;
    cmds_b[0].src_stride = TEXW * 2;
    cmds_b[0].src_x = 0; cmds_b[0].src_y = 0;              /* no bias */
    cmds_b[0].w = (uint16_t)(NSPR & 0xFFFF);
    cmds_b[0].h = (uint16_t)(NSPR >> 16);
    cmds_b[0].dst_x = (int16_t)(entry_off & 0xFFFFu);
    cmds_b[0].dst_y = (int16_t)(entry_off >> 16);
    cmds_b[1].opcode = BLT_OP_END;
    blt_execute(fb_b, &heap_b, cmds_b, 2);

    if (memcmp(fb_a, fb_b, sizeof fb_a) != 0) {
        for (int i = 0; i < BLT_FB_WIDTH * BLT_FB_HEIGHT; i++)
            if (fb_a[i] != fb_b[i]) {
                printf("FAIL: first diff at px %d (%d,%d): blits=%04x list=%04x\n",
                       i, i % BLT_FB_WIDTH, i / BLT_FB_WIDTH, fb_a[i], fb_b[i]);
                return 1;
            }
    }
    printf("ok: OP_SPRITELIST == %d x OP_BLIT (bit-exact framebuffer)\n", NSPR);
    return 0;
}
