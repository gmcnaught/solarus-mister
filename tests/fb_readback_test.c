/* fb_readback_test — RGB565 framebuffer -> ARGB32 conversion used by the
 * previous-map capture (mister_prev_map_capture_end). The capture itself only runs
 * on hardware; this pins the one piece of pixel math on that path.
 * Build: see tests/run_tests.sh. */
#include "mister_fb_readback.h"
#include <stdio.h>
#include <string.h>

/* SDL_PIXELFORMAT_ABGR8888, which is what Video::get_pixel_format() returns
 * (Video.cpp) and therefore what previous_map_surface is. */
#define RS 0
#define GS 8
#define BS 16
#define AMASK 0xFF000000u

static int fails = 0;
static void expect(uint32_t got, uint32_t want, const char* what) {
  if (got != want) { printf("FAIL: %s: got %08x want %08x\n", what, got, want); fails++; }
}

int main(void) {
  /* Endpoints must be exact: a black frame must stay black and a white frame must
     stay white, or every captured map would be tinted. */
  expect(mister_rgb565_to_argb32(0x0000, RS, GS, BS, AMASK), 0xFF000000u, "black");
  expect(mister_rgb565_to_argb32(0xFFFF, RS, GS, BS, AMASK), 0xFFFFFFFFu, "white");

  /* Pure channels land in the right lane for ABGR8888 (R in the low byte). */
  expect(mister_rgb565_to_argb32(0xF800, RS, GS, BS, AMASK), 0xFF0000FFu, "red");
  expect(mister_rgb565_to_argb32(0x07E0, RS, GS, BS, AMASK), 0xFF00FF00u, "green");
  expect(mister_rgb565_to_argb32(0x001F, RS, GS, BS, AMASK), 0xFFFF0000u, "blue");

  /* Alpha is forced opaque: the captured composite is a finished frame and the
     scrolling blit of it must cover the root's background fill, not blend with it. */
  for (int i = 0; i < 0x10000; ++i) {
    const uint32_t p = mister_rgb565_to_argb32((uint16_t)i, RS, GS, BS, AMASK);
    if ((p & AMASK) != AMASK) { printf("FAIL: pixel %04x not opaque\n", i); fails++; break; }
  }

  /* ROUND TRIP: a colour that came from an RGB565 quantization must come back
     unchanged, so a capture -> upload -> composite cycle is stable rather than
     drifting darker each time. */
  for (int i = 0; i < 0x10000; ++i) {
    const uint32_t p  = mister_rgb565_to_argb32((uint16_t)i, RS, GS, BS, AMASK);
    const uint32_t r8 = (p >> RS) & 0xFFu, g8 = (p >> GS) & 0xFFu, b8 = (p >> BS) & 0xFFu;
    const uint16_t back = (uint16_t)(((r8 & 0xF8u) << 8) | ((g8 & 0xFCu) << 3) | (b8 >> 3));
    if (back != (uint16_t)i) {
      printf("FAIL: round trip %04x -> %08x -> %04x\n", i, p, back); fails++; break;
    }
  }

  /* Monotonic per channel: no expansion step may go backwards. */
  for (uint32_t v = 1; v < 32; ++v)
    if (mister_expand5(v) <= mister_expand5(v - 1)) {
      printf("FAIL: expand5 not monotonic at %u\n", v); fails++; break;
    }
  for (uint32_t v = 1; v < 64; ++v)
    if (mister_expand6(v) <= mister_expand6(v - 1)) {
      printf("FAIL: expand6 not monotonic at %u\n", v); fails++; break;
    }

  /* Whole-image walk honours a PADDED destination pitch (SDL surfaces are padded, so
     a width-derived stride would shear the captured map) and never writes past a row. */
  enum { W = 5, H = 3, PITCH = W * 4 + 12 };
  uint16_t src[W * H];
  for (int i = 0; i < W * H; ++i) src[i] = (uint16_t)(i * 0x0821u);
  unsigned char dst[PITCH * H];
  memset(dst, 0xCD, sizeof dst);
  mister_fb565_to_argb32(src, W, H, dst, PITCH, RS, GS, BS, AMASK);
  for (int y = 0; y < H; ++y) {
    const uint32_t* row = (const uint32_t*)(dst + (size_t)y * PITCH);
    for (int x = 0; x < W; ++x)
      expect(row[x], mister_rgb565_to_argb32(src[y * W + x], RS, GS, BS, AMASK), "image pixel");
    for (int b = W * 4; b < PITCH; ++b)
      if (dst[(size_t)y * PITCH + b] != 0xCD) {
        printf("FAIL: wrote into row %d padding at byte %d\n", y, b); fails++; break;
      }
  }

  if (fails) { printf("fb_readback_test: %d FAILURES\n", fails); return 1; }
  printf("fb_readback_test: OK\n");
  return 0;
}
