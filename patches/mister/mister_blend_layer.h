#ifndef MISTER_BLEND_LAYER_H
#define MISTER_BLEND_LAYER_H
/* Pure logic for the blend-overlay fabric layer (dialogs + translucent in-game
 * menus). Kept header-only + dependency-free so a host test can exercise the
 * predicate and hash directly (the renderer .cpp is never compiled by the host
 * suite). Mirrors the mister_overlay_id.h convention. */
#include <stdint.h>
#include <stddef.h>

#define MISTER_BLENDMODE_BLEND 1  /* == Solarus BlendMode::BLEND (NONE=0,BLEND=1,ADD=2,MULTIPLY=3) */

/* Max simultaneous blend-overlay layers captured per frame (dialog + a menu, say).
 * A fixed small cap keeps the renderer registry allocation-free. */
#define MISTER_BLEND_LAYER_MAX 4

/* Is this root draw a capturable full-screen blend overlay?
 *   armed        : engine-truth gate (dialog active OR game paused)
 *   dst_is_root  : the draw targets the tagged root/fpga target
 *   src_w/h      : source SURFACE dimensions
 *   reg_x/y/w/h  : the source REGION actually drawn (DrawInfos::region)
 *   dst_w/h      : destination extent (DrawInfos::dst_rectangle())
 *   fb_w/h       : framebuffer (quest) dimensions
 *   blend_mode   : the Solarus BlendMode enum value of the draw
 *                  (NONE=0, BLEND=1, ADD=2, MULTIPLY=3) — NOT BLT_BLEND_*.
 *   opacity      : draw global opacity 0..255
 *
 * Keys on the REGION, not the surface. A full-screen overlay is frequently drawn
 * out of a larger atlas: the quest's pause menu is one 320x240 region of the
 * 1280x240 four-submenu pause_submenus.png at opacity 216. Testing the surface
 * rejected it (capture=0 on HW) even though the drawn rectangle is exactly the
 * framebuffer. The dialog case is unaffected: its region IS the whole surface.
 *
 * Gated by `armed` so the predicate is never evaluated on unrelated frames — there
 * is no first-wins lock to strand. Only the source-over (alpha-blend) case is
 * captured: a full-screen OPAQUE draw (NONE) is a promote (handled by the
 * menu-alias path), and full-screen ADD/MULTIPLY must NOT be captured — they are
 * not source-over so emitting them as PALPHA would be wrong. */
static inline int mister_blend_layer_is_capture(
    int armed, int dst_is_root,
    int src_w, int src_h,
    int reg_x, int reg_y, int reg_w, int reg_h,
    int dst_w, int dst_h,
    int fb_w, int fb_h,
    int blend_mode, int opacity) {
  (void)opacity;  /* opacity is carried to the emit as the layer's PALPHA alpha, not a capture gate */
  if (!armed || !dst_is_root) return 0;
  if (blend_mode != MISTER_BLENDMODE_BLEND) return 0;   /* source-over blends only:
                                                           excludes opaque promote (NONE) and ADD/MULTIPLY */
  if (reg_w != fb_w || reg_h != fb_h) return 0;         /* the DRAWN REGION must be full-screen */
  if (dst_w != reg_w || dst_h != reg_h) return 0;       /* 1:1 only — the fabric PALPHA emit is fixed-scale */
  if (reg_x < 0 || reg_y < 0) return 0;                 /* region must lie inside the surface */
  if (reg_x + reg_w > src_w || reg_y + reg_h > src_h) return 0;
  return 1;
}

/* FNV-1a offset basis — exposed so a caller can seed a multi-chunk hash. */
#define MISTER_BLEND_LAYER_HASH_BASIS 1469598103934665603ull

/* FNV-1a continuation over one chunk. Chaining chunks yields the same digest as
 * hashing the concatenation, which is what lets a region be hashed row by row
 * without copying it out of the surface. */
static inline uint64_t mister_blend_layer_hash_accum(uint64_t h, const void *px, size_t nbytes) {
  const unsigned char *p = (const unsigned char *)px;
  for (size_t i = 0; i < nbytes; i++) { h ^= p[i]; h *= 1099511628211ull; }
  return h;
}

/* FNV-1a content hash over a pixel buffer. Cheap content-identity signal so a
 * static/fully-revealed dialog re-uploads nothing. */
static inline uint64_t mister_blend_layer_hash(const void *px, size_t nbytes) {
  return mister_blend_layer_hash_accum(MISTER_BLEND_LAYER_HASH_BASIS, px, nbytes);
}
#endif /* MISTER_BLEND_LAYER_H */
