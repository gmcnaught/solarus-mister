/* blend_layer_test — pure predicate + content-hash for the blend-overlay
 * fabric layer. Build: see tests/run_tests.sh. */
#include "mister_blend_layer.h"
#include <stdio.h>
#include <string.h>

int main(void){
  int fails=0;
  const int W=320,H=240;
  /* Solarus BlendMode enum (NOT BLT_BLEND_*): NONE=0, BLEND=1, ADD=2, MULTIPLY=3 */
  const int NONE=0, BLEND=1, ADD=2, MULTIPLY=3;

  /* Armed + full-screen + BLEND (the real dialog/menu blend mode) at opacity 216 -> capture */
  if (!mister_blend_layer_is_capture(1,1, W,H, W,H, BLEND,216)){ printf("FAIL: dialog not captured\n"); fails++; }
  /* Not armed -> never capture (deterministic gate) */
  if ( mister_blend_layer_is_capture(0,1, W,H, W,H, BLEND,216)){ printf("FAIL: captured while disarmed\n"); fails++; }
  /* dst not root -> no capture */
  if ( mister_blend_layer_is_capture(1,0, W,H, W,H, BLEND,216)){ printf("FAIL: captured non-root\n"); fails++; }
  /* sub-screen source (a HUD blit) -> no capture */
  if ( mister_blend_layer_is_capture(1,1, 64,16, W,H, BLEND,255)){ printf("FAIL: captured HUD sub-blit\n"); fails++; }
  /* full-screen opaque NONE -> no capture (that is a promote, handled elsewhere) */
  if ( mister_blend_layer_is_capture(1,1, W,H, W,H, NONE,255)){ printf("FAIL: captured opaque promote\n"); fails++; }
  /* full-screen ADD, armed, any opacity -> NOT captured (not source-over) */
  if ( mister_blend_layer_is_capture(1,1, W,H, W,H, ADD,128)){ printf("FAIL: captured full-screen ADD\n"); fails++; }
  /* full-screen MULTIPLY, armed, any opacity -> NOT captured (not source-over) */
  if ( mister_blend_layer_is_capture(1,1, W,H, W,H, MULTIPLY,128)){ printf("FAIL: captured full-screen MULTIPLY\n"); fails++; }

  /* hash: identical buffers match, one-byte change differs */
  unsigned char a[128], b[128];
  memset(a,0xAB,sizeof a); memcpy(b,a,sizeof b);
  if (mister_blend_layer_hash(a,sizeof a)!=mister_blend_layer_hash(b,sizeof b)){ printf("FAIL: equal buffers hash differ\n"); fails++; }
  b[77]^=0x01;
  if (mister_blend_layer_hash(a,sizeof a)==mister_blend_layer_hash(b,sizeof b)){ printf("FAIL: changed buffer hash equal\n"); fails++; }

  /* --- ordering + overflow(escape) model --- */
  {
    struct Draw { int full; int blend; int op; } seq[] = {
      {0,BLEND,255}, /* HUD sub-blit  -> skip */
      {1,BLEND,216}, /* dialog        -> capture[0] */
      {1,BLEND,200}, /* menu          -> capture[1] */
    };
    int cap_order[MISTER_BLEND_LAYER_MAX]; int n=0;
    for (unsigned i=0;i<sizeof seq/sizeof seq[0];i++){
      int full=seq[i].full;
      int c = mister_blend_layer_is_capture(1,1, full?320:64, full?240:16, 320,240, seq[i].blend, seq[i].op);
      if (c && n<MISTER_BLEND_LAYER_MAX) cap_order[n++]=(int)i;
    }
    if (n!=2 || cap_order[0]!=1 || cap_order[1]!=2){ printf("FAIL: capture order wrong (n=%d)\n",n); fails++; }

    /* overflow -> escape */
    int captured=0, escaped=0;
    for (int i=0;i<MISTER_BLEND_LAYER_MAX+1;i++){
      int c = mister_blend_layer_is_capture(1,1, 320,240, 320,240, BLEND, 216);
      if (c){ if (captured<MISTER_BLEND_LAYER_MAX) captured++; else escaped++; }
    }
    if (captured!=MISTER_BLEND_LAYER_MAX || escaped!=1){ printf("FAIL: overflow escape wrong (cap=%d esc=%d)\n",captured,escaped); fails++; }
  }

  if (fails){ printf("blend_layer_test: %d FAIL\n", fails); return 1; }
  printf("blend_layer_test: OK\n"); return 0;
}
