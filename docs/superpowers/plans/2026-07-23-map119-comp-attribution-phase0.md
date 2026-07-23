# Map 119 comp attribution — Phase 0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the instruments that attribute map 119's compositor cost (`comp` ≈ 14.9ms) into ranked slices — `{overlay-PALPHA, tilemap-empty-walk, tilemap-resolve, tilemap-pixels, sprite}` — so Phase 1 can cull the biggest confirmed slice. No RBF; all instruments are engine-only + a fabric-sim calibration.

**Architecture:** Three measurements feed one attribution. (1) A default-off engine probe `SOLARUS_OVERLAYNOCOMP` skips the final full-screen PALPHA overlay blit so a standing map-119 A/B reads the overlay's `Δcomp` directly. (2) A default-off engine dump `SOLARUS_GRIDSTATS` walks the built tilemap grid over the fabric's visible cell window and prints empty-cell / run counts, via a pure host-tested helper `blt_grid_stats()`. (3) `tb_tilemap` gains per-FSM-state cycle counters to calibrate cycles-per-empty-cell and cycles-per-run. An offline script `comp_attribution.py` combines the three into the ranked breakdown.

**Tech Stack:** C++17 renderer (`patches/mister/mister_blitter_renderer.cpp`, whole-file copy — edit directly), C99 blitter headers + gcc host tests (`patches/mister/blitter/`, `tests/`), SystemVerilog + iverilog (`fpga/sim/tb_tilemap.sv`), Python 3 offline analyzer (`scripts/perf/`).

## Global Constraints

- **Env-flag convention:** every new probe is default-OFF, enabled with `SOLARUS_<FLAG>=1`, read ONCE via the existing `mister_flag_default_off("SOLARUS_<FLAG>")` helper (`mister_blitter_renderer.cpp:112`) cached into a file-scope `static bool` set in the ctor (`~line 2434`, beside `g_comptrace_on`). Unset (or any value not starting with `1`) → OFF → true no-op. Never call `getenv` on a hot path.
- **Renderer is a whole-file copy** — `patches/mister/mister_blitter_renderer.cpp` is NOT in `patches/series/`; edit it directly, nothing to regenerate.
- **Renderer is NOT compiled by the host test suite.** `bash tests/run_tests.sh` compiles only `patches/mister/blitter/` logic. Renderer edits (Tasks 1, 3) are verified by the native syntax-check recipe below; only extractable pure logic (Task 2 helper, Task 5 script) gets unit tests.
- **Native renderer syntax-check recipe** (BOTH `-D` flags mandatory — omitting them type-checks almost nothing):
  ```
  g++ -fsyntax-only -std=c++17 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO \
    -I patches/mister -I patches/mister/blitter -I work/solarus/include \
    -I build/armhf/include -I work/solarus/libraries/win32/mingw32/include \
    $(sdl2-config --cflags) patches/mister/mister_blitter_renderer.cpp
  ```
- **Fabric cell walk semantics** (mirror exactly in `blt_grid_stats`, from `fpga/rtl/blitter_top.sv:1171-1220`): EMPTY cell → advance one column (counts one empty fetch, no run); non-empty cell → read run = `blt_grid_cell_run(c)`, clamp `run = (cx+run > cx1) ? (cx1-cx) : run`, count ONE run + `run` cells, advance `cx += run`. Intermediate run cells are NOT re-read. At `cx >= cx1`, advance to the next row.
- **Cell accessors** (`patches/mister/blitter/grid_cell.h`): `blt_grid_cell_pid(c)`, `blt_grid_cell_run(c)` (returns run_m1+1, range 1..16), `blt_grid_cell_is_empty(c)` / `BLT_GRID_PID_EMPTY`.
- **Ship RBF for all HW captures:** `Solarus_20260723.rbf`. Single-engine launch discipline (kill daemons + prior `solarus-run` first; log under `/media/fat/logs`). Build via host-apply + `SOLARUS_SKIP_APPLY=1` Docker compile; refresh `deploy/` from `build/armhf` before `deploy.py --no-rbf`; verify the new symbol + mtime in the built lib.
- **Do not self-declare visual correctness** — any "HUD still looks right" claim needs the operator's eyes (memory `solarus-no-self-declared-visual-validation`).

---

## Task 1: Overlay-off probe (`SOLARUS_OVERLAYNOCOMP`)

Skip ONLY the final full-screen PALPHA overlay blit so a standing A/B reads the overlay's comp cost. Everything else (upload, digest logic, COMP_END disarm) stays identical, so `Δcomp` attributes the overlay and nothing else.

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` (flag decl ~line 145 area; ctor parse ~line 2434; guard in `emit_overlay_composite()` at line 1519)

**Interfaces:**
- Produces: file-scope `static bool g_overlaynocomp_on` (read by `emit_overlay_composite`); env flag `SOLARUS_OVERLAYNOCOMP`.

- [ ] **Step 1: Add the cached flag declaration.** Beside `g_comptrace_on` (line 145):

```cpp
static bool g_comptrace_on  = false;   // cached getenv presence (set in ctor)
static int  g_comptrace_arm = 0;       // 0 = idle, 1 = capturing this frame
static bool g_overlaynocomp_on = false; // [Phase0] SOLARUS_OVERLAYNOCOMP: skip the final PALPHA overlay blit (A/B for overlay comp cost)
```

- [ ] **Step 2: Parse it in the ctor.** Beside line 2434:

```cpp
  g_comptrace_on  = mister_flag_default_off("SOLARUS_COMPTRACE");   // [map119] overdraw attribution
  g_overlaynocomp_on = mister_flag_default_off("SOLARUS_OVERLAYNOCOMP"); // [Phase0] overlay comp-cost A/B
```

- [ ] **Step 3: Guard the PALPHA blit.** In `emit_overlay_composite()`, replace line 1519 so the composite blit is skipped when the probe is on. The upload above and the COMP_END disarm below stay — only the fabric composite is removed:

```cpp
    // [Phase0] SOLARUS_OVERLAYNOCOMP skips ONLY the fabric composite (HUD vanishes) so a
    // standing A/B's Δcomp = the overlay's per-frame full-screen PALPHA cost. Upload +
    // digest logic above and COMP_END disarm below are unchanged.
    if (!g_overlaynocomp_on)
      blt_blit(&em, ref, 0, 0, FB_W, FB_H, 0, 0, BLT_BLEND_PALPHA, 0, 255, 0);
    if (diag) g_overlay_blits++;
```

- [ ] **Step 4: Native syntax-check.** Run the recipe from Global Constraints.
Expected: exits 0, no errors. (If `work/solarus/include` is absent, run `scripts/apply_patch_series.sh` first.)

- [ ] **Step 5: Confirm no-op-when-unset by inspection.** `g_overlaynocomp_on` defaults `false`; the ctor sets it only when `SOLARUS_OVERLAYNOCOMP=1`; the guard is `if (!g_overlaynocomp_on) blt_blit(...)`. Unset → blit always emitted → byte-identical to today. Record this reasoning in the commit message (no host test possible — the renderer isn't host-compiled, same as the `SOLARUS_BGFILLPROBE` gate).

- [ ] **Step 6: Commit.**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "perf(map119): SOLARUS_OVERLAYNOCOMP probe — skip final PALPHA overlay blit for comp-cost A/B"
```

---

## Task 2: `blt_grid_stats()` helper + host test

Pure logic that walks a grid cell window exactly as the fabric does and counts empty cells + coalesced runs. Host-tested against hand-computed grids. This is the testable core of the grid-stats dump.

**Files:**
- Create: `patches/mister/blitter/grid_stats.h`
- Create: `tests/grid_stats_test.c`
- Modify: `tests/run_tests.sh` (add the compile+run block)

**Interfaces:**
- Consumes: `blt_grid_cell_t`, `blt_grid_cell_pid/run/is_empty`, `BLT_GRID_PID_EMPTY` (`grid_cell.h`).
- Produces:
  ```c
  typedef struct {
      uint32_t nonempty_cells;   // real-pid cells inside the window (== sum of run lengths)
      uint32_t empty_cells;      // EMPTY cells the walker fetch+decodes (window-local)
      uint32_t runs;             // coalesced non-empty runs == fabric blit count
      uint32_t run_hist[17];     // run-length histogram; index 1..16 used, [0] always 0
  } blt_grid_stats_t;
  void blt_grid_stats(const blt_grid_cell_t* cells, uint16_t grid_w,
                      uint16_t cx0, uint16_t cx1, uint16_t cy0, uint16_t cy1,
                      blt_grid_stats_t* out);
  ```

- [ ] **Step 1: Write the failing test** — `tests/grid_stats_test.c`:

```c
#include "grid_stats.h"
#include "grid_cell.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

/* 5-wide grid. Row 0: [run3 pid=7][run3 pid=7][run3 pid=7][EMPTY][EMPTY]
 * i.e. a 3-cell run of pid 7 (run_m1 = 2,1,0) then two empties.
 * Row 1: all EMPTY. Window = whole 5x2. */
static blt_grid_cell_t grid_5x2[10];

static void build(void) {
    for (int i = 0; i < 10; i++) grid_5x2[i] = blt_grid_cell_pack(BLT_GRID_PID_EMPTY,0,0,0);
    grid_5x2[0] = blt_grid_cell_pack(7,0,0,2); /* run_m1=2 -> run 3 */
    grid_5x2[1] = blt_grid_cell_pack(7,1,0,1);
    grid_5x2[2] = blt_grid_cell_pack(7,2,0,0);
}

int main(void) {
    build();
    blt_grid_stats_t s;
    blt_grid_stats(grid_5x2, /*grid_w=*/5, /*cx0=*/0,/*cx1=*/5, /*cy0=*/0,/*cy1=*/2, &s);
    /* one 3-run in row0 (+2 empties), whole row1 empty (5 empties) */
    assert(s.runs == 1);
    assert(s.nonempty_cells == 3);
    assert(s.empty_cells == 7);
    assert(s.run_hist[3] == 1);
    assert(s.run_hist[1] == 0 && s.run_hist[2] == 0);

    /* Window right-edge clamp: same grid, window cx1=2 cuts the 3-run to 2. */
    blt_grid_stats_t c;
    blt_grid_stats(grid_5x2, 5, 0,2, 0,1, &c);
    assert(c.runs == 1);
    assert(c.nonempty_cells == 2);   /* run clamped 3 -> 2 */
    assert(c.run_hist[2] == 1 && c.run_hist[3] == 0);
    assert(c.empty_cells == 0);

    /* All-empty window. */
    blt_grid_stats_t e;
    blt_grid_stats(grid_5x2, 5, 0,5, 1,2, &e);
    assert(e.runs == 0 && e.nonempty_cells == 0 && e.empty_cells == 5);

    printf("grid_stats_test PASS\n");
    return 0;
}
```

- [ ] **Step 2: Add the compile+run block to `tests/run_tests.sh`** (mirror the `bgfill_probe_test` block at line ~19):

```sh
echo "== grid_stats_test =="
$CC -Wall -Wextra -O2 -I patches/mister/blitter \
    tests/grid_stats_test.c \
    -o "$TMP/grid_stats_test" && "$TMP/grid_stats_test"
```
(Match the exact `$CC`/`$TMP` variable names already used in the file.)

- [ ] **Step 3: Run to verify it fails.**
Run: `bash tests/run_tests.sh 2>&1 | sed -n '/grid_stats/,+3p'`
Expected: FAIL — `grid_stats.h: No such file or directory`.

- [ ] **Step 4: Write `patches/mister/blitter/grid_stats.h`:**

```c
#ifndef BLT_GRID_STATS_H
#define BLT_GRID_STATS_H
#include <stdint.h>
#include <string.h>
#include "grid_cell.h"

/* Walk the cell window [cx0,cx1) x [cy0,cy1) of a grid_w-wide cell array EXACTLY as
 * blitter_top.sv's grid walker (S_GRID_DECODE / g_run clamp, blitter_top.sv:1171-1220):
 *   EMPTY  -> advance one column, count one empty fetch.
 *   run    -> run = blt_grid_cell_run(cell), clamp to window right edge, count one run
 *             + run cells, advance cx by run (intermediate cells NOT re-read).
 * So `runs` == the fabric's blit count and `empty_cells` == its empty-fetch count over
 * the visible window — the two inputs the Phase-0 cost model scales. */
typedef struct {
    uint32_t nonempty_cells;
    uint32_t empty_cells;
    uint32_t runs;
    uint32_t run_hist[17];
} blt_grid_stats_t;

static inline void blt_grid_stats(const blt_grid_cell_t* cells, uint16_t grid_w,
                                  uint16_t cx0, uint16_t cx1, uint16_t cy0, uint16_t cy1,
                                  blt_grid_stats_t* out) {
    memset(out, 0, sizeof(*out));
    for (uint16_t cy = cy0; cy < cy1; ++cy) {
        uint32_t row = (uint32_t)cy * grid_w;
        uint16_t cx = cx0;
        while (cx < cx1) {
            blt_grid_cell_t c = cells[row + cx];
            if (blt_grid_cell_is_empty(c)) {
                out->empty_cells++;
                cx++;
            } else {
                uint16_t run = blt_grid_cell_run(c);           /* 1..16 */
                if ((uint32_t)cx + run > cx1) run = cx1 - cx;  /* window clamp */
                out->runs++;
                out->nonempty_cells += run;
                if (run <= 16) out->run_hist[run]++;
                cx += run;
            }
        }
    }
}
#endif /* BLT_GRID_STATS_H */
```

- [ ] **Step 5: Run to verify it passes.**
Run: `bash tests/run_tests.sh 2>&1 | grep grid_stats`
Expected: `grid_stats_test PASS`.

- [ ] **Step 6: Commit.**

```bash
git add patches/mister/blitter/grid_stats.h tests/grid_stats_test.c tests/run_tests.sh
git commit -m "test(map119): blt_grid_stats — fabric-faithful empty/run counter for comp attribution"
```

---

## Task 3: Wire the grid-stats dump into the engine (`SOLARUS_GRIDSTATS`)

Call `blt_grid_stats` over the fabric's visible cell window for each built bucket and print one line per bucket. Default-off.

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` (include grid_stats.h ~line 31; flag decl + ctor parse as Task 1; dump after a bucket's grid is built, in the `for (auto& b : d->res_static_buckets)` loop, after `blt_grid_build_ov(...) == 0` succeeds, ~line 3316)

**Interfaces:**
- Consumes: `blt_grid_stats()` (Task 2), `d->grid_scratch` (the built gw×gh cell array), `mister_camera_x/y()`, `g_map_w8`/`g_map_h8`, `FB_W`/`FB_H`, the bucket's `scroll_ratio`.
- Produces: env flag `SOLARUS_GRIDSTATS`; stderr lines `GRIDSTATS layer=<L> ratio=<r> win=<cx0>,<cy0>-<cx1>,<cy1> nonempty=<n> empty=<e> runs=<r> hist=<c1>,<c2>,...,<c16>`.

- [ ] **Step 1: Include the helper.** Beside line 31:

```cpp
#include "blitter/grid_alloc.h"      // [Stage 3b B3] GRID_BUF bump allocator
#include "blitter/grid_stats.h"      // [Phase0] SOLARUS_GRIDSTATS empty/run attribution
```

- [ ] **Step 2: Add the cached flag** (decl beside `g_overlaynocomp_on`; ctor parse beside it):

```cpp
static bool g_gridstats_on = false;    // [Phase0] SOLARUS_GRIDSTATS: dump per-bucket empty/run counts
```
```cpp
  g_gridstats_on = mister_flag_default_off("SOLARUS_GRIDSTATS");   // [Phase0] tilemap walk attribution
```

- [ ] **Step 3: Dump after a successful grid build.** In the bucket loop, immediately after the `blt_grid_build_ov(...) != 0` bounds check passes (line 3316, before the `overlapped` handling), add the dump. Compute the visible cell window from the camera exactly as the offline `screen_rect` inverse (`comp_overdraw.py:129-156`): the layer's map cell `d` shows at screen `d + bias`, visible for `d in [-bias, FB-bias)`; `bias_x = (ratio<=1) ? -camx : camx/ratio - camx`. Standing capture ⇒ non-negative camera ⇒ `/` truncation matches:

```cpp
      if (g_gridstats_on) {
        const int camx = mister_camera_x(), camy = mister_camera_y();
        const int r = b.scroll_ratio;
        const int bx = (r <= 1) ? -camx : camx / r - camx;
        const int by = (r <= 1) ? -camy : camy / r - camy;
        // visible map-cell window [-bias/8, (FB-bias)/8), clamped to [0,g)
        auto clampc = [](int v, int hi){ return v < 0 ? 0 : (v > hi ? hi : v); };
        const int cx0 = clampc((-bx) / 8, gw), cx1 = clampc((FB_W - bx + 7) / 8, gw);
        const int cy0 = clampc((-by) / 8, gh), cy1 = clampc((FB_H - by + 7) / 8, gh);
        blt_grid_stats_t st;
        blt_grid_stats(d->grid_scratch.data(), gw,
                       (uint16_t)cx0, (uint16_t)cx1, (uint16_t)cy0, (uint16_t)cy1, &st);
        std::fprintf(stderr,
            "GRIDSTATS layer=%d ratio=%d win=%d,%d-%d,%d nonempty=%u empty=%u runs=%u hist=",
            b.layer, r, cx0, cy0, cx1, cy1,
            st.nonempty_cells, st.empty_cells, st.runs);
        for (int i = 1; i <= 16; ++i) std::fprintf(stderr, "%u%s", st.run_hist[i], i < 16 ? "," : "\n");
      }
```
(Note: this runs for buckets that pass bounds; the overlapped/replay branch a few lines down `continue`s — those buckets are NOT gridded and don't contribute grid-walk cost, so skipping them is correct.)

- [ ] **Step 4: Native syntax-check.** Run the recipe from Global Constraints.
Expected: exits 0, no errors.

- [ ] **Step 5: Commit.**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "perf(map119): SOLARUS_GRIDSTATS — per-bucket empty/run dump over the visible cell window"
```

---

## Task 4: Fabric cycle calibration in `tb_tilemap`

Add per-FSM-state cycle counters to `tb_tilemap` and print cycles-per-empty-cell and cycles-per-run, so the offline cost model uses measured constants instead of hand-counted RTL states.

**Files:**
- Modify: `fpga/sim/tb_tilemap.sv` (add cycle counters keyed on the DUT's `state`; `$display` a `CALIB` line at end of a scenario)

**Interfaces:**
- Consumes: the DUT instance's `state` register and the `S_GRID_*` localparam values (`blitter_top.sv:182-197`). Reference them via the existing hierarchical path the TB already uses to reach DUT internals (grep the file for `dut.` / the instance name).
- Produces: a stderr/stdout line `CALIB empty_cyc_per_cell=<a> run_cyc_fixed=<b> px_cyc_per_col=<c>` the analyzer reads (or hard-codes after one run).

- [ ] **Step 1: Find the DUT instance name + how the TB reaches `state`.**
Run: `grep -nE "blitter_top|\.state|dut|uut" fpga/sim/tb_tilemap.sv | head`
Record the instance path (e.g. `dut.state`). Use it below.

- [ ] **Step 2: Add cycle counters.** Near the other `always @(posedge clk)` blocks, count cycles spent in each grid state class. Use the instance path from Step 1 (shown as `dut` here):

```systemverilog
  // [Phase0] Grid-walk cycle attribution: bucket cycles by FSM state class so the
  // offline model uses measured cycles-per-empty-cell / cycles-per-run.
  integer cyc_empty_fetch, cyc_resolve, cyc_slice_wait, n_empty, n_runs;
  initial begin cyc_empty_fetch=0; cyc_resolve=0; cyc_slice_wait=0; n_empty=0; n_runs=0; end
  always @(posedge clk) begin
    case (dut.state)
      dut.S_GRID_FETCH, dut.S_GRID_DECODE: cyc_empty_fetch <= cyc_empty_fetch + 1;
      dut.S_TLR_CFT, dut.S_TLR_FRT, dut.S_GRID_SLICE:      cyc_resolve <= cyc_resolve + 1;
      dut.S_GRID_WAIT:                                     cyc_slice_wait <= cyc_slice_wait + 1;
      default: ;
    endcase
    // count a run at its SLICE issue (pipe_start), an empty at each DECODE of an empty cell
    if (dut.state == dut.S_GRID_SLICE) n_runs <= n_runs + 1;
  end
```
(If `S_TLR_CFT`/`S_TLR_FRT`/`S_GRID_SLICE`/`S_GRID_WAIT` are not visible by those names from the TB scope, reference them via the DUT path or copy their localparam values from `blitter_top.sv:166-197` as literal `6'dNN` comparisons — leave a comment citing the source line.)

- [ ] **Step 3: Print the CALIB line** at the end of the primary grid scenario (after the existing TX-COUNT `$display`, ~line 391):

```systemverilog
  $display("CALIB grid: empty_state_cyc=%0d resolve_cyc=%0d wait_cyc=%0d n_runs=%0d",
           cyc_empty_fetch, cyc_resolve, cyc_slice_wait, n_runs);
```

- [ ] **Step 4: Run the TB.**
Run: `cd fpga/sim && bash run_sims.sh tb_tilemap 2>&1 | grep -E "CALIB|TX-COUNT|PASS|FAIL"`
Expected: existing PASS assertions still pass; a `CALIB grid:` line prints with non-zero counters.

- [ ] **Step 5: Record the calibrated constants.** From the CALIB line, derive: `empty_cyc_per_cell = empty_state_cyc / (empty cells walked in the scenario)`, `run_cyc_fixed = (resolve_cyc + wait_cyc − pixel cycles) / n_runs`, where pixel cycles ≈ `Σ run_w·8` at issue-interval-1 + drain. Write the three constants into a comment block at the top of `scripts/perf/comp_attribution.py` (Task 5) and note the scenario they came from. (If the scenario's grid is too small/uniform to separate fixed vs per-pixel cost, add a second scenario with a longer empty span — but one representative run is usually enough for order-of-magnitude ranking.)

- [ ] **Step 6: Commit.**

```bash
git add fpga/sim/tb_tilemap.sv
git commit -m "test(fabric): tb_tilemap grid-walk cycle counters — calibrate comp attribution constants"
```

---

## Task 5: Phase 0 attribution script + operator runbook

Combine overlay `Δcomp` (Task 1 HW A/B), grid stats (Task 3 capture), and the calibrated constants (Task 4) into the ranked comp breakdown. The script's arithmetic is host-tested on synthetic inputs; the runbook drives the HW captures.

**Files:**
- Create: `scripts/perf/comp_attribution.py`
- Create: `scripts/perf/test_comp_attribution.py`
- Create: `docs/superpowers/plans/2026-07-23-map119-comp-attribution-runbook.md`

**Interfaces:**
- Consumes: a `GRIDSTATS` capture log, `--comp-ms`, `--overlay-ms` (from the A/B), the three calibrated constants (`--empty-cyc`, `--run-cyc`, `--px-cyc-per-col`), `FABRIC_HZ=98.4375e6`.
- Produces: ranked stdout lines `slice <name> <ms> <pct>` for `{overlay-palpha, tilemap-empty-walk, tilemap-resolve, tilemap-pixels, sprite}` plus a `SUM check` line.

- [ ] **Step 1: Write the failing test** — `scripts/perf/test_comp_attribution.py`:

```python
import subprocess, sys, os, textwrap
HERE = os.path.dirname(__file__)

def run(log, args):
    p = os.path.join(HERE, "comp_attribution.py")
    return subprocess.run([sys.executable, p, log] + args,
                          capture_output=True, text=True)

def test_ranks_and_sums(tmp_path):
    # two buckets: dense layer0 (many runs, few empties), sparse layer2 (few runs, many empties)
    log = tmp_path / "g.log"
    log.write_text(textwrap.dedent("""
      GRIDSTATS layer=0 ratio=1 win=0,0-40,30 nonempty=1200 empty=0 runs=120 hist=0,0,0,0,0,0,0,0,0,10,0,0,0,0,0,110
      GRIDSTATS layer=2 ratio=2 win=0,0-40,30 nonempty=200 empty=1000 runs=200 hist=200,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    """).strip())
    r = run(str(log), ["--comp-ms","14.9","--overlay-ms","4.0",
                       "--empty-cyc","2","--run-cyc","20","--px-cyc-per-col","2"])
    assert r.returncode == 0, r.stderr
    out = r.stdout
    # all five slices present, sorted descending, and a SUM check line
    assert "slice overlay-palpha" in out
    assert "tilemap-empty-walk" in out
    assert "SUM check" in out
    # empty-walk = 1000 empties * 2 cyc / FABRIC_HZ; assert it appears as ~0.02ms
    assert "tilemap-empty-walk" in out and "0.02" in out
```

- [ ] **Step 2: Run to verify it fails.**
Run: `python3 -m pytest scripts/perf/test_comp_attribution.py -q`
Expected: FAIL — `comp_attribution.py` not found / no such file.

- [ ] **Step 3: Write `scripts/perf/comp_attribution.py`:**

```python
"""Phase-0 comp attribution: combine a GRIDSTATS capture + overlay A/B Δcomp +
tb_tilemap-calibrated cycle constants into a ranked breakdown of comp's ms.

Calibrated constants (from fpga/sim/tb_tilemap CALIB line, Task 4 — replace after
the run): empty_cyc≈<fill in>, run_cyc≈<fill in>, px_cyc_per_col≈<fill in>.
"""
import argparse, sys

FABRIC_HZ = 98.4375e6

def parse_gridstats(lines):
    empty = runs = nonempty = 0
    for t in lines:
        if not t.startswith("GRIDSTATS"):
            continue
        kv = dict(tok.split("=", 1) for tok in t.split() if "=" in tok and "," not in tok.split("=")[0])
        empty    += int(kv.get("empty", 0))
        runs     += int(kv.get("runs", 0))
        nonempty += int(kv.get("nonempty", 0))
    return empty, runs, nonempty

def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("gridlog")
    ap.add_argument("--comp-ms", type=float, required=True)
    ap.add_argument("--overlay-ms", type=float, required=True)
    ap.add_argument("--sprite-ms", type=float, default=0.0)
    ap.add_argument("--empty-cyc", type=float, required=True)
    ap.add_argument("--run-cyc", type=float, required=True)
    ap.add_argument("--px-cyc-per-col", type=float, required=True)
    a = ap.parse_args(argv)
    with open(a.gridlog) as fh:
        empty, runs, nonempty = parse_gridstats(fh)
    ms = lambda cyc: cyc / FABRIC_HZ * 1e3
    empty_ms   = ms(empty * a.empty_cyc)
    resolve_ms = ms(runs * a.run_cyc)
    pixels_ms  = ms(nonempty * 8 * a.px_cyc_per_col)  # each cell = 8 cols * 8 rows; px model per col
    slices = {
        "overlay-palpha":     a.overlay_ms,
        "tilemap-empty-walk": empty_ms,
        "tilemap-resolve":    resolve_ms,
        "tilemap-pixels":     pixels_ms,
        "sprite":             a.sprite_ms,
    }
    total = sum(slices.values())
    for name, v in sorted(slices.items(), key=lambda kv: -kv[1]):
        print("slice %-20s %6.2f ms  %5.1f%%" % (name, v, 100.0 * v / total if total else 0))
    print("SUM check: modeled=%.2f ms vs measured comp=%.2f ms (ratio %.2f)"
          % (total, a.comp_ms, total / a.comp_ms if a.comp_ms else 0))
    return 0

if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run to verify it passes.**
Run: `python3 -m pytest scripts/perf/test_comp_attribution.py -q`
Expected: PASS.

- [ ] **Step 5: Write the operator runbook** — `docs/superpowers/plans/2026-07-23-map119-comp-attribution-runbook.md`. Model it on the existing COMPTRACE runbook (`docs/superpowers/plans/2026-07-23-map119-comptrace-runbook.md`) — same build/deploy/single-engine/teleport dance. It must specify:
  1. **Build+deploy** the Phase-0 engine (Tasks 1+3) via host-apply + `SOLARUS_SKIP_APPLY=1` Docker compile; verify `strings build/armhf/libsolarus.so.1.6.5 | grep -c GRIDSTATS` ≥ 1 and mtime is now; refresh `deploy/` then `deploy.py --no-rbf`.
  2. **Overlay A/B:** two standing map-119 legs (baseline vs `SOLARUS_OVERLAYNOCOMP=1`), grab `[blitter hwperf] comp=` from the last steady-state sample of each; `Δcomp` = overlay-ms. Reuse `scripts/perf/bgfillprobe_ab.sh` as the harness template (it already does the load-core/FIFO/teleport/settle dance) — inject the flag the same way it injects `PROBE`.
  3. **Grid-stats capture:** one standing map-119 launch with `SOLARUS_GRIDSTATS=1`; pull the `GRIDSTATS` lines from the log.
  4. **Attribute:** `python3 scripts/perf/comp_attribution.py <gridlog> --comp-ms <c> --overlay-ms <Δ> --empty-cyc <..> --run-cyc <..> --px-cyc-per-col <..>` with the Task-4 constants. Read the ranked slices + SUM check.
  5. **Gate:** if `SUM check` ratio is far from ~1.0, the model is wrong — stop and reconcile before Phase 1. Otherwise the top slice names the Phase-1 lever (per the design doc's decision table).

- [ ] **Step 6: Commit.**

```bash
git add scripts/perf/comp_attribution.py scripts/perf/test_comp_attribution.py docs/superpowers/plans/2026-07-23-map119-comp-attribution-runbook.md
git commit -m "perf(map119): comp attribution script + Phase-0 operator runbook"
```

---

## After Phase 0 (not in this plan)

Once the runbook's captures produce the ranked breakdown, write a short Phase-1 spec selecting the lever from the design doc's decision table (overlay-shrink / empty-run-skip / resolve-cache / occlusion-cull), implement it behind its own default-off flag, and run the combination A/B (`<lever> + SOLARUS_BGFILLPROBE`) against the 16.7ms/60fps threshold — or record a documented NO-GO if the top slice is too small.

## Self-review notes

- **Spec coverage:** Phase 0's three measurements → Tasks 1 (overlay A/B), 2+3 (grid stats), 4 (fabric calibration), 5 (attribution + runbook). Testing section → host tests (T2, T5), native syntax-check (T1, T3), sim assertions (T4). Stop condition → runbook Step 5 gate. All covered.
- **Renderer-not-host-compiled** is handled honestly: T1/T3 use the native syntax-check + inspection, only pure logic (T2, T5) is unit-tested — matching the `SOLARUS_BGFILLPROBE` precedent.
- **Type consistency:** `blt_grid_stats()` / `blt_grid_stats_t` fields (`nonempty_cells`, `empty_cells`, `runs`, `run_hist`) are used identically in T2 (def/test), T3 (call), and T5 (the `GRIDSTATS` line the script parses). The calibrated constants flow T4 → T5 args (`--empty-cyc`/`--run-cyc`/`--px-cyc-per-col`).
