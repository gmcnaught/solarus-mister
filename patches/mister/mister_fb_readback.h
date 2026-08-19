// [scroll snapshot] RGB565 framebuffer -> 32-bit ARGB conversion.
//
// The previous-map capture (mister_prev_map_capture_end) reads the fabric's finished
// frame out of the DDR3 scanout buffer, which is RGB565, and has to land it in an
// SDL_Surface whose format is Video::get_pixel_format() (32-bit, channel positions
// given by the format's shifts). The conversion is the only new pixel math on that
// path and hardware is the only place the path itself can run, so it lives here as a
// pure function the host suite can check (tests/fb_readback_test.c) rather than inline
// in the renderer.
//
// Channel expansion is BIT REPLICATION (v << n | v >> (bits-n)), not a multiply-shift:
// it is exact at both ends of the range (0 -> 0, all-ones -> 255) and monotonic, so a
// value that survives an RGB565 round trip comes back unchanged.
#ifndef MISTER_FB_READBACK_H
#define MISTER_FB_READBACK_H

#include <stdint.h>
#include <stddef.h>

/** Expand a 5-bit channel to 8 bits. */
static inline uint32_t mister_expand5(uint32_t v) { return (v << 3) | (v >> 2); }
/** Expand a 6-bit channel to 8 bits. */
static inline uint32_t mister_expand6(uint32_t v) { return (v << 2) | (v >> 4); }

/**
 * Convert one RGB565 pixel to a 32-bit pixel in the destination format.
 *
 *   r_shift/g_shift/b_shift  the SDL_PixelFormat channel shifts of the destination
 *   a_or                     bits OR'd into every pixel — pass the format's Amask to
 *                            make the result fully opaque, which is what the captured
 *                            composite is.
 */
static inline uint32_t mister_rgb565_to_argb32(uint16_t p,
                                               int r_shift, int g_shift, int b_shift,
                                               uint32_t a_or) {
  const uint32_t r5 = ((uint32_t)p >> 11) & 0x1Fu;
  const uint32_t g6 = ((uint32_t)p >> 5)  & 0x3Fu;
  const uint32_t b5 =  (uint32_t)p        & 0x1Fu;
  return (mister_expand5(r5) << r_shift)
       | (mister_expand6(g6) << g_shift)
       | (mister_expand5(b5) << b_shift)
       | a_or;
}

/**
 * Convert a whole w*h RGB565 image (tightly packed, `w` pixels per row) into `dst`,
 * whose rows are `dst_pitch` BYTES apart — SDL surfaces are padded, so the pitch is
 * not derivable from the width.
 */
static inline void mister_fb565_to_argb32(const uint16_t* src, int w, int h,
                                          void* dst, int dst_pitch,
                                          int r_shift, int g_shift, int b_shift,
                                          uint32_t a_or) {
  unsigned char* row = (unsigned char*)dst;
  for (int y = 0; y < h; ++y, row += dst_pitch) {
    uint32_t* out = (uint32_t*)row;
    const uint16_t* in = src + (size_t)y * (size_t)w;
    for (int x = 0; x < w; ++x)
      out[x] = mister_rgb565_to_argb32(in[x], r_shift, g_shift, b_shift, a_or);
  }
}

#endif  // MISTER_FB_READBACK_H
