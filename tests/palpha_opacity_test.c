/* palpha_opacity_test — PALPHA must honor the command's global opacity:
 * effective per-pixel alpha = div255_round(pa_a8 * cmd.alpha).
 * Build: see tests/run_tests.sh. */
#include "blitter_ref.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static unsigned d255(unsigned t){ unsigned m=t+128u; return (m+(m>>8))>>8; }

/* reference const-alpha channel blend at RGB565 widths */
static uint16_t blend565(uint16_t s, uint16_t d, unsigned a){
  unsigned na=255u-a;
  unsigned sr=(s>>11)&0x1F, sg=(s>>5)&0x3F, sb=s&0x1F;
  unsigned dr=(d>>11)&0x1F, dg=(d>>5)&0x3F, db=d&0x1F;
  unsigned rr=d255(sr*a+dr*na), rg=d255(sg*a+dg*na), rb=d255(sb*a+db*na);
  return (uint16_t)((rr<<11)|(rg<<5)|rb);
}

/* pack ARGB4444 {A4,R4,G4,B4} */
static uint16_t argb4444(unsigned a4,unsigned r4,unsigned g4,unsigned b4){
  return (uint16_t)((a4<<12)|(r4<<8)|(g4<<4)|b4);
}

int main(void){
  int fails=0;
  /* Source heap: one ARGB4444 pixel, fully opaque (A4=15), color R4=15,G4=0,B4=0. */
  uint16_t src_px = argb4444(15,15,0,0);
  blt_surface_heap_t heap; memset(&heap,0,sizeof heap);
  heap.base=(uint8_t*)&src_px; heap.size=sizeof src_px;

  uint16_t fb[1];
  const uint16_t DST = 0x8410; /* mid grey */

  /* expanded opaque source in RGB565: R4=15 -> R5 = (15<<1)|(15>>3)=31; G,B=0 */
  uint16_t src565 = (uint16_t)((31u<<11)|(0u<<5)|0u);

  /* Case A: alpha=128, A4=15 -> effective alpha 128 */
  blt_cmd_t c; memset(&c,0,sizeof c);
  c.opcode=BLT_OP_BLIT; c.blend_mode=BLT_BLEND_PALPHA; c.format=BLT_FMT_ARGB4444;
  c.src_off=0; c.src_stride=2; c.src_x=0; c.src_y=0; c.w=1; c.h=1;
  c.dst_x=0; c.dst_y=0; c.alpha=128;
  fb[0]=DST; blt_execute(fb,&heap,&c,1);
  uint16_t expA = blend565(src565, DST, 128);
  if (fb[0]!=expA){ printf("FAIL A: got %04x want %04x\n", fb[0], expA); fails++; }

  /* Case B (regression): alpha=255 -> opaque source-over (dest = src) */
  c.alpha=255; fb[0]=DST; blt_execute(fb,&heap,&c,1);
  if (fb[0]!=src565){ printf("FAIL B: got %04x want %04x\n", fb[0], src565); fails++; }

  if (fails){ printf("palpha_opacity_test: %d FAIL\n", fails); return 1; }
  printf("palpha_opacity_test: OK\n"); return 0;
}
