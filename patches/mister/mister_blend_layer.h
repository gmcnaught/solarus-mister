#ifndef MISTER_BLEND_LAYER_H
#define MISTER_BLEND_LAYER_H
/* Pure logic for the blend-overlay fabric layer (dialogs + translucent in-game
 * menus). Kept header-only + dependency-free so a host test can exercise the
 * predicate and hash directly (the renderer .cpp is never compiled by the host
 * suite). Mirrors the mister_overlay_id.h convention. */
#include <stdint.h>
#include <stddef.h>

/* Max simultaneous blend-overlay layers captured per frame (dialog + a menu, say).
 * A fixed small cap keeps the renderer registry allocation-free. */
#define MISTER_BLEND_LAYER_MAX 4

/* Is this root draw a capturable full-screen blend overlay?
 *   armed       : engine-truth gate (dialog active OR game paused)
 *   dst_is_root : the draw targets the tagged root/fpga target
 *   src_w/h     : source surface dimensions
 *   fb_w/h      : framebuffer (quest) dimensions
 *   blend_mode  : BLT_BLEND_* of the draw (COPY==0, PALPHA==3)
 *   opacity     : draw global opacity 0..255
 * Gated by `armed` so the predicate is never evaluated on unrelated frames —
 * there is no first-wins lock to strand. A full-screen OPAQUE COPY is a promote
 * (handled by the menu-alias path), not a blend overlay. */
static inline int mister_blend_layer_is_capture(
    int armed, int dst_is_root,
    int src_w, int src_h, int fb_w, int fb_h,
    int blend_mode, int opacity) {
  if (!armed || !dst_is_root) return 0;
  if (src_w != fb_w || src_h != fb_h) return 0;      /* full-screen source only */
  if (opacity >= 255 && blend_mode == 0 /*COPY*/) return 0; /* opaque promote */
  return 1;
}

/* FNV-1a content hash over a pixel buffer. Cheap content-identity signal so a
 * static/fully-revealed dialog re-uploads nothing. ~150 KB/frame worst case;
 * sub-millisecond, negligible vs the ~20 ms software blend it replaces. */
static inline uint64_t mister_blend_layer_hash(const void *px, size_t nbytes) {
  const unsigned char *p = (const unsigned char *)px;
  uint64_t h = 1469598103934665603ull;      /* FNV offset basis */
  for (size_t i = 0; i < nbytes; i++) { h ^= p[i]; h *= 1099511628211ull; }
  return h;
}
#endif /* MISTER_BLEND_LAYER_H */
