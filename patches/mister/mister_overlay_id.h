/*
 * [Stage 5 A9] Overlay content-identity unit — pure, header-only, C-compatible.
 *
 * The renderer re-converts + re-uploads the whole 320x240 root/overlay surface
 * to ARGB4444 every frame because MainLoop::draw() clears+repaints the root each
 * frame (so it is always in dirty_src). But the RESULT is usually pixel-identical
 * frame to frame (static HUD over transparent). This unit lets the renderer detect
 * that cheaply — WITHOUT hashing 153 KB of pixels — by hashing the sequence of
 * draw OPERATIONS into the root plus a per-frame source-mutation flag:
 *
 *   skippable == the same ordered draw ops, with the same params, AND no source
 *                surface was itself rewritten this frame.
 *
 * "no source rewritten this frame" is the stale-HUD guard: a HUD element whose
 * VALUE changed is re-rendered into its source surface (same op-params, new
 * pixels); the renderer flags that via src_written_this_frame so we do NOT skip.
 *
 * Cost: a handful of 64-bit folds per frame (a few HUD ops), not a pixel hash.
 */
#ifndef MISTER_OVERLAY_ID_H
#define MISTER_OVERLAY_ID_H

#include <stdint.h>

typedef struct {
  unsigned long long digest;   /* rolling hash of THIS frame's root draw ops    */
  unsigned long long prev;     /* last frame's digest                            */
  int src_mutated;             /* any root-draw src rewritten this frame -> 1    */
  int had_draw;                /* at least one root draw folded this frame -> 1  */
} overlay_id_t;

/* Fold one root-targeted draw. Geometry in pixels; rot_milli/sx_milli/sy_milli =
 * rotation(rad)*1000 and scale.x/y*1000 (ints so the hash is exact); color_rgba =
 * the packed modulation color; src_written_this_frame = 1 iff `src` was itself a
 * draw/clear/fill destination earlier THIS frame. */
static inline void overlay_id_fold(overlay_id_t* o, const void* src,
    int sx, int sy, int sw, int sh, int dx, int dy, int dw, int dh,
    int blend, int opacity, int rot_milli, int sx_milli, int sy_milli,
    unsigned color_rgba, int src_written_this_frame) {
  unsigned long long k = (unsigned long long)(uintptr_t)src * 1099511628211ull;
  k ^= ((unsigned long long)(sx & 0xffff))       | ((unsigned long long)(sy & 0xffff) << 16)
     | ((unsigned long long)(sw & 0xffff) << 32)  | ((unsigned long long)(sh & 0xffff) << 48);
  k ^= ((unsigned long long)(dx & 0xffff) * 2654435761ull)
     ^ ((unsigned long long)(dy & 0xffff) * 40503ull)
     ^ ((unsigned long long)(dw & 0xffff) * 2246822519ull)
     ^ ((unsigned long long)(dh & 0xffff) * 3266489917ull)
     ^ ((unsigned long long)(blend & 0xff) * 668265263ull)
     ^ ((unsigned long long)(opacity & 0xff) * 374761393ull)
     ^ ((unsigned long long)(rot_milli & 0xffff) * 2147483647ull)
     ^ ((unsigned long long)(sx_milli & 0xffff) * 40499ull)
     ^ ((unsigned long long)(sy_milli & 0xffff) * 65537ull)
     ^ ((unsigned long long)color_rgba * 2166136261ull);
  o->digest = o->digest * 1000003ull ^ k;   /* order-sensitive rolling hash */
  o->had_draw = 1;
  if (src_written_this_frame) o->src_mutated = 1;
}

/* Skip the reconvert+reupload iff the frame had draws, its op-digest equals last
 * frame's, and no source was rewritten this frame. Conservative: the FIRST of a
 * run of identical frames never matches (prev seeded from the prior frame), and
 * any mutation or geometry/opacity/blend/color change forces a non-skip. */
static inline int overlay_id_skippable(const overlay_id_t* o) {
  return o->had_draw && o->digest == o->prev && !o->src_mutated;
}

/* Advance to the next frame. Call ONCE per frame AFTER the skip decision. */
static inline void overlay_id_next(overlay_id_t* o) {
  o->prev = o->digest; o->digest = 0; o->src_mutated = 0; o->had_draw = 0;
}

#endif /* MISTER_OVERLAY_ID_H */
