#ifndef BLT_GRID_DECOMPOSE_H
#define BLT_GRID_DECOMPOSE_H
/* [Stage 5 lever] Stack-height paint-order decomposition of an OVERLAPPING tile
 * bucket into K non-overlapping sub-layers, each a valid single-pid grid.
 *
 * Per tile in painter's (emission) order:
 *   sublayer = max(occ[cell]) over the tile's cells;  occ[cell] = sublayer+1.
 * A later tile sharing a cell with an earlier one gets a strictly higher sublayer
 * (occ was bumped), so compositing sub-layer 0,1,...,K-1 reproduces painter's order.
 * Two tiles in the SAME sub-layer never overlap (the later would have seen a higher
 * occ), so each sub-layer builds cleanly with blt_grid_build.  NOT min-color greedy:
 * that can force a later tile below an earlier one and invert the paint order. */
#include "grid_build.h"   /* blt_grid_tile_t */
#include <stddef.h>
#include <stdint.h>

/* occ_scratch: caller-provided gw*gh bytes. sublayer_of_tile: n ints out.
 * Returns K (1..max_k), 0 if n==0, or -1 if K would exceed max_k (caller replays). */
static inline int blt_grid_decompose(const blt_grid_tile_t *tiles, size_t n,
                                     uint16_t gw, uint16_t gh, uint8_t *occ_scratch,
                                     int *sublayer_of_tile, int max_k) {
    if (n == 0) return 0;
    const size_t cells = (size_t)gw * (size_t)gh;
    for (size_t i = 0; i < cells; ++i) occ_scratch[i] = 0;
    int k_max_seen = 0;
    for (size_t t = 0; t < n; ++t) {
        const blt_grid_tile_t *ti = &tiles[t];
        int base = 0;
        for (uint8_t dy = 0; dy < ti->h_cells; ++dy)
            for (uint8_t dx = 0; dx < ti->w_cells; ++dx) {
                size_t ci = (size_t)(ti->cell_y + dy) * gw + (ti->cell_x + dx);
                if (occ_scratch[ci] > base) base = occ_scratch[ci];
            }
        if (base + 1 > max_k) return -1;          /* too deep -> caller replays */
        sublayer_of_tile[t] = base;
        if (base > k_max_seen) k_max_seen = base;
        uint8_t nh = (uint8_t)(base + 1);
        for (uint8_t dy = 0; dy < ti->h_cells; ++dy)
            for (uint8_t dx = 0; dx < ti->w_cells; ++dx) {
                size_t ci = (size_t)(ti->cell_y + dy) * gw + (ti->cell_x + dx);
                occ_scratch[ci] = nh;
            }
    }
    return k_max_seen + 1;
}
#endif /* BLT_GRID_DECOMPOSE_H */
