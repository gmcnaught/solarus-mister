/* Models bake_all_planes_sync()'s batch loop (mister_blitter_renderer.cpp) over
 * real plane geometry + the real emitter, and asserts the invariants the real
 * method must honor:
 *   (1) COMPLETENESS  — every cell of every plane gets exactly one
 *                       OP_BGPLANE_WRITE across all submitted batches.
 *   (2) DISPLAY SAFETY — the last command emitted in every submitted batch is a
 *                        full-screen background_color FILL (so the WORK->SCAN
 *                        snapshot is flat bg color, never bake scribble).
 *   (3) BOUNDEDNESS   — batch count stays within a small bound.
 *   (4) NO OVERFLOW   — no submitted batch set the emitter overflow flag.
 * MUST MATCH the loop shape in bake_all_planes_sync(). GPL-3.0. */
#include "blitter_ref.h"
#include "blt_emitter.h"
#include "blt_wire.h"
#include "blt_alloc.h"
#include "bgplane_geom.h"
#include "bgplane_sync.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { FB_W = 320, FB_H = 240 };
#define BG565 0x4CE9u   /* to_rgb565(72,152,72), the zsdx tileset-1 background */

/* One layer's plane geometry (mirrors Impl::BgPlane's baked fields). */
typedef struct { int map_w, map_h; uint32_t sdram_base; int cells, next_cell; } plane_t;

/* Decode the command at ring index i. */
static blt_cmd_t cmd_at(const uint8_t *ring, int i) {
    blt_cmd_t c; blt_unpack_cmd(ring + (size_t)i * BLT_CMD_BYTES, &c); return c;
}

/* Run the modeled sync bake for a set of planes with a given ring capacity.
 * Records, for every OP_BGPLANE_WRITE, its target qword offset (to verify
 * coverage), and checks the display-safety FILL at each submit. Returns the
 * number of batches submitted. */
static int run_model(plane_t *planes, int n_planes, size_t ring_bytes,
                     uint32_t *seen_off, int *seen_n) {
    uint8_t *ring = malloc(ring_bytes);
    blt_emitter_t em;
    /* 5-arg init: (e, ring, ring_cap, heap, heap_cap). No heap or TL_BUF needed —
     * this model emits only FILL / OP_BGPLANE_WRITE, never a real TILELIST. */
    blt_emitter_init(&em, ring, ring_bytes, NULL, 0);
    const size_t ring_cmd_cap = ring_bytes / BLT_CMD_BYTES;

    blt_begin_frame(&em, 0, 0, 0x0000);
    int batches = 0;

    for (;;) {
        /* Find the next plane with a cell left to bake. */
        plane_t *p = NULL;
        for (int i = 0; i < n_planes; ++i)
            if (planes[i].next_cell < planes[i].cells) { p = &planes[i]; break; }

        int cut = (p == NULL) || bgplane_sync_cut_before_cell(em.cmd_count, ring_cmd_cap);

        if (cut) {
            /* Display safety: bg FILL is the last command in the batch. */
            blt_fill(&em, 0, 0, FB_W, FB_H, BG565);
            /* --- modeled submit_and_drain(): inspect, then reset the ring --- */
            assert(em.overflow == 0);                    /* (4) */
            blt_cmd_t last = cmd_at(ring, em.cmd_count - 1);
            assert(last.opcode == BLT_OP_FILL);          /* (2) */
            assert(last.color == BG565);
            assert(last.w == FB_W && last.h == FB_H);
            ++batches;
            blt_end_frame(&em);                          /* bumps submit_seq */
            blt_begin_frame(&em, 0, 0, 0x0000);          /* fresh ring */
            if (p == NULL) break;                        /* all planes done */
            continue;
        }

        /* Emit ONE cell exactly like bake_background_plane_step's inner body:
         * clear-WORK FILL, BLT_F_BGCOV coverage FILL, (modeled tile paint as one
         * FILL), then OP_BGPLANE_WRITE at this cell's plane offset. */
        int idx = p->next_cell;
        blt_fill(&em, 0, 0, FB_W, FB_H, 0x0000);
        blt_fill_flags(&em, 0, 0, FB_W, FB_H, 0, BLT_F_BGCOV);
        blt_fill(&em, 0, 0, FB_W, FB_H, 0x1234);         /* stand-in for tile paint */
        uint32_t cell_off = bgplane_cell_plane_byte_offset(idx, p->map_w, p->map_h);
        uint32_t qw_off = (p->sdram_base + cell_off) / 8;
        uint32_t stride_qw = bgplane_row_stride_qw(p->map_w);
        int rc = blt_bgplane_write_cell(&em, qw_off, stride_qw, BLT_F_BGCOV);
        assert(rc == 0 && em.overflow == 0);
        seen_off[(*seen_n)++] = qw_off;
        p->next_cell++;
    }

    free(ring);
    return batches;
}

/* Assert every plane cell's qword offset appears exactly once in seen_off. */
static void check_coverage(plane_t *planes, int n_planes,
                           const uint32_t *seen_off, int seen_n) {
    int expect_total = 0;
    for (int i = 0; i < n_planes; ++i) {
        bgplane_grid_t g = bgplane_grid(planes[i].map_w, planes[i].map_h);
        expect_total += g.count;
        for (int c = 0; c < g.count; ++c) {
            uint32_t off = bgplane_cell_plane_byte_offset(c, planes[i].map_w, planes[i].map_h);
            uint32_t qw = (planes[i].sdram_base + off) / 8;
            int hits = 0;
            for (int k = 0; k < seen_n; ++k) if (seen_off[k] == qw) ++hits;
            assert(hits == 1);   /* (1) exactly-once coverage */
        }
    }
    assert(seen_n == expect_total);   /* no extra writes */
}

int main(void) {
    /* Two planes (base + one upper), map-119-like base dimensions. */
    plane_t base_planes[2] = {
        { .map_w = 640, .map_h = 752, .sdram_base = 0x01000000u, .cells = 0, .next_cell = 0 },
        { .map_w = 640, .map_h = 752, .sdram_base = 0x02000000u, .cells = 0, .next_cell = 0 },
    };
    for (int i = 0; i < 2; ++i)
        base_planes[i].cells = bgplane_grid(base_planes[i].map_w, base_planes[i].map_h).count;

    /* Case A: huge ring -> single batch. */
    {
        plane_t planes[2]; memcpy(planes, base_planes, sizeof(planes));
        uint32_t seen[4096]; int seen_n = 0;
        int batches = run_model(planes, 2, 512u * 1024u, seen, &seen_n);
        check_coverage(planes, 2, seen, seen_n);
        assert(batches == 1);            /* (3) fits one ring */
        printf("bgplane_sync_bake caseA(single-batch): batches=%d cells=%d PASS\n",
               batches, seen_n);
    }

    /* Case B: tiny ring -> forced multi-batch; same invariants must hold. */
    {
        plane_t planes[2]; memcpy(planes, base_planes, sizeof(planes));
        uint32_t seen[4096]; int seen_n = 0;
        /* Ring just big enough for the margin + a couple cells. */
        size_t tiny = (BGPLANE_SYNC_CELL_MARGIN + 8) * BLT_CMD_BYTES;
        int batches = run_model(planes, 2, tiny, seen, &seen_n);
        check_coverage(planes, 2, seen, seen_n);
        assert(batches >= 2 && batches < seen_n + 4);   /* (3) many but bounded */
        printf("bgplane_sync_bake caseB(multi-batch): batches=%d cells=%d PASS\n",
               batches, seen_n);
    }

    printf("bgplane_sync_bake: RESULT: PASS\n");
    return 0;
}
