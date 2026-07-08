#ifndef BGPLANE_GEOM_H
#define BGPLANE_GEOM_H
#include <stdint.h>

// Background-plane cell grid: the plane is BAKED in on-chip-BRAM-sized cells
// (comp_fbram is fixed at one 320x240 screen, FB_QWORDS=19200 qwords @
// 16bpp -- see fpga/rtl/fbram_snapshot.sv:15) but STORED as one contiguous
// map-scan-order image (row stride = the whole padded map width), NOT as a
// grid of independently-padded tiles -- so the per-frame COPY is always a
// single ordinary windowed blit, never a boundary-straddling multi-blit.
// Both plane dimensions are padded up to a cell-size multiple purely so a
// cell's full 320-wide row write never overruns a neighboring row's real
// data; the padding past the map's true edge is allocated but never read.
#define BGPLANE_CELL_W 320
#define BGPLANE_CELL_H 240
#define BGPLANE_BYTES_PER_PIXEL 2   // matches comp_fbram's RGB565-class format

typedef struct { int cols, rows, count; } bgplane_grid_t;
typedef struct { int cell_x, cell_y; int map_x, map_y; int w, h; } bgplane_cell_t;

static inline bgplane_grid_t bgplane_grid(int map_w, int map_h) {
    bgplane_grid_t g;
    g.cols = (map_w + BGPLANE_CELL_W - 1) / BGPLANE_CELL_W;
    g.rows = (map_h + BGPLANE_CELL_H - 1) / BGPLANE_CELL_H;
    if (g.cols < 1) g.cols = 1;
    if (g.rows < 1) g.rows = 1;
    g.count = g.cols * g.rows;
    return g;
}

// Cell index -> its map-coord origin + this cell's true (possibly clipped) size.
static inline bgplane_cell_t bgplane_cell(int cell_idx, int map_w, int map_h) {
    bgplane_grid_t g = bgplane_grid(map_w, map_h);
    bgplane_cell_t c;
    c.cell_x = cell_idx % g.cols;
    c.cell_y = cell_idx / g.cols;
    c.map_x  = c.cell_x * BGPLANE_CELL_W;
    c.map_y  = c.cell_y * BGPLANE_CELL_H;
    int rem_w = map_w - c.map_x, rem_h = map_h - c.map_y;
    c.w = rem_w < BGPLANE_CELL_W ? rem_w : BGPLANE_CELL_W;
    c.h = rem_h < BGPLANE_CELL_H ? rem_h : BGPLANE_CELL_H;
    return c;
}

static inline int bgplane_padded_w(int map_w) {
    return ((map_w + BGPLANE_CELL_W - 1) / BGPLANE_CELL_W) * BGPLANE_CELL_W;
}
static inline int bgplane_padded_h(int map_h) {
    return ((map_h + BGPLANE_CELL_H - 1) / BGPLANE_CELL_H) * BGPLANE_CELL_H;
}

// Row stride of the plane, in 8-byte qwords -- constant for the whole bake
// of a given map, passed to every cell's OP_BGPLANE_WRITE command.
static inline uint32_t bgplane_row_stride_qw(int map_w) {
    return (uint32_t)(bgplane_padded_w(map_w) * BGPLANE_BYTES_PER_PIXEL / 8);
}

// Total bytes to permanently allocate for this map's plane.
static inline uint32_t bgplane_total_bytes(int map_w, int map_h) {
    return (uint32_t)bgplane_padded_w(map_w) * (uint32_t)bgplane_padded_h(map_h)
           * BGPLANE_BYTES_PER_PIXEL;
}

// Byte offset of cell cell_idx's TOP-LEFT pixel within the padded,
// map-scan-order plane. Row r (0..cell.h-1) of this cell begins at this
// offset plus r * bgplane_row_stride_qw(map_w) * 8.
static inline uint32_t bgplane_cell_plane_byte_offset(int cell_idx, int map_w, int map_h) {
    bgplane_cell_t c = bgplane_cell(cell_idx, map_w, map_h);
    uint32_t stride_bytes = bgplane_padded_w(map_w) * (uint32_t)BGPLANE_BYTES_PER_PIXEL;
    return (uint32_t)c.map_y * stride_bytes + (uint32_t)c.map_x * BGPLANE_BYTES_PER_PIXEL;
}

#endif
