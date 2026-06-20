/*
 *  sdram_selftest_logic_test.c — native (no-device) test for the SDRAM round-trip
 *  self-test harness logic (issue #34). The on-device binary's verdict is only
 *  trustworthy if its pattern-gen + compare logic is itself proven; this models
 *  the DDR3->SDRAM->DDR3 round-trip (a plain RGB565 COPY blit is the fabric op
 *  under test elsewhere; here we only need the harness's own pattern/compare to
 *  be correct) and checks that:
 *    1. a CORRECT round-trip reads back the pattern 100% (st_compare all-match);
 *    2. st_pat / st_dec_x / st_dec_y round-trip (the decode used to fingerprint a
 *       geometry fault is self-consistent);
 *    3. a simulated wrong-address-bit read is CAUGHT, and the decoded "got" value
 *       points at the source pixel the bad address actually aliased to;
 *    4. an all-black framebuffer (the #34 symptom: stage never landed) is reported
 *       as nonzero=0.
 *
 *  Build/run: see tests/run_tests.sh. GPL-3.0.
 */
#include "sdram_pattern.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#define FB_W 320
#define FB_H 240
#define FB_PIXELS (FB_W * FB_H)

/* Model a fabric RGB565 COPY blit of the ST_W x ST_H source living at byte
 * `src_off` in `heap` (our stand-in for SDRAM) onto a fresh framebuffer at
 * (0,0); return st_compare over the result. */
static st_result_t roundtrip(const uint8_t *heap, uint32_t src_off) {
    static uint16_t fb[FB_PIXELS];
    memset(fb, 0, sizeof(fb));
    const uint16_t *src = (const uint16_t *)(heap + src_off);
    for (int y = 0; y < ST_H; y++)
        for (int x = 0; x < ST_W; x++)
            fb[y * FB_W + x] = src[y * ST_W + x];
    return st_compare(fb, FB_W);
}

int main(void) {
    /* --- decode self-consistency ---------------------------------------- */
    for (int y = 0; y < ST_H; y++)
        for (int x = 0; x < ST_W; x++) {
            uint16_t v = st_pat(x, y);
            assert(st_dec_x(v) == x);
            assert(st_dec_y(v) == y);
        }
    printf("  ok: st_pat/st_dec round-trip for all %d pixels\n", ST_PIXELS);

    /* Build a 'SDRAM' heap big enough for two staged copies at distinct offsets. */
    const uint32_t OFF_A = 0x00001000u;   /* aligned, low  */
    const uint32_t OFF_B = 0x00010000u;   /* aligned, high */
    size_t heap_size = OFF_B + ST_BYTES + 0x1000;
    uint8_t *heap = calloc(1, heap_size);
    assert(heap);

    uint16_t pat[ST_PIXELS];
    st_fill(pat);
    memcpy(heap + OFF_A, pat, ST_BYTES);
    memcpy(heap + OFF_B, pat, ST_BYTES);

    /* --- 1. correct round-trip is 100% --------------------------------- */
    st_result_t a = roundtrip(heap, OFF_A);
    assert(a.matched == ST_PIXELS);
    assert(a.first_bad == 0);
    assert(a.nonzero == ST_PIXELS - 1);   /* pixel (0,0) encodes value 0 */
    st_result_t b = roundtrip(heap, OFF_B);
    assert(b.matched == ST_PIXELS);
    assert(b.first_bad == 0);
    printf("  ok: correct round-trip at OFF_A and OFF_B both 100%% (%d/%d)\n",
           a.matched, ST_PIXELS);

    /* --- 2. a wrong-address read is CAUGHT and decoded ------------------ */
    /* Corrupt the value at source pixel (5,5) so it carries the code of a
     * DIFFERENT pixel (9,3), as a bad address bit would. The compare must flag
     * (5,5) and the decoded "got" must point at (9,3). */
    uint16_t *srcA = (uint16_t *)(heap + OFF_A);
    srcA[5 * ST_W + 5] = st_pat(9, 3);
    st_result_t c = roundtrip(heap, OFF_A);
    assert(c.first_bad == 1);
    assert(c.bx == 5 && c.by == 5);
    assert(c.bexp == st_pat(5, 5));
    assert(st_dec_x(c.bgot) == 9 && st_dec_y(c.bgot) == 3);
    assert(c.matched == ST_PIXELS - 1);
    printf("  ok: corruption at (5,5) caught; decoded alias -> (%d,%d)\n",
           st_dec_x(c.bgot), st_dec_y(c.bgot));

    /* --- 3. all-black framebuffer (stage never landed -> the #34 symptom) */
    static uint16_t black[FB_PIXELS];
    memset(black, 0, sizeof(black));
    st_result_t z = st_compare(black, FB_W);
    assert(z.nonzero == 0);
    assert(z.matched == 1);          /* only pixel (0,0), whose code is 0 */
    assert(z.first_bad == 1);
    printf("  ok: all-black framebuffer reports nonzero=0 (the #34 symptom)\n");

    free(heap);
    printf("sdram_selftest_logic: all assertions passed.\n");
    return 0;
}
