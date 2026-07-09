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

  std::printf("RESULT: PASS\n");
  return 0;
}
