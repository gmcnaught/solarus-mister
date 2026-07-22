#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "grid_build.h"     /* blt_grid_tile_t */
#include "grid_decompose.h" /* blt_grid_decompose */

static int max_sub(const int *s, size_t n){int m=0;for(size_t i=0;i<n;i++)if(s[i]>m)m=s[i];return m;}

int main(void){
  uint8_t occ[64];              /* 8x8 grid scratch */
  int sub[8];

  /* Case A: two tiles sharing cell (0,0) -> distinct sub-layers, later higher. */
  blt_grid_tile_t a[2] = { {1,0,0,1,1}, {2,0,0,1,1} };   /* both cover cell (0,0) */
  int K = blt_grid_decompose(a, 2, 8, 8, occ, sub, 8);
  assert(K == 2);
  assert(sub[0] == 0 && sub[1] == 1);                    /* painter's order preserved */

  /* Case B: disjoint tiles share sub-layer 0 (K=1). */
  blt_grid_tile_t b[2] = { {1,0,0,1,1}, {2,3,3,1,1} };
  K = blt_grid_decompose(b, 2, 8, 8, occ, sub, 8);
  assert(K == 1 && sub[0]==0 && sub[1]==0);

  /* Case C: 3-deep stack at one cell -> K=3, strictly increasing. */
  blt_grid_tile_t c[3] = { {1,0,0,2,2}, {2,0,0,2,2}, {3,0,0,2,2} };
  K = blt_grid_decompose(c, 3, 8, 8, occ, sub, 8);
  assert(K == 3 && sub[0]==0 && sub[1]==1 && sub[2]==2);

  /* Case D: K over max_k -> -1 (bucket will replay). */
  K = blt_grid_decompose(c, 3, 8, 8, occ, sub, /*max_k=*/2);
  assert(K == -1);

  /* Case E: same-sublayer tiles never overlap (invariant across a mixed set). */
  blt_grid_tile_t e[4] = { {1,0,0,2,1}, {2,2,0,2,1}, {3,1,0,2,1}, {4,5,5,1,1} };
  K = blt_grid_decompose(e, 4, 8, 8, occ, sub, 8);
  (void)max_sub;
  assert(K >= 1);
  /* tile 2 (cells x=1..2) overlaps tile 0 (x=0..1) at x=1 and tile 1 (x=2..3) at x=2,
     both earlier -> must be strictly above both. */
  assert(sub[2] > sub[0] && sub[2] > sub[1]);

  printf("gridov_decompose: OK\n");
  return 0;
}
