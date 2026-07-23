#ifndef BLT_GRID_STATS_H
#define BLT_GRID_STATS_H
#include <stdint.h>
#include <string.h>
#include "grid_cell.h"

/* Walk the cell window [cx0,cx1) x [cy0,cy1) of a grid_w-wide cell array EXACTLY as
 * blitter_top.sv's grid walker (S_GRID_DECODE / g_run clamp, blitter_top.sv:1171-1220):
 *   EMPTY  -> advance one column, count one empty fetch.
 *   run    -> run = blt_grid_cell_run(cell), clamp to window right edge, count one run
 *             + run cells, advance cx by run (intermediate cells NOT re-read).
 * So `runs` == the fabric's blit count and `empty_cells` == its empty-fetch count over
 * the visible window — the two inputs the Phase-0 cost model scales. */
typedef struct {
    uint32_t nonempty_cells;
    uint32_t empty_cells;
    uint32_t runs;
    uint32_t run_hist[17];
} blt_grid_stats_t;

static inline void blt_grid_stats(const blt_grid_cell_t* cells, uint16_t grid_w,
                                  uint16_t cx0, uint16_t cx1, uint16_t cy0, uint16_t cy1,
                                  blt_grid_stats_t* out) {
    memset(out, 0, sizeof(*out));
    for (uint16_t cy = cy0; cy < cy1; ++cy) {
        uint32_t row = (uint32_t)cy * grid_w;
        uint16_t cx = cx0;
        while (cx < cx1) {
            blt_grid_cell_t c = cells[row + cx];
            if (blt_grid_cell_is_empty(c)) {
                out->empty_cells++;
                cx++;
            } else {
                uint16_t run = blt_grid_cell_run(c);           /* 1..16 */
                if ((uint32_t)cx + run > cx1) run = cx1 - cx;  /* window clamp */
                out->runs++;
                out->nonempty_cells += run;
                if (run <= 16) out->run_hist[run]++;
                cx += run;
            }
        }
    }
}
#endif /* BLT_GRID_STATS_H */
