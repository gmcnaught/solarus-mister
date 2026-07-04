/*
 *  fabric_fps.c — on-device FABRIC-ALONE frame-rate ceiling probe.
 *
 *  WHAT & WHY
 *  ──────────
 *  Measures the maximum frame rate the FPGA compositor (blitter_top ->
 *  comp_pipeline) can sustain, ISOLATED from the entire Solarus engine / Lua /
 *  SDL stack. The engine's own perf line mixes fabric compute with A9 command
 *  emission, ring-handshake serialisation and 60 Hz pacing, so it cannot answer
 *  "how fast is the fabric itself?". This binary answers exactly that by loading
 *  a tileset once and hitting the fabric directly with a full-screen resident
 *  tile list every frame — real SDRAM source traffic, real command-ring DMA,
 *  real band-RMW compositing — then reading the fabric's OWN per-frame busy-cycle
 *  counter back out of the control block.
 *
 *  THE MEASUREMENT (why it is the true ceiling, not display-locked)
 *  ────────────────────────────────────────────────────────────────
 *  blitter_top publishes `perf_frame_cyc` (clk_sys cycles the fabric spent busy
 *  on a frame) in the HIGH 32 bits of the C_DONE qword. That counter is LATCHED
 *  into C_DONE at the write-back-done state, BEFORE the fabric parks in
 *  S_SNAP_WAIT for the vblank work->scan snapshot (blitter_top.sv). So the
 *  published value is pure COMPOSITING time and excludes the vblank wait — i.e.
 *  it is independent of the 60 Hz display refresh. The fabric-limited fps is
 *  therefore  FABRIC_HZ / perf_frame_cyc, which can exceed 60. The wall-clock
 *  fps we also print is vblank-paced (the snapshot serialises the next submit),
 *  so the gap between the two IS the headroom the display pacing is hiding.
 *  C_STATUS[63:32] carries `perf_pipe_cyc` (the comp_pipeline-busy subset), so we
 *  also report what fraction of fabric-busy time is actual pixel composite.
 *
 *  WORKLOADS (representative full-320x240-frame traffic)
 *  ─────────────────────────────────────────────────────
 *    bg16   COPY  16x16 tiles, whole screen   (~300 tiles — one opaque bg layer)
 *    bg8    COPY   8x8 tiles, whole screen     (~1200 tiles — fine tileset)
 *    ov16   PALPHA 16x16 ARGB4444, whole screen(~300 tiles — a transparent layer)
 *    layer2 bg16 COPY + ov16 PALPHA in one frame (two batches — a composited frame)
 *
 *  Build: scripts/build_fabric_fps.sh (armhf cross via docker).
 *  Run on device (RBF loaded, engine NOT required — kill solarus-run first):
 *    ./fabric_fps                 # default: 240 measured frames, 30 warmup
 *    ./fabric_fps 600 60          # 600 measured frames, 60 warmup
 *
 *  GPL-3.0.
 */
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
#define BLT_DDR_SIZE   0x01000000u      /* 16 MiB: ctrl + ring + heap + tl/frt/cft */
#define OFF_RING       0x00000040u
#define RING_CAP       0x0007FFC0u      /* ring spans 0x40..0x80000 */
#define OFF_HEAP       0x00080000u
#define OFF_BGCACHE    0x00F00000u      /* heap must stop below here */
#define OFF_TLBUF      0x00F40000u      /* fabric TL_BUF_QW base (resident entries) */
#define TL_BUF_BYTES   0x00080000u      /* 512 KiB */
#define OFF_FRTBUF     0x00FC0000u      /* fabric FRT_BUF_QW base */
#define OFF_CFTBUF     0x00FC2000u      /* fabric CFT_BUF_QW base */
#define HEAP_CAP       (OFF_BGCACHE - OFF_HEAP)   /* keep clear of bg/tl/frt regions */

#define SDRAM_ATLAS_BASE 0x01000000u    /* SDRAM source-atlas region base (bytes) */
#define SDRAM_CAP        0x04000000u    /* 64 MiB single AS4C32M16 */

#define VIDEO_PHYS     0x3A000000u
#define VIDEO_SIZE     0x00100000u
#define FB0_OFF        0x00000040u      /* buf0 pixels @ 0x3A000040 */
#define FB_W           320
#define FB_H           240

/* control-block byte offsets (qword-spaced; low 32 = field, high 32 = perf) */
#define C_SUBMIT   0x00u
#define C_CMDCOUNT 0x08u
#define C_TARGET   0x10u
#define C_CLEAR    0x18u
#define C_FLAGS    0x20u
#define C_DONE     0x28u                /* low32=done_seq ; high32=perf_frame_cyc */
#define C_STATUS   0x30u                /* low32=status   ; high32=perf_pipe_cyc  */
#define C_SRCSEL   0x38u                /* bit0 dead; bits[15:8]=f2h write-throttle */

#define FABRIC_HZ  98.4375e6            /* clk_sys (PLL outclk_3) — see Solarus.sv */
#define THROTTLE   32u                  /* f2h write-throttle cycles (renderer default) */

/* Source atlas geometry. One shared atlas holds NP distinct tiles; each resident
 * entry's pattern_id resolves through FRT to one atlas sub-rect. */
#define ATLAS_W    256
#define ATLAS_H    128
#define MAX_PAT    64                   /* distinct patterns we cycle across the grid */

static volatile uint8_t *g_ddr;   /* 0x3B mapping (ctrl/ring/heap/tl/frt/cft) */
static volatile uint8_t *g_vid;   /* 0x3A mapping (framebuffers)              */

static inline void     w32(volatile uint8_t *b, uint32_t o, uint32_t v){ *(volatile uint32_t*)(b+o)=v; }
static inline uint32_t r32(volatile uint8_t *b, uint32_t o){ return *(volatile uint32_t*)(b+o); }

/* Publish the emitter's just-ended frame + ring the doorbell, spin (bounded) for
 * the fabric to mirror DONE==submit_seq. Returns 1 on the handshake, 0 on timeout. */
static int submit_and_wait(blt_emitter_t *e) {
    w32(g_ddr, C_CMDCOUNT, (uint32_t)e->cmd_count);
    w32(g_ddr, C_TARGET,   (uint32_t)e->target_buf);
    w32(g_ddr, C_CLEAR,    e->clear_color);
    w32(g_ddr, C_FLAGS,    e->flags);
    w32(g_ddr, C_SRCSEL,   1u | (THROTTLE << 8));   /* source always SDRAM; set throttle */
    __sync_synchronize();
    w32(g_ddr, C_SUBMIT,   e->submit_seq);
    for (long i = 0; i < 20000000L; i++) {          /* ~a few 100 ms bound */
        if (r32(g_ddr, C_DONE) == e->submit_seq) return 1;
    }
    return 0;
}

/* distinct-per-tile RGB565 source content (position + tile encoded). */
static uint16_t px_rgb565(int x, int y) {
    return (uint16_t)(((x & 0x1F) << 11) | ((y & 0x3F) << 5) | ((x ^ y) & 0x1F));
}
/* ARGB4444 content with a mix of A4==0 (skip) and A4!=0 (blend) pixels. */
static uint16_t px_argb4444(int x, int y) {
    uint16_t a = (uint16_t)((x + y) & 0xF);         /* 0..15 -> some fully transparent */
    return (uint16_t)((a << 12) | (((x & 0xF)) << 8) | (((y & 0xF)) << 4) | ((x ^ y) & 0xF));
}

/* distinct patterns available for tile size T (grid-packed into the atlas). */
static int pat_count(int T) {
    int cols = ATLAS_W / T, rows = ATLAS_H / T, n = cols * rows;
    return n < MAX_PAT ? n : MAX_PAT;
}

/* Write the frame-rect table (FRT[pid*MAXF+0] = one atlas sub-rect per pattern)
 * and zero the current-frame table (all patterns on frame 0). Byte layout matches
 * res_arm_() in mister_blitter_renderer.cpp / the fabric FRT/CFT BRAM upload. */
static void build_frt(int T) {
    int np = pat_count(T), cols = ATLAS_W / T;
    /* zero the whole FRT + CFT spans first */
    for (uint32_t o = 0; o < (uint32_t)BLT_MAXP * BLT_MAXF * 8u; o += 4) w32(g_ddr, OFF_FRTBUF + o, 0);
    for (uint32_t o = 0; o < (uint32_t)BLT_MAXP * 2u;            o += 4) w32(g_ddr, OFF_CFTBUF + o, 0);
    for (int s = 0; s < np; s++) {
        uint16_t sx = (uint16_t)((s % cols) * T), sy = (uint16_t)((s / cols) * T);
        uint16_t w = (uint16_t)T, h = (uint16_t)T;
        volatile uint8_t *p = g_ddr + OFF_FRTBUF + (uint32_t)(s * BLT_MAXF + 0) * 8u;
        p[0]=(uint8_t)sx; p[1]=(uint8_t)(sx>>8); p[2]=(uint8_t)sy; p[3]=(uint8_t)(sy>>8);
        p[4]=(uint8_t)w;  p[5]=(uint8_t)(w>>8);  p[6]=(uint8_t)h;  p[7]=(uint8_t)(h>>8);
    }
}

/* Write N 8-byte resident entries tiling the whole 320x240 screen with size-T tiles
 * into TL_BUF at byte offset `eoff`. pattern_id cycles across the atlas so source
 * reads are spread (realistic cache traffic). Returns N. */
static int build_entries(int T, uint32_t eoff) {
    int np = pat_count(T);
    int cols = (FB_W + T - 1) / T, rows = (FB_H + T - 1) / T;
    int n = 0;
    for (int r = 0; r < rows; r++) for (int c = 0; c < cols; c++) {
        uint16_t pid = (uint16_t)(n % np);
        int16_t  dx  = (int16_t)(c * T), dy = (int16_t)(r * T);
        volatile uint8_t *p = g_ddr + OFF_TLBUF + eoff + (uint32_t)n * 8u;
        p[0]=(uint8_t)pid; p[1]=(uint8_t)(pid>>8);
        p[2]=(uint8_t)dx;  p[3]=(uint8_t)((uint16_t)dx>>8);
        p[4]=(uint8_t)dy;  p[5]=(uint8_t)((uint16_t)dy>>8);
        p[6]=0; p[7]=0;
        n++;
    }
    return n;
}

static long long ns_now(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (long long)t.tv_sec * 1000000000LL + t.tv_nsec;
}

/* Run one workload: `layers` (1 or 2) tile-list batches per frame. Returns 0 ok. */
static int run_workload(blt_emitter_t *e, const char *name,
                        blt_surface_ref_t bg, blt_surface_ref_t ov, int layers,
                        int T, uint8_t blend0, uint8_t blend1,
                        int meas_frames, int warm_frames) {
    build_frt(T);
    int N = build_entries(T, 0);

    long long sum_fab = 0, sum_pipe = 0;
    uint32_t min_fab = 0xFFFFFFFFu, max_fab = 0;
    int frt_uploaded = 0;
    long long wall0 = 0;

    for (int f = 0; f < warm_frames + meas_frames; f++) {
        if (f == warm_frames) wall0 = ns_now();       /* start wall timer after warmup */

        e->sdram_src = 1;                              /* tile-list reads atlas from SDRAM */
        blt_begin_frame(e, /*target=*/0, /*clear=*/1, /*clear_color=*/0x0000);
        if (!frt_uploaded) { blt_frt_upload(e, (uint32_t)BLT_MAXP * BLT_MAXF); frt_uploaded = 1; }
        blt_tile_list_res(e, bg, blend0, /*key=*/0, /*alpha=*/0, /*flags=*/0,
                          /*entry_off=*/0, N, /*bias_x=*/0, /*bias_y=*/0);
        if (layers == 2)
            blt_tile_list_res(e, ov, blend1, 0, 0, 0, 0, N, /*bias=*/2, 2);
        blt_end_frame(e);

        if (!submit_and_wait(e)) {
            printf("  %-7s TIMEOUT at frame %d (fabric wedged?)\n", name, f);
            return 1;
        }
        if (f >= warm_frames) {
            uint32_t fab = r32(g_ddr, C_DONE + 4), pipe = r32(g_ddr, C_STATUS + 4);
            sum_fab += fab; sum_pipe += pipe;
            if (fab < min_fab) min_fab = fab;
            if (fab > max_fab) max_fab = fab;
        }
    }
    long long wall_ns = ns_now() - wall0;

    double avg_fab  = (double)sum_fab  / meas_frames;
    double avg_pipe = (double)sum_pipe / meas_frames;
    double fab_fps  = FABRIC_HZ / avg_fab;
    double wall_fps = meas_frames / ((double)wall_ns / 1e9);
    double comp_pct = avg_fab > 0 ? 100.0 * avg_pipe / avg_fab : 0.0;
    double cyc_px   = avg_fab / (double)(FB_W * FB_H) / layers;

    printf("  %-7s tiles=%4d x%d  fab=%8.0f cyc/fr  %6.2f cyc/scrpx  "
           "comp=%4.1f%%  | FABRIC %6.1f fps  (wall %5.1f fps)  min/max=%u/%u\n",
           name, N, layers, avg_fab, cyc_px, comp_pct, fab_fps, wall_fps, min_fab, max_fab);
    return 0;
}

int main(int argc, char **argv) {
    int meas = (argc > 1) ? atoi(argv[1]) : 240;
    int warm = (argc > 2) ? atoi(argv[2]) : 30;
    if (meas < 1) meas = 1;

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
    blt_tile_list_init(&em, (void *)(g_ddr + OFF_TLBUF), TL_BUF_BYTES);
    blt_sdram_init(&em, SDRAM_ATLAS_BASE, SDRAM_CAP - SDRAM_ATLAS_BASE);

    /* Build the two source atlases in the DDR heap and stage them into SDRAM once
     * (the fabric reads all sources from SDRAM — C_SRCSEL=1). */
    static uint16_t atlas_rgb[ATLAS_W * ATLAS_H];
    static uint16_t atlas_pa [ATLAS_W * ATLAS_H];
    for (int y = 0; y < ATLAS_H; y++) for (int x = 0; x < ATLAS_W; x++) {
        atlas_rgb[y * ATLAS_W + x] = px_rgb565(x, y);
        atlas_pa [y * ATLAS_W + x] = px_argb4444(x, y);
    }
    blt_surface_ref_t bg = blt_upload         (&em, atlas_rgb, ATLAS_W, ATLAS_H, ATLAS_W * 2);
    blt_surface_ref_t ov = blt_upload_argb4444(&em, atlas_pa,  ATLAS_W, ATLAS_H, ATLAS_W * 2);
    if (!bg.valid || !ov.valid) { printf("atlas upload failed (heap)\n"); return 1; }

    /* stage both DDR3->SDRAM (one STAGE frame each). */
    blt_begin_frame(&em, 0, 0, 0); blt_stage_surface(&em, &bg); blt_end_frame(&em);
    if (!submit_and_wait(&em)) { printf("stage bg TIMEOUT\n"); return 1; }
    blt_begin_frame(&em, 0, 0, 0); blt_stage_surface(&em, &ov); blt_end_frame(&em);
    if (!submit_and_wait(&em)) { printf("stage ov TIMEOUT\n"); return 1; }

    printf("fabric-alone fps probe — clk_sys=%.4f MHz, %d measured frames (+%d warmup)\n",
           FABRIC_HZ / 1e6, meas, warm);
    printf("60fps budget=%.0f cyc/frame, 30fps=%.0f cyc/frame; source=SDRAM, throttle=%u\n",
           FABRIC_HZ / 60.0, FABRIC_HZ / 30.0, THROTTLE);
    printf("FABRIC fps = clk_sys / fabric-busy-cyc (excludes vblank wait); wall fps is vblank-paced.\n");

    int bad = 0;
    bad |= run_workload(&em, "bg16",   bg, ov, 1, 16, BLT_BLEND_COPY,   0,                meas, warm);
    bad |= run_workload(&em, "bg8",    bg, ov, 1,  8, BLT_BLEND_COPY,   0,                meas, warm);
    bad |= run_workload(&em, "ov16",   ov, ov, 1, 16, BLT_BLEND_PALPHA, 0,                meas, warm);
    bad |= run_workload(&em, "layer2", bg, ov, 2, 16, BLT_BLEND_COPY,   BLT_BLEND_PALPHA, meas, warm);

    /* liveness sanity: confirm the fabric actually composited (fb0 not all-black). */
    const uint16_t *fb = (const uint16_t *)(g_vid + FB0_OFF);
    int nz = 0; for (int i = 0; i < FB_W * FB_H; i++) if (fb[i]) nz++;
    printf("fb0 nonzero=%d/%d (%.1f%%) — %s\n", nz, FB_W * FB_H,
           100.0 * nz / (FB_W * FB_H), nz > 0 ? "fabric composited OK" : "ALL BLACK (check RBF/stage)");

    return bad ? 1 : 0;
}
