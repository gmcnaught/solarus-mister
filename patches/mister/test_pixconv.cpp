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

// ---- un-premultiply tests (Stage 1: overlay channel, root surface is --------
// premultiplied but the fabric's BLT_BLEND_PALPHA wants straight alpha) --------

// A spread of alpha levels (never 0 or 255 here -- those are dedicated edge
// cases below) and component values, including the low-alpha corner that
// crushes to nibble 0-1 if un-premultiplied incorrectly. Alpha never goes below
// 17: at 8-bit premultiplied precision, c_pm = floor(c*a/255) truncates to 0 for
// almost every c once a is single-digit, which is an inherent property of 8-bit
// premultiplied storage (information already lost before this code ever sees
// the pixel), not something un-premultiplying can recover -- a=17 is the
// brief's own low-alpha example and round-trips within tolerance for every c.
static const Uint8 kAlphas[]     = {17, 51, 85, 128, 170, 200, 254};
static const Uint8 kComponents[] = {0, 1, 17, 64, 85, 128, 170, 200, 254, 255};

static int nibble_a(uint16_t px) { return (px >> 12) & 0xF; }
static int nibble_r(uint16_t px) { return (px >> 8)  & 0xF; }
static int nibble_g(uint16_t px) { return (px >> 4)  & 0xF; }
static int nibble_b(uint16_t px) { return px & 0xF; }

// Build a surface where pixel (x,y) is the PREMULTIPLIED encoding of straight
// (kComponents[x], kComponents[x], kComponents[x], kAlphas[y]) -- premultiplied
// per-channel as c_pm = c*a/255 (integer truncation), matching how Solarus's
// software renderer premultiplies a render target's RGB by its alpha.
static SDL_Surface* make_premul_src(Uint32 fmt) {
  const int w = (int)(sizeof(kComponents) / sizeof(kComponents[0]));
  const int h = (int)(sizeof(kAlphas) / sizeof(kAlphas[0]));
  SDL_Surface* s = SDL_CreateRGBSurfaceWithFormat(0, w, h, 32, fmt);
  if (!s) { std::fprintf(stderr, "create %s failed: %s\n",
                         SDL_GetPixelFormatName(fmt), SDL_GetError()); return nullptr; }
  SDL_SetSurfaceBlendMode(s, SDL_BLENDMODE_NONE);
  SDL_LockSurface(s);
  for (int y = 0; y < h; ++y) {
    Uint8* row = (Uint8*)s->pixels + (size_t)y * s->pitch;
    Uint8 a = kAlphas[y];
    for (int x = 0; x < w; ++x) {
      Uint8 c = kComponents[x];
      Uint8 c_pm = (Uint8)(((Uint32)c * a) / 255u);
      ((Uint32*)row)[x] = SDL_MapRGBA(s->format, c_pm, c_pm, c_pm, a);
    }
  }
  SDL_UnlockSurface(s);
  return s;
}

static void test_unpremul_roundtrip(Uint32 fmt) {
  SDL_Surface* s = make_premul_src(fmt);
  if (!s) { g_fail++; return; }
  std::vector<uint16_t> got((size_t)s->w * s->h, 0xBEEF);
  bool ok = mpix::to_argb4444_unpremultiplied(s, got.data());
  CHECK(ok, "to_argb4444_unpremultiplied returned false for %s", SDL_GetPixelFormatName(fmt));
  if (ok) {
    for (int y = 0; y < s->h; ++y) {
      Uint8 a = kAlphas[y];
      for (int x = 0; x < s->w; ++x) {
        Uint8 c = kComponents[x];
        uint16_t px = got[(size_t)y * s->w + x];
        int want_a = a >> 4, want_c = c >> 4;
        CHECK(nibble_a(px) == want_a,
              "%s roundtrip a=%d c=%d: alpha nibble got %d want %d",
              SDL_GetPixelFormatName(fmt), a, c, nibble_a(px), want_a);
        CHECK(std::abs(nibble_r(px) - want_c) <= 1,
              "%s roundtrip a=%d c=%d: r nibble got %d want ~%d",
              SDL_GetPixelFormatName(fmt), a, c, nibble_r(px), want_c);
        CHECK(std::abs(nibble_g(px) - want_c) <= 1,
              "%s roundtrip a=%d c=%d: g nibble got %d want ~%d",
              SDL_GetPixelFormatName(fmt), a, c, nibble_g(px), want_c);
        CHECK(std::abs(nibble_b(px) - want_c) <= 1,
              "%s roundtrip a=%d c=%d: b nibble got %d want ~%d",
              SDL_GetPixelFormatName(fmt), a, c, nibble_b(px), want_c);
      }
    }
  }
  SDL_FreeSurface(s);
}

// The real point: white at low alpha must NOT crush to nibble 1. Straight
// (255,255,255) at a=17 premultiplies to (17,17,17,17); un-premultiplying must
// recover RGB nibble 15, while a naive pack of the premultiplied bytes (i.e.
// plain to_argb4444, no un-premultiply) gives nibble 1 -- that contrast is the
// regression this task exists to prevent from silently returning.
static void test_unpremul_range_preservation(Uint32 fmt) {
  SDL_Surface* s = SDL_CreateRGBSurfaceWithFormat(0, 1, 1, 32, fmt);
  if (!s) { g_fail++; return; }
  SDL_SetSurfaceBlendMode(s, SDL_BLENDMODE_NONE);
  SDL_LockSurface(s);
  // Straight white at a=17, premultiplied: c_pm = 255*17/255 = 17.
  ((Uint32*)s->pixels)[0] = SDL_MapRGBA(s->format, 17, 17, 17, 17);
  SDL_UnlockSurface(s);

  uint16_t got_unpremul = 0xBEEF, got_naive = 0xBEEF;
  bool ok1 = mpix::to_argb4444_unpremultiplied(s, &got_unpremul);
  bool ok2 = mpix::to_argb4444(s, &got_naive);
  CHECK(ok1, "to_argb4444_unpremultiplied returned false for %s", SDL_GetPixelFormatName(fmt));
  CHECK(ok2, "to_argb4444 returned false for %s", SDL_GetPixelFormatName(fmt));
  if (ok1)
    CHECK(nibble_r(got_unpremul) == 15,
          "%s range preservation: un-premultiplied r nibble got %d want 15",
          SDL_GetPixelFormatName(fmt), nibble_r(got_unpremul));
  if (ok2)
    CHECK(nibble_r(got_naive) == 1,
          "%s range preservation: naive pack r nibble got %d want 1 (the regression)",
          SDL_GetPixelFormatName(fmt), nibble_r(got_naive));
  SDL_FreeSurface(s);
}

// Edges: a==0 -> 0x0000; a==255 -> byte-identical to plain to_argb4444.
static void test_unpremul_edges(Uint32 fmt) {
  // a == 0.
  {
    SDL_Surface* s = SDL_CreateRGBSurfaceWithFormat(0, 1, 1, 32, fmt);
    if (!s) { g_fail++; }
    else {
      SDL_SetSurfaceBlendMode(s, SDL_BLENDMODE_NONE);
      SDL_LockSurface(s);
      ((Uint32*)s->pixels)[0] = SDL_MapRGBA(s->format, 0, 0, 0, 0);
      SDL_UnlockSurface(s);
      uint16_t got = 0xBEEF;
      bool ok = mpix::to_argb4444_unpremultiplied(s, &got);
      CHECK(ok, "to_argb4444_unpremultiplied returned false for %s", SDL_GetPixelFormatName(fmt));
      if (ok)
        CHECK(got == 0x0000, "%s a=0 edge: got %04x want 0x0000",
              SDL_GetPixelFormatName(fmt), got);
      SDL_FreeSurface(s);
    }
  }
  // a == 255: byte-identical to plain to_argb4444.
  {
    const int w = 37, h = 19;
    SDL_Surface* s = make_src(fmt, w, h);
    if (!s) { g_fail++; return; }
    SDL_LockSurface(s);
    for (int y = 0; y < h; ++y) {
      Uint32* row = (Uint32*)((Uint8*)s->pixels + (size_t)y * s->pitch);
      for (int x = 0; x < w; ++x) {
        Uint8 r, g, b, a;
        SDL_GetRGBA(row[x], s->format, &r, &g, &b, &a);
        row[x] = SDL_MapRGBA(s->format, r, g, b, 255);
      }
    }
    SDL_UnlockSurface(s);
    std::vector<uint16_t> want((size_t)w * h, 0xDEAD), got((size_t)w * h, 0xBEEF);
    bool ok1 = mpix::to_argb4444(s, want.data());
    bool ok2 = mpix::to_argb4444_unpremultiplied(s, got.data());
    CHECK(ok1 && ok2, "%s a=255 edge: fast path unavailable", SDL_GetPixelFormatName(fmt));
    if (ok1 && ok2) {
      int mism = 0;
      for (size_t i = 0; i < want.size(); ++i)
        if (got[i] != want[i] && mism++ < 4)
          CHECK(false, "%s a=255 edge px %zu: got %04x want %04x",
                SDL_GetPixelFormatName(fmt), i, got[i], want[i]);
    }
    SDL_FreeSurface(s);
  }
}

static void test_unsupported_returns_false() {
  // 8-bit indexed has no 32-bit fast path -> must return false so caller falls back.
  SDL_Surface* s = SDL_CreateRGBSurfaceWithFormat(0, 8, 8, 8, SDL_PIXELFORMAT_INDEX8);
  CHECK(s != nullptr, "create INDEX8 failed: %s", SDL_GetError());
  if (s) {
    std::vector<uint16_t> buf(64, 0);
    CHECK(!mpix::to_rgb565(s, buf.data(), 8), "INDEX8 should not take rgb565 fast path");
    CHECK(!mpix::to_argb4444(s, buf.data()), "INDEX8 should not take argb4444 fast path");
    CHECK(!mpix::to_argb4444_unpremultiplied(s, buf.data()),
          "INDEX8 should not take argb4444_unpremultiplied fast path");
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
  const Uint32 alpha_fmts[] = {
    SDL_PIXELFORMAT_ARGB8888, SDL_PIXELFORMAT_ABGR8888,
    SDL_PIXELFORMAT_RGBA8888, SDL_PIXELFORMAT_BGRA8888,
  };
  for (Uint32 f : alpha_fmts) {
    test_unpremul_roundtrip(f);
    test_unpremul_range_preservation(f);
    test_unpremul_edges(f);
  }
  test_unsupported_returns_false();
  SDL_Quit();
  if (g_fail) { std::fprintf(stderr, "\n%d CHECK(s) FAILED\n", g_fail); return 1; }
  std::printf("ALL PASS\n");
  return 0;
}
