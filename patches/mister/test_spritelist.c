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
 * assertion itself (bit-identical fb_a vs fb_b) is unchanged from the brief.
 *
 * [defect fix -- code review] OP_SPRITELIST's DEFINING feature versus
 * OP_TILELIST is that src_off travels PER ENTRY (sprites come from many
 * different sprite sheets; a tile layer comes from one shared tileset). The
 * original version of this test set src_off=0 on every entry, so a reviewer
 * was able to slip a byte-order bug into blt_ref_sprite_list's src_off decode
 * and this test still passed -- 0 reversed is still 0. Fixed by placing TWO
 * distinct source textures, with visibly different pixel content, at two
 * distinct nonzero, non-palindromic-byte offsets in the heap, and having
 * CONSECUTIVE sprite entries alternate between them. See OFF_TEXA/OFF_TEXB
 * below for why those specific offsets were chosen. */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "blitter_ref.h"
#include "blt_wire.h"
#include "blt_emitter.h"   /* [Task 3] blt_sprite_list_init / blt_sprite_list */

#define TEXW 32
#define TEXH 32
#define TEXBYTES (TEXW * TEXH * 2)   /* 2048 bytes per texture */

/* Two distinct source textures, each placed at a distinct, nonzero, byte
 * offset into the heap. Chosen so that:
 *   - neither offset is 0 (a mis-decode of 0 is indistinguishable from 0);
 *   - the little-endian byte tuple of each is NOT a palindrome, so a
 *     byte-reversal decode bug does not accidentally reproduce the same
 *     value;
 *   - each offset's low bytes are nonzero while its high bytes are zero, so
 *     a full byte-order reversal moves a nonzero byte into bit[31:24],
 *     producing a value in the hundreds-of-millions -- guaranteed to fall
 *     out of this (~32KB) heap and get clamped to 0 by heap_px16's
 *     model-safety check, i.e. a mis-decode reliably reads the WRONG data
 *     (garbage/zero) rather than coincidentally landing back in range. */
#define OFF_TEXA 0x00003412u   /* bytes LE: 12 34 00 00 -- reversed: 0x12340000 (OOB) */
#define OFF_TEXB 0x00007856u   /* bytes LE: 56 78 00 00 -- reversed: 0x56780000 (OOB) */

static uint16_t texA[TEXW * TEXH];
static uint16_t texB[TEXW * TEXH];
static uint16_t fb_a[BLT_FB_WIDTH * BLT_FB_HEIGHT];
static uint16_t fb_b[BLT_FB_WIDTH * BLT_FB_HEIGHT];

struct spr { uint16_t sx, sy, w, h; int16_t dx, dy; uint32_t off; };

/* Deliberately overlapping so ORDER is observable in the output. Also
 * deliberately ALTERNATING src_off (texA/texB) between every consecutive
 * entry, so a wrong per-entry src_off decode changes the sourced pixels for
 * (at least) most of the sprites, not just a coincidental subset. */
static const struct spr SPR[] = {
    {  0,  0, 16, 16,  10,  10, OFF_TEXA },
    {  8,  8, 16, 16,  18,  14, OFF_TEXB },
    { 16,  0,  8,  8,  20,  20, OFF_TEXA },
    {  0, 16, 16,  8,  12,  24, OFF_TEXB },
    { 16, 16, 16, 16,   0,   0, OFF_TEXA },
};
#define NSPR ((int)(sizeof SPR / sizeof SPR[0]))

/* Combined texture region: both textures copied in at their real (nonzero)
 * byte offsets, matching what a real src_off decode must dereference. */
#define TEXREGION_BYTES (OFF_TEXB + TEXBYTES)

/* Path A's heap: just the two textures (no entry array needed -- each BLIT
 * command carries its own src_off directly). */
static uint8_t heap_a_buf[TEXREGION_BYTES];

/* Path B's heap: the two textures (SAME layout/offsets as path A) followed by
 * the packed sprite-entry array -- same convention as BLT_OP_TILELIST's own
 * self-test in blitter_ref.c (the entry array lives inside the SAME heap
 * blt_execute is given, at the header's dst_x|dst_y<<16 byte offset). */
static uint8_t heap_b_buf[TEXREGION_BYTES + NSPR * 16];

int main(void)
{
    /* Two VISIBLY DIFFERENT pixel patterns -- sourcing from the wrong
     * texture changes the framebuffer, it isn't just a different-looking
     * no-op. */
    for (int i = 0; i < TEXW * TEXH; i++) texA[i] = (uint16_t)(i * 7 + 1);
    for (int i = 0; i < TEXW * TEXH; i++) texB[i] = (uint16_t)(0x8000u ^ (i * 13u + 4096u));

    /* A: N individual OP_BLITs, in order, via blt_execute -- each entry's
     * src_off matches its SPR[] slot's texture, exactly like path B's
     * per-entry src_off must. */
    memset(heap_a_buf, 0, sizeof heap_a_buf);
    memcpy(heap_a_buf + OFF_TEXA, texA, sizeof texA);
    memcpy(heap_a_buf + OFF_TEXB, texB, sizeof texB);
    blt_surface_heap_t heap_a = { heap_a_buf, sizeof heap_a_buf, 0, 0 };
    memset(fb_a, 0, sizeof fb_a);
    blt_cmd_t cmds_a[NSPR + 1];
    memset(cmds_a, 0, sizeof cmds_a);
    for (int i = 0; i < NSPR; i++) {
        cmds_a[i].opcode     = BLT_OP_BLIT;
        cmds_a[i].blend_mode = BLT_BLEND_COPY;
        cmds_a[i].format     = BLT_FMT_RGB565;
        cmds_a[i].src_off    = SPR[i].off;
        cmds_a[i].src_stride = TEXW * 2;
        cmds_a[i].src_x = SPR[i].sx; cmds_a[i].src_y = SPR[i].sy;
        cmds_a[i].w     = SPR[i].w;  cmds_a[i].h     = SPR[i].h;
        cmds_a[i].dst_x = SPR[i].dx; cmds_a[i].dst_y = SPR[i].dy;
    }
    cmds_a[NSPR].opcode = BLT_OP_END;
    blt_execute(fb_a, &heap_a, cmds_a, NSPR + 1);

    /* B: one OP_SPRITELIST over the same sprites, same order, each entry
     * carrying its OWN src_off (the feature under test). */
    memset(heap_b_buf, 0, sizeof heap_b_buf);
    memcpy(heap_b_buf + OFF_TEXA, texA, sizeof texA);
    memcpy(heap_b_buf + OFF_TEXB, texB, sizeof texB);
    uint32_t entry_off = (uint32_t)TEXREGION_BYTES;
    for (int i = 0; i < NSPR; i++) {
        blt_sprite_entry_t e = { SPR[i].off, SPR[i].sx, SPR[i].sy, SPR[i].w, SPR[i].h,
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
    printf("ok: OP_SPRITELIST == %d x OP_BLIT (bit-exact framebuffer, 2 distinct textures, "
           "alternating per-entry src_off)\n", NSPR);

    /* [Task 3] Emitter: header packing round-trips through the reference walker.
     * Adapted from the task-3 brief's snippet -- the real blt_begin_frame takes
     * 3 args (target_buf, clear, clear_color), not 5; the brief's 5-arg call
     * does not match this codebase's blt_emitter.h (stale, written before this
     * signature was set by earlier tasks on this branch).
     *
     * [defect fix -- code review] The original version of this block passed
     * entry_off=0, bias_x=0, bias_y=0 and asserted only eoff==0. Zero packs
     * to zero regardless of byte order or which struct field lands in which
     * wire slot, so a reviewer mutation (swapping c.dst_x/c.dst_y in
     * blt_sprite_list, or swapping c.src_x/c.src_y) still passed. Fixed by
     * using a nonzero, asymmetric entry_off (low/high halves differ) and
     * asymmetric, oppositely-signed biases, then asserting all three decode
     * back to exactly what was passed -- a swap or wrong shift now changes
     * the decoded value. */
    {
        blt_emitter_t e;
        static uint8_t ring[BLT_CMD_BYTES * 16];
        static uint8_t spb[NSPR * 16];
        blt_emitter_init(&e, ring, sizeof ring, NULL, 0);
        blt_sprite_list_init(&e, spb, sizeof spb);
        blt_begin_frame(&e, 0, 0, 0);
        for (int i = 0; i < NSPR; i++) {
            blt_sprite_entry_t se = { 0, SPR[i].sx, SPR[i].sy, SPR[i].w, SPR[i].h,
                                      SPR[i].dx, SPR[i].dy };
            blt_pack_sprite_entry(spb + i * 16, &se);
        }
        e.sp_used = NSPR * 16;
        /* entry_off: low16=0xABCD, high16=0x0002 -- distinct, so a dst_x/dst_y
         * swap (or wrong shift) produces a different decoded value, not a
         * coincidental match. bias_x/bias_y: different magnitudes, one
         * negative, so a src_x/src_y swap or a sign-handling bug is visible. */
        const uint32_t TEST_ENTRY_OFF = 0x0002ABCDu;
        const int16_t  TEST_BIAS_X    = (int16_t)-7;
        const int16_t  TEST_BIAS_Y    = (int16_t)300;
        if (blt_sprite_list(&e, TEXW * 2, BLT_FMT_RGB565, BLT_BLEND_COPY,
                            0, 255, 0, TEST_ENTRY_OFF, NSPR,
                            TEST_BIAS_X, TEST_BIAS_Y) != 0) {
            printf("FAIL: blt_sprite_list returned error\n"); return 1;
        }
        if (e.cmd_count != 1) {
            printf("FAIL: expected 1 command, got %d\n", e.cmd_count); return 1;
        }
        /* Decode the emitted header back and check every field round-trips,
         * not just cmd_count -- this is what actually proves the emitter's
         * w|h<<16 / dst_x|dst_y<<16 packing (identical convention to
         * BLT_OP_TILELIST) is correct. */
        blt_cmd_t c; blt_unpack_cmd(ring, &c);
        if (c.opcode != BLT_OP_SPRITELIST) {
            printf("FAIL: opcode %u exp %u\n", c.opcode, BLT_OP_SPRITELIST); return 1;
        }
        if (c.blend_mode != BLT_BLEND_COPY || c.format != BLT_FMT_RGB565) {
            printf("FAIL: blend/format %u/%u exp COPY/RGB565\n", c.blend_mode, c.format);
            return 1;
        }
        if (c.src_stride != TEXW * 2) {
            printf("FAIL: src_stride %u exp %d\n", c.src_stride, TEXW * 2); return 1;
        }
        uint32_t n = (uint32_t)c.w | ((uint32_t)c.h << 16);
        if (n != (uint32_t)NSPR) {
            printf("FAIL: entry count %u exp %d\n", n, NSPR); return 1;
        }
        uint32_t eoff = (uint32_t)(uint16_t)c.dst_x | ((uint32_t)(uint16_t)c.dst_y << 16);
        if (eoff != TEST_ENTRY_OFF) {
            printf("FAIL: entry_off 0x%08x exp 0x%08x\n", eoff, TEST_ENTRY_OFF); return 1;
        }
        int16_t bias_x = (int16_t)c.src_x;
        int16_t bias_y = (int16_t)c.src_y;
        if (bias_x != TEST_BIAS_X) {
            printf("FAIL: bias_x %d exp %d\n", bias_x, TEST_BIAS_X); return 1;
        }
        if (bias_y != TEST_BIAS_Y) {
            printf("FAIL: bias_y %d exp %d\n", bias_y, TEST_BIAS_Y); return 1;
        }
        printf("ok: emitter packs one OP_SPRITELIST for %d sprites "
               "(entry_off=0x%08x bias_x=%d bias_y=%d)\n",
               NSPR, eoff, bias_x, bias_y);
    }

    /* [Task 4] Run grouping: a change of ANY shared header field must start a NEW
     * list. Runs stay in emission order, so Z-order is preserved. */
    {
        blt_sprite_run_key_t K[5] = {
            { 64, BLT_FMT_RGB565,   BLT_BLEND_COPY,   255, 0, 0 },
            { 64, BLT_FMT_RGB565,   BLT_BLEND_COPY,   255, 0, 0 },
            { 64, BLT_FMT_RGB565,   BLT_BLEND_PALPHA, 255, 0, 0 }, /* break: blend  */
            { 128, BLT_FMT_RGB565,  BLT_BLEND_PALPHA, 255, 0, 0 }, /* break: stride */
            { 128, BLT_FMT_RGB565,  BLT_BLEND_PALPHA, 255, 0, 0 },
        };
        int runs = 1;
        for (int i = 1; i < 5; i++)
            if (blt_sprite_run_key_differs(&K[i], &K[i-1])) runs++;
        if (runs != 3) { printf("FAIL: expected 3 runs, got %d\n", runs); return 1; }

        /* Identical keys must NOT break a run (guards a comparator that always differs). */
        if (blt_sprite_run_key_differs(&K[0], &K[1])) {
            printf("FAIL: identical keys reported as different\n"); return 1;
        }
        /* Every field must participate -- a comparator ignoring one would silently merge
         * incompatible sprites into one batch and corrupt the frame. */
        for (int f = 0; f < 6; f++) {
            blt_sprite_run_key_t a = K[0], b = K[0];
            switch (f) {
            case 0: b.src_stride ^= 0x10; break;
            case 1: b.format     ^= 1;    break;
            case 2: b.blend      ^= 1;    break;
            case 3: b.alpha      ^= 1;    break;
            case 4: b.colorkey   ^= 1;    break;
            case 5: b.flags      ^= 1;    break;
            }
            if (!blt_sprite_run_key_differs(&a, &b)) {
                printf("FAIL: run key ignores field %d\n", f); return 1;
            }
        }
        printf("ok: run key breaks on every shared field (%d runs)\n", runs);
    }

    /* [Task 4] Cap: overflow drops the TAIL (keeping the earliest sprites) and counts
     * drops. The buffer deliberately holds EIGHT entries while cap is FOUR, so the
     * ENTRY cap -- not the byte capacity -- is what stops the push. (Sizing the buffer
     * to exactly the cap let an init that ignored its `cap` argument survive.) */
    {
        blt_sprite_channel_t ch;
        static uint8_t spb[8 * 16];
        memset(spb, 0xEE, sizeof spb);
        blt_sprite_channel_init(&ch, spb, sizeof spb, /*cap=*/4);
        blt_sprite_run_key_t k = { 64, BLT_FMT_RGB565, BLT_BLEND_COPY, 255, 0, 0 };
        int accepted = 0;
        for (int i = 0; i < 7; i++) {
            blt_sprite_entry_t e = { 0, 0, 0, 8, 8, (int16_t)(10 + i), (int16_t)(20 + i) };
            if (blt_sprite_channel_push(&ch, &k, &e)) accepted++;
        }
        if (accepted != 4)   { printf("FAIL: accepted %d, want 4\n", accepted);  return 1; }
        if (ch.dropped != 3) { printf("FAIL: dropped %u, want 3\n", ch.dropped); return 1; }
        if (ch.count != 4)   { printf("FAIL: count %d, want 4\n", ch.count);     return 1; }
        /* The TAIL is dropped, so slots 0..3 must still hold entries 0..3 IN ORDER --
         * this is the Z-order guarantee. A FIFO/ring that evicted the head would leave
         * entries 3..6 here instead. Check dst_x/dst_y of every surviving slot. */
        for (int i = 0; i < 4; i++) {
            int dx = (int16_t)((uint16_t)spb[i*16+12] | ((uint16_t)spb[i*16+13] << 8));
            int dy = (int16_t)((uint16_t)spb[i*16+14] | ((uint16_t)spb[i*16+15] << 8));
            if (dx != 10 + i || dy != 20 + i) {
                printf("FAIL: slot %d holds dst=(%d,%d), want (%d,%d) -- order not preserved\n",
                       i, dx, dy, 10 + i, 20 + i);
                return 1;
            }
        }
        /* Slot 4 must be UNTOUCHED (0xEE fill): a refused push must not write past count. */
        if (spb[4*16] != 0xEE) { printf("FAIL: refused push wrote past the cap\n"); return 1; }
        /* The channel must RETAIN each pushed key -- flush splits runs by reading these,
         * so a push that packed the entry but dropped the key would batch everything
         * under a stale header. */
        for (int i = 0; i < ch.count; i++) {
            if (blt_sprite_run_key_differs(&ch.keys[i], &k)) {
                printf("FAIL: key %d not retained by push\n", i); return 1;
            }
        }
        printf("ok: cap keeps head, drops tail, retains keys (%d accepted, %u dropped)\n",
               accepted, ch.dropped);
    }

    /* [Task 4] The BYTE capacity is a second, independent limit: a cap that the buffer
     * cannot physically hold must still refuse rather than overrun SP_BUF. */
    {
        blt_sprite_channel_t ch;
        static uint8_t spb2[2 * 16 + 8];       /* room for 2 entries, not 3 */
        blt_sprite_channel_init(&ch, spb2, sizeof spb2, /*cap=*/16);
        blt_sprite_run_key_t k = { 64, BLT_FMT_RGB565, BLT_BLEND_COPY, 255, 0, 0 };
        int accepted = 0;
        for (int i = 0; i < 5; i++) {
            blt_sprite_entry_t e = { 0, 0, 0, 8, 8, (int16_t)i, (int16_t)i };
            if (blt_sprite_channel_push(&ch, &k, &e)) accepted++;
        }
        if (accepted != 2)   { printf("FAIL: byte-cap accepted %d, want 2\n", accepted);  return 1; }
        if (ch.dropped != 3) { printf("FAIL: byte-cap dropped %u, want 3\n", ch.dropped); return 1; }
        printf("ok: byte capacity refuses independently of the entry cap (%d accepted)\n",
               accepted);
    }

    /* [Task 4] reset() clears the batch but NOT the diagnostic drop accumulator. */
    {
        blt_sprite_channel_t ch;
        static uint8_t spb3[4 * 16];
        blt_sprite_channel_init(&ch, spb3, sizeof spb3, /*cap=*/2);
        blt_sprite_run_key_t k = { 64, BLT_FMT_RGB565, BLT_BLEND_COPY, 255, 0, 0 };
        blt_sprite_entry_t e = { 0, 0, 0, 8, 8, 1, 1 };
        for (int i = 0; i < 3; i++) blt_sprite_channel_push(&ch, &k, &e);
        if (ch.count != 2 || ch.dropped != 1) {
            printf("FAIL: pre-reset count=%d dropped=%u\n", ch.count, ch.dropped); return 1;
        }
        blt_sprite_channel_reset(&ch);
        if (ch.count != 0)   { printf("FAIL: reset left count=%d\n", ch.count);       return 1; }
        if (ch.dropped != 1) { printf("FAIL: reset cleared dropped=%u\n", ch.dropped); return 1; }
        /* ...and the channel is reusable after reset. */
        if (!blt_sprite_channel_push(&ch, &k, &e)) { printf("FAIL: unusable after reset\n"); return 1; }
        printf("ok: reset clears the batch, keeps the drop accumulator\n");
    }

    return 0;
}
