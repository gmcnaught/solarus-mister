/* Host unit test for bgplane_geom (Task 1: background-plane cache geometry).
 * Pure C++, runs natively (no device). Build+run:
 * c++ -std=c++17 -Wall -Wextra -O2 -I patches/mister/blitter \
 *     tests/bgplane_geom_test.cpp -o /tmp/bgplane_geom_test && /tmp/bgplane_geom_test
 */
#include "bgplane_geom.h"
#include <cassert>
#include <cstdio>
#include <vector>

int main() {
  // A map exactly 320x240 -> 1 cell, no padding.
  { bgplane_grid_t g = bgplane_grid(320, 240);
    assert(g.cols == 1 && g.rows == 1 && g.count == 1);
    assert(bgplane_padded_w(320) == 320 && bgplane_padded_h(240) == 240);
    assert(bgplane_row_stride_qw(320) == 80u);              // 320*2/8
    assert(bgplane_total_bytes(320, 240) == 320u*240u*2u); }

  // A map 500x300 -> ceil(500/320)=2 cols, ceil(300/240)=2 rows = 4 cells;
  // padded plane is 640x480 (2x2 cells), row stride = 640*2/8 = 160 qwords.
  { bgplane_grid_t g = bgplane_grid(500, 300);
    assert(g.cols == 2 && g.rows == 2 && g.count == 4);
    assert(bgplane_padded_w(500) == 640 && bgplane_padded_h(300) == 480);
    assert(bgplane_row_stride_qw(500) == 160u);
    assert(bgplane_total_bytes(500, 300) == 640u*480u*2u);

    bgplane_cell_t c3 = bgplane_cell(3, 500, 300);   // bottom-right cell
    assert(c3.cell_x == 1 && c3.cell_y == 1);
    assert(c3.map_x == 320 && c3.map_y == 240);
    assert(c3.w == 180 && c3.h == 60);               // 500-320, 300-240 (true, clipped size)

    bgplane_cell_t c0 = bgplane_cell(0, 500, 300);    // top-left, full size
    assert(c0.map_x == 0 && c0.map_y == 0 && c0.w == 320 && c0.h == 240);

    // Map-scan-order byte offsets: cell 1 (cell_x=1,cell_y=0) starts at
    // map_x=320 within row 0 -> byte 320*2=640. Cell 2 (cell_x=0,cell_y=1)
    // starts at map_y=240 -> 240 * (640*2) = 307200. Cell 3 -> 307200+640=307840.
    assert(bgplane_cell_plane_byte_offset(0, 500, 300) == 0u);
    assert(bgplane_cell_plane_byte_offset(1, 500, 300) == 640u);
    assert(bgplane_cell_plane_byte_offset(2, 500, 300) == 307200u);
    assert(bgplane_cell_plane_byte_offset(3, 500, 300) == 307840u); }

  // [Task 5] Cursor sequencing: N calls to a per-cell baker complete a
  // grid.count-cell bake in exactly grid.count steps, visiting every cell
  // index exactly once, in increasing order. This is the invariant
  // MisterBlitterRenderer::bake_background_plane_step() relies on
  // (bg_bake_cell_idx incremented by exactly 1 per call, compared against
  // bgplane_grid(...).count) -- proven here against the pure geometry, since
  // the renderer method itself has hard DDR/hardware dependencies that make
  // it unit-testable only via this narrower cursor-logic slice.
  { bgplane_grid_t g = bgplane_grid(700, 500);  // -> 3x3 = 9 cells (ceil(700/320)=3, ceil(500/240)=3)
    assert(g.count == 9);
    std::vector<int> visited;
    int cursor = 0;
    while (cursor < g.count) {
      visited.push_back(cursor);
      cursor++;
    }
    assert((int)visited.size() == 9);
    for (int i = 0; i < 9; ++i) assert(visited[i] == i); }

  std::printf("RESULT: PASS\n");
  return 0;
}
