// Fast, dependency-light pixel-format converters for the MiSTer blitter source
// upload path (issue #52). They replace SDL_ConvertSurfaceFormat (which falls
// back to the per-pixel SDL_Blit_Slow general blitter and dominates the A9 in
// heavy areas) with specialized loops for the common 32-bit RGBA source formats.
//
// Bit-exactness contract (verified by test_pixconv.cpp):
//   - to_rgb565   == SDL_ConvertSurfaceFormat(src, SDL_PIXELFORMAT_RGB565)
//                    for a straight (blendmode-NONE) opaque copy.
//   - to_argb4444 == the legacy hand-pack: per pixel {A4,R4,G4,B4} = high nibbles
//                    of the surface's RGBA8888 components.
//
// Both return false when the source format is not a supported fast path; the
// caller must then fall back to the SDL conversion (correctness preserved).
#ifndef MISTER_PIXCONV_H
#define MISTER_PIXCONV_H

#include <SDL.h>
#include <cstdint>

namespace mpix {

// Convert `src` -> RGB565 into `dst`, `dst_stride_px` uint16 elements per row.
// `dst` must hold at least src->h rows of src->w pixels. Returns true if a fast
// path handled it; false => unsupported source format (use SDL fallback).
// (non-const: may SDL_LockSurface the source for the read).
bool to_rgb565(SDL_Surface* src, uint16_t* dst, int dst_stride_px);

// Convert `src` -> packed ARGB4444 {A4,R4,G4,B4} into `dst` (tightly packed,
// src->w * src->h uint16). Returns true on the fast path; false => fall back.
bool to_argb4444(SDL_Surface* src, uint16_t* dst);

// Convert `src` -> packed ARGB4444 {A4,R4,G4,B4} into `dst`, treating the source
// as PREMULTIPLIED alpha: each RGB channel is divided back out by alpha (in 8-bit
// space, before the 8->4 bit truncation) so the result is STRAIGHT alpha, which is
// what the fabric's BLT_BLEND_PALPHA expects. Un-premultiplying before truncation
// preserves the full 16-level RGB range at every alpha; doing it after (or not at
// all) crushes low-alpha pixels toward zero. a==0 pixels emit 0 (fully transparent,
// the fabric skip-writes them); a==255 is passed through unchanged.
// Returns true on the fast path; false => unsupported source format (use fallback).
bool to_argb4444_unpremultiplied(SDL_Surface* src, uint16_t* dst);

// Un-premultiply a single 8-bit channel value `c` by alpha `a` (round-to-nearest,
// clamped to 255). a==0 -> 0; a==255 -> c unchanged. Exposed so callers with their
// own per-pixel loop (e.g. the SDL_GetRGBA fallback in mister_blitter_renderer.cpp)
// can stay bit-exact with the fast path above without duplicating the reciprocal
// table's formula.
uint8_t unpremul_channel(uint8_t c, uint8_t a);

}  // namespace mpix

#endif  // MISTER_PIXCONV_H
