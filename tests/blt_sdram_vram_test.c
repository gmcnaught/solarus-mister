/* [MiSTer #33] Host test: emitter SDRAM-VRAM allocator + decoupled staging +
 * blit source-select. Pure C, no device. */
#include "blitter_ref.h"
#include "blt_emitter.h"
#include "blt_wire.h"
#include "blt_alloc.h"
#include <stdio.h>
#include <stdint.h>
#include <string.h>

static int failures = 0;
#define CHECK(c,m) do{ if(!(c)){ printf("FAIL: %s (line %d)\n", m, __LINE__); failures++; } }while(0)

static blt_cmd_t ring_read(const blt_emitter_t *e, int n){
    blt_cmd_t c; memset(&c,0,sizeof c); blt_unpack_cmd(e->ring + (size_t)n*BLT_CMD_BYTES, &c); return c;
}

int main(void){
    static uint8_t ring[64*BLT_CMD_BYTES];
    static uint8_t heap[64*1024];
    static uint16_t px[16*16];
    for (int i=0;i<16*16;i++) px[i]=(uint16_t)(0x1000+i);

    blt_emitter_t e;
    blt_emitter_init(&e, ring, sizeof ring, heap, sizeof heap);
    blt_sdram_init(&e, 1u<<20);             /* 1 MiB SDRAM space for the test */
    blt_begin_frame(&e, 0, 0, 0);

    /* upload two surfaces into the DDR3 heap */
    blt_surface_ref_t a = blt_upload(&e, px, 16, 16, 16*2);
    blt_surface_ref_t b = blt_upload(&e, px, 16, 16, 16*2);
    CHECK(a.valid && b.valid, "uploads valid");
    CHECK(a.sdram_off == BLT_ALLOC_FAIL, "fresh upload is unstaged (sdram_off=FAIL)");

    /* stage each to SDRAM: distinct, non-overlapping sdram offsets */
    int rs = blt_stage_surface(&e, &a);
    CHECK(rs == 0, "stage a returns 0");
    int before = e.cmd_count;
    blt_stage_surface(&e, &b);
    CHECK(a.sdram_off != BLT_ALLOC_FAIL && b.sdram_off != BLT_ALLOC_FAIL, "both staged");
    CHECK(a.sdram_off != b.sdram_off, "distinct SDRAM offsets");
    CHECK(b.sdram_off >= a.sdram_off + a.size || a.sdram_off >= b.sdram_off + b.size, "non-overlapping");

    /* the stage command for b: STAGE_DST flag, src_off=b.off (DDR bounce),
     * u32[2]=b.sdram_off, size=b.size */
    blt_cmd_t sc = ring_read(&e, before);
    CHECK(sc.opcode == BLT_OP_STAGE,        "stage cmd opcode");
    CHECK(sc.flags & BLT_F_STAGE_DST,       "stage cmd has STAGE_DST");
    CHECK(sc.src_off == b.off,              "stage cmd src_off = DDR bounce off");
    CHECK(((uint32_t)sc.src_x<<16 | sc.src_stride) == b.sdram_off, "stage cmd u32[2] = sdram off");

    /* with sdram_src on (set by blt_sdram_init), a blit reads from sdram_off */
    int bi = e.cmd_count;
    blt_blit(&e, a, 0,0, 16,16, 5,5, BLT_BLEND_COPY, 0, 255, 0);
    blt_cmd_t bc = ring_read(&e, bi);
    CHECK(bc.opcode == BLT_OP_BLIT,         "blit opcode");
    CHECK(bc.src_off == a.sdram_off,        "blit src_off = SDRAM offset (sdram_src mode)");
    CHECK(bc.src_stride == a.stride,        "blit stride preserved");

    if (failures==0){ printf("ALL PASS\n"); return 0; }
    printf("%d FAILURE(S)\n", failures); return 1;
}
