# Load-Progress Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the dirty-BRAM garbage shown during `preload_quest_assets()` with a FILL-based load-progress bar (issue #72).

**Architecture:** Engine-only, no RTL change. A tiny pure helper computes the bar's fill width; the renderer emits background/track/fill rects via the existing `blt_fill` primitive into the WORK framebuffer, and the existing `submit_and_drain()` → fabric snapshot path carries the composited bar to the SCAN buffer that scanout reads. The bar is painted at 0% before the stage loop (kills garbage at frame 0) and repainted at each existing drain seam (zero extra submits).

**Tech Stack:** C++17 renderer (`patches/mister/mister_blitter_renderer.cpp`), C blitter emitter (`blt_fill`), host C unit-test harness (`tests/run_tests.sh`), armhf Docker cross-build, DE10-Nano HW.

## Global Constraints

- **Gate:** all bar behavior behind `SOLARUS_LOADBAR`, **default-on / opt-out**, via the existing `mister_flag_default_on("SOLARUS_LOADBAR")` (empty/unset/non-`0` → ON).
- **No fabric/RTL change.** Bar is built only from `blt_fill(em, x, y, w, h, uint16_t rgb565)`.
- **No atlas/font dependency.** No text; rects only.
- **FB geometry:** `FB_W = 320`, `FB_H = 240` (constants already at `mister_blitter_renderer.cpp:283`).
- **Whole-file workflow:** `mister_blitter_renderer.cpp` and any new header under `patches/mister/` are **whole-file MiSTer additions** copied by `scripts/apply_mister_files.sh` — edit the file under `patches/mister/` directly; do NOT run `export_patches.sh` (that regenerates the upstream series patches only).
- **Real build gate is armhf Docker gcc**, not host clang: `docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_engine.sh` must print `Built target solarus-run`. Host `g++ -fsyntax-only` is a necessary-not-sufficient pre-check (Apple clang is more permissive than armhf gcc).

---

### Task 1: Pure bar-width helper + unit test

**Files:**
- Create: `patches/mister/loadbar.h`
- Test: `tests/loadbar_test.c`
- Modify: `tests/run_tests.sh` (add compile+run block)

**Interfaces:**
- Produces: `int loadbar_fill_w(int track_w, uint32_t staged, uint32_t total)` — returns the filled width in pixels, clamped to `[0, track_w]`. `total == 0` or `staged == 0` → `0`; `staged >= total` → `track_w`; otherwise `floor(track_w * staged / total)` computed in 64-bit to avoid overflow. Header-only `static inline`, includes only `<stdint.h>`, no SDL/Solarus deps (so it links into both the renderer and the host test).

- [ ] **Step 1: Write the failing test**

Create `tests/loadbar_test.c`:

```c
/* Host unit test for loadbar_fill_w — the pure bar-width math (issue #72).
 * The renderer itself can't be unit-tested on the host (pulls in SDL/Solarus),
 * so the only branch-worthy logic (fraction + clamp + divide-by-zero guard) is
 * factored into loadbar.h and exercised directly here.
 *
 * Build+run (from repo root):
 *   cc -Wall -Wextra -O2 -I patches/mister \
 *       tests/loadbar_test.c -o /tmp/loadbar_test && /tmp/loadbar_test
 */
#include "loadbar.h"
#include <stdio.h>
#include <stdint.h>

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s (line %d)\n", msg, __LINE__); failures++; } \
} while (0)

int main(void)
{
    /* empty: 0 staged -> 0 width */
    CHECK(loadbar_fill_w(200, 0, 331) == 0, "0/331 -> 0");
    /* full: staged == total -> full track */
    CHECK(loadbar_fill_w(200, 331, 331) == 200, "331/331 -> 200");
    /* half: 165/330 -> 100 */
    CHECK(loadbar_fill_w(200, 165, 330) == 100, "165/330 -> 100");
    /* floor: 1/331 -> 0 (monotonic, never negative) */
    CHECK(loadbar_fill_w(200, 1, 331) == 0, "1/331 -> 0 (floor)");
    /* divide-by-zero guard: total == 0 -> 0 */
    CHECK(loadbar_fill_w(200, 5, 0) == 0, "total==0 -> 0");
    /* over-count clamp: staged > total -> full track (never over-wide) */
    CHECK(loadbar_fill_w(200, 400, 331) == 200, "400/331 clamp -> 200");
    /* no 32-bit overflow at large counts */
    CHECK(loadbar_fill_w(200, 3000000u, 6000000u) == 100, "3e6/6e6 -> 100 (no overflow)");

    if (failures) { printf("loadbar: %d FAILURES\n", failures); return 1; }
    printf("loadbar: all checks passed\n");
    return 0;
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cc -Wall -Wextra -O2 -I patches/mister tests/loadbar_test.c -o /tmp/loadbar_test`
Expected: FAIL — `fatal error: 'loadbar.h' file not found`.

- [ ] **Step 3: Write minimal implementation**

Create `patches/mister/loadbar.h`:

```c
// Pure load-progress-bar geometry math (issue #72). Header-only, no SDL/Solarus
// deps so it links into both mister_blitter_renderer.cpp and the host unit test.
//
// loadbar_fill_w: filled width in pixels for `staged`/`total` progress across a
// `track_w`-pixel track. Clamped to [0, track_w]; guards total==0.
#ifndef MISTER_LOADBAR_H
#define MISTER_LOADBAR_H

#include <stdint.h>

static inline int loadbar_fill_w(int track_w, uint32_t staged, uint32_t total)
{
    if (total == 0u || staged == 0u) return 0;
    if (staged >= total)             return track_w;
    // 64-bit product so track_w*staged can't overflow at large asset counts.
    return (int)(((uint64_t)(uint32_t)track_w * staged) / total);
}

#endif // MISTER_LOADBAR_H
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cc -Wall -Wextra -O2 -I patches/mister tests/loadbar_test.c -o /tmp/loadbar_test && /tmp/loadbar_test`
Expected: PASS — `loadbar: all checks passed`, exit 0.

- [ ] **Step 5: Wire the test into the harness**

In `tests/run_tests.sh`, append this block after the last existing test block (before any final summary/`echo`), matching the file's existing style:

```bash
echo "== loadbar (issue #72 progress-bar width math) =="
$CC -Wall -Wextra -O2 -I patches/mister \
    tests/loadbar_test.c \
    -o /tmp/loadbar_test
/tmp/loadbar_test
```

- [ ] **Step 6: Run the whole harness**

Run: `bash tests/run_tests.sh`
Expected: all prior tests still pass AND `loadbar: all checks passed` appears; script exits 0 (`set -e`).

- [ ] **Step 7: Commit**

```bash
git add patches/mister/loadbar.h tests/loadbar_test.c tests/run_tests.sh
git commit -m "feat(#72): pure load-progress bar width helper + host test

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01XUFr7poWoUEg6h5n4Bd84u"
```

---

### Task 2: Renderer integration (pre-count, paint, wiring)

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` (add include + 4 members + 3 methods; wire `preload_quest_assets()` at ~924–975 and the drain seam in `preload_stage_one()` at ~989–1001)
- Modify: `scripts/apply_mister_files.sh:17` region (copy `loadbar.h` into the tree)

**Interfaces:**
- Consumes: `loadbar_fill_w(int, uint32_t, uint32_t)` from Task 1 (`loadbar.h`); existing `blt_fill`, `blt_begin_frame`, `submit_and_drain()`, `mister_flag_default_on`, `FB_W`/`FB_H`, `target_buf`, `QuestFiles::data_file_list_dir`, `QuestFiles::data_file_is_dir`, `ends_with_png`.
- Produces: no new external symbols (all changes are private to the renderer `Impl`).

- [ ] **Step 1: Ensure `loadbar.h` is copied into the build tree**

In `scripts/apply_mister_files.sh`, directly after the line
`cp patches/mister/mister_blitter_renderer.cpp "$MDST/"`, add:

```bash
cp patches/mister/loadbar.h                 "$MDST/"
```

(Both files land in the same renderer dir `$MDST`, so the `#include "loadbar.h"` resolves.)

- [ ] **Step 2: Add the include**

In `patches/mister/mister_blitter_renderer.cpp`, next to the existing blitter include
`#include "blitter/blt_emitter.h"` (~line 28), add:

```cpp
#include "loadbar.h"                  // issue #72: pure bar-width math
```

- [ ] **Step 3: Add loadbar members + geometry constants + methods**

Add these `static const` geometry constants near the existing `constexpr int FB_W = 320, FB_H = 240;` (line 283), at file scope:

```cpp
// [#72] Load-progress bar geometry (RGB565) + colors. Centered on the 320x240 FB.
static const int      LOADBAR_TRACK_W = 200;
static const int      LOADBAR_TRACK_H = 12;
static const int      LOADBAR_TRACK_X = (FB_W - LOADBAR_TRACK_W) / 2;   // 60
static const int      LOADBAR_TRACK_Y = 150;
static const uint16_t LOADBAR_BG      = 0x0000;   // black background
static const uint16_t LOADBAR_TRACK   = 0x4208;   // dark gray (empty)
static const uint16_t LOADBAR_FILL    = 0xFFFF;   // white (filled)
```

Inside the renderer `Impl` struct, near the other preload/residency members, add:

```cpp
// [#72] load-progress-bar state (set in preload_quest_assets, read in the drain seam)
bool     loadbar_on     = false;   // cached SOLARUS_LOADBAR gate
uint32_t preload_total  = 0;       // total PNGs to stage (pre-count)
uint32_t preload_staged = 0;       // PNGs staged so far
```

Add these three methods to the `Impl` struct (place them just above `preload_quest_assets()`):

```cpp
// [#72] Count quest PNGs without decoding — directory listing only. Denominator
// for the progress bar. Mirrors the stage-loop walk shape but never loads a surface.
uint32_t count_quest_pngs() {
  uint32_t n = 0;
  std::vector<std::string> stack{ std::string() };
  while (!stack.empty()) {
    std::string dir = stack.back(); stack.pop_back();
    for (const std::string& name : Solarus::QuestFiles::data_file_list_dir(dir)) {
      std::string path = dir.empty() ? name : dir + "/" + name;
      if (Solarus::QuestFiles::data_file_is_dir(path)) { stack.push_back(path); continue; }
      if (ends_with_png(path)) ++n;
    }
  }
  return n;
}

// [#72] Emit the bar's three FILL rects into the CURRENTLY-OPEN frame (no begin/submit).
// Full-screen bg fill makes each frame self-contained (idempotent) regardless of WORK
// persistence; then track, then the growing fill. Composites into WORK -> snapshot -> SCAN.
void emit_loadbar_fills() {
  if (!loadbar_on) return;
  blt_fill(&em, 0, 0, FB_W, FB_H, LOADBAR_BG);
  blt_fill(&em, LOADBAR_TRACK_X, LOADBAR_TRACK_Y, LOADBAR_TRACK_W, LOADBAR_TRACK_H, LOADBAR_TRACK);
  int fw = loadbar_fill_w(LOADBAR_TRACK_W, preload_staged, preload_total);
  if (fw > 0)
    blt_fill(&em, LOADBAR_TRACK_X, LOADBAR_TRACK_Y, fw, LOADBAR_TRACK_H, LOADBAR_FILL);
}

// [#72] Paint one standalone bar frame (own begin_frame + submit). Used for the
// initial 0% (kills garbage at frame 0) and any point not piggybacking a stage drain.
void paint_loadbar() {
  if (!loadbar_on) return;
  blt_begin_frame(&em, target_buf, /*clear=*/0, /*clear_color=*/0x0000);
  emit_loadbar_fills();
  submit_and_drain();
}
```

- [ ] **Step 4: Wire the initial paint + counters into `preload_quest_assets()`**

In `preload_quest_assets()` (line 924), immediately after the `SOLARUS_PRELOAD`
gate returns (after line 934, `if (!mister_flag_default_on("SOLARUS_PRELOAD")) return;`)
and BEFORE the existing `blt_begin_frame(&em, target_buf, /*clear=*/0, ...)` at line 936,
insert:

```cpp
    // [#72] Load-progress bar: count PNGs for the denominator, paint 0% now so the
    // scanout shows a clean bar instead of dirty WORK-BRAM garbage during staging.
    loadbar_on     = mister_flag_default_on("SOLARUS_LOADBAR");
    preload_total  = loadbar_on ? count_quest_pngs() : 0;
    preload_staged = 0;
    paint_loadbar();   // no-op if loadbar_on == false
```

In the same function's staging loop, increment the counter once per staged PNG.
The loop stages via `preload_stage_one(impl, pfmt);` (line 964). Immediately after
that call, add:

```cpp
        ++preload_staged;
```

Finally, paint 100% on the final flush. The function ends the walk then calls
`submit_and_drain();` (line 967). Immediately BEFORE that `submit_and_drain();`, add:

```cpp
    preload_staged = preload_total;   // [#72] guarantee the bar reads 100% on the last frame
    emit_loadbar_fills();             // into the final open frame -> snapshot shows full bar
```

- [ ] **Step 5: Wire the drain-seam repaint into `preload_stage_one()`**

In `preload_stage_one()` (line 982), the overflow path drains mid-load at line 993
(`submit_and_drain();`). Immediately BEFORE that `submit_and_drain();`, add:

```cpp
      emit_loadbar_fills();   // [#72] advance the bar on the drain we're about to submit
```

(This emits into the already-open stage frame — the FILLs target WORK BRAM, disjoint
from the SDRAM stage ops — so the snapshot carries the advanced bar with zero extra submits.)

- [ ] **Step 6: Host type-check the renderer**

Run:

```bash
g++ -std=c++17 -fsyntax-only \
  -I patches/mister -I work/solarus/include -I build/armhf/include \
  -I work/solarus/libraries/win32/mingw32/include \
  -I/opt/homebrew/include -I/opt/homebrew/include/SDL2 -D_THREAD_SAFE \
  patches/mister/mister_blitter_renderer.cpp
```

Expected: exit 0, no output. (If `work/solarus`/`build/armhf` aren't present yet, run
one Docker build first to populate them, or skip straight to Step 7 which is the real gate.)

- [ ] **Step 7: armhf Docker build (the real gate)**

Run:

```bash
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_engine.sh
```

Expected: ends with `Built target solarus-run`; produces `build/armhf/solarus-run` and
`build/armhf/libsolarus.so.1.6.5`. This also proves `apply_mister_files.sh` copied
`loadbar.h` (else the include fails).

- [ ] **Step 8: Re-run the host test harness (guard against regressions)**

Run: `bash tests/run_tests.sh`
Expected: all tests pass, exit 0.

- [ ] **Step 9: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp scripts/apply_mister_files.sh
git commit -m "feat(#72): load-progress bar during bulk SDRAM asset residency

Pre-count PNGs, paint bar at 0% before staging (kills dirty-BRAM garbage at
frame 0), repaint at each existing drain seam (piggyback, zero extra submits),
100% on final flush. FILL-only, no atlas/font. Behind SOLARUS_LOADBAR (opt-out).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01XUFr7poWoUEg6h5n4Bd84u"
```

---

### Task 3: HW validation on DE10-Nano (MoSDX)

**Files:** none (validation only). Uses `deploy.py` + on-device probes.

**Interfaces:** consumes the `build/armhf/` artifacts from Task 2.

- [ ] **Step 1: Refresh deploy artifacts + push engine**

```bash
cp build/armhf/libsolarus.so.1.6.5 deploy/libs/
cp build/armhf/solarus-run         deploy/
./deploy.py --no-rbf --host 192.168.20.81
```

(No RBF rebuild — this change is engine-only.) Verify the pushed `.so` matches
`build/armhf` (kill+rm the old open file first if the copy is refused — FAT can't
overwrite an open exe): `ssh root@192.168.20.81 'md5sum /media/fat/games/solarus/libs/libsolarus.so.1.6.5'`
should equal `md5sum build/armhf/libsolarus.so.1.6.5`.

- [ ] **Step 2: Relaunch and watch the load window**

Load the Solarus core from the OSD (so the fabric is live), pick MoSDX, and during
the several-second asset load capture the screen:

```bash
ssh root@192.168.20.81 'echo screenshot > /dev/MiSTer_cmd'
```

Take 2–3 shots across the load window (start / mid / end).

Expected:
- **No garbage** at any point during the load — the screen shows the bar over a black background.
- The white fill **advances 0 → 100%** monotonically as staging proceeds.
- After the load, the overworld renders normally (bar overwritten by the first gameplay frame).

- [ ] **Step 3: Confirm the opt-out gate**

Relaunch with `SOLARUS_LOADBAR=0` (via the launch env) and confirm the old behavior
returns (no bar; pre-fix dirty frames may appear) — proves the gate cleanly disables
the feature.

- [ ] **Step 4: Record the result**

Note pass/fail + screenshots in the issue #72 thread (or a session log). If the bar
colors/geometry read poorly on the real display, tune the `LOADBAR_*` constants in
Task 2 Step 3 and rebuild — no logic change.

---

## Self-Review

**Spec coverage:**
- Problem (dirty WORK-BRAM → SCAN garbage) → Task 2 Steps 4–5 paint clean frames across the whole window. ✓
- FILL-based bar, no atlas/font → Task 2 Step 3 (`emit_loadbar_fills`, rects only). ✓
- PNG pre-count denominator → Task 2 Step 3 (`count_quest_pngs`) + Step 4 wiring. ✓
- Paint 0% before staging → Task 2 Step 4 (`paint_loadbar()` before line 936). ✓
- Piggyback repaint at existing drain seams, zero extra submits → Task 2 Step 5. ✓
- 100% on final flush → Task 2 Step 4 (final `emit_loadbar_fills` before line 967). ✓
- `SOLARUS_LOADBAR` default-on gate → Task 2 Step 4 (`loadbar_on`), enforced in both `emit_loadbar_fills`/`paint_loadbar`. ✓
- Edge: `total==0` no divide-by-zero → Task 1 helper + test. ✓
- Edge: software path / `SOLARUS_PRELOAD=0` skip → inherited (bar wiring sits after the existing `!ddr` and `SOLARUS_PRELOAD` early-returns at lines 927/934). ✓
- Edge: `staged>total` clamp → Task 1 helper + test. ✓
- Testing: native type-check + armhf Docker + HW screenshot → Task 2 Steps 6–7, Task 3. ✓

**Placeholder scan:** none — all code shown in full, exact line anchors and commands given.

**Type consistency:** `loadbar_fill_w(int, uint32_t, uint32_t)` identical in Task 1 (def+test) and Task 2 (call). Members `loadbar_on`/`preload_total`/`preload_staged` defined once (Task 2 Step 3) and used consistently in Steps 4–5. Methods `count_quest_pngs`/`emit_loadbar_fills`/`paint_loadbar` defined and called by the same names. ✓
