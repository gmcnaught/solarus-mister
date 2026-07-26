/* ring_dbuf_emitter_test — bank/half cursor alternation + deferred-free.
 * Models the 2-deep pipeline invariants host-side (no fabric). */
#include "../patches/mister/blitter/blt_emitter.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static int fails = 0;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

int main(void) {
    static uint8_t ring0[0x10000], ring1[0x10000], heap[0x40000];
    static uint8_t tl[0x8000], sp[0x6000];
    blt_emitter_t e;
    blt_emitter_init(&e, ring0, sizeof ring0, heap, sizeof heap);
    blt_tile_list_init(&e, tl, sizeof tl);
    blt_sprite_list_init(&e, sp, sizeof sp);

    /* dbuf OFF: cursors at 0, ring is ring0, frees are immediate */
    blt_begin_frame(&e, 0, 0, 0);
    CHECK(e.bank == 0, "off: bank %d exp 0", e.bank);
    CHECK(e.tl_used == 0, "off: tl_used %zu exp 0", e.tl_used);
    CHECK(blt_frame_ring(&e) == ring0, "off: ring ptr");
    uint32_t off0 = blt_alloc(&e.alloc, 256);
    blt_emitter_free_deferred(&e, off0, 256);
    uint32_t off1 = blt_alloc(&e.alloc, 256);
    CHECK(off1 == off0, "off: immediate free -> same block reused");
    blt_emitter_free_deferred(&e, off1, 256);
    blt_end_frame(&e);                       /* seq 0 -> 1 */

    /* dbuf ON: seq parity picks bank + halves */
    blt_emitter_set_dbuf(&e, 1, ring1);
    blt_begin_frame(&e, 0, 0, 0);            /* building seq 2 -> bank 0 */
    CHECK(e.bank == 0, "f2: bank %d exp 0", e.bank);
    CHECK(e.tl_used == 0, "f2: tl_used %zu exp 0", e.tl_used);
    blt_end_frame(&e);                       /* seq -> 2 */
    blt_begin_frame(&e, 0, 0, 0);            /* building seq 3 -> bank 1 */
    CHECK(e.bank == 1, "f3: bank %d exp 1", e.bank);
    /* [ring-dbuf CORRECTION, docs/superpowers/specs/2026-07-26-ring-double-buffer-design.md
     * §4.1] TL_BUF is per-scene (res_arm_ is its only writer and it fully drains the
     * pipeline first), so it is NEVER bank-split -- tl_used stays 0 in EVERY bank,
     * unlike sp_used which genuinely halves. */
    CHECK(e.tl_used == 0, "f3: tl_used %zu exp 0 (TL is full-width, not bank-split)", e.tl_used);
    CHECK(e.sp_used == sizeof sp / 2, "f3: sp_used %zu exp half", e.sp_used);
    CHECK(blt_frame_ring(&e) == ring1, "f3: ring1 ptr");

    /* deferred free: block NOT reusable until drain(done >= tagged seq) */
    uint32_t offA = blt_alloc(&e.alloc, 512);
    blt_emitter_free_deferred(&e, offA, 512);        /* tagged seq 3 */
    uint32_t offB = blt_alloc(&e.alloc, 512);
    CHECK(offB != offA, "deferred: freed block must NOT be reused pre-drain");
    blt_emitter_drain_deferred(&e, 2);               /* done=2 < 3: no-op */
    uint32_t offC = blt_alloc(&e.alloc, 512);
    CHECK(offC != offA, "deferred: done=2 must not release seq-3 block");
    blt_emitter_drain_deferred(&e, 3);               /* releases it */
    uint32_t offD = blt_alloc(&e.alloc, 512);
    CHECK(offD == offA, "deferred: drained block reusable");

    /* [M5] blt_heap_reset must DROP the deferred-free queue with the heap it
     * points into. blt_alloc_reset rebuilds the free list as one whole-heap
     * block, so a surviving entry would later be blt_free()d into an allocator
     * that already owns those bytes -- an overlapping free block. All call sites
     * drain first today; the case that matters is the 1 s spin cap expiring on a
     * wedged fabric, modelled here by simply not draining. */
    uint32_t offE = blt_alloc(&e.alloc, 512);
    blt_emitter_free_deferred(&e, offE, 512);   /* tagged, never drained */
    CHECK(e.dfq_n > 0, "M5 setup: expected a queued deferred free");
    blt_heap_reset(&e);
    CHECK(e.dfq_n == 0, "M5: blt_heap_reset left %d deferred entr(y/ies) queued -- "
                        "they would be freed into a reset allocator", e.dfq_n);
    {   /* and the reset heap must behave like a clean one afterwards */
        uint32_t r1 = blt_alloc(&e.alloc, 512);
        blt_emitter_drain_deferred(&e, 0xFFFFFFFFu);   /* would double-free a survivor */
        uint32_t r2 = blt_alloc(&e.alloc, 512);
        CHECK(r1 != r2, "M5: allocator handed out the same block twice after a "
                        "heap reset + drain (free list corrupted by a survivor)");
    }

    printf(fails ? "ring_dbuf_emitter_test: FAIL (%d)\n" : "ring_dbuf_emitter_test: PASS\n", fails);
    return fails ? 1 : 0;
}
