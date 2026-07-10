/* Host unit test for compute_bgplane_bounds (bug #1 fix: bgplane restricted
 * to the map's base layer). Pure C++, runs natively (no device). Build+run:
 * c++ -std=c++17 -Wall -Wextra -O2 -I patches/mister/blitter \
 *     tests/bgplane_bounds_test.cpp -o /tmp/bgplane_bounds_test && /tmp/bgplane_bounds_test
 */
#include "bgplane_bounds.h"
#include <cassert>
#include <cstdio>

int main() {
  // Two layers of static content: layer 0 (the base layer) spans a small
  // area; layer 1 (e.g. tree canopy) spans a different, larger area. Only
  // layer 0's extents should contribute to the bounds. All layer-0
  // coordinates here are non-negative, so the origin-clamp rule ("origin is
  // never pulled positive, only shifted to cover negatives") clamps min_x/
  // min_y to 0 independently -- mw/mh are therefore the raw max ex/ey, NOT
  // reduced by the (would-be-positive) min values.
  {
    bgplane_tile_extent_t extents[] = {
      { 0, 10, 20, 16, 16 },   // layer 0: [10,26) x [20,36)
      { 0, 40, 5,  16, 16 },   // layer 0: [40,56) x [5,21)
      { 1, 0,  0,  200, 200 }, // layer 1 (canopy): much bigger, must be ignored
    };
    bgplane_bounds_t b = compute_bgplane_bounds(extents, 3, /*base_layer=*/0);
    assert(b.any == 1);
    assert(b.min_x == 0 && b.min_y == 0);   // raw min (10, 5) both positive -> clamped to 0
    assert(b.mw == 56 && b.mh == 36);       // max ex=56, max ey=36; unreduced since origin is 0
  }

  // Negative coordinates on the base layer are compensated (origin shifts
  // to cover them), matching the single-plane implementation this replaces.
  {
    bgplane_tile_extent_t extents[] = {
      { -1, -8, -24, 16, 16 },  // base layer is -1 here
      { -1, 100, 100, 16, 16 },
      { 0, 0, 0, 999, 999 },    // different layer, must be ignored
    };
    bgplane_bounds_t b = compute_bgplane_bounds(extents, 3, /*base_layer=*/-1);
    assert(b.any == 1);
    assert(b.min_x == -8 && b.min_y == -24);
    assert(b.mw == (100 + 16) - (-8));
    assert(b.mh == (100 + 16) - (-24));
  }

  // Base layer has zero matching extents: `any` stays false, and mw/mh/
  // min_x/min_y stay at their zero defaults -- callers must check `any`
  // before allocating a plane (a map where the base layer has no static
  // content should not bake anything, not bake a degenerate 0x0 plane).
  {
    bgplane_tile_extent_t extents[] = {
      { 1, 0, 0, 16, 16 },
      { 2, 5, 5, 16, 16 },
    };
    bgplane_bounds_t b = compute_bgplane_bounds(extents, 2, /*base_layer=*/0);
    assert(b.any == 0);
    assert(b.mw == 0 && b.mh == 0 && b.min_x == 0 && b.min_y == 0);
  }

  // Empty extents array entirely.
  {
    bgplane_bounds_t b = compute_bgplane_bounds(nullptr, 0, /*base_layer=*/0);
    assert(b.any == 0);
  }

  // [Task 6, generalized per-layer bake] Two DISTINCT layers, each with its own
  // static content, computed from the SAME extents array via two independent
  // calls (mirroring res_arm_'s new per-layer loop: one compute_bgplane_bounds
  // call per distinct layer present in res_static_buckets). Confirms the two
  // calls don't interfere with each other -- each returns ONLY its own layer's
  // bounds, correctly filtered, regardless of call order or the other layer's
  // (larger/overlapping/differently-positioned) content sharing the array.
  {
    bgplane_tile_extent_t extents[] = {
      { 0, 0,   0,   16, 16 },   // layer 0: [0,16) x [0,16)
      { 0, 100, 50,  16, 16 },   // layer 0: [100,116) x [50,66)
      { 1, -8,  -24, 16, 16 },   // layer 1: [-8,8) x [-24,-8)  (negative origin)
      { 1, 40,  40,  16, 16 },   // layer 1: [40,56) x [40,56)
      { 2, 0,   0,   999, 999 }, // layer 2: irrelevant to both calls below
    };
    bgplane_bounds_t b0 = compute_bgplane_bounds(extents, 5, /*base_layer=*/0);
    assert(b0.any == 1);
    assert(b0.min_x == 0 && b0.min_y == 0);        // both raw mins non-negative
    assert(b0.mw == 116 && b0.mh == 66);            // max ex=116, max ey=66

    bgplane_bounds_t b1 = compute_bgplane_bounds(extents, 5, /*base_layer=*/1);
    assert(b1.any == 1);
    assert(b1.min_x == -8 && b1.min_y == -24);      // negative origin compensated
    assert(b1.mw == (40 + 16) - (-8));
    assert(b1.mh == (40 + 16) - (-24));

    // Re-run b0's call AFTER b1's -- order must not matter (no shared/mutated
    // state between calls); same result both times.
    bgplane_bounds_t b0_again = compute_bgplane_bounds(extents, 5, /*base_layer=*/0);
    assert(b0_again.any == b0.any);
    assert(b0_again.mw == b0.mw && b0_again.mh == b0.mh);
    assert(b0_again.min_x == b0.min_x && b0_again.min_y == b0.min_y);
  }

  std::printf("RESULT: PASS\n");
  return 0;
}
