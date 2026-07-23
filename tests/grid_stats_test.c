#include "grid_stats.h"
#include "grid_cell.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

/* 5-wide grid. Row 0: [run3 pid=7][run3 pid=7][run3 pid=7][EMPTY][EMPTY]
 * i.e. a 3-cell run of pid 7 (run_m1 = 2,1,0) then two empties.
 * Row 1: all EMPTY. Window = whole 5x2. */
static blt_grid_cell_t grid_5x2[10];

static void build(void) {
    for (int i = 0; i < 10; i++) grid_5x2[i] = blt_grid_cell_pack(BLT_GRID_PID_EMPTY,0,0,0);
    grid_5x2[0] = blt_grid_cell_pack(7,0,0,2); /* run_m1=2 -> run 3 */
    grid_5x2[1] = blt_grid_cell_pack(7,1,0,1);
    grid_5x2[2] = blt_grid_cell_pack(7,2,0,0);
}

int main(void) {
    build();
    blt_grid_stats_t s;
    blt_grid_stats(grid_5x2, /*grid_w=*/5, /*cx0=*/0,/*cx1=*/5, /*cy0=*/0,/*cy1=*/2, &s);
    /* one 3-run in row0 (+2 empties), whole row1 empty (5 empties) */
    assert(s.runs == 1);
    assert(s.nonempty_cells == 3);
    assert(s.empty_cells == 7);
    assert(s.run_hist[3] == 1);
    assert(s.run_hist[1] == 0 && s.run_hist[2] == 0);

    /* Window right-edge clamp: same grid, window cx1=2 cuts the 3-run to 2. */
    blt_grid_stats_t c;
    blt_grid_stats(grid_5x2, 5, 0,2, 0,1, &c);
    assert(c.runs == 1);
    assert(c.nonempty_cells == 2);   /* run clamped 3 -> 2 */
    assert(c.run_hist[2] == 1 && c.run_hist[3] == 0);
    assert(c.empty_cells == 0);

    /* All-empty window. */
    blt_grid_stats_t e;
    blt_grid_stats(grid_5x2, 5, 0,5, 1,2, &e);
    assert(e.runs == 0 && e.nonempty_cells == 0 && e.empty_cells == 5);

    printf("grid_stats_test PASS\n");
    return 0;
}
