/* ring_dbuf_pipeline_test — host-side MODEL of the 2-deep ring/TL/SP pipeline that
 * HW validation will later probe on real silicon. Drives 6 frames with dbuf_en=1
 * through a fake "lagging fabric" (an array-and-counter stand-in for the DDR
 * consumer, always exactly one frame behind the A9 producer) and asserts the three
 * invariants the whole lever depends on:
 *
 *   (a) bank isolation   -- the bank being WRITTEN this frame must never be the
 *                            bank the lagging fabric is still READING.
 *   (b) half containment -- TL/SP cursors must stay inside their bank's HALF of
 *                            TL_BUF/SP_BUF; overflow must trip at the half cap
 *                            (not the full cap), with `dropped` accounting intact.
 *   (c) deferred-free safety -- a heap extent freed while its frame is still
 *                            in flight must not be handed back to a new
 *                            allocation until the (simulated) fabric has
 *                            actually drained that frame.
 *
 * Same CHECK/main harness shape as tests/ring_dbuf_emitter_test.c (Task 2). This
 * file is written AFTER blt_emitter's dbuf implementation already exists, so a
 * clean PASS on first run is expected -- the mutation evidence for each CHECK is
 * recorded in docs/.superpowers/sdd/rdb-task-6-report.md (each invariant's CHECK
 * was confirmed live by temporarily perturbing blt_emitter.c and observing the
 * expected FAIL, then reverting).
 */
#include "../patches/mister/blitter/blt_emitter.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static int fails = 0;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

/* [b, TL half] No bounds-checked TL entry-writer exists yet in blt_emitter.c -- the
 * renderer currently owns tl_used/tl_cap itself and hard-fails on overflow (see
 * MisterBlitterRenderer::res_arm_ in mister_blitter_renderer.cpp, which compares
 * against the FULL tl_cap, not a per-frame half). tl_frame_cap is exported by the
 * emitter specifically to "backstop future bounds-checking" (its doc comment in
 * blt_emitter.h) once a dbuf-aware TL writer is wired. This is that future check,
 * modeled here against the SAME production field blt_begin_frame already computes
 * -- so a regression in the half-cap math is caught even before a real writer
 * exists. blt_tile_entry_res_t is 8 bytes (blitter_ref.h).
 */
static int tl_push_entries(blt_emitter_t *e, int n)
{
    size_t need = (size_t)n * 8u;
    if (e->tl_used + need > e->tl_frame_cap) return 0;
    e->tl_used += need;
    return 1;
}

int main(void)
{
    static uint8_t ring0[0x10000], ring1[0x10000], heap[0x40000];
    static uint8_t tl[0x1000];   /* 4096 B -> half 2048 B -> 256 8-byte entries/frame */
    static uint8_t sp[0x1800];   /* 6144 B -> half 3072 B -> 128 24-byte entries/frame */
    blt_emitter_t e;
    blt_emitter_init(&e, ring0, sizeof ring0, heap, sizeof heap);
    blt_tile_list_init(&e, tl, sizeof tl);
    blt_sprite_list_init(&e, sp, sizeof sp);
    blt_emitter_set_dbuf(&e, 1, ring1);   /* armed for the whole drive */

    blt_sprite_run_key_t key;
    memset(&key, 0, sizeof key);
    key.src_stride = 64; key.format = 0; key.blend = 0; key.alpha = 255;
    blt_sprite_entry_t se;
    memset(&se, 0, sizeof se);

    int prev_bank = -1;     /* bank the fake fabric is (about to be, or currently)
                             * reading; -1 = fabric idle, nothing submitted yet */
    uint32_t hold = 0;      /* the tracked heap extent for the deferred-free scenario */
    uint32_t probeB = 0, probeC = 0;

    for (int n = 1; n <= 6; n++) {
        blt_begin_frame(&e, 0, 0, 0);

        /* (a) bank isolation: fabric is still compositing frame n-1 off bank
         * prev_bank while we write frame n's bank -- they must differ. Skipped
         * for n==1 since the fabric hasn't been handed anything yet. */
        if (n > 1)
            CHECK(e.bank != prev_bank,
                  "frame %d: bank isolation violated -- writing bank %d while "
                  "lagging fabric still reads bank %d", n, e.bank, prev_bank);

        /* (b) half containment -- SP, via the REAL bound-checked sprite channel. */
        size_t sp_avail = e.sp_frame_cap - e.sp_used;
        CHECK(sp_avail == sizeof(sp) / 2,
              "frame %d: sp per-frame budget %zu bytes, exp half %zu",
              n, sp_avail, sizeof(sp) / 2);

        blt_sprite_channel_t ch;
        blt_sprite_channel_init(&ch, &e, BLT_SPRITE_CHANNEL_MAX);
        int sp_pushed = 0;
        while (blt_sprite_channel_push(&ch, &key, &se)) sp_pushed++;
        size_t sp_expect = sp_avail / BLT_SPRITE_ENTRY_BYTES;
        CHECK((size_t)sp_pushed == sp_expect,
              "frame %d: sp channel accepted %d entries, exp %zu (half cap) "
              "before drop", n, sp_pushed, sp_expect);
        CHECK(ch.dropped >= 1,
              "frame %d: sp channel `dropped` counter did not fire at the half "
              "cap", n);
        blt_sprite_channel_flush(&ch, 0, 0);

        /* (b) half containment -- TL, via the local reference-model helper above. */
        size_t tl_avail = e.tl_frame_cap - e.tl_used;
        CHECK(tl_avail == sizeof(tl) / 2,
              "frame %d: tl per-frame budget %zu bytes, exp half %zu",
              n, tl_avail, sizeof(tl) / 2);
        int tl_pushed = 0;
        while (tl_push_entries(&e, 1)) tl_pushed++;
        size_t tl_expect = tl_avail / 8u;
        CHECK((size_t)tl_pushed == tl_expect,
              "frame %d: tl model accepted %d entries, exp %zu (half cap) "
              "before overflow", n, tl_pushed, tl_expect);

        /* (c) deferred-free safety, threaded through the same lagging-fabric
         * narrative: `hold` is a source extent uploaded for frame 2, whose LAST
         * reference is frame 3's commands -- so it is deferred-freed while frame 3
         * is being built (tagged submit_seq+1 == 3). It must not come back from
         * the allocator until the fabric has fully drained frame 3, which (one
         * frame behind) happens only once frame 4 has finished building. */
        if (n == 2) {
            hold = blt_alloc(&e.alloc, 400);
            CHECK(hold != BLT_ALLOC_FAIL, "frame 2: hold alloc failed");
        }
        if (n == 3) {
            blt_emitter_free_deferred(&e, hold, 400);   /* tagged seq 3 */
            probeB = blt_alloc(&e.alloc, 400);
            CHECK(probeB != hold,
                  "frame 3: extent freed by the in-flight frame was handed back "
                  "to a new allocation BEFORE the fabric drained it");
        }

        blt_end_frame(&e);

        /* Fabric progress: one frame behind, so by the time frame n has finished
         * BUILDING, the fabric has finished frame n-1 (not frame n). */
        if (n >= 2) {
            blt_emitter_drain_deferred(&e, (uint32_t)(n - 1));

            /* [timing gap] probeB (above) only proves `hold` wasn't released
             * BEFORE this drain call. But this call's own done_seq (n-1 == 2)
             * is one less than the tag (3) blt_emitter_free_deferred just
             * assigned `hold` earlier in this same iteration -- an off-by-one
             * that tags it with 2 instead of 3 would release it RIGHT HERE,
             * and nothing probes the allocator again until n==4's probeC,
             * which only checks equality-of-offset and can't tell "released
             * on time" from "released a frame early, then handed right back
             * out with nothing else touching the allocator in between". Probe
             * immediately after this call so an early release is caught at
             * the moment it happens. */
            if (n == 3) {
                uint32_t probeB2 = blt_alloc(&e.alloc, 400);
                CHECK(probeB2 != hold,
                      "frame 3: extent tagged for frame 3 was released by "
                      "frame 3's OWN drain_deferred(done_seq=%d) call -- one "
                      "frame too early", n - 1);
                blt_free(&e.alloc, probeB2, 400);  /* undo: restore heap state
                                                     * for n==4's probeC */
            }

            if (n == 4) {
                /* done_seq is now 3 -> the tag-3 entry (hold) must be released. */
                probeC = blt_alloc(&e.alloc, 400);
                CHECK(probeC == hold,
                      "frame 4: extent tagged for frame 3 was NOT released even "
                      "though the fabric has drained frame 3 -- deferred-free "
                      "would leak forever");
            }
        }

        prev_bank = e.bank;
    }

    /* Static capacity check (Task 6 step 3): map 119's heavy-map highwater is
     * 11,764 resident tile entries/frame (memory solarus-map119-gridov-nogo:
     * "tile_blits 11,764/fr UNCHANGED"), 8 bytes each (blt_tile_entry_res_t).
     * TL_BUF is 0x80000 bytes (fpga/rtl/blitter_defs.vh TL_BUF_BYTES), so a dbuf
     * half is 0x40000 -- confirm the heaviest known map's per-frame resident-tile
     * traffic fits a single half with headroom. */
    #define TL_BUF_BYTES_ 0x80000u
    #define TL_HALF_      (TL_BUF_BYTES_ / 2u)
    CHECK(11764u * 8u < TL_HALF_,
          "map119 highwater (11,764 entries * 8B = %u) does not fit a TL half "
          "(%u bytes)", 11764u * 8u, TL_HALF_);

    printf(fails ? "ring_dbuf_pipeline_test: FAIL (%d)\n" : "ring_dbuf_pipeline_test: PASS\n", fails);
    return fails ? 1 : 0;
}
