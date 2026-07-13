/* [PAL8 v1, Task 2.4] Host regression test: cumulative multi-tileset PAL8 staging.
 *
 * Modeled on the #84 cumulative regression (solarus-hostfix-84's
 * tests/preload_restage_test.c): the #84 bug class only shows up AFTER several
 * distinct immutable surfaces have each been staged into the grow-only permanent
 * SDRAM region -- a single-surface test structurally cannot see it. This test
 * drives >=6 distinct paletted-surface-sized index planes through the REAL
 * allocator path mister_blitter_renderer.cpp's preload_stage_pal8() uses
 * (blt_upload + blt_stage_surface_perm), and the REAL CLUT bank packer
 * (pal_pack) every immutable pal8 surface goes through first, and asserts:
 *
 *   (a) every staged surface's SDRAM offset stays IN-RANGE (< perm size) and
 *       DISTINCT from every other surface's -- no runaway offset past perm,
 *       the #84 class -- and, symmetrically, every packed surface's CLUT
 *       (bank,base) stays within the fabric's bank/entry bounds and doesn't
 *       alias another surface's slots in the same bank (the CLUT-side analog
 *       of the same "N-th cumulative allocation" bug class);
 *   (b) with v1's 16bpp index storage (index in the low byte; Phase 3/Task 3.2
 *       repacks to true 8bpp) the perm footprint after N tileset-sized surfaces
 *       is EXACTLY N * (w*h*2) -- the 16bpp baseline. Task 3.2 will change this
 *       assertion to the HALVED (w*h*1) footprint once 8bpp packing lands; the
 *       cumulative-offset/no-runaway assertions above stay valid unchanged.
 *
 * A companion case sizes perm deliberately too small and confirms the SAME
 * backstop #84 relied on: overflow is DETECTED (stage returns -1, sdram_off
 * stays BLT_ALLOC_FAIL) rather than silently handing back a runaway offset.
 */
#include "blitter_ref.h"
#include "blt_emitter.h"
#include "blt_wire.h"
#include "blt_alloc.h"
#include "palette_atlas.h"
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;
#define CHECK(c,m) do{ if(!(c)){ printf("FAIL: %s (line %d)\n", m, __LINE__); failures++; } }while(0)

/* Tileset-sized index plane: 128x128, v1 16bpp storage -> 32 KiB/surface,
 * matching the #84 regression's TSZ so the "footprint == N*baseline" reads
 * against the same field-scale numbers. */
enum { TW = 128, TH = 128 };
#define TSZ ((uint32_t)TW * TH * 2u)          /* 32768 B, v1 16bpp index storage */
enum { N_TILESETS = 8 };                       /* >=6 required; matches field census scale */
enum { HEADROOM = 2 };                         /* a little slack above exactly-N */
#define PERM_SIZE_FIT   ((uint32_t)(N_TILESETS + HEADROOM) * TSZ)
#define PERM_SIZE_TIGHT ((uint32_t)(N_TILESETS - 2) * TSZ)   /* deliberately short */

/* One synthetic index plane per tileset: value pattern doesn't matter for the
 * allocator/packer paths under test (pal_pack only reads ncolors/clut_*, the
 * stage path only cares about byte size) -- distinct small patterns just make
 * a failure easy to eyeball if ever dumped. */
static uint16_t idx16[TW * TH];

/* Stage one freshly-"uploaded" index plane into perm, mirroring
 * preload_stage_pal8()'s sequence exactly (bounce reset -> upload -> stage). */
static int stage_pal8_fresh(blt_emitter_t *e, blt_surface_ref_t *out) {
    blt_heap_reset(e);
    blt_surface_ref_t r = blt_upload(e, idx16, TW, TH, TW * 2);
    int rc = (r.valid) ? blt_stage_surface_perm(e, &r) : -1;
    *out = r;
    return rc;
}

/* ── (a)+(b): perm allocator — N distinct surfaces fit, offsets in-range/distinct,
 * footprint == N*TSZ (the 16bpp v1 baseline; Task 3.2 halves this). ────────────── */
static void test_perm_cumulative_fits(void) {
    static uint8_t ring[256 * BLT_CMD_BYTES];
    static uint8_t heap[4 * TSZ];
    blt_emitter_t e;
    blt_emitter_init(&e, ring, sizeof ring, heap, sizeof heap);
    blt_sdram_regions_init(&e, 0u, PERM_SIZE_FIT, PERM_SIZE_FIT, PERM_SIZE_FIT);
    blt_begin_frame(&e, 0, 0, 0);

    blt_surface_ref_t refs[N_TILESETS];
    for (int i = 0; i < N_TILESETS; i++) {
        int rc = stage_pal8_fresh(&e, &refs[i]);
        CHECK(rc == 0 && refs[i].sdram_off != BLT_ALLOC_FAIL,
              "pal8 cumulative: stage ok");
    }
    CHECK(e.perm_overflow == 0, "pal8 cumulative: no perm overflow with headroom");

    /* (a) every offset in-range and distinct — the #84 "no runaway" property. */
    for (int i = 0; i < N_TILESETS; i++) {
        CHECK(refs[i].sdram_off < PERM_SIZE_FIT, "pal8 cumulative: offset in perm range");
        for (int j = i + 1; j < N_TILESETS; j++)
            CHECK(refs[i].sdram_off != refs[j].sdram_off, "pal8 cumulative: offsets distinct");
    }

    /* (b) v1 16bpp-index footprint: exactly N*TSZ. Task 3.2 (true 8bpp packing)
     * will change this to N*(TW*TH) -- the halved footprint -- once it lands;
     * the offset/no-runaway checks above are format-agnostic and stay valid. */
    uint32_t used = blt_alloc_used(&e.sdram_perm);
    CHECK(used == (uint32_t)N_TILESETS * TSZ,
          "pal8 cumulative: perm footprint == N * 16bpp-index baseline");
}

/* ── overflow backstop: perm sized too small for N surfaces -> the allocator
 * DETECTS it (no runaway offset handed back), same #84 contract. ──────────────── */
static void test_perm_cumulative_overflow_detected(void) {
    static uint8_t ring[256 * BLT_CMD_BYTES];
    static uint8_t heap[4 * TSZ];
    blt_emitter_t e;
    blt_emitter_init(&e, ring, sizeof ring, heap, sizeof heap);
    blt_sdram_regions_init(&e, 0u, PERM_SIZE_TIGHT, PERM_SIZE_TIGHT, PERM_SIZE_TIGHT);
    blt_begin_frame(&e, 0, 0, 0);

    int fit_count = 0, overflow_rc = 0;
    blt_surface_ref_t bad = (blt_surface_ref_t){0};
    for (int i = 0; i < N_TILESETS; i++) {
        blt_surface_ref_t r;
        int rc = stage_pal8_fresh(&e, &r);
        if (rc == 0 && r.sdram_off != BLT_ALLOC_FAIL) {
            fit_count++;
        } else {
            overflow_rc = rc; bad = r; break;
        }
    }
    CHECK(fit_count == (N_TILESETS - 2), "pal8 overflow: exactly the sized headroom fits");
    CHECK(overflow_rc == -1, "pal8 overflow: (N-1)th surface returns -1");
    CHECK(e.perm_overflow == 1, "pal8 overflow: perm_overflow flag set");
    /* The core #84-class guarantee: NO runaway offset — the caller (preload_
     * stage_pal8) can detect this and die loudly instead of caching a garbage
     * SDRAM offset the fabric would read as corrupt tiles. */
    CHECK(bad.sdram_off == BLT_ALLOC_FAIL, "pal8 overflow: FAIL, not a runaway offset");
}

/* ── CLUT-side cumulative check: pal_pack across >=6 distinct surfaces stays
 * within fabric bank/entry bounds and never aliases a prior surface's slots in
 * the same bank -- the CLUT analog of the perm-allocator #84 bug class (a
 * single-surface test can't see a bank filling up after several packs). ────────── */
static void test_clut_pack_cumulative(void) {
    pal_bankset bs;
    pal_bankset_init(&bs);

    /* Palette sizes chosen so several surfaces share bank 0 before it fills
     * (0+... < 256) and later surfaces spill into bank 1+ -- exercising
     * first-fit's cross-bank behavior cumulatively. */
    const int ncolors[N_TILESETS] = { 64, 64, 64, 64, 200, 32, 100, 16 };
    uint8_t bank[N_TILESETS], base[N_TILESETS];

    for (int i = 0; i < N_TILESETS; i++) {
        bool ok = pal_pack(&bs, &(pal_surface){ .ncolors = ncolors[i] }, &bank[i], &base[i]);
        CHECK(ok, "clut cumulative: pack succeeds");
        CHECK(bank[i] < PAL_CLUT_BANKS, "clut cumulative: bank in range");
        CHECK((int)base[i] + ncolors[i] <= PAL_CLUT_ENTRIES,
              "clut cumulative: [base,base+ncolors) fits in the bank");
    }

    /* No two surfaces sharing a bank may have overlapping [base,base+ncolors). */
    for (int i = 0; i < N_TILESETS; i++) {
        for (int j = i + 1; j < N_TILESETS; j++) {
            if (bank[i] != bank[j]) continue;
            int lo_i = base[i], hi_i = base[i] + ncolors[i];
            int lo_j = base[j], hi_j = base[j] + ncolors[j];
            CHECK(hi_i <= lo_j || hi_j <= lo_i,
                  "clut cumulative: same-bank surfaces don't alias each other's slots");
        }
    }
}

int main(void) {
    for (int i = 0; i < TW * TH; i++) idx16[i] = (uint16_t)(i & 0xFF);   /* index in low byte */

    test_perm_cumulative_fits();
    test_perm_cumulative_overflow_detected();
    test_clut_pack_cumulative();

    printf(failures ? "FAILED (%d)\n" : "ok pal_restage (PAL8 v1 cumulative multi-tileset)\n",
           failures);
    return failures ? 1 : 0;
}
