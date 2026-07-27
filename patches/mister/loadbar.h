// Pure load-progress-bar geometry math (issue #72). Header-only, no SDL/Solarus
// deps so it links into both mister_blitter_renderer.cpp and the host unit test.
//
// loadbar_cells_filled: how many of `cells` discrete bar cells are lit for
// `staged`/`total` progress. Clamped to [0, cells]; guards total == 0.
#ifndef MISTER_LOADBAR_H
#define MISTER_LOADBAR_H

#include <stdint.h>

static inline int loadbar_cells_filled(int cells, uint32_t staged, uint32_t total)
{
    if (total == 0u || staged == 0u) return 0;
    if (staged >= total)             return cells;
    /* 64-bit product so cells*staged can't overflow at large asset counts. */
    return (int)(((uint64_t)(uint32_t)cells * staged) / total);
}

#endif // MISTER_LOADBAR_H
