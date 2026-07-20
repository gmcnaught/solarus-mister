# Stage 3b Phase B1 — grid wire format, emitter, and reference model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Define and validate the host side of a per-layer 8px cell-grid blitter op (`BLT_OP_TILEMAP`, opcode 11) — cell encoding, grid builder with horizontal run coalescing, emitter, and a reference-model executor — proven **bit-exact against the existing per-tile path** with zero RTL.

**Architecture:** The wire format is the contract between host and fabric. B1 builds and validates the host half in isolation: a grid built from the same tile entries the current path uses must render byte-identically to that path, verified by the two-heap / `memcmp` framebuffer-equivalence harness that Stage 2 established. B2 then implements the same op in RTL against this same reference; B3 wires it to real engine data and takes it to hardware. No Quartus build, no device, no engine patches in B1.

**Tech Stack:** C99 blitter emitter and reference model (`patches/mister/blitter/`, whole-file copies — NOT patch-series entries), host test harnesses built by `patches/mister/build_test_*.sh`, Python wire-constant cross-check.

## Global Constraints

- **Everything under `patches/mister/blitter/` and `patches/mister/mister_blitter_renderer.{cpp,h}` are whole-file copies, not patch-series entries.** Edit them DIRECTLY. Never run `export_patches.sh` for them. **B1 touches no engine patch and no file under `patches/series/`.**
- **Never use `git stash`** in this repo — three long-lived unrelated stashes exist and a bare `pop` restores the wrong one.
- **The renderer syntax-check MUST include `-DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO`.** `scripts/build_engine.sh:134-135` sets both unconditionally and virtually the whole renderer lives inside `#ifdef MISTER_NATIVE_VIDEO`; without them g++ compiles almost nothing and prints `SYNTAX OK` for a file with 20 hard errors.
- **Reuse the 32-byte command header.** `blt_pack_cmd` / `blt_unpack_cmd` (`blt_wire.h:52-92`) must NOT change. Every op since 5 reuses it; a grid op does too.
- **Variable-length payloads never live inline in the ring.** Follow `tl_emit_header` (`blt_emitter.c:360-387`): header carries entry count and a **byte offset into a dedicated DDR region**, plus a signed per-batch bias in `src_x`/`src_y`.
- **`BLT_OP_BGPLANE_WRITE = 8` and `BLT_F_BGCOV = 0x80` are RESERVED.** Do not reuse opcode 8. The new op is **11** (highest currently used is 10).
- **Host tests are C99 built with `-Wall -Wextra -Werror`** (`build_test_spritelist.sh:10-15`). Warnings are errors.
- Every task must leave the tree building and `patches/mister/build_host_tests.sh` passing.

## The cell encoding (frozen for B1 — B2's RTL depends on it)

```
bits [11:0]  pattern index  — 0xFFF means EMPTY (walker skips the cell)
bits [15:12] sub_x          — this cell's x offset inside its pattern, in cells (0-15)
bits [19:16] sub_y          — this cell's y offset inside its pattern, in cells (0-15)
bits [23:20] run_m1         — (cells remaining horizontally FROM THIS CELL) - 1, so 1-16
bits [31:24] spare          — must be written 0 and ignored on read
```

**`run_m1` is remaining-from-here, NOT length-from-run-start.** Every cell is self-describing, so a visible window that opens in the middle of a wide pattern still emits a correct partial run. A start-relative encoding breaks exactly there — which is every scroll.

**A run may only span cells whose source pixels are horizontally contiguous — i.e. cells within ONE pattern instance, with `sub_x` incrementing and `sub_y` constant.** Two adjacent instances of the same 8px pattern must NOT be merged: a wider blit would read past that pattern in the atlas. This is the single correctness rule of the format.

---

### Task 1: Cell encoding — packer, unpacker, and bit-layout self-test

**Files:**
- Create: `patches/mister/blitter/grid_cell.h`
- Create: `patches/mister/test_gridcell.c`
- Create: `patches/mister/build_test_gridcell.sh`
- Modify: `patches/mister/build_host_tests.sh` (register the new test)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `typedef uint32_t blt_grid_cell_t;`
  - `#define BLT_GRID_PID_EMPTY 0xFFFu`
  - `static inline blt_grid_cell_t blt_grid_cell_pack(uint16_t pid, uint8_t sub_x, uint8_t sub_y, uint8_t run_m1);`
  - `static inline uint16_t blt_grid_cell_pid(blt_grid_cell_t c);`
  - `static inline uint8_t blt_grid_cell_sub_x(blt_grid_cell_t c);`
  - `static inline uint8_t blt_grid_cell_sub_y(blt_grid_cell_t c);`
  - `static inline uint8_t blt_grid_cell_run(blt_grid_cell_t c);` — returns `run_m1 + 1`, i.e. 1..16
  - `static inline int blt_grid_cell_is_empty(blt_grid_cell_t c);`

- [ ] **Step 1: Write the failing test**

Create `patches/mister/test_gridcell.c`:

```c
/* Bit-layout pin for the 32-bit tilemap grid cell (Stage 3b Phase B1).
 * The fabric decodes these exact bit positions; a silent field move here
 * desynchronizes host and RTL. */
#include "blitter/grid_cell.h"
#include <stdio.h>
#include <string.h>

static int fails = 0;
#define CHECK(cond, ...) do { if (!(cond)) { \
    printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); fails++; } } while (0)

int main(void) {
    /* 1. Round-trip across the full range of every field. */
    for (uint16_t pid = 0; pid < 4096; pid += 7) {
        for (uint8_t sx = 0; sx < 16; ++sx) {
            for (uint8_t sy = 0; sy < 16; ++sy) {
                for (uint8_t r = 0; r < 16; ++r) {
                    blt_grid_cell_t c = blt_grid_cell_pack(pid, sx, sy, r);
                    CHECK(blt_grid_cell_pid(c) == pid, "pid %u != %u", blt_grid_cell_pid(c), pid);
                    CHECK(blt_grid_cell_sub_x(c) == sx, "sub_x %u != %u", blt_grid_cell_sub_x(c), sx);
                    CHECK(blt_grid_cell_sub_y(c) == sy, "sub_y %u != %u", blt_grid_cell_sub_y(c), sy);
                    CHECK(blt_grid_cell_run(c) == (uint8_t)(r + 1), "run %u != %u",
                          blt_grid_cell_run(c), (unsigned)(r + 1));
                }
            }
        }
    }

    /* 2. EXACT bit positions. These literals are the host<->RTL contract:
     *    pid=0x123, sub_x=4, sub_y=5, run_m1=6 -> 0x0065_4123 */
    blt_grid_cell_t k = blt_grid_cell_pack(0x123, 4, 5, 6);
    CHECK(k == 0x00654123u, "layout drifted: got 0x%08X want 0x00654123", k);

    /* 3. Spare bits [31:24] are written zero. */
    CHECK((blt_grid_cell_pack(0xFFF, 15, 15, 15) >> 24) == 0u, "spare bits not zero");

    /* 4. Empty sentinel. */
    blt_grid_cell_t e = blt_grid_cell_pack(BLT_GRID_PID_EMPTY, 0, 0, 0);
    CHECK(blt_grid_cell_is_empty(e), "empty sentinel not detected");
    CHECK(!blt_grid_cell_is_empty(blt_grid_cell_pack(0, 0, 0, 0)), "pid 0 wrongly reported empty");

    /* 5. run is remaining-from-here and is never zero — a zero run would make a
     *    walker emit a zero-width blit and fail to advance. */
    CHECK(blt_grid_cell_run(blt_grid_cell_pack(1, 0, 0, 0)) == 1, "minimum run must be 1");

    if (fails) { printf("test_gridcell: %d FAILURES\n", fails); return 1; }
    printf("test_gridcell: all checks passed\n");
    return 0;
}
```

- [ ] **Step 2: Create the build script and run it to verify the test FAILS**

Create `patches/mister/build_test_gridcell.sh` (model on `build_test_spritelist.sh`):

```bash
#!/usr/bin/env bash
# Stage 3b Phase B1: 32-bit tilemap grid cell bit-layout pin.
set -euo pipefail
cd "$(dirname "$0")"
cc -std=c99 -Wall -Wextra -Werror -I . -I blitter \
   test_gridcell.c -o /tmp/test_gridcell
/tmp/test_gridcell
echo "== gridcell OK =="
```

```bash
chmod +x patches/mister/build_test_gridcell.sh
bash patches/mister/build_test_gridcell.sh
```
Expected: FAILS to compile — `blitter/grid_cell.h` does not exist yet.

- [ ] **Step 3: Write the header**

Create `patches/mister/blitter/grid_cell.h`:

```c
#ifndef BLT_GRID_CELL_H
#define BLT_GRID_CELL_H
/* [Stage 3b Phase B1] 32-bit tilemap grid cell.
 *
 *   bits [11:0]  pattern index  (BLT_GRID_PID_EMPTY = empty, walker skips)
 *   bits [15:12] sub_x          x offset inside the pattern, in 8px cells
 *   bits [19:16] sub_y          y offset inside the pattern, in 8px cells
 *   bits [23:20] run_m1         (cells remaining horizontally FROM THIS CELL) - 1
 *   bits [31:24] spare          written 0, ignored on read
 *
 * run_m1 is REMAINING-FROM-HERE, not length-from-run-start, so a cell is
 * self-describing and a visible window opening mid-pattern still emits a
 * correct partial run.
 *
 * CORRECTNESS RULE: a run may only span cells whose source pixels are
 * horizontally contiguous -- cells within ONE pattern instance, sub_x
 * incrementing, sub_y constant. Merging two adjacent instances of the same
 * pattern would make the fabric read past that pattern in the atlas.
 *
 * These bit positions are decoded by the fabric. Changing them requires a
 * matching RTL change and a test_wire_constants.py update. */
#include <stdint.h>

typedef uint32_t blt_grid_cell_t;

#define BLT_GRID_PID_EMPTY 0xFFFu
#define BLT_GRID_MAX_RUN   16       /* widest pattern in the quest: 128px = 16 cells */

static inline blt_grid_cell_t blt_grid_cell_pack(uint16_t pid, uint8_t sub_x,
                                                 uint8_t sub_y, uint8_t run_m1) {
    return ((blt_grid_cell_t)(pid    & 0x0FFFu))
         | ((blt_grid_cell_t)(sub_x  & 0x0Fu) << 12)
         | ((blt_grid_cell_t)(sub_y  & 0x0Fu) << 16)
         | ((blt_grid_cell_t)(run_m1 & 0x0Fu) << 20);
}

static inline uint16_t blt_grid_cell_pid(blt_grid_cell_t c)   { return (uint16_t)( c        & 0x0FFFu); }
static inline uint8_t  blt_grid_cell_sub_x(blt_grid_cell_t c) { return (uint8_t) ((c >> 12) & 0x0Fu); }
static inline uint8_t  blt_grid_cell_sub_y(blt_grid_cell_t c) { return (uint8_t) ((c >> 16) & 0x0Fu); }
static inline uint8_t  blt_grid_cell_run(blt_grid_cell_t c)   { return (uint8_t)(((c >> 20) & 0x0Fu) + 1u); }
static inline int      blt_grid_cell_is_empty(blt_grid_cell_t c) {
    return blt_grid_cell_pid(c) == BLT_GRID_PID_EMPTY;
}

#endif /* BLT_GRID_CELL_H */
```

- [ ] **Step 4: Run the test to verify it PASSES**

```bash
bash patches/mister/build_test_gridcell.sh
```
Expected: `test_gridcell: all checks passed` then `== gridcell OK ==`.

- [ ] **Step 5: Register in the CI gate**

In `patches/mister/build_host_tests.sh`, add a comment line to the header block and `bash build_test_gridcell.sh` to the run list (currently lines 15-22).

```bash
bash patches/mister/build_host_tests.sh
```
Expected: ends with `== all host tests passed ==`.

- [ ] **Step 6: Commit**

```bash
git add patches/mister/blitter/grid_cell.h patches/mister/test_gridcell.c \
        patches/mister/build_test_gridcell.sh patches/mister/build_host_tests.sh
git commit -m "feat(blitter): 32-bit tilemap grid cell encoding + bit-layout pin

run_m1 is remaining-from-here so a window opening mid-pattern still emits a
correct partial run. Runs may only span one pattern instance."
```

---

### Task 2: Grid builder — tile entries to a cell grid, with run coalescing

Pure host-side data transformation, fully testable with no emitter and no framebuffer. This is where the correctness rule of the format is enforced.

**Files:**
- Create: `patches/mister/blitter/grid_build.h`
- Create: `patches/mister/test_gridbuild.c`
- Create: `patches/mister/build_test_gridbuild.sh`
- Modify: `patches/mister/build_host_tests.sh`

**Interfaces:**
- Consumes: `grid_cell.h` from Task 1.
- Produces:
```c
typedef struct { uint16_t pid; uint16_t cell_x, cell_y; uint8_t w_cells, h_cells; } blt_grid_tile_t;

/* Fills cells[w_cells*h_cells] row-major. Every cell is initialised EMPTY first.
 * Later tiles overwrite earlier ones (painter's order within a layer).
 * Returns 0 on success, -1 if any tile falls outside the grid. */
int blt_grid_build(blt_grid_cell_t *cells, uint16_t grid_w, uint16_t grid_h,
                   const blt_grid_tile_t *tiles, size_t n_tiles);
```

- [ ] **Step 1: Write the failing test**

Create `patches/mister/test_gridbuild.c`:

```c
/* [Stage 3b Phase B1] Grid builder: tile list -> cell grid with horizontal runs. */
#include "blitter/grid_build.h"
#include <stdio.h>
#include <string.h>

static int fails = 0;
#define CHECK(cond, ...) do { if (!(cond)) { \
    printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); fails++; } } while (0)

#define GW 8
#define GH 4
static blt_grid_cell_t g[GW * GH];
#define AT(x, y) g[(size_t)(y) * GW + (x)]

int main(void) {
    /* 1. Empty grid: every cell EMPTY. */
    CHECK(blt_grid_build(g, GW, GH, NULL, 0) == 0, "empty build failed");
    for (int i = 0; i < GW * GH; ++i)
        CHECK(blt_grid_cell_is_empty(g[i]), "cell %d not empty", i);

    /* 2. A single 1x1 pattern: run must be 1, sub 0,0. */
    {
        blt_grid_tile_t t = { .pid = 5, .cell_x = 2, .cell_y = 1, .w_cells = 1, .h_cells = 1 };
        CHECK(blt_grid_build(g, GW, GH, &t, 1) == 0, "1x1 build failed");
        CHECK(blt_grid_cell_pid(AT(2,1)) == 5, "pid wrong");
        CHECK(blt_grid_cell_run(AT(2,1)) == 1, "1x1 run must be 1, got %u", blt_grid_cell_run(AT(2,1)));
        CHECK(blt_grid_cell_is_empty(AT(3,1)), "neighbour must stay empty");
    }

    /* 3. A 3x2 pattern: each ROW is one run of 3, remaining-from-here counts down. */
    {
        blt_grid_tile_t t = { .pid = 9, .cell_x = 1, .cell_y = 0, .w_cells = 3, .h_cells = 2 };
        CHECK(blt_grid_build(g, GW, GH, &t, 1) == 0, "3x2 build failed");
        for (int row = 0; row < 2; ++row) {
            CHECK(blt_grid_cell_run(AT(1, row)) == 3, "row %d start run must be 3", row);
            CHECK(blt_grid_cell_run(AT(2, row)) == 2, "row %d mid run must be 2", row);
            CHECK(blt_grid_cell_run(AT(3, row)) == 1, "row %d end run must be 1", row);
            for (int c = 0; c < 3; ++c) {
                CHECK(blt_grid_cell_sub_x(AT(1 + c, row)) == (uint8_t)c, "sub_x wrong");
                CHECK(blt_grid_cell_sub_y(AT(1 + c, row)) == (uint8_t)row, "sub_y wrong");
                CHECK(blt_grid_cell_pid(AT(1 + c, row)) == 9, "pid wrong");
            }
        }
    }

    /* 4. THE CORRECTNESS RULE: two adjacent instances of the SAME 1-cell pattern
     *    must NOT coalesce. Each keeps run==1; merging them would make the fabric
     *    read past the pattern in the atlas. */
    {
        blt_grid_tile_t t[2] = {
            { .pid = 7, .cell_x = 0, .cell_y = 3, .w_cells = 1, .h_cells = 1 },
            { .pid = 7, .cell_x = 1, .cell_y = 3, .w_cells = 1, .h_cells = 1 },
        };
        CHECK(blt_grid_build(g, GW, GH, t, 2) == 0, "adjacent build failed");
        CHECK(blt_grid_cell_run(AT(0,3)) == 1, "adjacent same-pid tiles MUST NOT merge (got run %u)",
              blt_grid_cell_run(AT(0,3)));
        CHECK(blt_grid_cell_run(AT(1,3)) == 1, "second instance run must be 1");
        CHECK(blt_grid_cell_sub_x(AT(1,3)) == 0, "second instance sub_x must restart at 0");
    }

    /* 5. Overwrite: a later tile wins (painter's order within a layer). */
    {
        blt_grid_tile_t t[2] = {
            { .pid = 1, .cell_x = 0, .cell_y = 0, .w_cells = 2, .h_cells = 1 },
            { .pid = 2, .cell_x = 1, .cell_y = 0, .w_cells = 1, .h_cells = 1 },
        };
        CHECK(blt_grid_build(g, GW, GH, t, 2) == 0, "overwrite build failed");
        CHECK(blt_grid_cell_pid(AT(1,0)) == 2, "later tile must win");
        /* The truncated first tile must not claim a run that runs into the overwrite. */
        CHECK(blt_grid_cell_run(AT(0,0)) == 1,
              "run must be re-derived after overwrite, got %u", blt_grid_cell_run(AT(0,0)));
    }

    /* 6. Out-of-bounds tile is rejected, not silently clipped. */
    {
        blt_grid_tile_t t = { .pid = 3, .cell_x = GW - 1, .cell_y = 0, .w_cells = 4, .h_cells = 1 };
        CHECK(blt_grid_build(g, GW, GH, &t, 1) == -1, "OOB tile must be rejected");
    }

    /* 7. Run never exceeds BLT_GRID_MAX_RUN even for a maximal pattern. */
    {
        blt_grid_cell_t big[32 * 1];
        blt_grid_tile_t t = { .pid = 4, .cell_x = 0, .cell_y = 0, .w_cells = 16, .h_cells = 1 };
        CHECK(blt_grid_build(big, 32, 1, &t, 1) == 0, "16-wide build failed");
        CHECK(blt_grid_cell_run(big[0]) == 16, "max run must be 16, got %u", blt_grid_cell_run(big[0]));
    }

    if (fails) { printf("test_gridbuild: %d FAILURES\n", fails); return 1; }
    printf("test_gridbuild: all checks passed\n");
    return 0;
}
```

- [ ] **Step 2: Create the build script and confirm the test FAILS**

Create `patches/mister/build_test_gridbuild.sh`:

```bash
#!/usr/bin/env bash
# Stage 3b Phase B1: grid builder (tile list -> cell grid with runs).
set -euo pipefail
cd "$(dirname "$0")"
cc -std=c99 -Wall -Wextra -Werror -I . -I blitter \
   test_gridbuild.c -o /tmp/test_gridbuild
/tmp/test_gridbuild
echo "== gridbuild OK =="
```

```bash
chmod +x patches/mister/build_test_gridbuild.sh
bash patches/mister/build_test_gridbuild.sh
```
Expected: FAILS — `blitter/grid_build.h` does not exist.

- [ ] **Step 3: Implement the builder**

Create `patches/mister/blitter/grid_build.h`. Build in two passes — paint pattern identity and sub-offsets first, then derive runs — because case 5 proves a run cannot be computed while painting: a later tile can truncate an earlier tile's run.

```c
#ifndef BLT_GRID_BUILD_H
#define BLT_GRID_BUILD_H
/* [Stage 3b Phase B1] Build a cell grid from a tile list.
 *
 * Two passes, deliberately:
 *   pass 1 paints (pid, sub_x, sub_y) in painter's order, later tiles winning;
 *   pass 2 derives run_m1 by scanning each row.
 * A single fused pass is wrong -- a later tile can truncate an earlier tile's
 * run, so runs are only knowable once all painting is done. */
#include "grid_cell.h"
#include <stddef.h>

typedef struct {
    uint16_t pid;
    uint16_t cell_x, cell_y;
    uint8_t  w_cells, h_cells;
} blt_grid_tile_t;

static inline int blt_grid_build(blt_grid_cell_t *cells, uint16_t grid_w, uint16_t grid_h,
                                 const blt_grid_tile_t *tiles, size_t n_tiles) {
    const size_t n = (size_t)grid_w * (size_t)grid_h;
    for (size_t i = 0; i < n; ++i)
        cells[i] = blt_grid_cell_pack(BLT_GRID_PID_EMPTY, 0, 0, 0);

    /* Pass 1: paint identity + sub-offsets. */
    for (size_t t = 0; t < n_tiles; ++t) {
        const blt_grid_tile_t *ti = &tiles[t];
        if (ti->w_cells == 0 || ti->h_cells == 0) return -1;
        if ((size_t)ti->cell_x + ti->w_cells > grid_w) return -1;
        if ((size_t)ti->cell_y + ti->h_cells > grid_h) return -1;
        if (ti->w_cells > BLT_GRID_MAX_RUN)            return -1;
        if (ti->pid >= BLT_GRID_PID_EMPTY)             return -1;
        for (uint8_t dy = 0; dy < ti->h_cells; ++dy)
            for (uint8_t dx = 0; dx < ti->w_cells; ++dx)
                cells[(size_t)(ti->cell_y + dy) * grid_w + (ti->cell_x + dx)] =
                    blt_grid_cell_pack(ti->pid, dx, dy, 0);
    }

    /* Pass 2: derive runs, right-to-left. A cell extends the run to its right
     * only if that neighbour is the SAME pattern instance -- same pid, same
     * sub_y, and sub_x exactly one greater. That last condition is what stops
     * two adjacent instances of the same pattern from merging. */
    for (uint16_t y = 0; y < grid_h; ++y) {
        for (uint16_t x = grid_w; x-- > 0; ) {
            blt_grid_cell_t *c = &cells[(size_t)y * grid_w + x];
            if (blt_grid_cell_is_empty(*c)) continue;
            uint8_t run = 1;
            if (x + 1 < grid_w) {
                const blt_grid_cell_t r = cells[(size_t)y * grid_w + (x + 1)];
                if (!blt_grid_cell_is_empty(r)
                    && blt_grid_cell_pid(r)   == blt_grid_cell_pid(*c)
                    && blt_grid_cell_sub_y(r) == blt_grid_cell_sub_y(*c)
                    && blt_grid_cell_sub_x(r) == (uint8_t)(blt_grid_cell_sub_x(*c) + 1)) {
                    const uint8_t rr = blt_grid_cell_run(r);
                    run = (uint8_t)(rr + 1 > BLT_GRID_MAX_RUN ? BLT_GRID_MAX_RUN : rr + 1);
                }
            }
            *c = blt_grid_cell_pack(blt_grid_cell_pid(*c), blt_grid_cell_sub_x(*c),
                                    blt_grid_cell_sub_y(*c), (uint8_t)(run - 1));
        }
    }
    return 0;
}

#endif /* BLT_GRID_BUILD_H */
```

- [ ] **Step 4: Run the test to verify it PASSES**

```bash
bash patches/mister/build_test_gridbuild.sh
```
Expected: `test_gridbuild: all checks passed`.

- [ ] **Step 5: Mutation-check the correctness rule**

The rule this format lives or dies on is "adjacent same-pattern instances must not merge". Prove the test actually catches its violation: temporarily delete the
`&& blt_grid_cell_sub_x(r) == (uint8_t)(blt_grid_cell_sub_x(*c) + 1)` condition, rebuild, and confirm **case 4 fails**. Then restore it and confirm the suite passes again.

```bash
bash patches/mister/build_test_gridbuild.sh
```
Expected with the mutation: `FAIL ... adjacent same-pid tiles MUST NOT merge (got run 2)`.
Expected after restoring: all checks pass.

Record both outputs in your report. A test that does not fail under this mutation is not protecting the format.

- [ ] **Step 6: Register and commit**

Add `bash build_test_gridbuild.sh` to `patches/mister/build_host_tests.sh`, then:

```bash
bash patches/mister/build_host_tests.sh
git add patches/mister/blitter/grid_build.h patches/mister/test_gridbuild.c \
        patches/mister/build_test_gridbuild.sh patches/mister/build_host_tests.sh
git commit -m "feat(blitter): grid builder with horizontal run coalescing

Two passes: paint identity, then derive runs. Runs cannot be computed while
painting because a later tile can truncate an earlier tile's run. Adjacent
instances of the same pattern deliberately do NOT merge."
```

---

### Task 3: `BLT_OP_TILEMAP` opcode, GRID_BUF region, and emitter

**Files:**
- Modify: `patches/mister/blitter/blitter_ref.h` (opcode enum + `BLT_MAXP` neighbourhood)
- Modify: `patches/mister/blitter/blt_emitter.h`, `blt_emitter.c`
- Modify: `patches/mister/mister_blitter_renderer.cpp` (DDR region carve-out)
- Modify: `scripts/tests/test_wire_constants.py`

**Interfaces:**
- Consumes: `grid_cell.h`.
- Produces:
  - `BLT_OP_TILEMAP = 11` in the opcode enum.
  - `void blt_grid_list_init(blt_emitter_t *e, uint32_t buf_off, uint32_t cap);`
  - `int blt_grid_list(blt_emitter_t *e, blt_surface_ref_t tex, uint8_t blend, uint16_t colorkey, uint8_t alpha, uint8_t flags, uint32_t cells_off, uint16_t grid_w, uint16_t grid_h, int16_t bias_x, int16_t bias_y, uint16_t pal_color);`
  - Header field mapping (reusing the 32-byte header verbatim): `w | h<<16` = **grid_w | grid_h<<16** (cells, NOT an entry count); `dst_x | dst_y<<16` = byte offset of the cell array in GRID_BUF; `src_x`/`src_y` = signed bias.

- [ ] **Step 1: Add the opcode**

In `blitter_ref.h`, after `BLT_OP_SPRITELIST = 10`, add `BLT_OP_TILEMAP = 11` with a doc comment giving the full header-field mapping above, in the style of the `BLT_OP_SPRITELIST` block at `:102-112`. **Do not renumber anything.** Opcode 8 stays RESERVED.

- [ ] **Step 2: Carve the GRID_BUF DDR region**

In `mister_blitter_renderer.cpp`, add `OFF_GRIDBUF` / `GRID_BUF_BYTES` constants alongside the existing `OFF_SPBUF` / `SP_BUF_BYTES`. Size it for the worst case in the census: the largest map is 382x282 cells x 3 layers x 4 bytes = **1.23 MiB**; allocate **2 MiB** so two maps' worth of a scroll fit. It must not overlap `TL_BUF`, `SP_BUF`, `FRT`/`CFT`, or `CLUT` — add a `static_assert` proving disjointness, matching the existing region asserts.

- [ ] **Step 3: Implement the emitter**

In `blt_emitter.c`, add `blt_grid_list_init` (mirroring `blt_tile_list_init` at `:345-350`) and `blt_grid_list`. Reuse `tl_emit_header`'s idiom — do NOT write a new header packer:

```c
int blt_grid_list(blt_emitter_t *e, blt_surface_ref_t tex, uint8_t blend,
                  uint16_t colorkey, uint8_t alpha, uint8_t flags,
                  uint32_t cells_off, uint16_t grid_w, uint16_t grid_h,
                  int16_t bias_x, int16_t bias_y, uint16_t pal_color) {
    if (grid_w == 0 || grid_h == 0) return 1;   /* nothing to draw, not an error */
    blt_cmd_t c;
    memset(&c, 0, sizeof c);
    c.opcode = BLT_OP_TILEMAP;
    c.blend  = blend;
    c.format = tex.format;
    c.flags  = flags;
    c.src_off    = tex.off;
    c.src_stride = tex.stride;
    c.w = grid_w;              /* CELLS, not pixels, not an entry count */
    c.h = grid_h;
    c.dst_x = (uint16_t)(cells_off & 0xFFFFu);
    c.dst_y = (uint16_t)(cells_off >> 16);
    c.src_x = bias_x;
    c.src_y = bias_y;
    c.colorkey = colorkey;
    c.alpha    = alpha;
    c.color    = pal_color;
    return emit(e, &c);
}
```

Add matching declarations to `blt_emitter.h` with a doc comment stating the cells-not-pixels meaning of `w`/`h` explicitly — that is the field most likely to be misread.

- [ ] **Step 4: Add an emitter self-test**

In `blt_emitter.c`'s `-DBLT_EMITTER_SELFTEST` block, add `test_blt_grid_static()` modelled on `test_blt_tile_list_res` (`:582`). Assert the packed header round-trips: opcode 11, `w`/`h` carry grid dims, `dst_x|dst_y<<16` reconstructs `cells_off`, and `src_x`/`src_y` carry the signed bias **including negative values** (bias is routinely negative — it is `-camera`).

- [ ] **Step 5: Register the opcode in the wire cross-check**

Edit `scripts/tests/test_wire_constants.py` at all four points the gate requires: the host opcode-name tuple (`:70-71`), the fabric opcode-name tuple (`:131-132`), the `checks` loop tuple (`:158-159`), and a GRID_BUF region base/stride pair modelled on `:145-150` / `:178-181`.

**The fabric side does not exist yet** (B2 adds `OP_TILEMAP` to `blitter_defs.vh`). So either land the `blitter_defs.vh` constant in this task as a **declaration only** — the opcode localparam and `GRID_BUF_QW`, with no FSM logic — or gate the new cross-check until B2. **Prefer landing the constant**: a one-line localparam with no logic is inert, and it keeps host and fabric numbering committed together, which is the entire purpose of this gate.

```bash
python3 scripts/tests/test_wire_constants.py
```
Expected: passes, with the new pair reported.

- [ ] **Step 6: Verify and commit**

```bash
bash patches/mister/build_host_tests.sh
python3 scripts/tests/test_wire_constants.py
g++ -fsyntax-only -std=c++17 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO \
  -I patches/mister -I patches/mister/blitter \
  -I work/solarus/include -I build/armhf/include \
  -I work/solarus/libraries/win32/mingw32/include $(sdl2-config --cflags) \
  patches/mister/mister_blitter_renderer.cpp && echo "SYNTAX OK"
```
All three must pass. Then commit with a message naming the header field mapping.

---

### Task 4: Reference-model executor

The golden model. B2's RTL is validated against this, so it must be the clearest, most literal implementation of the walk — favour obviousness over speed.

**Files:**
- Modify: `patches/mister/blitter/blitter_ref.h` (declare `blt_ref_tilemap`)
- Modify: `patches/mister/blitter/blitter_ref.c` (body + `blt_execute` dispatch)

**Interfaces:**
- Consumes: `grid_cell.h`, the opcode from Task 3.
- Produces: `void blt_ref_tilemap(blt_ctx_t *ctx, const blt_cmd_t *c);`, non-static so host tests can call it directly (mirroring `blt_ref_sprite_list`, `blitter_ref.h:298-300`).

- [ ] **Step 1: Implement the walk**

Add to `blitter_ref.c`, and dispatch it from `blt_execute` alongside the `BLT_OP_SPRITELIST` arm (`:387-397`).

The walk, stated exactly (B2's RTL must match this):
1. Reconstruct `cells_off = c->dst_x | (c->dst_y << 16)`; grid is `c->w` x `c->h` cells.
2. Compute the visible cell window by intersecting the grid (biased by `src_x`/`src_y`) with the framebuffer, so off-screen cells are never fetched. Screen position of cell `(cx, cy)` is `(cx*8 + bias_x, cy*8 + bias_y)`.
3. For each visible row `cy`, walk `cx` left to right:
   - read the cell; if EMPTY, advance by 1 and continue;
   - `run = blt_grid_cell_run(cell)`, clamped so it does not pass the right edge of the visible window;
   - resolve the pattern's source rect via the same pattern table `OP_TILELIST_RES` uses;
   - issue ONE blit of `run*8` x `8` pixels, source at `pattern_src + (sub_x*8, sub_y*8)`, destination `(cx*8 + bias_x, cy*8 + bias_y)`;
   - advance `cx` by `run`.
4. Clip every blit to the framebuffer — a partially visible cell at the window edge must clip, not wrap. **This is the #24 out-of-bounds class**: destination coordinates go through unsigned fields downstream, so a negative destination must be clipped before it is cast, never after.

- [ ] **Step 2: Smoke-test the walk before the full suite**

Task 5 builds the real equivalence gate, but this task must stand on its own. Add a minimal scenario to `patches/mister/build_test_gridcell.sh`'s binary — or a scratch `main` you do not commit — asserting four things on a 2x2 grid holding one 1x1 pattern at cell (1,0), bias `(0,0)`:

1. exactly **one** blit is issued (empty cells issue nothing);
2. its destination is `(8, 0)` — cell index times 8;
3. its size is `8x8`;
4. re-running with `bias = (-8, 0)` moves the destination to `(0, 0)`, and with `bias = (-16, 0)` the blit is culled entirely rather than emitted at a negative destination.

Case 4 is the one that matters: it proves clipping happens **before** the cast to unsigned destination fields. Getting that backwards is the #24 out-of-bounds class, and it is invisible until hardware.

Report the observed destinations. If case 4 emits a blit at a wrapped coordinate such as 65528, stop — the clip is on the wrong side of the cast.

- [ ] **Step 3: Commit**

```bash
git add patches/mister/blitter/blitter_ref.h patches/mister/blitter/blitter_ref.c
git commit -m "feat(blitter): reference-model executor for BLT_OP_TILEMAP

Golden model for the grid walk; B2's RTL is validated against this. Clips
before casting to unsigned destination fields (the #24 OOB class), smoke-
tested with a negative bias that must cull rather than wrap."
```

---

### Task 5: Bit-exact framebuffer equivalence — the acceptance gate

Proves one grid op renders **byte-identically** to the per-tile path it replaces. This is the objective gate the spec asks for (the #24 arena-probe 60/60 pattern).

**Files:**
- Create: `patches/mister/test_tilemap.c`
- Create: `patches/mister/build_test_tilemap.sh`
- Modify: `patches/mister/build_host_tests.sh`

**Interfaces:**
- Consumes: everything from Tasks 1-4.
- Produces: nothing consumed downstream; it is a gate.

- [ ] **Step 1: Write the equivalence test**

Model the structure on `patches/mister/test_spritelist.c` — two static framebuffers, two heaps with **identical texture layout**, execute each, `memcmp` with a first-divergence report.

- **Path A (reference):** the same tiles emitted as individual `OP_BLIT`s, one per tile, in painter's order.
- **Path B (under test):** `blt_grid_build` over the same tiles, then a single `blt_grid_list`.
- **Assertion:** `memcmp(fb_a, fb_b) == 0`.

Cover these cases, each as its own scenario with its own framebuffer pair:
1. **1x1 patterns only** — the simplest walk.
2. **Multi-cell patterns** (3x2, 2x1, 1x3) — exercises sub-offsets and run coalescing. The whole point of the format.
3. **Adjacent same-pattern instances** — must render identically to Path A. If runs wrongly merged, colours bleed and this fails.
4. **Overlapping tiles** (a later tile partially covering an earlier one) so painter's order is observable.
5. **Non-zero bias, both signs** — `bias_x = -13, bias_y = -7`, then `+11, +5`. Negative bias is the normal case (`-camera`).
6. **Window clipping** — a grid larger than the framebuffer with a bias that puts cells off every edge (left, right, top, bottom). Partially visible multi-cell runs at each edge are the highest-risk case in the format.
7. **Empty cells interspersed** — gaps must be skipped, not painted.

- [ ] **Step 2: Build and confirm it passes**

Create `patches/mister/build_test_tilemap.sh` linking the real emitter and reference model:

```bash
#!/usr/bin/env bash
# Stage 3b Phase B1: BLT_OP_TILEMAP framebuffer equivalence vs the per-tile path.
set -euo pipefail
cd "$(dirname "$0")"
cc -std=c99 -Wall -Wextra -Werror -I . -I blitter \
   blitter/blitter_ref.c blitter/blt_emitter.c blitter/blt_alloc.c \
   test_tilemap.c -o /tmp/test_tilemap
/tmp/test_tilemap
echo "== tilemap OK =="
```

```bash
chmod +x patches/mister/build_test_tilemap.sh
bash patches/mister/build_test_tilemap.sh
```
Expected: all scenarios report equivalence.

- [ ] **Step 3: Mutation-check the gate**

A `memcmp` gate that never fails proves nothing. Run these three mutations, one at a time, confirming each is caught, then revert:
1. In `blt_ref_tilemap`, drop the `sub_y*8` term from the source offset → scenario 2 must fail.
2. Clamp the run to 1 → scenario 2 must still PASS (a run of 1 is just the un-coalesced walk, which is equally correct) but the transaction count from Task 6 must rise. **If a scenario fails here instead, the run logic is doing something beyond coalescing and that is a bug.**
3. Remove the right-edge run clamp → scenario 6 must fail.

Record all three outcomes. Mutation 2 is the interesting one: it distinguishes "runs are an optimization" from "runs changed the output", and the format is only correct if runs are purely an optimization.

- [ ] **Step 4: Register and commit**

```bash
bash patches/mister/build_host_tests.sh
git add patches/mister/test_tilemap.c patches/mister/build_test_tilemap.sh \
        patches/mister/build_host_tests.sh
git commit -m "test(blitter): bit-exact FB equivalence, grid op vs per-tile path

7 scenarios incl. both bias signs and clipping on all four edges. Mutation
checked: dropping sub_y, clamping runs, and removing the edge clamp are all
caught, and run coalescing is proven to be purely an optimization."
```

---

### Task 6: Transaction-count instrumentation

Replaces the estimate that motivated run coalescing with a measurement, and hands B2/B3 a number instead of a guess.

**Files:**
- Modify: `patches/mister/blitter/blitter_ref.c` (a counter in the ref walk, behind a compile-time flag)
- Modify: `patches/mister/test_tilemap.c` (report counts per scenario)

**Interfaces:**
- Consumes: Tasks 1-5.
- Produces: a printed per-scenario comparison of Path A blit count vs Path B blit count.

- [ ] **Step 1: Count issues in both paths**

Add a counter incremented once per blit issued, in both the per-tile reference path and the grid walk. Keep it behind `#ifdef BLT_REF_COUNT_ISSUES` so the shipping reference model is unchanged.

- [ ] **Step 2: Report the ratio**

Have `test_tilemap.c` print, per scenario: Path A blits, Path B blits, and the ratio. Assert only that **Path B is not more than 4x Path A** — a loose sanity bound, not a performance gate. The spec is explicit that throughput is not a gate this stage; this number exists so B2/B3 start from a measurement.

- [ ] **Step 3: Record the numbers**

Run the test and record the ratios in the commit message and in `.superpowers/sdd/progress.md`. **These feed directly into B2's design review** — if multi-cell-heavy scenarios show a ratio near 1.0, coalescing is doing its job; a ratio near the cell/tile ratio means it is not.

- [ ] **Step 4: Commit**

```bash
git add patches/mister/blitter/blitter_ref.c patches/mister/test_tilemap.c
git commit -m "test(blitter): count grid-walk vs per-tile blit issues

Replaces the ~3x transaction estimate that motivated run coalescing with a
measurement. Sanity bound only (<=4x); throughput is not a gate this stage."
```

---

## B1 completion

B1 is done when: `build_host_tests.sh` passes including the three new tests, `test_wire_constants.py` passes with the grid opcode and GRID_BUF registered on both sides, the framebuffer-equivalence gate passes all seven scenarios, all mutation checks are confirmed caught, and the transaction ratios are recorded.

**No device, no Quartus, no engine patch is involved in B1.** If any task finds itself needing one, the task has drifted — stop and re-scope.

---

## What comes next (outlines — full plans written after B1 validates the format)

### Phase B2 — `tilemap_unit` RTL and bgplane RTL removal

Implements the same op in fabric, validated in sim against B1's reference model.

- Add `OP_TILEMAP = 8'd11` FSM logic to `blitter_top.sv`, following the `OP_SPRITELIST` template exactly: new fetch/latch states, one select reg, widen `tl_entry_stride` and `tl_next_fetch` (`:383-385`) to four-way, one decode arm, converge on the shared `S_TL_ISSUE`.
- **Two known obstacles, both surfaced during B1 planning:**
  1. **State-encoding budget is tight.** The FSM state is 6-bit and only `6'd62`/`6'd63` remain above the high-water mark; retired slots (`14`, `27-29`, `31`, `40`, `41`) must be reclaimed or the field widened. Decide this before writing states.
  2. **The grid op is the first payload with an implicit destination** (derived from cell index) rather than a per-entry `dst`. Every existing list op adds `res_bias + entry.dst` at latch time; the grid walker needs a cell-index-to-destination computation the others do not have.
- Widen `frt_bram` `MAXP` 128 -> 256 (measured max is 251 distinct patterns, map 3). ~8 M10K blocks against **86 free** — confirm against a real fit report, remembering block memory is 61% by bits but **84% by blocks**, so blocks bind and bit arithmetic understates cost.
- Delete the bgplane RTL in the same build: `fbram_to_sdram.sv`, `bgw_ch0_mux.sv`, `bgplane_coverage.sv`, 85 refs in `blitter_top.sv`, and twelve `tb_bgplane_*` TBs.
- New `fpga/sim/tb_tilemap.sv` — **auto-discovered**, no `run_sims.sh` or workflow registration needed. Model on `tb_spritelist.sv`: assert identical *issue transaction sequences* (order-sensitive; catches reorder/drop/dup) plus identical `comp_fbram` pixels.
- Quartus fit + **seed sweep** + STA against the +0.361 ns blitter-clock baseline. A single build is not evidence — Stage 2's own delta on that clock was non-attributable placement variance. A passing RBF is not evidence of passing timing.

### Phase B3 — engine patches, renderer wiring, hardware gate

- **Two engine patches** (would be `0039`, `0040`; `patches/series.manifest` needs entries too):
  1. Add a `tokens` parameter to `resident_record_static` — mechanically mirroring `resident_record_batch`, which already has exactly this shape.
  2. Forward map `width8`/`height8`. **Cheapest route found:** `NonAnimatedRegions::record_static` already has map dims in scope; `Entities::notify_map_starting` is semantically nicer but has no `Renderer&` and needs new plumbing.
- Wire `TilemapChannel` into `resident_emit_static_layer()` behind `SOLARUS_TILEMAPCH` (**default OFF**) — the same seam Phase A collapsed to bucket replay.
- HW gate: **map 119** (the only map where parallax is load-bearing, 295 entries vs 1 elsewhere) and **map 3** (251 distinct patterns, the case that pins `MAXP`). Operator's eyes; never self-declared.
- Record `tilemap_unit` cyc/px on map 119 — **measured, not gated**.
