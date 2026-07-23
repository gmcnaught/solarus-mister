# Map 119 Background-Fill Attribution Probe — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure how much of map 119's ~15 ms non-comp fabric slice is the fabric's per-cell walk of the two big opaque background fills (ground pattern 7, parallax sky 1201), to make a data-driven go/no-go on the Phase-1 tiled-fill RTL op.

**Architecture:** An env-gated engine-only probe (`SOLARUS_BGFILLPROBE`). At resident-record time it finds, per static bucket, the pid covering the largest total area, records that region as a solid-fill rect, and drops those entries from the bucket. At emit time it paints that region with one existing `BLT_OP_FILL` (debug magenta) instead of walking the cells. It is deliberately visually wrong — this measures fabric time via the existing `[blitter hwperf]` counters. No RTL, no RBF rebuild: it runs against the current ship RBF (`Solarus_20260723.rbf`).

**Tech Stack:** C++17 renderer (`patches/mister/mister_blitter_renderer.cpp`, a whole-file copy — edit directly), C blitter emitter (`patches/mister/blitter/`), C host tests (`tests/`), armhf Docker build (`scripts/build_engine.sh`), device A/B over SSH (`scripts/perf/`).

## Global Constraints

- Engine source `mister_blitter_renderer.cpp` and `patches/mister/blitter/*` are **whole-file copies** — edit directly, NOT via `patches/series/`. Do not regenerate a patch.
- `StaticBucket` (renderer) **must stay an aggregate** (brace-init at the record path, no default member initializers). Do NOT add fields to it — use a parallel `std::vector` on `Impl`.
- Native type-check is only meaningful WITH both flags: `-DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO` (nearly all renderer code is under `#ifdef MISTER_NATIVE_VIDEO`; omitting them type-checks almost nothing and falsely passes).
- Flag default: probe is **OFF** by default (presence-gated `std::getenv` like `SOLARUS_GRIDOV`), never `mister_flag_default_on`. It is a diagnostic, not a shipping default.
- Never reuse reserved wire constant `OP_BGPLANE_WRITE = 8` / `BLT_F_BGCOV`.
- Visual correctness is **operator-confirmed**, never self-declared (`solarus-no-self-declared-visual-validation`). The probe's "correct" outcome is: magenta fills appear exactly over the sky + ground, decorations/sprites/HUD still paint on top.
- Device IP `192.168.20.81`; deploy root `/media/fat/games/solarus/`; log at `/media/fat/logs/Solarus/`.

---

## File Structure

- **Create** `patches/mister/blitter/mister_bgfill_probe.h` — the pure, testable selection helper (`bgfill_pick`). One responsibility: given a bucket's entries, pick the max-total-area pid and its bounding box. No renderer/SDL dependencies.
- **Create** `tests/bgfill_probe_test.c` — host unit test for `bgfill_pick`.
- **Modify** `patches/mister/mister_blitter_renderer.cpp` — flag parse; parallel `res_bgfill` vector + `BgFillProbe` POD; record-time call to `bgfill_pick` + entry removal; emit-time `blt_fill`.
- **Modify** `tests/run_tests.sh` — wire the new host test into the suite.
- **Create** `scripts/perf/bgfillprobe_ab.sh` — one-leg device capture (probe off vs on, same current-ship RBF), adapted from `scripts/perf/stage5_ab_cache.sh`.
- **Create** `docs/superpowers/2026-07-22-map119-bgfillprobe-attribution.md` — measured results + the Phase-1 go/no-go decision.

---

### Task 1: Pure selection helper `bgfill_pick` (TDD)

**Files:**
- Create: `patches/mister/blitter/mister_bgfill_probe.h`
- Test: `tests/bgfill_probe_test.c`
- Modify: `tests/run_tests.sh`

**Interfaces:**
- Produces:
  ```c
  typedef struct { int dx, dy, w, h; unsigned short pid; } bgfill_ent_t;
  /* Pick the pid covering the largest total area (sum w*h) across ents, ignoring
   * tokenless entries (pid == 0xFFFF). If that pid's total area >= area_min, write
   * its pid and the bounding box [x0,y0)-(x1,y1) of its entries and return 1.
   * Otherwise return 0 and leave outputs untouched. */
  int bgfill_pick(const bgfill_ent_t *ents, unsigned long n, unsigned long area_min,
                  unsigned short *out_pid, int *x0, int *y0, int *x1, int *y1);
  ```

- [ ] **Step 1: Write the failing test**

Create `tests/bgfill_probe_test.c`:
```c
#include "mister_bgfill_probe.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    /* Ground pid=7 as 3 big rects (coalesced) + two small pid=9 decorations. */
    bgfill_ent_t ents[] = {
        {  0,   0, 320, 240, 7 },   /* 76800 px */
        {320,   0, 320, 240, 7 },   /* 76800 px */
        {  0, 240, 640, 264, 7 },   /* 168960 px -> pid 7 total 322560 */
        { 16,  16,   8,   8, 9 },
        { 48,  16,   8,   8, 9 },   /* pid 9 total 128 px */
    };
    unsigned short pid = 0; int x0=0,y0=0,x1=0,y1=0;
    int hit = bgfill_pick(ents, 5, /*area_min=*/0x8000, &pid, &x0,&y0,&x1,&y1);
    assert(hit == 1);
    assert(pid == 7);
    assert(x0 == 0 && y0 == 0 && x1 == 640 && y1 == 504);
    printf("bbox pid=%u [%d,%d)-(%d,%d) OK\n", pid, x0, y0, x1, y1);

    /* No dominant fill: all small -> below area_min -> no hit. */
    bgfill_ent_t small[] = { {0,0,8,8,1}, {8,0,8,8,2}, {16,0,8,8,3} };
    int hit2 = bgfill_pick(small, 3, 0x8000, &pid, &x0,&y0,&x1,&y1);
    assert(hit2 == 0);

    /* Tokenless (pid 0xFFFF) is ignored even if largest. */
    bgfill_ent_t tok[] = { {0,0,640,504,0xFFFF}, {0,0,200,200,5} };  /* 40000 px */
    int hit3 = bgfill_pick(tok, 2, 0x8000, &pid, &x0,&y0,&x1,&y1);
    assert(hit3 == 1 && pid == 5);
    assert(x0==0 && y0==0 && x1==200 && y1==200);

    printf("bgfill_probe_test PASS\n");
    return 0;
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
cc -Wall -Wextra -O2 -I patches/mister/blitter tests/bgfill_probe_test.c -o /tmp/bgfill_probe_test
```
Expected: FAIL to compile — `mister_bgfill_probe.h: No such file or directory`.

- [ ] **Step 3: Write minimal implementation**

Create `patches/mister/blitter/mister_bgfill_probe.h`:
```c
#ifndef MISTER_BGFILL_PROBE_H
#define MISTER_BGFILL_PROBE_H
/* [Phase 0 probe] Pure helper for SOLARUS_BGFILLPROBE. Given a static bucket's
 * entries, pick the pid covering the largest total area and its bounding box, so
 * the renderer can collapse a big single-pattern background fill (ground / parallax
 * sky) into one BLT_OP_FILL for a fabric-time attribution measurement. Area-based
 * (not count-based) so it is robust whether entries are per-8px-cell or coalesced
 * into larger rects. Header-only: no renderer/SDL deps, unit-testable on the host. */
#include <stddef.h>

typedef struct { int dx, dy, w, h; unsigned short pid; } bgfill_ent_t;

static inline int bgfill_pick(const bgfill_ent_t *ents, unsigned long n,
                              unsigned long area_min, unsigned short *out_pid,
                              int *x0, int *y0, int *x1, int *y1) {
    /* Two-pass over pids without a hash map: find the max-total-area pid by scanning.
     * n is small (a few thousand); O(n) per distinct pid is fine for a diagnostic. */
    unsigned long best_area = 0; int have_best = 0; unsigned short best_pid = 0;
    for (unsigned long i = 0; i < n; ++i) {
        unsigned short pid = ents[i].pid;
        if (pid == 0xFFFFu) continue;                 /* tokenless: never a fill */
        /* Only tally a pid the first time we see it (avoid double-counting). */
        int seen = 0;
        for (unsigned long j = 0; j < i; ++j)
            if (ents[j].pid == pid) { seen = 1; break; }
        if (seen) continue;
        unsigned long area = 0;
        for (unsigned long j = i; j < n; ++j)
            if (ents[j].pid == pid)
                area += (unsigned long)ents[j].w * (unsigned long)ents[j].h;
        if (!have_best || area > best_area) { have_best = 1; best_area = area; best_pid = pid; }
    }
    if (!have_best || best_area < area_min) return 0;
    int bx0 = 0, by0 = 0, bx1 = 0, by1 = 0, first = 1;
    for (unsigned long i = 0; i < n; ++i) {
        if (ents[i].pid != best_pid) continue;
        int ex0 = ents[i].dx, ey0 = ents[i].dy;
        int ex1 = ents[i].dx + ents[i].w, ey1 = ents[i].dy + ents[i].h;
        if (first) { bx0=ex0; by0=ey0; bx1=ex1; by1=ey1; first=0; }
        else {
            if (ex0 < bx0) bx0 = ex0;
            if (ey0 < by0) by0 = ey0;
            if (ex1 > bx1) bx1 = ex1;
            if (ey1 > by1) by1 = ey1;
        }
    }
    *out_pid = best_pid; *x0 = bx0; *y0 = by0; *x1 = bx1; *y1 = by1;
    return 1;
}
#endif /* MISTER_BGFILL_PROBE_H */
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
cc -Wall -Wextra -O2 -I patches/mister/blitter tests/bgfill_probe_test.c -o /tmp/bgfill_probe_test && /tmp/bgfill_probe_test
```
Expected: PASS — prints `bbox pid=7 [0,0)-(640,504) OK` then `bgfill_probe_test PASS`.

- [ ] **Step 5: Wire into the suite**

In `tests/run_tests.sh`, after the `wire_pal8` block, add:
```bash
echo "== bgfill_probe (Phase 0 background-fill selection) =="
$CC -Wall -Wextra -O2 -I patches/mister/blitter \
    tests/bgfill_probe_test.c \
    -o /tmp/bgfill_probe_test
/tmp/bgfill_probe_test
```

- [ ] **Step 6: Run the whole suite**

Run: `bash tests/run_tests.sh`
Expected: all existing tests still PASS and the new `bgfill_probe` line prints `bgfill_probe_test PASS`.

- [ ] **Step 7: Commit**

```bash
git add patches/mister/blitter/mister_bgfill_probe.h tests/bgfill_probe_test.c tests/run_tests.sh
git commit -m "test(map119): pure bgfill_pick helper for the Phase-0 fabric-attribution probe"
```

---

### Task 2: Wire the probe into the renderer (flag + record + emit)

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp`

**Interfaces:**
- Consumes: `bgfill_pick` (Task 1); existing `Impl::static_bucket_bias(const StaticBucket&, int16_t&, int16_t&)`; existing `int blt_fill(blt_emitter_t*, int x, int y, int w, int h, uint16_t color)`.
- Produces: env flag `SOLARUS_BGFILLPROBE`; a parallel `std::vector<Impl::BgFillProbe> res_bgfill` sized 1:1 with `res_static_buckets`.

- [ ] **Step 1: Add the include**

Near the other blitter includes at the top of `mister_blitter_renderer.cpp` (with `#include "blitter/blt_emitter.h"` etc.), add:
```cpp
#include "blitter/mister_bgfill_probe.h"   // [Phase 0] SOLARUS_BGFILLPROBE selection helper
```

- [ ] **Step 2: Add the Impl state**

In the `Impl` struct, next to the `bool gridov;` / `bool tilemapch;` flags (around line 784), add:
```cpp
  bool bgfillprobe = false;   // [Phase 0] SOLARUS_BGFILLPROBE: collapse the largest-area
                              // static fill per bucket to one BLT_OP_FILL (fabric-time probe)
```
And next to `std::vector<StaticBucket> res_static_buckets;` (line 715), add the parallel probe vector + POD:
```cpp
  // [Phase 0] Parallel to res_static_buckets (NOT a StaticBucket field -- that aggregate
  // must stay brace-initable). res_bgfill[i] describes the fill collapsed out of bucket i.
  struct BgFillProbe { bool valid; int16_t x0, y0; uint16_t w, h; uint16_t color; };
  std::vector<BgFillProbe> res_bgfill;
```

- [ ] **Step 3: Parse the flag in the ctor**

After the `self->d->gridov = (std::getenv("SOLARUS_GRIDOV") != nullptr);` line (≈2465), add:
```cpp
  self->d->bgfillprobe = (std::getenv("SOLARUS_BGFILLPROBE") != nullptr);
  if (self->d->bgfillprobe)
    std::fprintf(stderr, "[MiSTer blitter] BGFILL PROBE ENABLED (SOLARUS_BGFILLPROBE) -- "
                         "collapses the largest static fill/bucket to a solid fill; "
                         "DIAGNOSTIC, visually wrong on purpose\n");
```

- [ ] **Step 4: Clear the parallel vector where buckets are cleared**

At the scene-reset site that runs `d->res_static_buckets.clear(); d->res_static_ops.clear();` (line 2906), append:
```cpp
  d->res_bgfill.clear();
```

- [ ] **Step 5: Populate the probe at record time + drop the filled entries**

In `resident_record_static`, replace the final tail (from `d->res_static_buckets.push_back(std::move(bk));` through the closing of the function, lines 3090-3094) with:
```cpp
  // [Phase 0] Before the bucket is finalized, optionally carve the largest-area pid out
  // into a solid-fill rect and remove its entries so the fabric never walks those cells.
  Impl::BgFillProbe probe{false, 0, 0, 0, 0, 0};
  if (d->bgfillprobe && !bk.ent.empty()) {
    // Marshal to the pure helper's POD (map-coord dst + size + pid).
    std::vector<bgfill_ent_t> pe; pe.reserve(bk.ent.size());
    for (const auto& e : bk.ent)
      pe.push_back({ (int)e.dx, (int)e.dy, (int)e.w, (int)e.h, e.pid });
    unsigned short fpid = 0; int x0=0, y0=0, x1=0, y1=0;
    // area_min = 0x8000 (32768 px): the ground (322560) and sky (158720) clear it by 5-10x;
    // any decoration pattern's total area stays well under it.
    if (bgfill_pick(pe.data(), pe.size(), 0x8000u, &fpid, &x0, &y0, &x1, &y1)) {
      probe = { true, (int16_t)x0, (int16_t)y0,
                (uint16_t)(x1 - x0), (uint16_t)(y1 - y0),
                (uint16_t)0xF81F /* magenta RGB565: operator-visible */ };
      // Erase every entry of the carved pid; the fill replaces them under the survivors.
      bk.ent.erase(std::remove_if(bk.ent.begin(), bk.ent.end(),
                     [fpid](const Impl::StaticEnt& e){ return e.pid == fpid; }),
                   bk.ent.end());
      if (d->diag)
        std::fprintf(stderr,
          "[blitter bgfillprobe] layer=%d pid=%u fill=[%d,%d %ux%u] survivors=%zu\n",
          layer, fpid, x0, y0, (unsigned)(x1-x0), (unsigned)(y1-y0), bk.ent.size());
    }
  }
  d->res_static_buckets.push_back(std::move(bk));
  d->res_bgfill.push_back(probe);   // 1:1 with res_static_buckets
  d->res_static_ops.push_back({(uint32_t)(d->res_static_buckets.size() - 1), layer});
  d->alias_drawn_this_frame = true;
  if (d->diag) d->g_tile_blits += (long)entries.size();
}
```
Ensure `#include <algorithm>` is present near the top (for `std::remove_if`); add it if the file does not already include it.

- [ ] **Step 6: Emit the fill at emit time**

In `resident_emit_static_layer`, inside the per-op loop, immediately after `Impl::StaticBucket& b = d->res_static_buckets[bi];` (line 3464), add:
```cpp
    // [Phase 0] Paint the carved fill first (under this bucket's survivors) using the
    // bucket's own camera/parallax bias so a parallax fill (sky) scrolls at its ratio.
    if (d->bgfillprobe && bi < d->res_bgfill.size() && d->res_bgfill[bi].valid) {
      const Impl::BgFillProbe& pf = d->res_bgfill[bi];
      int16_t fbx, fby; d->static_bucket_bias(b, fbx, fby);
      blt_fill(&d->em, (int)pf.x0 + fbx, (int)pf.y0 + fby, (int)pf.w, (int)pf.h, pf.color);
    }
```

- [ ] **Step 7: Native type-check**

Run (both `-D` flags mandatory or it checks almost nothing):
```bash
g++ -fsyntax-only -std=c++17 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO \
  -I patches/mister -I patches/mister/blitter -I work/solarus/include \
  -I build/armhf/include -I work/solarus/libraries/win32/mingw32/include \
  $(sdl2-config --cflags) patches/mister/mister_blitter_renderer.cpp
```
Expected: no output (clean). If `blt_fill`/`static_bucket_bias`/`bgfill_ent_t` mismatch, fix the call sites to the signatures in Task 1 / this task's Interfaces.

- [ ] **Step 8: Re-run the host suite (nothing regressed)**

Run: `bash tests/run_tests.sh`
Expected: all PASS (this task adds no host test; it verifies the emitter/model tests still pass with the include in place).

- [ ] **Step 9: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "feat(map119): SOLARUS_BGFILLPROBE -- collapse largest static fill/bucket to BLT_OP_FILL (fabric-time probe)"
```

---

### Task 3: Build, deploy, and capture the A/B on hardware

**Files:**
- Create: `scripts/perf/bgfillprobe_ab.sh`

**Interfaces:**
- Consumes: current ship RBF already on device (`Solarus_20260723.rbf`); the rebuilt engine from this branch; existing `scripts/perf/stage5_device_launch.sh` launch template and its FIFO/log conventions.

- [ ] **Step 1: Build the armhf engine**

Run:
```bash
scripts/build_engine.sh
```
Expected: `build/armhf/solarus-run` and `build/armhf/libsolarus.so.1.6.5` rebuilt without error (armhf Docker; no libGL DT_NEEDED). If the build image is missing, this is an environment issue to surface, not a code fix.

- [ ] **Step 2: Deploy engine only (no RBF change)**

Run:
```bash
./deploy.py --no-rbf --host 192.168.20.81
```
Expected: `solarus-run` + `libs/` refreshed and sha1-verified on device; RBF untouched (Phase 0 reuses the current ship core).

- [ ] **Step 3: Write the A/B capture script**

Create `scripts/perf/bgfillprobe_ab.sh` (adapted from `stage5_ab_cache.sh`; same RBF both legs, the only variable is the `SOLARUS_BGFILLPROBE` env):
```bash
#!/usr/bin/env bash
# Phase 0 attribution A/B: SAME ship RBF, one leg with SOLARUS_BGFILLPROBE off (baseline)
# and one with it on. Teleport to the map-119 parallax spot, settle, sample the standing
# [blitter hwperf] (fabric_hw/comp) + [blitter timing] (fps) + [blitter p0] (BLEND count).
# Diff fabric_hw and non-comp (= fabric_hw - comp) between legs.
#
# Usage: TAG=off              scripts/perf/bgfillprobe_ab.sh
#        TAG=on PROBE=1        scripts/perf/bgfillprobe_ab.sh
set -euo pipefail
HOST="${HOST:-root@192.168.20.81}"
TAG="${TAG:?set TAG=off|on}"; PROBE="${PROBE:-}"
MAP="${MAP:-119}"; DEST="${DEST:-from_dungeon_10}"
LOG=/media/fat/logs/Solarus/bgfillprobe-ab.log
FIFO=/tmp/sol_in
OUTDIR="docs/superpowers/data/stage5"; mkdir -p "$OUTDIR"
OUT="$OUTDIR/ab-bgfill-${TAG}-map${MAP}.txt"

# Launch template with the probe env injected for the ON leg. stage5_device_launch.sh
# already exports SOLARUS_* before exec; add ours next to it.
LAUNCH=/tmp/_bgfill_launch.sh
if [ -n "$PROBE" ]; then
  sed -e 's#^\(\s*\)\(exec .*solarus-run\)#\1export SOLARUS_BGFILLPROBE=1\n\1\2#' \
      -e 's#stage5-boot.log#bgfillprobe-ab.log#g' \
      "$(dirname "$0")/stage5_device_launch.sh" > "$LAUNCH"
else
  sed -e 's#stage5-boot.log#bgfillprobe-ab.log#g' \
      "$(dirname "$0")/stage5_device_launch.sh" > "$LAUNCH"
fi
scp -q "$LAUNCH" "$HOST:/tmp/bgfill_launch.sh"
ssh "$HOST" "kill -9 \$(pidof solarus-run) 2>/dev/null; sh /tmp/bgfill_launch.sh" >/dev/null 2>&1 &
sleep 20

ssh "$HOST" "printf 'sol.main.game = sol.game.load(\"save1.dat\"); sol.menu.stop_all(sol.main); sol.main:start_savegame(sol.main.game)\n' > $FIFO"
sleep 7
ssh "$HOST" "printf 'sol.main.game:get_hero():teleport(\"$MAP\",\"$DEST\")\n' > $FIFO"
sleep 8
CUR=""
for _ in 1 2 3 4 5; do
  ssh "$HOST" "printf 'print(\"CURMAP_NOW=\"..sol.main.game:get_map():get_id())\n' > $FIFO" 2>/dev/null || true
  sleep 2
  CUR=$(ssh "$HOST" "grep -ao 'CURMAP_NOW=[0-9]*' $LOG | tail -1" 2>/dev/null || true)
  [ -n "$CUR" ] && break
done
sleep 12
{
  echo "### bgfill A/B TAG=$TAG PROBE=${PROBE:-0} map=$MAP ($CUR)"
  for b in timing hwperf p0 resident; do
    echo "--- [blitter $b] (last 3) ---"
    ssh "$HOST" "grep -E \"\\[blitter $b\\]\" $LOG | tail -3" 2>/dev/null || true
  done
  echo "--- probe active? ---"
  ssh "$HOST" "grep -c 'BGFILL PROBE ENABLED' $LOG" 2>/dev/null || true
  echo "--- engine alive? ---"
  ssh "$HOST" "pidof solarus-run >/dev/null && echo ALIVE || echo DEAD"
} | tee "$OUT"
echo "captured -> $OUT"
```
Make it executable: `chmod +x scripts/perf/bgfillprobe_ab.sh`.

- [ ] **Step 4: Capture the baseline (probe OFF) leg**

Run:
```bash
TAG=off scripts/perf/bgfillprobe_ab.sh
```
Expected: `docs/superpowers/data/stage5/ab-bgfill-off-map119.txt` written; `hwperf` shows ~`fabric_hw≈30ms comp≈15ms`, `timing` fps≈19-20, `p0` BLEND≈1700, engine `ALIVE`, `probe active?` = `0`. (This reconfirms the current-ship number as this-branch baseline.)

- [ ] **Step 5: Capture the probe ON leg + operator visual gate**

Run:
```bash
TAG=on PROBE=1 scripts/perf/bgfillprobe_ab.sh
```
Expected: `ab-bgfill-on-map119.txt` written; `probe active?` = `1`; engine `ALIVE`.
Then STOP and ask the operator to look at the screen: **magenta must fill exactly the sky + ground, with decorations/sprites/HUD still drawn on top** (confirms the probe carved the right pids and nothing else broke). Do NOT self-declare this. If the magenta covers the wrong region or decorations vanish, the selection/removal is wrong — fix Task 2 before trusting any number.

- [ ] **Step 6: Commit the script + captures**

```bash
git add scripts/perf/bgfillprobe_ab.sh docs/superpowers/data/stage5/ab-bgfill-off-map119.txt docs/superpowers/data/stage5/ab-bgfill-on-map119.txt
git commit -m "perf(map119): bgfillprobe A/B harness + off/on hwperf captures"
```

---

### Task 4: Interpret, decide, and record

**Files:**
- Create: `docs/superpowers/2026-07-22-map119-bgfillprobe-attribution.md`
- Modify: `MEMORY.md` (index) + a new memory file under the memory dir

- [ ] **Step 1: Compute the deltas**

From the two capture files, for the standing window compute, off → on:
- `fabric_hw` delta (ms) and %,
- `comp` delta (ms) — this answers the spec's confounder: **if `comp` barely moves and only non-comp drops, `BLT_OP_FILL` is cheap and NOT counted under comp; if `comp` drops too, fill routes through comp_pipeline.** Record which.
- non-comp (= `fabric_hw − comp`) delta (ms) — the headline number,
- `p0` BLEND count delta,
- fps delta.

- [ ] **Step 2: Apply the decision gate**

Write the decision using the spec's gate:
- **non-comp drops ≥ 3–4 ms (~10%+ fps) → GO:** the per-cell walk of the big fills is the cost; proceed to a Phase-1 spec for the tiled-pattern-fill COPY op.
- **non-comp delta small → NO-GO / pivot:** the walk is not the dominant non-comp cost; do not build the RTL op. Note the actual dominant cost candidates (fill routed through comp? DDR/scanout? SRCFILL still stalling?) as the next investigation.
- Note the **confound**: removing the base fill pid can flip a bucket from replay to grid, so the measured delta is an **upper bound** on the tiled-fill op's isolated payoff. State this explicitly next to the number.

- [ ] **Step 3: Write the results doc**

Create `docs/superpowers/2026-07-22-map119-bgfillprobe-attribution.md` with: the two capture tables, the computed deltas, the comp-confounder finding, the upper-bound caveat, and the GO/NO-GO decision with reasoning. Link the design spec `docs/superpowers/specs/2026-07-22-map119-tiled-fill-design.md`.

- [ ] **Step 4: Update memory**

Create a memory file (e.g. `solarus-map119-bgfill-attribution.md`, type `project`) capturing the measured non-comp delta and the GO/NO-GO, and add a one-line pointer to `MEMORY.md`. Cross-link `[[solarus-stage5-fabric-fetch-bound-source-cache]]` and `[[solarus-parallax-fabric-bound-perf]]`.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/2026-07-22-map119-bgfillprobe-attribution.md MEMORY.md
git commit -m "docs(map119): bgfillprobe attribution results + Phase-1 go/no-go decision"
```

---

## Self-Review

**Spec coverage:**
- Spec "Phase 0 probe (env-gated, existing BLT_OP_FILL, two large fills)" → Tasks 1–2 (selection + emit) and 3 (capture). ✓
- Spec "measure fabric_hw/comp/non-comp/p0 BLEND, HW A/B on current ship" → Task 3. ✓
- Spec "confounder: does BLT_OP_FILL count under comp?" → Task 4 Step 1. ✓
- Spec "decision gate ≥3–4 ms" → Task 4 Step 2. ✓
- Spec "operator-confirmed visual, never self-declared" → Task 3 Step 5. ✓
- Spec Phase 1 (RTL op) → intentionally OUT of this plan: contingent on the gate, and its design (opcode, byte layout, ground-vs-sky scope, expected ceiling) depends on this plan's measurements. It gets its own spec→plan cycle if the gate says GO.

**Placeholder scan:** No TBD/TODO; every code step shows complete code; the results-doc content (Task 4) is enumerated field-by-field, not "write it up." ✓

**Type consistency:** `bgfill_ent_t { int dx,dy,w,h; unsigned short pid; }` and `bgfill_pick(...)` identical in Task 1 header, Task 1 test, and Task 2 marshaling. `BgFillProbe { bool valid; int16_t x0,y0; uint16_t w,h; uint16_t color; }` defined once (Task 2 Step 2), constructed with matching field order in Task 2 Step 5, read with matching names in Task 2 Step 6. `blt_fill(&d->em, x, y, w, h, color)` matches the emitter signature confirmed in `blt_emitter.h`. ✓
