/* [residency] Host test: permanent vs intermediate SDRAM allocator split.
 * perm is grow-only (never freed); intermediate frees on evict; regions disjoint. */
#include "blitter_ref.h"
#include "blt_emitter.h"
#include "blt_wire.h"
#include "blt_alloc.h"
#include <stdio.h>
#include <stdint.h>
#include <string.h>

static int failures = 0;
#define CHECK(c,m) do{ if(!(c)){ printf("FAIL: %s (line %d)\n", m, __LINE__); failures++; } }while(0)

int main(void){
    static uint8_t  ring[256*BLT_CMD_BYTES];  /* [residency] large ring for 200+ STAGE cmds */
    static uint8_t  heap[256*1024];   /* [residency] large heap so perm exhausts first */
    static uint16_t px[16*16];
    for (int i=0;i<16*16;i++) px[i]=(uint16_t)(0x1000+i);

    blt_emitter_t e;
    blt_emitter_init(&e, ring, sizeof ring, heap, sizeof heap);
    /* perm [0, 64KiB), intermediate [64KiB, 128KiB) — disjoint */
    blt_sdram_regions_init(&e, 0u, 0x10000u, 0x10000u, 0x10000u);
    CHECK(e.sdram_src == 1, "regions_init enables sdram_src");
    blt_begin_frame(&e, 0, 0, 0);

    /* two permanent stages: land in perm range, distinct, non-overlapping */
    blt_surface_ref_t a = blt_upload(&e, px, 16, 16, 16*2);
    blt_surface_ref_t b = blt_upload(&e, px, 16, 16, 16*2);
    CHECK(blt_stage_surface_perm(&e, &a) == 0, "perm stage a ok");
    CHECK(blt_stage_surface_perm(&e, &b) == 0, "perm stage b ok");
    CHECK(a.sdram_off < 0x10000u && b.sdram_off < 0x10000u, "perm offsets in perm range");
    CHECK(a.sdram_off != b.sdram_off, "perm offsets distinct");
    CHECK(e.perm_overflow == 0, "no perm overflow yet");

    /* intermediate stage lands in intermediate range, above perm */
    blt_surface_ref_t c = blt_upload(&e, px, 16, 16, 16*2);
    CHECK(blt_stage_surface(&e, &c) == 0, "intermediate stage ok");
    CHECK(c.sdram_off >= 0x10000u && c.sdram_off < 0x20000u, "intermediate offset in inter range");

    /* intermediate frees and reuses; perm never returns to the intermediate pool */
    uint32_t coff = c.sdram_off;
    blt_sdram_free(&e, &c);
    CHECK(c.sdram_off == BLT_ALLOC_FAIL, "freed intermediate ref reset");
    blt_surface_ref_t d = blt_upload(&e, px, 16, 16, 16*2);
    blt_stage_surface(&e, &d);
    CHECK(d.sdram_off == coff, "intermediate slot reused after free");

    /* perm exhaustion: loud signal via perm_overflow, returns -1, does NOT touch e.overflow */
    e.overflow = 0;
    int rc = 0;
    for (int i=0;i<200 && rc==0;i++){
        blt_surface_ref_t big = blt_upload(&e, px, 16, 16, 16*2); /* 512 B each in perm */
        big.sdram_off = BLT_ALLOC_FAIL;
        rc = blt_stage_surface_perm(&e, &big);
    }
    CHECK(rc == -1, "perm overflow returns -1");
    CHECK(e.perm_overflow == 1, "perm overflow sets perm_overflow flag");
    CHECK(e.overflow == 0, "perm overflow does NOT set bounce overflow flag");

    printf(failures ? "FAILED (%d)\n" : "ok blt_sdram_regions\n", failures);
    return failures ? 1 : 0;
}
