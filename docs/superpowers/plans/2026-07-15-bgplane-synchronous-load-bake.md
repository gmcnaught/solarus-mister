# Synchronous load-time bgplane bake — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bake every static bgplane to completion synchronously at map-load (before the first gameplay content frame) so the overworld base layer never shows the multi-frame "settle" garbage.

**Architecture:** Today `bake_background_plane_step()` advances the ARGB4444 plane bake one cell per `present()`; until a plane is `valid`, the layer falls back to replaying every static tile each frame — that heavy transient is the garbage. We add `bake_all_planes_sync()`, which drives the *existing* per-cell bake to completion inside one frame using the *existing* `submit_and_drain()` doorbell, batching cells to the command ring and ending each batch with a full-screen `background_color` FILL so the fabric's WORK→SCAN snapshot shows flat background color, never bake scribble. No RTL, wire, or opcode change.

**Tech Stack:** C++17 (host renderer, `patches/mister/mister_blitter_renderer.cpp`), C blitter emitter/geometry (`patches/mister/blitter/`), C/C++ host model tests (`tests/`, built by `tests/run_tests.sh`).

## Global Constraints

- Edit the **vendored renderer source** `patches/mister/mister_blitter_renderer.cpp` / `.h` directly (these are full-file sources in this repo, not `git am` series patches). All line numbers below are against the current file on branch `feat/bgplane-default-on`.
- No RTL / no `blt_wire.h` / no new opcode. Reuse `BLT_OP_FILL`, `OP_BGPLANE_WRITE`, `submit_and_drain()`.
- New behavior is **default ON**, opt-out via `SOLARUS_BGPLANE_SYNC=0` (falls back to the legacy incremental one-cell-per-frame path for A/B).
- Host model tests follow the repo pattern (`tests/blt_bgplane_write_test.c`): link `blt_emitter.c` + `blt_alloc.c`, model the host logic, assert on the emitted command stream / geometry. Build lines go in `tests/run_tests.sh`.
- Never self-declare visual correctness — HW visual is an **operator gate** (`[[solarus-no-self-declared-visual-validation]]`).
- Display safety is load-bearing: the fabric snapshots WORK→SCAN once per submitted list (`mister_blitter_renderer.cpp:2515`); every submitted bake batch MUST end with the `background_color` FILL.

---

## File Structure

- **Create** `patches/mister/blitter/bgplane_sync.h` — one pure inline helper deciding when a bake batch must be cut before the next cell so the ring can never overflow. Shared verbatim by the renderer and the tests. One responsibility: the batch-cut boundary math.
- **Create** `tests/bgplane_sync_batch_test.c` — red-green unit test of the cut helper.
- **Create** `tests/bgplane_sync_bake_test.c` — model/integration test: drives a modeled sync-bake loop over real plane geometry + the real emitter, asserting cell-coverage completeness, display-safety (bg FILL last in every submitted batch), boundedness, and no overflow.
- **Modify** `patches/mister/mister_blitter_renderer.h` — declare `void bake_all_planes_sync();`.
- **Modify** `patches/mister/mister_blitter_renderer.cpp` — add the `bgplane_sync` flag + env gate, implement `bake_all_planes_sync()`, and call it (gated) at the sig-branch bake site (`:2535`).
- **Modify** `tests/run_tests.sh` — build + run the two new tests.

---

## Task 1: Batch-cut helper + unit test

**Files:**
- Create: `patches/mister/blitter/bgplane_sync.h`
- Test: `tests/bgplane_sync_batch_test.c`
- Modify: `tests/run_tests.sh`

**Interfaces:**
- Produces: `int bgplane_sync_cut_before_cell(size_t cmd_count, size_t ring_cmd_cap)` — returns non-zero when the current batch must be submitted before emitting the next cell (i.e. remaining headroom is below the reserved per-cell margin). Also exposes `#define BGPLANE_SYNC_CELL_MARGIN 1024` (commands reserved for one cell's worst-case emission: 2 FILLs + a handful of TILELIST buckets + 1 BGPLANE_WRITE — far more than any real cell needs).

- [ ] **Step 1: Write the failing test**

Create `tests/bgplane_sync_batch_test.c`:

```c
/* Unit test for bgplane_sync_cut_before_cell (batch-cut boundary math).
 * A batch must be cut BEFORE a cell whenever fewer than BGPLANE_SYNC_CELL_MARGIN
 * command slots remain, so a cell's emission can never overflow the ring. */
#include "bgplane_sync.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    const size_t cap = 16384;   /* 512 KB ring / 32 B per command */

    /* Fresh ring: never cut. */
    assert(bgplane_sync_cut_before_cell(0, cap) == 0);

    /* Comfortable headroom: never cut. */
    assert(bgplane_sync_cut_before_cell(cap / 2, cap) == 0);

    /* Exactly one margin of headroom left: still fits, do not cut. */
    assert(bgplane_sync_cut_before_cell(cap - BGPLANE_SYNC_CELL_MARGIN, cap) == 0);

    /* One past the margin: must cut. */
    assert(bgplane_sync_cut_before_cell(cap - BGPLANE_SYNC_CELL_MARGIN + 1, cap) != 0);

    /* Ring already full: must cut. */
    assert(bgplane_sync_cut_before_cell(cap, cap) != 0);

    printf("bgplane_sync_batch: RESULT: PASS\n");
    return 0;
}
```

- [ ] **Step 2: Run it, expect FAIL (missing header)**

Run:
```bash
cc -Wall -Wextra -O2 -I patches/mister/blitter tests/bgplane_sync_batch_test.c -o /tmp/bgplane_sync_batch_test && /tmp/bgplane_sync_batch_test
```
Expected: compile error — `bgplane_sync.h: No such file or directory`.

- [ ] **Step 3: Write the helper**

Create `patches/mister/blitter/bgplane_sync.h`:

```c
/* bgplane_sync.h — batch-cut boundary math for the synchronous load-time
 * bgplane bake (bake_all_planes_sync in mister_blitter_renderer.cpp). Shared
 * VERBATIM by that renderer and by tests/bgplane_sync_*_test.c. GPL-3.0. */
#ifndef BGPLANE_SYNC_H
#define BGPLANE_SYNC_H

#include <stddef.h>

/* Commands reserved as headroom for a single cell's worst-case emission:
 * clear-WORK FILL + BLT_F_BGCOV coverage FILL + one BLT_OP_TILELIST per static
 * bucket on the layer + one OP_BGPLANE_WRITE. Real cells emit a handful; 1024 is
 * a generous, safe reservation well under the ~16384-command 512 KB ring. */
#define BGPLANE_SYNC_CELL_MARGIN ((size_t)1024)

/* Return non-zero when the current bake batch must be submitted BEFORE emitting
 * the next cell, so that cell's commands can never overflow the ring. */
static inline int bgplane_sync_cut_before_cell(size_t cmd_count,
                                               size_t ring_cmd_cap) {
    return (cmd_count + BGPLANE_SYNC_CELL_MARGIN) > ring_cmd_cap;
}

#endif /* BGPLANE_SYNC_H */
```

- [ ] **Step 4: Run it, expect PASS**

Run:
```bash
cc -Wall -Wextra -O2 -I patches/mister/blitter tests/bgplane_sync_batch_test.c -o /tmp/bgplane_sync_batch_test && /tmp/bgplane_sync_batch_test
```
Expected: `bgplane_sync_batch: RESULT: PASS`.

- [ ] **Step 5: Wire into run_tests.sh**

In `tests/run_tests.sh`, immediately after the `blt_bgplane_write` block (ends at line ~144, right before the `fps_overlay` block), add:

```bash
echo "== bgplane_sync_batch (sync load-bake batch-cut boundary math) =="
$CC -Wall -Wextra -O2 -I patches/mister/blitter \
    tests/bgplane_sync_batch_test.c \
    -o /tmp/bgplane_sync_batch_test
/tmp/bgplane_sync_batch_test
```

- [ ] **Step 6: Run the whole suite**

Run: `bash tests/run_tests.sh`
Expected: ends with `All host tests passed.` and includes the `bgplane_sync_batch ... RESULT: PASS` line.

- [ ] **Step 7: Commit**

```bash
git add patches/mister/blitter/bgplane_sync.h tests/bgplane_sync_batch_test.c tests/run_tests.sh
git commit -m "feat(render): batch-cut helper for synchronous bgplane bake + unit test"
```

---

## Task 2: Model test for the full sync-bake loop (completeness + display safety)

**Files:**
- Create: `tests/bgplane_sync_bake_test.c`
- Modify: `tests/run_tests.sh`

**Interfaces:**
- Consumes: `bgplane_sync_cut_before_cell` / `BGPLANE_SYNC_CELL_MARGIN` (Task 1); the emitter (`blt_emitter.c`: `blt_emitter_init`, `blt_begin_frame`, `blt_fill`, `blt_bgplane_write_cell`, `blt_end_frame`, `blt_cmd_t`, `blt_unpack_cmd`); geometry (`bgplane_geom.h`: `bgplane_grid`, `bgplane_cell_plane_byte_offset`, `bgplane_row_stride_qw`); alloc (`blt_alloc.c`).
- Produces: nothing consumed later — this test pins the invariants `bake_all_planes_sync()` (Task 3) must honor.

This test **models** the batch loop exactly as Task 3 implements it (the repo pattern — see `tests/blt_bgplane_write_test.c`, "Models the engine-side behaviour"). It runs the model twice: once with a huge ring (single batch) and once with a deliberately tiny ring (forced multi-batch), and asserts the same invariants both times.

- [ ] **Step 1: Write the failing test**

Create `tests/bgplane_sync_bake_test.c`:

```c
/* Models bake_all_planes_sync()'s batch loop (mister_blitter_renderer.cpp) over
 * real plane geometry + the real emitter, and asserts the invariants the real
 * method must honor:
 *   (1) COMPLETENESS  — every cell of every plane gets exactly one
 *                       OP_BGPLANE_WRITE across all submitted batches.
 *   (2) DISPLAY SAFETY — the last command emitted in every submitted batch is a
 *                        full-screen background_color FILL (so the WORK->SCAN
 *                        snapshot is flat bg color, never bake scribble).
 *   (3) BOUNDEDNESS   — batch count stays within a small bound.
 *   (4) NO OVERFLOW   — no submitted batch set the emitter overflow flag.
 * MUST MATCH the loop shape in bake_all_planes_sync(). GPL-3.0. */
#include "blitter_ref.h"
#include "blt_emitter.h"
#include "blt_wire.h"
#include "blt_alloc.h"
#include "bgplane_geom.h"
#include "bgplane_sync.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { FB_W = 320, FB_H = 240 };
#define BG565 0x4CE9u   /* to_rgb565(72,152,72), the zsdx tileset-1 background */

/* One layer's plane geometry (mirrors Impl::BgPlane's baked fields). */
typedef struct { int map_w, map_h; uint32_t sdram_base; int cells, next_cell; } plane_t;

/* Decode the command at ring index i. */
static blt_cmd_t cmd_at(const uint8_t *ring, int i) {
    blt_cmd_t c; blt_unpack_cmd(ring + (size_t)i * BLT_CMD_BYTES, &c); return c;
}

/* Run the modeled sync bake for a set of planes with a given ring capacity.
 * Records, for every OP_BGPLANE_WRITE, its target qword offset (to verify
 * coverage), and checks the display-safety FILL at each submit. Returns the
 * number of batches submitted. */
static int run_model(plane_t *planes, int n_planes, size_t ring_bytes,
                     uint32_t *seen_off, int *seen_n) {
    uint8_t *ring = malloc(ring_bytes);
    blt_emitter_t em;
    /* 5-arg init: (e, ring, ring_cap, heap, heap_cap). No heap or TL_BUF needed —
     * this model emits only FILL / OP_BGPLANE_WRITE, never a real TILELIST. */
    blt_emitter_init(&em, ring, ring_bytes, NULL, 0);
    const size_t ring_cmd_cap = ring_bytes / BLT_CMD_BYTES;

    blt_begin_frame(&em, 0, 0, 0x0000);
    int batches = 0;

    for (;;) {
        /* Find the next plane with a cell left to bake. */
        plane_t *p = NULL;
        for (int i = 0; i < n_planes; ++i)
            if (planes[i].next_cell < planes[i].cells) { p = &planes[i]; break; }

        int cut = (p == NULL) || bgplane_sync_cut_before_cell(em.cmd_count, ring_cmd_cap);

        if (cut) {
            /* Display safety: bg FILL is the last command in the batch. */
            blt_fill(&em, 0, 0, FB_W, FB_H, BG565);
            /* --- modeled submit_and_drain(): inspect, then reset the ring --- */
            assert(em.overflow == 0);                    /* (4) */
            blt_cmd_t last = cmd_at(ring, em.cmd_count - 1);
            assert(last.opcode == BLT_OP_FILL);          /* (2) */
            assert(last.color == BG565);
            assert(last.w == FB_W && last.h == FB_H);
            ++batches;
            blt_end_frame(&em);                          /* bumps submit_seq */
            blt_begin_frame(&em, 0, 0, 0x0000);          /* fresh ring */
            if (p == NULL) break;                        /* all planes done */
            continue;
        }

        /* Emit ONE cell exactly like bake_background_plane_step's inner body:
         * clear-WORK FILL, BLT_F_BGCOV coverage FILL, (modeled tile paint as one
         * FILL), then OP_BGPLANE_WRITE at this cell's plane offset. */
        int idx = p->next_cell;
        blt_fill(&em, 0, 0, FB_W, FB_H, 0x0000);
        blt_fill_flags(&em, 0, 0, FB_W, FB_H, 0, BLT_F_BGCOV);
        blt_fill(&em, 0, 0, FB_W, FB_H, 0x1234);         /* stand-in for tile paint */
        uint32_t cell_off = bgplane_cell_plane_byte_offset(idx, p->map_w, p->map_h);
        uint32_t qw_off = (p->sdram_base + cell_off) / 8;
        uint32_t stride_qw = bgplane_row_stride_qw(p->map_w);
        int rc = blt_bgplane_write_cell(&em, qw_off, stride_qw, BLT_F_BGCOV);
        assert(rc == 0 && em.overflow == 0);
        seen_off[(*seen_n)++] = qw_off;
        p->next_cell++;
    }

    free(ring);
    return batches;
}

/* Assert every plane cell's qword offset appears exactly once in seen_off. */
static void check_coverage(plane_t *planes, int n_planes,
                           const uint32_t *seen_off, int seen_n) {
    int expect_total = 0;
    for (int i = 0; i < n_planes; ++i) {
        bgplane_grid_t g = bgplane_grid(planes[i].map_w, planes[i].map_h);
        expect_total += g.count;
        for (int c = 0; c < g.count; ++c) {
            uint32_t off = bgplane_cell_plane_byte_offset(c, planes[i].map_w, planes[i].map_h);
            uint32_t qw = (planes[i].sdram_base + off) / 8;
            int hits = 0;
            for (int k = 0; k < seen_n; ++k) if (seen_off[k] == qw) ++hits;
            assert(hits == 1);   /* (1) exactly-once coverage */
        }
    }
    assert(seen_n == expect_total);   /* no extra writes */
}

int main(void) {
    /* Two planes (base + one upper), map-119-like base dimensions. */
    plane_t base_planes[2] = {
        { .map_w = 640, .map_h = 752, .sdram_base = 0x01000000u, .cells = 0, .next_cell = 0 },
        { .map_w = 640, .map_h = 752, .sdram_base = 0x02000000u, .cells = 0, .next_cell = 0 },
    };
    for (int i = 0; i < 2; ++i)
        base_planes[i].cells = bgplane_grid(base_planes[i].map_w, base_planes[i].map_h).count;

    /* Case A: huge ring -> single batch. */
    {
        plane_t planes[2]; memcpy(planes, base_planes, sizeof(planes));
        uint32_t seen[4096]; int seen_n = 0;
        int batches = run_model(planes, 2, 512u * 1024u, seen, &seen_n);
        check_coverage(planes, 2, seen, seen_n);
        assert(batches == 1);            /* (3) fits one ring */
        printf("bgplane_sync_bake caseA(single-batch): batches=%d cells=%d PASS\n",
               batches, seen_n);
    }

    /* Case B: tiny ring -> forced multi-batch; same invariants must hold. */
    {
        plane_t planes[2]; memcpy(planes, base_planes, sizeof(planes));
        uint32_t seen[4096]; int seen_n = 0;
        /* Ring just big enough for the margin + a couple cells. */
        size_t tiny = (BGPLANE_SYNC_CELL_MARGIN + 8) * BLT_CMD_BYTES;
        int batches = run_model(planes, 2, tiny, seen, &seen_n);
        check_coverage(planes, 2, seen, seen_n);
        assert(batches >= 2 && batches < seen_n + 4);   /* (3) many but bounded */
        printf("bgplane_sync_bake caseB(multi-batch): batches=%d cells=%d PASS\n",
               batches, seen_n);
    }

    printf("bgplane_sync_bake: RESULT: PASS\n");
    return 0;
}
```

- [ ] **Step 2: Confirm the emitter signatures the test hard-codes**

The test is written against the current signatures (verified on this branch):
- `void blt_emitter_init(blt_emitter_t *e, void *ring, size_t ring_cap, void *heap, size_t heap_cap)` — 5 args (no separate TL_BUF arg; the test passes `NULL, 0` for the unused heap).
- `int blt_fill_flags(blt_emitter_t *e, int x, int y, int w, int h, uint16_t color, uint8_t flags)`.
- `int blt_bgplane_write_cell(blt_emitter_t *e, uint32_t sdram_qword_offset, ...)`.

Sanity-check they still match before compiling:
```bash
grep -nE "blt_emitter_init|blt_fill_flags|blt_bgplane_write_cell|blt_end_frame|blt_begin_frame" patches/mister/blitter/blt_emitter.h
```
Expected: the declarations above. If any differ, adjust the call in the test to match.

- [ ] **Step 3: Run it, expect PASS**

Run:
```bash
cc -Wall -Wextra -O2 -I patches/mister/blitter \
   tests/bgplane_sync_bake_test.c \
   patches/mister/blitter/blt_emitter.c \
   patches/mister/blitter/blt_alloc.c \
   -o /tmp/bgplane_sync_bake_test && /tmp/bgplane_sync_bake_test
```
Expected: three `PASS` lines ending with `bgplane_sync_bake: RESULT: PASS`.

> If Case A does not produce exactly 1 batch, the margin/ring math needs re-checking against real cell count — a 640×752 plane is ~a handful of FB-sized cells, so 2 planes at ~5 commands/cell is far under a 512 KB ring. If an assert in `check_coverage` fires, the modeled per-cell offset does not match `bgplane_cell_plane_byte_offset` — STOP and reconcile with `bgplane_geom.h` (do not weaken the assert).

- [ ] **Step 4: Wire into run_tests.sh**

In `tests/run_tests.sh`, right after the `bgplane_sync_batch` block added in Task 1, add:

```bash
echo "== bgplane_sync_bake (sync load-bake: cell coverage + display-safety FILL) =="
$CC -Wall -Wextra -O2 -I patches/mister/blitter \
    tests/bgplane_sync_bake_test.c \
    patches/mister/blitter/blt_emitter.c \
    patches/mister/blitter/blt_alloc.c \
    -o /tmp/bgplane_sync_bake_test
/tmp/bgplane_sync_bake_test
```

- [ ] **Step 5: Run the whole suite**

Run: `bash tests/run_tests.sh`
Expected: ends with `All host tests passed.`, including both new `bgplane_sync_*` PASS lines.

- [ ] **Step 6: Commit**

```bash
git add tests/bgplane_sync_bake_test.c tests/run_tests.sh
git commit -m "test(render): model sync bgplane bake — cell-coverage + display-safety invariants"
```

---

## Task 3: Implement `bake_all_planes_sync()` and gate it in

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.h` (declare the method, near `:98`)
- Modify: `patches/mister/mister_blitter_renderer.cpp`:
  - add `#include "blitter/bgplane_sync.h"` with the other blitter includes
  - add `bool bgplane_sync = true;` flag (near `:562`, by `bgplane_enabled`)
  - init the flag from env (near `:2166`, by the other `bgplane_*` getenv lines)
  - implement `bake_all_planes_sync()` (next to `bake_background_plane_step`, after `:2987`)
  - swap the sig-branch bake call (`:2535`)

**Interfaces:**
- Consumes: `bgplane_sync_cut_before_cell`, `BGPLANE_SYNC_CELL_MARGIN` (Task 1); existing `bake_background_plane_step()` (`:2639`, appends ONE cell to `d->em`, returns `true` only when every plane is `valid`); `d->submit_and_drain()` (`:1155`); `blt_begin_frame` (`blt_emitter.c:82`); `to_rgb565` (`:390`); file-static `g_bg_color_r/g/b` (`:180`); `FB_W`/`FB_H` (`:344`); `d->em`, `d->target_buf`, `d->bg_planes`.
- Produces: `void MisterBlitterRenderer::bake_all_planes_sync()` — drives every armed plane to `valid` within this frame, leaving a fresh (`blt_begin_frame`'d) command ring so the caller's real content emits normally.

- [ ] **Step 1: Declare the method in the header**

In `patches/mister/mister_blitter_renderer.h`, directly after the `bake_background_plane_step()` declaration (`:98`), add:

```cpp
  // Synchronous load-time variant of the bake: drive EVERY armed plane to valid
  // within one frame (batched submit_and_drain, each batch display-safe), so the
  // first gameplay frame has no per-tile settle fallback. Gated by bgplane_sync.
  void bake_all_planes_sync();
```

- [ ] **Step 2: Add the include and the flag**

In `patches/mister/mister_blitter_renderer.cpp`, add the include next to the existing `#include "blitter/..."` lines (near the top of the file):

```cpp
#include "blitter/bgplane_sync.h"
```

Then, immediately after the `bgplane_enabled` flag declaration (`:562`), add:

```cpp
  // [sync bake] Drive the whole plane bake at map-load (one frame) instead of
  // one cell per present(); kills the base-layer "settle" garbage. Default ON;
  // SOLARUS_BGPLANE_SYNC=0 restores the legacy incremental path for A/B.
  bool bgplane_sync = true;
```

- [ ] **Step 3: Init the flag from env**

In `patches/mister/mister_blitter_renderer.cpp`, next to the other `bgplane_*` getenv lines (near `:2166`), add:

```cpp
  { const char* s = std::getenv("SOLARUS_BGPLANE_SYNC");
    self->d->bgplane_sync = !(s && s[0] == '0'); }   // default ON, opt-out with =0
```

- [ ] **Step 4: Implement `bake_all_planes_sync()`**

In `patches/mister/mister_blitter_renderer.cpp`, immediately after `bake_background_plane_step()`'s closing brace (`:2987`), add:

```cpp
// [sync bake] Drive every armed plane to valid within THIS frame, so the first
// gameplay content frame emits the steady-state single-COPY-per-layer picture
// with no per-tile settle fallback (the base-layer garbage). Reuses the existing
// per-cell bake body (bake_background_plane_step, one cell per call) and the
// existing submit_and_drain() doorbell; batches cells into the command ring and
// ends EACH submitted batch with a full-screen background_color FILL so the
// fabric's one-per-list WORK->SCAN snapshot shows flat bg color, never the bake
// scribble (the :2515 snapshot-safety contract). Called from the sig branch
// BEFORE any real content is emitted this frame; leaves a fresh blt_begin_frame'd
// ring so the caller's content loop appends normally and present() submits it.
void MisterBlitterRenderer::bake_all_planes_sync() {
  // Cheap no-op in the steady state: nothing armed -> return immediately.
  bool any_baking = false;
  for (auto& kv : d->bg_planes) if (kv.second.baking) { any_baking = true; break; }
  if (!any_baking) return;

  const uint16_t bg565 = to_rgb565(g_bg_color_r, g_bg_color_g, g_bg_color_b);
  const size_t ring_cmd_cap = d->em.ring_cap / BLT_CMD_BYTES;

  // Bounded batch budget: real quests need 1 (all cells fit one 512 KB ring).
  // The cap is a runaway backstop; if it ever trips, remaining planes stay
  // baking and the incremental one-cell-per-frame path finishes them.
  const int MAX_BATCHES = 256;
  for (int batch = 0; batch < MAX_BATCHES; ++batch) {
    // Accumulate cells into the current ring until it nears capacity or the
    // whole bake finishes. bake_background_plane_step() appends ONE cell to
    // d->em (via its own ensure_frame) and returns true only when every plane
    // is valid.
    bool all_done = false;
    while (!bgplane_sync_cut_before_cell(d->em.cmd_count, ring_cmd_cap)) {
      all_done = bake_background_plane_step();
      if (all_done) break;
      if (d->em.overflow) break;   // a single cell overran a fresh ring (huge map)
    }

    if (d->em.overflow) {
      // Pathological cell too large for a fresh ring: do NOT submit a corrupt
      // batch. Discard it (fresh begin_frame) and leave the remaining planes
      // baking -> the incremental path bakes them one-per-frame. Cells already
      // committed in prior batches stay valid in SDRAM.
      blt_begin_frame(&d->em, d->target_buf, /*clear=*/0, /*clear_color=*/0x0000);
      return;
    }

    // Display safety: end the batch with a full-screen background_color FILL so
    // the WORK->SCAN snapshot is flat bg color, never bake scribble.
    d->ensure_frame();
    blt_fill(&d->em, 0, 0, FB_W, FB_H, bg565);
    d->submit_and_drain();   // publish + block until the fabric finishes the batch
    // Fresh ring for the next batch (or for the caller's real content). Preserves
    // the armed TL_BUF entries (blt_begin_frame only resets the cursor, not the
    // data the bake replays from b.hw_off).
    blt_begin_frame(&d->em, d->target_buf, /*clear=*/0, /*clear_color=*/0x0000);

    if (all_done) return;   // every plane valid; caller's content emits next
  }
  // MAX_BATCHES tripped (not expected for real quests): remaining planes stay
  // baking; the incremental bake_background_plane_step path finishes them.
}
```

- [ ] **Step 5: Gate it in at the sig-branch bake site**

In `patches/mister/mister_blitter_renderer.cpp`, replace the single line at `:2535`:

```cpp
    if (d->bgplane_enabled) bake_background_plane_step();
```

with:

```cpp
    if (d->bgplane_enabled) {
      if (d->bgplane_sync) bake_all_planes_sync();      // whole bake this frame (default)
      else                 bake_background_plane_step(); // legacy incremental (SOLARUS_BGPLANE_SYNC=0)
    }
```

- [ ] **Step 6: Syntax-check the renderer (no armhf Docker needed)**

Per `[[fpga-renderer-native-typecheck]]`, type-check the edited file natively:

Run:
```bash
g++ -fsyntax-only -std=c++17 -I patches/mister -I patches/mister/blitter \
    -I work/solarus/include $(sdl2-config --cflags) \
    patches/mister/mister_blitter_renderer.cpp 2>&1 | head -30
```
Expected: no errors (warnings about unrelated Solarus headers are acceptable). If `work/solarus/include` is absent, first run the engine build's prepare step per `scripts/build_engine.sh` to vendor the upstream headers, or use the existing native-typecheck recipe in that memory. A missing-symbol error for `bgplane_sync_cut_before_cell` means the `#include "blitter/bgplane_sync.h"` (Step 2) is missing or mis-pathed.

- [ ] **Step 7: Re-run the host suite (nothing regressed)**

Run: `bash tests/run_tests.sh`
Expected: `All host tests passed.` (the two `bgplane_sync_*` tests still pass; the model in Task 2 now matches the shipped loop shape).

- [ ] **Step 8: Commit**

```bash
git add patches/mister/mister_blitter_renderer.h patches/mister/mister_blitter_renderer.cpp
git commit -m "feat(render): synchronous load-time bgplane bake (bake_all_planes_sync), default ON

Drives every armed plane to valid within one frame at map-load (batched
submit_and_drain, each batch ends with a background_color FILL for snapshot
safety) instead of one cell per present() — eliminates the base-layer settle
garbage. SOLARUS_BGPLANE_SYNC=0 restores the incremental path."
```

---

## Task 4: HW build, deploy, and operator visual gate

**Files:** none (build + deploy + validate).

**Interfaces:**
- Consumes: the full change from Tasks 1–3.
- Produces: an operator verdict — the deliverable is HW-confirmed behavior, not a self-declared claim.

- [ ] **Step 1: Cross-build the engine (armhf)**

Run: `bash scripts/build_engine.sh` (LuaJIT default per CLAUDE.md build-phase notes).
Expected: `build/armhf/solarus-run` + `build/armhf/libsolarus.so.1.6.5` rebuilt, no libGL/GLEW `DT_NEEDED`. Confirm the new symbol is present:
```bash
nm -C build/armhf/libsolarus.so.1.6.5 | grep bake_all_planes_sync
```
Expected: one `T` (defined) entry.

- [ ] **Step 2: Refresh deploy/ and push to the device**

Per `[[fpga-deploy-refresh-from-build-armhf]]`: copy `build/armhf/{solarus-run,libsolarus.so.1.6.5}` into `deploy/`, then:
```bash
./deploy.py --no-rbf --host 192.168.20.81
```
Expected: upload completes; verify the on-device `.so` sha1 matches the local build (FAT truncation gotcha in CLAUDE.md deploy notes).

- [ ] **Step 3: Launch detached and drive to the overworld**

Per `[[solarus-ssh-launch-dies-on-disconnect]]`, launch detached so it survives the SSH session, with bgplane on (this branch defaults it on; set it explicitly to be sure) and sync on (default):
```bash
ssh root@192.168.20.81 'cd /media/fat/games/solarus && \
  SOLARUS_BGPLANE=1 setsid sh solarus_run.sh >/tmp/solarus.log 2>&1 </dev/null &'
```
Load Mystery of Solarus DX and walk into the outside-world overworld, then teleport across several distinct-tileset maps (the `[[solarus-84-luaconsole-teleport-repro]]` route).

- [ ] **Step 4: Objective log check**

In `/tmp/solarus.log`, confirm the sync bake ran and the settle window collapsed:
- No `[MiSTer bgplane] FATAL` / `WARNING: OP_BGPLANE_WRITE dropped` lines (no ring overflow during the bake).
- Resident line shows `valid=1` within **one** frame of entering a map — not after N frames. (Per the spec's "Known residual": the single *arming* frame still precedes the first sync bake, so `valid=1` appears on the frame after arming, ~1 frame in, not the literal first frame.)

Run:
```bash
ssh root@192.168.20.81 'grep -nE "bgplane\] (FATAL|WARNING)|valid=1|overflow=[1-9]" /tmp/solarus.log | tail -30'
```
Expected: `valid=1` within a frame, no FATAL/WARNING, no non-zero overflow.

- [ ] **Step 5: Operator visual gate (required — do NOT self-declare)**

Capture screenshots on map entry and across transitions (mrext `kbd:screenshot`, recipe in `[[solarus-120-paletted-hw-validation-fail]]`). **Specifically inspect the first settled frame after each transition** (the spec's "Known residual" arming frame) — this is the frame the sync bake does NOT cover, so it is where any remaining flash would appear. The **operator** confirms: no multi-frame garbage — at most one brief frame (the arming frame) and/or a flat-`background_color` hold, then the correct map. Record the verdict in the spec's validation notes. If that first frame flashes visibly, the follow-up is the arm-at-frame-top fix named in the spec's "Known residual"; capture it and stop for a decision. Per `[[solarus-no-self-declared-visual-validation]]`, wait for the operator verdict before marking this task done.

- [ ] **Step 6: A/B sanity (optional but recommended)**

Relaunch with `SOLARUS_BGPLANE_SYNC=0` (legacy incremental) and confirm the old settle garbage reappears — proving the fix is what removed it, not an unrelated change. Then relaunch default (sync on) for the shipped configuration.

---

## Self-Review

**Spec coverage:**
- Root cause (heavy base-tile-layer incremental bake + per-tile settle fallback) → addressed by Task 3's synchronous bake. ✓
- "No new opcode; background_color already a FILL" → honored: Tasks reuse `BLT_OP_FILL`/`OP_BGPLANE_WRITE`, no wire change (Global Constraints + Task 3). ✓
- Insertion point after arming, before first content frame → Task 3 Step 5 (sig-branch `:2535`). ✓
- Mechanism reuses `bake_background_plane_step` + `submit_and_drain` + ring batching → Task 3 Step 4. ✓
- Display safety (bg FILL ends every batch) → asserted in Task 2, implemented in Task 3 Step 4. ✓
- Edge case: map too large / ring overflow → incremental fallback → Task 3 Step 4 (overflow discard + MAX_BATCHES). ✓
- Edge case: `blt_alloc` FAIL → per-bucket replay unchanged → not touched (bake_all_planes_sync only iterates existing `bg_planes` entries). ✓
- Edge case: `submit_and_drain` wedge → Task 3 note; `submit_and_drain` itself bounds the spin at ~1 s (`:1165`) and returns, so the loop cannot hang. ✓
- Testing: host completeness/display-safety (Tasks 1–2), sim fabric correctness already covered by `tb_pal8_bgplane`/`tb_bgplane_equivalence` (unchanged command semantics), HW operator gate (Task 4). ✓
- Risk: first-frame time spike → measured via the log/soak in Task 4. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; test bodies are concrete. ✓

**Type consistency:** `bgplane_sync_cut_before_cell(size_t, size_t)` and `BGPLANE_SYNC_CELL_MARGIN` identical across Task 1 (def), Task 2 (use), Task 3 (use). `bake_all_planes_sync()` signature identical in header (Task 3 Step 1) and definition (Task 3 Step 4) and gate call (Step 5). `to_rgb565`, `g_bg_color_*`, `FB_W/FB_H`, `d->em.ring_cap`, `d->target_buf`, `d->submit_and_drain()`, `blt_begin_frame` all verified against the current source. ✓

One follow-up flagged for the implementer: Task 2 Step 2 verifies the exact `blt_emitter_init`/`blt_fill_flags` argument lists before first compile, since the test hard-codes them.
