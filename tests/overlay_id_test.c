/* Host unit test for the overlay content-identity unit. cc-compatible. */
#include <stdio.h>
#include <assert.h>
#include "../patches/mister/mister_overlay_id.h"

/* Fold one "typical HUD draw": src ptr S, src 0,0,16,16 -> dst 8,8,16,16,
 * blend 1, opacity 255, no rot/scale, white, not-mutated-this-frame. */
static void hud(overlay_id_t* o, const void* s, int dx, int opacity,
                unsigned color, int mutated) {
  overlay_id_fold(o, s, 0,0,16,16, dx,8,16,16, 1, opacity, 0,1000,1000, color, mutated);
}

int main(void) {
  int S1, S2;   /* two distinct surface addresses */
  const void *A = &S1, *B = &S2;
  unsigned WHITE = 0xffffffffu;

  /* 1. Two identical frames -> the SECOND is skippable, the first is not. */
  overlay_id_t o = {0,0,0,0};
  hud(&o, A, 8, 255, WHITE, 0);
  assert(!overlay_id_skippable(&o));          /* frame 1: prev=0, no match */
  overlay_id_next(&o);
  hud(&o, A, 8, 255, WHITE, 0);
  assert(overlay_id_skippable(&o));           /* frame 2: identical -> skip */

  /* 2. Mutation guard: identical op-params but the source was written this
   *    frame (HUD value re-rendered) -> NOT skippable (stale-HUD guard). */
  overlay_id_next(&o);
  hud(&o, A, 8, 255, WHITE, 1);               /* mutated=1 */
  assert(!overlay_id_skippable(&o));

  /* 3. Moved dst -> not skippable. */
  overlay_id_t o3 = {0,0,0,0};
  hud(&o3, A, 8, 255, WHITE, 0); overlay_id_next(&o3);
  hud(&o3, A, 9, 255, WHITE, 0);              /* dst x 8 -> 9 */
  assert(!overlay_id_skippable(&o3));

  /* 4. Changed opacity -> not skippable (fade). */
  overlay_id_t o4 = {0,0,0,0};
  hud(&o4, A, 8, 255, WHITE, 0); overlay_id_next(&o4);
  hud(&o4, A, 8, 200, WHITE, 0);
  assert(!overlay_id_skippable(&o4));

  /* 5. Changed source pointer -> not skippable. */
  overlay_id_t o5 = {0,0,0,0};
  hud(&o5, A, 8, 255, WHITE, 0); overlay_id_next(&o5);
  hud(&o5, B, 8, 255, WHITE, 0);
  assert(!overlay_id_skippable(&o5));

  /* 6. Changed color modulation -> not skippable. */
  overlay_id_t o6 = {0,0,0,0};
  hud(&o6, A, 8, 255, WHITE, 0); overlay_id_next(&o6);
  hud(&o6, A, 8, 255, 0xff0000ffu, 0);
  assert(!overlay_id_skippable(&o6));

  /* 7. Empty frame (no draws) -> not skippable (had_draw=0), even vs empty. */
  overlay_id_t o7 = {0,0,0,0};
  assert(!overlay_id_skippable(&o7));
  overlay_id_next(&o7);
  assert(!overlay_id_skippable(&o7));

  /* 8. Multi-draw order sensitivity: same set, different order -> different
   *    digest -> not skippable (a reordered z-stack is a real change). */
  overlay_id_t o8 = {0,0,0,0};
  hud(&o8, A, 8, 255, WHITE, 0); hud(&o8, B, 20, 255, WHITE, 0); overlay_id_next(&o8);
  hud(&o8, B, 20, 255, WHITE, 0); hud(&o8, A, 8, 255, WHITE, 0);
  assert(!overlay_id_skippable(&o8));

  printf("overlay_id_test: all 8 passed\n");
  return 0;
}
