# Stage 3b Phase B3 — Engine Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the Solarus engine/renderer to build a per-static-bucket 8px cell grid and emit `BLT_OP_TILEMAP` in gameplay, behind `SOLARUS_TILEMAPCH` (default OFF), owning the GRID_BUF allocator.

**Architecture:** B1 delivered the host emitter (`blt_grid_list`, `grid_build.h`, `blt_ref_tilemap`) and B2 the fabric (`tilemap_unit`, `BLT_OP_TILEMAP=11`, `MAXP=256`) + a passing RTL sim (`fpga/sim/tb_tilemap.sv`). B3 is **pure host/engine — no RTL, no Quartus, no seed sweep**; it runs on the already-deployed B2 RBF. Static tiles reach the fabric through `resident_emit_static_layer()`; B3 replaces that seam's body with a grid op when the flag is on, keeping the existing per-bucket replay as the flag-OFF path and A/B reference. New pure logic (the GRID_BUF bump allocator) is factored into a testable header; the renderer/engine glue is verified by `g++ -fsyntax-only` + the HW gate, per this project's convention that host tests do not compile the renderer.

**Tech Stack:** C11 (blitter emitter/ref headers), C++17 (renderer, LuaJIT engine), Python 3 (wire-constant check), Solarus 1.6.5 upstream (git-am series patches), armhf cross-build in Docker, MiSTer DE10-Nano HW.

## Global Constraints

- `SOLARUS_TILEMAPCH` gate flag, **default OFF**. Flag OFF must be byte-identical to today's output.
- **GRID_BUF budget overflow → graceful per-layer fallback** to bucket-replay (decision C). **Pattern-table overflow (`>= BLT_MAXP`) → `res_fatal`** (decision C; the existing guard at `mister_blitter_renderer.cpp:2955` already does this — static patterns inherit it).
- `mister_blitter_renderer.{cpp,h}` and everything under `patches/mister/blitter/` are **whole-file copies** — edit directly, NOT via the patch series.
- The two engine patches touch **pristine upstream files** (`work/solarus/**`) → they are **git-am series patches** under `patches/series/`; regenerate with `scripts/export_patches.sh`.
- Renderer native type-check recipe (both `-D` flags MANDATORY, or it type-checks nothing):
  ```
  g++ -fsyntax-only -std=c++17 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO \
    -I patches/mister -I patches/mister/blitter -I work/solarus/include \
    -I build/armhf/include -I work/solarus/libraries/win32/mingw32/include \
    $(sdl2-config --cflags) patches/mister/mister_blitter_renderer.cpp
  ```
- Host test suite gate: `bash patches/mister/build_host_tests.sh` (compiles + runs the C/C++ emitter/ref tests). Also `bash tests/run_tests.sh` for the broader suite.
- Grid cell encoding is FROZEN (`patches/mister/blitter/grid_cell.h`): `pid[11:0]` (`0xFFF`=empty), `sub_x[15:12]`, `sub_y[19:16]`, `run_m1[23:20]`, `spare[31:24]`=0. `blt_ref_tilemap` (`blitter_ref.c`) is the golden walk.
- GRID_BUF host region: `OFF_GRIDBUF=0x00FF3000` (ddr-relative), `GRID_BUF_BYTES=0x00200000` (2 MiB), already defined in `mister_blitter_renderer.cpp:389-390`. FRT lives immediately above it — never write past `GRID_BUF_BYTES`.
- HW discipline: leave `Solarus.s0` empty, load core, launch with a private `S0_FILE` override (two engines wedge the host); log to `/media/fat/logs/Solarus/`; never blind-inject joypad; confirm the loaded RBF is the B2 tilemap core.

---

## Task 1: GRID_BUF bump allocator (`grid_alloc.h`)

Factor the allocator into a pure, host-testable header. Closes both B2-deferred items: qword alignment guaranteed by the allocator (not a downstream TB assertion), and `grid_cap` enforced (not ignored).

**Files:**
- Create: `patches/mister/blitter/grid_alloc.h`
- Create: `patches/mister/blitter/grid_alloc_test.c`
- Modify: `patches/mister/build_host_tests.sh` (register the new test)

**Interfaces:**
- Produces:
  - `typedef struct { uint32_t base_off, cap, used; } blt_grid_alloc_t;`
  - `void blt_grid_alloc_init(blt_grid_alloc_t *a, uint32_t base_off, uint32_t cap);`
  - `void blt_grid_alloc_reset(blt_grid_alloc_t *a);`  — sets `used=0`
  - `#define BLT_GRID_ALLOC_FAIL 0xFFFFFFFFu`
  - `uint32_t blt_grid_alloc_take(blt_grid_alloc_t *a, uint32_t bytes);` — returns a **GRID_BUF-region-relative byte offset** (i.e. `base_off + prior_used`, rounded so the returned offset is 8-byte aligned) suitable to pass as `blt_grid_list`'s `cells_off`, or `BLT_GRID_ALLOC_FAIL` if it would exceed `cap`. Advances `used`.

- [ ] **Step 1: Write the failing test**

Create `patches/mister/blitter/grid_alloc_test.c`:

```c
#include "grid_alloc.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    blt_grid_alloc_t a;
    blt_grid_alloc_init(&a, 0x1000u, 0x100u);   /* base 0x1000, cap 256 bytes */

    /* First take returns the base, 8-byte aligned. */
    uint32_t o0 = blt_grid_alloc_take(&a, 12u);  /* 12 -> rounds used to 16 */
    assert(o0 == 0x1000u);
    assert((o0 & 7u) == 0u);

    /* Second take starts after the aligned first (16), also aligned. */
    uint32_t o1 = blt_grid_alloc_take(&a, 8u);
    assert(o1 == 0x1010u);
    assert((o1 & 7u) == 0u);

    /* used is now 24; a 240-byte take exceeds cap 256 -> FAIL, used unchanged. */
    uint32_t of = blt_grid_alloc_take(&a, 240u);
    assert(of == BLT_GRID_ALLOC_FAIL);
    uint32_t o2 = blt_grid_alloc_take(&a, 8u);   /* still room for a small one */
    assert(o2 == 0x1018u);

    /* Exact-fit take at the boundary succeeds; the next byte fails. */
    blt_grid_alloc_reset(&a);
    assert(a.used == 0u);
    uint32_t ofull = blt_grid_alloc_take(&a, 0x100u);   /* exactly cap */
    assert(ofull == 0x1000u);
    assert(blt_grid_alloc_take(&a, 1u) == BLT_GRID_ALLOC_FAIL);

    printf("grid_alloc_test OK\n");
    return 0;
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cc -I patches/mister/blitter -o /tmp/grid_alloc_test patches/mister/blitter/grid_alloc_test.c && /tmp/grid_alloc_test`
Expected: FAIL — `fatal error: grid_alloc.h: No such file or directory`.

- [ ] **Step 3: Write minimal implementation**

Create `patches/mister/blitter/grid_alloc.h`:

```c
#ifndef BLT_GRID_ALLOC_H
#define BLT_GRID_ALLOC_H
/* [Stage 3b Phase B3] Bump allocator over the GRID_BUF DDR region.
 *
 * Owns the two items B2 deferred to B3:
 *   - every returned offset is 8-byte (qword) aligned, so a grid's cell array
 *     never straddles a qword boundary the fabric fetch assumes aligned;
 *   - a take that would exceed `cap` returns BLT_GRID_ALLOC_FAIL instead of
 *     silently running past GRID_BUF into the FRT region above it.
 * Reset once per map rebuild; take once per static bucket that grids. */
#include <stdint.h>

#define BLT_GRID_ALLOC_FAIL 0xFFFFFFFFu

typedef struct {
    uint32_t base_off;   /* GRID_BUF region base, ddr-relative bytes */
    uint32_t cap;        /* region capacity in bytes                 */
    uint32_t used;       /* bytes handed out since the last reset    */
} blt_grid_alloc_t;

static inline void blt_grid_alloc_init(blt_grid_alloc_t *a, uint32_t base_off, uint32_t cap) {
    a->base_off = base_off; a->cap = cap; a->used = 0u;
}
static inline void blt_grid_alloc_reset(blt_grid_alloc_t *a) { a->used = 0u; }

static inline uint32_t blt_grid_alloc_take(blt_grid_alloc_t *a, uint32_t bytes) {
    /* Align the START of this allocation to 8 bytes. base_off is already
     * qword-aligned (GRID_BUF base is), so aligning `used` aligns the result. */
    uint32_t used = (a->used + 7u) & ~7u;
    if (bytes > a->cap || used > a->cap - bytes) return BLT_GRID_ALLOC_FAIL;
    a->used = used + bytes;
    return a->base_off + used;
}

#endif /* BLT_GRID_ALLOC_H */
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cc -I patches/mister/blitter -o /tmp/grid_alloc_test patches/mister/blitter/grid_alloc_test.c && /tmp/grid_alloc_test`
Expected: `grid_alloc_test OK`.

- [ ] **Step 5: Register the test in the host suite**

In `patches/mister/build_host_tests.sh`, find the block that compiles the other `blitter/*_test.c` files (search for `grid_alloc` neighbours like `gridbuild` / `gridcell`) and add a stanza mirroring the existing ones, e.g.:

```sh
cc $CFLAGS -I "$HERE/blitter" -o "$TMP/grid_alloc_test" "$HERE/blitter/grid_alloc_test.c" && "$TMP/grid_alloc_test"
```

(Match the surrounding lines' exact variable names — `$CFLAGS`, `$HERE`, `$TMP` — read two neighbouring stanzas first and copy their form.)

- [ ] **Step 6: Run the host suite**

Run: `bash patches/mister/build_host_tests.sh`
Expected: all tests pass, including `grid_alloc_test OK`.

- [ ] **Step 7: Commit**

```bash
git add patches/mister/blitter/grid_alloc.h patches/mister/blitter/grid_alloc_test.c patches/mister/build_host_tests.sh
git commit -m "feat(blitter): GRID_BUF bump allocator (qword-align + cap enforce)"
```

---

## Task 2: Grid-walk equivalence + edge-case gate (host)

Strengthen the objective gate: prove `blt_grid_build` → `blt_ref_tilemap` is pixel-identical to a per-tile reference blit, and pin the three walker behaviours the B1→B2 handoff (§3) flagged as untested through the walker end-to-end: full-cull, a maximal 16-cell run, and negative-bias edge clipping (#24). Uses B1 infra already present in `blitter_ref.c` — this task adds a test, no product code.

**Files:**
- Create: `patches/mister/blitter/grid_walk_equiv_test.c`
- Modify: `patches/mister/build_host_tests.sh` (register it)

**Interfaces:**
- Consumes: `blt_grid_build` (`grid_build.h`), `blt_ref_tilemap` + the reference framebuffer/per-tile helpers already used by B1's equivalence gate (`blitter_ref.h`/`blitter_ref.c`).

- [ ] **Step 1: Read B1's existing equivalence test to reuse its harness**

Run: `ls patches/mister/blitter/*tilemap*equiv* patches/mister/blitter/*grid*equiv* 2>/dev/null; grep -rln blt_ref_tilemap patches/mister/blitter/*_test.c`
Read the B1 equivalence test it names. Reuse its framebuffer alloc + per-tile reference + `memcmp` scaffolding verbatim; this task only adds three scenarios.

- [ ] **Step 2: Write the failing test**

Create `patches/mister/blitter/grid_walk_equiv_test.c`. Model the harness on the B1 equivalence test found in Step 1 (same FB size, same `blt_ref_tilemap` call convention, same per-tile reference builder). Add exactly these three scenarios, each asserting `memcmp(fb_grid, fb_ref, fb_bytes) == 0` AND asserting the issued-blit count where noted:

```c
/* Scenario A — FULL CULL: a non-empty grid biased entirely off-screen emits
 * zero blits and leaves the framebuffer untouched (all-transparent). */
/* Build a 4x4-cell grid of one 1x1 pattern; walk with bias_x = -100000 (far
 * left of FB). Assert fb_grid is all zero AND equals a never-touched fb_ref. */

/* Scenario B — MAXIMAL 16-CELL RUN end-to-end: one 16x1-cell pattern instance
 * (128px wide) fully on-screen. Build -> single run_m1=15 cell. Walk. Assert
 * pixel-identical to 16 individual 1-cell reference blits from the same atlas. */

/* Scenario C — NEGATIVE-BIAS EDGE CLIP (#24): a grid whose left edge sits at
 * bias_x = -12 (partially off the left of the FB). Assert pixel-identical to a
 * per-tile reference that clips each blit's dst in SIGNED space before any
 * unsigned cast. The visible-cell window uses cx0=floor, cx1=ceil. */
```

Fill each scenario with concrete cell/pattern/atlas values (small integers), following the B1 test's style. Every atlas byte must be deterministic so the two framebuffers are comparable.

- [ ] **Step 3: Run test to verify it fails**

Run: `cc -I patches/mister/blitter -o /tmp/gwe patches/mister/blitter/grid_walk_equiv_test.c patches/mister/blitter/blitter_ref.c && /tmp/gwe`
Expected: FAIL (test not yet correct/compiling, or an assertion trips) — confirm it is genuinely exercising the walk, not a compile no-op.

- [ ] **Step 4: Make it pass**

Correct the scenario constants until all three `memcmp`s and blit-count assertions pass. Do NOT weaken an assertion to force a pass — if Scenario C fails, the bug is in the test's reference clip, not in `blt_ref_tilemap` (which B1 proved). Re-read the frozen `blt_ref_tilemap` clip rule (Global Constraints) before adjusting.

Run: `cc -I patches/mister/blitter -o /tmp/gwe patches/mister/blitter/grid_walk_equiv_test.c patches/mister/blitter/blitter_ref.c && /tmp/gwe`
Expected: `grid_walk_equiv_test OK` (or your final print line).

- [ ] **Step 5: Register + run the suite**

Add a stanza to `patches/mister/build_host_tests.sh` mirroring the `grid_alloc_test` one from Task 1 but linking `blitter_ref.c` too:

```sh
cc $CFLAGS -I "$HERE/blitter" -o "$TMP/grid_walk_equiv_test" "$HERE/blitter/grid_walk_equiv_test.c" "$HERE/blitter/blitter_ref.c" && "$TMP/grid_walk_equiv_test"
```

Run: `bash patches/mister/build_host_tests.sh`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add patches/mister/blitter/grid_walk_equiv_test.c patches/mister/build_host_tests.sh
git commit -m "test(blitter): grid-walk equivalence + full-cull/16-run/edge-clip gate"
```

---

## Task 3: Cell-bitfield host↔RTL cross-check

Close B1→B2 handoff item #2: `test_wire_constants.py` pins opcode 11 and GRID_BUF base/size but not the cell bit positions. Add an assertion that `grid_cell.h`'s shift constants match `tilemap_unit`'s decode.

**Files:**
- Modify: `scripts/tests/test_wire_constants.py`

**Interfaces:**
- Consumes: `patches/mister/blitter/grid_cell.h` (shifts), `fpga/rtl/tilemap_unit.sv` (RTL bit-slice literals).

- [ ] **Step 1: Find the RTL decode bit positions**

Run: `grep -nE '\[(31|23|19|15|11)' fpga/rtl/tilemap_unit.sv | grep -iE 'pid|sub|run|cell|\[' | head -30`
Identify the bit slices `tilemap_unit` uses to decode `pid`, `sub_x`, `sub_y`, `run_m1` from a fetched 32-bit cell. Note the exact `[hi:lo]` literals.

- [ ] **Step 2: Write the failing assertion**

In `scripts/tests/test_wire_constants.py`, find the existing grid/opcode block (search `TILEMAP` / `GRID_BUF` / `11`). Add a check that parses the shift amounts from `grid_cell.h` (`<< 12`, `<< 16`, `<< 20`, mask `0x0FFF`) and asserts they equal the RTL slices found in Step 1. Follow the file's existing parse+assert idiom (it already greps headers and RTL). Concretely assert the tuple:

```python
# [Stage 3b B3] Cell bitfield host<->RTL cross-check (handoff item #2).
# grid_cell.h: pid[11:0], sub_x[15:12], sub_y[19:16], run_m1[23:20], spare[31:24].
assert host_cell_shifts == {"pid_lo": 0, "pid_hi": 11,
                            "subx_lo": 12, "subx_hi": 15,
                            "suby_lo": 16, "suby_hi": 19,
                            "run_lo": 20, "run_hi": 23}, host_cell_shifts
assert rtl_cell_slices == host_cell_shifts, (rtl_cell_slices, host_cell_shifts)
```

(Build `host_cell_shifts` and `rtl_cell_slices` by parsing the two files; match the script's existing regex helpers rather than hand-rolling new ones.)

- [ ] **Step 3: Run to verify it fails first if positions are wrong**

Temporarily change one expected number (e.g. `subx_lo` to 13), run:
`python3 scripts/tests/test_wire_constants.py`
Expected: AssertionError showing the mismatch. Then restore the correct number.

- [ ] **Step 4: Run to verify it passes**

Run: `python3 scripts/tests/test_wire_constants.py`
Expected: exit 0, all constants (incl. new cell-bitfield check) pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/tests/test_wire_constants.py
git commit -m "test(wire): cross-check grid cell bitfields host<->tilemap_unit RTL"
```

---

## Task 4: Engine patch #1 — pattern tokens on the static path

The static record path discards pattern identity; the grid is built ON pattern indices. Thread a `tokens` vector through the static path exactly as the animated path (`resident_record_batch`) already does, intern each into the shared `res_pat_index`, populate the static pattern's single frame rect, and store the interned pid per static entry.

**Files:**
- Modify (upstream, series): `work/solarus/include/solarus/graphics/Renderer.h:114-119` (base virtual signature)
- Modify (upstream, series): `work/solarus/src/entities/NonAnimatedRegions.cpp:370-390` (collect + pass tokens)
- Modify (whole-file copy): `patches/mister/mister_blitter_renderer.h:75-77` (override signature)
- Modify (whole-file copy): `patches/mister/mister_blitter_renderer.cpp:2983-3009` (`resident_record_static` body) and `Impl::StaticEnt` / `Impl::StaticBucket` (`:637-646`)
- Regenerate: `patches/series/0016-*.patch` via `scripts/export_patches.sh`

**Interfaces:**
- Consumes: `res_pat_index`, `res_patterns` (`Impl`, `:648-649`); `ResPattern` (has `.token`, `.frames[]`, `.frame_count`); the animated intern pattern at `mister_blitter_renderer.cpp:2951-2975`; the TileInfo pattern pointer `tile.pattern` (`Entities.cpp:817`, and `TileInfo` in `NonAnimatedRegions`).
- Produces: `resident_record_static(int layer, int scroll_ratio, const SurfaceImpl& tileset_image, BlendMode blend, const std::vector<TileBatchEntry>& entries, const std::vector<uintptr_t>& tokens)` — new trailing `tokens` param, one per entry (0 = no identity). `Impl::StaticEnt` gains `uint16_t pid;` holding the interned slot (`0xFFFF` when tokenless).

- [ ] **Step 1: Extend the base virtual (upstream)**

In `work/solarus/include/solarus/graphics/Renderer.h`, add the trailing `tokens` param to the `resident_record_static` virtual (mirror `resident_record_batch` at `:62-65` of the renderer header for the shape). Keep the default impl a no-op:

```cpp
  virtual void resident_record_static(int /*layer*/, int /*scroll_ratio*/,
                                      const SurfaceImpl& /*tileset_image*/,
                                      BlendMode /*blend*/,
                                      const std::vector<TileBatchEntry>& /*entries*/,
                                      const std::vector<uintptr_t>& /*tokens*/) {}
```

- [ ] **Step 2: Collect + pass tokens at the call site (upstream)**

In `work/solarus/src/entities/NonAnimatedRegions.cpp:record_static`, add a `std::vector<uintptr_t> cur_tokens;` parallel to `cur_entries`, push `reinterpret_cast<uintptr_t>(tile.pattern)` for each recorded tile at the same place `cur_entries.push_back(...)` happens (find that push in `:390-465`), and pass `cur_tokens` as the new final arg in `flush_bucket`'s `resident_record_static(...)` call. Clear `cur_tokens` wherever `cur_entries` is cleared. (`tile` is the `TileInfo`; confirm its pattern member name — `tile.pattern` per `Entities.cpp:817` — and that it is non-null for non-animated tiles.)

- [ ] **Step 3: Update the override signature + entry struct (whole-file copy)**

In `patches/mister/mister_blitter_renderer.h`, change the `resident_record_static` declaration (`:75-77`) to add `const std::vector<uintptr_t>& tokens`. In `patches/mister/mister_blitter_renderer.cpp`, add `uint16_t pid;` to `Impl::StaticEnt` (`:638`), initialised `0xFFFF`.

- [ ] **Step 4: Intern tokens + set static frame rect in the body**

In `resident_record_static` (`:2983`), before/while building `bk.ent`, intern each entry's token mirroring the animated block at `:2951-2975`:
- look up `tokens[i]` in `res_pat_index`; on miss, allocate slot `pi = res_patterns.size()`, hard-fail `res_fatal` if `pi >= BLT_MAXP` (reuse the exact fprintf form at `:2960`), else insert and push a `ResPattern{ .token=tok }`;
- **set the static pattern's frame rect once:** for a freshly-interned static pattern set `rp.frame_count = 1` and `rp.frames[0] = entries[i].src` (a `Rectangle`), so `res_arm_`'s FRT writer (`:3053-3061`) emits its src rect. (An already-interned pattern — e.g. shared with the animated path — keeps its frames; do not overwrite.)
- store `pi` into the pushed `StaticEnt.pid` (tokenless entry → `0xFFFF`, still recorded for the replay path).

Leave the existing `bk.ent.push_back({sx,sy,w,h,dx,dy, pid})` producing the same 6 rect fields the replay path already uses — only the new `pid` field is added.

- [ ] **Step 5: Type-check the renderer**

Run the Global-Constraints `g++ -fsyntax-only` recipe.
Expected: exit 0, no errors. (This is the only automated check for renderer glue — host tests do not compile it.)

- [ ] **Step 6: Regenerate the series + verify round-trip**

Run: `bash scripts/export_patches.sh` (or the repo's documented series-export script), then confirm the two upstream edits landed in `0016` (and the base-virtual edit wherever `resident_record_static` is declared):
Run: `grep -l 'tokens' patches/series/0016-*.patch`
Expected: the patch now carries the `tokens` param.

- [ ] **Step 7: Run host suite (regression) + commit**

Run: `bash patches/mister/build_host_tests.sh`
Expected: all pass (this task adds no host-testable unit but must not regress the suite).

```bash
git add work/solarus/include/solarus/graphics/Renderer.h work/solarus/src/entities/NonAnimatedRegions.cpp \
        patches/mister/mister_blitter_renderer.h patches/mister/mister_blitter_renderer.cpp \
        patches/series/0016-*.patch
git commit -m "feat(engine): thread pattern tokens through the static tile path"
```

---

## Task 5: Engine patch #2 — map dimensions at load

The renderer holds `map_id` as an opaque `uintptr_t` and has no `Map&`, so it cannot size grids. Publish `(w8, h8)` at map start so grids are sized rather than grown.

**Files:**
- Modify (whole-file copy): `patches/mister/mister_blitter_renderer.h` (new public method `mister_set_map_dims`)
- Modify (whole-file copy): `patches/mister/mister_blitter_renderer.cpp` (store `map_w8`/`map_h8` in `Impl`)
- Modify (upstream, series): `work/solarus/src/entities/Entities.cpp:notify_map_starting` (call it after `build()`)
- Regenerate: the series patch owning `Entities.cpp` map-start (or a new patch)

**Interfaces:**
- Produces: `void MisterBlitterRenderer::mister_set_map_dims(int w8, int h8);` storing `Impl::map_w8`, `Impl::map_h8` (both `int`, default 0). A free function `void mister_set_map_dims(int,int)` if the engine calls through the same C-shim style as `mister_set_background_color` / `mister_tag_root_surface` — match whichever mechanism those use.

- [ ] **Step 1: Find how existing map/root hooks reach the renderer**

Run: `grep -n 'mister_set_background_color\|mister_tag_root_surface\|mister_set_map_dims' patches/mister/*.h patches/mister/*.cpp work/solarus/src/**/*.cpp`
Mirror whichever indirection those use (free function forwarding to the singleton, or a virtual). Use the same style for `mister_set_map_dims`.

- [ ] **Step 2: Add `map_w8`/`map_h8` to `Impl` + the setter (whole-file copy)**

In `mister_blitter_renderer.cpp`, add `int map_w8 = 0, map_h8 = 0;` to `Impl` (near the resident state, `~:648`). Implement `mister_set_map_dims(w8,h8)` to store them. Declare it in the header per Step 1's style.

- [ ] **Step 3: Call it at map start (upstream)**

In `work/solarus/src/entities/Entities.cpp::notify_map_starting` (`:676-697`), after the `build()` loop, call the setter with `map.get_width8()` / `map.get_height8()`. (These already exist — used in `NonAnimatedRegions.cpp:68-69`.) Guard behind the same "MiSTer blitter renderer active" condition the other `mister_*` calls use.

- [ ] **Step 4: Type-check the renderer**

Run the `g++ -fsyntax-only` recipe. Expected: exit 0.

- [ ] **Step 5: Regenerate series + verify**

Run: `bash scripts/export_patches.sh`; then `grep -rl 'mister_set_map_dims\|get_width8' patches/series/*.patch`
Expected: an `Entities.cpp` series patch now carries the call.

- [ ] **Step 6: Host suite (regression) + commit**

Run: `bash patches/mister/build_host_tests.sh` — Expected: all pass.

```bash
git add patches/mister/mister_blitter_renderer.h patches/mister/mister_blitter_renderer.cpp \
        work/solarus/src/entities/Entities.cpp patches/series/*.patch
git commit -m "feat(engine): publish map w8/h8 to the renderer at map start"
```

---

## Task 6: GRID_BUF allocator wiring + per-bucket grid build

Bind the Task-1 allocator to GRID_BUF, reset it per map rebuild, and at `res_arm_` build one full-map-sized cell grid **per static bucket** (the granularity that keeps parallax/normal biases separable and stays within budget — big maps have no parallax, parallax maps are tiny). Store `cells_off` + `grid_ok` per bucket; a bucket that does not fit stays `grid_ok=false` and falls back to replay (decision C).

**Files:**
- Modify (whole-file copy): `patches/mister/mister_blitter_renderer.cpp` — `Impl` (add `blt_grid_alloc_t grid_alloc;` + a scratch `std::vector<blt_grid_cell_t>`), `Impl::StaticBucket` (add `uint32_t grid_off; uint16_t grid_w, grid_h; bool grid_ok;`), the emitter bind site (`:1066`), `res_arm_` (`:3030+`)
- Modify (whole-file copy): `patches/mister/mister_blitter_renderer.cpp` includes — add `#include "blitter/grid_alloc.h"` and `#include "blitter/grid_build.h"`

**Interfaces:**
- Consumes: Task 1 `blt_grid_alloc_*`; `grid_build.h` `blt_grid_build` + `blt_grid_tile_t`; `OFF_GRIDBUF`/`GRID_BUF_BYTES`; `StaticEnt.pid` (Task 4); `map_w8`/`map_h8` (Task 5).
- Produces: per `StaticBucket`, `grid_off` (GRID_BUF-region-relative byte offset of its cell array), `grid_w`/`grid_h` (= `map_w8`/`map_h8`), `grid_ok`. Consumed by Task 7's emit.

- [ ] **Step 1: Bind the allocator + add bucket fields**

Add the two includes. Add `blt_grid_alloc_t grid_alloc;` and `std::vector<blt_grid_cell_t> grid_scratch;` to `Impl`. Add `uint32_t grid_off=0; uint16_t grid_w=0, grid_h=0; bool grid_ok=false;` to `Impl::StaticBucket`. At the emitter init near `:1066` (where `blt_grid_list_init(&em, OFF_GRIDBUF, GRID_BUF_BYTES)` is), also `blt_grid_alloc_init(&d->grid_alloc, OFF_GRIDBUF, GRID_BUF_BYTES);` (offsets from the allocator match `blt_grid_list`'s expected `cells_off` domain).

- [ ] **Step 2: Reset the allocator per map rebuild**

Find where the resident scene is cleared per rebuild (`res_static_buckets.clear()` at `:2867`). Add `blt_grid_alloc_reset(&d->grid_alloc);` alongside it so each map rebuild starts the bump allocator at 0.

- [ ] **Step 3: Build per-bucket grids in `res_arm_`**

In `res_arm_` (after the FRT + entry writes, `~:3070`), add a pass over `res_static_buckets`. For each bucket `b`:
```cpp
b.grid_ok = false;
if (d->map_w8 > 0 && d->map_h8 > 0) {
    const uint16_t gw = (uint16_t)d->map_w8, gh = (uint16_t)d->map_h8;
    const uint32_t bytes = (uint32_t)gw * gh * 4u;
    uint32_t off = blt_grid_alloc_take(&d->grid_alloc, bytes);
    if (off != BLT_GRID_ALLOC_FAIL) {
        // Marshal StaticEnt -> blt_grid_tile_t (dst/src are map-coord, 8px-aligned).
        std::vector<blt_grid_tile_t> tiles; tiles.reserve(b.ent.size());
        bool tokenless = false;
        for (const auto& e : b.ent) {
            if (e.pid == 0xFFFF) { tokenless = true; break; }  // no identity -> can't grid
            tiles.push_back({ e.pid, (uint16_t)(e.dx / 8), (uint16_t)(e.dy / 8),
                              (uint8_t)(e.w / 8), (uint8_t)(e.h / 8) });
        }
        d->grid_scratch.assign((size_t)gw * gh, 0);
        if (!tokenless &&
            blt_grid_build(d->grid_scratch.data(), gw, gh, tiles.data(), tiles.size()) == 0) {
            // One-shot copy into the GRID_BUF DDR region (written once per map;
            // fabric reads it only after this frame's command emit + barrier).
            std::memcpy((void*)(d->ddr + off), d->grid_scratch.data(),
                        (size_t)gw * gh * sizeof(blt_grid_cell_t));
            b.grid_off = off; b.grid_w = gw; b.grid_h = gh; b.grid_ok = true;
        }
    } else if (d->diag) {
        std::fprintf(stderr,
            "[blitter grid] GRID_BUF full: bucket layer=%d falls back to replay (need %u B)\n",
            b.layer, bytes);
    }
}
```
Notes for the implementer:
- `blt_grid_build` returns `-1` if any tile violates bounds (e.g. `dx/8 + w/8 > gw`); on `-1` leave `grid_ok=false` (that bucket replays). This is a safety net, not an expected path.
- A `tokenless` bucket (any `pid==0xFFFF`) cannot be gridded — replay it.
- `d->ddr` is `volatile uint8_t*`; the `(void*)` cast for the one-shot bulk write is deliberate and safe here (single write per map, ordered before the fabric read by the existing end-of-frame barrier).

- [ ] **Step 4: Type-check the renderer**

Run the `g++ -fsyntax-only` recipe. Expected: exit 0. (Watch for `<cstring>` needed for `memcpy` — add the include if the compiler flags it.)

- [ ] **Step 5: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "feat(blitter): build per-bucket static grids into GRID_BUF at arm"
```

---

## Task 7: `SOLARUS_TILEMAPCH` flag + grid emit at the seam

Parse the gate flag (default OFF) and, when on, emit one `BLT_OP_TILEMAP` per gridded static bucket at `resident_emit_static_layer`, falling back to per-bucket replay for the flag or for any `!grid_ok` bucket. Factor the camera/parallax bias so grid-emit and replay use one source of truth.

**Files:**
- Modify (whole-file copy): `patches/mister/mister_blitter_renderer.cpp` — `Impl` (add `bool tilemapch=false;`), the flag parse (near the `spritech`/`scrollfab` parses, `:2426`/`:2437`), a bias helper, `resident_emit_static_layer` (`:3203-3211`), and `res_emit_static_bucket_` (`:3131`) to use the shared bias helper.

**Interfaces:**
- Consumes: `mister_flag_default_off` (the OFF-default sibling of `mister_flag_default_on` used at `:2426`; confirm its exact name via grep), Task 6's `grid_off`/`grid_w`/`grid_h`/`grid_ok`, `blt_grid_list` (`blt_emitter.h`), `res_bucket_params` (`:1877`) for `tex`/blend/key/flags/pal, the existing bias math inside `res_emit_static_bucket_`.
- Produces: nothing consumed downstream (terminal wiring).

- [ ] **Step 1: Confirm the OFF-default flag helper name**

Run: `grep -n 'mister_flag_default_off\|mister_flag_default_on' patches/mister/mister_blitter_renderer.cpp | head`
Use `mister_flag_default_off` if present; else replicate `mister_flag_default_on`'s logic inverted (default false unless env == "1").

- [ ] **Step 2: Add the flag field + parse**

Add `bool tilemapch = false;` to `Impl`. Next to the `scrollfab` parse (`:2437`), add:
```cpp
self->d->tilemapch = mister_flag_default_off("SOLARUS_TILEMAPCH");
if (self->d->tilemapch)
  std::fprintf(stderr, "[MiSTer blitter] tilemap channel ENABLED (SOLARUS_TILEMAPCH)\n");
```

- [ ] **Step 3: Extract a shared bias helper**

Inside `res_emit_static_bucket_` (`:3131`), locate the code computing the per-bucket destination bias (`ratio<=1 → bias=-camera`; `ratio>1 → bias=camera/ratio-camera`; plus `scroll_bias_x()/scroll_bias_y()`). Extract it into a private method:
```cpp
void MisterBlitterRenderer::static_bucket_bias_(const Impl::StaticBucket& b, int& bx, int& by) const;
```
Declare it in `mister_blitter_renderer.h` (private, near `res_emit_static_bucket_` at `:102`). Have `res_emit_static_bucket_` call it (behaviour-preserving refactor — the replay path output must not change).

- [ ] **Step 4: Grid-emit at the seam**

Rewrite `resident_emit_static_layer` (`:3203`):
```cpp
void MisterBlitterRenderer::resident_emit_static_layer(int layer) {
  d->flush_sprites_before_other_op();   // keep buffered sprites UNDER this op (unchanged)
  for (size_t i = 0; i < d->res_static_ops.size(); ++i) {
    if (d->res_static_ops[i].layer != layer) continue;
    const size_t bi = d->res_static_ops[i].bk;
    Impl::StaticBucket& b = d->res_static_buckets[bi];
    if (d->tilemapch && b.grid_ok) {
      blt_surface_ref_t tex; uint8_t bl, fl, fmt, pal_id, pal_base; uint16_t key;
      if (d->res_bucket_params(*b.tsimg, (BlendMode)b.blend, tex, bl, key, fl, fmt, pal_id, pal_base)) {
        int bx, by; static_bucket_bias_(b, bx, by);
        const uint16_t pal_color = (fmt == BLT_FMT_PAL8) ? blt_pal_color(pal_id, pal_base) : 0;
        blt_grid_list(&d->em, tex, bl, key, /*alpha=*/0xFF, fl,
                      b.grid_off, b.grid_w, b.grid_h,
                      (int16_t)bx, (int16_t)by, pal_color);
        continue;
      }
    }
    res_emit_static_bucket_(bi);   // flag OFF, !grid_ok, or params miss -> replay (unchanged)
  }
}
```
Confirm `blt_pal_color`'s exact name/signature via `grep -n 'blt_pal_color' patches/mister/blitter/*.h` and match the PAL8 branch used elsewhere in this file (e.g. how `res_emit_static_bucket_` derives `pal_color`). Match `res_bucket_params`' actual out-param order from `:1877`.

- [ ] **Step 5: Type-check the renderer**

Run the `g++ -fsyntax-only` recipe. Expected: exit 0.

- [ ] **Step 6: In-container engine build (grep BUILD_EXIT)**

Run: `scripts/docker_run.sh bash scripts/build_engine.sh 2>&1 | tee /tmp/b3_build.log; grep BUILD_EXIT /tmp/b3_build.log`
Expected: `BUILD_EXIT=0`. (Do NOT trust the task exit code — grep the marker, per Global Constraints.)

- [ ] **Step 7: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp patches/mister/mister_blitter_renderer.h
git commit -m "feat(blitter): emit BLT_OP_TILEMAP per static bucket behind SOLARUS_TILEMAPCH"
```

---

## Task 8: Deploy prep + DDR GRID_BUF-tail HW-soak

Refresh the deploy artifacts from the container build and HW-soak the grown GRID_BUF DDR tail (`0x3C000000..0x3C200000`) before any grid traffic runs there — only the pre-B1 16 MiB was ever pattern-verified.

**Files:**
- Modify: `deploy/libs/` (refreshed `libsolarus.so.1.6.5`, `solarus-run` from `build/armhf/`)

**Interfaces:**
- Consumes: the Task-7 container build output in `build/armhf/`.

- [ ] **Step 1: Refresh deploy artifacts + verify sha1**

Run:
```bash
cp build/armhf/libsolarus.so.1.6.5 build/armhf/solarus-run deploy/libs/ 2>/dev/null || \
  cp build/armhf/libsolarus.so.1.6.5 deploy/games/Solarus/libs/   # match the repo's real deploy layout
sha1sum build/armhf/libsolarus.so.1.6.5 deploy/**/libsolarus.so.1.6.5
```
Expected: identical sha1 for source and deployed copy. (Confirm the actual deploy path — `deploy/libs/` vs `deploy/games/Solarus/libs/` — with `ls deploy` and the deploy memory before copying.)

- [ ] **Step 2: Deploy to device (engine only, existing B2 RBF)**

Run: `./deploy.py --no-rbf --host 192.168.20.81`
Then sha1-verify on device:
`ssh root@192.168.20.81 'sha1sum /media/fat/games/Solarus/libs/libsolarus.so.1.6.5'`
Expected: matches the local sha1 (deploy.py exit 0 alone is not proof — a partial scp truncates).

- [ ] **Step 3: HW-soak the grown DDR tail**

On device, pattern-write/verify the 2 MiB GRID_BUF tail before trusting it. Use the project's existing DDR probe idiom (busybox `devmem`, or the arena-probe path). Minimum viable check — write a known 32-bit pattern across a sample of the tail and read it back:
```bash
ssh root@192.168.20.81 'for a in 0x3C000000 0x3C080000 0x3C100000 0x3C1F0000; do \
  busybox devmem $a 32 0xA5A5F00F; v=$(busybox devmem $a 32); echo "$a -> $v"; done'
```
Expected: every readback returns `0xA5A5F00F`. (If the repo has a fuller soak script under `scripts/`, prefer it. Do NOT overwrite `0x3C1F3000`+ — that is the FRT region above GRID_BUF.)

- [ ] **Step 4: Commit deploy artifacts (if tracked) / record soak result**

If `deploy/` libs are gitignored ship artifacts (per CLAUDE.md they are), do NOT commit binaries; instead record the soak result in the HW-validation doc created in Task 9. Otherwise:
```bash
git add deploy
git commit -m "chore(deploy): refresh engine for B3 tilemap channel"
```

---

## Task 9: HW gate — map 119 + map 3 A/B (operator's eyes)

Objective checks all pass in CI/host; the visual gate is the operator's, never self-declared (memory `solarus-no-self-declared-visual-validation`). A/B `SOLARUS_TILEMAPCH` on vs off on the two acceptance maps; pass = no visible difference.

**Files:**
- Create: `docs/superpowers/2026-07-21-stage3b-phaseB3-hw-validation.md` (the validation record)

**Interfaces:**
- Consumes: the deployed engine (Task 8) on the B2 RBF.

- [ ] **Step 1: Confirm the loaded RBF is the B2 tilemap core**

Run: `ssh root@192.168.20.81 'cat /tmp/CORENAME 2>/dev/null; ls -la /media/fat/_Other/Solarus_*.rbf'`
Confirm CORENAME=Solarus and the loaded RBF is the B2 core (`Solarus_20260721.rbf` or successor). An opcode sent to a fabric with no tilemap arm falls through to FILL/BLIT and looks like corruption — this step prevents mis-attributing that.

- [ ] **Step 2: Launch flag-OFF baseline (map 119), capture**

Leave `Solarus.s0` empty; launch with a private `S0_FILE` override and `SOLARUS_TILEMAPCH=0`, logging to `/media/fat/logs/Solarus/`. Teleport/navigate to map 119 "Outside world C3". Capture a screenshot via the mrext recipe (memory `solarus-120-paletted-hw-validation-fail` has it). Repeat for map 3 "Outside world A3".

- [ ] **Step 3: Launch flag-ON (map 119 + map 3), capture**

Relaunch with `SOLARUS_TILEMAPCH=1`. Navigate to the same two maps, same camera positions. Capture screenshots. Watch the log for `tilemap channel ENABLED`, any `GRID_BUF full` fallback lines, and any `res_fatal`.

- [ ] **Step 4: Operator A/B verdict**

Present both pairs (OFF vs ON, map 119 and map 3) to the operator. Pass condition: **no visible difference** on either map (grid walk is pixel-equivalent to bucket replay). Record the operator's verdict verbatim. Do NOT self-declare.

- [ ] **Step 5: Record the measured (not gated) cyc/px**

With the flag ON on map 119, read the `tilemap_unit` throughput counter (the fabric HW counter used in prior throughput sessions; see `docs/superpowers/2026-06-25-compositor-throughput-session.md`). Record cyc/px so the throughput workstream starts from a measurement, not an estimate. This is NOT a gate — record it whatever it is.

- [ ] **Step 6: Write the validation doc + commit**

Write `docs/superpowers/2026-07-21-stage3b-phaseB3-hw-validation.md`: the RBF confirmed, DDR soak result (Task 8), the A/B verdict per map, any fallback/`res_fatal` log lines, and the map-119 cyc/px. Then:
```bash
git add docs/superpowers/2026-07-21-stage3b-phaseB3-hw-validation.md
git commit -m "docs(stage3b): B3 tilemap channel HW validation"
```

---

## Self-Review

**Spec coverage (against `2026-07-21-...phaseB3-engine-wiring-design.md`):**
- §2 data lifecycle (build on map change, emit per frame) → Tasks 6 (build at arm) + 7 (emit at seam). ✓
- §3 flag-gated seam → Task 7. ✓
- §4 engine patch #1 (tokens) → Task 4; patch #2 (map dims) → Task 5. ✓
- §5 GRID_BUF allocator (bump, qword-align, grid_cap → graceful per-layer/bucket fallback) → Task 1 (pure) + Task 6 (wiring). ✓
- §6 pattern-table overflow → `res_fatal` → Task 4 Step 4 reuses the existing `>= BLT_MAXP` guard. ✓
- §7 per-layer fallback wired, coverage-trigger disabled → Task 6/7 drive `grid_ok` only from GRID_BUF-fit; no coverage threshold introduced. ✓
- §8 cell-bitfield cross-check → Task 3; DDR tail soak → Task 8 Step 3. ✓
- §9 objective gate (host equivalence, host suite, wire check, type-check, in-container build) → Tasks 2/1/3/(4-7 type-check)/7 Step 6; visual gate (map 119/3 A/B) → Task 9; measured cyc/px → Task 9 Step 5. ✓
- §10 process discipline (container build + BUILD_EXIT, series vs whole-file, sha1 deploy, HW hygiene) → folded into Tasks 4-9. ✓
- §1 out-of-scope items → none introduced. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step carries concrete code or an exact grep-then-mirror instruction. Steps that say "match the existing style" name the exact neighbouring line to copy from. ✓

**Type consistency:** `resident_record_static(...tokens)` signature identical in Task 4 Steps 1/3/4. `StaticEnt.pid` (`uint16_t`, `0xFFFF` sentinel) introduced Task 4, consumed Task 6. `StaticBucket.{grid_off,grid_w,grid_h,grid_ok}` introduced Task 6, consumed Task 7. `blt_grid_alloc_take` returns region-relative offset (Task 1) matching `blt_grid_list`'s `cells_off` domain (Task 6/7). `static_bucket_bias_` declared + used consistently in Task 7. ✓

**Note on unverifiable-until-implementation details:** several steps say "confirm exact name/param-order via grep" (`mister_flag_default_off`, `blt_pal_color`, `res_bucket_params` out-params, `TileInfo.pattern`). These are real symbols in the tree; the grep is a guard against a stale line number, not a placeholder — each step names the concrete symbol and the file to confirm it in.
