/*
 *  sdram_selftest.c — on-device SDRAM second-bus round-trip self-test (issue #34).
 *
 *  WHY: the #31/#32/#33 RBF renders BLACK on the SDRAM-source path on real
 *  silicon while every iverilog sim passes (the documented sim-clean/HW-broken
 *  SDRAM gap). The DE10-Nano SDRAM is NOT in the HPS memory map, so the ARM
 *  cannot peek at it directly. This standalone binary isolates the fabric
 *  STAGE(DDR3->SDRAM) + BLIT(SDRAM->DDR3) path from the entire engine/quest/SDL
 *  stack and measures it directly, sweeping SDRAM offsets across the address bits
 *  the #31 64MB geometry remapped (col=addr[10:1], bank=addr[12:11], row=addr[25:13]).
 *
 *  WHAT it does, per swept SDRAM offset:
 *    1. blt_upload a 64x64 position-encoding RGB565 pattern into the DDR3 heap
 *       (each pixel = (y<<8)|x), and verify the DDR3 copy landed (boundary 1).
 *    2. STAGE it DDR3->SDRAM at the offset under test (blt_stage_to), submit,
 *       wait C_DONE (boundary 2: SDRAM written — unobservable from the ARM).
 *    3. Clear framebuffer 0, then BLIT from SDRAM (C_SRCSEL=1) at that offset back
 *       into the framebuffer, submit, wait C_DONE (boundary 3: DDR3 readable).
 *    4. Read the framebuffer back and st_compare vs the pattern; print match%,
 *       nonzero count, and the decoded first-mismatch alias.
 *
 *  Interpreting the sweep:
 *    - all offsets ~100%            -> raw SDRAM path is fine on HW; the #34 bug is
 *                                      in the renderer integration (#33), not geometry.
 *    - low offsets OK, high (>=32MB,
 *      addr[25]=1) fail             -> the #31 high-address geometry bit is wrong.
 *    - all offsets ~0% / black      -> the whole column-low remap (or SDRAM timing)
 *                                      is broken; bisect vs the #19 32MB map.
 *    - matches but shifted/aliased  -> decoded "got -> (x,y)" fingerprints which
 *                                      address bit is mis-wired.
 *
 *  Build: scripts/build_sdram_selftest.sh (armhf cross via docker).
 *  Run on device (RBF loaded, engine NOT required):
 *    ./sdram_selftest                # default sweep
 *    ./sdram_selftest 0x100000 0x2000000 0x3f00000   # explicit offsets (bytes)
 *
 *  GPL-3.0.
 */
#include "sdram_pattern.h"
#include "blt_emitter.h"
#include "blt_alloc.h"
#include "blitter_ref.h"

#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

/* ---- DDR layout — MUST MATCH mister_blitter_renderer.cpp / blitter_defs.vh --- */
#define BLT_DDR_PHYS   0x3B000000u
#define BLT_DDR_SIZE   0x01000000u      /* 16 MiB: ctrl + ring + heap */
#define OFF_RING       0x00000040u
#define RING_CAP       0x00007FC0u
#define OFF_HEAP       0x00008000u
#define HEAP_CAP       0x00100000u      /* 1 MiB working heap (plenty for 8 KiB) */

#define VIDEO_PHYS     0x3A000000u
#define VIDEO_SIZE     0x00100000u      /* 1 MiB: ctrl word + framebuffers */
#define FB0_OFF        0x00000040u      /* buf0 pixels @ 0x3A000040 */
#define FB1_OFF        0x00040040u      /* buf1 pixels @ 0x3A040040 */
#define FB_W           320
#define FB_H           240

/* control-block byte offsets (qword-spaced; low 32 used) */
#define C_SUBMIT   0x00u
#define C_CMDCOUNT 0x08u
#define C_TARGET   0x10u
#define C_CLEAR    0x18u
#define C_FLAGS    0x20u
#define C_DONE     0x28u
#define C_SRCSEL   0x38u

static volatile uint8_t *g_ddr;   /* 0x3B mapping (ctrl/ring/heap) */
static volatile uint8_t *g_vid;   /* 0x3A mapping (framebuffers)   */

static inline void w32(volatile uint8_t *base, uint32_t off, uint32_t v) {
    *(volatile uint32_t *)(base + off) = v;
}
static inline uint32_t r32(volatile uint8_t *base, uint32_t off) {
    return *(volatile uint32_t *)(base + off);
}

/* Publish the emitter's just-ended frame to the control block + ring the doorbell,
 * then spin (bounded) until the fabric mirrors DONE==submit_seq. Returns 1 on the
 * handshake, 0 on timeout. `srcsel` selects DDR3 (0) or SDRAM (1) sources. */
static int submit_and_wait(blt_emitter_t *e, int srcsel) {
    w32(g_ddr, C_CMDCOUNT, (uint32_t)e->cmd_count);
    w32(g_ddr, C_TARGET,   (uint32_t)e->target_buf);
    w32(g_ddr, C_CLEAR,    e->clear_color);
    w32(g_ddr, C_FLAGS,    e->flags);
    w32(g_ddr, C_SRCSEL,   srcsel ? 1u : 0u);
    __sync_synchronize();
    w32(g_ddr, C_SUBMIT,   e->submit_seq);
    /* ~0.5s bound: STAGE of 8 KiB + a 64x64 blit complete in microseconds. */
    for (long i = 0; i < 5000000L; i++) {
        if (r32(g_ddr, C_DONE) == e->submit_seq) return 1;
    }
    return 0;
}

/* Run the full round-trip for one SDRAM offset; print a one-line verdict. */
static void test_offset(blt_emitter_t *e, const uint16_t *pat, uint32_t sdram_off) {
    /* (1) upload the pattern fresh into the DDR3 heap and confirm it landed. */
    blt_heap_reset(e);
    blt_surface_ref_t ref = blt_upload(e, pat, ST_W, ST_H, ST_W * 2);
    if (!ref.valid) { printf("  off=0x%08x  UPLOAD FAILED (heap)\n", sdram_off); return; }
    int ddr_ok = (memcmp((const void *)(g_ddr + OFF_HEAP + ref.off), pat, ST_BYTES) == 0);

    /* (2) STAGE DDR3(ref.off) -> SDRAM(sdram_off). */
    blt_begin_frame(e, /*target=*/0, /*clear=*/0, /*clear_color=*/0);
    blt_stage_to(e, ref.off, sdram_off, ST_BYTES);
    blt_end_frame(e);
    int staged = submit_and_wait(e, /*srcsel=*/1);

    /* (3) clear fb0 + BLIT from SDRAM(sdram_off) -> fb0 at (0,0), C_SRCSEL=1. */
    blt_begin_frame(e, /*target=*/0, /*clear=*/1, /*clear_color=*/0x0000);
    e->sdram_src = 1;
    blt_surface_ref_t sref;
    memset(&sref, 0, sizeof(sref));
    sref.off       = 0;
    sref.sdram_off = sdram_off;          /* C_SRCSEL=1 -> src read base = sdram_off */
    sref.stride    = ST_W * 2;
    sref.w = ST_W; sref.h = ST_H;
    sref.format = BLT_FMT_RGB565;
    sref.valid = 1;
    blt_blit(e, sref, 0, 0, ST_W, ST_H, 0, 0, BLT_BLEND_COPY, 0, 0, 0);
    blt_end_frame(e);
    int blitted = submit_and_wait(e, /*srcsel=*/1);

    /* (4) read fb0 back and compare. */
    const uint16_t *fb = (const uint16_t *)(g_vid + FB0_OFF);
    st_result_t res = st_compare(fb, FB_W);
    double pct = 100.0 * res.matched / ST_PIXELS;

    printf("  off=0x%08x  ddr3=%s stage=%s blit=%s  match=%4d/%d (%.1f%%)  nz=%d",
           sdram_off, ddr_ok ? "ok" : "BAD",
           staged ? "ok" : "TIMEOUT", blitted ? "ok" : "TIMEOUT",
           res.matched, ST_PIXELS, pct, res.nonzero);
    if (res.first_bad)
        printf("  first@(%d,%d) exp=0x%04x got=0x%04x->(%d,%d)",
               res.bx, res.by, res.bexp, res.bgot,
               st_dec_x(res.bgot), st_dec_y(res.bgot));
    printf("\n");
}

/* Demonstrate the suspected #33 failure mode: C_SRCSEL is a GLOBAL per-frame mux,
 * but an UN-STAGED surface's command carries its DDR3-heap offset. Submitted under
 * C_SRCSEL=0 it reads DDR3 (correct); under C_SRCSEL=1 the fabric reads SDRAM at
 * that DDR3 offset (never staged there) -> garbage/black. The renderer sets
 * C_SRCSEL=1 for the WHOLE frame, so any blit of an un-staged source corrupts. */
static void test_mixed_source_mux(blt_emitter_t *e, const uint16_t *pat) {
    blt_heap_reset(e);
    blt_surface_ref_t ref = blt_upload(e, pat, ST_W, ST_H, ST_W * 2);
    if (!ref.valid) { printf("  MIXED: upload failed\n"); return; }
    /* ref.sdram_off == BLT_ALLOC_FAIL (unstaged) -> blt_blit emits src_off=ref.off. */

    /* (a) un-staged source, C_SRCSEL=0 -> reads DDR3 heap -> should be correct. */
    blt_begin_frame(e, 0, 1, 0x0000);
    blt_blit(e, ref, 0, 0, ST_W, ST_H, 0, 0, BLT_BLEND_COPY, 0, 0, 0);
    blt_end_frame(e);
    submit_and_wait(e, /*srcsel=*/0);
    st_result_t d0 = st_compare((const uint16_t *)(g_vid + FB0_OFF), FB_W);

    /* (b) SAME un-staged source, C_SRCSEL=1 -> fabric reads SDRAM[ref.off]. */
    blt_begin_frame(e, 0, 1, 0x0000);
    blt_blit(e, ref, 0, 0, ST_W, ST_H, 0, 0, BLT_BLEND_COPY, 0, 0, 0);
    blt_end_frame(e);
    submit_and_wait(e, /*srcsel=*/1);
    st_result_t d1 = st_compare((const uint16_t *)(g_vid + FB0_OFF), FB_W);

    printf("  unstaged src (off=0x%06x): C_SRCSEL=0 match=%d/%d (%.1f%%)  |  "
           "C_SRCSEL=1 match=%d/%d (%.1f%%) nz=%d\n",
           ref.off, d0.matched, ST_PIXELS, 100.0 * d0.matched / ST_PIXELS,
           d1.matched, ST_PIXELS, 100.0 * d1.matched / ST_PIXELS, d1.nonzero);
    /* The emitter tags a blit F_SRC_SDRAM only for STAGED sources. This ref is
     * un-staged, so under C_SRCSEL=1: a PRE-fix RBF (global mux) reads SDRAM ->
     * garbage; a FIXED RBF (per-command mux) reads DDR3 -> correct. */
    if (d0.matched == ST_PIXELS && d1.matched == ST_PIXELS)
        printf("  => PASS (per-command mux): un-staged source read DDR3 under C_SRCSEL=1\n");
    else if (d0.matched == ST_PIXELS && d1.matched < ST_PIXELS)
        printf("  => BUG PRESENT (pre-#34-fix RBF): global C_SRCSEL=1 corrupts un-staged sources\n");
    else
        printf("  => inconclusive (see numbers above)\n");
}

int main(int argc, char **argv) {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }
    void *pd = mmap(NULL, BLT_DDR_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, BLT_DDR_PHYS);
    void *pv = mmap(NULL, VIDEO_SIZE,   PROT_READ | PROT_WRITE, MAP_SHARED, fd, VIDEO_PHYS);
    if (pd == MAP_FAILED || pv == MAP_FAILED) { perror("mmap"); return 1; }
    g_ddr = (volatile uint8_t *)pd;
    g_vid = (volatile uint8_t *)pv;

    blt_emitter_t em;
    blt_emitter_init(&em, (void *)(g_ddr + OFF_RING), RING_CAP,
                     (void *)(g_ddr + OFF_HEAP), HEAP_CAP);

    uint16_t pat[ST_PIXELS];
    st_fill(pat);

    /* Default sweep crosses every #31-remapped address bit:
     *   1MB(low) | 16MB(atlas base) | 32MB(addr[25]=1) | 48MB | ~63MB(top). */
    uint32_t def[] = { 0x00100000u, 0x01000000u, 0x02000000u, 0x03000000u, 0x03F00000u };
    uint32_t *offs = def;
    int n = (int)(sizeof(def) / sizeof(def[0]));
    uint32_t custom[32];
    if (argc > 1) {
        n = argc - 1; if (n > 32) n = 32;
        for (int i = 0; i < n; i++) custom[i] = (uint32_t)strtoul(argv[i + 1], NULL, 0);
        offs = custom;
    }

    printf("SDRAM round-trip self-test (issue #34) — %dx%d RGB565 pattern, %d bytes/stage\n",
           ST_W, ST_H, ST_BYTES);
    printf("DDR3 heap @0x%08x  ring @0x%08x  fb0 @0x%08x\n",
           BLT_DDR_PHYS + OFF_HEAP, BLT_DDR_PHYS + OFF_RING, VIDEO_PHYS + FB0_OFF);
    for (int i = 0; i < n; i++) test_offset(&em, pat, offs[i]);

    printf("-- mixed-source mux check (global C_SRCSEL vs un-staged source) --\n");
    test_mixed_source_mux(&em, pat);

    printf("done. (a wrong-but-consistent 'got->(x,y)' fingerprints a mis-wired "
           "SDRAM address bit; all-black nz=0 => stage/read never reaches SDRAM)\n");
    return 0;
}
