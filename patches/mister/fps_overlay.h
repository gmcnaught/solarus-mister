// Pure FPS-overlay math + the 7-segment digit lookup table (OSD FPS Overlay
// feature). Header-only, no SDL/Solarus deps so it links into both
// mister_blitter_renderer.cpp and the host unit test.
#ifndef MISTER_FPS_OVERLAY_H
#define MISTER_FPS_OVERLAY_H

#include <stdint.h>

// 7-segment membership per digit 0-9. bit0=a(top) bit1=b(upper-right)
// bit2=c(lower-right) bit3=d(bottom) bit4=e(lower-left) bit5=f(upper-left)
// bit6=g(middle).
static const uint8_t FPSOV_SEGMENTS[10] = {
    0x3F, /* 0: a b c d e f       */
    0x06, /* 1: b c               */
    0x5B, /* 2: a b d e g         */
    0x4F, /* 3: a b c d g         */
    0x66, /* 4: b c f g           */
    0x6D, /* 5: a c d f g         */
    0x7D, /* 6: a c d e f g       */
    0x07, /* 7: a b c             */
    0x7F, /* 8: a b c d e f g     */
    0x6F, /* 9: a b c d f g       */
};

// Clamp a rolling FPS reading to the [0,99] range the 2-digit overlay can show.
// Rounds to nearest (e.g. 59.6 -> 60); values >= 99.5 saturate at 99.
static inline int fps_overlay_clamp(double fps)
{
    int v = (int)(fps + 0.5);
    if (v < 0)  return 0;
    if (v > 99) return 99;
    return v;
}

#endif // MISTER_FPS_OVERLAY_H
