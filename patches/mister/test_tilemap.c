/* Stage 3b Phase B1 Task 5 -- the acceptance gate: one BLT_OP_TILEMAP grid must
 * render BYTE-IDENTICALLY to the per-tile OP_BLIT path it replaces. GPL-3.0.
 *
 * Structural template: patches/mister/test_spritelist.c (two framebuffers, two
 * heaps with IDENTICAL texture layout, blt_execute each, memcmp, first-divergence
 * report). Adapted for the grid opcode:
 *
 *   Path A (reference)  : the tiles emitted as individual OP_BLITs, one per
 *                          placed tile (its FULL w_cells x h_cells rect), in
 *                          painter's order -- via the real emitter's blt_blit,
 *                          so this exercises the actual header pack/unpack too.
 *   Path B (under test)  : blt_grid_build() over the SAME tiles, then ONE
 *                          blt_grid_list() -- the real emitter call Task 3 added
 *                          -- executed against blt_ref_tilemap (Task 4).
 *
 * Both paths share ONE texture atlas (g_atlas) and ONE pattern table (PATTERNS),
 * so a pattern's resolved source rect is defined exactly once: Path A reads it
 * directly, Path B resolves it through the FRT/CFT tables blt_ref_tilemap uses
 * (the same per-pattern frame-rect table BLT_OP_TILELIST_RES uses). If the two
 * paths ever disagree, that is a real defect in the grid pipeline, not a test
 * artifact -- the whole point of a byte-exact memcmp gate.
 *
 * 9 scenarios (7 from the brief + 2 mandatory additions, from the Task 4 and
 * Task 5/6 reviews):
 *   1. 1x1 patterns only.
 *   2. Multi-cell patterns (3x2, 2x1, 1x3) -- sub-offsets + run coalescing.
 *   3. Adjacent same-pattern instances -- must NOT wrongly merge.
 *   4. Overlapping tiles -- painter's order observable.
 *   5. Non-zero bias, both signs (fully on-screen, no clipping).
 *   6. Window clipping on all four edges (8-aligned bias).
 *   7. Empty cells interspersed.
 *   8. [MANDATORY, Task 4 review] non-8-aligned bias (-13,-7) combined with a
 *      multi-cell run partially off the LEFT edge and, separately, one
 *      partially off the RIGHT edge -- the case that would hide a golden-model
 *      or emitter clipping bug that only 8px-aligned biases can't reach (the
 *      COARSE cell-window cull vs the FINE per-pixel destination clip).
 *   9. [MANDATORY, Task 5/6 review] a 5-cell run whose right end is clamped
 *      exactly at the framebuffer edge -- makes the right-edge run clamp in
 *      blt_ref_tilemap (blitter_ref.c) load-bearing to something other than
 *      pixel content. Task 5 proved the clamp is memcmp-invisible (blit_one's
 *      per-pixel clip already discards the off-screen pixels a wider blit
 *      would touch); this scenario asserts on the ISSUED BLIT'S extent
 *      (blt_ref_tilemap_max_right_x, Task 6 instrumentation) instead of on
 *      pixels, so removing the clamp is caught even though the framebuffer
 *      would still memcmp clean.
 *
 * When built with -DBLT_REF_COUNT_ISSUES (build_test_tilemap.sh always does),
 * every scenario also prints Path A's blit count, Path B's blit count, and
 * their ratio (blt_ref_issue_count instrumentation, Task 6), and asserts the
 * loose sanity bound Path B <= 4x Path A. This is NOT a performance gate --
 * see blitter_ref.c's Task 6 comment block; the number exists so B2/B3 start
 * from a measurement instead of the ~3x estimate that motivated run
 * coalescing.
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "blitter_ref.h"
#include "blt_wire.h"
#include "blt_emitter.h"
#include "grid_build.h"

/* [Stage 3b / grid, Phase B1 Task 6] Transaction-count instrumentation.
 * blitter_ref.c defines these under #ifdef BLT_REF_COUNT_ISSUES (see its
 * Task 6 comment block); blitter_ref.h is VENDORED (not ours to edit -- see
 * its header comment), so declare them here directly rather than adding
 * declarations upstream for a host-test-only feature.
 *   blt_ref_issue_count         : increments once per blit_one() call, i.e.
 *                                 once per blit issued by EITHER path.
 *   blt_ref_tilemap_max_right_x : high-water mark of (dst_x+w) across every
 *                                 blit the grid walk (blt_ref_tilemap) has
 *                                 issued since last reset by the caller. */
#ifdef BLT_REF_COUNT_ISSUES
#include <limits.h>
extern unsigned long blt_ref_issue_count;
extern int blt_ref_tilemap_max_right_x;
#endif

/* ── Shared texture atlas + pattern table ───────────────────────────────────
 * All pattern rects are disjoint, 8px-aligned sub-rects of one atlas, so every
 * scenario below draws from the SAME uploaded texture (Path A and Path B each
 * upload their own copy, exactly like test_spritelist.c's heap_a/heap_b). */
#define ATLASW 96
#define ATLASH 48

static uint16_t g_atlas[ATLASW * ATLASH];

typedef struct { uint16_t pid; uint16_t sx, sy, w, h; } pat_t;

enum {
    PAT_A = 0, PAT_B, PAT_C,
    PAT_MULTI_3x2, PAT_MULTI_2x1, PAT_MULTI_1x3,
    PAT_OVERLAP_BASE, PAT_OVERLAP_TOP,
    PAT_CLIP5,
    N_PAT
};

static const pat_t PATTERNS[N_PAT] = {
    { PAT_A,              0,  0,  8,  8 },  /* 1x1 */
    { PAT_B,               8,  0,  8,  8 },  /* 1x1 */
    { PAT_C,              16,  0,  8,  8 },  /* 1x1 */
    { PAT_MULTI_3x2,        0,  8, 24, 16 }, /* 3 cells x 2 cells */
    { PAT_MULTI_2x1,       24,  8, 16,  8 }, /* 2 cells x 1 cell  */
    { PAT_MULTI_1x3,       40,  8,  8, 24 }, /* 1 cell  x 3 cells */
    { PAT_OVERLAP_BASE,    48,  8, 16, 16 }, /* 2x2 -- "earlier" tile     */
    { PAT_OVERLAP_TOP,     64,  8,  8,  8 }, /* 1x1 -- "later" tile       */
    { PAT_CLIP5,            0, 32, 40,  8 }, /* 5 cells x 1 cell (clip runs) */
};

/* Shared FRT/CFT for Path B -- the SAME per-pattern frame-rect table
 * BLT_OP_TILELIST_RES uses (blt_ref_tilemap resolves FRT[pid][CFT[pid]]). */
static blt_frame_rect_t g_frt[BLT_MAXP * BLT_MAXF];
static uint16_t         g_cft[BLT_MAXP];

static void init_atlas_and_tables(void)
{
    for (int y = 0; y < ATLASH; y++)
        for (int x = 0; x < ATLASW; x++)
            g_atlas[y * ATLASW + x] =
                (uint16_t)(((unsigned)x * 769u) ^ ((unsigned)y * 233u + 41u)) + 0x1357u;

    memset(g_frt, 0, sizeof g_frt);
    memset(g_cft, 0, sizeof g_cft);
    for (int i = 0; i < N_PAT; i++) {
        const pat_t *p = &PATTERNS[i];
        g_frt[(size_t)p->pid * BLT_MAXF + 0] =
            (blt_frame_rect_t){ p->sx, p->sy, p->w, p->h };
        g_cft[p->pid] = 0;
    }
}

/* ── Scenario runner ────────────────────────────────────────────────────── */
#define MAX_TILES       24
#define MAX_CMDS_A      40
#define MAX_GRID_CELLS  ((size_t)64 * 64)

static int run_scenario(const char *name,
                        const blt_grid_tile_t *tiles, int n_tiles,
                        uint16_t grid_w, uint16_t grid_h,
                        int16_t bias_x, int16_t bias_y)
{
    static uint16_t fb_a[BLT_FB_PIXELS];
    static uint16_t fb_b[BLT_FB_PIXELS];
    static uint8_t  heapA[ATLASW * ATLASH * 2 + 256];
    static uint8_t  heapB[ATLASW * ATLASH * 2 + 256];
    static uint8_t  ringA[BLT_CMD_BYTES * MAX_CMDS_A];
    static uint8_t  ringB[BLT_CMD_BYTES * 4];
    static blt_grid_cell_t cells[MAX_GRID_CELLS];

    if ((size_t)grid_w * (size_t)grid_h > MAX_GRID_CELLS) {
        printf("FAIL[%s]: grid %ux%u exceeds test fixture capacity\n", name, grid_w, grid_h);
        return 1;
    }
    if (n_tiles > MAX_TILES) {
        printf("FAIL[%s]: %d tiles exceeds test fixture capacity\n", name, n_tiles);
        return 1;
    }

#ifdef BLT_REF_COUNT_ISSUES
    unsigned long count_a_before = blt_ref_issue_count;
    unsigned long count_a = 0, count_b = 0;
#endif

    /* ---- Path A: N individual OP_BLITs, painter's order, via the real
     * emitter (blt_blit) -- one full w_cells x h_cells rect per placed tile,
     * exactly as the per-tile path this opcode replaces would emit. ---- */
    blt_emitter_t eA;
    blt_emitter_init(&eA, ringA, sizeof ringA, heapA, sizeof heapA);
    blt_begin_frame(&eA, 0, 0, 0);
    blt_surface_ref_t texA = blt_upload(&eA, g_atlas, ATLASW, ATLASH, ATLASW * 2);
    if (!texA.valid) { printf("FAIL[%s]: path A texture upload failed\n", name); return 1; }
    for (int i = 0; i < n_tiles; i++) {
        const pat_t *p = &PATTERNS[tiles[i].pid];
        int dx = (int)tiles[i].cell_x * 8 + bias_x;
        int dy = (int)tiles[i].cell_y * 8 + bias_y;
        int w  = (int)tiles[i].w_cells * 8;
        int h  = (int)tiles[i].h_cells * 8;
        if (blt_blit(&eA, texA, p->sx, p->sy, w, h, dx, dy,
                     BLT_BLEND_COPY, 0, 255, 0) != 0) {
            printf("FAIL[%s]: path A blt_blit[%d] overflow\n", name, i);
            return 1;
        }
    }
    blt_end_frame(&eA);
    {
        blt_cmd_t cmds_a[MAX_CMDS_A];
        for (int i = 0; i < eA.cmd_count; i++)
            blt_unpack_cmd(ringA + (size_t)i * BLT_CMD_BYTES, &cmds_a[i]);
        blt_surface_heap_t heap_a = { heapA, sizeof heapA, NULL, NULL, NULL, NULL };
        memset(fb_a, 0, sizeof fb_a);
        blt_execute(fb_a, &heap_a, cmds_a, eA.cmd_count);
    }
#ifdef BLT_REF_COUNT_ISSUES
    count_a = blt_ref_issue_count - count_a_before;
#endif

    /* ---- Path B: blt_grid_build over the SAME tiles, then ONE blt_grid_list
     * (the real Task 3 emitter call) executed via blt_execute/blt_ref_tilemap
     * (Task 4). ---- */
    if (blt_grid_build(cells, grid_w, grid_h, tiles, (size_t)n_tiles) != 0) {
        printf("FAIL[%s]: blt_grid_build rejected the tile list\n", name);
        return 1;
    }
#ifdef BLT_REF_COUNT_ISSUES
    unsigned long count_b_before = blt_ref_issue_count;
    blt_ref_tilemap_max_right_x = INT_MIN;   /* reset the grid-walk high-water mark */
#endif
    blt_emitter_t eB;
    blt_emitter_init(&eB, ringB, sizeof ringB, heapB, sizeof heapB);
    blt_begin_frame(&eB, 0, 0, 0);
    blt_surface_ref_t texB = blt_upload(&eB, g_atlas, ATLASW, ATLASH, ATLASW * 2);
    if (!texB.valid) { printf("FAIL[%s]: path B texture upload failed\n", name); return 1; }
    blt_grid_list_init(&eB, 0, (uint32_t)((size_t)grid_w * grid_h * sizeof(blt_grid_cell_t)));
    if (blt_grid_list(&eB, texB, BLT_BLEND_COPY, 0, 255, 0,
                      /*cells_off=*/0, grid_w, grid_h, bias_x, bias_y, /*pal_color=*/0) != 0) {
        printf("FAIL[%s]: blt_grid_list overflow\n", name);
        return 1;
    }
    blt_end_frame(&eB);
    {
        blt_cmd_t cmds_b[4];
        for (int i = 0; i < eB.cmd_count; i++)
            blt_unpack_cmd(ringB + (size_t)i * BLT_CMD_BYTES, &cmds_b[i]);
        blt_surface_heap_t heap_b = { heapB, sizeof heapB,
                                       (const uint8_t *)g_frt, (const uint8_t *)g_cft,
                                       NULL, (const uint8_t *)cells };
        memset(fb_b, 0, sizeof fb_b);
        blt_execute(fb_b, &heap_b, cmds_b, eB.cmd_count);
    }
#ifdef BLT_REF_COUNT_ISSUES
    count_b = blt_ref_issue_count - count_b_before;
#endif

    if (memcmp(fb_a, fb_b, sizeof fb_a) != 0) {
        for (int i = 0; i < BLT_FB_PIXELS; i++) {
            if (fb_a[i] != fb_b[i]) {
                printf("FAIL[%s]: first diff at px %d (%d,%d): blits=%04x grid=%04x\n",
                       name, i, i % BLT_FB_WIDTH, i / BLT_FB_WIDTH, fb_a[i], fb_b[i]);
                return 1;
            }
        }
    }

#ifdef BLT_REF_COUNT_ISSUES
    /* [Task 6] Path A (per-tile) vs Path B (grid) issued-blit counts. This is
     * the measurement that replaces the ~3x transaction estimate that
     * motivated run coalescing -- B2/B3 inherit these numbers. Sanity bound
     * only (Path B <= 4x Path A); throughput is not a gate this stage. */
    {
        double ratio = count_a ? (double)count_b / (double)count_a : 0.0;
        printf("  blits[%s]: pathA=%lu pathB=%lu ratio=%.3f\n", name, count_a, count_b, ratio);
        if (count_a > 0 && count_b > 4 * count_a) {
            printf("FAIL[%s]: grid blit count %lu exceeds 4x the per-tile count %lu (ratio %.3f)\n",
                   name, count_b, count_a, ratio);
            return 1;
        }
        /* blt_ref_tilemap_max_right_x now holds this scenario's Path B
         * high-water mark (reset just before Path B ran, above). NOT checked
         * against BLT_FB_WIDTH here in general: the coarse cell-granularity
         * clamp (cx1) is a CEIL of the pixel window to whole cells, so a
         * legitimately-clamped run can still issue a blit reaching a few
         * pixels past the framebuffer edge (scenario 8's right tile does,
         * by design -- blit_one's own fine per-pixel clip is what discards
         * those extra columns; see its comment). A blanket "never past the
         * edge" assertion would misfire on that correct, already-covered
         * case. Scenario 9 (main(), below) is deliberately built so the
         * cell boundary lands EXACTLY on the pixel edge, making the check
         * exact and safe to apply there specifically. */
    }
#endif

    printf("ok[%s]: grid == %d individual blits (grid %ux%u cells, bias %d,%d)\n",
           name, n_tiles, grid_w, grid_h, bias_x, bias_y);
    return 0;
}

int main(void)
{
    init_atlas_and_tables();
    int fails = 0;

    /* 1. 1x1 patterns only -- the simplest walk. */
    {
        static const blt_grid_tile_t T[] = {
            { PAT_A, 1, 1, 1, 1 }, { PAT_B, 3, 1, 1, 1 },
            { PAT_C, 1, 3, 1, 1 }, { PAT_A, 5, 4, 1, 1 },
        };
        fails += run_scenario("1 1x1-only", T, 4, 8, 8, 0, 0);
    }

    /* 2. Multi-cell patterns (3x2, 2x1, 1x3) -- sub-offsets + run coalescing.
     * [mutation target] dropping sub_y*8 in blt_ref_tilemap must break the
     * 3x2 (2 rows) and 1x3 (3 rows) tiles here, since row>0 would then read
     * the WRONG source row. */
    {
        static const blt_grid_tile_t T[] = {
            { PAT_MULTI_3x2, 1, 1, 3, 2 },
            { PAT_MULTI_2x1, 6, 1, 2, 1 },
            { PAT_MULTI_1x3, 1, 5, 1, 3 },
        };
        fails += run_scenario("2 multi-cell", T, 3, 12, 10, 0, 0);
    }

    /* 3. Adjacent same-pattern instances -- must NOT wrongly merge (grid_build's
     * sub_x-continuity rule is what stops this; this proves it end-to-end on
     * the framebuffer, not just on the cell array). A gap + a 4th instance
     * further out also exercises the empty-neighbour path. */
    {
        static const blt_grid_tile_t T[] = {
            { PAT_B, 0, 0, 1, 1 }, { PAT_B, 1, 0, 1, 1 },
            { PAT_B, 2, 0, 1, 1 }, { PAT_B, 4, 0, 1, 1 },
        };
        fails += run_scenario("3 adjacent-same-pattern", T, 4, 6, 2, 0, 0);
    }

    /* 4. Overlapping tiles -- a later tile PARTIALLY covering an earlier one,
     * so painter's order (later wins) is observable in the shared cell. */
    {
        static const blt_grid_tile_t T[] = {
            { PAT_OVERLAP_BASE, 1, 1, 2, 2 },  /* covers (1,1)-(2,2) */
            { PAT_OVERLAP_TOP,  2, 2, 1, 1 },  /* overwrites the bottom-right cell only */
        };
        fails += run_scenario("4 overlap", T, 2, 6, 6, 0, 0);
    }

    /* 5. Non-zero bias, both signs -- fully on-screen after bias (no clipping;
     * clipping is scenarios 6 and 8). Negative bias is the normal case
     * (-camera). */
    {
        static const blt_grid_tile_t Tn[] = {
            { PAT_A, 5, 5, 1, 1 },
            { PAT_MULTI_3x2, 10, 10, 3, 2 },
            { PAT_B, 15, 8, 1, 1 },
        };
        fails += run_scenario("5a bias-negative", Tn, 3, 20, 16, -13, -7);

        static const blt_grid_tile_t Tp[] = {
            { PAT_C, 2, 2, 1, 1 },
            { PAT_MULTI_2x1, 6, 4, 2, 1 },
            { PAT_MULTI_1x3, 10, 1, 1, 3 },
        };
        fails += run_scenario("5b bias-positive", Tp, 3, 16, 12, 11, 5);
    }

    /* 6. Window clipping on all four edges, 8-ALIGNED bias: a grid larger
     * than the framebuffer with cells off every edge. Two 5-cell runs
     * straddle the left/right visible-cell boundary (partially visible
     * multi-cell runs -- the highest-risk case), and two 1x1 tiles sit in
     * rows fully culled off the top/bottom. */
    {
        static const blt_grid_tile_t T[] = {
            { PAT_A,     20,  0, 1, 1 },   /* top row: fully culled (cy0=2)     */
            { PAT_A,     20, 33, 1, 1 },   /* bottom row: fully culled (cy1=32) */
            { PAT_CLIP5,  0, 10, 5, 1 },   /* left edge: cells 0-1 culled, 2-4 visible */
            { PAT_CLIP5, 39, 15, 5, 1 },   /* right edge: cells 39-41 visible, 42-43 culled */
            { PAT_B,     20, 20, 1, 1 },   /* fully visible control tile */
        };
        fails += run_scenario("6 window-clip-4-edges", T, 5, 44, 34, -16, -16);
    }

    /* 7. Empty cells interspersed -- gaps must be skipped, not painted. */
    {
        static const blt_grid_tile_t T[] = {
            { PAT_A, 0, 0, 1, 1 }, { PAT_B, 2, 0, 1, 1 }, { PAT_C, 4, 0, 1, 1 },
        };
        fails += run_scenario("7 empty-cells", T, 3, 6, 1, 0, 0);
    }

    /* 8. [MANDATORY -- Task 4 review] non-8-aligned bias combined with a
     * multi-cell run partially off the LEFT edge, and separately one
     * partially off the RIGHT edge. bias_x=-13, bias_y=-7 are deliberately
     * NOT multiples of 8, so the visible cell window's coarse boundary
     * (cx0/cx1) does not line up with the framebuffer edge -- exactly the
     * case an 8px-aligned bias (0, -8, -16 in Task 4's smoke test) cannot
     * reach, and where a golden-model or emitter clipping bug would hide.
     *
     *   Left tile:  PAT_CLIP5 at cell_x=1  -> dst_x = 1*8-13 = -5. The run's
     *               first cell spans screen x [-5,3): partially offscreen
     *               WITHIN a single cell, not at a cell boundary. cx0 must
     *               resolve to 1 (not 0 or 2) to include this cell at all.
     *   Right tile: PAT_CLIP5 at cell_x=38 -> dst_x = 38*8-13 = 291, run of 5
     *               cells reaches screen x=331; the framebuffer edge (320)
     *               falls mid-run (291+29=320), so the right-edge run clamp
     *               and blit_one's own per-pixel clip must BOTH land on the
     *               same visible pixels as painter's-order Path A. */
    {
        static const blt_grid_tile_t T[] = {
            { PAT_CLIP5,  1,  6, 5, 1 },   /* left edge, non-aligned partial cell   */
            { PAT_CLIP5, 38, 10, 5, 1 },   /* right edge, non-aligned partial cell  */
        };
        fails += run_scenario("8 nonaligned-bias-partial-run-clip", T, 2, 48, 20, -13, -7);
    }

    /* 9. [MANDATORY -- Task 5/6 review] the right-edge run clamp made
     * load-bearing to something other than a pixel memcmp (Task 5 proved the
     * clamp is memcmp-invisible: blit_one's own per-pixel clip already
     * discards the columns a wider blit would touch). bias_x=0 is 8-aligned
     * and the grid (44 cells = 352px) extends past the 320px framebuffer, so
     * the visible-cell boundary lands EXACTLY on the pixel edge with no ceil
     * remainder: cx1 = (320-0)/8 = 40 exactly, i.e. vis_hi_x=320 IS a cell
     * boundary (unlike scenario 8, where the ceil rounds cx1 a few pixels
     * past 320). PAT_CLIP5 (5 cells) placed at cell_x=38 straddles that
     * boundary in the MIDDLE of its run (cells 38,39 visible; 40,41,42 not):
     *   WITH the clamp:    run clamps to cx1-cx = 40-38 = 2 cells -> the
     *                       issued blit is dst_x=304, w=16, right edge = 320
     *                       (== BLT_FB_WIDTH exactly -- does not extend past
     *                       the visible window).
     *   WITHOUT the clamp: run stays 5 (grid_cell.h's self-describing
     *                       run_m1) -> dst_x=304, w=40, right edge = 344
     *                       (24px past the visible window).
     * The framebuffer memcmp cannot tell these apart (blit_one's per-pixel
     * clip erases the difference); blt_ref_tilemap_max_right_x can, and this
     * is the assertion the Task 6 mutation check (clamp temporarily removed
     * from blitter_ref.c) is verified against. */
    {
        static const blt_grid_tile_t T[] = {
            { PAT_CLIP5, 38, 1, 5, 1 },   /* run straddles the cx1=40 cell boundary */
        };
        fails += run_scenario("9 right-edge-clamp-load-bearing", T, 1, 44, 4, 0, 0);
#ifdef BLT_REF_COUNT_ISSUES
        printf("  clamp[9]: grid-issued right edge = %d (BLT_FB_WIDTH = %d)\n",
               blt_ref_tilemap_max_right_x, BLT_FB_WIDTH);
        if (blt_ref_tilemap_max_right_x > BLT_FB_WIDTH) {
            printf("FAIL[9]: right-edge run clamp did not hold -- grid-issued blit reaches "
                   "%d, past the framebuffer edge %d\n",
                   blt_ref_tilemap_max_right_x, BLT_FB_WIDTH);
            fails++;
        }
#endif
    }

    if (fails) {
        printf("FAILED: %d scenario(s) diverged\n", fails);
        return 1;
    }
    printf("ok: all tilemap scenarios byte-identical to the per-tile path\n");
    return 0;
}
