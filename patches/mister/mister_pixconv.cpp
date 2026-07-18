#include "mister_pixconv.h"

// Fast pixel-format converters for the MiSTer blitter source-upload path (#52).
//
// Scalar path: handles any 32-bit packed format with 8-bit components (loss==0)
// via the surface's masks/shifts -> bit-identical to SDL_GetRGBA. Always correct,
// always available; also handles the <16px row tail and unknown byte orders.
//
// NEON path (ARMv7-A Cortex-A9 on the DE10-Nano; AArch64 locally): vld4q_u8
// deinterleaves 16 pixels into per-byte-lane planes, so RGB565/ARGB4444 packing
// is a few shifts + ORs on 16 px/iteration. Selected per known byte order; falls
// back to scalar for the tail and any format not in the dispatch table. Bit-exact
// to the scalar path (test_pixconv.cpp checks both, incl. MPIX_FORCE_SCALAR).

#if defined(__ARM_NEON) && !defined(MPIX_FORCE_SCALAR)
#define MPIX_NEON 1
#include <arm_neon.h>
#else
#define MPIX_NEON 0
#endif

namespace mpix {
namespace {

struct Rgba32 {
  Uint32 rmask, gmask, bmask, amask;
  Uint8  rshift, gshift, bshift, ashift;
  bool   has_alpha;
};

// Returns false if `s` is not a supported 32-bit loss-0 source.
bool probe(SDL_Surface* s, Rgba32& f) {
  if (!s || !s->format || !s->pixels) return false;
  const SDL_PixelFormat* p = s->format;
  if (p->BytesPerPixel != 4) return false;
  if (p->Rloss != 0 || p->Gloss != 0 || p->Bloss != 0) return false;
  if (p->Amask != 0 && p->Aloss != 0) return false;
  f.rmask = p->Rmask; f.gmask = p->Gmask; f.bmask = p->Bmask; f.amask = p->Amask;
  f.rshift = p->Rshift; f.gshift = p->Gshift; f.bshift = p->Bshift; f.ashift = p->Ashift;
  f.has_alpha = (p->Amask != 0);
  return true;
}

// ---- scalar kernels (one row) ---------------------------------------------
void scalar_rgb565_row(const Uint8* row, int w, const Rgba32& f, uint16_t* out) {
  const Uint32* px = reinterpret_cast<const Uint32*>(row);
  for (int x = 0; x < w; ++x) {
    Uint32 p = px[x];
    Uint32 r = (p & f.rmask) >> f.rshift;
    Uint32 g = (p & f.gmask) >> f.gshift;
    Uint32 b = (p & f.bmask) >> f.bshift;
    out[x] = (uint16_t)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
  }
}
void scalar_argb4444_row(const Uint8* row, int w, const Rgba32& f, uint16_t* out) {
  const Uint32* px = reinterpret_cast<const Uint32*>(row);
  for (int x = 0; x < w; ++x) {
    Uint32 p = px[x];
    Uint32 r = (p & f.rmask) >> f.rshift;
    Uint32 g = (p & f.gmask) >> f.gshift;
    Uint32 b = (p & f.bmask) >> f.bshift;
    Uint32 a = f.has_alpha ? ((p & f.amask) >> f.ashift) : 255u;
    out[x] = (uint16_t)(((a >> 4) << 12) | ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4));
  }
}

// ---- un-premultiply (Stage 1: overlay channel, root surface is premultiplied)---

// Reciprocal table for un-premultiplying: recip[a] = round(255 * 65536 / a).
// Lets the hot loop do (c * recip[a] + 32768) >> 16 instead of a per-pixel divide.
const uint32_t* unpremul_recip() {
  static uint32_t t[256];
  static bool init = false;
  if (!init) {
    t[0] = 0;
    for (int a = 1; a < 256; ++a)
      t[a] = (uint32_t)((255u * 65536u + (unsigned)a / 2u) / (unsigned)a);
    init = true;
  }
  return t;
}

inline uint8_t unpremul_chan(uint8_t c, uint8_t a, const uint32_t* recip) {
  if (a == 0)   return 0;
  if (a == 255) return c;
  uint32_t v = ((uint32_t)c * recip[a] + 32768u) >> 16;
  return (uint8_t)(v > 255u ? 255u : v);
}

void scalar_argb4444_unpremul_row(const Uint8* row, int w, const Rgba32& f,
                                  uint16_t* out) {
  const uint32_t* recip = unpremul_recip();
  const Uint32* px = reinterpret_cast<const Uint32*>(row);
  for (int x = 0; x < w; ++x) {
    Uint32 p = px[x];
    Uint8 r = (Uint8)((p & f.rmask) >> f.rshift);
    Uint8 g = (Uint8)((p & f.gmask) >> f.gshift);
    Uint8 b = (Uint8)((p & f.bmask) >> f.bshift);
    Uint8 a = f.has_alpha ? (Uint8)((p & f.amask) >> f.ashift) : 255u;
    r = unpremul_chan(r, a, recip);
    g = unpremul_chan(g, a, recip);
    b = unpremul_chan(b, a, recip);
    out[x] = (uint16_t)(((a >> 4) << 12) | ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4));
  }
}

#if MPIX_NEON
// Byte-lane index of a channel within the little-endian uint32 pixel = shift/8.
// vld4q_u8 plane k == byte-lane k of every pixel, so these are the .val[] indices.
template <int RL, int GL, int BL>
void neon_rgb565_row(const Uint8* row, int w, uint16_t* out) {
  int x = 0;
  for (; x + 16 <= w; x += 16) {
    uint8x16x4_t v = vld4q_u8(row + (size_t)x * 4);
    uint8x16_t r5 = vshrq_n_u8(v.val[RL], 3);   // top 5 bits
    uint8x16_t g6 = vshrq_n_u8(v.val[GL], 2);   // top 6 bits
    uint8x16_t b5 = vshrq_n_u8(v.val[BL], 3);   // top 5 bits
    uint16x8_t lo = vorrq_u16(
        vorrq_u16(vshlq_n_u16(vmovl_u8(vget_low_u8(r5)), 11),
                  vshlq_n_u16(vmovl_u8(vget_low_u8(g6)), 5)),
        vmovl_u8(vget_low_u8(b5)));
    uint16x8_t hi = vorrq_u16(
        vorrq_u16(vshlq_n_u16(vmovl_u8(vget_high_u8(r5)), 11),
                  vshlq_n_u16(vmovl_u8(vget_high_u8(g6)), 5)),
        vmovl_u8(vget_high_u8(b5)));
    vst1q_u16(out + x, lo);
    vst1q_u16(out + x + 8, hi);
  }
  if (x < w) {
    Rgba32 f{}; f.rmask = 0xFFu << (RL * 8); f.gmask = 0xFFu << (GL * 8);
    f.bmask = 0xFFu << (BL * 8); f.rshift = RL * 8; f.gshift = GL * 8; f.bshift = BL * 8;
    scalar_rgb565_row(row + (size_t)x * 4, w - x, f, out + x);
  }
}

template <int RL, int GL, int BL, int AL, bool HASA>
void neon_argb4444_row(const Uint8* row, int w, uint16_t* out) {
  int x = 0;
  const uint8x16_t a4_const = vdupq_n_u8(15);   // opaque (255>>4) when no alpha
  for (; x + 16 <= w; x += 16) {
    uint8x16x4_t v = vld4q_u8(row + (size_t)x * 4);
    uint8x16_t r4 = vshrq_n_u8(v.val[RL], 4);
    uint8x16_t g4 = vshrq_n_u8(v.val[GL], 4);
    uint8x16_t b4 = vshrq_n_u8(v.val[BL], 4);
    uint8x16_t a4 = HASA ? vshrq_n_u8(v.val[AL], 4) : a4_const;
    uint16x8_t lo = vorrq_u16(
        vorrq_u16(vshlq_n_u16(vmovl_u8(vget_low_u8(a4)), 12),
                  vshlq_n_u16(vmovl_u8(vget_low_u8(r4)), 8)),
        vorrq_u16(vshlq_n_u16(vmovl_u8(vget_low_u8(g4)), 4),
                  vmovl_u8(vget_low_u8(b4))));
    uint16x8_t hi = vorrq_u16(
        vorrq_u16(vshlq_n_u16(vmovl_u8(vget_high_u8(a4)), 12),
                  vshlq_n_u16(vmovl_u8(vget_high_u8(r4)), 8)),
        vorrq_u16(vshlq_n_u16(vmovl_u8(vget_high_u8(g4)), 4),
                  vmovl_u8(vget_high_u8(b4))));
    vst1q_u16(out + x, lo);
    vst1q_u16(out + x + 8, hi);
  }
  if (x < w) {
    Rgba32 f{}; f.rmask = 0xFFu << (RL * 8); f.gmask = 0xFFu << (GL * 8);
    f.bmask = 0xFFu << (BL * 8); f.rshift = RL * 8; f.gshift = GL * 8; f.bshift = BL * 8;
    f.amask = HASA ? (0xFFu << (AL * 8)) : 0; f.ashift = AL * 8; f.has_alpha = HASA;
    scalar_argb4444_row(row + (size_t)x * 4, w - x, f, out + x);
  }
}

// Dispatch a known little-endian byte order to a NEON kernel. Returns false for
// formats not in the table (caller uses scalar). Lanes = shift/8 (see above).
// Plain function pointers (not a generic lambda) so this stays C++11 — the
// Solarus engine compiles its sources at -std=c++11.
typedef void (*Rgb565Kern)(const Uint8*, int, uint16_t*);
typedef void (*Argb4444Kern)(const Uint8*, int, uint16_t*);

bool neon_rgb565(SDL_Surface* s, uint16_t* dst, int stride) {
  Rgb565Kern kern = nullptr;
  switch (s->format->format) {
    case SDL_PIXELFORMAT_ARGB8888:   // mem B,G,R,A
    case SDL_PIXELFORMAT_RGB888:     // mem B,G,R,X
      kern = &neon_rgb565_row<2, 1, 0>; break;
    case SDL_PIXELFORMAT_ABGR8888:   // mem R,G,B,A
    case SDL_PIXELFORMAT_BGR888:     // mem R,G,B,X
      kern = &neon_rgb565_row<0, 1, 2>; break;
    case SDL_PIXELFORMAT_RGBA8888:   // mem A,B,G,R
      kern = &neon_rgb565_row<3, 2, 1>; break;
    case SDL_PIXELFORMAT_BGRA8888:   // mem A,R,G,B
      kern = &neon_rgb565_row<1, 2, 3>; break;
    default: return false;
  }
  const Uint8* base = static_cast<const Uint8*>(s->pixels);
  for (int y = 0; y < s->h; ++y)
    kern(base + (size_t)y * s->pitch, s->w, dst + (size_t)y * stride);
  return true;
}
bool neon_argb4444(SDL_Surface* s, uint16_t* dst) {
  Argb4444Kern kern = nullptr;
  switch (s->format->format) {
    case SDL_PIXELFORMAT_ARGB8888: kern = &neon_argb4444_row<2, 1, 0, 3, true>;  break;
    case SDL_PIXELFORMAT_RGB888:   kern = &neon_argb4444_row<2, 1, 0, 3, false>; break;
    case SDL_PIXELFORMAT_ABGR8888: kern = &neon_argb4444_row<0, 1, 2, 3, true>;  break;
    case SDL_PIXELFORMAT_BGR888:   kern = &neon_argb4444_row<0, 1, 2, 3, false>; break;
    case SDL_PIXELFORMAT_RGBA8888: kern = &neon_argb4444_row<3, 2, 1, 0, true>;  break;
    case SDL_PIXELFORMAT_BGRA8888: kern = &neon_argb4444_row<1, 2, 3, 0, true>;  break;
    default: return false;
  }
  const Uint8* base = static_cast<const Uint8*>(s->pixels);
  for (int y = 0; y < s->h; ++y)
    kern(base + (size_t)y * s->pitch, s->w, dst + (size_t)y * s->w);
  return true;
}
#endif  // MPIX_NEON

}  // namespace

bool to_rgb565(SDL_Surface* s, uint16_t* dst, int dst_stride_px) {
  Rgba32 f;
  if (!probe(s, f)) return false;
  if (SDL_LockSurface(s) != 0) return false;
#if MPIX_NEON
  if (neon_rgb565(s, dst, dst_stride_px)) { SDL_UnlockSurface(s); return true; }
#endif
  const Uint8* base = static_cast<const Uint8*>(s->pixels);
  for (int y = 0; y < s->h; ++y)
    scalar_rgb565_row(base + (size_t)y * s->pitch, s->w, f, dst + (size_t)y * dst_stride_px);
  SDL_UnlockSurface(s);
  return true;
}

bool to_argb4444(SDL_Surface* s, uint16_t* dst) {
  Rgba32 f;
  if (!probe(s, f)) return false;
  if (SDL_LockSurface(s) != 0) return false;
#if MPIX_NEON
  if (neon_argb4444(s, dst)) { SDL_UnlockSurface(s); return true; }
#endif
  const Uint8* base = static_cast<const Uint8*>(s->pixels);
  for (int y = 0; y < s->h; ++y)
    scalar_argb4444_row(base + (size_t)y * s->pitch, s->w, f, dst + (size_t)y * s->w);
  SDL_UnlockSurface(s);
  return true;
}

bool to_argb4444_unpremultiplied(SDL_Surface* s, uint16_t* dst) {
  Rgba32 f;
  if (!probe(s, f)) return false;
  if (SDL_LockSurface(s) != 0) return false;
  // No NEON variant: the per-pixel reciprocal lookup is not vectorized here. This
  // runs once per dirty overlay frame on one 320x240 surface, not per sprite.
  const Uint8* base = static_cast<const Uint8*>(s->pixels);
  for (int y = 0; y < s->h; ++y)
    scalar_argb4444_unpremul_row(base + (size_t)y * s->pitch, s->w, f,
                                 dst + (size_t)y * s->w);
  SDL_UnlockSurface(s);
  return true;
}

uint8_t unpremul_channel(uint8_t c, uint8_t a) {
  return unpremul_chan(c, a, unpremul_recip());
}

}  // namespace mpix
