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

}  // namespace mpix

#endif  // MISTER_PIXCONV_H
