/* blt_alloc — pure-C free-list offset allocator for the blitter DDR source heap.
 *
 * Manages free space within a [base, base+size) byte region as OFFSETS only — it
 * never touches DDR or pixels, so it is host-unit-testable in isolation. Replaces
 * the bump allocator in blt_emitter so individual surface uploads can be freed and
 * reused (issue #14: the bump heap leaked on invalidate/dirty -> transition overflow).
 *
 * Algorithm: free-list, first-fit + coalescing. The allocator tracks only FREE
 * blocks; the caller passes the size back to blt_free (the surface ref carries it),
 * so no allocated-block table is needed. All sizes are rounded up to BLT_ALLOC_ALIGN
 * (8 bytes, for the fabric's qword reads) by BOTH alloc and free so blocks coalesce.
 * GPL-3.0.
 */
#ifndef BLT_ALLOC_H
#define BLT_ALLOC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define BLT_ALLOC_FAIL     0xFFFFFFFFu   /* returned by blt_alloc on out-of-space   */
#define BLT_ALLOC_ALIGN    8u            /* allocation/offset alignment (qword)      */
#define BLT_ALLOC_MAX_FREE 1024          /* max distinct free blocks (fragment cap)  */

typedef struct { uint32_t off, size; } blt_free_block_t;

typedef struct {
    uint32_t base;                          /* region base offset                   */
    uint32_t size;                          /* region total size                    */
    int      n;                             /* number of free blocks                */
    /* [MiSTer #109] cumulative bytes dropped by blt_free when the free-list is
     * saturated (BLT_ALLOC_MAX_FREE distinct fragments). Those bytes are lost
     * until the next blt_alloc_reset. Lifetime tally (NOT cleared by reset) so a
     * caller can observe/log a slow capacity leak under heavy fragmentation. */
    uint32_t leaked_bytes;
    blt_free_block_t fb[BLT_ALLOC_MAX_FREE];/* free blocks, kept sorted by off asc  */
} blt_alloc_t;

/* Initialize: the whole region is one free block. */
void     blt_alloc_init(blt_alloc_t *a, uint32_t base_off, uint32_t size);

/* Allocate `size` bytes (rounded up to BLT_ALLOC_ALIGN). Returns an aligned offset
 * in [base, base+size), or BLT_ALLOC_FAIL if no free block fits (or the free-list is
 * full). First-fit. */
uint32_t blt_alloc(blt_alloc_t *a, uint32_t size);

/* Free a block previously returned by blt_alloc. `size` must be the same value passed
 * to blt_alloc (the caller's surface ref carries it); it is rounded the same way.
 * Inserts the extent into the free-list and coalesces with adjacent free neighbors. */
void     blt_free(blt_alloc_t *a, uint32_t offset, uint32_t size);

/* Reset to a single free block spanning the whole region. */
void     blt_alloc_reset(blt_alloc_t *a);

/* Bytes currently outstanding (region size minus total free). Diagnostics. */
uint32_t blt_alloc_used(const blt_alloc_t *a);

/* [MiSTer #109] Cumulative bytes lost to free-list saturation since init (see
 * leaked_bytes). Nonzero means BLT_ALLOC_MAX_FREE was too small for the observed
 * fragmentation; the region self-heals on the next blt_alloc_reset. Diagnostics. */
uint32_t blt_alloc_leaked(const blt_alloc_t *a);

#ifdef __cplusplus
}
#endif

#endif /* BLT_ALLOC_H */
