/*
 * ddr_write_bench.c — how fast can the A9 write the blitter DDR window?
 *
 * WHY: every byte the fabric composites is written by the A9 into the 18 MiB
 * window at 0x3B000000 first — the command ring, the ARGB4444 overlay root,
 * the CLUT, GRID_BUF, and every staged atlas pixel. That window is mapped
 * through /dev/mem, and on ARM a /dev/mem mmap of a fabric address is
 * unconditionally Strongly-Ordered: phys_mem_access_prot() (arch/arm/mm/mmu.c)
 * returns pgprot_noncached() whenever pfn_valid(pfn) is false, and only reaches
 * the O_SYNC test when it is true. /proc/iomem on the DE10-Nano shows System
 * RAM ending at 0x1fefffff, so 0x3B000000 always takes the first branch and
 * *no argument to /dev/mem yields write-combining*. SO stores cannot merge:
 * each one is its own bus transaction.
 *
 * This measures the four store shapes this codebase actually uses, so the
 * result maps onto named call sites rather than onto a generic MB/s figure:
 *
 *   overlay memcpy   153,600 B  mister_blitter_renderer.cpp:2232 reupload_in_place()
 *   ring bytewise     32 B/cmd  blt_wire.h:44-46 blt_wr32() — p[0..3] ONE BYTE
 *                               AT A TIME, x8 per blt_pack_cmd(). The most
 *                               SO-hostile pattern in the tree.
 *   ring word         32 B/cmd  the same commands as aligned 32-bit stores.
 *                               Present to SEPARATE two levers: store width is
 *                               fixable without any driver, write-combining is
 *                               not. If bytewise->word already recovers most of
 *                               it, that is the cheaper change.
 *   grid memcpy      1,290,240 B renderer:3940 — per map transition, not per frame
 *   clut bytewise       65,536 B renderer:2024-2028 — volatile byte stores, at preload
 *
 * across three mappings:
 *
 *   cached RAM    upper bound, not a transport — the fabric cannot see it.
 *   /dev/mem      the baseline, and what ships today.
 *   /dev/mem_wc   CANDIDATE. patches/mister/mem_wc/ maps the same physical
 *                 pages Normal Non-Cacheable so the write buffer can merge.
 *
 * SAFETY: every arm writes ONLY into a 4 MiB scratch slice at BLT_HEAP
 * (0x3B100000). That is inside the source heap — never the control block, the
 * command ring, or the doorbell — so this cannot submit work, cannot advance
 * submit_seq, and cannot make the fabric read a torn command. It DOES clobber
 * staged atlas pixels, so a running engine will render garbage until its next
 * re-stage. Kill the engine first:
 *     kill -9 $(pidof solarus-run)
 * The RBF does not need to be loaded; nothing here depends on the fabric.
 *
 * Build:  bash scripts/build_ddr_write_bench.sh
 * Run:    ssh root@<dev> /tmp/ddr_write_bench
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/mman.h>

/* Scratch slice: OFF_HEAP (0x00100000) into the 0x3B000000 blitter window.
 * Page-aligned and far from OFF_TLBUF (0x00F40000) and everything above it. */
#define BLT_PHYS   0x3B000000u
#define SCRATCH    (BLT_PHYS + 0x00100000u)
#define SCRATCH_SZ 0x00400000u            /* 4 MiB */

#define OVERLAY_BYTES (320u * 240u * 2u)  /* 153,600 — one ARGB4444 root */
#define GRID_BYTES    (382u * 282u * 3u * 4u) /* 1,292,904 -> worst-case grid */
#define CLUT_BYTES    (32u * 256u * 8u)   /* 65,536 */
#define CMD_BYTES     32u                 /* one packed blitter command */
#define RING_CMDS     2000u               /* a heavy frame's command count */

/* How much faster than the SO baseline a mapping must measure before this
 * bench will call it write-combining. Well clear of run-to-run noise. */
#define WC_MIN_SPEEDUP 3.0

static double now_s(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC_RAW, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

/* ---- the five store shapes -------------------------------------------- */

static void w_memcpy(void *dst, const void *src, size_t n, unsigned iters)
{
    for (unsigned i = 0; i < iters; i++) memcpy(dst, src, n);
}

/* blt_wire.h blt_wr32(): four separate byte stores, x8 per command. */
static void w_ring_bytewise(void *dst, unsigned cmds, unsigned iters)
{
    volatile uint8_t *p = (volatile uint8_t *)dst;
    for (unsigned i = 0; i < iters; i++)
        for (unsigned c = 0; c < cmds; c++) {
            volatile uint8_t *q = p + (size_t)c * CMD_BYTES;
            for (unsigned w = 0; w < 8; w++) {
                uint32_t v = (uint32_t)(c + w);
                q[w * 4 + 0] = (uint8_t)v;
                q[w * 4 + 1] = (uint8_t)(v >> 8);
                q[w * 4 + 2] = (uint8_t)(v >> 16);
                q[w * 4 + 3] = (uint8_t)(v >> 24);
            }
        }
}

/* The same commands as aligned 32-bit stores. The ring is 32 B-aligned, so
 * this is a legal rewrite of blt_wr32 — it is the no-driver alternative. */
static void w_ring_word(void *dst, unsigned cmds, unsigned iters)
{
    volatile uint32_t *p = (volatile uint32_t *)dst;
    for (unsigned i = 0; i < iters; i++)
        for (unsigned c = 0; c < cmds; c++) {
            volatile uint32_t *q = p + (size_t)c * (CMD_BYTES / 4);
            for (unsigned w = 0; w < 8; w++) q[w] = (uint32_t)(c + w);
        }
}

/* renderer:2024-2028 — CLUT upload, individual volatile byte stores. */
static void w_clut_bytewise(void *dst, size_t n, unsigned iters)
{
    volatile uint8_t *p = (volatile uint8_t *)dst;
    for (unsigned i = 0; i < iters; i++)
        for (size_t b = 0; b < n; b++) p[b] = (uint8_t)b;
}

/* ---- arms -------------------------------------------------------------- */

struct row { double overlay, ring_b, ring_w, grid, clut; };

static void bench(const char *label, void *dst, const uint8_t *src, struct row *out)
{
    double t;
    /* Iteration counts chosen so each arm runs ~0.3-3 s at the SO baseline;
     * the bytewise arms are ~30x slower so they get proportionally fewer. */
    const unsigned IT_OVERLAY = 200, IT_GRID = 40, IT_RING = 20, IT_CLUT = 5;

    t = now_s(); w_memcpy(dst, src, OVERLAY_BYTES, IT_OVERLAY);   t = now_s() - t;
    out->overlay = (double)OVERLAY_BYTES * IT_OVERLAY / (1048576.0 * t);

    t = now_s(); w_ring_bytewise(dst, RING_CMDS, IT_RING);        t = now_s() - t;
    out->ring_b = (double)RING_CMDS * CMD_BYTES * IT_RING / (1048576.0 * t);

    t = now_s(); w_ring_word(dst, RING_CMDS, IT_RING);            t = now_s() - t;
    out->ring_w = (double)RING_CMDS * CMD_BYTES * IT_RING / (1048576.0 * t);

    t = now_s(); w_memcpy(dst, src, GRID_BYTES, IT_GRID);         t = now_s() - t;
    out->grid = (double)GRID_BYTES * IT_GRID / (1048576.0 * t);

    t = now_s(); w_clut_bytewise(dst, CLUT_BYTES, IT_CLUT);       t = now_s() - t;
    out->clut = (double)CLUT_BYTES * IT_CLUT / (1048576.0 * t);

    printf("  %-14s %8.1f %8.1f %8.1f %8.1f %8.1f\n",
           label, out->overlay, out->ring_b, out->ring_w, out->grid, out->clut);
}

static void *map_dev(const char *dev, int *fd_out)
{
    int fd = open(dev, O_RDWR | O_SYNC);
    void *p;
    if (fd < 0) return NULL;
    p = mmap(NULL, SCRATCH_SZ, PROT_READ | PROT_WRITE, MAP_SHARED, fd, SCRATCH);
    if (p == MAP_FAILED) { close(fd); return NULL; }
    *fd_out = fd;
    return p;
}

int main(void)
{
    uint8_t *src, *ram;
    void *so = NULL, *wc = NULL;
    int so_fd = -1, wc_fd = -1;
    struct row r_ram, r_so, r_wc;
    int have_wc;

    if (GRID_BYTES > SCRATCH_SZ) { fprintf(stderr, "scratch too small\n"); return 2; }

    src = malloc(GRID_BYTES);
    ram = malloc(GRID_BYTES);
    if (!src || !ram) { perror("malloc"); return 2; }
    memset(src, 0xA5, GRID_BYTES);

    so = map_dev("/dev/mem", &so_fd);
    if (!so) { perror("mmap /dev/mem"); return 2; }
    wc = map_dev("/dev/mem_wc", &wc_fd);
    have_wc = (wc != NULL);

    printf("ddr_write_bench — A9 stores into the blitter window\n");
    printf("  scratch      0x%08X + %u MiB (inside OFF_HEAP; ctrl/ring untouched)\n",
           SCRATCH, SCRATCH_SZ >> 20);
    printf("  overlay %u B   ring %u cmds x %u B   grid %u B   clut %u B\n\n",
           OVERLAY_BYTES, RING_CMDS, CMD_BYTES, GRID_BYTES, CLUT_BYTES);
    printf("  %-14s %8s %8s %8s %8s %8s   (MB/s)\n",
           "mapping", "overlay", "ring-b", "ring-w", "grid", "clut");
    printf("  ------------------------------------------------------------------\n");

    bench("cached RAM", ram, src, &r_ram);
    bench("/dev/mem", so, src, &r_so);
    if (have_wc) bench("/dev/mem_wc", wc, src, &r_wc);
    else printf("  %-14s  (absent — insmod patches/mister/mem_wc/)\n", "/dev/mem_wc");

    printf("\n");
    printf("  store-width lever (no driver): ring bytewise -> word = %.2fx on /dev/mem\n",
           r_so.ring_w / r_so.ring_b);

    if (have_wc) {
        double sp_overlay = r_wc.overlay / r_so.overlay;
        double sp_ring    = r_wc.ring_w  / r_so.ring_w;
        double sp_grid    = r_wc.grid    / r_so.grid;
        printf("  write-combining lever: overlay %.2fx  ring-w %.2fx  grid %.2fx"
               "  clut %.2fx\n",
               sp_overlay, sp_ring, sp_grid, r_wc.clut / r_so.clut);
        /* A throughput number alone can be faked by a wrong region or a cached
         * alias. Require the bulk arms to actually clear the SO baseline. */
        if (sp_overlay >= WC_MIN_SPEEDUP && sp_grid >= WC_MIN_SPEEDUP)
            printf("\n  VERDICT: /dev/mem_wc is write-combining (bulk arms >= %.1fx).\n",
                   WC_MIN_SPEEDUP);
        else
            printf("\n  VERDICT: /dev/mem_wc did NOT behave as write-combining "
                   "(bulk arms < %.1fx). Check the module is loaded and its\n"
                   "  allowlist covers 0x%08X..0x%08X.\n",
                   WC_MIN_SPEEDUP, SCRATCH, SCRATCH + SCRATCH_SZ);
    }

    munmap(so, SCRATCH_SZ); close(so_fd);
    if (have_wc) { munmap(wc, SCRATCH_SZ); close(wc_fd); }
    free(src); free(ram);
    return 0;
}
