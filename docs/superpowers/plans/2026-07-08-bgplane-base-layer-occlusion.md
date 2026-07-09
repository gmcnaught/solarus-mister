# BGPLANE Base-Layer-Only Bake (Bug #1 Fix) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the SOLARUS_BGPLANE cross-layer occlusion bug (hero/entities always paint in front of every static tile, even ones on a higher layer meant to hide them, e.g. tree canopy / doorframes) by restricting the flattened background-plane bake to exactly one layer — the map's base layer (`map.get_min_layer()`) — and letting every other layer keep using the pre-existing, already-correct per-bucket tile-list replay.

**Architecture:** `map.get_min_layer()` is threaded explicitly from `Entities::draw()` into `Renderer::resident_begin_frame()` (a new parameter) and latched as `Impl::bg_base_layer` on each resident rebuild. `res_arm_()`, `bake_background_plane_step()`, `resident_emit_static_layer()`, and the new `resident_static_before_animated(int layer)` all gate on `layer == bg_base_layer` instead of treating every layer identically. A new pure, host-testable helper (`compute_bgplane_bounds`) replaces the inline bounding-box computation in `res_arm_()`, dropping the current mixing-in of every layer's statics plus animated-bucket extents.

**Tech Stack:** C++17 (Solarus engine, patched via `patches/series/*.patch` + `git am`), plain C-style host-testable helpers under `patches/mister/blitter/`, MiSTer armhf cross-build via Docker (`solarus-armhf-build:bullseye`), HW validation over SSH to the MiSTer device.

## Global Constraints

- Every upstream-file change (`work/solarus/include/solarus/graphics/Renderer.h`, `work/solarus/src/entities/Entities.cpp`) must be made inside the `work/solarus` git tree (a disposable, patch-authoring clone rebuilt from `patches/series/*.patch` via `bash scripts/apply_patch_series.sh`), committed there, then re-exported with `bash scripts/export_patches.sh`. Never hand-edit `patches/series/*.patch` files directly.
- Whole-file MiSTer additions (`patches/mister/mister_blitter_renderer.h`, `patches/mister/mister_blitter_renderer.cpp`, and any new file under `patches/mister/blitter/`) are edited directly at their canonical path under `patches/mister/` — they are copied verbatim into `work/solarus` by `scripts/apply_mister_files.sh` (part of `apply_patch_series.sh`), not tracked as git-series patches.
- After every patch-series change, re-run `bash scripts/apply_patch_series.sh` from the repo root and confirm `VERIFY PASS` (the ast-grep gate) before moving on.
- Run `bash tests/run_tests.sh` after every host-testable change; it must print `All host tests passed.` with zero regressions before proceeding to the next task.
- No git commits until the user explicitly asks for one, per this project's standing convention — commit steps in this plan assume that request has already been made (it has, for this feature: "write the plan, and if needed use teammates to implement the plan" following the approved design). If executing this plan in a future session where that request wasn't made, skip the commit steps and ask first.
- The armhf cross-build must run inside the Docker container, not on the host directly: `docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_engine.sh`. Running `scripts/build_engine.sh` directly on the host will fail (`arm-linux-gnueabihf-gcc` not in PATH). If `build/armhf/` has a stale `CMakeCache.txt` from a different invocation context, `rm -rf build/armhf` before rebuilding.

---

### Task 1: Pure `compute_bgplane_bounds` helper + host test

**Files:**
- Create: `patches/mister/blitter/bgplane_bounds.h`
- Create: `tests/bgplane_bounds_test.cpp`
- Modify: `tests/run_tests.sh` (register the new test, mirroring the existing `bgplane_geom` entry)

**Interfaces:**
- Produces: `bgplane_tile_extent_t { int layer; int dx, dy, w, h; }`, `bgplane_bounds_t { int any; int mw, mh; int min_x, min_y; }`, and `static inline bgplane_bounds_t compute_bgplane_bounds(const bgplane_tile_extent_t* extents, int count, int base_layer)` — a free function with no dependency on `MisterBlitterRenderer` or DDR/hardware state, consumed by Task 3.

- [ ] **Step 1: Write the failing test**

Create `tests/bgplane_bounds_test.cpp`:

```cpp
/* Host unit test for compute_bgplane_bounds (bug #1 fix: bgplane restricted
 * to the map's base layer). Pure C++, runs natively (no device). Build+run:
 * c++ -std=c++17 -Wall -Wextra -O2 -I patches/mister/blitter \
 *     tests/bgplane_bounds_test.cpp -o /tmp/bgplane_bounds_test && /tmp/bgplane_bounds_test
 */
#include "bgplane_bounds.h"
#include <cassert>
#include <cstdio>

int main() {
  // Two layers of static content: layer 0 (the base layer) spans a small
  // area; layer 1 (e.g. tree canopy) spans a different, larger area. Only
  // layer 0's extents should contribute to the bounds. All layer-0
  // coordinates here are non-negative, so the origin-clamp rule ("origin is
  // never pulled positive, only shifted to cover negatives") clamps min_x/
  // min_y to 0 independently -- mw/mh are therefore the raw max ex/ey, NOT
  // reduced by the (would-be-positive) min values.
  {
    bgplane_tile_extent_t extents[] = {
      { 0, 10, 20, 16, 16 },   // layer 0: [10,26) x [20,36)
      { 0, 40, 5,  16, 16 },   // layer 0: [40,56) x [5,21)
      { 1, 0,  0,  200, 200 }, // layer 1 (canopy): much bigger, must be ignored
    };
    bgplane_bounds_t b = compute_bgplane_bounds(extents, 3, /*base_layer=*/0);
    assert(b.any == 1);
    assert(b.min_x == 0 && b.min_y == 0);   // raw min (10, 5) both positive -> clamped to 0
    assert(b.mw == 56 && b.mh == 36);       // max ex=56, max ey=36; unreduced since origin is 0
  }

  // Negative coordinates on the base layer are compensated (origin shifts
  // to cover them), matching the single-plane implementation this replaces.
  {
    bgplane_tile_extent_t extents[] = {
      { -1, -8, -24, 16, 16 },  // base layer is -1 here
      { -1, 100, 100, 16, 16 },
      { 0, 0, 0, 999, 999 },    // different layer, must be ignored
    };
    bgplane_bounds_t b = compute_bgplane_bounds(extents, 3, /*base_layer=*/-1);
    assert(b.any == 1);
    assert(b.min_x == -8 && b.min_y == -24);
    assert(b.mw == (100 + 16) - (-8));
    assert(b.mh == (100 + 16) - (-24));
  }

  // Base layer has zero matching extents: `any` stays false, and mw/mh/
  // min_x/min_y stay at their zero defaults -- callers must check `any`
  // before allocating a plane (a map where the base layer has no static
  // content should not bake anything, not bake a degenerate 0x0 plane).
  {
    bgplane_tile_extent_t extents[] = {
      { 1, 0, 0, 16, 16 },
      { 2, 5, 5, 16, 16 },
    };
    bgplane_bounds_t b = compute_bgplane_bounds(extents, 2, /*base_layer=*/0);
    assert(b.any == 0);
    assert(b.mw == 0 && b.mh == 0 && b.min_x == 0 && b.min_y == 0);
  }

  // Empty extents array entirely.
  {
    bgplane_bounds_t b = compute_bgplane_bounds(nullptr, 0, /*base_layer=*/0);
    assert(b.any == 0);
  }

  std::printf("RESULT: PASS\n");
  return 0;
}
```

- [ ] **Step 2: Run test to verify it fails (header doesn't exist yet)**

Run: `c++ -std=c++17 -Wall -Wextra -O2 -I patches/mister/blitter tests/bgplane_bounds_test.cpp -o /tmp/bgplane_bounds_test`
Expected: FAIL to compile with `fatal error: 'bgplane_bounds.h' file not found` (or equivalent — the header doesn't exist yet).

- [ ] **Step 3: Write the implementation**

Create `patches/mister/blitter/bgplane_bounds.h`:

```c
#ifndef BGPLANE_BOUNDS_H
#define BGPLANE_BOUNDS_H

// [bug #1 fix] One recorded static-tile placement, layer-tagged -- mirrors
// the fields of MisterBlitterRenderer::Impl::StaticEnt (dx,dy,w,h) plus its
// owning StaticBucket's layer, flattened here for pure bounds computation
// independent of the renderer's DDR/hardware-backed types (so this is host-
// unit-testable; MisterBlitterRenderer itself is not, per bgplane_geom_test.cpp).
typedef struct {
    int layer;
    int dx, dy, w, h;
} bgplane_tile_extent_t;

typedef struct {
    int any;              // nonzero iff >=1 extent matched base_layer
    int mw, mh;            // plane pixel dimensions (max - origin)
    int min_x, min_y;      // origin (<=0; only ever shifted to cover negatives)
} bgplane_bounds_t;

// Compute the baked-plane bounding box from every recorded static-tile
// extent belonging to base_layer, ignoring every other layer entirely.
//
// The bgplane bake is restricted to exactly one layer per map -- the base
// layer (map.get_min_layer(), the only layer Entities::draw() is guaranteed
// to process before anything else has drawn to the framebuffer this frame,
// so an opaque full-screen COPY of its baked plane can never erase another
// layer's already-drawn content). See
// docs/superpowers/specs/2026-07-08-bgplane-base-layer-occlusion-design.md
// for the full rationale (this replaces a prior design that merged every
// layer's statics, plus animated-bucket extents, into one plane -- both of
// which are gone here: animated tiles are never baked regardless of layer,
// so their extent never needs to size the plane).
//
// Origin is only ever shifted to cover negative coordinates, never pulled
// positive -- mirrors the single-plane implementation this replaces.
static inline bgplane_bounds_t compute_bgplane_bounds(
        const bgplane_tile_extent_t* extents, int count, int base_layer) {
    bgplane_bounds_t b; b.any = 0; b.mw = 0; b.mh = 0; b.min_x = 0; b.min_y = 0;
    for (int i = 0; i < count; ++i) {
        const bgplane_tile_extent_t* e = &extents[i];
        if (e->layer != base_layer) continue;
        int ex = e->dx + e->w, ey = e->dy + e->h;
        if (!b.any) { b.min_x = e->dx; b.min_y = e->dy; b.any = 1; }
        if (ex > b.mw) b.mw = ex;
        if (ey > b.mh) b.mh = ey;
        if (e->dx < b.min_x) b.min_x = e->dx;
        if (e->dy < b.min_y) b.min_y = e->dy;
    }
    if (b.min_x > 0) b.min_x = 0;
    if (b.min_y > 0) b.min_y = 0;
    b.mw -= b.min_x; b.mh -= b.min_y;
    return b;
}

#endif
```

- [ ] **Step 4: Run test to verify it passes**

Run: `c++ -std=c++17 -Wall -Wextra -O2 -I patches/mister/blitter tests/bgplane_bounds_test.cpp -o /tmp/bgplane_bounds_test && /tmp/bgplane_bounds_test`
Expected: `RESULT: PASS`

- [ ] **Step 5: Register the test in `tests/run_tests.sh`**

Find this existing block (search for `bgplane_geom`):

```bash
echo "== bgplane_geom (background-plane cache cell/plane geometry) =="
CXX="${CXX:-g++}"
$CXX -std=c++17 -Wall -Wextra -O2 -I patches/mister/blitter \
    tests/bgplane_geom_test.cpp -o /tmp/bgplane_geom_test
/tmp/bgplane_geom_test
```

Immediately after it, add:

```bash
echo "== bgplane_bounds (bug #1 fix: base-layer-only bake bounds) =="
CXX="${CXX:-g++}"
$CXX -std=c++17 -Wall -Wextra -O2 -I patches/mister/blitter \
    tests/bgplane_bounds_test.cpp -o /tmp/bgplane_bounds_test
/tmp/bgplane_bounds_test
```

- [ ] **Step 6: Run the full host test suite**

Run: `bash tests/run_tests.sh`
Expected: every existing test still passes, plus the new `bgplane_bounds` section prints `RESULT: PASS`, ending in `All host tests passed.`

- [ ] **Step 7: Commit**

```bash
git add patches/mister/blitter/bgplane_bounds.h tests/bgplane_bounds_test.cpp tests/run_tests.sh
git commit -m "$(cat <<'EOF'
feat(render): add compute_bgplane_bounds helper (bug #1 fix, part 1/5)

Pure, host-testable bounding-box computation for a single map layer's
recorded static-tile extents, ignoring every other layer. This is the
first piece of restricting SOLARUS_BGPLANE's flattened-plane bake to the
map's base layer only (docs/superpowers/specs/2026-07-08-bgplane-base-layer-occlusion-design.md)
-- not yet wired into the renderer.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01D9q29xQQmLGtT7vp1ygtRU
EOF
)"
```

---

### Task 2: Thread `min_layer` through `resident_begin_frame` and `resident_static_before_animated`

**Files:**
- Modify: `work/solarus/include/solarus/graphics/Renderer.h` (base virtual defaults)
- Modify: `work/solarus/src/entities/Entities.cpp` (the one caller)
- Modify: `patches/mister/mister_blitter_renderer.h` (declarations)
- Modify: `patches/mister/mister_blitter_renderer.cpp` (implementation + new `Impl::bg_base_layer` field)

**Interfaces:**
- Consumes: nothing new from Task 1 yet (this task only threads the parameter; Task 3 will actually call `compute_bgplane_bounds`).
- Produces: `Renderer::resident_begin_frame(uintptr_t map_id, uintptr_t tileset_id, int min_layer)`, `Renderer::resident_static_before_animated(int layer) const`, and `MisterBlitterRenderer::Impl::bg_base_layer` (an `int` field, latched once per resident rebuild) — consumed by Tasks 3, 4, 5, 6.

**IMPORTANT — `work/solarus` is a disposable, git-tracked authoring clone.** Before editing it, refresh it from the current patch series so you're editing the exact tree the patches produce:

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
bash scripts/apply_patch_series.sh
```

Expected tail output: `verify ok: ...` lines ending in `VERIFY PASS` then `[apply] OK`.

- [ ] **Step 1: Edit `work/solarus/include/solarus/graphics/Renderer.h`**

Find (exact current text):

```cpp
  virtual int resident_begin_frame(uintptr_t /*map_id*/, uintptr_t /*tileset_id*/) { return 0; }
```

Replace with:

```cpp
  virtual int resident_begin_frame(uintptr_t /*map_id*/, uintptr_t /*tileset_id*/, int /*min_layer*/) { return 0; }
```

Find (exact current text):

```cpp
  virtual bool resident_static_before_animated() const { return false; }
```

Replace with:

```cpp
  virtual bool resident_static_before_animated(int /*layer*/) const { return false; }
```

- [ ] **Step 2: Edit `work/solarus/src/entities/Entities.cpp`**

Find (exact current text, in `Entities::draw()`'s FAST-mode per-layer loop):

```cpp
    const int rmode = R.resident_begin_frame(
        reinterpret_cast<uintptr_t>(&map),
        reinterpret_cast<uintptr_t>(&map.get_tileset()));
```

Replace with:

```cpp
    const int rmode = R.resident_begin_frame(
        reinterpret_cast<uintptr_t>(&map),
        reinterpret_cast<uintptr_t>(&map.get_tileset()),
        map.get_min_layer());
```

Find (exact current text):

```cpp
      const bool _static_first = R.resident_static_before_animated();
```

Replace with:

```cpp
      const bool _static_first = R.resident_static_before_animated(layer);
```

- [ ] **Step 3: Edit `patches/mister/mister_blitter_renderer.h`**

Find:

```cpp
  int  resident_begin_frame(uintptr_t map_id, uintptr_t tileset_id) override;
```

Replace with:

```cpp
  int  resident_begin_frame(uintptr_t map_id, uintptr_t tileset_id, int min_layer) override;
```

Find:

```cpp
  bool resident_static_before_animated() const override;
```

Replace with:

```cpp
  bool resident_static_before_animated(int layer) const override;
```

- [ ] **Step 4: Add the `bg_base_layer` field in `patches/mister/mister_blitter_renderer.cpp`**

Find (in the `Impl` struct, near the other `bg_*` fields):

```cpp
  int      bg_bake_cell_idx = 0;       // next cell index to bake (0..grid.count)
  int      bg_map_w = 0, bg_map_h = 0; // map pixel dims this plane covers
```

Replace with:

```cpp
  int      bg_bake_cell_idx = 0;       // next cell index to bake (0..grid.count)
  int      bg_base_layer = 0;          // [bug #1 fix] map.get_min_layer(), latched once per
                                        // resident rebuild (resident_begin_frame) -- the ONLY
                                        // layer the bake/COPY applies to. Every other layer
                                        // always uses the per-bucket replay fallback.
  int      bg_map_w = 0, bg_map_h = 0; // map pixel dims this plane covers
```

- [ ] **Step 5: Thread `min_layer` through `resident_begin_frame`'s signature and latch it on rebuild**

Find:

```cpp
int MisterBlitterRenderer::resident_begin_frame(uintptr_t map_id, uintptr_t tileset_id) {
```

Replace with:

```cpp
int MisterBlitterRenderer::resident_begin_frame(uintptr_t map_id, uintptr_t tileset_id, int min_layer) {
```

Find (later in the same function, the rebuild branch):

```cpp
  // New / changed signature: rebuild the resident list THIS frame.
  d->res_map = map_id; d->res_tileset = tileset_id;
  d->res_buckets.clear(); d->res_ops.clear();
```

Replace with:

```cpp
  // New / changed signature: rebuild the resident list THIS frame.
  d->res_map = map_id; d->res_tileset = tileset_id;
  // [bug #1 fix] Latch the map's base layer for this whole build -- res_arm_,
  // bake_background_plane_step, resident_emit_static_layer, and
  // resident_static_before_animated all gate on this. Not map.get_min_layer()
  // read live elsewhere: the renderer only ever sees opaque map_id/tileset_id
  // tokens, so this is the one place it learns the actual layer range.
  d->bg_base_layer = min_layer;
  d->res_buckets.clear(); d->res_ops.clear();
```

- [ ] **Step 6: Update `resident_static_before_animated`'s signature and gate on the base layer**

Find:

```cpp
bool MisterBlitterRenderer::resident_static_before_animated() const {
  // Only while the flattened plane is actually what's about to draw -- the
  // per-bucket replay fallback (bgplane off, or plane not baked yet right after a
  // map change) is order-independent, same as the default no-op renderer's false.
  return d->bgplane_enabled && d->bg_plane_valid;
}
```

Replace with:

```cpp
bool MisterBlitterRenderer::resident_static_before_animated(int layer) const {
  // Only while the flattened plane is actually what's about to draw for THIS
  // layer -- i.e. only the base layer (bg_base_layer, latched from
  // map.get_min_layer() in resident_begin_frame). Every other layer's
  // per-bucket replay fallback is order-independent, same as the default
  // no-op renderer's false. See docs/superpowers/specs/2026-07-08-bgplane-base-layer-occlusion-design.md.
  return d->bgplane_enabled && d->bg_plane_valid && layer == d->bg_base_layer;
}
```

- [ ] **Step 7: Refresh `work/solarus`, export the patch series, verify clean re-apply**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister/work/solarus
git add -A include/solarus/graphics/Renderer.h src/entities/Entities.cpp
git commit -m "feat(render): thread min_layer through resident_begin_frame/resident_static_before_animated

Part of restricting SOLARUS_BGPLANE's bake to the map's base layer only.
Not yet used by the renderer's bgplane logic -- that's the next commits."
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
bash scripts/export_patches.sh
bash scripts/apply_patch_series.sh
```

Expected: `export_patches.sh` prints `[export] regenerated N patches from work/solarus on v1.6`; `apply_patch_series.sh`'s tail ends in `VERIFY PASS` / `[apply] OK` with no `git am` failures.

- [ ] **Step 8: Run the host test suite (regression check — no behavior change yet, just signatures)**

Run: `bash tests/run_tests.sh`
Expected: `All host tests passed.` (this task doesn't change any tested behavior, only signatures internal to the C++ engine build, which the host test suite doesn't compile — this step exists to confirm nothing else broke)

- [ ] **Step 9: Commit the regenerated patch series files**

```bash
git add patches/series/ patches/mister/mister_blitter_renderer.h patches/mister/mister_blitter_renderer.cpp
git commit -m "$(cat <<'EOF'
feat(render): thread min_layer through resident_begin_frame (bug #1 fix, part 2/5)

Renderer::resident_begin_frame() and Renderer::resident_static_before_animated()
both gain a layer/min_layer parameter, threaded from Entities::draw()'s
map.get_min_layer(). MisterBlitterRenderer latches it as Impl::bg_base_layer
once per resident rebuild. Not yet consumed by the bake/COPY logic itself --
that's Tasks 3-6 of docs/superpowers/specs/2026-07-08-bgplane-base-layer-occlusion-design.md.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01D9q29xQQmLGtT7vp1ygtRU
EOF
)"
```

---

### Task 3: Restrict `res_arm_()`'s bounding-box computation to the base layer

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp`

**Interfaces:**
- Consumes: `compute_bgplane_bounds` / `bgplane_tile_extent_t` / `bgplane_bounds_t` from Task 1 (`patches/mister/blitter/bgplane_bounds.h`); `Impl::bg_base_layer` from Task 2.
- Produces: no new symbols; `res_arm_()`'s behavior changes to only size/allocate the plane from the base layer's static content.

- [ ] **Step 1: Add the include**

In `patches/mister/mister_blitter_renderer.cpp`, find:

```cpp
#include "blitter/bgplane_geom.h"     // [Phase 3b] cell grid / plane-offset math
```

Add immediately after it:

```cpp
#include "blitter/bgplane_bounds.h"   // [bug #1 fix] base-layer-only bounding box
```

- [ ] **Step 2: Replace the bounding-box computation in `res_arm_()`**

Find this exact block (the whole `if (d->bgplane_enabled) { ... }` body inside `res_arm_()`):

```cpp
  if (d->bgplane_enabled) {
    // Free the previous map's plane region before computing this map's bounds --
    // res_arm_ runs once per rebuild, so bg_plane_sdram_base/bg_map_w/bg_map_h
    // still name the map we're replacing (they're only overwritten below, on a
    // successful blt_alloc for the NEW map). Without this, every map transition
    // leaked another map-sized region out of the finite sdram_perm pool.
    if (d->bg_plane_sdram_allocated) {
      blt_free(&d->em.sdram_perm, d->bg_plane_sdram_base,
                bgplane_total_bytes(d->bg_map_w, d->bg_map_h));
      d->bg_plane_sdram_allocated = false;
    }
    // Track BOTH the min and max map-coord seen across every recorded tile: a
    // map's content is not guaranteed to start at (0,0) (real hardware has shown
    // static-tile dx/dy as low as -8/-24), so the plane's true pixel extent is
    // (max - min), not max assuming a zero origin.
    int mw = 0, mh = 0;
    int min_x = 0, min_y = 0;
    bool first = true;
    for (const auto& b : d->res_static_buckets) {
      for (const auto& e : b.ent) {
        int ex = (int)e.dx + (int)e.w, ey = (int)e.dy + (int)e.h;
        if (ex > mw) mw = ex;
        if (ey > mh) mh = ey;
        if (first) { min_x = e.dx; min_y = e.dy; first = false; }
        if ((int)e.dx < min_x) min_x = e.dx;
        if ((int)e.dy < min_y) min_y = e.dy;
      }
    }
    for (const auto& b : d->res_buckets) {
      for (const auto& e : b.hw) {
        if (e.pid >= d->res_patterns.size()) continue;
        const Rectangle& fr = d->res_patterns[e.pid].frames[0];
        int ex = (int)e.dx + fr.get_width(), ey = (int)e.dy + fr.get_height();
        if (ex > mw) mw = ex;
        if (ey > mh) mh = ey;
        if (first) { min_x = e.dx; min_y = e.dy; first = false; }
        if ((int)e.dx < min_x) min_x = e.dx;
        if ((int)e.dy < min_y) min_y = e.dy;
      }
    }
    if (min_x > 0) min_x = 0;  // origin is never pulled positive -- only shifted to cover negatives
    if (min_y > 0) min_y = 0;
    mw -= min_x; mh -= min_y;  // true extent = max - origin, not max assuming origin (0,0)
    if (mw > 0 && mh > 0) {
      uint32_t need = bgplane_total_bytes(mw, mh);
      uint32_t off = blt_alloc(&d->em.sdram_perm, need);
      if (off == BLT_ALLOC_FAIL) {
        std::fprintf(stderr,
            "[blitter bgplane] FATAL: perm SDRAM exhausted allocating %u bytes "
            "for a %dx%d background plane -- feature stays off for this map\n",
            need, mw, mh);
        d->bg_baking = false; d->bg_plane_valid = false;
      } else {
        d->bg_map_w = mw; d->bg_map_h = mh;
        d->bg_origin_x = min_x; d->bg_origin_y = min_y;
        // Latch NOW, once, for this whole bake -- see the field comment (Impl::bg_clear_rgb565).
        d->bg_clear_rgb565 = to_rgb565(g_bg_color_r, g_bg_color_g, g_bg_color_b);
        d->bg_plane_sdram_base = off;
        d->bg_plane_sdram_allocated = true;
        d->bg_bake_cell_idx = 0;
        d->bg_baking = true;
        d->bg_plane_valid = false;
        if (min_x != 0 || min_y != 0) {
          std::fprintf(stderr,
              "[blitter bgplane] map content extends into negative map-coord space "
              "(origin=%d,%d) -- compensated in the plane's internal coordinate space\n",
              min_x, min_y);
        }
      }
    }
  }
  d->res_armed = true;
```

Replace with:

```cpp
  if (d->bgplane_enabled) {
    // Free the previous map's plane region before computing this map's bounds --
    // res_arm_ runs once per rebuild, so bg_plane_sdram_base/bg_map_w/bg_map_h
    // still name the map we're replacing (they're only overwritten below, on a
    // successful blt_alloc for the NEW map). Without this, every map transition
    // leaked another map-sized region out of the finite sdram_perm pool.
    if (d->bg_plane_sdram_allocated) {
      blt_free(&d->em.sdram_perm, d->bg_plane_sdram_base,
                bgplane_total_bytes(d->bg_map_w, d->bg_map_h));
      d->bg_plane_sdram_allocated = false;
    }
    // [bug #1 fix] Bound the plane to the map's BASE layer only (bg_base_layer,
    // latched from map.get_min_layer() in resident_begin_frame) -- the only
    // layer guaranteed nothing has drawn to the framebuffer yet when its
    // opaque COPY fires. Animated-bucket extents (res_buckets) no longer
    // contribute at all: animated tiles are never baked into the plane
    // regardless of layer, so folding their extent into the bounding box only
    // risked over-sizing it for no benefit. See
    // docs/superpowers/specs/2026-07-08-bgplane-base-layer-occlusion-design.md.
    std::vector<bgplane_tile_extent_t> extents;
    extents.reserve(d->res_static_buckets.size());
    for (const auto& b : d->res_static_buckets)
      for (const auto& e : b.ent)
        extents.push_back({b.layer, (int)e.dx, (int)e.dy, (int)e.w, (int)e.h});
    bgplane_bounds_t bounds =
        compute_bgplane_bounds(extents.data(), (int)extents.size(), d->bg_base_layer);
    if (bounds.any && bounds.mw > 0 && bounds.mh > 0) {
      uint32_t need = bgplane_total_bytes(bounds.mw, bounds.mh);
      uint32_t off = blt_alloc(&d->em.sdram_perm, need);
      if (off == BLT_ALLOC_FAIL) {
        std::fprintf(stderr,
            "[blitter bgplane] FATAL: perm SDRAM exhausted allocating %u bytes "
            "for a %dx%d background plane -- feature stays off for this map\n",
            need, bounds.mw, bounds.mh);
        d->bg_baking = false; d->bg_plane_valid = false;
      } else {
        d->bg_map_w = bounds.mw; d->bg_map_h = bounds.mh;
        d->bg_origin_x = bounds.min_x; d->bg_origin_y = bounds.min_y;
        // Latch NOW, once, for this whole bake -- see the field comment (Impl::bg_clear_rgb565).
        d->bg_clear_rgb565 = to_rgb565(g_bg_color_r, g_bg_color_g, g_bg_color_b);
        d->bg_plane_sdram_base = off;
        d->bg_plane_sdram_allocated = true;
        d->bg_bake_cell_idx = 0;
        d->bg_baking = true;
        d->bg_plane_valid = false;
        if (bounds.min_x != 0 || bounds.min_y != 0) {
          std::fprintf(stderr,
              "[blitter bgplane] map content extends into negative map-coord space "
              "(origin=%d,%d) -- compensated in the plane's internal coordinate space\n",
              bounds.min_x, bounds.min_y);
        }
      }
    }
    // else: the base layer has no recorded static content -- the per-layer-
    // plane optimization simply doesn't engage for this map. bg_baking/
    // bg_plane_valid stay false (already set on the rebuild path in
    // resident_begin_frame), so every layer -- including the base layer --
    // falls back to the per-bucket replay, same as SOLARUS_BGPLANE being
    // off entirely. No sliding to another layer with content: see the design
    // doc for why that would be unsafe.
  }
  d->res_armed = true;
```

- [ ] **Step 3: Refresh `work/solarus` and verify clean apply**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
bash scripts/apply_patch_series.sh
```

Expected: tail ends in `VERIFY PASS` / `[apply] OK` (this task only touches `patches/mister/`, a whole-file copy — no `git am` involved, so this should always apply cleanly; running it anyway confirms `apply_mister_files.sh` picked up the change).

- [ ] **Step 4: Run the host test suite**

Run: `bash tests/run_tests.sh`
Expected: `All host tests passed.` (still no C++ engine compile at this stage — this confirms the `bgplane_bounds_test` from Task 1 is unaffected)

- [ ] **Step 5: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "$(cat <<'EOF'
feat(render): restrict bgplane bounding box to the base layer (bug #1 fix, part 3/5)

res_arm_() now computes the baked plane's dimensions/origin from
compute_bgplane_bounds(), filtered to Impl::bg_base_layer, instead of
mixing in every layer's static buckets plus every animated bucket's
extent. If the base layer has no recorded static content, the plane
simply isn't allocated (bg_baking/bg_plane_valid stay false) -- no
fallback to another layer, per the design doc's safety argument.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01D9q29xQQmLGtT7vp1ygtRU
EOF
)"
```

---

### Task 4: Restrict `bake_background_plane_step()` to the base layer's buckets

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp`

**Interfaces:**
- Consumes: `Impl::bg_base_layer` (Task 2).
- Produces: no new symbols; the per-cell paint loop now skips any bucket not belonging to the base layer.

- [ ] **Step 1: Add the layer filter**

Find this exact block (inside `bake_background_plane_step()`):

```cpp
  for (size_t bi = 0; bi < d->res_static_buckets.size(); ++bi) {
    const Impl::StaticBucket& b = d->res_static_buckets[bi];
    if (b.hw_count == 0) continue;
    blt_surface_ref_t tex = d->upload(*b.tsimg, b.fmt);
```

Replace with:

```cpp
  for (size_t bi = 0; bi < d->res_static_buckets.size(); ++bi) {
    const Impl::StaticBucket& b = d->res_static_buckets[bi];
    if (b.hw_count == 0) continue;
    // [bug #1 fix] Only bake this layer's buckets -- the plane covers the
    // base layer alone now (see res_arm_/compute_bgplane_bounds). A bucket
    // from any other layer would have been ignored when sizing the plane
    // (res_arm_), so painting it here would write out of the allocated
    // plane's bounds; skip it instead.
    if (b.layer != d->bg_base_layer) continue;
    blt_surface_ref_t tex = d->upload(*b.tsimg, b.fmt);
```

- [ ] **Step 2: Refresh `work/solarus` and verify clean apply**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
bash scripts/apply_patch_series.sh
```

Expected: tail ends in `VERIFY PASS` / `[apply] OK`.

- [ ] **Step 3: Run the host test suite**

Run: `bash tests/run_tests.sh`
Expected: `All host tests passed.`

- [ ] **Step 4: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "$(cat <<'EOF'
feat(render): skip non-base-layer buckets when baking bgplane cells (bug #1 fix, part 4/5)

bake_background_plane_step() now skips any StaticBucket whose layer isn't
Impl::bg_base_layer, matching res_arm_'s bounding-box restriction from the
previous commit -- painting a non-base-layer bucket would otherwise write
outside the plane's (now smaller) allocated bounds.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01D9q29xQQmLGtT7vp1ygtRU
EOF
)"
```

---

### Task 5: Gate `resident_emit_static_layer()` on the base layer

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp`

**Interfaces:**
- Consumes: `Impl::bg_base_layer` (Task 2).
- Produces: no new symbols; `resident_emit_static_layer(int layer)` now only takes the flattened-plane COPY path when `layer == bg_base_layer`, fixing the cross-layer occlusion bug.

- [ ] **Step 1: Gate the COPY path on the base layer, and rewrite the now-obsolete "not addressed here" comment**

Find this exact block:

```cpp
// [Phase 3b] Replace the whole static-bucket replay with one ordinary windowed
// COPY from the baked background plane, when available. Falls back to the
// original per-bucket replay (res_emit_static_bucket_ per op, unchanged) when
// the plane isn't ready yet (bg_plane_valid false -- e.g. still baking right
// after a map change) or the feature is gated off. Because the plane is
// stored map-scan-order (bgplane_geom.h), the source window is always a
// single contiguous strided rect -- no per-cell splitting needed even when
// the camera straddles a cell boundary.
void MisterBlitterRenderer::resident_emit_static_layer(int layer) {
  if (!d->bgplane_enabled || !d->bg_plane_valid) {
    for (size_t i = 0; i < d->res_static_ops.size(); ++i)
      if (d->res_static_ops[i].layer == layer)
        res_emit_static_bucket_(d->res_static_ops[i].bk);
    return;
  }
  // The baked plane already merges ALL static layers into one image (see
  // bake_background_plane_step), but the engine calls this function once PER
  // map layer from the same per-frame draw loop that also draws each layer's
  // animated tiles/dynamic entities. A full opaque COPY on every call would
  // overwrite earlier layers' already-drawn content -- so latch it to fire
  // at most once per frame (reset in ensure_frame's per-frame reset block).
  // Entities.cpp now asks resident_static_before_animated() where to put this call;
  // this renderer answers true whenever the plane is what's about to draw (below),
  // so it still runs before any animated/entity draws this frame, same as always --
  // the static/animated reorder needed for correct parallax paint order (elsewhere)
  // doesn't change this path's timing. The pre-existing cross-layer flattening bug
  // (hero/entities on a later layer still land on top of ALL static content, since
  // it's one flat plane blitted on the first layer) is untouched -- not addressed
  // here -- SOLARUS_BGPLANE stays opt-in/default-OFF pending a per-layer-aware bake.
  if (d->bg_plane_copied_this_frame) return;
  d->bg_plane_copied_this_frame = true;
```

Replace with:

```cpp
// [Phase 3b] Replace the whole static-bucket replay with one ordinary windowed
// COPY from the baked background plane, when available. Falls back to the
// original per-bucket replay (res_emit_static_bucket_ per op, unchanged) when
// the plane isn't ready yet (bg_plane_valid false -- e.g. still baking right
// after a map change), the feature is gated off, or (bug #1 fix) this ISN'T
// the map's base layer -- the plane only ever covers bg_base_layer now (see
// res_arm_/bake_background_plane_step), so every other layer always uses the
// per-bucket path, exactly as if BGPLANE were off. Because the plane is
// stored map-scan-order (bgplane_geom.h), the source window is always a
// single contiguous strided rect -- no per-cell splitting needed even when
// the camera straddles a cell boundary.
void MisterBlitterRenderer::resident_emit_static_layer(int layer) {
  if (!d->bgplane_enabled || !d->bg_plane_valid || layer != d->bg_base_layer) {
    for (size_t i = 0; i < d->res_static_ops.size(); ++i)
      if (d->res_static_ops[i].layer == layer)
        res_emit_static_bucket_(d->res_static_ops[i].bk);
    return;
  }
  // The plane covers ONLY the base layer now (bug #1 fix), so this full
  // opaque COPY is safe: this is the one layer Entities::draw() is
  // guaranteed to process before anything else has drawn to the framebuffer
  // this frame. Every higher layer -- including whatever occludes the hero
  // (tree canopy, doorframes) -- falls through to the per-bucket path above,
  // which fires at the correct point in ITS OWN layer's draw step and
  // respects gaps/transparency, fixing the reported occlusion bug. The
  // per-frame latch below is now redundant in principle (this branch is only
  // ever reached once per frame, since bg_base_layer appears exactly once in
  // Entities::draw()'s per-layer loop) but kept as cheap defense-in-depth.
  if (d->bg_plane_copied_this_frame) return;
  d->bg_plane_copied_this_frame = true;
```

- [ ] **Step 2: Refresh `work/solarus` and verify clean apply**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
bash scripts/apply_patch_series.sh
```

Expected: tail ends in `VERIFY PASS` / `[apply] OK`.

- [ ] **Step 3: Run the host test suite**

Run: `bash tests/run_tests.sh`
Expected: `All host tests passed.`

- [ ] **Step 4: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "$(cat <<'EOF'
fix(render): only take the bgplane COPY path on the map's base layer (bug #1 fix, part 5/5)

resident_emit_static_layer(layer) now falls back to the per-bucket replay
for every layer except bg_base_layer, instead of taking the flattened
plane's opaque full-frame COPY on whichever layer draws first regardless
of which layer that plane actually covers. Combined with the previous
three commits (bounds/bake restricted to the base layer, the min_layer
threading from Entities.cpp), this is the actual fix for bug #1: hero/
entities no longer paint in front of higher-layer occluders (tree canopy,
doorframes) under SOLARUS_BGPLANE, since those layers now use the same
per-bucket path they'd use with BGPLANE off.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01D9q29xQQmLGtT7vp1ygtRU
EOF
)"
```

---

### Task 6: Cross-build, deploy, and HW-validate

**Files:** none new — this task builds and tests the accumulated changes from Tasks 1-5.

**Interfaces:**
- Consumes: everything from Tasks 1-5.
- Produces: `build/armhf/solarus-run`, `build/armhf/libsolarus.so.1.6.5`, deployed to the device; HW validation evidence (screenshots, diag log excerpts).

- [ ] **Step 1: Full clean re-apply of the patch series (sanity check before the real build)**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
bash scripts/apply_patch_series.sh
```

Expected: tail ends in `VERIFY PASS` / `[apply] OK` with no `git am` conflicts.

- [ ] **Step 2: Run the full host test suite one more time**

Run: `bash tests/run_tests.sh`
Expected: `All host tests passed.`

- [ ] **Step 3: Cross-build the armhf engine inside Docker**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
rm -rf build/armhf
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_engine.sh
```

Expected: ends with `[100%] Built target solarus-run` and `Build done. Artifacts under build/armhf/ :` listing `build/armhf/solarus-run`. If this fails with a CMake "different directory" error, run `rm -rf build/armhf` and retry (stale cache from a prior host-vs-container invocation mismatch).

- [ ] **Step 4: If the build fails, fix compile errors and re-run Step 3**

The most likely failure mode: a signature mismatch missed in Task 2 or Task 5 (e.g. a call site still passing the old 2-argument `resident_begin_frame`, or a leftover 0-argument `resident_static_before_animated()` call). Grep for stale call sites:

```bash
grep -rn "resident_begin_frame(" work/solarus/src work/solarus/include patches/mister
grep -rn "resident_static_before_animated(" work/solarus/src work/solarus/include patches/mister
```

Every result should show 3 arguments for `resident_begin_frame` and 1 argument for `resident_static_before_animated` (declarations may show named or `/*commented*/` parameters — that's fine, just confirm the count). Fix any mismatch, then re-run Step 3.

- [ ] **Step 5: Refresh `deploy/` and push to the device**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
cp build/armhf/libsolarus.so.1.6.5 deploy/libsolarus.so.1.6.5
cp build/armhf/libsolarus.so.1.6.5 deploy/libs/libsolarus.so.1.6.5
cp build/armhf/solarus-run deploy/solarus-run
ssh root@192.168.20.81 'kill -9 $(pidof solarus-run) 2>/dev/null; sleep 0.5; pidof solarus-run; echo killed'
python3 deploy.py --no-rbf --host 192.168.20.81
```

Expected: `deploy.py` ends with `Done. Load the Solarus core from the MiSTer menu...`. Before this step, confirm with the user that the Solarus core is currently loaded on the device (a prior session in this project found that launching solarus-run against a different core causes an early, silent-looking exit) -- if unsure, ask.

**Do not write to `/media/fat/config/Solarus.s0` while an engine may still be running with the same quest** -- doing so triggers `quest_manager.sh`'s auto-launch, which can spawn a SECOND `solarus-run` process alongside a manually-launched one. On this device (492MB RAM, ~325MB per `solarus-run` instance), two overlapping instances reliably trigger a kernel OOM-kill of one of them. Always `kill -9 $(pidof solarus-run)` and confirm `pidof solarus-run` is empty before writing `Solarus.s0` or launching manually.

- [ ] **Step 6: Launch with diagnostics and the Lua console, confirm a single stable instance**

```bash
ssh root@192.168.20.81 '
rm -f /tmp/solarus_stdin /tmp/solarus_cmdlog
mkfifo /tmp/solarus_stdin
touch /tmp/solarus_cmdlog
cd /media/fat/games/Solarus
setsid sh -c "tail -n0 -F /tmp/solarus_cmdlog > /tmp/solarus_stdin" </dev/null >/tmp/tail_holder.log 2>&1 &
sleep 0.3
SOLARUS_LUACONSOLE=0 setsid sh ./solarus_run.sh </tmp/solarus_stdin >/tmp/solarus_launch.log 2>&1 &
sleep 2
pidof solarus-run
cat /tmp/solarus_launch.log
'
```

Expected: exactly one PID printed, and the launch log shows `Solarus: lua-console=0 (arg: -lua-console=yes)` and `Solarus: DIAG capture -> ...`. `diag.env` on the device already has `SOLARUS_BGPLANE=1` set (from this project's prior session), so BGPLANE is on by default for this test -- confirm with `ssh root@192.168.20.81 'grep -i "bgplane bake ENABLED" /media/fat/logs/Solarus/Solarus.diag.log'` (or whatever `SOLARUS_DIAG_LOG` path `diag.env` currently points at).

To drive the hero through the title screen and save-select without a physical controller, hammer the Action button bit via `devmem` (the FPGA re-drives the register every frame, so a single write is overwritten -- hammer in a tight loop):

```bash
ssh root@192.168.20.81 '
for i in $(seq 1 400); do busybox devmem 0x3A000008 32 0x20; done
busybox devmem 0x3A000008 32 0x0
'
```

Repeat with a ~1.5s sleep between presses until a Lua console query confirms `sol.main.get_game()` returns non-nil (see the console query pattern below).

- [ ] **Step 7: Ask the user for a map/spot with tree-canopy or doorframe occlusion**

This plan does not hardcode a specific map, since the exact spot depends on which area of Mystery of Solarus DX (or whichever quest is loaded) has a clear canopy-hides-hero or door-frame-hides-hero setup. Ask the user directly, or navigate the overworld yourself (via the `devmem` input injection above, taking periodic screenshots with `echo screenshot > /dev/MiSTer_cmd` and fetching them via `scp`) to find one: a good candidate is any grove of trees whose canopy sprite is on a higher layer than the hero, or any building entrance with a doorframe/awning that should visually cover the hero's head as they walk under it.

Once you have a candidate spot, query the hero's exact position via the Lua console for later reproducibility:

```bash
ssh root@192.168.20.81 'echo "local g=sol.main.get_game(); if g then local m=g:get_map(); local h=m:get_hero(); local x,y,l=h:get_position(); print(string.format(\"MAP=%s X=%d Y=%d L=%d\", m:get_id(), x, y, l)) else print(\"NO_GAME\") end" >> /tmp/solarus_cmdlog; sleep 1; grep -A3 "Begin Lua command" /media/fat/logs/Solarus/Solarus.diag.log | tail -4'
```

- [ ] **Step 8: Capture a screenshot at the occlusion spot and confirm the fix**

```bash
ssh root@192.168.20.81 'echo screenshot > /dev/MiSTer_cmd; sleep 1; ls -t /media/fat/screenshots/Solarus/*.png | head -1'
scp root@192.168.20.81:/media/fat/screenshots/Solarus/<latest-filename>.png /tmp/bug1_after_fix.png
```

View `/tmp/bug1_after_fix.png`. Expected: the hero is correctly hidden (fully or partially, matching the occluding sprite's actual shape) by the canopy/doorframe, not drawn in front of it. If the hero is still drawn in front, STOP -- do not proceed to Step 9. Re-check: is `bg_base_layer` actually being latched correctly (add a temporary diagnostic print in `resident_begin_frame` if needed, following the pattern already used for the bgplane COPY diagnostic in `resident_emit_static_layer`, gated on `d->diag` and throttled to avoid log spam)? Is the occluding sprite actually on a layer other than the hero's (if it's on the SAME layer as the hero, this fix doesn't apply -- same-layer occlusion is a per-entity draw-order concern, not a bgplane layer concern, and is out of scope for this fix)?

- [ ] **Step 9: Re-confirm bug #2 (parallax) and the background-color fix still hold**

Navigate to the parallax map from the prior session's fix (map 119, roughly X=117 Y=312 per the earlier session's Lua console query) and confirm the distant background still renders behind the foreground, not in front and not black. Also re-check a map with a solid-color "floor" background (map 4 in Mystery of Solarus DX, tileset 1's `background_color{104,184,104}`) still renders that color correctly (not black) wherever no tile covers it. Screenshot both.

- [ ] **Step 10: Record the perf tradeoff**

```bash
ssh root@192.168.20.81 'grep "\[blitter hwperf\]" /media/fat/logs/Solarus/Solarus.diag.log | tail -5'
```

Report the `fabric_hw=...ms` figure from a busy scene (ideally the same reference scene used in PR #77's original measurement, if reachable) so the user can compare against the ~7ms full-flatten figure and the ~20ms pre-BGPLANE baseline mentioned in the design doc.

- [ ] **Step 11: Report results to the user**

Summarize: whether bug #1 is confirmed fixed, whether bug #2 and the background-color fix still hold, and the measured perf figure. Do not commit further changes at this point -- Tasks 1-5's commits already captured the actual code change; this task is validation only.

---

## Self-Review Notes

- **Spec coverage:** every component listed in the design doc's "Components changed" section has a corresponding task (Task 2: `resident_begin_frame` + `resident_static_before_animated` signatures; Task 3: `res_arm_`; Task 4: `bake_background_plane_step`; Task 5: `resident_emit_static_layer`). The design doc's "Testing" section (host: extend bgplane test; HW: 3 numbered checks) maps to Task 1 (host, as a new pure-helper test rather than modifying `bgplane_geom_test.cpp` directly, since the bounds logic is genuinely separable and the existing file tests unrelated geometry) and Task 6 Steps 7-10 (the three HW checks).
- **Placeholder scan:** no TBD/TODO; the one open-ended item (Task 6 Step 7, finding a specific occlusion map/spot) is explicitly flagged as needing the user or live exploration, with a concrete method given for both — not a vague "add appropriate tests" placeholder.
- **Type consistency:** `bgplane_tile_extent_t`/`bgplane_bounds_t` field names and the `compute_bgplane_bounds` signature are identical between Task 1's header/test and Task 3's call site. `bg_base_layer` is named identically everywhere it's introduced (Task 2) and consumed (Tasks 3, 4, 5).
