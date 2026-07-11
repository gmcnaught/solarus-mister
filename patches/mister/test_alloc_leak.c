/* blt_alloc free-list-saturation leak-accounting test (issue #109, part 3).
 * Pure C, host-only, no device.
 *
 * blt_free() drops a freed block when the free-list is already at
 * BLT_ALLOC_MAX_FREE distinct fragments (pathological fragmentation): the bytes
 * are lost until the next blt_alloc_reset. Before #109 that drop was silent.
 * Now blt_free tallies the dropped bytes in a->leaked_bytes (accessor
 * blt_alloc_leaked), so a slow capacity leak is observable instead of invisible.
 *
 * This test forces exactly-saturating fragmentation and asserts:
 *   - leaked stays 0 up to and including the MAX_FREE-th fragment,
 *   - the (MAX_FREE+1)-th non-coalescing free is dropped and tallied,
 *   - a COALESCING free while saturated does NOT leak (n doesn't grow),
 *   - blt_alloc_reset keeps the lifetime tally, blt_alloc_init zeroes it.
 *
 * Build/run:  see patches/mister/build_test_alloc_leak.sh
 */
#include "blitter/blt_alloc.h"
#include <stdio.h>

static int g_fail = 0;
#define CHECK(cond, ...) do { if (!(cond)) {                    \
  fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);          \
  fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); g_fail++; } } while (0)

int main(void) {
  /* 2*MAX_FREE + 2 blocks of ALIGN bytes, filling the whole region so there is
   * no leftover free tail (which would itself be a fragment). */
  const int      NBLK = 2 * BLT_ALLOC_MAX_FREE + 2;
  const uint32_t A    = BLT_ALLOC_ALIGN;
  const uint32_t REGION = (uint32_t)NBLK * A;

  blt_alloc_t a;
  blt_alloc_init(&a, 0u, REGION);
  CHECK(blt_alloc_leaked(&a) == 0, "init zeroes leaked");

  /* Allocate every block; offsets come out sequential (0, A, 2A, ...). */
  for (int i = 0; i < NBLK; i++) {
    uint32_t off = blt_alloc(&a, A);
    CHECK(off == (uint32_t)i * A, "alloc %d sequential (got %u)", i, off);
  }
  CHECK(a.n == 0, "fully allocated -> no free blocks");

  /* Free every OTHER block (offsets 0, 2A, 4A, ...): each freed block keeps
   * allocated neighbors on both sides, so it forms an isolated fragment that
   * cannot coalesce. Free exactly MAX_FREE of them -> free-list is now full. */
  for (int k = 0; k < BLT_ALLOC_MAX_FREE; k++) {
    blt_free(&a, (uint32_t)(2 * k) * A, A);
    CHECK(a.n == k + 1, "isolated free grows the list (k=%d n=%d)", k, a.n);
  }
  CHECK(a.n == BLT_ALLOC_MAX_FREE, "free-list saturated");
  CHECK(blt_alloc_leaked(&a) == 0, "no leak up to saturation");

  /* One more isolated free (offset 2*MAX_FREE*A, still allocated neighbors):
   * the list is full -> dropped -> tallied. */
  blt_free(&a, (uint32_t)(2 * BLT_ALLOC_MAX_FREE) * A, A);
  CHECK(a.n == BLT_ALLOC_MAX_FREE, "saturated: list did not grow");
  CHECK(blt_alloc_leaked(&a) == A, "the dropped block's bytes were tallied");

  /* A COALESCING free while saturated must NOT leak: freeing offset A (block 1)
   * merges with the freed fragments at 0 and 2A, shrinking n -- no new slot
   * needed. */
  blt_free(&a, A, A);
  CHECK(a.n < BLT_ALLOC_MAX_FREE, "coalescing free shrank the list");
  CHECK(blt_alloc_leaked(&a) == A, "coalescing free did not add to the leak");

  /* Lifetime semantics: reset reclaims space but keeps the tally; init zeroes. */
  blt_alloc_reset(&a);
  CHECK(blt_alloc_leaked(&a) == A, "reset keeps the lifetime leak tally");
  blt_alloc_init(&a, 0u, REGION);
  CHECK(blt_alloc_leaked(&a) == 0, "re-init zeroes the tally");

  if (g_fail == 0) {
    printf("test_alloc_leak: OK (MAX_FREE=%d, saturation drop tallied)\n",
           BLT_ALLOC_MAX_FREE);
  } else {
    fprintf(stderr, "test_alloc_leak: %d FAILURE(S)\n", g_fail);
  }
  return g_fail ? 1 : 0;
}
