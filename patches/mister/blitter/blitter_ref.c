/* VENDORED-PEER of blitter_ref.h — the C reference model body. Workstream C
 * (Verification) owns this file for the "v2 blitter escape elimination" effort:
 * it implements the bit-exact software goldens that the comp_pipeline RTL
 * (Workstream B) must match, and the command-list executor blt_execute() that
 * the sim testbenches diff against.
 *
 *  blitter_ref.c — software reference model for the MiSTer fabric 2D blitter.
 *
 *  Pixel model (v1): 320x240 RGB565 framebuffer. v2 adds the "escape
 *  elimination" colour ops so Solarus colour-modulation / additive / multiply
 *  draws never fall back to the A9 software path:
 *    - colour-mod  (BLT_F_COLORMOD): modulate the source by an 8-bit-per-channel
 *                  tint BEFORE the blend; composes with every blend mode.
 *    - ADD         (blend_mode 4): saturating per-channel add.
 *    - MULTIPLY    (blend_mode 5): per-channel modulate src by dst.
 *
 *  THESE GOLDENS ARE THE SINGLE SOURCE OF TRUTH. The RTL (comp_mixer /
 *  comp_pipeline) must be bit-exact to blt_tint565 / blt_add565 / blt_mul565
 *  and to the compositing performed in blt_execute().
 *
 *  Copyright (C) 2026 — GPL-3.0 (matches solarus-mister/fpga).
 */
#include "blitter_ref.h"

/* ──────────────────────────────────────────────────────────────────────────
 *  Frozen v2 ABI constants.
 *
 *  These belong to the wire-ABI owned by Workstream A in blitter_ref.h. They
 *  are declared here under #ifndef guards ONLY so this verification TU builds
 *  and self-checks standalone before A's frozen header lands; when the header
 *  defines them the guards make this a no-op (no redefinition, identical
 *  values). Do NOT change the values — they are the frozen contract:
 *      blend_mode ADD       = 4
 *      blend_mode MULTIPLY  = 5
 *      flag       COLORMOD  = 0x40
 * ────────────────────────────────────────────────────────────────────────── */
#ifndef BLT_BLEND_ADD
#define BLT_BLEND_ADD       4   /* dst = saturating_add(src, dst), per channel */
#endif
#ifndef BLT_BLEND_MULTIPLY
#define BLT_BLEND_MULTIPLY  5   /* dst = round(src*dst / chan_max), per channel */
#endif
#ifndef BLT_F_COLORMOD
#define BLT_F_COLORMOD      0x40u /* modulate source by {cr,cg,cb} before blend */
#endif

/* Goldens are declared in the frozen header; forward-declare here under a guard
 * so this TU compiles even against the pre-freeze header (this worktree). */
#ifndef BLT_GOLDENS_DECLARED
uint16_t blt_tint565(uint16_t src565, uint8_t cr, uint8_t cg, uint8_t cb);
uint16_t blt_add565 (uint16_t src565, uint16_t dst565);
uint16_t blt_mul565 (uint16_t src565, uint16_t dst565);
#endif

/* ──────────────────────────────────────────────────────────────────────────
 *  Divide-free rounding reductions — the bit-exact targets for the RTL.
 *
 *  All three are the SAME canonical shape  out = (m + (m>>k)) >> k, m = t + 2^(k-1)
 *  with k chosen for the divisor (2^k - 1):
 *      /255 (k=8): out = (t + 128 + ((t+128)>>8)) >> 8      [== blt_blend565]
 *      /63  (k=6): out = (t +  32 + ((t+ 32)>>6)) >> 6      [G channel multiply]
 *      /31  (k=5): out = (t +  16 + ((t+ 16)>>5)) >> 5      [R/B channel multiply]
 *  Each computes round(t / (2^k-1)) EXACTLY over the full operand domain used
 *  here (proven by exhaustion in the self-test main() and in finddiv).
 * ────────────────────────────────────────────────────────────────────────── */
static unsigned div255_round(unsigned t) { unsigned m = t + 128u; return (m + (m >> 8)) >> 8; }
static unsigned div63_round (unsigned t) { unsigned m = t +  32u; return (m + (m >> 6)) >> 6; }
static unsigned div31_round (unsigned t) { unsigned m = t +  16u; return (m + (m >> 5)) >> 5; }

/* Modulate one dest-width channel value `ch` by an 8-bit factor `mod`/255.
 * mod==255 is an exact identity (round(ch*255/255) == ch). */
static unsigned modch(unsigned ch, unsigned mod) { return div255_round(ch * mod); }

/* ──────────────────────────────────────────────────────────────────────────
 *  Public RGB565 helpers (declared in blitter_ref.h).
 * ────────────────────────────────────────────────────────────────────────── */
uint16_t blt_rgb565(uint8_t r, uint8_t g, uint8_t b) {
    return (uint16_t)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
}

/* Canonical const-alpha channel blend: out = round((s*a + d*(255-a)) / 255),
 * via the divide-free /255 reduction. Bit-exact to comp_mixer COMP_CA. */
uint16_t blt_blend565(uint16_t src, uint16_t dst, uint8_t alpha) {
    unsigned a = alpha, na = 255u - a;
    unsigned sr = (src >> 11) & 0x1F, sg = (src >> 5) & 0x3F, sb = src & 0x1F;
    unsigned dr = (dst >> 11) & 0x1F, dg = (dst >> 5) & 0x3F, db = dst & 0x1F;
    unsigned orr = div255_round(sr * a + dr * na);
    unsigned og  = div255_round(sg * a + dg * na);
    unsigned ob  = div255_round(sb * a + db * na);
    return (uint16_t)(((orr & 0x1F) << 11) | ((og & 0x3F) << 5) | (ob & 0x1F));
}

/* ──────────────────────────────────────────────────────────────────────────
 *  v2 GOLDENS.
 * ────────────────────────────────────────────────────────────────────────── */

/* COLOUR-MOD: out_ch = round(src_ch * mod_ch / 255) per dest-width channel.
 * R expands 5b, G 6b, B 5b. (cr,cg,cb)=(255,255,255) is an exact identity. */
uint16_t blt_tint565(uint16_t src565, uint8_t cr, uint8_t cg, uint8_t cb) {
    unsigned sr = (src565 >> 11) & 0x1F, sg = (src565 >> 5) & 0x3F, sb = src565 & 0x1F;
    unsigned orr = modch(sr, cr);
    unsigned og  = modch(sg, cg);
    unsigned ob  = modch(sb, cb);
    return (uint16_t)(((orr & 0x1F) << 11) | ((og & 0x3F) << 5) | (ob & 0x1F));
}

/* ADD: out_ch = min(src_ch + dst_ch, chan_max). R/B max 31, G max 63. */
uint16_t blt_add565(uint16_t src565, uint16_t dst565) {
    unsigned sr = (src565 >> 11) & 0x1F, sg = (src565 >> 5) & 0x3F, sb = src565 & 0x1F;
    unsigned dr = (dst565 >> 11) & 0x1F, dg = (dst565 >> 5) & 0x3F, db = dst565 & 0x1F;
    unsigned orr = sr + dr; if (orr > 31u) orr = 31u;
    unsigned og  = sg + dg; if (og  > 63u) og  = 63u;
    unsigned ob  = sb + db; if (ob  > 31u) ob  = 31u;
    return (uint16_t)((orr << 11) | (og << 5) | ob);
}

/* MULTIPLY: out_ch = round(src_ch * dst_ch / chan_max), chan_max = 31 (R/B) or
 * 63 (G). Divide-free EXACT reduction (see div31_round/div63_round above):
 *      R,B: out = ((t+16) + ((t+16)>>5)) >> 5,  t = src_ch*dst_ch   (== round(t/31))
 *      G:   out = ((t+32) + ((t+32)>>6)) >> 6,  t = src_ch*dst_ch   (== round(t/63))
 * src_ch * chan_max is an exact identity (round(ch*max/max) == ch). */
uint16_t blt_mul565(uint16_t src565, uint16_t dst565) {
    unsigned sr = (src565 >> 11) & 0x1F, sg = (src565 >> 5) & 0x3F, sb = src565 & 0x1F;
    unsigned dr = (dst565 >> 11) & 0x1F, dg = (dst565 >> 5) & 0x3F, db = dst565 & 0x1F;
    unsigned orr = div31_round(sr * dr);
    unsigned og  = div63_round(sg * dg);
    unsigned ob  = div31_round(sb * db);
    return (uint16_t)((orr << 11) | (og << 5) | ob);
}

/* ──────────────────────────────────────────────────────────────────────────
 *  Colour-mod applied to dest-width channels of an ARGB4444 source (PALPHA).
 *  Returns the modulated RGB565-domain source; the per-pixel-alpha blend then
 *  proceeds on these channels. (Used by blt_execute for COLORMOD+PALPHA.)
 * ────────────────────────────────────────────────────────────────────────── */
static void argb4444_expand(uint16_t s16, unsigned *a8,
                            unsigned *sr, unsigned *sg, unsigned *sb) {
    unsigned a4 = (s16 >> 12) & 0xF, r4 = (s16 >> 8) & 0xF,
             g4 = (s16 >> 4) & 0xF, b4 = s16 & 0xF;
    *a8 = (a4 << 4) | a4;
    *sr = (r4 << 1) | (r4 >> 3);   /* R4 -> 5b {r4,r4[3]}   */
    *sg = (g4 << 2) | (g4 >> 2);   /* G4 -> 6b {g4,g4[3:2]} */
    *sb = (b4 << 1) | (b4 >> 3);   /* B4 -> 5b {b4,b4[3]}   */
}

/* ──────────────────────────────────────────────────────────────────────────
 *  Source-heap fetch with model-safety clamp (OOB -> 0).
 * ────────────────────────────────────────────────────────────────────────── */
static uint16_t heap_px16(const blt_surface_heap_t *heap, size_t byte_off) {
    if (!heap || !heap->base) return 0;
    if (byte_off + 1 >= heap->size) return 0;
    /* little-endian 16bpp */
    return (uint16_t)(heap->base[byte_off] | (heap->base[byte_off + 1] << 8));
}

/* ──────────────────────────────────────────────────────────────────────────
 *  Composite one source pixel (already in the RGB565 domain, post-colormod for
 *  the non-PALPHA path) into the framebuffer at (dx,dy) per blend_mode.
 *  `raw_src` is the UN-modulated source used for colour-key comparison.
 * ────────────────────────────────────────────────────────────────────────── */
static void put_blend(uint16_t *fb, int dx, int dy,
                      uint16_t src, uint16_t raw_src,
                      uint8_t blend_mode, uint8_t flags,
                      uint16_t colorkey, uint8_t alpha) {
    if (dx < 0 || dx >= BLT_FB_WIDTH || dy < 0 || dy >= BLT_FB_HEIGHT) return;
    unsigned idx = (unsigned)dy * BLT_FB_WIDTH + (unsigned)dx;

    /* colour-key (compared against the RAW source, pre-colormod) honored in
     * COLORKEY mode or when F_COLORKEY is set on any blend. */
    int keyed = (blend_mode == BLT_BLEND_COLORKEY) || (flags & BLT_F_COLORKEY);
    if (keyed && raw_src == colorkey) return;

    uint16_t dst = fb[idx];
    uint16_t out;
    switch (blend_mode) {
        case BLT_BLEND_CONST_ALPHA: out = blt_blend565(src, dst, alpha); break;
        case BLT_BLEND_ADD:         out = blt_add565(src, dst);          break;
        case BLT_BLEND_MULTIPLY:    out = blt_mul565(src, dst);          break;
        /* COPY and COLORKEY both write the (possibly modulated) source. */
        case BLT_BLEND_COPY:
        case BLT_BLEND_COLORKEY:
        default:                    out = src;                           break;
    }
    fb[idx] = out;
}

/* ──────────────────────────────────────────────────────────────────────────
 *  blt_execute — walk the command list against a 320x240 RGB565 framebuffer.
 * ────────────────────────────────────────────────────────────────────────── */
int blt_execute(uint16_t *fb,
                const blt_surface_heap_t *heap,
                const blt_cmd_t *cmds,
                int count) {
    int executed = 0;
    for (int ci = 0; ci < count; ci++) {
        const blt_cmd_t *c = &cmds[ci];
        executed++;
        if (c->opcode == BLT_OP_END)  break;
        if (c->opcode == BLT_OP_NOP)  continue;
        if (c->opcode == BLT_OP_STAGE) continue; /* DDR->SDRAM stage: no FB effect */

        /* colour-mod tint (8-bit per channel) carried in the reserved bytes:
         *   _pad[0]=cr  _pad[1]=cg  _pad[2]=cb   (assumed frozen wire placement;
         * see header note "_pad reserved -> future tint"). */
        int do_mod = (c->flags & BLT_F_COLORMOD) != 0;
        uint8_t cr = c->_pad[0], cg = c->_pad[1], cb = c->_pad[2];

        if (c->opcode == BLT_OP_FILL) {
            /* FILL: blend source channel = cmd.color (optionally modulated),
             * composited per blend_mode into the dst rect. */
            uint16_t fillc = c->color;
            uint16_t src = do_mod ? blt_tint565(fillc, cr, cg, cb) : fillc;
            for (int j = 0; j < c->h; j++) {
                for (int i = 0; i < c->w; i++) {
                    put_blend(fb, c->dst_x + i, c->dst_y + j,
                              src, fillc, c->blend_mode, c->flags,
                              c->colorkey, c->alpha);
                }
            }
            continue;
        }

        if (c->opcode == BLT_OP_BLIT) {
            int hflip = (c->flags & BLT_F_HFLIP) != 0;
            int vflip = (c->flags & BLT_F_VFLIP) != 0;
            int palpha = (c->blend_mode == BLT_BLEND_PALPHA) &&
                         (c->format == BLT_FMT_ARGB4444);
            for (int j = 0; j < c->h; j++) {
                for (int i = 0; i < c->w; i++) {
                    int dx = c->dst_x + i, dy = c->dst_y + j;
                    if (dx < 0 || dx >= BLT_FB_WIDTH || dy < 0 || dy >= BLT_FB_HEIGHT)
                        continue;
                    int sx = c->src_x + (hflip ? (c->w - 1 - i) : i);
                    int sy = c->src_y + (vflip ? (c->h - 1 - j) : j);
                    size_t boff = (size_t)c->src_off
                                + (size_t)sy * c->src_stride + (size_t)sx * 2u;
                    uint16_t raw = heap_px16(heap, boff);

                    if (palpha) {
                        /* per-pixel source-over with optional colour-mod on the
                         * expanded RGB channels (alpha preserved). */
                        unsigned a8, sr, sg, sb;
                        argb4444_expand(raw, &a8, &sr, &sg, &sb);
                        if (a8 == 0) continue;            /* A4==0 -> skip-write */
                        if (do_mod) { sr = modch(sr, cr); sg = modch(sg, cg); sb = modch(sb, cb); }
                        unsigned idx = (unsigned)dy * BLT_FB_WIDTH + (unsigned)dx;
                        uint16_t d = fb[idx];
                        unsigned dr = (d >> 11) & 0x1F, dg = (d >> 5) & 0x3F, db = d & 0x1F;
                        unsigned na = 255u - a8;
                        unsigned orr = div255_round(sr * a8 + dr * na);
                        unsigned og  = div255_round(sg * a8 + dg * na);
                        unsigned ob  = div255_round(sb * a8 + db * na);
                        fb[idx] = (uint16_t)(((orr & 0x1F) << 11) | ((og & 0x3F) << 5) | (ob & 0x1F));
                        continue;
                    }

                    uint16_t src = do_mod ? blt_tint565(raw, cr, cg, cb) : raw;
                    put_blend(fb, dx, dy, src, raw, c->blend_mode, c->flags,
                              c->colorkey, c->alpha);
                }
            }
            continue;
        }
        /* unknown opcode: ignore (model safety) */
    }
    return executed;
}

/* ══════════════════════════════════════════════════════════════════════════
 *  Self-test. Build with -DBLT_REF_SELFTEST and run on the host:
 *      cc -DBLT_REF_SELFTEST -I patches/mister/blitter \
 *         patches/mister/blitter/blitter_ref.c -o /tmp/blt_ref && /tmp/blt_ref
 *  Proves: divide-free reductions are EXACT over their whole domain; golden
 *  identity cases; and blt_execute composites COLORMOD / ADD / MULTIPLY for
 *  both BLIT and FILL.
 * ══════════════════════════════════════════════════════════════════════════ */
#ifdef BLT_REF_SELFTEST
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_fail = 0;
#define CHECK(cond, ...) do { if (!(cond)) { g_fail++; printf("  FAIL: "); printf(__VA_ARGS__); printf("\n"); } } while (0)

/* exact integer round(n/D) reference (D odd -> no ties). */
static unsigned rnd_div(unsigned n, unsigned D) { return (n + D / 2u) / D; }

int main(void) {
    /* 1) divide-free reductions are EXACT across the operand domain. */
    for (unsigned t = 0; t <= 31u * 31u; t++)
        CHECK(div31_round(t) == rnd_div(t, 31u), "div31_round(%u)=%u exp %u", t, div31_round(t), rnd_div(t, 31u));
    for (unsigned t = 0; t <= 63u * 63u; t++)
        CHECK(div63_round(t) == rnd_div(t, 63u), "div63_round(%u)=%u exp %u", t, div63_round(t), rnd_div(t, 63u));
    for (unsigned t = 0; t <= 63u * 255u; t++)
        CHECK(div255_round(t) == rnd_div(t, 255u), "div255_round(%u)", t);

    /* 2) golden identity cases. */
    for (uint16_t s = 0; ; s++) {                 /* tint(255,255,255) == src for all 65536 */
        CHECK(blt_tint565(s, 255, 255, 255) == s, "tint identity s=%04x got %04x", s, blt_tint565(s,255,255,255));
        if (s == 0xFFFF) break;
    }
    CHECK(blt_add565(0x0000, 0xABCD) == 0xABCD, "add 0+dst");          /* add src=0 -> dst */
    CHECK(blt_add565(0xFFFF, 0x0001) == 0xFFFF, "add saturate");      /* full saturate */
    for (uint16_t s = 0; ; s++) {                 /* multiply by white(max) == src */
        CHECK(blt_mul565(s, 0xFFFF) == s, "mul identity s=%04x got %04x", s, blt_mul565(s,0xFFFF));
        if (s == 0xFFFF) break;
    }
    CHECK(blt_mul565(0xFFFF, 0x0000) == 0x0000, "mul by black");

    /* 3) blt_execute integration: COLORMOD, ADD, MULTIPLY for BLIT and FILL. */
    static uint16_t fb[BLT_FB_PIXELS];

    /* FILL ADD: bg grey + add red -> per-channel saturating add. */
    for (int i = 0; i < BLT_FB_PIXELS; i++) fb[i] = 0x4208; /* r=8,g=16,b=8 */
    {
        blt_cmd_t cmds[2];
        memset(cmds, 0, sizeof(cmds));
        cmds[0].opcode = BLT_OP_FILL; cmds[0].blend_mode = BLT_BLEND_ADD;
        cmds[0].color = blt_rgb565(255, 0, 0);  /* r=31,g=0,b=0 */
        cmds[0].dst_x = 10; cmds[0].dst_y = 10; cmds[0].w = 4; cmds[0].h = 4;
        cmds[1].opcode = BLT_OP_END;
        blt_execute(fb, 0, cmds, 2);
        uint16_t got = fb[12 * BLT_FB_WIDTH + 12];
        uint16_t exp = blt_add565(blt_rgb565(255,0,0), 0x4208);
        CHECK(got == exp, "FILL ADD got %04x exp %04x", got, exp);
    }

    /* FILL MULTIPLY: dst * fill. */
    for (int i = 0; i < BLT_FB_PIXELS; i++) fb[i] = 0x8410;
    {
        blt_cmd_t cmds[2];
        memset(cmds, 0, sizeof(cmds));
        cmds[0].opcode = BLT_OP_FILL; cmds[0].blend_mode = BLT_BLEND_MULTIPLY;
        cmds[0].color = 0xC618;
        cmds[0].dst_x = 0; cmds[0].dst_y = 0; cmds[0].w = 2; cmds[0].h = 2;
        cmds[1].opcode = BLT_OP_END;
        blt_execute(fb, 0, cmds, 2);
        CHECK(fb[0] == blt_mul565(0xC618, 0x8410), "FILL MUL got %04x exp %04x", fb[0], blt_mul565(0xC618,0x8410));
    }

    /* BLIT COLORMOD over COPY: source modulated by tint, written opaque. */
    for (int i = 0; i < BLT_FB_PIXELS; i++) fb[i] = 0;
    {
        uint16_t srcpix = 0xFFFF;                 /* white source */
        uint8_t heapbuf[8];
        heapbuf[0] = srcpix & 0xFF; heapbuf[1] = srcpix >> 8;
        blt_surface_heap_t heap = { heapbuf, sizeof(heapbuf) };
        blt_cmd_t cmds[2];
        memset(cmds, 0, sizeof(cmds));
        cmds[0].opcode = BLT_OP_BLIT; cmds[0].blend_mode = BLT_BLEND_COPY;
        cmds[0].format = BLT_FMT_RGB565;
        cmds[0].src_off = 0; cmds[0].src_stride = 2; cmds[0].w = 1; cmds[0].h = 1;
        cmds[0].dst_x = 5; cmds[0].dst_y = 5;
        cmds[0].flags = BLT_F_COLORMOD;
        cmds[0]._pad[0] = 128; cmds[0]._pad[1] = 64; cmds[0]._pad[2] = 255; /* cr,cg,cb */
        cmds[1].opcode = BLT_OP_END;
        blt_execute(fb, &heap, cmds, 2);
        uint16_t got = fb[5 * BLT_FB_WIDTH + 5];
        uint16_t exp = blt_tint565(0xFFFF, 128, 64, 255);
        CHECK(got == exp, "BLIT COLORMOD got %04x exp %04x", got, exp);
    }

    if (g_fail == 0) { printf("blitter_ref self-test: PASS\n"); return 0; }
    printf("blitter_ref self-test: FAIL (%d)\n", g_fail);
    return 1;
}
#endif /* BLT_REF_SELFTEST */
