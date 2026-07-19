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
static uint8_t heap_b_buf[TEXREGION_BYTES + NSPR * BLT_SPRITE_ENTRY_BYTES];

/* ── [Task 4b] PAL8 fixtures ────────────────────────────────────────────────
 * 220/220 of the quest's sprite sheets are paletted, so the per-entry palette
 * is the difference between OP_SPRITELIST carrying every sprite and carrying
 * none. Two entries in ONE list with DIFFERENT (pal_id, base_off) must paint
 * exactly as two OP_BLITs with those same palettes in their header colour. */
#define PTEXW 16
#define PTEXH 16
#define OFF_PALTEX 0x00001234u              /* nonzero, non-palindromic LE bytes */
#define PAL_HEAP_TEX (OFF_PALTEX + PTEXW * PTEXH)
#define NPSPR 2
static uint8_t  pal_heap_a[PAL_HEAP_TEX];
static uint8_t  pal_heap_b[PAL_HEAP_TEX + NPSPR * BLT_SPRITE_ENTRY_BYTES];
static uint8_t  clut_buf[BLT_CLUT_BANKS * BLT_CLUT_ENTRIES * 4];
static uint16_t fb_pa[BLT_FB_WIDTH * BLT_FB_HEIGHT];
static uint16_t fb_pb[BLT_FB_WIDTH * BLT_FB_HEIGHT];

/* Two DIFFERENT banks AND different base offsets, so both halves of the packed
 * colour word are load-bearing: a swap of the pal_id/base_off bytes selects a
 * different bank and a different slot, hence different pixels. */
static const struct { uint8_t bank, base; int16_t dx, dy; } PSPR[NPSPR] = {
    {  3, 0x00, 40, 50 },
    { 11, 0x05, 60, 70 },
};

/* ── [Task 4b] PAL8 ABSOLUTE (golden-value) fixtures ────────────────────────
 * The equivalence test above runs BOTH sides through the same blit_one, so it
 * is blind to any mutation of the CLUT semantics THEMSELVES (a review found two
 * that escaped it: replacing the {a4,a4} alpha replication with a4<<4, and
 * dropping the &0xFF slot wrap). These fixtures pin the semantics against
 * literals derived BY HAND from the RTL:
 *   fpga/rtl/comp_pipeline.sv
 *     :180  clut_rd_addr = {c_pal_id[4:0], (lb_serve_pix[7:0] + c_base_off)}
 *           -- the slot adder is 8 BITS WIDE, so index+base_off WRAPS mod 256
 *           and never carries into the bank field. => (idx+base)&0xFF.
 *     :558-559 pal_rgb = clut_rd_data[15:0], pal_a4 = clut_rd_data[19:16]
 *     :568  s3_skip_eff = PAL8 ? (s3_palpha && pal_a4==0) : s3_skip
 *     :894  mx_in_alpha <= (PAL8 && palpha) ? {pal_a4_s3, pal_a4_s3} : c_alpha
 *   fpga/rtl/comp_mixer.sv
 *     :86-90 COMP_CA -> ARITH_CA with stA_alpha = in_alpha
 *     :183-188 out_ch = ((t+128) + ((t+128)>>8)) >> 8, t = s*a + d*(255-a)
 *   fpga/rtl/comp_clut.vh  entry = {A4[19:16], RGB565[15:0]}
 * Every expected pixel below was computed from those equations, NOT by running
 * the model under test. */
#define OFF_GOLDTEX 0x00000100u
/* index row at +0, sprite entries at +32 (8 entries max, 24 B each) */
#define GOLD_HEAP   (OFF_GOLDTEX + 32u + 8u * BLT_SPRITE_ENTRY_BYTES)
static uint8_t  gold_heap[GOLD_HEAP];
static uint8_t  gold_clut[BLT_CLUT_BANKS * BLT_CLUT_ENTRIES * 4];
static uint16_t fb_gold[BLT_FB_WIDTH * BLT_FB_HEIGHT];

/* Pre-fill colour: all three channels distinct and NONZERO (dr=10, dg=20,
 * db=30), so "destination unchanged" is a real assertion and so a wrong alpha
 * perturbs every channel. (10<<11)|(20<<5)|30 == 0x529E. */
#define GOLD_DST 0x529Eu

static void gold_clut_put(unsigned bank, unsigned slot, unsigned a4, uint16_t rgb)
{
    uint32_t w  = ((uint32_t)(a4 & 0xFu) << 16) | rgb;   /* comp_clut.vh CLUT_MAKE */
    uint8_t *d  = gold_clut + ((size_t)bank * BLT_CLUT_ENTRIES + slot) * 4u;
    d[0] = (uint8_t)w; d[1] = (uint8_t)(w >> 8);
    d[2] = (uint8_t)(w >> 16); d[3] = (uint8_t)(w >> 24);
}

int main(void)
{
    /* The entry is 24 bytes = 3 qwords ON PURPOSE: the fabric fetches whole
     * aligned qwords, so a non-multiple-of-8 entry would force the barrel-shift
     * extraction the 12-byte tile entry needs. Assert both the struct size and
     * the wire constant the emitter/channel/model all stride by. */
    if (sizeof(blt_sprite_entry_t) != 24) {
        printf("FAIL: sizeof(blt_sprite_entry_t)=%u exp 24\n",
               (unsigned)sizeof(blt_sprite_entry_t));
        return 1;
    }
    if (BLT_SPRITE_ENTRY_BYTES != 24 ||
        BLT_SPRITE_ENTRY_BYTES != (int)sizeof(blt_sprite_entry_t)) {
        printf("FAIL: BLT_SPRITE_ENTRY_BYTES=%d exp 24 == sizeof(entry)\n",
               (int)BLT_SPRITE_ENTRY_BYTES);
        return 1;
    }

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
    blt_surface_heap_t heap_a = { heap_a_buf, sizeof heap_a_buf, 0, 0, 0 };
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
                                 SPR[i].dx, SPR[i].dy, 0, 0, 0 };
        blt_pack_sprite_entry(heap_b_buf + entry_off + (size_t)i * BLT_SPRITE_ENTRY_BYTES, &e);
    }
    blt_surface_heap_t heap_b = { heap_b_buf, sizeof heap_b_buf, 0, 0, 0 };
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

    /* ── [Task 4b] PAL8: the palette travels PER ENTRY ──────────────────────
     * A tile layer is one tileset = one palette, so OP_TILELIST can keep the
     * palette in its header. Sprites are Y-sorted across many sheets, so two
     * consecutive entries of the SAME list routinely need different palettes.
     * Two entries with DIFFERENT (pal_id, base_off) reading the SAME index
     * texture must paint exactly as two OP_BLITs carrying those palettes in
     * their header colour word -- if the entry colour were ignored (or its two
     * bytes swapped) both entries would resolve through the wrong CLUT bank
     * and/or slot and the framebuffers would differ. */
    {
        /* CLUT: every (bank, slot) holds a DISTINCT opaque colour, so selecting
         * the wrong bank or the wrong slot is always visible in the pixels. */
        for (unsigned bank = 0; bank < BLT_CLUT_BANKS; bank++)
            for (unsigned slot = 0; slot < BLT_CLUT_ENTRIES; slot++) {
                uint32_t rgb = (bank * 7919u + slot * 31u + 1u) & 0xFFFFu;
                uint32_t w   = (0xFu << 16) | rgb;      /* a4=opaque | rgb565 */
                uint8_t *d   = clut_buf + ((bank * BLT_CLUT_ENTRIES + slot) * 4u);
                d[0] = (uint8_t)w; d[1] = (uint8_t)(w >> 8);
                d[2] = (uint8_t)(w >> 16); d[3] = (uint8_t)(w >> 24);
            }

        memset(pal_heap_a, 0, sizeof pal_heap_a);
        memset(pal_heap_b, 0, sizeof pal_heap_b);
        for (int y = 0; y < PTEXH; y++)
            for (int x = 0; x < PTEXW; x++) {
                uint8_t idx = (uint8_t)(y * PTEXW + x);
                pal_heap_a[OFF_PALTEX + y * PTEXW + x] = idx;
                pal_heap_b[OFF_PALTEX + y * PTEXW + x] = idx;
            }

        blt_surface_heap_t hpa = { pal_heap_a, sizeof pal_heap_a, 0, 0, clut_buf };
        blt_surface_heap_t hpb = { pal_heap_b, sizeof pal_heap_b, 0, 0, clut_buf };

        /* A: NPSPR individual PAL8 OP_BLITs, palette in the header colour. */
        memset(fb_pa, 0, sizeof fb_pa);
        blt_cmd_t pcmds[NPSPR + 1];
        memset(pcmds, 0, sizeof pcmds);
        for (int i = 0; i < NPSPR; i++) {
            pcmds[i].opcode     = BLT_OP_BLIT;
            pcmds[i].blend_mode = BLT_BLEND_COPY;
            pcmds[i].format     = BLT_FMT_PAL8;
            pcmds[i].src_off    = OFF_PALTEX;
            pcmds[i].src_stride = PTEXW;          /* PAL8 is 1 byte per pixel */
            pcmds[i].src_x = 0;  pcmds[i].src_y = 0;
            pcmds[i].w = PTEXW;  pcmds[i].h = PTEXH;
            pcmds[i].dst_x = PSPR[i].dx; pcmds[i].dst_y = PSPR[i].dy;
            pcmds[i].color = blt_pal_color(PSPR[i].bank, PSPR[i].base);
        }
        pcmds[NPSPR].opcode = BLT_OP_END;
        blt_execute(fb_pa, &hpa, pcmds, NPSPR + 1);

        /* Sanity: the two palettes must actually paint DIFFERENT pixels, or the
         * equivalence below would hold even for a model that ignores the
         * palette entirely. */
        if (fb_pa[(unsigned)PSPR[0].dy * BLT_FB_WIDTH + PSPR[0].dx] ==
            fb_pa[(unsigned)PSPR[1].dy * BLT_FB_WIDTH + PSPR[1].dx]) {
            printf("FAIL: PAL8 fixture is degenerate -- both palettes paint the "
                   "same colour, so the comparison would prove nothing\n");
            return 1;
        }

        /* B: ONE OP_SPRITELIST, palette carried PER ENTRY. */
        uint32_t peoff = (uint32_t)PAL_HEAP_TEX;
        for (int i = 0; i < NPSPR; i++) {
            blt_sprite_entry_t e;
            memset(&e, 0, sizeof e);
            e.src_off = OFF_PALTEX;
            e.src_x = 0; e.src_y = 0; e.w = PTEXW; e.h = PTEXH;
            e.dst_x = PSPR[i].dx; e.dst_y = PSPR[i].dy;
            e.color = blt_pal_color(PSPR[i].bank, PSPR[i].base);
            blt_pack_sprite_entry(pal_heap_b + peoff
                                  + (size_t)i * BLT_SPRITE_ENTRY_BYTES, &e);
        }
        memset(fb_pb, 0, sizeof fb_pb);
        blt_cmd_t plist[2];
        memset(plist, 0, sizeof plist);
        plist[0].opcode     = BLT_OP_SPRITELIST;
        plist[0].blend_mode = BLT_BLEND_COPY;
        plist[0].format     = BLT_FMT_PAL8;
        plist[0].src_stride = PTEXW;
        plist[0].src_x = 0; plist[0].src_y = 0;                /* no bias */
        plist[0].w = (uint16_t)NPSPR; plist[0].h = 0;
        plist[0].dst_x = (int16_t)(peoff & 0xFFFFu);
        plist[0].dst_y = (int16_t)(peoff >> 16);
        /* The HEADER colour is deliberately a palette NEITHER entry uses: if the
         * model fell back to the header (as OP_TILELIST legitimately does), both
         * entries would resolve through bank 30 and the compare would fail. */
        plist[0].color = blt_pal_color(30, 0x77);
        plist[1].opcode = BLT_OP_END;
        blt_execute(fb_pb, &hpb, plist, 2);

        if (memcmp(fb_pa, fb_pb, sizeof fb_pa) != 0) {
            for (int i = 0; i < BLT_FB_WIDTH * BLT_FB_HEIGHT; i++)
                if (fb_pa[i] != fb_pb[i]) {
                    printf("FAIL: PAL8 first diff at px %d (%d,%d): blits=%04x list=%04x\n",
                           i, i % BLT_FB_WIDTH, i / BLT_FB_WIDTH, fb_pa[i], fb_pb[i]);
                    return 1;
                }
        }
        printf("ok: PAL8 OP_SPRITELIST == %d x OP_BLIT with per-entry palettes "
               "(banks %u/%u, base 0x%02x/0x%02x)\n",
               NPSPR, PSPR[0].bank, PSPR[1].bank, PSPR[0].base, PSPR[1].base);
    }

    /* ── [Task 4b] PAL8 ABSOLUTE golden values ──────────────────────────────
     * Known CLUT + known indices => known pixels, asserted against literals.
     * See the derivation note at the gold fixtures above. */
    {
        /* CLUT starts fully zeroed: every entry not explicitly written is
         * a4=0/rgb=0, so an addressing bug that lands on an unwritten entry
         * shows up as a skip or as black -- never as a coincidental match. */
        memset(gold_clut, 0, sizeof gold_clut);

        /* Bank 2 -- the PALPHA alpha cases (base_off 0, so slot == index). */
        gold_clut_put(2, 0x10, 0x0, 0x1234);  /* a4==0  -> skipped entirely   */
        gold_clut_put(2, 0x11, 0x8, 0xF800);  /* mid alpha, pure red          */
        gold_clut_put(2, 0x12, 0xF, 0x07E0);  /* opaque, pure green           */
        /* Bank 2 -- the slot-WRAP case: index 0xFA + base_off 0x0A == 0x104,
         * which the RTL's 8-bit adder truncates to slot 0x04 (it CANNOT carry
         * into c_pal_id, which is a separate concatenated field). */
        gold_clut_put(2, 0x04, 0xF, 0x001F);  /* the correct, WRAPPED slot    */
        /* If the &0xFF were dropped, byte-addressing bank*256+0x104 lands on
         * bank 3 slot 4. Give that a DIFFERENT opaque colour so the unwrapped
         * read is visible as a wrong pixel rather than as a black/skip. */
        gold_clut_put(3, 0x04, 0xF, 0x7FFF);
        /* Banks 5 and 6 -- the same index resolving through different banks,
         * pinning the pal_bank*256 + slot addressing. */
        gold_clut_put(5, 0x20, 0xF, 0xF81F);
        gold_clut_put(6, 0x20, 0xF, 0x03E0);

        /* Index texture: one row, one index per case. */
        memset(gold_heap, 0, sizeof gold_heap);
        gold_heap[OFF_GOLDTEX + 0] = 0x10;    /* transparent CLUT entry       */
        gold_heap[OFF_GOLDTEX + 1] = 0x11;    /* mid-alpha CLUT entry         */
        gold_heap[OFF_GOLDTEX + 2] = 0x12;    /* opaque CLUT entry            */
        gold_heap[OFF_GOLDTEX + 3] = 0xFA;    /* wraps when base_off == 0x0A  */
        gold_heap[OFF_GOLDTEX + 4] = 0x20;    /* same index, two banks        */

        blt_surface_heap_t hg = { gold_heap, sizeof gold_heap, 0, 0, gold_clut };

        /* Each case is a 1x1 PALPHA blit at its own destination pixel. */
        static const struct {
            int      sx;        /* index-texture column                       */
            uint8_t  bank, base;
            int16_t  dx, dy;
            uint16_t want;      /* HAND-DERIVED expected framebuffer pixel    */
            const char *what;
        } G[] = {
            /* 1. a4==0 -> comp_pipeline s3_skip_eff asserts, no write at all,
             *    so the destination keeps its pre-fill. */
            { 0, 2, 0x00, 10, 10, GOLD_DST,
              "PALPHA a4==0 skips the pixel (dst unchanged)" },
            /* 2. a4==0x8 -> a8 = {a4,a4} = 0x88 = 136 (NOT 0x80 = 128).
             *    src 0xF800 = (sr,sg,sb) = (31,0,0); dst 0x529E = (10,20,30).
             *    na = 255-136 = 119.
             *      R: t = 31*136 + 10*119 = 4216 + 1190 = 5406
             *         m = 5534, (5534 + 21) >> 8 = 5555 >> 8 = 21
             *      G: t = 0*136 + 20*119 = 2380
             *         m = 2508, (2508 + 9) >> 8 = 2517 >> 8 = 9
             *      B: t = 0*136 + 30*119 = 3570
             *         m = 3698, (3698 + 14) >> 8 = 3712 >> 8 = 14
             *    out = (21<<11)|(9<<5)|14 = 0xA92E.
             *    With a8 = a4<<4 = 0x80 this would be 0xA94F -- so this case
             *    is what kills the "(a4 << 4)" mutation. */
            { 1, 2, 0x00, 11, 10, 0xA92Eu,
              "PALPHA mid alpha replicates {a4,a4} (a8==0x88, not 0x80)" },
            /* 3. a4==0xF -> a8 = 0xFF = 255, na = 0, so out == the CLUT RGB
             *    exactly (div255_round(ch*255) is an exact identity). */
            { 2, 2, 0x00, 12, 10, 0x07E0u,
              "PALPHA a4==0xF writes the CLUT RGB exactly" },
            /* 4. slot wrap: (0xFA + 0x0A) & 0xFF = 0x04 in bank 2 -> 0x001F.
             *    Without the wrap it would read bank 3 slot 4 -> 0x7FFF. */
            { 3, 2, 0x0A, 13, 10, 0x001Fu,
              "slot index wraps mod 256 ((idx+base_off) & 0xFF)" },
            /* 5. bank selection: index 0x20 through bank 5 vs bank 6. */
            { 4, 5, 0x00, 14, 10, 0xF81Fu,
              "bank 5 selects its own CLUT entry (pal_bank*256 + slot)" },
            { 4, 6, 0x00, 15, 10, 0x03E0u,
              "bank 6 selects a DIFFERENT entry for the same index" },
        };
        const int NG = (int)(sizeof G / sizeof G[0]);

        blt_cmd_t gc[8];
        memset(gc, 0, sizeof gc);
        for (int i = 0; i < NG; i++) {
            gc[i].opcode     = BLT_OP_BLIT;
            gc[i].blend_mode = BLT_BLEND_PALPHA;
            gc[i].format     = BLT_FMT_PAL8;
            gc[i].src_off    = OFF_GOLDTEX;
            gc[i].src_stride = 8;                 /* PAL8: 1 byte per pixel   */
            gc[i].src_x = (int16_t)G[i].sx; gc[i].src_y = 0;
            gc[i].w = 1; gc[i].h = 1;
            gc[i].dst_x = G[i].dx; gc[i].dst_y = G[i].dy;
            /* alpha is deliberately a value the PALPHA path must IGNORE: for
             * PAL8+PALPHA the RTL overrides mx_in_alpha with {a4,a4}, so if the
             * command alpha leaked through, every expectation below breaks. */
            gc[i].alpha = 0x11;
            gc[i].color = blt_pal_color(G[i].bank, G[i].base);
        }
        gc[NG].opcode = BLT_OP_END;

        for (int i = 0; i < BLT_FB_WIDTH * BLT_FB_HEIGHT; i++)
            fb_gold[i] = (uint16_t)GOLD_DST;
        blt_execute(fb_gold, &hg, gc, NG + 1);

        for (int i = 0; i < NG; i++) {
            uint16_t got = fb_gold[(unsigned)G[i].dy * BLT_FB_WIDTH + (unsigned)G[i].dx];
            if (got != G[i].want) {
                printf("FAIL: PAL8 golden case %d (%s): got %04x want %04x\n",
                       i, G[i].what, got, G[i].want);
                return 1;
            }
        }
        printf("ok: PAL8 golden values -- %d absolute cases "
               "(a4==0 skip, {a4,a4} replication, opaque, slot wrap, bank select)\n",
               NG);

        /* The same golden pixels must come out of the OP_SPRITELIST path, where
         * the palette travels in the PER-ENTRY colour word rather than the
         * header -- this pins the entry decode to ABSOLUTE values too, not just
         * to agreement with OP_BLIT. */
        {
            uint32_t geoff = OFF_GOLDTEX + 32u;   /* past the index row        */
            for (int i = 0; i < NG; i++) {
                blt_sprite_entry_t e;
                memset(&e, 0, sizeof e);
                e.src_off = OFF_GOLDTEX;
                e.src_x = (uint16_t)G[i].sx; e.src_y = 0;
                e.w = 1; e.h = 1;
                e.dst_x = G[i].dx; e.dst_y = G[i].dy;
                e.color = blt_pal_color(G[i].bank, G[i].base);
                blt_pack_sprite_entry(gold_heap + geoff
                                      + (size_t)i * BLT_SPRITE_ENTRY_BYTES, &e);
            }
            blt_cmd_t gl[2];
            memset(gl, 0, sizeof gl);
            gl[0].opcode     = BLT_OP_SPRITELIST;
            gl[0].blend_mode = BLT_BLEND_PALPHA;
            gl[0].format     = BLT_FMT_PAL8;
            gl[0].src_stride = 8;
            gl[0].alpha      = 0x11;
            gl[0].w = (uint16_t)NG; gl[0].h = 0;
            gl[0].dst_x = (int16_t)(geoff & 0xFFFFu);
            gl[0].dst_y = (int16_t)(geoff >> 16);
            gl[0].color = blt_pal_color(30, 0x77);   /* a palette NO entry uses */
            gl[1].opcode = BLT_OP_END;

            for (int i = 0; i < BLT_FB_WIDTH * BLT_FB_HEIGHT; i++)
                fb_gold[i] = (uint16_t)GOLD_DST;
            blt_execute(fb_gold, &hg, gl, 2);

            for (int i = 0; i < NG; i++) {
                uint16_t got = fb_gold[(unsigned)G[i].dy * BLT_FB_WIDTH + (unsigned)G[i].dx];
                if (got != G[i].want) {
                    printf("FAIL: PAL8 golden (SPRITELIST) case %d (%s): "
                           "got %04x want %04x\n", i, G[i].what, got, G[i].want);
                    return 1;
                }
            }
            printf("ok: PAL8 golden values hold through OP_SPRITELIST "
                   "per-entry palettes (%d absolute cases)\n", NG);
        }
    }

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
        static uint8_t spb[NSPR * BLT_SPRITE_ENTRY_BYTES];
        blt_emitter_init(&e, ring, sizeof ring, NULL, 0);
        blt_sprite_list_init(&e, spb, sizeof spb);
        blt_begin_frame(&e, 0, 0, 0);
        for (int i = 0; i < NSPR; i++) {
            blt_sprite_entry_t se = { 0, SPR[i].sx, SPR[i].sy, SPR[i].w, SPR[i].h,
                                      SPR[i].dx, SPR[i].dy, 0, 0, 0 };
            blt_pack_sprite_entry(spb + i * BLT_SPRITE_ENTRY_BYTES, &se);
        }
        e.sp_used = NSPR * BLT_SPRITE_ENTRY_BYTES;
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
        static uint8_t spb[8 * BLT_SPRITE_ENTRY_BYTES];
        blt_emitter_t em; static uint8_t ring[BLT_CMD_BYTES * 8];
        memset(spb, 0xEE, sizeof spb);
        blt_emitter_init(&em, ring, sizeof ring, NULL, 0);
        blt_sprite_list_init(&em, spb, sizeof spb);
        blt_sprite_channel_init(&ch, &em, /*cap=*/4);
        blt_sprite_run_key_t k = { 64, BLT_FMT_RGB565, BLT_BLEND_COPY, 255, 0, 0 };
        int accepted = 0;
        for (int i = 0; i < 7; i++) {
            blt_sprite_entry_t e = { 0, 0, 0, 8, 8, (int16_t)(10 + i), (int16_t)(20 + i), 0, 0, 0 };
            if (blt_sprite_channel_push(&ch, &k, &e)) accepted++;
        }
        if (accepted != 4)   { printf("FAIL: accepted %d, want 4\n", accepted);  return 1; }
        if (ch.dropped != 3) { printf("FAIL: dropped %u, want 3\n", ch.dropped); return 1; }
        if (ch.count != 4)   { printf("FAIL: count %d, want 4\n", ch.count);     return 1; }
        /* The TAIL is dropped, so slots 0..3 must still hold entries 0..3 IN ORDER --
         * this is the Z-order guarantee. A FIFO/ring that evicted the head would leave
         * entries 3..6 here instead. Check dst_x/dst_y of every surviving slot. */
        for (int i = 0; i < 4; i++) {
            int dx = (int16_t)((uint16_t)spb[i*BLT_SPRITE_ENTRY_BYTES+12] | ((uint16_t)spb[i*BLT_SPRITE_ENTRY_BYTES+13] << 8));
            int dy = (int16_t)((uint16_t)spb[i*BLT_SPRITE_ENTRY_BYTES+14] | ((uint16_t)spb[i*BLT_SPRITE_ENTRY_BYTES+15] << 8));
            if (dx != 10 + i || dy != 20 + i) {
                printf("FAIL: slot %d holds dst=(%d,%d), want (%d,%d) -- order not preserved\n",
                       i, dx, dy, 10 + i, 20 + i);
                return 1;
            }
        }
        /* Slot 4 must be UNTOUCHED (0xEE fill): a refused push must not write past count. */
        if (spb[4*BLT_SPRITE_ENTRY_BYTES] != 0xEE) { printf("FAIL: refused push wrote past the cap\n"); return 1; }
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
        static uint8_t spb2[2 * BLT_SPRITE_ENTRY_BYTES + 8];       /* room for 2 entries, not 3 */
        blt_emitter_t em2; static uint8_t ring2[BLT_CMD_BYTES * 8];
        blt_emitter_init(&em2, ring2, sizeof ring2, NULL, 0);
        blt_sprite_list_init(&em2, spb2, sizeof spb2);
        blt_sprite_channel_init(&ch, &em2, /*cap=*/16);
        blt_sprite_run_key_t k = { 64, BLT_FMT_RGB565, BLT_BLEND_COPY, 255, 0, 0 };
        int accepted = 0;
        for (int i = 0; i < 5; i++) {
            blt_sprite_entry_t e = { 0, 0, 0, 8, 8, (int16_t)i, (int16_t)i, 0, 0, 0 };
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
        static uint8_t spb3[4 * BLT_SPRITE_ENTRY_BYTES];
        blt_emitter_t em3; static uint8_t ring3[BLT_CMD_BYTES * 8];
        blt_emitter_init(&em3, ring3, sizeof ring3, NULL, 0);
        blt_sprite_list_init(&em3, spb3, sizeof spb3);
        blt_sprite_channel_init(&ch, &em3, /*cap=*/2);
        blt_sprite_run_key_t k = { 64, BLT_FMT_RGB565, BLT_BLEND_COPY, 255, 0, 0 };
        blt_sprite_entry_t e = { 0, 0, 0, 8, 8, 1, 1, 0, 0, 0 };
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

    /* [Task 4 defect] MULTIPLE FLUSHES IN ONE FRAME must not share SP_BUF bytes.
     *
     * Nothing is consumed during the frame: the fabric executes the whole ring only
     * after present() writes C_SUBMIT. So every list's entries must still be intact,
     * at the offset ITS OWN header points at, when the frame is submitted. The design
     * flushes once per layer boundary (plus the overlay/root-blit ordering guards), so
     * two-or-more lists per frame is the NORMAL case, not an edge case.
     *
     * The bug this pins: the channel wrote from offset 0 on every batch and flushed
     * entry_off = i*16, so list 0's header still pointed at byte 0 while list 1's
     * entries had already overwritten it -- every earlier list in the frame painted
     * the LAST list's sprites. Two independent checks, because either alone is
     * satisfiable by a wrong fix: the ranges must be DISJOINT, and each list's bytes
     * must read back as the sprites pushed for THAT list. */
    {
        blt_emitter_t em;   static uint8_t ring[BLT_CMD_BYTES * 16];
        static uint8_t spb[64 * BLT_SPRITE_ENTRY_BYTES];
        blt_sprite_channel_t ch;
        blt_emitter_init(&em, ring, sizeof ring, NULL, 0);
        blt_sprite_list_init(&em, spb, sizeof spb);
        blt_begin_frame(&em, 0, 0, 0);
        blt_sprite_channel_init(&ch, &em, /*cap=*/64);
        memset(spb, 0, sizeof spb);

        /* Distinct run keys so each batch flushes as EXACTLY one command (the run
         * splitter is covered separately above), and distinct dst coordinates so a
         * readback can tell the two lists apart. */
        blt_sprite_run_key_t kA = { 64,  BLT_FMT_RGB565, BLT_BLEND_COPY,   255, 0, 0 };
        blt_sprite_run_key_t kB = { 128, BLT_FMT_RGB565, BLT_BLEND_PALPHA, 200, 0, 0 };
#define NA 2
#define NB 3
        for (int i = 0; i < NA; i++) {
            blt_sprite_entry_t e = { 0, 0, 0, 8, 8, (int16_t)(100 + i), (int16_t)(200 + i), 0, 0, 0 };
            if (!blt_sprite_channel_push(&ch, &kA, &e)) {
                printf("FAIL: list A push %d refused\n", i); return 1;
            }
        }
        if (blt_sprite_channel_flush(&ch, 0, 0) != 1) {
            printf("FAIL: list A did not flush as exactly 1 command\n"); return 1;
        }
        for (int i = 0; i < NB; i++) {
            blt_sprite_entry_t e = { 0, 0, 0, 8, 8, (int16_t)(10 + i), (int16_t)(20 + i), 0, 0, 0 };
            if (!blt_sprite_channel_push(&ch, &kB, &e)) {
                printf("FAIL: list B push %d refused\n", i); return 1;
            }
        }
        if (blt_sprite_channel_flush(&ch, 0, 0) != 1) {
            printf("FAIL: list B did not flush as exactly 1 command\n"); return 1;
        }
        if (em.cmd_count != 2) {
            printf("FAIL: expected 2 commands in the frame, got %d\n", em.cmd_count);
            return 1;
        }

        blt_cmd_t cA, cB;
        blt_unpack_cmd(ring + 0 * BLT_CMD_BYTES, &cA);
        blt_unpack_cmd(ring + 1 * BLT_CMD_BYTES, &cB);
        uint32_t nA   = (uint32_t)cA.w | ((uint32_t)cA.h << 16);
        uint32_t nB   = (uint32_t)cB.w | ((uint32_t)cB.h << 16);
        uint32_t offA = (uint32_t)(uint16_t)cA.dst_x | ((uint32_t)(uint16_t)cA.dst_y << 16);
        uint32_t offB = (uint32_t)(uint16_t)cB.dst_x | ((uint32_t)(uint16_t)cB.dst_y << 16);
        if (nA != NA || nB != NB) {
            printf("FAIL: counts %u/%u exp %d/%d\n", nA, nB, NA, NB); return 1;
        }
        /* 1. DISJOINT byte ranges. */
        if (offA + nA * (uint32_t)BLT_SPRITE_ENTRY_BYTES > offB && offB + nB * (uint32_t)BLT_SPRITE_ENTRY_BYTES > offA) {
            printf("FAIL: SP_BUF ranges OVERLAP -- A=[%u,%u) B=[%u,%u); the second "
                   "flush overwrote the first list's entries\n",
                   offA, offA + nA * (uint32_t)BLT_SPRITE_ENTRY_BYTES, offB, offB + nB * (uint32_t)BLT_SPRITE_ENTRY_BYTES);
            return 1;
        }
        /* 2. Each header points at ITS OWN entries. Disjointness alone would be
         *    satisfied by a header pointing at untouched zeroed bytes. */
        for (int i = 0; i < NA; i++) {
            int dx = (int16_t)((uint16_t)spb[offA + i*BLT_SPRITE_ENTRY_BYTES + 12] | ((uint16_t)spb[offA + i*BLT_SPRITE_ENTRY_BYTES + 13] << 8));
            int dy = (int16_t)((uint16_t)spb[offA + i*BLT_SPRITE_ENTRY_BYTES + 14] | ((uint16_t)spb[offA + i*BLT_SPRITE_ENTRY_BYTES + 15] << 8));
            if (dx != 100 + i || dy != 200 + i) {
                printf("FAIL: list A entry %d at off %u reads dst=(%d,%d), want (%d,%d)\n",
                       i, offA, dx, dy, 100 + i, 200 + i);
                return 1;
            }
        }
        for (int i = 0; i < NB; i++) {
            int dx = (int16_t)((uint16_t)spb[offB + i*BLT_SPRITE_ENTRY_BYTES + 12] | ((uint16_t)spb[offB + i*BLT_SPRITE_ENTRY_BYTES + 13] << 8));
            int dy = (int16_t)((uint16_t)spb[offB + i*BLT_SPRITE_ENTRY_BYTES + 14] | ((uint16_t)spb[offB + i*BLT_SPRITE_ENTRY_BYTES + 15] << 8));
            if (dx != 10 + i || dy != 20 + i) {
                printf("FAIL: list B entry %d at off %u reads dst=(%d,%d), want (%d,%d)\n",
                       i, offB, dx, dy, 10 + i, 20 + i);
                return 1;
            }
        }
        /* 3. The frame cursor accounts for BOTH lists -- a flush that emitted correct
         *    offsets but failed to commit them would let the NEXT flush alias again. */
        if (em.sp_used != (size_t)(NA + NB) * (size_t)BLT_SPRITE_ENTRY_BYTES) {
            printf("FAIL: sp_used %u exp %u\n",
                   (unsigned)em.sp_used, (unsigned)((NA + NB) * BLT_SPRITE_ENTRY_BYTES));
            return 1;
        }
        /* 4. blt_begin_frame must RECYCLE the arena, or a long session leaks SP_BUF. */
        blt_begin_frame(&em, 0, 0, 0);
        if (em.sp_used != 0) {
            printf("FAIL: blt_begin_frame left sp_used=%u\n", (unsigned)em.sp_used);
            return 1;
        }
        printf("ok: two lists in one frame occupy disjoint SP_BUF ranges "
               "([%u,%u) and [%u,%u)) and each header points at its own entries\n",
               offA, offA + nA * (uint32_t)BLT_SPRITE_ENTRY_BYTES, offB, offB + nB * (uint32_t)BLT_SPRITE_ENTRY_BYTES);
#undef NA
#undef NB
    }

    /* [Task 4 defect] The PER-FRAME budget is a real limit once entries accumulate
     * ACROSS flushes, and exhausting it must DROP-and-COUNT (observable in the diag
     * counters), never silently wrap onto a live list's bytes. */
    {
        blt_emitter_t em;   static uint8_t ring[BLT_CMD_BYTES * 16];
        static uint8_t spb[4 * BLT_SPRITE_ENTRY_BYTES];            /* budget: 4 entries per FRAME */
        blt_sprite_channel_t ch;
        blt_emitter_init(&em, ring, sizeof ring, NULL, 0);
        blt_sprite_list_init(&em, spb, sizeof spb);
        blt_begin_frame(&em, 0, 0, 0);
        blt_sprite_channel_init(&ch, &em, /*cap=*/64);   /* entry cap is NOT the limit */
        blt_sprite_run_key_t k = { 64, BLT_FMT_RGB565, BLT_BLEND_COPY, 255, 0, 0 };
        blt_sprite_entry_t e = { 0, 0, 0, 8, 8, 1, 1, 0, 0, 0 };

        int accepted = 0;
        for (int i = 0; i < 3; i++) if (blt_sprite_channel_push(&ch, &k, &e)) accepted++;
        blt_sprite_channel_flush(&ch, 0, 0);            /* commits 3 of the 4 */
        for (int i = 0; i < 3; i++) if (blt_sprite_channel_push(&ch, &k, &e)) accepted++;
        if (accepted != 4) {
            printf("FAIL: frame budget accepted %d, want 4\n", accepted); return 1;
        }
        if (ch.dropped != 2) {
            printf("FAIL: frame budget dropped %u, want 2\n", ch.dropped); return 1;
        }
        /* And the budget is per FRAME, not per process: a new frame restores it. */
        blt_sprite_channel_flush(&ch, 0, 0);
        blt_begin_frame(&em, 0, 0, 0);
        if (!blt_sprite_channel_push(&ch, &k, &e)) {
            printf("FAIL: budget not restored by blt_begin_frame\n"); return 1;
        }
        printf("ok: per-frame SP_BUF budget drops the tail and counts it "
               "(%d accepted, %u dropped), and resets per frame\n", accepted, ch.dropped);
    }

    return 0;
}
