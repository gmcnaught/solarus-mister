#ifndef BLT_GRID_ALLOC_H
#define BLT_GRID_ALLOC_H
/* [Stage 3b Phase B3] Bump allocator over the GRID_BUF DDR region.
 *
 * Owns the two items B2 deferred to B3:
 *   - every returned offset is 8-byte (qword) aligned, so a grid's cell array
 *     never straddles a qword boundary the fabric fetch assumes aligned;
 *   - a take that would exceed `cap` returns BLT_GRID_ALLOC_FAIL instead of
 *     silently running past GRID_BUF into the FRT region above it.
 * Reset once per map rebuild; take once per static bucket that grids. */
#include <stdint.h>

#define BLT_GRID_ALLOC_FAIL 0xFFFFFFFFu

typedef struct {
    uint32_t base_off;   /* GRID_BUF region base, ddr-relative bytes */
    uint32_t cap;        /* region capacity in bytes                 */
    uint32_t used;       /* bytes handed out since the last reset    */
} blt_grid_alloc_t;

static inline void blt_grid_alloc_init(blt_grid_alloc_t *a, uint32_t base_off, uint32_t cap) {
    a->base_off = base_off; a->cap = cap; a->used = 0u;
}
static inline void blt_grid_alloc_reset(blt_grid_alloc_t *a) { a->used = 0u; }

static inline uint32_t blt_grid_alloc_take(blt_grid_alloc_t *a, uint32_t bytes) {
    /* Align the START of this allocation to 8 bytes. base_off is already
     * qword-aligned (GRID_BUF base is), so aligning `used` aligns the result. */
    uint32_t used = (a->used + 7u) & ~7u;
    if (bytes > a->cap || used > a->cap - bytes) return BLT_GRID_ALLOC_FAIL;
    a->used = used + bytes;
    return a->base_off + used;
}

#endif /* BLT_GRID_ALLOC_H */
