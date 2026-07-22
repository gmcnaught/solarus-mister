# Stage 5 lever — grid overlap decomposition (K-grid) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make map 119's overlapping parallax buckets composite via the grid-walk (instead of per-tile BLEND replay) by decomposing each into K non-overlapping single-pid sub-grids, host-side, gated `SOLARUS_GRIDOV` default-off. Zero RTL.

**Architecture:** A pure host header (`grid_decompose.h`) does stack-height paint-order layering; the renderer's overlap-fallback site emits K grids instead of replaying; a bit-exact host test proves the K-grid framebuffer equals the replay framebuffer. Reuses the existing grid build, `blt_grid_list` (already blend-aware), the GRID_BUF allocator, and the unchanged RTL grid walk. Validated by HW A/B on map 119.

**Tech Stack:** C (blitter headers + host tests via `tests/run_tests.sh`, `gcc -std` C), C++11 (`mister_blitter_renderer.cpp` whole-file copy), armhf Docker build (`scripts/build_engine.sh`), the Stage 5 capture harness (`scripts/perf/capture_map119.sh`), device `192.168.20.81`.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-07-21-stage5-lever-grid-overlap-design.md`. **Decision/baseline:** `docs/superpowers/2026-07-21-stage5-decision.md` (map 119 = 11.8 fps, `[blitter p0]` BLEND=1739, the flag-off reference).
- **Zero RTL / no Quartus / no new RBF.** The grid walk already composites single-pid grids with per-command blend. HW validation is `./deploy.py --no-rbf`.
- **Gated `SOLARUS_GRIDOV`, default-off.** `=0` must reproduce the committed baseline byte-for-byte (the `if (overlapped) continue;` path is untouched when off). Parse in the ctor next to `tilemapch` (`std::getenv("SOLARUS_GRIDOV") != nullptr`). The lever also requires `SOLARUS_TILEMAPCH` on (shipping default) — it only widens which buckets set `grid_ok`.
- **Correctness bar is bit-exact-vs-replay**, not eyeballing. The host equivalence test is the gate; the operator visual gate is the final HW check (never self-declare visual correctness).
- **Decomposition = stack-height layering** (NOT min-color greedy — that can invert painter's order). Per tile in paint order: `sublayer = max(occ[cell])`; then `occ[cell] = sublayer+1`. `K = 1 + max sublayer`.
- **Renderer type-check `-std=c++11`** (not c++17), mandatory `-DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO` (recipe in CLAUDE.md).
- **`StaticBucket` has NO default member initializers** (hot rebuild path) — the new `grid_off[BLT_GRIDOV_MAXK]`/`n_grids` fields must be set explicitly at every construction site.
- **`cells_off` is GRID_BUF-RELATIVE** (0-based from the allocator); the DDR write adds `OFF_GRIDBUF` (renderer:3110-3117). Each of the K sub-grids follows this exactly.
- **Commit trailers:** end every commit with the repo's `Co-Authored-By:` + `Claude-Session:` lines.

**Line numbers are anchors as of `feat/stage5-perf-rebaseline` @ HEAD; re-grep before editing.**

---

### Task 1: `grid_decompose.h` — stack-height layering (pure host, TDD)

**Files:**
- Create: `patches/mister/blitter/grid_decompose.h`
- Create: `tests/gridov_decompose_test.c`
- Modify: `tests/run_tests.sh` (register the test)

**Interfaces:**
- Consumes: `grid_build.h`'s `blt_grid_tile_t { uint16_t pid; uint16_t cell_x, cell_y; uint8_t w_cells, h_cells; }`.
- Produces: `int blt_grid_decompose(const blt_grid_tile_t *tiles, size_t n, uint16_t gw, uint16_t gh, uint8_t *occ_scratch, int *sublayer_of_tile, int max_k)` → returns `K` (1..max_k), or `-1` if K would exceed `max_k`, or `0` if `n==0`. `occ_scratch` is a caller-provided `gw*gh`-byte buffer (avoids allocation in the header). `sublayer_of_tile[i]` gets tile i's sub-layer. Consumed by Task 3.

- [ ] **Step 1: Write the failing test.** Create `tests/gridov_decompose_test.c`:

```c
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "grid_build.h"     /* blt_grid_tile_t */
#include "grid_decompose.h" /* blt_grid_decompose */

static int max_sub(const int *s, size_t n){int m=0;for(size_t i=0;i<n;i++)if(s[i]>m)m=s[i];return m;}

int main(void){
  uint8_t occ[64];              /* 8x8 grid scratch */
  int sub[8];

  /* Case A: two tiles sharing cell (0,0) -> distinct sub-layers, later higher. */
  blt_grid_tile_t a[2] = { {1,0,0,1,1}, {2,0,0,1,1} };   /* both cover cell (0,0) */
  int K = blt_grid_decompose(a, 2, 8, 8, occ, sub, 8);
  assert(K == 2);
  assert(sub[0] == 0 && sub[1] == 1);                    /* painter's order preserved */

  /* Case B: disjoint tiles share sub-layer 0 (K=1). */
  blt_grid_tile_t b[2] = { {1,0,0,1,1}, {2,3,3,1,1} };
  K = blt_grid_decompose(b, 2, 8, 8, occ, sub, 8);
  assert(K == 1 && sub[0]==0 && sub[1]==0);

  /* Case C: 3-deep stack at one cell -> K=3, strictly increasing. */
  blt_grid_tile_t c[3] = { {1,0,0,2,2}, {2,0,0,2,2}, {3,0,0,2,2} };
  K = blt_grid_decompose(c, 3, 8, 8, occ, sub, 8);
  assert(K == 3 && sub[0]==0 && sub[1]==1 && sub[2]==2);

  /* Case D: K over max_k -> -1 (bucket will replay). */
  K = blt_grid_decompose(c, 3, 8, 8, occ, sub, /*max_k=*/2);
  assert(K == -1);

  /* Case E: same-sublayer tiles never overlap (invariant across a mixed set). */
  blt_grid_tile_t e[4] = { {1,0,0,2,1}, {2,2,0,2,1}, {3,1,0,2,1}, {4,5,5,1,1} };
  K = blt_grid_decompose(e, 4, 8, 8, occ, sub, 8);
  (void)max_sub;
  assert(K >= 1);
  /* tile 2 (cells x=1..2) overlaps tile 0 (x=0..1) at x=1 and tile 1 (x=2..3) at x=2,
     both earlier -> must be strictly above both. */
  assert(sub[2] > sub[0] && sub[2] > sub[1]);

  printf("gridov_decompose: OK\n");
  return 0;
}
```

- [ ] **Step 2: Run to verify it fails.**

  Run: `cc -Wall -Wextra -O2 -I patches/mister/blitter tests/gridov_decompose_test.c -o /tmp/gridov_decompose_test`
  Expected: FAIL — `grid_decompose.h: No such file` / `blt_grid_decompose` undefined.

- [ ] **Step 3: Implement `grid_decompose.h`.** Create `patches/mister/blitter/grid_decompose.h`:

```c
#ifndef BLT_GRID_DECOMPOSE_H
#define BLT_GRID_DECOMPOSE_H
/* [Stage 5 lever] Stack-height paint-order decomposition of an OVERLAPPING tile
 * bucket into K non-overlapping sub-layers, each a valid single-pid grid.
 *
 * Per tile in painter's (emission) order:
 *   sublayer = max(occ[cell]) over the tile's cells;  occ[cell] = sublayer+1.
 * A later tile sharing a cell with an earlier one gets a strictly higher sublayer
 * (occ was bumped), so compositing sub-layer 0,1,...,K-1 reproduces painter's order.
 * Two tiles in the SAME sub-layer never overlap (the later would have seen a higher
 * occ), so each sub-layer builds cleanly with blt_grid_build.  NOT min-color greedy:
 * that can force a later tile below an earlier one and invert the paint order. */
#include "grid_build.h"   /* blt_grid_tile_t */
#include <stddef.h>
#include <stdint.h>

/* occ_scratch: caller-provided gw*gh bytes. sublayer_of_tile: n ints out.
 * Returns K (1..max_k), 0 if n==0, or -1 if K would exceed max_k (caller replays). */
static inline int blt_grid_decompose(const blt_grid_tile_t *tiles, size_t n,
                                     uint16_t gw, uint16_t gh, uint8_t *occ_scratch,
                                     int *sublayer_of_tile, int max_k) {
    if (n == 0) return 0;
    const size_t cells = (size_t)gw * (size_t)gh;
    for (size_t i = 0; i < cells; ++i) occ_scratch[i] = 0;
    int k_max_seen = 0;
    for (size_t t = 0; t < n; ++t) {
        const blt_grid_tile_t *ti = &tiles[t];
        int base = 0;
        for (uint8_t dy = 0; dy < ti->h_cells; ++dy)
            for (uint8_t dx = 0; dx < ti->w_cells; ++dx) {
                size_t ci = (size_t)(ti->cell_y + dy) * gw + (ti->cell_x + dx);
                if (occ_scratch[ci] > base) base = occ_scratch[ci];
            }
        if (base + 1 > max_k) return -1;          /* too deep -> caller replays */
        sublayer_of_tile[t] = base;
        if (base > k_max_seen) k_max_seen = base;
        uint8_t nh = (uint8_t)(base + 1);
        for (uint8_t dy = 0; dy < ti->h_cells; ++dy)
            for (uint8_t dx = 0; dx < ti->w_cells; ++dx) {
                size_t ci = (size_t)(ti->cell_y + dy) * gw + (ti->cell_x + dx);
                occ_scratch[ci] = nh;
            }
    }
    return k_max_seen + 1;
}
#endif /* BLT_GRID_DECOMPOSE_H */
```

- [ ] **Step 4: Run to verify it passes.**

  Run: `cc -Wall -Wextra -O2 -I patches/mister/blitter tests/gridov_decompose_test.c -o /tmp/gridov_decompose_test && /tmp/gridov_decompose_test`
  Expected: `gridov_decompose: OK`, exit 0.

- [ ] **Step 5: Register in `tests/run_tests.sh`.** Add near the other blitter tests:

```sh
echo "== gridov_decompose (Stage 5: stack-height overlap decomposition) =="
$CC -Wall -Wextra -O2 -I patches/mister/blitter \
    tests/gridov_decompose_test.c \
    -o /tmp/gridov_decompose_test
/tmp/gridov_decompose_test
```

- [ ] **Step 6: Run the full suite + commit.**

  Run: `bash tests/run_tests.sh` → Expected: all green including `gridov_decompose: OK`.
  ```bash
  git add patches/mister/blitter/grid_decompose.h tests/gridov_decompose_test.c tests/run_tests.sh
  git commit -m "perf(stage5): grid_decompose.h stack-height overlap layering + tests"
  ```

---

### Task 2: Bit-exact equivalence — K-grid path == replay path

**Files:**
- Create: `tests/gridov_equiv_test.c`
- Modify: `tests/run_tests.sh` (register)

Model `patches/mister/blitter/test_grid_walk_equiv.c` (the B3 grid-vs-golden test) for heap/header setup. This test proves the K-grid composite is **pixel-identical** to the per-tile replay for an overlapping bucket — the correctness bar.

**Interfaces:**
- Consumes: `blt_grid_decompose` (Task 1); `blt_grid_build`, `blt_ref_tilemap`, `blt_ref_sprite_list`/per-tile ref composite, `blt_blend565` (from `blitter_ref.{h,c}`); `grid_cell.h`.
- Produces: nothing (a test).

- [ ] **Step 1: Read the reference test to copy its harness.** Read `patches/mister/blitter/test_grid_walk_equiv.c` for how it builds a `blt_surface_heap_t`, a source atlas, a `blt_cmd_t` header, and calls `blt_ref_tilemap`. Reuse that scaffolding verbatim (same heap/atlas/header construction).

- [ ] **Step 2: Write the failing equivalence test.** Create `tests/gridov_equiv_test.c` that:
  1. Builds a small atlas + heap (copy from the reference test).
  2. Defines an **overlapping** tile bucket (≥2 tiles sharing cells, distinct pids, a BLEND blend mode) at known dst cells.
  3. **Replay reference framebuffer `fb_ref`:** composite the bucket tile-by-tile in paint order (each tile a `blt_ref_tilemap` of a 1-tile grid, or the per-tile ref blit used by the replay path), applying the bucket's blend — this is what the current replay path produces.
  4. **K-grid framebuffer `fb_grid`:** `blt_grid_decompose` → for each sub-layer build a grid with `blt_grid_build` over that sub-layer's tiles → `blt_ref_tilemap` each sub-grid into `fb_grid` in sub-layer order, same blend.
  5. `assert(memcmp(fb_ref, fb_grid, sizeof(fb)) == 0)` — pixel-identical. Include a 2-deep case and a 3-deep case; assert equality for both. Print `gridov_equiv: OK`.

  (Show the actual tile coords, pids, blend mode, and the two composite loops in the file — no "compose the bucket" prose. The assertion is `memcmp == 0`.)

- [ ] **Step 3: Run to verify it fails, then passes.**

  Compile with the same source set the reference grid test uses (grep its line in `run_tests.sh` if present, else: `$CC ... tests/gridov_equiv_test.c patches/mister/blitter/blitter_ref.c patches/mister/blitter/blt_emitter.c patches/mister/blitter/blt_alloc.c -o /tmp/gridov_equiv_test`).
  Expected first run: FAIL (test not yet correct or fb mismatch surfaces a real bug); after the composite loops are right: `gridov_equiv: OK`. If `fb_ref != fb_grid`, that is a real decomposition/order bug — fix `grid_decompose.h` or the emit order, do NOT weaken the assertion.

- [ ] **Step 4: Register + full suite + commit.**

  Add the `== gridov_equiv ==` block to `tests/run_tests.sh` (same source set as compiled).
  Run: `bash tests/run_tests.sh` → all green.
  ```bash
  git add tests/gridov_equiv_test.c tests/run_tests.sh
  git commit -m "perf(stage5): bit-exact test — K-grid composite == replay for overlapping bucket"
  ```

---

### Task 3: Wire the decomposition into the renderer (gated `SOLARUS_GRIDOV`)

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp`

**Interfaces:**
- Consumes: `blt_grid_decompose` (Task 1), existing `blt_grid_build`, `blt_grid_alloc_take`, `blt_grid_list`.
- Produces: nothing downstream (final renderer behavior).

- [ ] **Step 1: Add the flag + include.** Add `#include "blitter/grid_decompose.h"` near the other blitter includes. In the ctor parse block (next to `tilemapch`), add member `bool gridov = false;` and parse `self->d->gridov = (std::getenv("SOLARUS_GRIDOV") != nullptr);`, with a startup log `if (self->d->gridov) std::fprintf(stderr, "[MiSTer blitter] grid overlap decomposition ENABLED (SOLARUS_GRIDOV)\n");`. Define `static constexpr int BLT_GRIDOV_MAXK = 8;` near the StaticBucket definition.

- [ ] **Step 2: Extend `StaticBucket` to hold K grids.** At ~670 change the single-grid fields to:
```cpp
  uint32_t grid_off[BLT_GRIDOV_MAXK]; uint16_t grid_w, grid_h; uint8_t n_grids; bool grid_ok;
```
  Update EVERY construction site of `StaticBucket` (grep `grid_off=`/`grid_ok=` — e.g. the `~2915` fatal-path braced init) to set the array element `[0]` and `n_grids` explicitly (no default init exists). For the existing single-grid success path (~3118), set `grid_off[0]=off; n_grids=1;`.

- [ ] **Step 3: Replace the overlap fallback with decomposition.** At ~3087 (`if (overlapped) { … continue; }`), when `d->gridov` is on, replace the `continue` with: run `blt_grid_decompose(tiles.data(), tiles.size(), gw, gh, occ_scratch, sublayer.data(), BLT_GRIDOV_MAXK)`; if it returns `-1` or `0`, keep the current replay fallback (`continue`). Otherwise for each sub-layer `s` in `0..K-1`: gather that sub-layer's tiles, `blt_grid_build` into `grid_scratch`, `blt_grid_alloc_take` (if `BLT_GRID_ALLOC_FAIL`, free the sub-grids already taken this bucket and `continue` → replay — do not leak GRID_BUF), `memcpy` into `ddr + OFF_GRIDBUF + off`, store `b.grid_off[s]=off`. Then `b.grid_w=gw; b.grid_h=gh; b.n_grids=K; b.grid_ok=true;`. Keep the `!d->gridov` path exactly as today (`continue` on overlap). Add scratch buffers (`std::vector<uint8_t> occ_scratch(gw*gh)`, `std::vector<int> sublayer(tiles.size())`) reused across buckets. Emit a `[blitter gridov]` diag line per decomposed bucket: `layer, K, total bytes`.

- [ ] **Step 4: Emit K grids at composite time.** At ~3266 (`if (d->tilemapch && b.grid_ok) { … blt_grid_list(...) … }`), change the single `blt_grid_list` to a loop over `s = 0..b.n_grids-1` emitting `blt_grid_list(&d->em, tex, b.blend, b.key, 255, b.flags, /*cells_off=*/b.grid_off[s], b.grid_w, b.grid_h, …)` in order (sub-layer 0 first). The single-grid case (`n_grids==1`) is naturally covered. Leave the `else` replay path unchanged.

- [ ] **Step 5: Type-check.**

  Run the `-std=c++11` type-check (Global Constraints).
  Expected: exits 0, no errors. (c++11, not c++17 — it caught a real aggregate-init break before.)

- [ ] **Step 6: Host suite still green + commit.**

  Run: `bash tests/run_tests.sh` → all green (Task 1/2 tests + existing).
  ```bash
  git add patches/mister/mister_blitter_renderer.cpp
  git commit -m "perf(stage5): emit K decomposed grids for overlapping buckets behind SOLARUS_GRIDOV (default-off)"
  ```

---

### Task 4: armhf build + census + HW A/B on map 119 (operator-gated)

**Files:**
- Create: `docs/superpowers/2026-07-21-stage5-hw-validation.md`
- Use: `scripts/perf/capture_map119.sh` (Stage 5 harness), `scripts/perf/derive_tilemap_cycpx.py`

- [ ] **Step 1: Build the engine (armhf Docker).**

  Run: `bash scripts/build_engine.sh` → produces `build/armhf/{solarus-run,libsolarus.so.1.6.5}`, 0 `error:`.
  Confirm the flag string is in the binary: `strings build/armhf/libsolarus.so.1.6.5 | grep -c SOLARUS_GRIDOV` → ≥1.

- [ ] **Step 2: Deploy engine-only + census (flag ON).**

  Refresh `deploy/` from `build/armhf`, `./deploy.py --no-rbf`, verify on-device `.so` sha1 matches the new build.
  Add `SOLARUS_GRIDOV=1` to the device `diag.env`, run `bash scripts/perf/capture_map119.sh`. In the captured log, read `[blitter gridov]` (per-bucket K + bytes) and confirm: K is small (≤ a few), all previously-overlapping buckets now decompose (no `[blitter grid] overlap: … replays` for map-119 buckets), and `[blitter resident] fatal=0`, `valid=1`.

- [ ] **Step 3: A/B — flag off vs on, same map-119 spot.**

  Capture with `SOLARUS_GRIDOV` unset (off) then `=1` (on). Assert:
  - OFF reproduces the committed baseline (fps ~11.8, `[blitter p0]` BLEND ~1739) — proves true no-op.
  - ON: `[blitter p0]` BLEND collapses (parallax buckets now grid), `[blitter hwperf]` fabric_hw drops, `[blitter timing]` fps/period improves. Record the deltas.
  Run `python3 scripts/perf/derive_tilemap_cycpx.py < <on-standing-window>`; with the grid now live, `grid_path_live=True` and a real tilemap cyc/px prints.

- [ ] **Step 4: Operator visual gate.** Operator confirms on device: map 119 renders **correctly** standing + moving with the flag ON (parallax layers correct, no seam/flash/missing tiles), and an in/out transition is clean. Never self-declare — this is the operator's eyes.

- [ ] **Step 5: Record + commit + PR.** Write `docs/superpowers/2026-07-21-stage5-hw-validation.md`: the off/on numbers, the census K, the derived cyc/px (now measurable), the operator confirmation. Commit. Then update the PR (`feat/stage5-perf-rebaseline` → master) to summarize: baseline → finding (grid fallback) → lever (K-grid decomposition) → measured delta + operator sign-off. Do NOT mark Stage 5 done until the operator confirms.

---

## Self-Review

**Spec coverage:** §2 host-only (blend already grids; overlap sole blocker) → Task 3 replaces only the overlap `continue` ✓; §3 stack-height algorithm → Task 1 `grid_decompose.h` + its exact code ✓; §4 boundaries (grid_decompose.h / StaticBucket K grids / res_arm_ branch / K-grid emit) → Tasks 1,3 ✓; §5 gating default-off true no-op + graceful fallback (max_k, GRID_BUF full) → Task 3 Steps 1,3 ✓; §6 bit-exact-vs-replay + decomposition units + census + HW A/B → Tasks 2,1,4 ✓; §7 risks (K size→census; mis-order→bit-exact test; blend divergence→same comp_pipeline+test; flag-off no-op→A/B; small win→measured gate) → Tasks 2,4 ✓; §8 open items (MAXK=8, fixed array, gridov fields) → Task 3 Steps 1,2,3 ✓.

**Placeholder scan:** No TBD/TODO. `BLT_GRIDOV_MAXK=8` is a concrete starting value (spec §8 open item, tunable from Task 4's census). Task 2's composite loops are described with required assertions (`memcmp==0`, 2-deep + 3-deep) and told to copy `test_grid_walk_equiv.c`'s concrete harness — the one place code isn't inlined is the heap/atlas scaffolding, which must match the existing reference test verbatim rather than be reinvented.

**Type consistency:** `blt_grid_decompose(tiles, n, gw, gh, occ_scratch, sublayer_of_tile, max_k) -> int K` is defined in Task 1 and consumed with the same signature in Tasks 2, 3. `StaticBucket.grid_off[BLT_GRIDOV_MAXK]` / `n_grids` / `grid_ok` named consistently across Task 3 Steps 2-4. `SOLARUS_GRIDOV` / `gridov` / `BLT_GRIDOV_MAXK` used identically throughout. `blt_grid_list(e, tex, blend, key, alpha, flags, cells_off, gw, gh, …)` matches the real signature (blt_emitter.h:403) with `cells_off` GRID_BUF-relative per the Global Constraint.
