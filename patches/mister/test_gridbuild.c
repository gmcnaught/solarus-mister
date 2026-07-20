/* [Stage 3b Phase B1] Grid builder: tile list -> cell grid with horizontal runs. */
#include "blitter/grid_build.h"
#include <stdio.h>
#include <string.h>

static int fails = 0;
#define CHECK(cond, ...) do { if (!(cond)) { \
    printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); fails++; } } while (0)

#define GW 8
#define GH 4
static blt_grid_cell_t g[GW * GH];
#define AT(x, y) g[(size_t)(y) * GW + (x)]

int main(void) {
    /* 1. Empty grid: every cell EMPTY. */
    CHECK(blt_grid_build(g, GW, GH, NULL, 0) == 0, "empty build failed");
    for (int i = 0; i < GW * GH; ++i)
        CHECK(blt_grid_cell_is_empty(g[i]), "cell %d not empty", i);

    /* 2. A single 1x1 pattern: run must be 1, sub 0,0. */
    {
        blt_grid_tile_t t = { .pid = 5, .cell_x = 2, .cell_y = 1, .w_cells = 1, .h_cells = 1 };
        CHECK(blt_grid_build(g, GW, GH, &t, 1) == 0, "1x1 build failed");
        CHECK(blt_grid_cell_pid(AT(2,1)) == 5, "pid wrong");
        CHECK(blt_grid_cell_run(AT(2,1)) == 1, "1x1 run must be 1, got %u", blt_grid_cell_run(AT(2,1)));
        CHECK(blt_grid_cell_is_empty(AT(3,1)), "neighbour must stay empty");
    }

    /* 3. A 3x2 pattern: each ROW is one run of 3, remaining-from-here counts down. */
    {
        blt_grid_tile_t t = { .pid = 9, .cell_x = 1, .cell_y = 0, .w_cells = 3, .h_cells = 2 };
        CHECK(blt_grid_build(g, GW, GH, &t, 1) == 0, "3x2 build failed");
        for (int row = 0; row < 2; ++row) {
            CHECK(blt_grid_cell_run(AT(1, row)) == 3, "row %d start run must be 3", row);
            CHECK(blt_grid_cell_run(AT(2, row)) == 2, "row %d mid run must be 2", row);
            CHECK(blt_grid_cell_run(AT(3, row)) == 1, "row %d end run must be 1", row);
            for (int c = 0; c < 3; ++c) {
                CHECK(blt_grid_cell_sub_x(AT(1 + c, row)) == (uint8_t)c, "sub_x wrong");
                CHECK(blt_grid_cell_sub_y(AT(1 + c, row)) == (uint8_t)row, "sub_y wrong");
                CHECK(blt_grid_cell_pid(AT(1 + c, row)) == 9, "pid wrong");
            }
        }
    }

    /* 4. THE CORRECTNESS RULE: two adjacent instances of the SAME 1-cell pattern
     *    must NOT coalesce. Each keeps run==1; merging them would make the fabric
     *    read past the pattern in the atlas. */
    {
        blt_grid_tile_t t[2] = {
            { .pid = 7, .cell_x = 0, .cell_y = 3, .w_cells = 1, .h_cells = 1 },
            { .pid = 7, .cell_x = 1, .cell_y = 3, .w_cells = 1, .h_cells = 1 },
        };
        CHECK(blt_grid_build(g, GW, GH, t, 2) == 0, "adjacent build failed");
        CHECK(blt_grid_cell_run(AT(0,3)) == 1, "adjacent same-pid tiles MUST NOT merge (got run %u)",
              blt_grid_cell_run(AT(0,3)));
        CHECK(blt_grid_cell_run(AT(1,3)) == 1, "second instance run must be 1");
        CHECK(blt_grid_cell_sub_x(AT(1,3)) == 0, "second instance sub_x must restart at 0");
    }

    /* 5. Overwrite: a later tile wins (painter's order within a layer). */
    {
        blt_grid_tile_t t[2] = {
            { .pid = 1, .cell_x = 0, .cell_y = 0, .w_cells = 2, .h_cells = 1 },
            { .pid = 2, .cell_x = 1, .cell_y = 0, .w_cells = 1, .h_cells = 1 },
        };
        CHECK(blt_grid_build(g, GW, GH, t, 2) == 0, "overwrite build failed");
        CHECK(blt_grid_cell_pid(AT(1,0)) == 2, "later tile must win");
        /* The truncated first tile must not claim a run that runs into the overwrite. */
        CHECK(blt_grid_cell_run(AT(0,0)) == 1,
              "run must be re-derived after overwrite, got %u", blt_grid_cell_run(AT(0,0)));
    }

    /* 6. Out-of-bounds tile is rejected, not silently clipped. */
    {
        blt_grid_tile_t t = { .pid = 3, .cell_x = GW - 1, .cell_y = 0, .w_cells = 4, .h_cells = 1 };
        CHECK(blt_grid_build(g, GW, GH, &t, 1) == -1, "OOB tile must be rejected");
    }

    /* 7. Run never exceeds BLT_GRID_MAX_RUN even for a maximal pattern. */
    {
        blt_grid_cell_t big[32 * 1];
        blt_grid_tile_t t = { .pid = 4, .cell_x = 0, .cell_y = 0, .w_cells = 16, .h_cells = 1 };
        CHECK(blt_grid_build(big, 32, 1, &t, 1) == 0, "16-wide build failed");
        CHECK(blt_grid_cell_run(big[0]) == 16, "max run must be 16, got %u", blt_grid_cell_run(big[0]));
    }

    /* 8. Merge guard: pid must match even when dx-continuity and sub_y both
     *    hold. Paint a 2x1 pid=2 pattern (sub_x 0,1), then overwrite just its
     *    first cell with an unrelated 1x1 pid=1 tile. The surviving fragment
     *    at (1,2) still has pid=2, sub_x=1, sub_y=0; its left neighbour (0,2)
     *    now has pid=1, sub_x=0, sub_y=0 -- sub_x and sub_y both line up for
     *    a merge, so only the pid check can stop it. */
    {
        blt_grid_tile_t t[2] = {
            { .pid = 2, .cell_x = 0, .cell_y = 2, .w_cells = 2, .h_cells = 1 },
            { .pid = 1, .cell_x = 0, .cell_y = 2, .w_cells = 1, .h_cells = 1 },
        };
        CHECK(blt_grid_build(g, GW, GH, t, 2) == 0, "pid-guard build failed");
        CHECK(blt_grid_cell_pid(AT(0,2)) == 1, "overwritten cell pid wrong");
        CHECK(blt_grid_cell_sub_x(AT(0,2)) == 0, "overwritten cell sub_x wrong");
        CHECK(blt_grid_cell_pid(AT(1,2)) == 2, "fragment cell pid wrong");
        CHECK(blt_grid_cell_sub_x(AT(1,2)) == 1, "fragment cell sub_x wrong");
        CHECK(blt_grid_cell_run(AT(0,2)) == 1,
              "dx-continuous different-pid neighbour MUST NOT merge (got run %u)",
              blt_grid_cell_run(AT(0,2)));
    }

    /* 9. Merge guard: sub_y must match even when pid and dx-continuity both
     *    hold. Paint a 2x2 pid=3 pattern, then overwrite the bottom-left cell
     *    with a fresh 1x1 pid=3 tile (its own instance, so sub_x=sub_y=0).
     *    Its right neighbour (5,1) is untouched: still pid=3, sub_x=1,
     *    sub_y=1 from the original paint. pid matches and sub_x is
     *    dx-continuous (0+1==1), so only the sub_y check can stop the merge. */
    {
        blt_grid_tile_t t[2] = {
            { .pid = 3, .cell_x = 4, .cell_y = 0, .w_cells = 2, .h_cells = 2 },
            { .pid = 3, .cell_x = 4, .cell_y = 1, .w_cells = 1, .h_cells = 1 },
        };
        CHECK(blt_grid_build(g, GW, GH, t, 2) == 0, "sub_y-guard build failed");
        CHECK(blt_grid_cell_pid(AT(4,1)) == 3, "overwritten cell pid wrong");
        CHECK(blt_grid_cell_sub_x(AT(4,1)) == 0, "overwritten cell sub_x wrong");
        CHECK(blt_grid_cell_sub_y(AT(4,1)) == 0, "overwritten cell sub_y wrong");
        CHECK(blt_grid_cell_pid(AT(5,1)) == 3, "untouched neighbour pid wrong");
        CHECK(blt_grid_cell_sub_x(AT(5,1)) == 1, "untouched neighbour sub_x wrong");
        CHECK(blt_grid_cell_sub_y(AT(5,1)) == 1, "untouched neighbour sub_y wrong");
        CHECK(blt_grid_cell_run(AT(4,1)) == 1,
              "same-pid dx-continuous but sub_y-mismatched neighbour MUST NOT merge (got run %u)",
              blt_grid_cell_run(AT(4,1)));
    }

    /* 10. w_cells / h_cells bound: a >BLT_GRID_MAX_RUN dimension must be
     *     rejected by the dedicated bound check, not merely happen to be
     *     caught by the grid-bounds OOB check -- use a grid wide/tall enough
     *     that a 17-cell tile placed at the origin is NOT out of bounds. */
    {
        blt_grid_cell_t big2[20 * 20];
        blt_grid_tile_t tw = { .pid = 1, .cell_x = 0, .cell_y = 0, .w_cells = 17, .h_cells = 1 };
        CHECK(blt_grid_build(big2, 20, 20, &tw, 1) == -1, "w_cells=17 must be rejected");
        blt_grid_tile_t th = { .pid = 1, .cell_x = 0, .cell_y = 0, .w_cells = 1, .h_cells = 17 };
        CHECK(blt_grid_build(big2, 20, 20, &th, 1) == -1, "h_cells=17 must be rejected");
    }

    if (fails) { printf("test_gridbuild: %d FAILURES\n", fails); return 1; }
    printf("test_gridbuild: all checks passed\n");
    return 0;
}
