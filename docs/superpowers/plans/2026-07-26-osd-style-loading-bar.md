# OSD-Style Loading Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle the `#72` preload progress bar so it reads as a MiSTer OSD — dark tinted box, foreground border, a `Loading...` label and a blocky cell bar — using colours derived from `fpga/sys/osd.v`.

**Architecture:** Pure host-side drawing change. All new branch-worthy logic (cell math, bitmap run extraction) goes into the existing header `patches/mister/loadbar.h`, which is already registered in `scripts/apply_mister_files.sh:22` and already unit-tested by `tests/loadbar_test.c`. The renderer's `emit_loadbar_fills()` is rewritten to consume those helpers and emit `blt_fill` rects. Nothing else changes — `paint_loadbar()`, the drain seam, the `SOLARUS_LOADBAR` gate and the forced repaint every `preload_total/40` assets all stay as they are.

**Tech Stack:** C99 header-only helpers, C++17 renderer, the `blt_fill` emitter API, the repo's existing `tests/run_tests.sh` harness.

**Spec:** `docs/superpowers/specs/2026-07-26-osd-style-loading-bar-design.md`

## Global Constraints

- **Engine-only.** No RTL, no new RBF, no change to `patches/mister/blitter/` (the emitter). Deploy is engine-only.
- **No new header files.** All additions go into the existing `patches/mister/loadbar.h`. Adding a new `patches/mister/*.h` that the renderer `#include`s requires registering it in `scripts/apply_mister_files.sh` or the engine cross-build fails — and neither the local type-check nor the host suite catches it. Avoid the trap entirely by not adding a header.
- **`loadbar.h` must stay free of SDL/Solarus/C++ dependencies.** It is compiled by a C host test (`cc -Wall -Wextra -O2 -I patches/mister`) and included by the C++ renderer. C99, `<stdint.h>` only, all functions `static inline`.
- **Colours are RGB565** (`blt_fill(..., uint16_t color)`).
- **Exact derived colour constants** (from `osd.v:266-268` with `OSD_COLOR = 3'd4`, evaluated over `din = 0`):
  - box background: RGB888 (32, 0, 0) → RGB565 `0x2000`
  - border / label / bar fill: RGB888 (224, 192, 192) → RGB565 `0xE618`
- **Drawing is fills only.** Never `blt_upload` for the label — preload cycles the DDR3 bounce heap via `blt_heap_reset`, so an uploaded bitmap would be invalidated every batch.
- **The visual result is never self-declared correct.** The final gate is the operator's eyes against a real OSD screenshot.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `patches/mister/loadbar.h` | Pure, testable bar math + the `Loading...` bitmap and its run extractor. No I/O, no drawing. | Modify |
| `tests/loadbar_test.c` | Host unit tests for everything in `loadbar.h`. | Modify |
| `patches/mister/mister_blitter_renderer.cpp` | Turns the helpers into `blt_fill` calls. Geometry constants + `emit_loadbar_fills()`. | Modify (`:527-534`, `:1516-1522`) |

`tests/run_tests.sh` needs **no** change — line 132-136 already compiles `tests/loadbar_test.c` with `-I patches/mister`, which picks up the additions automatically.

---

### Task 1: Cell-count math

Replaces `loadbar_fill_w` (continuous pixel width) with `loadbar_cells_filled` (discrete cell count), carrying the existing clamp/floor/guard semantics forward.

**Files:**
- Modify: `patches/mister/loadbar.h`
- Test: `tests/loadbar_test.c`

**Interfaces:**
- Consumes: nothing.
- Produces: `static inline int loadbar_cells_filled(int cells, uint32_t staged, uint32_t total)` — returns how many of `cells` discrete cells are lit. Floors, clamps to `[0, cells]`, returns 0 when `total == 0`.

- [ ] **Step 1: Write the failing tests**

In `tests/loadbar_test.c`, replace the entire body of `main()` (the seven existing `CHECK` lines for `loadbar_fill_w`) with the ported cell-based equivalents:

```c
int main(void)
{
    /* empty: 0 staged -> 0 cells */
    CHECK(loadbar_cells_filled(32, 0, 331) == 0, "0/331 -> 0 cells");
    /* full: staged == total -> every cell */
    CHECK(loadbar_cells_filled(32, 331, 331) == 32, "331/331 -> 32 cells");
    /* half: 165/330 -> 16 cells */
    CHECK(loadbar_cells_filled(32, 165, 330) == 16, "165/330 -> 16 cells");
    /* floor: 1/331 -> 0 (monotonic, never negative) */
    CHECK(loadbar_cells_filled(32, 1, 331) == 0, "1/331 -> 0 cells (floor)");
    /* divide-by-zero guard: total == 0 -> 0 */
    CHECK(loadbar_cells_filled(32, 5, 0) == 0, "total==0 -> 0 cells");
    /* over-count clamp: staged > total -> full (never over-wide) */
    CHECK(loadbar_cells_filled(32, 400, 331) == 32, "400/331 clamp -> 32 cells");
    /* no 32-bit overflow at large counts */
    CHECK(loadbar_cells_filled(32, 3000000u, 6000000u) == 16,
          "3e6/6e6 -> 16 cells (no overflow)");

    if (failures) { printf("loadbar: %d FAILURES\n", failures); return 1; }
    printf("loadbar: all checks passed\n");
    return 0;
}
```

Also update the file's top comment: change `Host unit test for loadbar_fill_w — the pure bar-width math (issue #72).` to `Host unit tests for loadbar.h — cell math and Loading... bitmap runs (issue #72).`

- [ ] **Step 2: Run test to verify it fails**

```bash
cc -Wall -Wextra -O2 -I patches/mister tests/loadbar_test.c -o /tmp/loadbar_test
```

Expected: **compile error**, `implicit declaration of function 'loadbar_cells_filled'` (and, with `-Wall -Wextra`, it will not link).

- [ ] **Step 3: Write minimal implementation**

In `patches/mister/loadbar.h`, replace the `loadbar_fill_w` function with:

```c
/* Number of lit cells for `staged`/`total` progress across a `cells`-cell bar.
 * Clamped to [0, cells]; guards total == 0. Floors, so a cell lights only once
 * its share is fully earned (monotonic, never over-wide). */
static inline int loadbar_cells_filled(int cells, uint32_t staged, uint32_t total)
{
    if (total == 0u || staged == 0u) return 0;
    if (staged >= total)             return cells;
    /* 64-bit product so cells*staged can't overflow at large asset counts. */
    return (int)(((uint64_t)(uint32_t)cells * staged) / total);
}
```

Update the header's top comment block: replace the `loadbar_fill_w:` paragraph with

```c
// loadbar_cells_filled: how many of `cells` discrete bar cells are lit for
// `staged`/`total` progress. Clamped to [0, cells]; guards total == 0.
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cc -Wall -Wextra -O2 -I patches/mister tests/loadbar_test.c -o /tmp/loadbar_test && /tmp/loadbar_test
```

Expected: `loadbar: all checks passed`

- [ ] **Step 5: Commit**

```bash
git add patches/mister/loadbar.h tests/loadbar_test.c
git commit -m "refactor(loadbar): cell-count math replaces continuous fill width

The OSD-style bar is drawn as discrete cells, so the progress math returns a
cell count rather than a pixel width. Same semantics carried forward: floor,
clamp to [0, cells], total==0 guard, 64-bit product against overflow."
```

---

### Task 2: The `Loading...` bitmap and its run extractor

**Files:**
- Modify: `patches/mister/loadbar.h`
- Test: `tests/loadbar_test.c`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `#define LOADBAR_LABEL_W 80` — bitmap width in pixels.
  - `#define LOADBAR_LABEL_H 8` — bitmap height in rows.
  - `#define LOADBAR_LABEL_MAX_RUNS 16` — caller's array must hold at least this many (the densest rows carry 11).
  - `typedef struct { int x0; int len; } loadbar_run_t;`
  - `static inline int loadbar_label_runs(int row, loadbar_run_t *out, int max)` — writes the horizontal runs of set pixels for `row` into `out`, returns the count written. Returns 0 for `row < 0 || row >= LOADBAR_LABEL_H`, for `out == NULL`, or for `max <= 0`. Stops early (returning `max`) if the row has more runs than `max`.

The bitmap is a fixed 1bpp strip of the literal string `Loading...` — ten 8px cells, so each row is exactly 10 bytes and each byte is one character cell, MSB-first (bit 7 = leftmost pixel). Glyphs are 5px wide in the high bits with a 3px gap, cap/ascender height rows 0-6, x-height rows 2-6, baseline row 6, descender row 7 (used only by `g`).

- [ ] **Step 1: Write the failing tests**

Append to `main()` in `tests/loadbar_test.c`, before the `if (failures)` block:

```c
    /* ---- Loading... bitmap run extraction ---- */
    loadbar_run_t runs[LOADBAR_LABEL_MAX_RUNS];

    /* Row 7 is the descender row: only 'g' has ink, 3px at x=49. */
    CHECK(loadbar_label_runs(7, runs, LOADBAR_LABEL_MAX_RUNS) == 1, "row7 -> 1 run");
    CHECK(runs[0].x0 == 49 && runs[0].len == 3, "row7 run = (49,3) g descender");

    /* Row 1: only 'L' stem (x=0) and 'd' ascender (x=28). */
    CHECK(loadbar_label_runs(1, runs, LOADBAR_LABEL_MAX_RUNS) == 2, "row1 -> 2 runs");
    CHECK(runs[0].x0 == 0  && runs[0].len == 1, "row1 run0 = (0,1) L stem");
    CHECK(runs[1].x0 == 28 && runs[1].len == 1, "row1 run1 = (28,1) d ascender");

    /* Row 6 is the baseline: densest row, 11 runs, incl. the three periods. */
    CHECK(loadbar_label_runs(6, runs, LOADBAR_LABEL_MAX_RUNS) == 11, "row6 -> 11 runs");
    CHECK(runs[0].x0 == 0  && runs[0].len == 5, "row6 run0 = (0,5) L foot");
    CHECK(runs[8].x0  == 57 && runs[8].len  == 1, "row6 period 1 at x=57");
    CHECK(runs[9].x0  == 65 && runs[9].len  == 1, "row6 period 2 at x=65");
    CHECK(runs[10].x0 == 73 && runs[10].len == 1, "row6 period 3 at x=73");

    /* Out-of-range rows yield nothing (no OOB read). */
    CHECK(loadbar_label_runs(-1, runs, LOADBAR_LABEL_MAX_RUNS) == 0, "row -1 -> 0");
    CHECK(loadbar_label_runs(LOADBAR_LABEL_H, runs, LOADBAR_LABEL_MAX_RUNS) == 0,
          "row H -> 0");

    /* Defensive guards: null out, non-positive max. */
    CHECK(loadbar_label_runs(6, NULL, LOADBAR_LABEL_MAX_RUNS) == 0, "null out -> 0");
    CHECK(loadbar_label_runs(6, runs, 0) == 0, "max 0 -> 0");

    /* max clamps rather than overflowing the caller's array. */
    CHECK(loadbar_label_runs(6, runs, 3) == 3, "row6 with max=3 -> 3 runs");

    /* Every row's run count fits the advertised bound. */
    for (int r = 0; r < LOADBAR_LABEL_H; r++)
        CHECK(loadbar_label_runs(r, runs, LOADBAR_LABEL_MAX_RUNS) <= LOADBAR_LABEL_MAX_RUNS,
              "row run count within LOADBAR_LABEL_MAX_RUNS");
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cc -Wall -Wextra -O2 -I patches/mister tests/loadbar_test.c -o /tmp/loadbar_test
```

Expected: **compile error**, `unknown type name 'loadbar_run_t'` / `'LOADBAR_LABEL_MAX_RUNS' undeclared`.

- [ ] **Step 3: Write minimal implementation**

Append inside the include guard in `patches/mister/loadbar.h`, before `#endif`:

```c
/* ---- "Loading..." label bitmap (1bpp) -------------------------------------
 * A fixed strip, not a font: the string never changes, so there is no glyph
 * indexing. Ten 8px character cells => each row is exactly 10 bytes and each
 * byte is one cell, MSB-first (bit 7 = leftmost pixel). Glyphs are 5px wide in
 * the high bits with a 3px gap. Cap/ascender rows 0-6, x-height rows 2-6,
 * baseline row 6, descender row 7 (only 'g' uses it).
 *
 * Authored in the OSD's blocky idiom; NOT a copy of Main_MiSTer's charfont
 * glyphs, which are not available in this repo.
 *
 *   cell:   0 'L'  1 'o'  2 'a'  3 'd'  4 'i'  5 'n'  6 'g'  7-9 '.'
 *
 * The table below renders as (verified by expanding the bits):
 *
 *   #...........................#.....#.............................................
 *   #...........................#...................................................
 *   #........###.....###.....####.....#.....#.##.....####...........................
 *   #.......#...#.......#...#...#.....#.....##..#...#...#...........................
 *   #.......#...#....####...#...#.....#.....#...#...#...#...........................
 *   #.......#...#...#...#...#...#.....#.....#...#....####...........................
 *   #####....###.....####....####.....#.....#...#.......#....#.......#.......#......
 *   .................................................###............................
 */
#define LOADBAR_LABEL_W        80
#define LOADBAR_LABEL_H         8
#define LOADBAR_LABEL_BYTES    10   /* LOADBAR_LABEL_W / 8 */
/* The densest rows (3-6) carry 11 runs; 16 gives headroom. */
#define LOADBAR_LABEL_MAX_RUNS 16

typedef struct { int x0; int len; } loadbar_run_t;

static const uint8_t loadbar_label_bits[LOADBAR_LABEL_H][LOADBAR_LABEL_BYTES] = {
    /*        L     o     a     d     i     n     g     .     .     .   */
    /* 0 */ { 0x80, 0x00, 0x00, 0x08, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00 },
    /* 1 */ { 0x80, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    /* 2 */ { 0x80, 0x70, 0x70, 0x78, 0x20, 0xB0, 0x78, 0x00, 0x00, 0x00 },
    /* 3 */ { 0x80, 0x88, 0x08, 0x88, 0x20, 0xC8, 0x88, 0x00, 0x00, 0x00 },
    /* 4 */ { 0x80, 0x88, 0x78, 0x88, 0x20, 0x88, 0x88, 0x00, 0x00, 0x00 },
    /* 5 */ { 0x80, 0x88, 0x88, 0x88, 0x20, 0x88, 0x78, 0x00, 0x00, 0x00 },
    /* 6 */ { 0xF8, 0x70, 0x78, 0x78, 0x20, 0x88, 0x08, 0x40, 0x40, 0x40 },
    /* 7 */ { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x70, 0x00, 0x00, 0x00 },
};

/* Extract the horizontal runs of set pixels in `row` into `out` (at most `max`).
 * Returns the number written. A flat column scan, so runs spanning a byte
 * boundary are joined correctly. Returns 0 for an out-of-range row, a NULL
 * `out`, or a non-positive `max`. */
static inline int loadbar_label_runs(int row, loadbar_run_t *out, int max)
{
    int n = 0, x = 0, run_x0 = 0, in_run = 0;

    if (row < 0 || row >= LOADBAR_LABEL_H || out == 0 || max <= 0) return 0;

    for (x = 0; x < LOADBAR_LABEL_W; x++) {
        int bit = (loadbar_label_bits[row][x >> 3] >> (7 - (x & 7))) & 1;
        if (bit && !in_run) { in_run = 1; run_x0 = x; }
        else if (!bit && in_run) {
            in_run = 0;
            out[n].x0 = run_x0; out[n].len = x - run_x0;
            if (++n >= max) return n;
        }
    }
    if (in_run) {   /* run reaching the right edge */
        out[n].x0 = run_x0; out[n].len = LOADBAR_LABEL_W - run_x0;
        n++;
    }
    return n;
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cc -Wall -Wextra -O2 -I patches/mister tests/loadbar_test.c -o /tmp/loadbar_test && /tmp/loadbar_test
```

Expected: `loadbar: all checks passed`

- [ ] **Step 5: Commit**

```bash
git add patches/mister/loadbar.h tests/loadbar_test.c
git commit -m "feat(loadbar): 1bpp Loading... bitmap + per-row run extractor

A fixed strip rather than a font — the string never changes, so ten 8px cells
means one byte per character per row. loadbar_label_runs() flattens a row into
horizontal runs the renderer emits as blt_fill rects (no upload: preload cycles
the DDR3 bounce heap via blt_heap_reset)."
```

---

### Task 3: Renderer — OSD palette, geometry and drawing

One task, one commit: the constants and the drawing that consumes them are
halves of a single edit, and a commit carrying only the constants would not
build. Every commit on this branch compiles.

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp:527-534` (geometry block)
- Modify: `patches/mister/mister_blitter_renderer.cpp:1516-1522` (`emit_loadbar_fills`)

**Interfaces:**
- Consumes: `FB_W`, `FB_H` (`:525`); `loadbar_cells_filled` (Task 1);
  `loadbar_label_runs`, `loadbar_run_t`, `LOADBAR_LABEL_W`, `LOADBAR_LABEL_H`,
  `LOADBAR_LABEL_MAX_RUNS` (Task 2); the existing members `loadbar_on`,
  `preload_staged`, `preload_total`, `em`.
- Produces: nothing consumed by later tasks.

`paint_loadbar()` (`:1526-1531`), the drain seam, the `SOLARUS_LOADBAR` gate and
the forced repaint every `preload_total/40` assets are **not** modified.

- [ ] **Step 1: Confirm `loadbar.h` is already included**

```bash
rg -n '#include "loadbar.h"' patches/mister/mister_blitter_renderer.cpp
```

Expected: one hit. If there is no hit, add `#include "loadbar.h"` alongside the other `patches/mister` includes near the top of the file. Do **not** create a new header.

- [ ] **Step 2: Replace the geometry block**

Replace `mister_blitter_renderer.cpp:527-534` (the comment line `// [#72] Load-progress bar geometry ...` through `static const uint16_t LOADBAR_FILL = 0xFFFF; ...`) with:

```cpp
// [#72] Load-progress bar geometry (RGB565), restyled to the MiSTer OSD's visual
// language. Colours are DERIVED, not chosen: fpga/sys/osd.v:266-268 blends
//   R = {osd_pixel, osd_pixel, OSD_COLOR[2], din[23:19]}   (G/B likewise)
// and sys_top.v:1190 instantiates it with no override, so OSD_COLOR = 3'd4.
// Over a black background (din = 0, which is what a loading screen is):
//   osd_pixel=0 -> RGB(32,0,0)      -> 0x2000   (box background)
//   osd_pixel=1 -> RGB(224,192,192) -> 0xE618   (border/label/cells)
// 3'd4 == 3'b100 puts the tint bit on RED, so the OSD is a dark red-tinted box
// with warm off-white content — not the blue-grey it is often remembered as.
// The OSD is 1bpp, so these two colours are the whole palette.
static const uint16_t LOADBAR_BG     = 0x0000;   // full-screen clear (black)
static const uint16_t LOADBAR_BOX_BG = 0x2000;   // OSD box interior
static const uint16_t LOADBAR_FG     = 0xE618;   // border, label, filled cells

// osd_buffer is 256x64, but it composites in OUTPUT space with multiscan
// scaling, so it does NOT map 1:1 onto this 320x240 FB. 256x64 centred is the
// starting point; final size is settled by screenshot comparison against a real
// OSD capture (see the spec's Risks section).
static const int LOADBAR_BOX_W = 256;
static const int LOADBAR_BOX_H = 64;
static const int LOADBAR_BOX_X = (FB_W - LOADBAR_BOX_W) / 2;   // 32
static const int LOADBAR_BOX_Y = (FB_H - LOADBAR_BOX_H) / 2;   // 88

// "Loading..." label: LOADBAR_LABEL_W x LOADBAR_LABEL_H (80x8) from loadbar.h,
// drawn at 2x (160x16) and centred in the box's upper half.
static const int LOADBAR_LABEL_SCALE = 2;
static const int LOADBAR_LABEL_X =
    LOADBAR_BOX_X + (LOADBAR_BOX_W - LOADBAR_LABEL_W * LOADBAR_LABEL_SCALE) / 2;  // 80
static const int LOADBAR_LABEL_Y = LOADBAR_BOX_Y + 12;                            // 100

// Blocky cell bar — the most recognisable OSD element, and what a 1bpp overlay
// forces anyway. 32 cells x (6px + 1px gap) - 1 = 223px inside a 224px track
// (box inset 16px each side). 32 cells sits below the ~40-update repaint
// granularity (preload_total/40), so cells advance one at a time.
static const int LOADBAR_CELLS    = 32;
static const int LOADBAR_CELL_W   = 6;
static const int LOADBAR_CELL_GAP = 1;
static const int LOADBAR_CELL_H   = 10;
static const int LOADBAR_TRACK_X  = LOADBAR_BOX_X + 16;                      // 48
static const int LOADBAR_TRACK_Y  = LOADBAR_BOX_Y + LOADBAR_BOX_H - 22;      // 130
```

- [ ] **Step 3: Rewrite `emit_loadbar_fills`**

Replace the function at `:1516-1522` (its doc comment through its closing brace) with:

```cpp
  // [#72] Emit the OSD-style bar into the CURRENTLY-OPEN frame (no begin/submit).
  // Full-screen bg fill first, so each frame is self-contained (idempotent)
  // regardless of WORK persistence; then the box, border, label and cells.
  // Fills only — never blt_upload: preload cycles the DDR3 bounce heap via
  // blt_heap_reset, so an uploaded label would be invalidated every batch.
  void emit_loadbar_fills() {
    if (!loadbar_on) return;

    // Screen clear, then the OSD box with a 1px foreground border (drawn as a
    // filled FG rect with the interior painted back over it).
    blt_fill(&em, 0, 0, FB_W, FB_H, LOADBAR_BG);
    blt_fill(&em, LOADBAR_BOX_X, LOADBAR_BOX_Y,
             LOADBAR_BOX_W, LOADBAR_BOX_H, LOADBAR_FG);
    blt_fill(&em, LOADBAR_BOX_X + 1, LOADBAR_BOX_Y + 1,
             LOADBAR_BOX_W - 2, LOADBAR_BOX_H - 2, LOADBAR_BOX_BG);

    // "Loading..." — one blt_fill per horizontal run per row, scaled up by
    // multiplying the run coordinates (scaling is free in fill-space).
    for (int row = 0; row < LOADBAR_LABEL_H; row++) {
      loadbar_run_t runs[LOADBAR_LABEL_MAX_RUNS];
      int n = loadbar_label_runs(row, runs, LOADBAR_LABEL_MAX_RUNS);
      for (int i = 0; i < n; i++)
        blt_fill(&em,
                 LOADBAR_LABEL_X + runs[i].x0 * LOADBAR_LABEL_SCALE,
                 LOADBAR_LABEL_Y + row        * LOADBAR_LABEL_SCALE,
                 runs[i].len * LOADBAR_LABEL_SCALE,
                 LOADBAR_LABEL_SCALE,
                 LOADBAR_FG);
    }

    // Cell bar: lit cells are solid FG blocks, unlit cells are a 1px FG outline
    // over the box background — the two-tone discipline a 1bpp overlay forces.
    const int lit = loadbar_cells_filled(LOADBAR_CELLS, preload_staged, preload_total);
    for (int c = 0; c < LOADBAR_CELLS; c++) {
      const int cx = LOADBAR_TRACK_X + c * (LOADBAR_CELL_W + LOADBAR_CELL_GAP);
      blt_fill(&em, cx, LOADBAR_TRACK_Y, LOADBAR_CELL_W, LOADBAR_CELL_H, LOADBAR_FG);
      if (c >= lit)   // unlit: punch the interior back out, leaving a 1px outline
        blt_fill(&em, cx + 1, LOADBAR_TRACK_Y + 1,
                 LOADBAR_CELL_W - 2, LOADBAR_CELL_H - 2, LOADBAR_BOX_BG);
    }
  }
```

- [ ] **Step 4: Verify the renderer type-checks**

```bash
g++ -fsyntax-only -std=c++17 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO \
  -I patches/mister -I patches/mister/blitter -I work/solarus/include \
  -I build/armhf/include -I work/solarus/libraries/win32/mingw32/include \
  $(sdl2-config --cflags) patches/mister/mister_blitter_renderer.cpp
```

Expected: **no output** (clean).

- [ ] **Step 5: Confirm no stale references remain**

```bash
rg -n "loadbar_fill_w|LOADBAR_TRACK_W|LOADBAR_TRACK_H|LOADBAR_FILL\b" \
   patches/mister/ tests/
```

Expected: **no matches**. Any hit is a leftover from the old bar — remove it.

- [ ] **Step 6: Run the full host suite**

```bash
bash tests/run_tests.sh
```

Expected: every section passes, including `== loadbar (issue #72 progress-bar width math) ==` → `loadbar: all checks passed`.

- [ ] **Step 7: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "feat(loadbar): OSD-style box, Loading... label and cell bar

Colours computed from osd.v's blend formula with OSD_COLOR=3'd4 over a black
background, not picked by eye. Geometry is a 256x64 centred box with a 32-cell
bar. emit_loadbar_fills() paints the bordered box, the Loading... strip as
per-row fill runs at 2x, and the cells (lit = solid FG, unlit = FG outline over
box background). Fills only, so nothing touches the DDR3 bounce heap that
preload is cycling."
```

---

### Task 4: Engine build, deploy and the operator visual gate

The local type-check passes `-I patches/mister`, so it cannot prove the engine cross-build works. Only the cross-build sees the real tree. This task is not optional.

**Files:** none modified.

**Interfaces:** none.

- [ ] **Step 1: Cross-build the engine**

```bash
scripts/docker_run.sh scripts/build_engine.sh
```

Expected: build succeeds, producing `build/armhf/solarus-run` and `build/armhf/libsolarus.so.1.6.5`.

If this fails with `loadbar.h: No such file or directory`, the header lost its registration — re-check `scripts/apply_mister_files.sh:22`.

- [ ] **Step 2: Refresh `deploy/` and push**

`deploy.py` ships from `deploy/`, not `build/armhf`, so a stale `deploy/` silently ships the old engine.

```bash
./deploy.py --no-rbf --host 192.168.20.81
```

Expected: sha1 verification passes for the uploaded binary. `--no-rbf` is correct here — this change is engine-only.

- [ ] **Step 3: Launch and capture the loading screen**

Launch the quest, then during preload:

```bash
ssh root@192.168.20.81 'echo screenshot > /dev/MiSTer_cmd; sleep 1; \
  ls -t /media/fat/screenshots/Solarus/*.png | head -1'
```

Fetch the newest capture with `scp`. Preload is brief, so expect to retry the capture a few times to land mid-load; the `paint_loadbar()` call for the initial 0% frame gives an early target.

- [ ] **Step 4: Operator visual gate**

Present the capture to the user alongside a real MiSTer OSD screenshot for comparison. **Do not declare the result correct.** The user judges:

1. Does the box read as a MiSTer OSD (dark tinted panel, warm off-white content)?
2. Is `Loading...` legible at 2× on their display?
3. Does the cell bar advance visibly and monotonically across the load?
4. Is the box size/position right, or does it need the tuning pass the spec anticipates?

Expect iteration on box geometry — the OSD composites in output space, so a first-try match is unlikely. If the red tint reads wrong, `LOADBAR_BOX_BG` and `LOADBAR_FG` are the two constants to change.

- [ ] **Step 5: Record the outcome**

Once the user passes the gate, write `docs/superpowers/2026-07-26-osd-loadbar-hw-validation.md` recording: the flags used, the screenshot path, the user's verdict on each of the four questions above, and any geometry constants changed during tuning. Commit it.

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| Palette derived from `osd.v` (`0x2000` / `0xE618`) | 3 |
| 256×64 centred box, 1px FG border | 3 |
| `Loading...` as a 1bpp strip, not a font | 2 |
| Drawn as per-row fill runs, never `blt_upload` | 2, 3 |
| 2× label scale | 3 |
| 32 cells × 6px + 1px gap = 223px in a 224px track | 3 |
| `loadbar_cells_filled` replaces `loadbar_fill_w`, semantics carried forward | 1 |
| `loadbar_label_runs` with bounds/null/max guards | 2 |
| Existing `loadbar_fill_w` test cases ported across | 1 |
| No new header; `loadbar.h` already registered | Global Constraints, 3 (Step 1) |
| `emit_loadbar_fills` rewritten; `paint_loadbar`, drain seam, gate untouched | 3 |
| Host suite + type-check with both `-D` flags | 3 |
| Engine cross-build (local type-check insufficient) | 4 |
| Operator visual gate, never self-declared | 4 |
| Geometry tuning anticipated | 4 (Step 4) |

No gaps.

**Placeholder scan:** No TBD/TODO, no "handle edge cases", no "similar to Task N". Every code step carries complete code; every command carries expected output.

**Type consistency:** `loadbar_cells_filled(int, uint32_t, uint32_t) -> int` is defined in Task 1 and called with `(LOADBAR_CELLS, preload_staged, preload_total)` in Task 4 — `preload_staged`/`preload_total` are `uint32_t` (`:1187-1188`). `loadbar_label_runs(int, loadbar_run_t*, int) -> int` is defined in Task 2 and called identically in Task 4. `LOADBAR_LABEL_W/H/MAX_RUNS` and `loadbar_run_t` are defined in Task 2 and used in Tasks 3 and 4 under the same names. `LOADBAR_BG` is the only constant surviving from the old block and keeps its meaning and value.

**Deliberate non-obvious choice:** Tasks 3 and 4 of the original draft were merged into one renderer task, so every commit on this branch builds. Task numbering is therefore 1-4, not 1-5.
