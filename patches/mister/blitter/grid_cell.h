#ifndef BLT_GRID_CELL_H
#define BLT_GRID_CELL_H
/* [Stage 3b Phase B1] 32-bit tilemap grid cell.
 *
 *   bits [11:0]  pattern index  (BLT_GRID_PID_EMPTY = empty, walker skips)
 *   bits [15:12] sub_x          x offset inside the pattern, in 8px cells
 *   bits [19:16] sub_y          y offset inside the pattern, in 8px cells
 *   bits [23:20] run_m1         (cells remaining horizontally FROM THIS CELL) - 1
 *   bits [31:24] spare          written 0, ignored on read
 *
 * run_m1 is REMAINING-FROM-HERE, not length-from-run-start, so a cell is
 * self-describing and a visible window opening mid-pattern still emits a
 * correct partial run.
 *
 * CORRECTNESS RULE: a run may only span cells whose source pixels are
 * horizontally contiguous -- cells within ONE pattern instance, sub_x
 * incrementing, sub_y constant. Merging two adjacent instances of the same
 * pattern would make the fabric read past that pattern in the atlas.
 *
 * These bit positions are decoded by the fabric. Changing them requires a
 * matching RTL change and a test_wire_constants.py update. */
#include <stdint.h>

typedef uint32_t blt_grid_cell_t;

#define BLT_GRID_PID_EMPTY 0xFFFu
#define BLT_GRID_MAX_RUN   16       /* widest pattern in the quest: 128px = 16 cells */

static inline blt_grid_cell_t blt_grid_cell_pack(uint16_t pid, uint8_t sub_x,
                                                 uint8_t sub_y, uint8_t run_m1) {
    return ((blt_grid_cell_t)(pid    & 0x0FFFu))
         | ((blt_grid_cell_t)(sub_x  & 0x0Fu) << 12)
         | ((blt_grid_cell_t)(sub_y  & 0x0Fu) << 16)
         | ((blt_grid_cell_t)(run_m1 & 0x0Fu) << 20);
}

static inline uint16_t blt_grid_cell_pid(blt_grid_cell_t c)   { return (uint16_t)( c        & 0x0FFFu); }
static inline uint8_t  blt_grid_cell_sub_x(blt_grid_cell_t c) { return (uint8_t) ((c >> 12) & 0x0Fu); }
static inline uint8_t  blt_grid_cell_sub_y(blt_grid_cell_t c) { return (uint8_t) ((c >> 16) & 0x0Fu); }
static inline uint8_t  blt_grid_cell_run(blt_grid_cell_t c)   { return (uint8_t)(((c >> 20) & 0x0Fu) + 1u); }
static inline int      blt_grid_cell_is_empty(blt_grid_cell_t c) {
    return blt_grid_cell_pid(c) == BLT_GRID_PID_EMPTY;
}

#endif /* BLT_GRID_CELL_H */
