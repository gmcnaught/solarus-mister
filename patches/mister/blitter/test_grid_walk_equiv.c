/* [Stage 3b Phase B3 / Task 2] grid_walk_equiv_test — prove the BLT_OP_TILEMAP
 * grid walk (blt_ref_tilemap, the golden model B2's RTL tilemap_unit is
 * validated against) is PIXEL-IDENTICAL to a per-tile reference blit, and pin
 * three walker behaviours:
 *
 *   A) FULL CULL              — a fully off-screen grid issues zero blits and
 *                               leaves the framebuffer untouched.
 *   B) MAXIMAL 16-CELL RUN    — one 16x1-cell pattern (128px) builds to a single
 *                               cell with run_m1=15 and walks as ONE blit that is
 *                               pixel-identical to SIXTEEN 1-cell reference blits.
 *   C) NEGATIVE-BIAS EDGE CLIP — a grid whose left edge sits at bias_x=-12 clips
 *                               each per-tile dst in SIGNED space (the #24 class:
 *                               a negative destination must clip, never wrap).
 *
 * Harness modeled VERBATIM on test_tilelist_res_equals_n_blits() in
 * blitter_ref.c (Phase B1's tilemap/grid equivalence self-test): same
 * framebuffer allocation, same FRT/CFT surface-heap wiring, same "path A vs a
 * hand-expanded array of BLT_OP_BLIT commands run through blt_execute" +
 * memcmp scaffolding. This test only adds the three grid-walk scenarios in that
 * same style.
 *
 * The reference decomposes every run into individual 1-cell BLITs and lets
 * blit_one() perform the per-pixel signed clip (blt_ref_tilemap is already
 * proven by B1, so the reference deliberately reuses the SAME clipper rather
 * than re-implementing clipping — a run of N is pixel-identical to N 1-cell
 * blits per grid_cell.h's contract).
 *
 * Build:  cc -I patches/mister/blitter -o /tmp/gwe \
 *            patches/mister/blitter/grid_walk_equiv_test.c \
 *            patches/mister/blitter/blitter_ref.c && /tmp/gwe
 */
#include "blitter_ref.h"
#include "grid_cell.h"
#include "grid_build.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#ifdef BLT_REF_COUNT_ISSUES
extern unsigned long blt_ref_issue_count;   /* increments once per blit_one() */
#endif

/* Shared deterministic atlas: 256x64 RGB565, distinct-per-pixel so a src-offset
 * bug (wrong sub_x / stride) would perturb the compared framebuffers. */
enum { ATLAS_W = 256, ATLAS_H = 64 };
static uint16_t g_atlas[ATLAS_W * ATLAS_H];

static void atlas_init(void) {
    for (int i = 0; i < ATLAS_W * ATLAS_H; i++)
        g_atlas[i] = (uint16_t)((unsigned)i * 2654435761u);   /* Knuth hash */
}

/* Shared BLT_OP_TILEMAP header: opaque RGB565 COPY out of the atlas. */
static blt_cmd_t tilemap_header(void) {
    blt_cmd_t h;
    memset(&h, 0, sizeof h);
    h.opcode     = BLT_OP_TILEMAP;
    h.blend_mode = BLT_BLEND_COPY;
    h.format     = BLT_FMT_RGB565;
    h.src_off    = 0;
    h.src_stride = (uint16_t)(ATLAS_W * 2);
    return h;
}

/* Build the per-tile REFERENCE as an array of 1-cell (8x8) BLT_OP_BLIT commands,
 * one per non-empty cell in the visible window — the window computed with the
 * SAME floor(cx0)/ceil(cx1) rounding blt_ref_tilemap uses. Each blit's dst is
 * computed in a wide SIGNED int and only THEN cast to the command's int16_t
 * field, so blit_one()'s per-pixel signed clip handles negative destinations
 * (the #24 rule). Returns the blit count; out[] gets a trailing BLT_OP_END. */
static int build_ref_blits(blt_cmd_t *out, int out_cap,
                           const blt_grid_cell_t *cells,
                           uint16_t grid_w, uint16_t grid_h,
                           const blt_frame_rect_t *frt, const uint16_t *cft,
                           int16_t bias_x, int16_t bias_y,
                           const blt_cmd_t *hdr) {
    const int grid_px_w = (int)grid_w * 8;
    const int grid_px_h = (int)grid_h * 8;
    const int vis_lo_x = bias_x > 0 ? bias_x : 0;
    const int vis_hi_x = (bias_x + grid_px_w) < BLT_FB_WIDTH  ? (bias_x + grid_px_w) : BLT_FB_WIDTH;
    const int vis_lo_y = bias_y > 0 ? bias_y : 0;
    const int vis_hi_y = (bias_y + grid_px_h) < BLT_FB_HEIGHT ? (bias_y + grid_px_h) : BLT_FB_HEIGHT;

    int n = 0;
    if (vis_lo_x < vis_hi_x && vis_lo_y < vis_hi_y) {         /* else: fully culled */
        int cx0 = (vis_lo_x - bias_x) / 8;                   /* floor (numerator >= 0) */
        int cx1 = (vis_hi_x - bias_x + 7) / 8;               /* ceil */
        int cy0 = (vis_lo_y - bias_y) / 8;                   /* floor */
        int cy1 = (vis_hi_y - bias_y + 7) / 8;               /* ceil */
        if (cx1 > grid_w) cx1 = grid_w;
        if (cy1 > grid_h) cy1 = grid_h;

        for (int cy = cy0; cy < cy1; cy++) {
            for (int cx = cx0; cx < cx1; cx++) {
                blt_grid_cell_t c = cells[(size_t)cy * grid_w + (size_t)cx];
                if (blt_grid_cell_is_empty(c)) continue;     /* skip empties one at a time */
                uint16_t pid   = blt_grid_cell_pid(c);
                uint8_t  sub_x = blt_grid_cell_sub_x(c);
                uint8_t  sub_y = blt_grid_cell_sub_y(c);
                uint16_t frame = cft ? cft[pid] : 0;
                blt_frame_rect_t r = frt[(size_t)pid * BLT_MAXF + frame];

                assert(n < out_cap - 1);
                blt_cmd_t b = *hdr;                           /* inherit shared params */
                b.opcode = BLT_OP_BLIT;
                b.src_x  = (uint16_t)(r.src_x + (uint16_t)(sub_x * 8u));
                b.src_y  = (uint16_t)(r.src_y + (uint16_t)(sub_y * 8u));
                b.w      = 8;
                b.h      = 8;
                int dst_x = cx * 8 + bias_x;                  /* WIDE SIGNED, then cast */
                int dst_y = cy * 8 + bias_y;
                b.dst_x  = (int16_t)dst_x;
                b.dst_y  = (int16_t)dst_y;
                out[n++] = b;
            }
        }
    }
    memset(&out[n], 0, sizeof out[n]);
    out[n].opcode = BLT_OP_END;
    return n;
}

static int g_fail = 0;
#define CHECK(cond, msg) do { if (!(cond)) { g_fail++; printf("  FAIL: %s\n", msg); } } while (0)

/* ── Scenario A — FULL CULL ────────────────────────────────────────────────
 * 4x4-cell grid fully painted with a 1x1 pattern; bias_x far off the left of
 * the FB. (The plan's -100000 does not fit the int16_t bias field the wire
 * carries — src_x reinterpreted signed — so -30000 is used: equally fully
 * culling for a 32px-wide grid, and the farthest-off value the ABI permits.)
 * The grid walk must issue ZERO blits and leave the framebuffer all-zero. */
static void scenario_a_full_cull(void) {
    enum { GW = 4, GH = 4 };
    const int16_t bias_x = -30000, bias_y = 0;

    static blt_frame_rect_t frt[BLT_MAXP * BLT_MAXF];
    memset(frt, 0, sizeof frt);
    frt[0 * BLT_MAXF + 0] = (blt_frame_rect_t){ 0, 0, 8, 8 };   /* pattern 0: 1x1 cell */

    /* Paint all 16 cells with 1x1 instances of pattern 0. */
    blt_grid_tile_t tiles[GW * GH];
    int nt = 0;
    for (uint16_t y = 0; y < GH; y++)
        for (uint16_t x = 0; x < GW; x++)
            tiles[nt++] = (blt_grid_tile_t){ 0, x, y, 1, 1 };
    static blt_grid_cell_t cells[GW * GH];
    int rc = blt_grid_build(cells, GW, GH, tiles, (size_t)nt);
    CHECK(rc == 0, "A: grid build failed");

    blt_surface_heap_t h = { .base = (const uint8_t *)g_atlas, .size = sizeof g_atlas,
                             .frt = (const uint8_t *)frt, .cft = NULL,
                             .clut = NULL, .grid = (const uint8_t *)cells };
    blt_cmd_t hdr = tilemap_header();

    static uint16_t fb_grid[BLT_FB_PIXELS], fb_ref[BLT_FB_PIXELS];
    memset(fb_grid, 0, sizeof fb_grid);
    memset(fb_ref,  0, sizeof fb_ref);   /* NEVER touched */

#ifdef BLT_REF_COUNT_ISSUES
    unsigned long c0 = blt_ref_issue_count;
#endif
    blt_ref_tilemap(fb_grid, &h, &hdr, /*cells_off=*/0, GW, GH, bias_x, bias_y);
#ifdef BLT_REF_COUNT_ISSUES
    CHECK(blt_ref_issue_count - c0 == 0, "A: cull issued blits");
#endif

    int all_zero = 1;
    for (int i = 0; i < BLT_FB_PIXELS; i++) if (fb_grid[i]) { all_zero = 0; break; }
    CHECK(all_zero, "A: culled framebuffer not all-zero");
    CHECK(memcmp(fb_grid, fb_ref, sizeof fb_grid) == 0, "A: fb_grid != untouched fb_ref");
}

/* ── Scenario B — MAXIMAL 16-CELL RUN, end to end ──────────────────────────
 * One 16x1-cell (128px) pattern fully on-screen. blt_grid_build collapses it to
 * cells with run_m1 up to 15 on the leftmost cell; the walk emits ONE 128px-wide
 * blit. That must equal SIXTEEN individual 1-cell (8px) blits from the same
 * atlas. Grid walk issues 1 blit; the reference issues 16. */
static void scenario_b_maximal_run(void) {
    enum { GW = 16, GH = 1 };
    const int16_t bias_x = 40, bias_y = 24;   /* fully on-screen: px 40..167 x 24..31 */

    static blt_frame_rect_t frt[BLT_MAXP * BLT_MAXF];
    memset(frt, 0, sizeof frt);
    frt[0 * BLT_MAXF + 0] = (blt_frame_rect_t){ 0, 0, 128, 8 };  /* 16-cell-wide pattern */

    blt_grid_tile_t tiles[1] = { { 0, 0, 0, 16, 1 } };           /* one 16x1 instance */
    static blt_grid_cell_t cells[GW * GH];
    int rc = blt_grid_build(cells, GW, GH, tiles, 1);
    CHECK(rc == 0, "B: grid build failed");
    /* The leftmost cell must carry the maximal run (run_m1 == 15). */
    CHECK(blt_grid_cell_run(cells[0]) == 16, "B: leftmost run != 16");

    blt_surface_heap_t h = { .base = (const uint8_t *)g_atlas, .size = sizeof g_atlas,
                             .frt = (const uint8_t *)frt, .cft = NULL,
                             .clut = NULL, .grid = (const uint8_t *)cells };
    blt_cmd_t hdr = tilemap_header();

    static uint16_t fb_grid[BLT_FB_PIXELS], fb_ref[BLT_FB_PIXELS];
    memset(fb_grid, 0, sizeof fb_grid);
    memset(fb_ref,  0, sizeof fb_ref);

#ifdef BLT_REF_COUNT_ISSUES
    unsigned long c0 = blt_ref_issue_count;
#endif
    blt_ref_tilemap(fb_grid, &h, &hdr, 0, GW, GH, bias_x, bias_y);
#ifdef BLT_REF_COUNT_ISSUES
    CHECK(blt_ref_issue_count - c0 == 1, "B: run did not collapse to ONE blit");
    unsigned long c1 = blt_ref_issue_count;
#endif

    blt_cmd_t ref[64];
    int nb = build_ref_blits(ref, 64, cells, GW, GH, frt, NULL, bias_x, bias_y, &hdr);
    CHECK(nb == 16, "B: reference did not expand to 16 blits");
    blt_execute(fb_ref, &h, ref, nb + 1);
#ifdef BLT_REF_COUNT_ISSUES
    CHECK(blt_ref_issue_count - c1 == 16, "B: reference issued != 16 blits");
#endif

    CHECK(memcmp(fb_grid, fb_ref, sizeof fb_grid) == 0, "B: 16-run != 16 1-cell blits");
}

/* ── Scenario C — NEGATIVE-BIAS EDGE CLIP (#24) ────────────────────────────
 * A 6-cell-wide pattern in an 8-wide grid, walked with bias_x=-12: cell 0 is
 * fully off the left (dst px -12..-5, culled by the window's floor cx0=1), cell
 * 1 straddles x=0 (dst px -4..3 — only 0..3 visible). If the destination were
 * cast to unsigned BEFORE clipping, -4 -> 65532 and cell 1 would vanish. The
 * per-tile reference clips in signed space (blit_one) and must match. */
static void scenario_c_negative_bias_clip(void) {
    enum { GW = 8, GH = 2 };
    const int16_t bias_x = -12, bias_y = 5;

    static blt_frame_rect_t frt[BLT_MAXP * BLT_MAXF];
    memset(frt, 0, sizeof frt);
    frt[0 * BLT_MAXF + 0] = (blt_frame_rect_t){ 16, 8, 48, 8 };  /* 6-cell-wide pattern */

    /* One 6x1 instance on each row, leaving cells 6,7 empty (exercises the
     * empty-skip too). Row starts at cell_x=0, so bias_x=-12 straddles x=0. */
    blt_grid_tile_t tiles[2] = { { 0, 0, 0, 6, 1 }, { 0, 0, 1, 6, 1 } };
    static blt_grid_cell_t cells[GW * GH];
    int rc = blt_grid_build(cells, GW, GH, tiles, 2);
    CHECK(rc == 0, "C: grid build failed");

    blt_surface_heap_t h = { .base = (const uint8_t *)g_atlas, .size = sizeof g_atlas,
                             .frt = (const uint8_t *)frt, .cft = NULL,
                             .clut = NULL, .grid = (const uint8_t *)cells };
    blt_cmd_t hdr = tilemap_header();

    static uint16_t fb_grid[BLT_FB_PIXELS], fb_ref[BLT_FB_PIXELS];
    memset(fb_grid, 0, sizeof fb_grid);
    memset(fb_ref,  0, sizeof fb_ref);

    blt_ref_tilemap(fb_grid, &h, &hdr, 0, GW, GH, bias_x, bias_y);

    blt_cmd_t ref[64];
    int nb = build_ref_blits(ref, 64, cells, GW, GH, frt, NULL, bias_x, bias_y, &hdr);
    blt_execute(fb_ref, &h, ref, nb + 1);

    /* Sanity: something IS drawn (the straddling cell is partly visible), so a
     * both-empty false pass is ruled out. */
    int any = 0;
    for (int i = 0; i < BLT_FB_PIXELS; i++) if (fb_grid[i]) { any = 1; break; }
    CHECK(any, "C: nothing drawn — grid fully culled unexpectedly");
    CHECK(memcmp(fb_grid, fb_ref, sizeof fb_grid) == 0,
          "C: negative-bias run != signed-clipped per-tile reference");
}

int main(void) {
    atlas_init();
    scenario_a_full_cull();
    scenario_b_maximal_run();
    scenario_c_negative_bias_clip();

    if (g_fail) { printf("grid_walk_equiv_test FAILED (%d)\n", g_fail); return 1; }
    printf("grid_walk_equiv_test OK\n");
    return 0;
}
