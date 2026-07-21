#include "grid_alloc.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    blt_grid_alloc_t a;
    blt_grid_alloc_init(&a, 0x1000u, 0x100u);   /* base 0x1000, cap 256 bytes */

    /* First take returns the base, 8-byte aligned. */
    uint32_t o0 = blt_grid_alloc_take(&a, 12u);  /* 12 -> rounds used to 16 */
    assert(o0 == 0x1000u);
    assert((o0 & 7u) == 0u);

    /* Second take starts after the aligned first (16), also aligned. */
    uint32_t o1 = blt_grid_alloc_take(&a, 8u);
    assert(o1 == 0x1010u);
    assert((o1 & 7u) == 0u);

    /* used is now 24; a 240-byte take exceeds cap 256 -> FAIL, used unchanged. */
    uint32_t of = blt_grid_alloc_take(&a, 240u);
    assert(of == BLT_GRID_ALLOC_FAIL);
    uint32_t o2 = blt_grid_alloc_take(&a, 8u);   /* still room for a small one */
    assert(o2 == 0x1018u);

    /* Exact-fit take at the boundary succeeds; the next byte fails. */
    blt_grid_alloc_reset(&a);
    assert(a.used == 0u);
    uint32_t ofull = blt_grid_alloc_take(&a, 0x100u);   /* exactly cap */
    assert(ofull == 0x1000u);
    assert(blt_grid_alloc_take(&a, 1u) == BLT_GRID_ALLOC_FAIL);

    printf("grid_alloc_test OK\n");
    return 0;
}
