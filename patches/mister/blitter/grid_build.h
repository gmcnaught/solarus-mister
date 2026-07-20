#ifndef BLT_GRID_BUILD_H
#define BLT_GRID_BUILD_H
/* [Stage 3b Phase B1] Build a cell grid from a tile list.
 *
 * Two passes, deliberately:
 *   pass 1 paints (pid, sub_x, sub_y) in painter's order, later tiles winning;
 *   pass 2 derives run_m1 by scanning each row.
 * A single fused pass is wrong -- a later tile can truncate an earlier tile's
 * run, so runs are only knowable once all painting is done. */
#include "grid_cell.h"
#include <stddef.h>

typedef struct {
    uint16_t pid;
    uint16_t cell_x, cell_y;
    uint8_t  w_cells, h_cells;
} blt_grid_tile_t;

static inline int blt_grid_build(blt_grid_cell_t *cells, uint16_t grid_w, uint16_t grid_h,
                                 const blt_grid_tile_t *tiles, size_t n_tiles) {
    const size_t n = (size_t)grid_w * (size_t)grid_h;
    for (size_t i = 0; i < n; ++i)
        cells[i] = blt_grid_cell_pack(BLT_GRID_PID_EMPTY, 0, 0, 0);

    /* Pass 1: paint identity + sub-offsets. */
    for (size_t t = 0; t < n_tiles; ++t) {
        const blt_grid_tile_t *ti = &tiles[t];
        if (ti->w_cells == 0 || ti->h_cells == 0) return -1;
        if ((size_t)ti->cell_x + ti->w_cells > grid_w) return -1;
        if ((size_t)ti->cell_y + ti->h_cells > grid_h) return -1;
        if (ti->w_cells > BLT_GRID_MAX_RUN)            return -1;
        if (ti->h_cells > BLT_GRID_MAX_RUN)            return -1;
        if (ti->pid >= BLT_GRID_PID_EMPTY)             return -1;
        for (uint8_t dy = 0; dy < ti->h_cells; ++dy)
            for (uint8_t dx = 0; dx < ti->w_cells; ++dx)
                cells[(size_t)(ti->cell_y + dy) * grid_w + (ti->cell_x + dx)] =
                    blt_grid_cell_pack(ti->pid, dx, dy, 0);
    }

    /* Pass 2: derive runs, right-to-left. A cell extends the run to its right
     * only if that neighbour is the SAME pattern instance -- same pid, same
     * sub_y, and sub_x exactly one greater. That last condition is what stops
     * two adjacent instances of the same pattern from merging. */
    for (uint16_t y = 0; y < grid_h; ++y) {
        for (uint16_t x = grid_w; x-- > 0; ) {
            blt_grid_cell_t *c = &cells[(size_t)y * grid_w + x];
            if (blt_grid_cell_is_empty(*c)) continue;
            uint8_t run = 1;
            if (x + 1 < grid_w) {
                const blt_grid_cell_t r = cells[(size_t)y * grid_w + (x + 1)];
                if (!blt_grid_cell_is_empty(r)
                    && blt_grid_cell_pid(r)   == blt_grid_cell_pid(*c)
                    && blt_grid_cell_sub_y(r) == blt_grid_cell_sub_y(*c)
                    && blt_grid_cell_sub_x(r) == (uint8_t)(blt_grid_cell_sub_x(*c) + 1)) {
                    const uint8_t rr = blt_grid_cell_run(r);
                    run = (uint8_t)(rr + 1 > BLT_GRID_MAX_RUN ? BLT_GRID_MAX_RUN : rr + 1);
                }
            }
            *c = blt_grid_cell_pack(blt_grid_cell_pid(*c), blt_grid_cell_sub_x(*c),
                                    blt_grid_cell_sub_y(*c), (uint8_t)(run - 1));
        }
    }
    return 0;
}

#endif /* BLT_GRID_BUILD_H */
