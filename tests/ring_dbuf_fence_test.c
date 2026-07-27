/* ring_dbuf_fence_test — [C1] the ensure_frame() fence must never be satisfied by
 * a STALE C_DONE inherited from a previous engine run.
 *
 * Why this test exists. Nothing in the engine ever writes C_DONE: it is
 * fabric-owned. DDR3 at BLT_DDR_PHYS is not zeroed by mmap(), by engine exit, or
 * by a core reload, so the SECOND engine run on a board starts with whatever
 * counts the FIRST run left behind. Before the ring-double-buffer branch that was
 * harmless: blitter_top's S_WR_DONE wrote submit_reg, so C_DONE snapped to the
 * host's sequence within one frame. Spec §3.4 changes it to done_reg + 1 (a
 * submit-copy collapses a frame when two are in flight) — which removes the
 * self-heal. A host sequence restarting at 0 against a stale-HIGH C_DONE then
 * makes ensure_frame()'s wrap-safe signed compare read "already satisfied", so
 * the fence NEVER waits and the host overwrites the ring the fabric is still
 * reading — precisely the corruption the fence exists to prevent, and it fires on
 * the rollback path (SOLARUS_RINGDBUF=0) too.
 *
 * The fix is host-side, in map_ddr(): the host ADOPTS the fabric's origin
 * (sync_submit_origin() reads C_DONE, returns it once C_SUBMIT == C_DONE, and
 * writes only C_SUBMIT — never C_DONE — to stop a non-quiescent fabric) and seeds
 * em.submit_seq with it.
 *
 * This models the comparison arithmetic and the origin handshake only — no DDR,
 * no mmap. The fabric is a counter that publishes one completion per composited
 * frame, exactly like S_WR_DONE's done_reg + 1.
 */
#include <stdio.h>
#include <stdint.h>

static int fails = 0;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

/* ---- mirrors of the production host logic (mister_blitter_renderer.cpp) ---- */

/* ensure_frame(): the frame about to be BUILT publishes as submit_seq+1, so with
 * dbuf armed it reuses the bank of submit_seq-1; off, it reuses the single bank
 * of submit_seq itself. */
static uint32_t fence_need(uint32_t submit_seq, int dbuf)
{
    return dbuf ? (submit_seq >= 1 ? submit_seq - 1u : 0u) : submit_seq;
}
/* ensure_frame()'s spin predicate: wrap-safe signed delta. */
static int fence_must_wait(uint32_t c_done, uint32_t need)
{
    return (int32_t)(c_done - need) < 0;
}
/* submit_and_drain() / drain_pipeline(): plain inequality, so a C_DONE that can
 * never be reached burns the full 1 s spin cap instead of returning. */
static int drain_must_wait(uint32_t c_done, uint32_t submit_seq)
{
    return c_done != submit_seq;
}

/* sync_submit_origin(): read C_DONE first, adopt it when the pair is already
 * quiescent (writing NOTHING, so the fabric can never observe C_SUBMIT != C_DONE
 * and composite a stale-ring frame); otherwise pull C_SUBMIT down to the C_DONE
 * just read and retry. `*submit`/`*done` are the DDR words; `*writes` counts
 * C_SUBMIT stores. The fabric model advances done by one per pass while the pair
 * differs (a frame it was already mid-way through). */
static uint32_t sync_submit_origin(uint32_t *submit, uint32_t *done, int *writes)
{
    *writes = 0;
    for (int i = 0; i < 100; i++) {
        uint32_t d = *done;                 /* C_DONE read FIRST */
        if (*submit == d) return d;         /* quiescent: adopt, write nothing */
        *submit = d; (*writes)++;           /* never writes C_DONE */
        if (*submit != *done) (*done)++;    /* fabric finishes its in-flight frame */
    }
    return *done;
}

/* ---- the session driver ------------------------------------------------- *
 * Runs `frames` frames against a SLOW fabric (it finishes one frame every
 * `fab_every` host iterations) and returns the number of times the fence FAILED
 * to block although the fabric had not actually finished the frame whose bank the
 * host was about to overwrite. Zero is the only safe answer. `adopt` selects the
 * fixed origin (adopt the fabric's count) vs the pre-fix behaviour (hard 0, from
 * blt_emitter_init's memset).
 *
 * The fabric rate is imposed; how far the host may run AHEAD of it is NOT — that
 * is precisely what the fence is supposed to bound (to 1 frame with dbuf armed, 0
 * without). A fence that never blocks lets the host run away, which is the
 * failure this models.
 *
 * GROUND TRUTH is tracked separately from the DDR word, because the whole bug is
 * that the two can live in DIFFERENT sequence spaces: `nf` counts the HOST frames
 * the fabric has really composited, while the published word is
 * `done_start + nf` (S_WR_DONE's done_reg + 1, starting from whatever the
 * previous session left in DDR3). Host frame `need` is the (need - origin)-th
 * host frame, so it is genuinely complete iff nf >= need - origin.
 */
static int run_session(uint32_t ddr_submit, uint32_t ddr_done,
                       int adopt, int dbuf, int frames, int fab_every,
                       int *drain_stuck)
{
    int writes = 0;
    uint32_t origin = 0u;
    if (adopt) origin = sync_submit_origin(&ddr_submit, &ddr_done, &writes);
    const uint32_t done_start = ddr_done;   /* the fabric's own counter origin */

    uint32_t submit_seq = origin;
    long nf = 0, submitted = 0;
    int unsafe = 0;
    *drain_stuck = 0;

    for (int f = 0; f < frames; f++) {
        /* --- ensure_frame(): fence before touching the bank we are about to
         * build into. The bank's previous occupant is `need`. */
        const uint32_t need = fence_need(submit_seq, dbuf);
        if (submit_seq != 0) {           /* production skips the fence at seq 0 */
            const long k_need   = (long)(int32_t)(need - origin);
            const int  finished = (k_need <= 0) || (nf >= k_need);
            if (!fence_must_wait(done_start + (uint32_t)nf, need) && !finished)
                unsafe++;                /* fence let the host through too early */
            /* the spin: the fabric catches up while we wait (it can only work on
             * frames that were actually submitted). */
            int spins = 0;
            while (fence_must_wait(done_start + (uint32_t)nf, need) &&
                   nf < submitted && spins < 5000) { nf++; spins++; }
        }
        /* --- present(): pack + ring the doorbell --- */
        submit_seq++; submitted++;
        /* --- the fabric composites, one frame every `fab_every` iterations --- */
        if ((f % fab_every) == 0 && nf < submitted) nf++;
        /* --- a drain point (submit_and_drain's plain != spin) --- */
        if (f == frames - 1) {
            int spins = 0;
            while (drain_must_wait(done_start + (uint32_t)nf, submit_seq) &&
                   spins < 5000) {
                if (nf < submitted) nf++;
                spins++;
            }
            if (spins >= 5000) *drain_stuck = 1;
        }
    }
    return unsafe;
}

int main(void)
{
    int stuck;

    /* ── 1. THE REGRESSION. A restart inherits a large, self-consistent pair
     * (the previous run ended quiescent at 5000). The host must adopt it. ── */
    for (int dbuf = 0; dbuf <= 1; dbuf++) {
        int unsafe = run_session(5000u, 5000u, /*adopt=*/1, dbuf, 200, 2, &stuck);
        CHECK(unsafe == 0,
              "dbuf=%d: adopted origin still let the fence through %d time(s) "
              "before the fabric published the sequence being overwritten",
              dbuf, unsafe);
        CHECK(!stuck,
              "dbuf=%d: adopted origin left submit_and_drain's != spin unable to "
              "converge (it would burn the full 1 s cap every frame)", dbuf);

        /* The same session with the PRE-FIX hard-zero origin must be caught.
         * If this ever reports 0 the test has stopped modelling the bug and the
         * check above proves nothing. */
        int pre = run_session(5000u, 5000u, /*adopt=*/0, dbuf, 200, 2, &stuck);
        CHECK(pre > 0,
              "dbuf=%d: hard-zero origin against a stale C_DONE=5000 was NOT "
              "detected as unsafe — this test no longer covers C1", dbuf);
        CHECK(stuck,
              "dbuf=%d: hard-zero origin should also strand submit_and_drain's "
              "!= spin (C_DONE unreachable) — model drifted", dbuf);
    }

    /* ── 2. Wrap safety: an origin near UINT32_MAX must still fence correctly
     * as the sequence rolls over. ── */
    for (int dbuf = 0; dbuf <= 1; dbuf++) {
        int unsafe = run_session(0xFFFFFFF0u, 0xFFFFFFF0u, /*adopt=*/1, dbuf,
                                 64, 2, &stuck);
        CHECK(unsafe == 0,
              "dbuf=%d: fence broke across the uint32 sequence wrap (%d unsafe)",
              dbuf, unsafe);
        CHECK(!stuck, "dbuf=%d: drain spin stranded across the wrap", dbuf);
    }

    /* ── 3. sync_submit_origin() ordering contract. ── */
    {
        /* Quiescent pair (the normal restart): ZERO writes, so there is no window
         * in which the fabric can see C_SUBMIT != C_DONE and composite a stale
         * frame. This is the property the whole ordering argument rests on. */
        uint32_t s = 4242u, d = 4242u; int w = -1;
        uint32_t o = sync_submit_origin(&s, &d, &w);
        CHECK(o == 4242u, "quiescent origin adopted %u, expected 4242", o);
        CHECK(w == 0, "quiescent pair took %d C_SUBMIT write(s), expected 0 "
                      "(any write opens an unequal window)", w);
        CHECK(d == 4242u, "sync_submit_origin advanced C_DONE — it must never "
                          "write or disturb the fabric-owned word");
    }
    {
        /* Core reload: fabric reset done_reg to 0 while DDR kept a stale-high
         * C_SUBMIT, so it is grinding through garbage frames. The helper must
         * pull C_SUBMIT DOWN and converge, and must never leave C_DONE above
         * C_SUBMIT (the fabric would then chase equality for 2^32 frames). */
        uint32_t s = 5000u, d = 3u; int w = -1;
        uint32_t o = sync_submit_origin(&s, &d, &w);
        CHECK(s == d, "runaway fabric not equalised: C_SUBMIT=%u C_DONE=%u", s, d);
        CHECK(o == s, "adopted origin %u != the equalised pair %u", o, s);
        CHECK(w >= 1 && w <= 4,
              "runaway equalisation took %d C_SUBMIT writes, expected to "
              "converge in a couple of passes", w);
        CHECK((int32_t)(d - s) <= 0,
              "C_DONE (%u) left ABOVE C_SUBMIT (%u) — fabric would never idle",
              d, s);
    }

    printf(fails ? "ring_dbuf_fence_test: FAIL (%d)\n"
                 : "ring_dbuf_fence_test: PASS\n", fails);
    return fails ? 1 : 0;
}
