/* blt_alloc — free-list, first-fit + coalescing offset allocator. See blt_alloc.h.
 * GPL-3.0. */
#include "blt_alloc.h"

static uint32_t round_up(uint32_t s) {
    return (s + (BLT_ALLOC_ALIGN - 1u)) & ~(BLT_ALLOC_ALIGN - 1u);
}

void blt_alloc_reset(blt_alloc_t *a) {
    if (a->size == 0) { a->n = 0; return; }
    a->n = 1;
    a->fb[0].off = a->base;
    a->fb[0].size = a->size;
}

void blt_alloc_init(blt_alloc_t *a, uint32_t base_off, uint32_t size) {
    a->base = base_off;
    a->size = size;
    a->leaked_bytes = 0;   /* [MiSTer #109] lifetime saturation-drop tally */
    blt_alloc_reset(a);
}

uint32_t blt_alloc(blt_alloc_t *a, uint32_t size) {
    size = round_up(size);
    if (size == 0) size = BLT_ALLOC_ALIGN;
    /* first-fit over the free-list */
    for (int i = 0; i < a->n; i++) {
        if (a->fb[i].size >= size) {
            uint32_t off = a->fb[i].off;
            if (a->fb[i].size == size) {
                for (int j = i; j < a->n - 1; j++) a->fb[j] = a->fb[j + 1];  /* remove */
                a->n--;
            } else {
                a->fb[i].off  += size;   /* shrink from the front */
                a->fb[i].size -= size;
            }
            return off;
        }
    }
    return BLT_ALLOC_FAIL;
}

void blt_free(blt_alloc_t *a, uint32_t offset, uint32_t size) {
    size = round_up(size);
    if (size == 0) return;

    /* insertion point: first free block with off >= offset (i-1 is the left neighbor) */
    int i = 0;
    while (i < a->n && a->fb[i].off < offset) i++;

    /* coalesce with the LEFT neighbor (i-1) if it ends exactly at `offset` */
    if (i > 0 && a->fb[i - 1].off + a->fb[i - 1].size == offset) {
        a->fb[i - 1].size += size;
        /* the grown left block may now also meet the RIGHT neighbor (i) */
        if (i < a->n && a->fb[i - 1].off + a->fb[i - 1].size == a->fb[i].off) {
            a->fb[i - 1].size += a->fb[i].size;
            for (int j = i; j < a->n - 1; j++) a->fb[j] = a->fb[j + 1];   /* remove i */
            a->n--;
        }
        return;
    }

    /* coalesce with the RIGHT neighbor (i) if the freed block ends at its start */
    if (i < a->n && offset + size == a->fb[i].off) {
        a->fb[i].off   = offset;
        a->fb[i].size += size;
        return;
    }

    /* no neighbor: insert a fresh free block at i (keep sorted by off). If the
     * free-list is full (pathological fragmentation), drop it — the block is lost
     * until the next full blt_alloc_reset reclaims it (the emitter's overflow
     * fallback). [MiSTer #109] Tally the dropped bytes so the leak is observable
     * (blt_alloc_leaked) instead of silent; the region self-heals on reset. */
    if (a->n >= BLT_ALLOC_MAX_FREE) { a->leaked_bytes += size; return; }
    for (int j = a->n; j > i; j--) a->fb[j] = a->fb[j - 1];
    a->fb[i].off  = offset;
    a->fb[i].size = size;
    a->n++;
}

uint32_t blt_alloc_used(const blt_alloc_t *a) {
    uint32_t freebytes = 0;
    for (int i = 0; i < a->n; i++) freebytes += a->fb[i].size;
    return a->size - freebytes;
}

uint32_t blt_alloc_leaked(const blt_alloc_t *a) {
    return a->leaked_bytes;   /* [MiSTer #109] cumulative saturation-drop bytes */
}
