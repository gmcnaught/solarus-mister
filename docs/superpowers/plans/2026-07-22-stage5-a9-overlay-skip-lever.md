# Stage 5 (A9 track) — Overlay content-identity skip lever — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the redundant per-frame overlay/root ARGB4444 re-convert+re-upload (the #1 A9 leaf, ~6 ms/frame) when the root's rendered content is identical to the previous frame — gated `SOLARUS_OVERLAYSKIP`, default-off, HW-validated.

**Architecture:** A pure, C-compatible header (`mister_overlay_id.h`) computes a rolling **op-param digest** of the root's draw operations plus a **per-frame source-mutation** guard. The renderer folds each root draw into the digest; at composite time, if the digest matches last frame AND no source surface was mutated this frame, it removes the root from `dirty_src` so the existing `upload()` cache-hit path returns the already-uploaded ref *without* reconverting — while still emitting the cached full-screen blit. A `[blitter overlayid]` diagnostic measures the skip-rate and proves the guard fires on real HUD changes **before** the skip is trusted.

**Tech Stack:** C++17 renderer (`patches/mister/mister_blitter_renderer.cpp`, a whole-file copy — edit directly), a C-compatible header, C host test (compiled with `cc` like the existing `blt_*` tests), armhf cross-build, MiSTer device.

**Spec:** `docs/superpowers/2026-07-22-stage5-a9-decision.md` ("The ONE lever (scoped) — corrected after the whole-branch review").

## Global Constraints

- **Renderer file is a whole-file copy**, NOT in the patch series — edit `patches/mister/mister_blitter_renderer.cpp` directly (CLAUDE.md "Engine source layout"). Confirm with `grep mister_blitter_renderer patches/series/0001*.patch` → no hit.
- **Gating:** `SOLARUS_OVERLAYSKIP` is an **opt-in lever** — parse via **`std::getenv("SOLARUS_OVERLAYSKIP") != nullptr`** (like `SOLARUS_GRIDOV` at `:2435`), NOT `mister_flag_default_on`. Default-off. Absent/`=0`-absent ⇒ **exact prior behaviour** (a true no-op: the digest/tracking only runs when `diag || overlayskip_on`, and the skip only when `overlayskip_on`).
- **Never reuse the persistent `dirty_src` as a per-frame mutation signal.** `dirty_src` is only erased on fabric re-upload (`:1828`) or surface destruction (`:1099`); a base-SDL HUD source, once mutated, stays in it for its lifetime. The per-frame mutation signal is a NEW set (`written_this_frame`) cleared every frame.
- **The cached overlay blit must still be EMITTED every frame** — only the *convert + upload* is skipped, never the `blt_blit` emit (the ring is rebuilt per frame; skipping the emit would drop the overlay entirely).
- **Type-check both `-D` flags (mandatory, CLAUDE.md):** `g++ -fsyntax-only -std=c++17 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO -I patches/mister -I patches/mister/blitter -I work/solarus/include -I build/armhf/include -I work/solarus/libraries/win32/mingw32/include $(sdl2-config --cflags) patches/mister/mister_blitter_renderer.cpp`.
- **Host tests use `cc` (C)** — the identity header must compile as C (no STL, `const void*` for the surface pointer, `uintptr_t`).
- **HW A/B spots (identical to the decision-doc capture):** map 119 `save1`→`from_dungeon_10`; map 3 `save1`→`out_link_house`. Standing + moving. Capture with `scripts/perf/capture_a9_drill.sh` (already on this branch).
- **Device discipline:** one engine on the fabric only; log to `/media/fat/logs/Solarus/`; sequence around the FPGA-track agent (`solarus-two-engines-wedge-launch-recipe`). Build+deploy: `scripts/build_engine.sh` (armhf Docker) → `./deploy.py --no-rbf` (RBF unchanged) → verify on-device sha1.
- **Never self-declare visual correctness** — the stale-HUD check is an **operator** gate.
- Commit trailer on every commit: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` + the `Claude-Session:` line.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `patches/mister/mister_overlay_id.h` | Pure C-compatible unit: fold a root draw into a rolling op-param digest; decide skippable (digest==prev ∧ ¬src_mutated ∧ had_draw); advance per frame | 1 |
| `tests/overlay_id_test.c` | Host unit test over the pure unit (identity, mutation-guard, geometry/opacity/blend/color changes, first-frame, empty-frame) | 1 |
| `tests/run_tests.sh` | Wire the new test into the suite | 1 |
| `patches/mister/mister_blitter_renderer.cpp` | Integrate: include header; members; ctor flag; per-frame mutation tracking in `mark_src_dirty`; fold at the root-draw site; skip in `emit_overlay_composite`; `[blitter overlayid]` banner; per-frame reset | 2 |
| `docs/superpowers/2026-07-22-stage5-a9-overlay-skip-hw-validation.md` | HW results: diag skip-rate + guard-fires precheck, A/B present-ms delta, operator visual gate, ship-default recommendation | 3 |

---

## Task 1: Pure identity unit + host test (TDD, worktree, no HW)

**Files:**
- Create: `patches/mister/mister_overlay_id.h`
- Test: `tests/overlay_id_test.c`
- Modify: `tests/run_tests.sh`

**Interfaces:**
- Produces (C linkage, header-only `static inline`):
  - `typedef struct { unsigned long long digest, prev; int src_mutated, had_draw; } overlay_id_t;`
  - `void overlay_id_fold(overlay_id_t* o, const void* src, int sx,int sy,int sw,int sh, int dx,int dy,int dw,int dh, int blend,int opacity, int rot_milli,int sx_milli,int sy_milli, unsigned color_rgba, int src_written_this_frame);`
  - `int  overlay_id_skippable(const overlay_id_t* o);` — `had_draw && digest==prev && !src_mutated`
  - `void overlay_id_next(overlay_id_t* o);` — `prev=digest; digest=0; src_mutated=0; had_draw=0`

- [ ] **Step 1: Write the failing test**

Create `tests/overlay_id_test.c`:

```c
/* Host unit test for the overlay content-identity unit. cc-compatible. */
#include <stdio.h>
#include <assert.h>
#include "../patches/mister/mister_overlay_id.h"

/* Fold one "typical HUD draw": src ptr S, src 0,0,16,16 -> dst 8,8,16,16,
 * blend 1, opacity 255, no rot/scale, white, not-mutated-this-frame. */
static void hud(overlay_id_t* o, const void* s, int dx, int opacity,
                unsigned color, int mutated) {
  overlay_id_fold(o, s, 0,0,16,16, dx,8,16,16, 1, opacity, 0,1000,1000, color, mutated);
}

int main(void) {
  int S1, S2;   /* two distinct surface addresses */
  const void *A = &S1, *B = &S2;
  unsigned WHITE = 0xffffffffu;

  /* 1. Two identical frames -> the SECOND is skippable, the first is not. */
  overlay_id_t o = {0,0,0,0};
  hud(&o, A, 8, 255, WHITE, 0);
  assert(!overlay_id_skippable(&o));          /* frame 1: prev=0, no match */
  overlay_id_next(&o);
  hud(&o, A, 8, 255, WHITE, 0);
  assert(overlay_id_skippable(&o));           /* frame 2: identical -> skip */

  /* 2. Mutation guard: identical op-params but the source was written this
   *    frame (HUD value re-rendered) -> NOT skippable (stale-HUD guard). */
  overlay_id_next(&o);
  hud(&o, A, 8, 255, WHITE, 1);               /* mutated=1 */
  assert(!overlay_id_skippable(&o));

  /* 3. Moved dst -> not skippable. */
  overlay_id_t o3 = {0,0,0,0};
  hud(&o3, A, 8, 255, WHITE, 0); overlay_id_next(&o3);
  hud(&o3, A, 9, 255, WHITE, 0);              /* dst x 8 -> 9 */
  assert(!overlay_id_skippable(&o3));

  /* 4. Changed opacity -> not skippable (fade). */
  overlay_id_t o4 = {0,0,0,0};
  hud(&o4, A, 8, 255, WHITE, 0); overlay_id_next(&o4);
  hud(&o4, A, 8, 200, WHITE, 0);
  assert(!overlay_id_skippable(&o4));

  /* 5. Changed source pointer -> not skippable. */
  overlay_id_t o5 = {0,0,0,0};
  hud(&o5, A, 8, 255, WHITE, 0); overlay_id_next(&o5);
  hud(&o5, B, 8, 255, WHITE, 0);
  assert(!overlay_id_skippable(&o5));

  /* 6. Changed color modulation -> not skippable. */
  overlay_id_t o6 = {0,0,0,0};
  hud(&o6, A, 8, 255, WHITE, 0); overlay_id_next(&o6);
  hud(&o6, A, 8, 255, 0xff0000ffu, 0);
  assert(!overlay_id_skippable(&o6));

  /* 7. Empty frame (no draws) -> not skippable (had_draw=0), even vs empty. */
  overlay_id_t o7 = {0,0,0,0};
  assert(!overlay_id_skippable(&o7));
  overlay_id_next(&o7);
  assert(!overlay_id_skippable(&o7));

  /* 8. Multi-draw order sensitivity: same set, different order -> different
   *    digest -> not skippable (a reordered z-stack is a real change). */
  overlay_id_t o8 = {0,0,0,0};
  hud(&o8, A, 8, 255, WHITE, 0); hud(&o8, B, 20, 255, WHITE, 0); overlay_id_next(&o8);
  hud(&o8, B, 20, 255, WHITE, 0); hud(&o8, A, 8, 255, WHITE, 0);
  assert(!overlay_id_skippable(&o8));

  printf("overlay_id_test: all 8 passed\n");
  return 0;
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cc -Wall -Wextra -O2 tests/overlay_id_test.c -o /tmp/overlay_id_test && /tmp/overlay_id_test`
Expected: **compile FAILS** — `fatal error: '../patches/mister/mister_overlay_id.h' file not found` (header not created yet).

- [ ] **Step 3: Write the implementation**

Create `patches/mister/mister_overlay_id.h`:

```c
/*
 * [Stage 5 A9] Overlay content-identity unit — pure, header-only, C-compatible.
 *
 * The renderer re-converts + re-uploads the whole 320x240 root/overlay surface
 * to ARGB4444 every frame because MainLoop::draw() clears+repaints the root each
 * frame (so it is always in dirty_src). But the RESULT is usually pixel-identical
 * frame to frame (static HUD over transparent). This unit lets the renderer detect
 * that cheaply — WITHOUT hashing 153 KB of pixels — by hashing the sequence of
 * draw OPERATIONS into the root plus a per-frame source-mutation flag:
 *
 *   skippable == the same ordered draw ops, with the same params, AND no source
 *                surface was itself rewritten this frame.
 *
 * "no source rewritten this frame" is the stale-HUD guard: a HUD element whose
 * VALUE changed is re-rendered into its source surface (same op-params, new
 * pixels); the renderer flags that via src_written_this_frame so we do NOT skip.
 *
 * Cost: a handful of 64-bit folds per frame (a few HUD ops), not a pixel hash.
 */
#ifndef MISTER_OVERLAY_ID_H
#define MISTER_OVERLAY_ID_H

#include <stdint.h>

typedef struct {
  unsigned long long digest;   /* rolling hash of THIS frame's root draw ops    */
  unsigned long long prev;     /* last frame's digest                            */
  int src_mutated;             /* any root-draw src rewritten this frame -> 1    */
  int had_draw;                /* at least one root draw folded this frame -> 1  */
} overlay_id_t;

/* Fold one root-targeted draw. Geometry in pixels; rot_milli/sx_milli/sy_milli =
 * rotation(rad)*1000 and scale.x/y*1000 (ints so the hash is exact); color_rgba =
 * the packed modulation color; src_written_this_frame = 1 iff `src` was itself a
 * draw/clear/fill destination earlier THIS frame. */
static inline void overlay_id_fold(overlay_id_t* o, const void* src,
    int sx, int sy, int sw, int sh, int dx, int dy, int dw, int dh,
    int blend, int opacity, int rot_milli, int sx_milli, int sy_milli,
    unsigned color_rgba, int src_written_this_frame) {
  unsigned long long k = (unsigned long long)(uintptr_t)src * 1099511628211ull;
  k ^= ((unsigned long long)(sx & 0xffff))       | ((unsigned long long)(sy & 0xffff) << 16)
     | ((unsigned long long)(sw & 0xffff) << 32)  | ((unsigned long long)(sh & 0xffff) << 48);
  k ^= ((unsigned long long)(dx & 0xffff) * 2654435761ull)
     ^ ((unsigned long long)(dy & 0xffff) * 40503ull)
     ^ ((unsigned long long)(dw & 0xffff) * 2246822519ull)
     ^ ((unsigned long long)(dh & 0xffff) * 3266489917ull)
     ^ ((unsigned long long)(blend & 0xff) * 668265263ull)
     ^ ((unsigned long long)(opacity & 0xff) * 374761393ull)
     ^ ((unsigned long long)(rot_milli & 0xffff) * 2147483647ull)
     ^ ((unsigned long long)(sx_milli & 0xffff) * 40499ull)
     ^ ((unsigned long long)(sy_milli & 0xffff) * 65537ull)
     ^ ((unsigned long long)color_rgba * 2166136261ull);
  o->digest = o->digest * 1000003ull ^ k;   /* order-sensitive rolling hash */
  o->had_draw = 1;
  if (src_written_this_frame) o->src_mutated = 1;
}

/* Skip the reconvert+reupload iff the frame had draws, its op-digest equals last
 * frame's, and no source was rewritten this frame. Conservative: the FIRST of a
 * run of identical frames never matches (prev seeded from the prior frame), and
 * any mutation or geometry/opacity/blend/color change forces a non-skip. */
static inline int overlay_id_skippable(const overlay_id_t* o) {
  return o->had_draw && o->digest == o->prev && !o->src_mutated;
}

/* Advance to the next frame. Call ONCE per frame AFTER the skip decision. */
static inline void overlay_id_next(overlay_id_t* o) {
  o->prev = o->digest; o->digest = 0; o->src_mutated = 0; o->had_draw = 0;
}

#endif /* MISTER_OVERLAY_ID_H */
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cc -Wall -Wextra -O2 tests/overlay_id_test.c -o /tmp/overlay_id_test && /tmp/overlay_id_test`
Expected: `overlay_id_test: all 8 passed`, no warnings.

- [ ] **Step 5: Wire the test into the suite**

In `tests/run_tests.sh`, after the last existing test block (before any final "all passed" echo — append a new block matching the existing idiom, using `$CC`):

```bash
echo "== overlay_id (Stage 5 A9: overlay content-identity skip decision) =="
$CC -Wall -Wextra -O2 \
    tests/overlay_id_test.c \
    -o /tmp/overlay_id_test
/tmp/overlay_id_test
```

Run: `bash tests/run_tests.sh 2>&1 | tail -20`
Expected: the suite runs to the end including `overlay_id_test: all 8 passed`; no failures (`set -e` aborts on any).

- [ ] **Step 6: Commit**

```bash
git add patches/mister/mister_overlay_id.h tests/overlay_id_test.c tests/run_tests.sh
git commit -m "feat(stage5-a9): pure overlay content-identity unit + host test

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013qHAXsgJ4PZMsrSMgRFu2t"
```

---

## Task 2: Renderer integration — diagnostic + gated skip

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp`

**Interfaces:**
- Consumes: `overlay_id_t` + `overlay_id_fold/skippable/next` (Task 1); existing `upload()`/`dirty_src`/`emit_overlay_composite()`/`mark_src_dirty()`.
- Produces: env flag `SOLARUS_OVERLAYSKIP` (opt-in), `[blitter overlayid]` diag banner (per-60fr: total overlay frames, skippable frames, guard-fires), and the skip behaviour behind the flag.

Each step is one anchored edit. All new code paths are gated so `!diag && !overlayskip_on` ⇒ byte-for-byte prior behaviour.

- [ ] **Step 1: Confirm the file is a whole-file copy (not in the series)**

Run: `grep -l mister_blitter_renderer patches/series/0001*.patch; echo "exit=$?"`
Expected: no path printed (grep exit 1) — edit the file directly.

- [ ] **Step 2: Include the header**

Anchor — the existing include of the lua-prof header near the top includes:
```cpp
#include "mister_lua_prof.h"
```
Add immediately after it:
```cpp
#include "mister_overlay_id.h"       // [Stage 5 A9] overlay content-identity skip
```

- [ ] **Step 3: Add members**

Anchor — the `overlay_touched` declaration at `:628`:
```cpp
  bool overlay_touched = false;   // root was painted this frame -> composite it
```
Add immediately after it:
```cpp
  // [Stage 5 A9 overlay-skip] Skip the redundant per-frame root ARGB4444 reconvert
  // +reupload when the root's rendered content is identical to last frame. Active
  // when (diag || overlayskip_on); the SKIP is applied only when overlayskip_on.
  bool overlayskip_on = false;                       // SOLARUS_OVERLAYSKIP (opt-in)
  overlay_id_t ovl_id = {0,0,0,0};                   // rolling op-param identity
  std::unordered_set<const SurfaceImpl*> written_this_frame;  // per-frame dst mutations
  long g_ovl_total = 0, g_ovl_skip = 0, g_ovl_guard = 0;      // [blitter overlayid] diag
```

- [ ] **Step 4: Parse the flag in the ctor**

Anchor — the `gridov` opt-in parse at `:2435`:
```cpp
  self->d->gridov = (std::getenv("SOLARUS_GRIDOV") != nullptr);
```
Add immediately after it:
```cpp
  // [Stage 5 A9] opt-in lever, NOT a validated default -> getenv-presence like gridov.
  self->d->overlayskip_on = (std::getenv("SOLARUS_OVERLAYSKIP") != nullptr);
  if (self->d->overlayskip_on)
    std::fprintf(stderr, "[MiSTer blitter] overlay content-identity skip ENABLED\n");
```

- [ ] **Step 5: Track per-frame source mutations in `mark_src_dirty`**

Anchor — `mark_src_dirty` at `:1085`:
```cpp
  void mark_src_dirty(const SurfaceImpl* p) { if (p && !is_immutable(p)) dirty_src.insert(p); }
```
Replace with:
```cpp
  void mark_src_dirty(const SurfaceImpl* p) {
    if (p && !is_immutable(p)) {
      dirty_src.insert(p);
      // [overlay-skip] per-FRAME mutation set (dirty_src is persistent, unusable as
      // a per-frame signal). Only populated when the identity path is active.
      if (overlayskip_on || diag) written_this_frame.insert(p);
    }
  }
```

- [ ] **Step 6: Fold each root draw into the digest**

Anchor — the root-draw path at `:2746-2749`:
```cpp
    SDLRenderer::draw(dst, src, infos);
    d->mark_src_dirty(&dst);      // root pixels changed -> refresh its upload
    d->overlay_touched = true;
    if (d->diag) d->g_overlay_draws++;
```
Replace with (insert the fold between `overlay_touched = true;` and the diag counter):
```cpp
    SDLRenderer::draw(dst, src, infos);
    d->mark_src_dirty(&dst);      // root pixels changed -> refresh its upload
    d->overlay_touched = true;
    if (d->overlayskip_on || d->diag) {
      const Rectangle& sr = infos.region;          // src sub-rect (see :2130)
      Rectangle dr = infos.dst_rectangle();         // dst rect
      uint8_t cr, cg, cb, ca; infos.color.get_components(cr, cg, cb, ca);
      unsigned col = ((unsigned)cr << 24) | ((unsigned)cg << 16) | ((unsigned)cb << 8) | ca;
      overlay_id_fold(&d->ovl_id, (const void*)&src,
          sr.get_x(), sr.get_y(), sr.get_width(), sr.get_height(),
          dr.get_x(), dr.get_y(), dr.get_width(), dr.get_height(),
          (int)infos.blend_mode, (int)infos.opacity,
          (int)(infos.rotation * 1000.f), (int)(infos.scale.x * 1000.f),
          (int)(infos.scale.y * 1000.f), col,
          d->written_this_frame.count(&src) ? 1 : 0);
    }
    if (d->diag) d->g_overlay_draws++;
```

- [ ] **Step 7: Apply the skip + diag counting in `emit_overlay_composite`**

Anchor — the upload call in `emit_overlay_composite()` at `:1456`:
```cpp
    if (root->get_width() != FB_W || root->get_height() != FB_H) return;
    blt_surface_ref_t ref = upload(*root, BLT_FMT_ARGB4444);
```
Replace with:
```cpp
    if (root->get_width() != FB_W || root->get_height() != FB_H) return;
    // [Stage 5 A9 overlay-skip] If the root's op-digest matches last frame and no
    // source was rewritten this frame, the ARGB4444 result is identical to the
    // cached upload -> drop the root from dirty_src so upload() returns the cached
    // ref WITHOUT reconverting (the ~6ms saving). The blit below is STILL emitted,
    // so the overlay is unchanged on screen. Only when a cached upload exists.
    if (diag || overlayskip_on) {
      g_ovl_total++;
      bool digest_match = ovl_id.had_draw && ovl_id.digest == ovl_id.prev;
      bool skip = digest_match && !ovl_id.src_mutated;
      if (digest_match && ovl_id.src_mutated) g_ovl_guard++;   // matched-but-guarded
      if (skip) g_ovl_skip++;
      if (skip && overlayskip_on && handles.count(SurfKey{root, BLT_FMT_ARGB4444}))
        dirty_src.erase(root);   // upload() cache-hit now returns without reconvert
    }
    blt_surface_ref_t ref = upload(*root, BLT_FMT_ARGB4444);
```

> Note the `handles` key type: confirm the exact key struct used by `upload()` (`SurfKey{&src, fmt}` at `:1817`) and match it; if the field names differ, use the same aggregate the code uses at `:1817`.

- [ ] **Step 8: Advance the per-frame identity + reset the mutation set**

Anchor — the per-frame overlay reset at `:3971`:
```cpp
  d->overlay_touched = false;   // [Stage 1] re-armed by next frame's root draws
```
Add immediately after it:
```cpp
  if (d->overlayskip_on || d->diag) {   // advance AFTER the composite/skip decision
    overlay_id_next(&d->ovl_id);
    d->written_this_frame.clear();
  }
```

- [ ] **Step 9: Emit the `[blitter overlayid]` banner**

Anchor — the `[blitter a9split]` banner emit at `:3649-3651`:
```cpp
        std::fprintf(stderr,
          "[blitter a9split] /60fr: A9=%.1fms = lua=%.1fms + emit=%.1fms + present=%.1fms\n",
          a9_ms, lua_ms, emit_ms, presov_ms);
```
Add immediately after it:
```cpp
        // [Stage 5 A9 overlay-skip] How many overlay frames were content-identical
        // (skippable), and how many matched op-digest but were correctly GUARDED as
        // changed because a source was rewritten (proves the stale-HUD guard fires).
        {
          long ot = g_ovl_total - d->t_ovl_total_prev;
          long os = g_ovl_skip  - d->t_ovl_skip_prev;
          long og = g_ovl_guard - d->t_ovl_guard_prev;
          d->t_ovl_total_prev = g_ovl_total; d->t_ovl_skip_prev = g_ovl_skip;
          d->t_ovl_guard_prev = g_ovl_guard;
          std::fprintf(stderr,
            "[blitter overlayid] /60fr: overlay_frames=%ld skippable=%ld guard_fires=%ld | mode=%s\n",
            ot, os, og, d->overlayskip_on ? "SKIP" : "measure");
        }
```
Then add the three window-snapshot fields to the diag-state struct alongside the other `t_*_prev` members (search for `t_lua_vm_prev` near `:912` and add beside it):
```cpp
  long t_ovl_total_prev = 0, t_ovl_skip_prev = 0, t_ovl_guard_prev = 0;  // [overlayid]
```

- [ ] **Step 10: Type-check**

Run:
```bash
g++ -fsyntax-only -std=c++17 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO \
  -I patches/mister -I patches/mister/blitter -I work/solarus/include \
  -I build/armhf/include -I work/solarus/libraries/win32/mingw32/include \
  $(sdl2-config --cflags) patches/mister/mister_blitter_renderer.cpp
```
Expected: exit 0, no errors. (If `work/solarus/include` is absent in this worktree, run after a first `scripts/build_engine.sh` checkout, or on the build host — the two `-D` flags are mandatory or almost nothing is checked, CLAUDE.md.)

- [ ] **Step 11: armhf build**

Run: `bash scripts/build_engine.sh 2>&1 | tail -20`
Expected: builds `build/armhf/solarus-run` + `libsolarus.so.1.6.5` with no errors. Confirm the new banner string is present: `grep -qa "blitter overlayid" build/armhf/libsolarus.so.1.6.5 && echo ok`.

- [ ] **Step 12: Host suite still green (no-op regression)**

Run: `bash tests/run_tests.sh 2>&1 | tail -5`
Expected: full suite passes (Task 1's `overlay_id_test` included).

- [ ] **Step 13: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "feat(stage5-a9): overlay content-identity skip (gated SOLARUS_OVERLAYSKIP) + [blitter overlayid] diag

Fold root draw ops into an op-param digest + per-frame source-mutation guard;
skip the redundant ARGB4444 reconvert/reupload when the overlay is unchanged
(blit still emitted). Default-off opt-in; diag banner measures skip-rate and
guard-fires. No-op when the flag+diag are both off.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013qHAXsgJ4PZMsrSMgRFu2t"
```

---

## Task 3: HW validation (device) — precheck, A/B, operator gate

> Runs on hardware; needs exclusive device time (coordinate with the FPGA-track agent). Deploy the Task-2 engine first. No RBF change.

**Files:**
- Create: `docs/superpowers/2026-07-22-stage5-a9-overlay-skip-hw-validation.md`

- [ ] **Step 1: Deploy + verify**

Run: `./deploy.py --no-rbf` then
`ssh root@192.168.20.81 'sha1sum /media/fat/games/solarus/libs/libsolarus.so.1.6.5; grep -qa "blitter overlayid" /media/fat/games/solarus/libs/libsolarus.so.1.6.5 && echo BANNER-OK'`
Expected: sha1 matches the just-built `.so`; `BANNER-OK`.

- [ ] **Step 2: Correctness precheck — diag, flag OFF (no behaviour change yet)**

With `SOLARUS_BLITTER_DIAG=1` and **SOLARUS_OVERLAYSKIP unset**, capture map 119 + map 3 (the skip is inert, so this is safe — it only MEASURES). Reuse the harness:
```bash
MAP=119 DEST=from_dungeon_10 TAG=ovlmeas-map119 bash scripts/perf/capture_a9_drill.sh
```
Then, on the live engine via the FIFO, trigger real HUD changes and watch `[blitter overlayid]`:
- standing idle → expect `skippable` ≈ most `overlay_frames` (the win exists), `guard_fires` low.
- take damage / spend a rupee / open a dialog / open the pause menu → expect `guard_fires > 0` and `skippable` drops on those frames (**proves the stale-HUD guard catches value changes**).
Record the `[blitter overlayid]` lines for each state. **Gate:** if `skippable` is near-zero standing, the lever won't help — STOP and re-scope (the identity signal is too strict; investigate which op param varies via a temporary per-field log). If a HUD change does NOT raise `guard_fires`/drop `skippable`, the guard is unsafe — STOP and fix before enabling the skip.

- [ ] **Step 3: A/B the skip — flag OFF vs ON**

Capture both legs at both spots, standing + moving:
```bash
                       MAP=119 DEST=from_dungeon_10 TAG=ovloff-map119 bash scripts/perf/capture_a9_drill.sh
SOLARUS_OVERLAYSKIP=1  MAP=119 DEST=from_dungeon_10 TAG=ovlon-map119  bash scripts/perf/capture_a9_drill.sh
                       MAP=3   DEST=out_link_house  TAG=ovloff-map3   bash scripts/perf/capture_a9_drill.sh
SOLARUS_OVERLAYSKIP=1  MAP=3   DEST=out_link_house  TAG=ovlon-map3    bash scripts/perf/capture_a9_drill.sh
```
> `capture_a9_drill.sh` sets the engine env via `stage5_device_launch.sh`; pass `SOLARUS_OVERLAYSKIP=1` so the launch inherits it (confirm the launch script forwards env — if not, edit the launched `_a9_launch.sh` copy to export it, or set it in the on-device launch command). Decompose each with `a9_decompose.py` (split per state).
Expected (per the decision doc, **upper bounds**): flag-ON `present` drops toward ~1 ms on static-HUD frames; A9 falls ~4–6 ms standing / ~4.5 ms moving; map 3 moving fps ~27 → ~29. `[blitter overlayid] mode=SKIP` shows `skippable` frames actually skipped. **Regression guard:** flag-OFF reproduces the Task-4 baseline present (~6–7.7 ms).

- [ ] **Step 4: Operator visual gate (stale-HUD — never self-declared)**

Ask the operator to play with `SOLARUS_OVERLAYSKIP=1` and confirm, on the enlarged/ship RBF, that the HUD/UI stay **live**: hearts update on damage, rupee/magic counters update on change, dialogs and the pause menu open/animate correctly, map transitions and fades render, and no HUD element freezes or shows a stale value. This is the pass/fail gate for shipping the flag on.

- [ ] **Step 5: Write the validation doc + ship recommendation**

Create `docs/superpowers/2026-07-22-stage5-a9-overlay-skip-hw-validation.md` with: the precheck `[blitter overlayid]` skip-rate + guard-fires table (per state + per HUD event), the A/B present/A9/fps deltas (both maps, both states), the operator verdict, and a **ship-default recommendation** (keep opt-in vs flip default-on) — flip default-on ONLY if the operator gate passes clean AND the A/B shows a real win with no regression, mirroring how prior levers were promoted. Commit:
```bash
git add docs/superpowers/2026-07-22-stage5-a9-overlay-skip-hw-validation.md docs/superpowers/data/stage5-a9/
git commit -m "validate(stage5-a9): overlay-skip HW A/B + operator gate

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013qHAXsgJ4PZMsrSMgRFu2t"
```

---

## Self-Review

**Spec coverage** (decision doc "The ONE lever (scoped) — corrected"):
- Cheap op-param digest, NOT a pixel hash → Task 1 (`overlay_id_fold` folds op params only) ✓
- Mutated-source guard (trap #1) → per-frame `written_this_frame` set (NOT persistent `dirty_src`), folded via `src_written_this_frame`; test #2 covers it; Task-3 Step-2 proves it on HW ✓
- "cached blit must still be emitted; only convert+upload skipped" (trap #2) → Task 2 Step 7 erases root from `dirty_src` before `upload()` but leaves the `blt_blit` emit intact ✓
- Self-validating A/B (trap #3) → Task 3 Step 3 + the `[blitter overlayid]` skip counter ✓
- Diag-tax note (ps_frame_end) → the precheck reads present under diag on both legs, so it cancels in the A/B; noted in the validation doc ✓
- Gated `SOLARUS_OVERLAYSKIP` default-off, `=0`=no-op → Task 2 Steps 4/7, getenv-presence like gridov; all new paths gated on `overlayskip_on || diag` and the skip on `overlayskip_on` ✓
- Renderer-side whole-file edit, no series change → Task 2 Step 1 verifies ✓
- HW A/B at `from_dungeon_10` / `out_link_house`, operator gate → Task 3 ✓
- Fps projections are UPPER BOUNDS (moving carries a non-recoverable term) → stated in Task 3 Step 3 ✓

**Placeholder scan:** all code (header, test, renderer edits) is complete and anchored to exact existing lines. The two "confirm the exact accessor/key" notes (Step 7 `SurfKey`, Step 6 `infos.region`) cite the exact source line the pattern is copied from (`:1817`, `:2130`) — not open-ended TODOs. Task 3's `<paste>`-style values live only in the validation doc produced from real HW output, which is the correct place for measured numbers.

**Type/name consistency:** `overlay_id_t` + `overlay_id_fold/skippable/next` signatures match between the header, the test, and the renderer calls; `written_this_frame`/`ovl_id`/`overlayskip_on`/`g_ovl_*`/`t_ovl_*_prev` are declared (Steps 3, 9) before use (Steps 5–9); the `overlay_id_fold` arg list in Task-2 Step 6 matches Task-1's 17-arg signature (src, sx,sy,sw,sh, dx,dy,dw,dh, blend,opacity, rot,sx,sy milli, color, mutated).
```
