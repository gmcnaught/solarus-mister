// Bit-exactness tests for mpix::to_rgb565 / to_argb4444 (issue #52 fast convert).
// Oracle for RGB565   = SDL_ConvertSurfaceFormat(src, SDL_PIXELFORMAT_RGB565).
// Oracle for ARGB4444 = legacy hand-pack via SDL_ConvertSurfaceFormat(ARGB8888)
//                       then high-nibble {A4,R4,G4,B4} (copied from the renderer).
//
// Build/run:  see patches/mister/build_test_pixconv.sh
#include "mister_pixconv.h"
#include <SDL.h>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>

static int g_fail = 0;
#define CHECK(cond, ...) do { if (!(cond)) { \
  std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
  std::fprintf(stderr, __VA_ARGS__); std::fprintf(stderr, "\n"); g_fail++; } } while (0)

// Deterministic, full-range pixel pattern (hits 0 and 255 at corners).
static SDL_Surface* make_src(Uint32 fmt, int w, int h) {
  SDL_Surface* s = SDL_CreateRGBSurfaceWithFormat(0, w, h, 32, fmt);
  if (!s) { std::fprintf(stderr, "create %s failed: %s\n",
                         SDL_GetPixelFormatName(fmt), SDL_GetError()); return nullptr; }
  SDL_SetSurfaceBlendMode(s, SDL_BLENDMODE_NONE);  // straight copy (opaque upload reality)
  SDL_LockSurface(s);
  for (int y = 0; y < h; ++y) {
    Uint8* row = (Uint8*)s->pixels + (size_t)y * s->pitch;
    for (int x = 0; x < w; ++x) {
      Uint8 r = (Uint8)((x * 7) & 0xFF);
      Uint8 g = (Uint8)((y * 13) & 0xFF);
      Uint8 b = (Uint8)(((x + y) * 5) & 0xFF);
      Uint8 a = (Uint8)((x * y * 3) & 0xFF);
      if (x == 0 && y == 0) { r = g = b = a = 0; }
      if (x == w - 1 && y == h - 1) { r = g = b = a = 255; }
      ((Uint32*)row)[x] = SDL_MapRGBA(s->format, r, g, b, a);
    }
  }
  SDL_UnlockSurface(s);
  return s;
}

static void test_rgb565(Uint32 fmt) {
  const int w = 37, h = 19, stride = w + 5;   // oversized dst stride
  SDL_Surface* s = make_src(fmt, w, h);
  if (!s) { g_fail++; return; }

  // Oracle.
  SDL_Surface* c = SDL_ConvertSurfaceFormat(s, SDL_PIXELFORMAT_RGB565, 0);
  CHECK(c != nullptr, "oracle convert failed for %s", SDL_GetPixelFormatName(fmt));
  std::vector<uint16_t> want((size_t)h * stride, 0xDEAD), got((size_t)h * stride, 0xBEEF);
  if (c) {
    SDL_LockSurface(c);
    for (int y = 0; y < h; ++y) {
      const uint16_t* src = (const uint16_t*)((Uint8*)c->pixels + (size_t)y * c->pitch);
      for (int x = 0; x < w; ++x) want[(size_t)y * stride + x] = src[x];
    }
    SDL_UnlockSurface(c);
    SDL_FreeSurface(c);
  }

  // Fast path.
  bool ok = mpix::to_rgb565(s, got.data(), stride);
  CHECK(ok, "to_rgb565 returned false (no fast path) for %s", SDL_GetPixelFormatName(fmt));
  if (ok) {
    int mism = 0;
    for (int y = 0; y < h; ++y)
      for (int x = 0; x < w; ++x) {
        size_t i = (size_t)y * stride + x;
        if (got[i] != want[i] && mism++ < 4)
          CHECK(false, "%s rgb565 (%d,%d): got %04x want %04x",
                SDL_GetPixelFormatName(fmt), x, y, got[i], want[i]);
      }
    // Padding past w must be untouched (stride respected).
    for (int y = 0; y < h; ++y)
      CHECK(got[(size_t)y * stride + w] == 0xBEEF,
            "%s wrote past width at row %d", SDL_GetPixelFormatName(fmt), y);
  }
  SDL_FreeSurface(s);
}

// Legacy ARGB4444 oracle (verbatim from mister_blitter_renderer.cpp to_argb4444).
static bool oracle_argb4444(SDL_Surface* s, std::vector<uint16_t>& out) {
  SDL_Surface* c = SDL_ConvertSurfaceFormat(s, SDL_PIXELFORMAT_ARGB8888, 0);
  if (!c) return false;
  out.resize((size_t)c->w * c->h);
  SDL_LockSurface(c);
  const uint8_t* base = (const uint8_t*)c->pixels;
  for (int y = 0; y < c->h; ++y) {
    const uint32_t* row = (const uint32_t*)(base + (size_t)y * c->pitch);
    for (int x = 0; x < c->w; ++x) {
      uint32_t px = row[x];
      uint8_t r, g, b, a;
      SDL_GetRGBA(px, c->format, &r, &g, &b, &a);
      out[(size_t)y * c->w + x] =
          (uint16_t)(((a >> 4) << 12) | ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4));
    }
  }
  SDL_UnlockSurface(c);
  SDL_FreeSurface(c);
  return true;
}

static void test_argb4444(Uint32 fmt) {
  const int w = 37, h = 19;
  SDL_Surface* s = make_src(fmt, w, h);
  if (!s) { g_fail++; return; }

  std::vector<uint16_t> want;
  CHECK(oracle_argb4444(s, want), "oracle argb4444 failed for %s", SDL_GetPixelFormatName(fmt));
  std::vector<uint16_t> got((size_t)w * h, 0xBEEF);
  bool ok = mpix::to_argb4444(s, got.data());
  CHECK(ok, "to_argb4444 returned false for %s", SDL_GetPixelFormatName(fmt));
  if (ok && want.size() == got.size()) {
    int mism = 0;
    for (size_t i = 0; i < want.size(); ++i)
      if (got[i] != want[i] && mism++ < 4)
        CHECK(false, "%s argb4444 px %zu: got %04x want %04x",
              SDL_GetPixelFormatName(fmt), i, got[i], want[i]);
  }
  SDL_FreeSurface(s);
}

static void test_unsupported_returns_false() {
  // 8-bit indexed has no 32-bit fast path -> must return false so caller falls back.
  SDL_Surface* s = SDL_CreateRGBSurfaceWithFormat(0, 8, 8, 8, SDL_PIXELFORMAT_INDEX8);
  CHECK(s != nullptr, "create INDEX8 failed: %s", SDL_GetError());
  if (s) {
    std::vector<uint16_t> buf(64, 0);
    CHECK(!mpix::to_rgb565(s, buf.data(), 8), "INDEX8 should not take rgb565 fast path");
    CHECK(!mpix::to_argb4444(s, buf.data()), "INDEX8 should not take argb4444 fast path");
    SDL_FreeSurface(s);
  }
}

int main() {
  if (SDL_Init(0) != 0) { std::fprintf(stderr, "SDL_Init: %s\n", SDL_GetError()); return 2; }
  const Uint32 fmts[] = {
    SDL_PIXELFORMAT_ARGB8888, SDL_PIXELFORMAT_ABGR8888,
    SDL_PIXELFORMAT_RGBA8888, SDL_PIXELFORMAT_BGRA8888,
    SDL_PIXELFORMAT_RGB888,   // XRGB, no alpha bits -> alpha reads 255
  };
  for (Uint32 f : fmts) { test_rgb565(f); test_argb4444(f); }
  test_unsupported_returns_false();
  SDL_Quit();
  if (g_fail) { std::fprintf(stderr, "\n%d CHECK(s) FAILED\n", g_fail); return 1; }
  std::printf("ALL PASS\n");
  return 0;
}
