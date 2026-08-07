/* Host unit test for palette_atlas.h (task 2.1: index recovery + palette
 * extraction). Exercises both pal_extract branches (8-bit indexed source,
 * 32-bit RGBA source) plus the >256-distinct-colours failure case.
 *
 * Build+run (from repo root):
 *   cc -I patches/mister tests/palette_atlas_test.c \
 *       $(sdl2-config --cflags --libs) -o /tmp/pa && /tmp/pa
 */
#include "palette_atlas.h"
#include <stdio.h>
#include <stdint.h>

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s (line %d)\n", msg, __LINE__); failures++; } \
} while (0)

/* ---- (a) 8-bit indexed surface: verbatim index copy + CLUT from palette ---- */
static void test_indexed(void)
{
    const int w = 2, h = 2;
    SDL_Surface* s = SDL_CreateRGBSurfaceWithFormat(0, w, h, 8, SDL_PIXELFORMAT_INDEX8);
    CHECK(s != NULL, "indexed surface created");
    if (!s) return;

    SDL_Color colors[4] = {
        {255,   0,   0, 255}, /* idx0 red    */
        {  0, 255,   0, 255}, /* idx1 green  */
        {  0,   0, 255, 255}, /* idx2 blue   */
        {255, 255,   0, 255}, /* idx3 yellow */
    };
    SDL_SetPaletteColors(s->format->palette, colors, 0, 4);

    /* known index pattern, row-major: [0,1] / [2,3] */
    uint8_t pattern[4] = {0, 1, 2, 3};
    for (int y = 0; y < h; y++) {
        uint8_t* row = (uint8_t*)s->pixels + (size_t)y * s->pitch;
        for (int x = 0; x < w; x++) row[x] = pattern[y * w + x];
    }

    pal_surface out;
    bool ok = pal_extract(s, &out);
    CHECK(ok, "indexed: pal_extract succeeds");
    if (ok) {
        CHECK(out.w == w && out.h == h, "indexed: dims copied");
        CHECK(out.index != NULL, "indexed: index plane allocated");
        for (int i = 0; i < w * h; i++) {
            CHECK(out.index[i] == pattern[i], "indexed: index copied verbatim");
        }
        for (int i = 0; i < 4; i++) {
            uint16_t expect_rgb = pal_rgb565(colors[i].r, colors[i].g, colors[i].b);
            CHECK(out.clut_rgb[i] == expect_rgb, "indexed: clut_rgb matches palette");
            CHECK(out.clut_a4[i] == 15, "indexed: clut_a4 opaque (no colorkey/alphamod)");
        }
        free(out.index);
    }
    SDL_FreeSurface(s);
}

/* ---- (a2) indexed surface with PER-ENTRY alpha (a PNG tRNS chunk) ----------
 * SDL_image stores a paletted PNG's tRNS chunk as the alpha of each SDL_Color,
 * so pal_extract_indexed must read colors[i].a. It used to derive alpha from
 * SDL_GetSurfaceAlphaMod() alone and hand every non-colorkey entry the same
 * value, silently flattening tRNS to opaque -- harmless only because the
 * indexed branch was unreachable while every image was converted to ABGR8888
 * first. 259 of the 270 paletted assets in the shipping quest carry tRNS. */
static void test_indexed_per_entry_alpha(void)
{
    const int w = 4, h = 1;
    SDL_Surface* s = SDL_CreateRGBSurfaceWithFormat(0, w, h, 8, SDL_PIXELFORMAT_INDEX8);
    CHECK(s != NULL, "tRNS surface created");
    if (!s) return;

    /* The four alpha levels the shipping quest actually uses map to a4
     * 0 / 7 / 11 / 15 through pal_alpha_to_a4's round-to-nearest. */
    SDL_Color colors[4] = {
        { 10,  20,  30,   0 }, /* fully transparent (typical tRNS index) */
        { 40,  50,  60, 119 }, /* 119/17 == 7 exactly                    */
        { 70,  80,  90, 187 }, /* 187/17 == 11 exactly                   */
        {100, 110, 120, 255 }, /* opaque                                 */
    };
    SDL_SetPaletteColors(s->format->palette, colors, 0, 4);

    uint8_t* row = (uint8_t*)s->pixels;
    for (int x = 0; x < w; x++) row[x] = (uint8_t)x;

    pal_surface out;
    bool ok = pal_extract(s, &out);
    CHECK(ok, "tRNS: pal_extract succeeds");
    if (ok) {
        const uint8_t expect_a4[4] = {0, 7, 11, 15};
        for (int i = 0; i < 4; i++) {
            CHECK(out.clut_a4[i] == expect_a4[i],
                  "tRNS: clut_a4 comes from the palette entry, not alphamod");
            CHECK(out.clut_rgb[i] == pal_rgb565(colors[i].r, colors[i].g, colors[i].b),
                  "tRNS: clut_rgb still matches the palette entry");
        }
        free(out.index);
    }
    SDL_FreeSurface(s);
}

/* ---- (b) 32-bit RGBA surface: reverse map, first-appearance order, alpha ---- */
static void test_rgba(void)
{
    const int w = 2, h = 2;
    SDL_Surface* s = SDL_CreateRGBSurfaceWithFormat(0, w, h, 32, SDL_PIXELFORMAT_RGBA32);
    CHECK(s != NULL, "rgba surface created");
    if (!s) return;

    /* pixel order (row-major): A, B, C(translucent), A again
     * expected first-appearance index order: A=0, B=1, C=2 */
    Uint32 pA = SDL_MapRGBA(s->format, 255,   0,   0, 255);
    Uint32 pB = SDL_MapRGBA(s->format,   0, 255,   0, 255);
    Uint32 pC = SDL_MapRGBA(s->format,   0,   0, 255, 127);
    Uint32 row0[2] = { pA, pB };
    Uint32 row1[2] = { pC, pA };

    memcpy((uint8_t*)s->pixels + 0 * s->pitch, row0, sizeof(row0));
    memcpy((uint8_t*)s->pixels + 1 * s->pitch, row1, sizeof(row1));

    pal_surface out;
    bool ok = pal_extract(s, &out);
    CHECK(ok, "rgba: pal_extract succeeds");
    if (ok) {
        CHECK(out.ncolors == 3, "rgba: ncolors == 3 distinct colours");
        CHECK(out.index[0] == 0, "rgba: pixel0 -> idx0 (A, first appearance)");
        CHECK(out.index[1] == 1, "rgba: pixel1 -> idx1 (B, first appearance)");
        CHECK(out.index[2] == 2, "rgba: pixel2 -> idx2 (C, first appearance)");
        CHECK(out.index[3] == 0, "rgba: pixel3 -> idx0 (A, reused)");

        CHECK(out.clut_rgb[0] == pal_rgb565(255, 0, 0), "rgba: clut_rgb[0] == A");
        CHECK(out.clut_rgb[1] == pal_rgb565(0, 255, 0), "rgba: clut_rgb[1] == B");
        CHECK(out.clut_rgb[2] == pal_rgb565(0, 0, 255), "rgba: clut_rgb[2] == C");

        CHECK(out.clut_a4[0] == 15, "rgba: clut_a4[0] opaque");
        CHECK(out.clut_a4[1] == 15, "rgba: clut_a4[1] opaque");
        CHECK(out.clut_a4[2] == 7, "rgba: clut_a4[2] == round(127/17) == 7");
        free(out.index);
    }
    SDL_FreeSurface(s);
}

/* ---- (c) overflow is measured in the CLUT's OWN colour space ----------------
 * [always-PAL8] pal_extract dedups on the quantized (RGB565, A4) pair, not on
 * the source RGBA8888, because that pair is all the CLUT can store. So the two
 * cases below are genuinely different and both must hold:
 *
 *   (c1) >256 distinct AFTER quantization  -> still fails (caller keeps 16bpp)
 *   (c2) >256 distinct BEFORE quantization but <=256 after -> now SUCCEEDS
 *
 * (c2) is not hypothetical: it is MoSDX's 9.tiles.png, the only quest asset that
 * ever failed pal_extract -- 258 distinct RGBA8888 collapsing to 90 distinct
 * (RGB565, A4). The old contract rejected it over colours the fabric cannot
 * tell apart. Note the OLD version of this test believed it was building 300
 * distinct colours while feeding r=ci&0xFF, g=(ci>>8)&0xFF, b=(ci>>16)&0xFF --
 * which quantizes to only ~32 distinct RGB565 values, so it was really a (c2)
 * case all along and passed for the wrong reason. */

/* Build a pixel whose quantized RGB565 is exactly `v` (pal_rgb565 keeps the high
 * bits, so shifting each field back up round-trips exactly). */
static Uint32 px_for_rgb565(SDL_Surface* s, int v, Uint8 a)
{
    Uint8 r = (Uint8)(((v >> 11) & 0x1F) << 3);
    Uint8 g = (Uint8)(((v >> 5)  & 0x3F) << 2);
    Uint8 b = (Uint8)(( v        & 0x1F) << 3);
    return SDL_MapRGBA(s->format, r, g, b, a);
}

static void test_too_many_colors(void)
{
    const int w = 20, h = 20; /* 400 px, first 300 carry the distinct colours */
    SDL_Surface* s = SDL_CreateRGBSurfaceWithFormat(0, w, h, 32, SDL_PIXELFORMAT_RGBA32);
    CHECK(s != NULL, "overflow surface created");
    if (!s) return;

    /* 300 pixels with 300 genuinely distinct RGB565 values (v = i round-trips
     * exactly for i < 2048), so the quantized palette really does exceed 256. */
    for (int i = 0; i < w * h; i++) {
        int v = (i < 300) ? i : 0;
        int x = i % w, y = i / w;
        ((Uint32*)((uint8_t*)s->pixels + (size_t)y * s->pitch))[x] =
            px_for_rgb565(s, v, 255);
    }

    pal_surface out;
    bool ok = pal_extract(s, &out);
    CHECK(!ok, "overflow: pal_extract fails for >256 distinct (RGB565,A4) pairs");
    if (ok) free(out.index);
    SDL_FreeSurface(s);
}

/* ---- (c2) the 9.tiles.png case: collapses under quantization -> must succeed ---- */
static void test_many_colors_collapse(void)
{
    const int w = 20, h = 20;
    SDL_Surface* s = SDL_CreateRGBSurfaceWithFormat(0, w, h, 32, SDL_PIXELFORMAT_RGBA32);
    CHECK(s != NULL, "collapse surface created");
    if (!s) return;

    /* 300 distinct RGBA8888: 100 distinct (r,g) pairs x 3 alphas that differ
     * only below the A4 step (255/254/253 all round to a4 == 15). After
     * quantization exactly 100 distinct (RGB565, A4) pairs remain. */
    for (int i = 0; i < w * h; i++) {
        int j    = (i < 300) ? i : 0;
        int base = j / 3, sub = j % 3;
        Uint8 r = (Uint8)((base % 32) << 3);
        Uint8 g = (Uint8)((base / 32) << 2);
        Uint8 a = (Uint8)(255 - sub);
        int x = i % w, y = i / w;
        ((Uint32*)((uint8_t*)s->pixels + (size_t)y * s->pitch))[x] =
            SDL_MapRGBA(s->format, r, g, 0, a);
    }

    pal_surface out;
    bool ok = pal_extract(s, &out);
    CHECK(ok, "collapse: pal_extract succeeds when >256 RGBA8888 fold to <=256 CLUT entries");
    if (ok) {
        CHECK(out.ncolors == 100, "collapse: ncolors == 100 distinct (RGB565,A4) pairs");
        /* The three sub-alphas of one base must share ONE index, not three. */
        CHECK(out.index[0] == out.index[1] && out.index[1] == out.index[2],
              "collapse: source colours that quantize together share an index");
        CHECK(out.index[3] != out.index[0],
              "collapse: a different base still gets a different index");
        CHECK(out.clut_a4[out.index[0]] == 15, "collapse: folded alpha is a4 == 15");
        free(out.index);
    }
    SDL_FreeSurface(s);
}

/* ---- (d) helpers: build a pal_surface with N synthetic distinct colours ---- */
static void make_surface(pal_surface* s, int ncolors)
{
    memset(s, 0, sizeof(*s));
    s->w = ncolors;
    s->h = 1;
    s->ncolors = ncolors;
    s->index = (uint8_t*)malloc((size_t)ncolors);
    for (int i = 0; i < ncolors; i++) {
        s->index[i] = (uint8_t)i;
        /* deterministic, distinguishable-per-i colour/alpha so packed entries
         * can be told apart later if needed */
        s->clut_rgb[i] = pal_rgb565((uint8_t)(i & 0xFF), (uint8_t)((i * 3) & 0xFF), (uint8_t)((i * 7) & 0xFF));
        s->clut_a4[i] = (uint8_t)(i & 0xF);
    }
}

static void free_surface(pal_surface* s)
{
    free(s->index);
}

/* ---- (e) pal_pack: first-fit bank packing ---- */
static void test_pack_first_fit(void)
{
    pal_bankset bs;
    pal_bankset_init(&bs);

    pal_surface s6, s15, s250;
    make_surface(&s6, 6);
    make_surface(&s15, 15);
    make_surface(&s250, 250);

    uint8_t bank6, base6, bank15, base15, bank250, base250;
    CHECK(pal_pack(&bs, &s6, &bank6, &base6), "pack: 6-colour surface packs");
    CHECK(pal_pack(&bs, &s15, &bank15, &base15), "pack: 15-colour surface packs");
    CHECK(pal_pack(&bs, &s250, &bank250, &base250), "pack: 250-colour surface packs");

    /* First surface packed lands in bank 0 -- the "tileset pinned to bank 0"
     * contract, satisfied by first-fit + pack-tileset-first calling order. */
    CHECK(bank6 == 0, "pack: first (tileset) surface pins to bank 0");
    CHECK(base6 == 0, "pack: first surface starts at base 0");

    /* 15-colour surface: first-fit continues in bank 0 (256-6=250 >= 15). */
    CHECK(bank15 == 0, "pack: 15-colour surface first-fits into bank 0");
    CHECK(base15 == 6, "pack: 15-colour surface appended after the 6-colour one");

    /* 250-colour surface: bank 0 now has 256-6-15=235 free < 250, so it must
     * land in the next bank. */
    CHECK(bank250 == 1, "pack: 250-colour surface overflows to bank 1");
    CHECK(base250 == 0, "pack: 250-colour surface starts at base 0 of its bank");

    /* Distinct, non-overlapping (bank,base) ranges for the three so far. */
    CHECK(!(bank6 == bank15 && base6 < base15 + 15 && base15 < base6 + 6),
          "pack: 6- and 15-colour ranges don't overlap");
    CHECK(!(bank6 == bank250), "pack: 6-colour and 250-colour surfaces in different banks");
    CHECK(!(bank15 == bank250), "pack: 15-colour and 250-colour surfaces in different banks");

    /* 4th surface needing 20: bank 0 has 235 free (>=20) but bank 1 only has
     * 256-250=6 free (<20) -- must land back in bank 0, not bank 1. */
    pal_surface s20;
    make_surface(&s20, 20);
    uint8_t bank20, base20;
    CHECK(pal_pack(&bs, &s20, &bank20, &base20), "pack: 20-colour surface packs");
    CHECK(bank20 == 0, "pack: 20-colour surface lands in the 6+15 bank (bank 0), not bank 1");
    CHECK(base20 == 21, "pack: 20-colour surface appended after the 6+15 (base 21)");

    /* Fill banks 2..(PAL_CLUT_BANKS-1) with 250 each so that EVERY bank is full
     * enough (>=250 used, <250 free) that one more 250-colour surface has nowhere
     * to go. Bank 0 currently holds 6+15+20=41 (215 free < 250), bank 1 holds 250.
     * This is parameterized by PAL_CLUT_BANKS so it stays correct as banks widen
     * (was hardcoded to 8; now 32). */
    const int NFILL = PAL_CLUT_BANKS - 2;   /* banks 2..PAL_CLUT_BANKS-1 */
    pal_surface *fillers = (pal_surface*)malloc(sizeof(pal_surface) * (size_t)NFILL);
    for (int i = 0; i < NFILL; i++) {
        make_surface(&fillers[i], 250);
        uint8_t fb, fbase;
        CHECK(pal_pack(&bs, &fillers[i], &fb, &fbase), "pack: filler 250-colour surface packs");
        CHECK(fb == (uint8_t)(i + 2), "pack: filler surfaces land in banks 2..N in order");
    }

    /* All PAL_CLUT_BANKS banks are now full enough that one more 250-colour
     * surface cannot fit anywhere (bank0=41 used/215 free, banks 1..N=250 used/6
     * free — all < 250 free). */
    pal_surface s250b;
    make_surface(&s250b, 250);
    uint8_t bank250b, base250b;
    CHECK(!pal_pack(&bs, &s250b, &bank250b, &base250b),
          "pack: extra 250-colour surface overflows all PAL_CLUT_BANKS banks -> false");

    free_surface(&s6);
    free_surface(&s15);
    free_surface(&s250);
    free_surface(&s20);
    free_surface(&s250b);
    for (int i = 0; i < NFILL; i++) free_surface(&fillers[i]);
    free(fillers);
}

/* ---- (f) pal_bankset_bytes: exact CLUTBUF qword layout ---- */
static void test_bankset_bytes(void)
{
    pal_bankset bs;
    pal_bankset_init(&bs);

    /* Spot entry: bank 3, slot 5 -> linear index 3*256+5 = 773. */
    const int bank = 3, slot = 5;
    const int k = bank * PAL_CLUT_ENTRIES + slot;
    const uint32_t a4 = 0xA;      /* 4 bits */
    const uint16_t rgb = 0xBEEF;  /* 16 bits (not a real colour, just distinct bits) */
    bs.entries[k] = (a4 << 16) | rgb; /* CLUT_MAKE(a4, rgb) */

    uint8_t* ddr = (uint8_t*)malloc((size_t)PAL_CLUT_BANKS * PAL_CLUT_ENTRIES * 8);
    CHECK(ddr != NULL, "bytes: ddr buffer allocated");
    if (!ddr) return;
    memset(ddr, 0xFF, (size_t)PAL_CLUT_BANKS * PAL_CLUT_ENTRIES * 8); /* poison, so zero-padding is provable */

    pal_bankset_bytes(&bs, ddr);

    /* Entry k lives at byte offset k*8: low 4 bytes = CLUT_MAKE word LE,
     * high 4 bytes = 0 (per tb_clut_upload.sv's {32'd0, pattern_word(k)}). */
    size_t off = (size_t)k * 8;
    uint32_t want = (a4 << 16) | rgb;
    uint32_t got = (uint32_t)ddr[off + 0]
                 | ((uint32_t)ddr[off + 1] << 8)
                 | ((uint32_t)ddr[off + 2] << 16)
                 | ((uint32_t)ddr[off + 3] << 24);
    CHECK(got == want, "bytes: spot entry round-trips through the qword layout (low 32 = CLUT_MAKE word, LE)");
    CHECK(ddr[off + 4] == 0, "bytes: high 4 bytes of the qword are zero (byte 4)");
    CHECK(ddr[off + 5] == 0, "bytes: high 4 bytes of the qword are zero (byte 5)");
    CHECK(ddr[off + 6] == 0, "bytes: high 4 bytes of the qword are zero (byte 6)");
    CHECK(ddr[off + 7] == 0, "bytes: high 4 bytes of the qword are zero (byte 7)");

    /* A neighbouring, never-written entry (k=0, since bank 3 slot 5 != bank 0
     * slot 0) is all-zero, not left poisoned -- pal_bankset_bytes must write
     * every entry (zero-initialized pal_bankset), not just touched ones. */
    CHECK(ddr[0] == 0 && ddr[1] == 0 && ddr[2] == 0 && ddr[3] == 0
          && ddr[4] == 0 && ddr[5] == 0 && ddr[6] == 0 && ddr[7] == 0,
          "bytes: untouched entry 0 is fully zeroed, not left poisoned");

    /* Total size sanity: last qword (index 2047) is in-bounds. */
    size_t last_off = (size_t)(PAL_CLUT_BANKS * PAL_CLUT_ENTRIES - 1) * 8;
    CHECK(last_off + 8 == (size_t)PAL_CLUT_BANKS * PAL_CLUT_ENTRIES * 8,
          "bytes: buffer size is exactly PAL_CLUT_BANKS*PAL_CLUT_ENTRIES*8 (16384) bytes");

    free(ddr);
}

int main(void)
{
    test_indexed();
    test_indexed_per_entry_alpha();
    test_rgba();
    test_too_many_colors();
    test_many_colors_collapse();
    test_pack_first_fit();
    test_bankset_bytes();

    if (failures) {
        printf("%d check(s) failed.\n", failures);
        return 1;
    }
    printf("All palette_atlas checks passed.\n");
    return 0;
}
