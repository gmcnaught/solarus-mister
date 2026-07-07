// Pure load-progress-bar geometry math (issue #72). Header-only, no SDL/Solarus
// deps so it links into both mister_blitter_renderer.cpp and the host unit test.
//
// loadbar_fill_w: filled width in pixels for `staged`/`total` progress across a
// `track_w`-pixel track. Clamped to [0, track_w]; guards total==0.
#ifndef MISTER_LOADBAR_H
#define MISTER_LOADBAR_H

#include <stdint.h>

static inline int loadbar_fill_w(int track_w, uint32_t staged, uint32_t total)
{
    if (total == 0u || staged == 0u) return 0;
    if (staged >= total)             return track_w;
    // 64-bit product so track_w*staged can't overflow at large asset counts.
    return (int)(((uint64_t)(uint32_t)track_w * staged) / total);
}

#endif // MISTER_LOADBAR_H
