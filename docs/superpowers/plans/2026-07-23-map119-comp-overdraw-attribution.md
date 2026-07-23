# Map 119 `comp` Overdraw Attribution — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Attribute map 119's 14.89 ms `comp` (compositor) time by draw category and screen region — engine-only, no RBF — so the 60 fps overdraw fix targets the real waste.

**Architecture:** An env-gated engine trace (`SOLARUS_COMPTRACE=1`) dumps every emitted dst rectangle for one settled build frame as `COMP <cat> …` lines; a pure-Python offline analyzer (`scripts/perf/comp_overdraw.py`) clips each rect to the 320×240 screen, sums composited pixels per category, builds an overdraw heatmap, and cross-checks the traced pixel total against the HW `comp` cycle count. The plan also produces the operator runbook for the capture and the additive combination A/B (overdraw-fix + PR 140 bgfill).

**Tech Stack:** C++17 (`patches/mister/mister_blitter_renderer.cpp`, a whole-file copy — edit directly), Python 3 stdlib only (offline analyzer + its test).

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-07-23-map119-comp-overdraw-attribution-design.md`. Every task serves it.
- **No RTL / RBF change.** Ships on current `Solarus_20260723.rbf`. Attribution only.
- **Engine trace is a true no-op unless armed:** gated on the cached env flag AND a one-frame latch; the shippable path (flag unset) must be byte-unchanged in behavior. Matches the `SOLARUS_FETCHTRACE` / `SOLARUS_BGFILLPROBE` conventions already in this file.
- **`mister_blitter_renderer.cpp` is a whole-file copy under `patches/mister/`** — NOT in the git-am series. Edit it directly; nothing to regenerate.
- **Native type-check command (mandatory `-D` flags):**
  ```
  g++ -fsyntax-only -std=c++17 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO \
    -I patches/mister -I patches/mister/blitter -I work/solarus/include \
    -I build/armhf/include -I work/solarus/libraries/win32/mingw32/include \
    $(sdl2-config --cflags) patches/mister/mister_blitter_renderer.cpp
  ```
  Omitting the two `-D` flags type-checks almost nothing (the renderer lives inside `#ifdef MISTER_NATIVE_VIDEO`).
- **Python analyzer: stdlib only** (no numpy/PIL); optional PNG via a hand-written PPM/P6 writer.
- **Line format (frozen — engine writer and Python reader must agree):**
  - Marker: `COMP_FRAME map=<m> camx=<cx> camy=<cy> fbw=<W> fbh=<H>` (all single-token key=vals)
  - Record: `COMP <cat> <dx> <dy> <w> <h> <blend> <op> <ratio>`
    - `cat` ∈ {`fill`,`blit`,`sprite`,`tilemap`,`overlay`}
    - `dx dy w h`: for all cats EXCEPT `tilemap`, already FB-space. For `tilemap`, MAP-coords (offline transform via `cam` + `ratio`).
    - `blend`: numeric `BLT_BLEND_*`; `op`: 0–255 opacity; `ratio`: bucket `scroll_ratio` (1 for non-tilemap).
  - Terminator: `COMP_END`

---

## Task 1: Offline analyzer `comp_overdraw.py` + unit test (TDD, no device)

**Files:**
- Create: `scripts/perf/comp_overdraw.py`
- Test: `scripts/perf/test_comp_overdraw.py`

**Interfaces:**
- Produces (imported by the test):
  - `parse_frame(lines: Iterable[str]) -> Frame` where `Frame` has `.map:int`, `.cam:tuple[int,int]`, `.fb:tuple[int,int]`, `.records:list[Rec]`.
  - `Rec` = namedtuple `('cat dx dy w h blend op ratio')` (all ints, `cat` str).
  - `screen_rect(rec: Rec, cam: tuple[int,int]) -> tuple[int,int,int,int]` — returns `(sx, sy, w, h)`; applies the tilemap map→screen bias.
  - `clip(rect, W, H) -> tuple[int,int,int,int] | None` — intersect with `[0,W)×[0,H)`; `None` if empty.
  - `attribute(frame: Frame) -> Report` where `Report` has `.per_cat:dict[str,int]` (clipped composited px), `.total:int`, `.grid:list[list[int]]` (H×W overdraw counts), `.mean_overdraw:float`, `.max_overdraw:int`.

- [ ] **Step 1: Write the failing test**

```python
# scripts/perf/test_comp_overdraw.py
import comp_overdraw as co

FRAME = [
    "COMP_FRAME map=119 camx=100 camy=200 fbw=320 fbh=240",
    # fill: FB-space, exactly the screen -> 320*240 px, overdraw 1 everywhere
    "COMP fill 0 0 320 240 0 255 1",
    # blit: FB-space 100x100 at (0,0) -> stacks on the fill (overdraw 2 there)
    "COMP blit 0 0 100 100 4 255 1",
    # sprite: partly off-screen left -> clips to (0,0,10,10)
    "COMP sprite -20 0 30 10 4 255 1",
    # tilemap normal (ratio=1): map (100,200) - cam (100,200) = screen (0,0), 8x8
    "COMP tilemap 100 200 8 8 0 255 1",
    # tilemap parallax (ratio=2): screen x = 240 + (100//2 - 100) = 240-50 = 190
    "COMP tilemap 240 200 8 8 0 255 2",
    # overlay: full-screen PALPHA
    "COMP overlay 0 0 320 240 2 255 1",
    "COMP_END",
]

def test_parse_frame_header():
    f = co.parse_frame(FRAME)
    assert f.map == 119
    assert f.cam == (100, 200)
    assert f.fb == (320, 240)
    assert len(f.records) == 6

def test_screen_rect_tilemap_normal():
    f = co.parse_frame(FRAME)
    r = [x for x in f.records if x.cat == "tilemap" and x.ratio == 1][0]
    assert co.screen_rect(r, f.cam) == (0, 0, 8, 8)

def test_screen_rect_tilemap_parallax():
    f = co.parse_frame(FRAME)
    r = [x for x in f.records if x.cat == "tilemap" and x.ratio == 2][0]
    # sx = 240 + (100//2 - 100) = 190 ; sy = 200 + (200//2 - 200) = 100
    assert co.screen_rect(r, f.cam) == (190, 100, 8, 8)

def test_clip_partial_and_offscreen():
    assert co.clip((-20, 0, 30, 10), 320, 240) == (0, 0, 10, 10)
    assert co.clip((400, 0, 10, 10), 320, 240) is None

def test_attribute_totals_and_overdraw():
    f = co.parse_frame(FRAME)
    rep = co.attribute(f)
    # fill 320*240 = 76800 ; overlay 76800 ; blit 100*100 = 10000 ;
    # sprite clipped 10*10 = 100 ; two 8x8 tiles = 128
    assert rep.per_cat["fill"] == 76800
    assert rep.per_cat["overlay"] == 76800
    assert rep.per_cat["blit"] == 10000
    assert rep.per_cat["sprite"] == 100
    assert rep.per_cat["tilemap"] == 128
    assert rep.total == 76800 + 76800 + 10000 + 100 + 128
    # hottest pixel (0,0): fill + blit + sprite(clipped to 0,0,10,10) +
    # tilemap-normal(screen 0,0) + overlay all overlap = 5
    assert rep.max_overdraw == 5
    assert abs(rep.mean_overdraw - rep.total / (320 * 240)) < 1e-9
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd scripts/perf && python3 -m pytest test_comp_overdraw.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'comp_overdraw'` (or collection error).

- [ ] **Step 3: Write the analyzer**

```python
# scripts/perf/comp_overdraw.py
"""Offline overdraw attribution for SOLARUS_COMPTRACE dumps.

Reads one COMP_FRAME..COMP_END block, clips every emitted dst rect to the
320x240 screen, sums composited pixels per category, and reports the overdraw
map. tilemap rects are stored in MAP coords and transformed to screen via the
per-bucket camera bias (normal: -cam ; parallax: cam//ratio - cam), matching
mister_blitter_renderer.cpp's static_bucket_bias / res_emit_bucket_.
"""
import argparse
import sys
from collections import namedtuple

Rec = namedtuple("Rec", "cat dx dy w h blend op ratio")


class Frame:
    def __init__(self, map_, cam, fb, records):
        self.map = map_
        self.cam = cam
        self.fb = fb
        self.records = records


class Report:
    def __init__(self, per_cat, total, grid, mean_overdraw, max_overdraw):
        self.per_cat = per_cat
        self.total = total
        self.grid = grid
        self.mean_overdraw = mean_overdraw
        self.max_overdraw = max_overdraw


def parse_frame(lines):
    map_ = 0
    cam = (0, 0)
    fb = (320, 240)
    records = []
    started = False
    for raw in lines:
        t = raw.strip().split()
        if not t:
            continue
        if t[0] == "COMP_FRAME":
            kv = dict(tok.split("=", 1) for tok in t[1:] if "=" in tok)
            map_ = int(kv.get("map", "0"))
            cam = (int(kv.get("camx", "0")), int(kv.get("camy", "0")))
            fb = (int(kv.get("fbw", "320")), int(kv.get("fbh", "240")))
            started = True
            continue
        if t[0] == "COMP_END":
            break
        if t[0] == "COMP" and started:
            _, cat, dx, dy, w, h, blend, op, ratio = t[:9]
            records.append(Rec(cat, int(dx), int(dy), int(w), int(h),
                               int(blend), int(op), int(ratio)))
    return Frame(map_, cam, fb, records)


def screen_rect(rec, cam):
    if rec.cat == "tilemap":
        cx, cy = cam
        if rec.ratio <= 1:
            bx, by = -cx, -cy
        else:
            bx, by = cx // rec.ratio - cx, cy // rec.ratio - cy
        return (rec.dx + bx, rec.dy + by, rec.w, rec.h)
    return (rec.dx, rec.dy, rec.w, rec.h)


def clip(rect, W, H):
    x, y, w, h = rect
    x0, y0 = max(0, x), max(0, y)
    x1, y1 = min(W, x + w), min(H, y + h)
    if x1 <= x0 or y1 <= y0:
        return None
    return (x0, y0, x1 - x0, y1 - y0)


def attribute(frame):
    W, H = frame.fb
    grid = [[0] * W for _ in range(H)]
    per_cat = {}
    for rec in frame.records:
        c = clip(screen_rect(rec, frame.cam), W, H)
        if c is None:
            continue
        x, y, w, h = c
        per_cat[rec.cat] = per_cat.get(rec.cat, 0) + w * h
        for yy in range(y, y + h):
            row = grid[yy]
            for xx in range(x, x + w):
                row[xx] += 1
    total = sum(per_cat.values())
    mx = max((max(r) for r in grid), default=0)
    mean = total / (W * H) if W and H else 0.0
    return Report(per_cat, total, grid, mean, mx)


def _ascii_heatmap(grid, cols=80, rows=48):
    H = len(grid)
    W = len(grid[0]) if H else 0
    shades = " .:-=+*#%@"
    mx = max((max(r) for r in grid), default=0) or 1
    out = []
    for ry in range(rows):
        line = []
        for rx in range(cols):
            x = rx * W // cols
            y = ry * H // rows
            v = grid[y][x]
            line.append(shades[min(len(shades) - 1, v * (len(shades) - 1) // mx)])
        out.append("".join(line))
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description="COMPTRACE overdraw attribution")
    ap.add_argument("log", help="captured stderr log containing a COMP_FRAME block")
    ap.add_argument("--comp-cyc", type=float, default=None,
                    help="comp cyc/frame from [blitter hwperf] for cross-check")
    ap.add_argument("--cyc-per-px", type=float, default=2.38,
                    help="modeled fabric cycles per composited px (cache-knee.md)")
    ap.add_argument("--heatmap", action="store_true", help="print ASCII overdraw heatmap")
    a = ap.parse_args(argv)
    with open(a.log) as fh:
        frame = parse_frame(fh)
    rep = attribute(frame)
    print("map=%d cam=%s fb=%s records=%d"
          % (frame.map, frame.cam, frame.fb, len(frame.records)))
    print("composited px total = %d  (mean overdraw %.2fx, max %d)"
          % (rep.total, rep.mean_overdraw, rep.max_overdraw))
    for cat in sorted(rep.per_cat, key=lambda k: -rep.per_cat[k]):
        px = rep.per_cat[cat]
        print("  %-8s %9d px  %5.1f%%" % (cat, px, 100.0 * px / rep.total))
    if a.comp_cyc:
        modeled = a.comp_cyc / a.cyc_per_px
        print("cross-check: hwperf comp=%.0f cyc / %.2f cyc-per-px = %.0f modeled px"
              % (a.comp_cyc, a.cyc_per_px, modeled))
        print("             traced/modeled = %.2f  (1.0 = trustworthy; <1 = fabric"
              " does more per px than dst-area, e.g. blend RMW)" % (rep.total / modeled))
    if a.heatmap:
        print(_ascii_heatmap(rep.grid))
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd scripts/perf && python3 -m pytest test_comp_overdraw.py -v`
Expected: PASS (5 tests). If `pytest` is unavailable, `python3 -c "import test_comp_overdraw as t,inspect; [f() for n,f in inspect.getmembers(t,inspect.isfunction) if n.startswith('test_')]; print('ok')"`.

- [ ] **Step 5: Commit**

```bash
git add scripts/perf/comp_overdraw.py scripts/perf/test_comp_overdraw.py
git commit -m "perf(map119): offline COMPTRACE overdraw analyzer + tests"
```

---

## Task 2: Engine `comptrace` helper, env parse, one-frame latch, markers

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` — add the static helper + globals near the `fetchtrace_log` block (~112–135); add env parse in the ctor (~2404); arm + `COMP_FRAME`/camera line at the resident-build marker (~2912, beside the `FETCH_SCENE` print).

**Interfaces:**
- Produces (used by Task 3):
  - `static bool g_comptrace_on;` and `static int g_comptrace_arm;` (0 idle, 1 capturing).
  - `static inline void comptrace_rec(const char* cat, int dx, int dy, int w, int h, int blend, int op, int ratio);` — writes one `COMP …` line when `g_comptrace_on && g_comptrace_arm`.
  - The arm site prints `COMP_FRAME map=… cam=… fb=…` and sets `g_comptrace_arm = 1`.

- [ ] **Step 1: Add the helper + globals (beside `fetchtrace_log`, after line ~135)**

```cpp
// [map119 overdraw] Comp-trace diag (SOLARUS_COMPTRACE=1). Emits one
//   COMP <cat> <dx> <dy> <w> <h> <blend> <op> <ratio>
// line per emitted dst rectangle for ONE settled build frame (armed at the
// resident-build marker, disarmed after the overlay composite), so the offline
// analyzer (scripts/perf/comp_overdraw.py) can attribute the fabric compositor's
// per-frame pixel work (overdraw) by draw category and screen region WITHOUT any
// RTL change. tilemap rects are MAP-coords (offline applies the camera bias);
// all other cats are FB-space. Gated + latched so it is a true no-op unset.
static bool g_comptrace_on  = false;   // cached getenv presence (set in ctor)
static int  g_comptrace_arm = 0;       // 0 = idle, 1 = capturing this frame
static inline void comptrace_rec(const char* cat, int dx, int dy, int w, int h,
                                 int blend, int op, int ratio) {
  if (!g_comptrace_on || !g_comptrace_arm) return;
  std::fprintf(stderr, "COMP %s %d %d %d %d %d %d %d\n",
               cat, dx, dy, w, h, blend, op, ratio);
}
```

- [ ] **Step 2: Parse the env flag in the ctor (beside the `SOLARUS_FETCHTRACE` parse, ~2404)**

Find:
```cpp
  g_fetchtrace_on = mister_flag_default_off("SOLARUS_FETCHTRACE");  // [Stage 5 Task A] atlas fetch trace
```
Add immediately after:
```cpp
  g_comptrace_on  = mister_flag_default_off("SOLARUS_COMPTRACE");   // [map119] overdraw attribution
```

- [ ] **Step 3: Arm + emit the frame marker at the resident-build marker (~2912, in the `if (g_fetchtrace_on)` neighborhood inside `resident_begin_frame`)**

Find the existing fetch-scene marker block:
```cpp
  if (g_fetchtrace_on) {
    g_fetchtrace_n = 0;
    std::fprintf(stderr, "FETCH_SCENE map=%lu tileset=%lu\n",
```
Immediately AFTER that `if (g_fetchtrace_on) { … }` block closes, add:
```cpp
  // [map119 overdraw] Arm the comp-trace for exactly this build frame. Emit the
  // frame marker with the LIVE camera (offline tilemap map->screen transform) and
  // FB size; disarm fires after the overlay composite (emit_overlay_composite).
  if (g_comptrace_on) {
    g_comptrace_arm = 1;
    std::fprintf(stderr, "COMP_FRAME map=%lu camx=%d camy=%d fbw=%d fbh=%d\n",
                 (unsigned long)mister_current_map_id(),
                 mister_camera_x(), mister_camera_y(), FB_W, FB_H);
  }
```
NOTE: if `mister_current_map_id()` is not the exact accessor in this file, use the same map id source the `FETCH_SCENE` line uses (copy its first `%lu` argument expression verbatim). Verify by reading the `FETCH_SCENE` fprintf args at ~2914.

- [ ] **Step 4: Native type-check**

Run the Global-Constraints type-check command.
Expected: no errors (helper compiles; `g_comptrace_*` referenced only where defined so far). A clean exit with no diagnostics.

- [ ] **Step 5: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "perf(map119): SOLARUS_COMPTRACE helper + one-frame arm/marker (no sites yet)"
```

---

## Task 3: Wire the five trace call sites

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` at the five emit sites.

**Interfaces:**
- Consumes: `comptrace_rec(...)`, `g_comptrace_on`, `g_comptrace_arm` from Task 2.
- Produces: a complete one-frame `COMP_FRAME … COMP_END` dump when `SOLARUS_COMPTRACE=1` and a resident build runs (scene entry / teleport).

- [ ] **Step 1: `fill()` — category `fill` (after `blt_fill(...)`, ~2642–2644)**

In `MisterBlitterRenderer::fill`, the opaque path emits `blt_fill(&d->em, where.get_x()+ox, where.get_y()+oy, where.get_width(), where.get_height(), fill_rgb565);`. Immediately after that call (and before its `return`), add:
```cpp
    comptrace_rec("fill", where.get_x() + ox, where.get_y() + oy,
                  where.get_width(), where.get_height(), (int)mode, 255, 1);
```
Also add the same call after the two early-return fill variants in this function (the `BlendMode::ADD/MULTIPLY` `blt_fill_blend` path ~2614 and the `a < 255` `blt_fill_alpha` path ~2633), using the same `where.get_x()+ox` args and `(int)mode`, `op = (a<255? a : 255)`. This captures every fill that reaches the fabric.

- [ ] **Step 2: `emit_draw()` — category `blit` (post-clip, beside the fetch-trace at ~2181)**

Find:
```cpp
    if (g_fetchtrace_on && res_building)
      fetchtrace_log(eff_src_off(h), sx, sy, bw, bh, h.stride);
```
Add immediately after:
```cpp
    // [map119 overdraw] post-clip dst rect (bdx,bdy,bw,bh) is the fabric composite
    // footprint; blend/opacity as emitted. FB-space (ratio=1).
    comptrace_rec("blit", bdx, bdy, bw, bh, (int)blend, (int)infos.opacity, 1);
```

- [ ] **Step 3: sprite push — category `sprite` (beside the fetch-trace at ~2295)**

Find:
```cpp
    if (g_fetchtrace_on && res_building)
      fetchtrace_log(src_off, sx, sy, bw, bh, h.stride);
```
Add immediately after:
```cpp
    comptrace_rec("sprite", bdx, bdy, bw, bh, (int)blend, (int)infos.opacity, 1);
```

- [ ] **Step 4: animated tiles — category `tilemap` (build loop, beside the fetch-trace at ~3028)**

In `resident_record_batch` (signature `resident_record_batch(int layer, int scroll_ratio, …)`), find:
```cpp
    if (g_fetchtrace_on)
      fetchtrace_log(d->eff_src_off(tex), e.src.get_x(), e.src.get_y(),
                     e.src.get_width(), e.src.get_height(), tex.stride);
```
Add immediately after:
```cpp
    // [map119 overdraw] MAP-coord dst + tile size + scroll_ratio; offline applies
    // the per-bucket camera bias. blend from the bucket's resolved mode.
    comptrace_rec("tilemap", e.dst.x, e.dst.y,
                  e.src.get_width(), e.src.get_height(), (int)blend, 255, scroll_ratio);
```
(`blend` here is the `resident_record_batch` argument; `scroll_ratio` is the arg.)

- [ ] **Step 5: static tiles — category `tilemap` (build loop, beside the fetch-trace at ~3097)**

In the static record function, find:
```cpp
    if (g_fetchtrace_on)
      fetchtrace_log(d->eff_src_off(tex), e.src.get_x(), e.src.get_y(),
                     e.src.get_width(), e.src.get_height(), tex.stride);
```
Add immediately after:
```cpp
    comptrace_rec("tilemap", e.dst.x, e.dst.y,
                  e.src.get_width(), e.src.get_height(), (int)blend, 255, scroll_ratio);
```
Confirm this function's parameters expose `blend` and `scroll_ratio` (same shape as `resident_record_batch`); if the static recorder names the ratio differently, use its actual parameter name. Read the function signature (~3070) before editing.
NOTE (documented behavior): when `SOLARUS_BGFILLPROBE=1`, entries are carved out below this loop (~3107), so a combined COMPTRACE+BGFILLPROBE run correctly shows the carved cells GONE from `tilemap` — that is the intended interaction for the combination A/B, not a bug.

- [ ] **Step 6: overlay — category `overlay` + disarm + `COMP_END` (after `blt_blit(... PALPHA ...)`, ~1502)**

In `emit_overlay_composite`, find:
```cpp
    blt_blit(&em, ref, 0, 0, FB_W, FB_H, 0, 0, BLT_BLEND_PALPHA, 0, 255, 0);
    if (diag) g_overlay_blits++;
```
Add immediately after those two lines (still inside the function):
```cpp
    // [map119 overdraw] the full-screen per-pixel-alpha overlay, composited LAST.
    // This is the last emit of the frame -> record it, then disarm and close the
    // one-frame block so the dump is exactly one frame.
    comptrace_rec("overlay", 0, 0, FB_W, FB_H, (int)BLT_BLEND_PALPHA, 255, 1);
    if (g_comptrace_on && g_comptrace_arm) {
      g_comptrace_arm = 0;
      std::fprintf(stderr, "COMP_END\n");
    }
```
EDGE CASE: if `emit_overlay_composite` early-returns (no overlay this frame: `!overlay_touched`, root size guard, or upload failure) while armed, the block would never close. Guard against a dangling arm by also disarming at frame teardown: in the same function, at the top after `if (!overlay_touched) return;` is NOT reachable when armed on a normal map frame (the overlay is default-ON and touched every frame), so no extra code is required for the map119 capture. Document this assumption in the runbook (Task 4) rather than adding teardown plumbing.

- [ ] **Step 7: Native type-check**

Run the Global-Constraints type-check command.
Expected: no errors.

- [ ] **Step 8: Host test suite (guard against accidental behavior change)**

Run: `bash tests/run_tests.sh`
Expected: all host tests pass (the trace is gated OFF by default, so modeled engine logic is unchanged).

- [ ] **Step 9: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "perf(map119): wire COMPTRACE at fill/blit/sprite/tilemap/overlay emit sites"
```

---

## Task 4: Operator runbook — capture + combination A/B

**Files:**
- Create: `docs/superpowers/plans/2026-07-23-map119-comptrace-runbook.md`

**Interfaces:**
- Consumes: the `SOLARUS_COMPTRACE=1` engine build (Tasks 2–3), `comp_overdraw.py` (Task 1), the existing `SOLARUS_BGFILLPROBE` (PR 140), and `scripts/perf/bgfillprobe_ab.sh`.
- Produces: a step-by-step the operator runs on 192.168.20.81; outputs `report.txt` + heatmap and the combination A/B table.

- [ ] **Step 1: Write the runbook**

Contents (fill each section with the exact commands):

1. **Build (engine-only, no RBF), avoiding the flaky in-docker `git am`:**
   ```
   scripts/apply_patch_series.sh
   SOLARUS_SKIP_APPLY=1 scripts/docker_run.sh scripts/build_engine.sh
   strings build/armhf/libsolarus.so.1.6.5 | grep -c COMP_FRAME   # expect >=1
   ls -l build/armhf/libsolarus.so.1.6.5                          # confirm fresh mtime
   ```
   Then refresh `deploy/` from `build/armhf` and `./deploy.py --no-rbf`.

2. **Capture the attribution frame (map 119 standing):** launch detached with
   `SOLARUS_COMPTRACE=1` + the normal diag env, teleport to `from_dungeon_10`,
   confirm `CURMAP=119`, tee stderr to `/media/fat/logs/comptrace-map119.log`.
   Also grab a steady-state `[blitter hwperf]` line for the cross-check
   (`comp=…ms … (<cyc>/frame)`). Use the detached launch recipe
   (`setsid sh solarus_run.sh >log 2>&1 </dev/null &`, log to `/media/fat/logs`)
   so it survives ssh disconnect.

3. **Analyze offline:**
   ```
   python3 scripts/perf/comp_overdraw.py comptrace-map119.log \
     --comp-cyc <cyc/frame from hwperf> --heatmap > report.txt
   ```
   Read: per-category %, mean/max overdraw, cross-check ratio (≈1.0 = the dst-area
   model captures comp; <1 = fabric spends more per px than dst-area → blend RMW is
   a separate lever).

4. **Combination A/B (the additive-lever test, once an overdraw fix exists):** four
   legs on map 119 standing, each reading `[blitter hwperf]` fabric_hw + `[blitter
   timing]` fps — reuse `scripts/perf/bgfillprobe_ab.sh` as the harness template:
   | leg | env | expect |
   |---|---|---|
   | baseline | (none) | fabric 20.63 ms, 29.5 fps |
   | overdraw-fix | `<fix flag>=1` | Δcomp |
   | bgfill | `SOLARUS_BGFILLPROBE=1` | ~16.83 ms (re-confirm PR 140) |
   | **both** | `<fix flag>=1 SOLARUS_BGFILLPROBE=1` | **fabric_hw < 16.7 ms AND fps→60?** |
   Success = the pair crosses 16.7 ms and fps jumps (not more `sleep`). If so,
   productionize BOTH (correct bgfill + the overdraw cull) together.

5. **Caveat:** one build frame ≈ steady state; sprites animate slightly. If the
   `sprite` share looks material, re-capture across a few frames (re-teleport
   re-arms) and average. `overlay` is default-ON and touched every frame, so the
   one-frame block always closes on a normal map frame.

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/plans/2026-07-23-map119-comptrace-runbook.md
git commit -m "docs(map119): COMPTRACE capture + combination A/B runbook"
```

---

## Self-Review

**Spec coverage:**
- Component 1 (engine trace, 5 sites, one-frame latch, markers) → Tasks 2–3. ✓
- Component 2 (offline analyzer: clip, per-cat area, overdraw grid, ASCII heatmap, cross-check) → Task 1. ✓
- Capture recipe → Task 4 §1–3. ✓
- Combination step (PR 140 additive, four legs, 16.7 ms threshold) → Task 4 §4. ✓
- Decision gate (attribution outputs, not a fix) → produced by Task 1 report + Task 4 §3; no fix task, by design. ✓
- Risks/caveats (one-frame steady-state, transparent early-out via cross-check ratio, tilemap on-screen clip) → Task 1 `clip`/`screen_rect`, Task 4 §5, cross-check line. ✓

**Placeholder scan:** No TBD/TODO. `<fix flag>` in Task 4 §4 is intentionally symbolic — no overdraw fix exists yet (out of scope; this plan produces the attribution that designs it). Every code step shows complete code.

**Type consistency:** `comptrace_rec(cat,dx,dy,w,h,blend,op,ratio)` — same 8-arg signature at all five sites and in the Python `Rec`. `g_comptrace_on`/`g_comptrace_arm` defined in Task 2, referenced in Task 3. Line format `COMP <cat> <dx> <dy> <w> <h> <blend> <op> <ratio>` matches the Python `parse_frame` split (9 tokens) and the test fixture. `screen_rect` tilemap bias (`cx//ratio - cx`) matches the engine's `cx / b.scroll_ratio - cx` (integer division; C++ truncates toward zero, Python `//` floors — camera coords are ≥0 in these captures so they agree; noted for negative-camera maps, not map119).
