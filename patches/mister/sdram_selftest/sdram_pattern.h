/*
 *  sdram_pattern.h — position-encoding pattern + compare for the SDRAM round-trip
 *  self-test (issue #34 fabric debug). PURE (no I/O), shared by the native logic
 *  test (tests/sdram_selftest_logic_test.c) and the on-device binary
 *  (patches/mister/sdram_selftest/sdram_selftest.c).
 *
 *  Why a position-encoding pattern: the DE10-Nano SDRAM second bus is NOT in the
 *  HPS memory map, so the ARM cannot read SDRAM to verify a stage landed. The only
 *  observable is a DDR3->SDRAM->DDR3 round-trip: stage the pattern to a chosen
 *  SDRAM offset, blit it back from SDRAM into a DDR3 framebuffer, read the
 *  framebuffer. Each source pixel encodes its OWN coordinates:
 *      value = (y<<8) | x          (x,y in 0..255)
 *  so after a correct round-trip every framebuffer pixel equals st_pat(x,y). If a
 *  SDRAM address bit is wrong on silicon (the #31 64MB-geometry hypothesis), a
 *  pixel reads a DIFFERENT source location; decoding the wrong value yields the
 *  (x,y) it actually came from -> the alias fingerprints the geometry fault.
 *
 *  GPL-3.0.
 */
#ifndef SDRAM_PATTERN_H
#define SDRAM_PATTERN_H

#include <stdint.h>
#include <stddef.h>

#define ST_W       64
#define ST_H       64
#define ST_PIXELS  (ST_W * ST_H)
#define ST_BYTES   (ST_PIXELS * 2)      /* RGB565, packed */

/* Per-pixel position code. x,y < 256 -> unique 16-bit value per pixel. */
static inline uint16_t st_pat(int x, int y) {
    return (uint16_t)(((y & 0xFF) << 8) | (x & 0xFF));
}
static inline int st_dec_x(uint16_t v) { return (int)(v & 0xFF); }
static inline int st_dec_y(uint16_t v) { return (int)((v >> 8) & 0xFF); }

/* Fill `dst` (ST_W*ST_H uint16, packed) with the pattern. */
static inline void st_fill(uint16_t *dst) {
    for (int y = 0; y < ST_H; y++)
        for (int x = 0; x < ST_W; x++)
            dst[y * ST_W + x] = st_pat(x, y);
}

typedef struct {
    int      matched;   /* pixels == expected                        */
    int      nonzero;   /* framebuffer pixels != 0                    */
    int      first_bad; /* 1 if a mismatch was recorded              */
    int      bx, by;    /* coords (expected grid) of first mismatch  */
    uint16_t bexp;      /* expected value at first mismatch          */
    uint16_t bgot;      /* value actually read                       */
} st_result_t;

/* Compare the ST_W x ST_H region at (0,0) of framebuffer `fb` (row stride
 * `fb_stride_px` PIXELS) against the pattern. Pure; no I/O. */
static inline st_result_t st_compare(const uint16_t *fb, int fb_stride_px) {
    st_result_t r;
    r.matched = 0; r.nonzero = 0; r.first_bad = 0;
    r.bx = r.by = 0; r.bexp = r.bgot = 0;
    for (int y = 0; y < ST_H; y++) {
        for (int x = 0; x < ST_W; x++) {
            uint16_t got = fb[(size_t)y * fb_stride_px + x];
            uint16_t exp = st_pat(x, y);
            if (got != 0) r.nonzero++;
            if (got == exp) {
                r.matched++;
            } else if (!r.first_bad) {
                r.first_bad = 1;
                r.bx = x; r.by = y; r.bexp = exp; r.bgot = got;
            }
        }
    }
    return r;
}

#endif /* SDRAM_PATTERN_H */
