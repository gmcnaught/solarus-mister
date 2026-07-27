// Pure load-progress-bar geometry math (issue #72). Header-only, no SDL/Solarus
// deps so it links into both mister_blitter_renderer.cpp and the host unit test.
//
// loadbar_cells_filled: how many of `cells` discrete bar cells are lit for
// `staged`/`total` progress. Clamped to [0, cells]; guards total == 0.
#ifndef MISTER_LOADBAR_H
#define MISTER_LOADBAR_H

#include <stdint.h>

static inline int loadbar_cells_filled(int cells, uint32_t staged, uint32_t total)
{
    if (total == 0u || staged == 0u) return 0;
    if (staged >= total)             return cells;
    /* 64-bit product so cells*staged can't overflow at large asset counts. */
    return (int)(((uint64_t)(uint32_t)cells * staged) / total);
}

/* ---- "Loading..." label bitmap (1bpp) -------------------------------------
 * A fixed strip, not a font: the string never changes, so there is no glyph
 * indexing. Ten 8px character cells => each row is exactly 10 bytes and each
 * byte is one cell, MSB-first (bit 7 = leftmost pixel). Glyphs are 5px wide in
 * the high bits with a 3px gap. Cap/ascender rows 0-6, x-height rows 2-6,
 * baseline row 6, descender row 7 (only 'g' uses it).
 *
 * Authored in the OSD's blocky idiom; NOT a copy of Main_MiSTer's charfont
 * glyphs, which are not available in this repo.
 *
 *   cell:   0 'L'  1 'o'  2 'a'  3 'd'  4 'i'  5 'n'  6 'g'  7-9 '.'
 *
 * The table below renders as (verified by expanding the bits):
 *
 *   #...........................#.....#.............................................
 *   #...........................#...................................................
 *   #........###.....###.....####.....#.....#.##.....####...........................
 *   #.......#...#.......#...#...#.....#.....##..#...#...#...........................
 *   #.......#...#....####...#...#.....#.....#...#...#...#...........................
 *   #.......#...#...#...#...#...#.....#.....#...#....####...........................
 *   #####....###.....####....####.....#.....#...#.......#....#.......#.......#......
 *   .................................................###............................
 */
#define LOADBAR_LABEL_W        80
#define LOADBAR_LABEL_H         8
#define LOADBAR_LABEL_BYTES    10   /* LOADBAR_LABEL_W / 8 */
/* The densest rows (3-6) carry 11 runs; 16 gives headroom. */
#define LOADBAR_LABEL_MAX_RUNS 16

typedef struct { int x0; int len; } loadbar_run_t;

static const uint8_t loadbar_label_bits[LOADBAR_LABEL_H][LOADBAR_LABEL_BYTES] = {
    /*        L     o     a     d     i     n     g     .     .     .   */
    /* 0 */ { 0x80, 0x00, 0x00, 0x08, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00 },
    /* 1 */ { 0x80, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    /* 2 */ { 0x80, 0x70, 0x70, 0x78, 0x20, 0xB0, 0x78, 0x00, 0x00, 0x00 },
    /* 3 */ { 0x80, 0x88, 0x08, 0x88, 0x20, 0xC8, 0x88, 0x00, 0x00, 0x00 },
    /* 4 */ { 0x80, 0x88, 0x78, 0x88, 0x20, 0x88, 0x88, 0x00, 0x00, 0x00 },
    /* 5 */ { 0x80, 0x88, 0x88, 0x88, 0x20, 0x88, 0x78, 0x00, 0x00, 0x00 },
    /* 6 */ { 0xF8, 0x70, 0x78, 0x78, 0x20, 0x88, 0x08, 0x40, 0x40, 0x40 },
    /* 7 */ { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x70, 0x00, 0x00, 0x00 },
};

/* Extract the horizontal runs of set pixels in `row` into `out` (at most `max`).
 * Returns the number written. A flat column scan, so runs spanning a byte
 * boundary are joined correctly. Returns 0 for an out-of-range row, a NULL
 * `out`, or a non-positive `max`. */
static inline int loadbar_label_runs(int row, loadbar_run_t *out, int max)
{
    int n = 0, x = 0, run_x0 = 0, in_run = 0;

    if (row < 0 || row >= LOADBAR_LABEL_H || out == 0 || max <= 0) return 0;

    for (x = 0; x < LOADBAR_LABEL_W; x++) {
        int bit = (loadbar_label_bits[row][x >> 3] >> (7 - (x & 7))) & 1;
        if (bit && !in_run) { in_run = 1; run_x0 = x; }
        else if (!bit && in_run) {
            in_run = 0;
            out[n].x0 = run_x0; out[n].len = x - run_x0;
            if (++n >= max) return n;
        }
    }
    if (in_run) {   /* run reaching the right edge */
        out[n].x0 = run_x0; out[n].len = LOADBAR_LABEL_W - run_x0;
        n++;
    }
    return n;
}

#endif // MISTER_LOADBAR_H
