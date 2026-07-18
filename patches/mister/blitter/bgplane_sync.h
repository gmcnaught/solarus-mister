/* bgplane_sync.h — batch-cut boundary math for the synchronous load-time
 * bgplane bake (bake_all_planes_sync in mister_blitter_renderer.cpp). Shared
 * VERBATIM by that renderer and by tests/bgplane_sync_*_test.c. GPL-3.0. */
#ifndef BGPLANE_SYNC_H
#define BGPLANE_SYNC_H

#include <stddef.h>

/* Commands reserved as headroom for a single cell's worst-case emission:
 * clear-WORK FILL + BLT_F_BGCOV coverage FILL + one BLT_OP_TILELIST per static
 * bucket on the layer + one OP_BGPLANE_WRITE. Real cells emit a handful; 1024 is
 * a generous, safe reservation well under the ~16384-command 512 KB ring. */
#define BGPLANE_SYNC_CELL_MARGIN ((size_t)1024)

/* Return non-zero when the current bake batch must be submitted BEFORE emitting
 * the next cell, so that cell's commands can never overflow the ring. */
static inline int bgplane_sync_cut_before_cell(size_t cmd_count,
                                               size_t ring_cmd_cap) {
    return (cmd_count + BGPLANE_SYNC_CELL_MARGIN) > ring_cmd_cap;
}

#endif /* BGPLANE_SYNC_H */
