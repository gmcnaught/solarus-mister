/* Unit test for bgplane_sync_cut_before_cell (batch-cut boundary math).
 * A batch must be cut BEFORE a cell whenever fewer than BGPLANE_SYNC_CELL_MARGIN
 * command slots remain, so a cell's emission can never overflow the ring. */
#include "bgplane_sync.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    const size_t cap = 16384;   /* 512 KB ring / 32 B per command */

    /* Fresh ring: never cut. */
    assert(bgplane_sync_cut_before_cell(0, cap) == 0);

    /* Comfortable headroom: never cut. */
    assert(bgplane_sync_cut_before_cell(cap / 2, cap) == 0);

    /* Exactly one margin of headroom left: still fits, do not cut. */
    assert(bgplane_sync_cut_before_cell(cap - BGPLANE_SYNC_CELL_MARGIN, cap) == 0);

    /* One past the margin: must cut. */
    assert(bgplane_sync_cut_before_cell(cap - BGPLANE_SYNC_CELL_MARGIN + 1, cap) != 0);

    /* Ring already full: must cut. */
    assert(bgplane_sync_cut_before_cell(cap, cap) != 0);

    printf("bgplane_sync_batch: RESULT: PASS\n");
    return 0;
}
