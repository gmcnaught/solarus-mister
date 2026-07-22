/* [Stage 5 lever / Task 2] gridov_equiv_test — prove the K-grid overlap
 * decomposition (blt_grid_decompose, Task 1) composites PIXEL-IDENTICALLY to
 * the current per-tile replay path for an OVERLAPPING tile bucket. This is
 * the correctness bar for the whole Stage 5 lever: a bucket the single-pid
 * grid cannot represent (blt_grid_build_ov's `overlapped` flag) decomposes
 * into K non-overlapping sub-layers, each sub-layer built as its own grid via
 * blt_grid_build and walked with blt_ref_tilemap in painter's order.
 *
 * Harness copied VERBATIM (heap/atlas/header construction) from
 * patches/mister/blitter/test_grid_walk_equiv.c — see that file's header
 * comment for the harness rationale. This test adds the two-framebuffer
 * (fb_ref vs fb_grid) overlap comparison on top.
 *
 * Build:
 *   cc -Wall -Wextra -O2 -I patches/mister/blitter tests/gridov_equiv_test.c \
 *      patches/mister/blitter/blitter_ref.c patches/mister/blitter/blt_emitter.c \
 *      patches/mister/blitter/blt_alloc.c -o /tmp/gridov_equiv_test && \
 *      /tmp/gridov_equiv_test
 */
#include "blitter_ref.h"
#include "grid_cell.h"
#include "grid_build.h"
#include "grid_decompose.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

/* Shared deterministic atlas: 256x64 RGB565, distinct-per-pixel so a wrong
 * src-offset / order bug would perturb the compared framebuffers. Copied
 * from test_grid_walk_equiv.c's atlas_init(). */
enum { ATLAS_W = 256, ATLAS_H = 64 };
static uint16_t g_atlas[ATLAS_W * ATLAS_H];

static void atlas_init(void) {
    for (int i = 0; i < ATLAS_W * ATLAS_H; i++)
        g_atlas[i] = (uint16_t)((unsigned)i * 2654435761u);   /* Knuth hash */
}

/* Shared BLT_OP_TILEMAP header: BLEND (CONST_ALPHA) out of the atlas, so
 * paint ORDER actually changes the composited result -- an opaque COPY
 * header would mask a mis-ordered sub-layer (the top layer would win either
 * way). alpha=128 is a genuine partial blend, not an accidental COPY/nop. */
static blt_cmd_t blend_header(void) {
    blt_cmd_t h;
    memset(&h, 0, sizeof h);
    h.opcode     = BLT_OP_TILEMAP;
    h.blend_mode = BLT_BLEND_CONST_ALPHA;
    h.format     = BLT_FMT_RGB565;
    h.alpha      = 128;
    h.src_off    = 0;
    h.src_stride = (uint16_t)(ATLAS_W * 2);
    return h;
}

static int g_fail = 0;
#define CHECK(cond, msg) do { if (!(cond)) { g_fail++; printf("  FAIL: %s\n", msg); } } while (0)

/* Composite `tiles[0..n)` (in painter's/emission order) onto `fb` the way the
 * REPLAY path does: each tile drawn as its own 1-tile grid via
 * blt_ref_tilemap, same header/blend, later tiles blending on top of
 * earlier ones. This is the ground truth the K-grid path must match. */
static void composite_replay(uint16_t *fb, const blt_surface_heap_t *heap_template,
                             const blt_cmd_t *hdr, const blt_grid_tile_t *tiles, size_t n,
                             uint16_t gw, uint16_t gh, int16_t bias_x, int16_t bias_y) {
    static blt_grid_cell_t cells[64 * 64];
    blt_surface_heap_t h = *heap_template;
    h.grid = (const uint8_t *)cells;
    for (size_t t = 0; t < n; t++) {
        int rc = blt_grid_build(cells, gw, gh, &tiles[t], 1);
        assert(rc == 0);
        blt_ref_tilemap(fb, &h, hdr, /*cells_off=*/0, gw, gh, bias_x, bias_y);
    }
}

/* Composite `tiles[0..n)` onto `fb` the way the K-GRID path does:
 * blt_grid_decompose assigns each tile a sub-layer (painter's-order stack
 * height); each sub-layer's tiles are collected and built into their OWN
 * non-overlapping grid via blt_grid_build; the sub-layers walk in order
 * 0..K-1 via blt_ref_tilemap, same header/blend. */
static int composite_grid(uint16_t *fb, const blt_surface_heap_t *heap_template,
                          const blt_cmd_t *hdr, const blt_grid_tile_t *tiles, size_t n,
                          uint16_t gw, uint16_t gh, int16_t bias_x, int16_t bias_y,
                          int max_k) {
    static uint8_t occ[64 * 64];
    static int sublayer_of_tile[64];
    assert(n <= 64);
    int K = blt_grid_decompose(tiles, n, gw, gh, occ, sublayer_of_tile, max_k);
    assert(K >= 1);

    static blt_grid_cell_t cells[64 * 64];
    blt_surface_heap_t h = *heap_template;
    h.grid = (const uint8_t *)cells;

    for (int layer = 0; layer < K; layer++) {
        static blt_grid_tile_t layer_tiles[64];
        int nlt = 0;
        for (size_t t = 0; t < n; t++)
            if (sublayer_of_tile[t] == layer)
                layer_tiles[nlt++] = tiles[t];
        assert(nlt > 0);
        int rc = blt_grid_build(cells, gw, gh, layer_tiles, (size_t)nlt);
        CHECK(rc == 0, "sub-layer grid build failed (should be non-overlapping by construction)");
        blt_ref_tilemap(fb, &h, hdr, /*cells_off=*/0, gw, gh, bias_x, bias_y);
    }
    return K;
}

/* ── Case 1 — 2-DEEP overlap ────────────────────────────────────────────────
 * Two 2x2-cell tiles (distinct pids), painted in order [0, 1], sharing ONE
 * cell (3,3):
 *   tile0 (pid 0): cells (2,2)-(3,3)
 *   tile1 (pid 1): cells (3,3)-(4,4)   <- overlaps tile0 at (3,3)
 * decompose: tile0 -> sub-layer 0; tile1 sees occ=1 at (3,3) -> sub-layer 1.
 * K == 2. */
static void case_2deep(void) {
    enum { GW = 8, GH = 8 };
    const int16_t bias_x = 32, bias_y = 40;   /* on-screen, arbitrary offset */

    static blt_frame_rect_t frt[BLT_MAXP * BLT_MAXF];
    memset(frt, 0, sizeof frt);
    frt[0 * BLT_MAXF + 0] = (blt_frame_rect_t){   0,  0, 16, 16 };  /* pid 0: 2x2-cell pattern */
    frt[1 * BLT_MAXF + 0] = (blt_frame_rect_t){  32,  0, 16, 16 };  /* pid 1: 2x2-cell pattern */

    blt_grid_tile_t tiles[2] = {
        { /*pid=*/0, /*cell_x=*/2, /*cell_y=*/2, /*w_cells=*/2, /*h_cells=*/2 },
        { /*pid=*/1, /*cell_x=*/3, /*cell_y=*/3, /*w_cells=*/2, /*h_cells=*/2 },
    };

    blt_surface_heap_t heap = { .base = (const uint8_t *)g_atlas, .size = sizeof g_atlas,
                                .frt = (const uint8_t *)frt, .cft = NULL,
                                .clut = NULL, .grid = NULL };
    blt_cmd_t hdr = blend_header();

    static uint16_t fb_ref[BLT_FB_PIXELS], fb_grid[BLT_FB_PIXELS];
    memset(fb_ref,  0x00, sizeof fb_ref);
    memset(fb_grid, 0x00, sizeof fb_grid);

    composite_replay(fb_ref, &heap, &hdr, tiles, 2, GW, GH, bias_x, bias_y);
    int K = composite_grid(fb_grid, &heap, &hdr, tiles, 2, GW, GH, bias_x, bias_y, /*max_k=*/8);
    CHECK(K == 2, "case_2deep: expected K==2");

    CHECK(memcmp(fb_ref, fb_grid, sizeof fb_ref) == 0,
          "case_2deep: fb_grid != fb_ref (K-grid decomposition diverged from replay)");
}

/* ── Case 2 — 3-DEEP overlap ────────────────────────────────────────────────
 * Three 2x2-cell tiles (distinct pids), painted in order [0, 1, 2], each
 * sharing the PREVIOUS tile's bottom-right cell so the stack is exactly 3
 * deep at cell (5,5):
 *   tile0 (pid 0): cells (2,2)-(3,3)
 *   tile1 (pid 1): cells (3,3)-(4,4)   <- overlaps tile0 at (3,3)
 *   tile2 (pid 2): cells (4,4)-(5,5)   <- overlaps tile1 at (4,4)
 * decompose: tile0 -> 0; tile1 -> 1 (sees occ=1 at (3,3)); tile2 -> 2 (sees
 * occ=2 at (4,4)). K == 3. */
static void case_3deep(void) {
    enum { GW = 8, GH = 8 };
    const int16_t bias_x = 96, bias_y = 40;   /* on-screen, disjoint from case 1 */

    static blt_frame_rect_t frt[BLT_MAXP * BLT_MAXF];
    memset(frt, 0, sizeof frt);
    frt[0 * BLT_MAXF + 0] = (blt_frame_rect_t){   0,  0, 16, 16 };  /* pid 0 */
    frt[1 * BLT_MAXF + 0] = (blt_frame_rect_t){  32,  0, 16, 16 };  /* pid 1 */
    frt[2 * BLT_MAXF + 0] = (blt_frame_rect_t){  64,  0, 16, 16 };  /* pid 2 */

    blt_grid_tile_t tiles[3] = {
        { /*pid=*/0, /*cell_x=*/2, /*cell_y=*/2, /*w_cells=*/2, /*h_cells=*/2 },
        { /*pid=*/1, /*cell_x=*/3, /*cell_y=*/3, /*w_cells=*/2, /*h_cells=*/2 },
        { /*pid=*/2, /*cell_x=*/4, /*cell_y=*/4, /*w_cells=*/2, /*h_cells=*/2 },
    };

    blt_surface_heap_t heap = { .base = (const uint8_t *)g_atlas, .size = sizeof g_atlas,
                                .frt = (const uint8_t *)frt, .cft = NULL,
                                .clut = NULL, .grid = NULL };
    blt_cmd_t hdr = blend_header();

    static uint16_t fb_ref[BLT_FB_PIXELS], fb_grid[BLT_FB_PIXELS];
    memset(fb_ref,  0x00, sizeof fb_ref);
    memset(fb_grid, 0x00, sizeof fb_grid);

    composite_replay(fb_ref, &heap, &hdr, tiles, 3, GW, GH, bias_x, bias_y);
    int K = composite_grid(fb_grid, &heap, &hdr, tiles, 3, GW, GH, bias_x, bias_y, /*max_k=*/8);
    CHECK(K == 3, "case_3deep: expected K==3");

    CHECK(memcmp(fb_ref, fb_grid, sizeof fb_ref) == 0,
          "case_3deep: fb_grid != fb_ref (K-grid decomposition diverged from replay)");
}

int main(void) {
    atlas_init();
    case_2deep();
    case_3deep();

    if (g_fail) { printf("gridov_equiv_test FAILED (%d)\n", g_fail); return 1; }
    printf("gridov_equiv: OK\n");
    return 0;
}
