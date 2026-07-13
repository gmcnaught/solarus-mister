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

/* ---- (c) >256 distinct colours: pal_extract must fail (caller keeps direct-colour) ---- */
static void test_too_many_colors(void)
{
    const int w = 20, h = 20; /* 400 px, first 300 distinct */
    SDL_Surface* s = SDL_CreateRGBSurfaceWithFormat(0, w, h, 32, SDL_PIXELFORMAT_RGBA32);
    CHECK(s != NULL, "overflow surface created");
    if (!s) return;

    int n = w * h;
    for (int i = 0; i < n; i++) {
        int ci = (i < 300) ? i : 0; /* first 300 pixels distinct, rest reuse colour 0 */
        Uint8 r = (Uint8)(ci & 0xFF);
        Uint8 g = (Uint8)((ci >> 8) & 0xFF);
        Uint8 b = (Uint8)((ci >> 16) & 0xFF);
        Uint32 p = SDL_MapRGBA(s->format, r, g, b, 255);
        int x = i % w, y = i / w;
        ((Uint32*)((uint8_t*)s->pixels + (size_t)y * s->pitch))[x] = p;
    }

    pal_surface out;
    bool ok = pal_extract(s, &out);
    CHECK(!ok, "overflow: pal_extract returns false for >256 distinct colours");
    if (ok) free(out.index);
    SDL_FreeSurface(s);
}

int main(void)
{
    test_indexed();
    test_rgba();
    test_too_many_colors();

    if (failures) {
        printf("%d check(s) failed.\n", failures);
        return 1;
    }
    printf("All palette_atlas checks passed.\n");
    return 0;
}
