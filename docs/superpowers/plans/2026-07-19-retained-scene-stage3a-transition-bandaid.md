# Stage 3a — Remove the `g_transition_scroll` Bandaid: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Composite a scrolling map transition on the FPGA fabric instead of falling back to a full software map render, and delete the `g_transition_scroll` bandaid — giving #122 and #123 their first deliberate measurement.

**Architecture:** During a scrolling transition Solarus draws two full-screen blits onto the root: the OLD map (`previous_map_surface`) and the NEW map (the camera surface), each at an animating offset. Today `g_transition_scroll` disables the camera alias for the duration, so the whole new map re-composites in software and both blits land in the Stage 1 overlay. Instead we publish the scroll offsets from **engine truth** (before the map draws), point the camera alias at the scrolled offset so camera draws composite on-fabric at the right place, and emit the old map as a normal fabric blit whose source stays resident in the `handles` cache. **No RTL change** — per-batch signed dst bias already exists and is plumbed end to end.

**Tech Stack:** C++17 (`patches/mister/mister_blitter_renderer.cpp`, a whole-file copy — edit directly, NOT in the patch series), the `git-am` patch series (`patches/series/*.patch`) for engine-side seams, host unit tests under `patches/mister/` built by `build_host_tests.sh`, armhf cross-build in Docker, MiSTer hardware at `192.168.20.81`.

## Global Constraints

- **`mister_blitter_renderer.{cpp,h}` and `patches/mister/blitter/` are WHOLE-FILE COPIES, not in the patch series.** Edit them directly; there is nothing to regenerate. Engine-side changes (`work/solarus/src/...`) DO go in `patches/series/*.patch`.
- **Do NOT edit `patches/mister/blitter/*`** in this plan. Those files are re-synced from the upstream `mister-fpga-blitter` repo; changing them here creates a divergence. Every change in this plan lives in the renderer or the series.
- **No RTL changes.** If a task appears to need one, STOP and escalate — the design's central claim is that dst bias already exists (`blitter_top.sv:395`, `:729-730`, `:755-756`, `:793-794`).
- **Build inside the container**, and do not trust the task exit code (a wrapper's `tail` can mask a failure). `BUILD_EXIT` is NOT emitted by any script — the CALLER must emit it, which is the half an earlier draft of this plan dropped. Use exactly:
  ```bash
  scripts/docker_run.sh bash -c 'bash scripts/build_engine.sh; echo "BUILD_EXIT=$?"' 2>&1 | tee /tmp/build.log
  grep BUILD_EXIT /tmp/build.log
  ```
  Building on the host creates a host-path `CMakeCache.txt` that then blocks the container build.
- **Engine-side patches: use `scripts/export_patches.sh`, never a hand-rolled `git add -A` + `format-patch`.** `work/solarus` contains the renderer whole-file copy as a TRACKED, MODIFIED file, so `git add -A` there silently bakes the renderer diff into the series patch. Verify with `scripts/tests/test_export_roundtrip.sh`.
- **Native type-check without Docker** (fast inner loop): the `g++ -fsyntax-only` recipe in `CLAUDE.md`.
- **New behavior ships behind `SOLARUS_SCROLLFAB`, default OFF.** The hardware A/B in Task 8 requires toggling it. Do not make it default-ON in this plan.
- **Do not delete `g_transition_scroll` in this plan.** It remains the flag-OFF path so the A/B has a baseline. Deletion happens after Task 8 validates.
- **Never self-declare visual correctness.** Task 8 is gated on the operator's eyes plus objective counters.
- Commit messages end with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01YTKoioGE2kBeHM8Gdp2ppe`

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `patches/mister/mister_blitter_renderer.cpp` | comment fix, heap peak tracker, `SOLARUS_SCROLLFAB` gate, scrolled alias offset, old-map fabric blit | 1, 2, 4, 5, 6 |
| `patches/series/0044-feat-render-publish-scroll-transition-offsets.patch` | engine seam: publish scroll offsets + tag previous-map surface | 3 |
| `work/solarus/include/solarus/graphics/Transition.h` (via series) | virtual scroll-offset accessor, default {0,0} | 3 |
| `work/solarus/src/graphics/TransitionScrolling.cpp` (via series) | override returning engine-truth offsets | 3 |
| `work/solarus/src/core/Game.cpp` (via series) | extended `mister_set_transition` call | 3 |
| `patches/mister/test_scrollalias.cpp` | host test: scrolled-alias offset + old-map emit | 7 |
| `patches/mister/build_test_scrollalias.sh` | build/run script for the above | 7 |
| `patches/mister/build_host_tests.sh` | register the new test | 7 |

---

## Background an implementer needs

**What `g_transition_scroll` does today.** Set in `mister_blitter_renderer.cpp:229-231` from `Game::draw`. While true it gates six sites — alias adoption (`:2708`), promote-skip (`:2737`), promote-lock (`:2758`), case-2 alias composite (`:2807`), alias re-adopt in `resident_begin_frame` (`:2863`), and the resident tile-list fast path (`:2872`) — plus the `clear()` backed-surface test (`:2594`) and the `emit_draw` alias test (`:2617`).

Net effect: `alias_target` is never adopted during a scroll, so case-2 camera draws fall through to `SDLRenderer::draw` (software), and the two root blits go to the Stage 1 overlay channel (base SDL into the root, one ARGB4444 upload composited last).

**Why the comment is wrong.** It cites a per-edge heap reset that was deleted in commit `4f91c1b`. `heap_reset_pending`, `was_in_transition`, `did_reset_last` have zero occurrences. See the design doc §1.2.

**The exact engine seam.** `TransitionScrolling::draw` (`work/solarus/src/graphics/TransitionScrolling.cpp:218-228`) issues exactly two draws onto the root:

```cpp
  // draw the old map
  infos.proxy.draw(dst_surface,*previous_surface,
                   DrawInfos(infos, Rectangle(Point(),previous_surface->get_size()),
                             previous_map_dst_position.get_xy()-current_scrolling_position.get_xy()));
  // draw the new map
  infos.proxy.draw(dst_surface,src_surface,
                   DrawInfos(infos, Rectangle(Point(),src_surface.get_size()),
                             current_map_dst_position.get_xy()-current_scrolling_position.get_xy()));
```

`src_surface` for the new map **is** the camera surface — i.e. `g_tagged_camera`.

**The ordering problem this plan solves.** Those two root blits arrive *after* the camera's own per-sprite draws in the same frame. So we cannot learn this frame's scroll offset from the promote blit and still use it for the camera draws that already happened. Hence Task 3: publish the offsets from engine truth in `Game::draw`, which runs at `Game.cpp:616` **before** `current_map->draw()` at `:642`. `Transition::update()` has already advanced `current_scrolling_position` by then.

---

### Task 1: Correct the stale bandaid comment

Standalone and risk-free. Do it first so the rest of the work is read against an accurate comment.

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp:209-231`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing. Comment-only.

- [ ] **Step 1: Replace the comment block**

Replace lines 209-231 (from `// [MiSTer #24] Map-to-map transition tracking` through the closing `}` of `mister_set_transition`) with:

```cpp
// [MiSTer #24] Map-to-map transition tracking (set each frame from Game::draw).
// TransitionScrolling blits the OLD (previous_map_surface) and NEW (camera surface)
// maps onto the root at animating scroll offsets. Our alias optimization composites
// the new map's content straight into DDR at (0,0), leaving the camera SURFACE's own
// pixels empty -- so with the alias on, the new map has nothing to scroll in (only the
// old map scrolls away). Disabling the alias for the duration is the bandaid: it
// forces the whole map to re-composite in SOFTWARE through SDL, and routes both root
// blits into the Stage 1 overlay channel.
//
// [2026-07-19] A SECOND justification used to live here -- "the two maps' atlases
// co-resident overflow the heap (black flicker)", i.e. #123 -- describing a per-edge
// heap reset. That reset was DELETED in commit 4f91c1b ("drop scene_too_big +
// heap-reset/transition-reclaim"); the deletion was pre-planned in
// plans/2026-07-06-sdram-asset-residency.md:631, which also said to remove "their
// explanatory comment block". The code went, the comment did not, and two stages of
// planning then treated a dead constraint as live. Removed here. There is no
// heap_reset_pending / was_in_transition / did_reset_last in this file. The premise is
// independently gone too: tileset atlases resolve to PERM SDRAM (see res_bucket_params
// / upload()), and the DDR heap grew 4 -> 16 MiB (#14).
//
// [const-alpha fill / transition scope] The alias-disable is needed ONLY for SCROLLING
// -- the one transition with two maps co-resident and a non-(0,0) blit. FADE and
// IMMEDIATE draw a SINGLE map at its normal (0,0) position, so the alias is valid for
// them; disabling it forced a software re-composite for the fade's duration for no
// benefit. So gate on g_transition_scroll (= active && needs_previous_surface()), true
// only for TransitionScrolling.
//
// [Stage 3a / SOLARUS_SCROLLFAB] The bandaid is being removed: with the flag ON we
// publish the scroll offsets from engine truth (mister_set_transition below) and
// composite BOTH maps on the fabric at their offsets. g_transition_scroll stays as the
// flag-OFF baseline so the two paths can be A/B'd on hardware; delete it once that
// validates.
static bool g_transition_scroll = false;  // scrolling transition (alias-disable)
void mister_set_transition(bool active, bool needs_prev) {
  g_transition_scroll = active && needs_prev;   // only TransitionScrolling needs_previous_surface()
}
```

- [ ] **Step 2: Verify it still compiles**

Run:
```bash
g++ -fsyntax-only -std=c++17 -I patches/mister -I patches/mister/blitter \
  -I work/solarus/include -I build/armhf/include \
  -I work/solarus/libraries/win32/mingw32/include $(sdl2-config --cflags) \
  patches/mister/mister_blitter_renderer.cpp
```
Expected: no output, exit 0.

- [ ] **Step 3: Confirm the claim in the comment is still true**

Run:
```bash
grep -c "heap_reset_pending\|was_in_transition\|did_reset_last" patches/mister/mister_blitter_renderer.cpp
git log --oneline -1 4f91c1b
```
Expected: `0`, then a line reading `4f91c1b refactor(renderer): drop scene_too_big + heap-reset/transition-reclaim (residency); keep escape/too_big fallbacks`.

If the grep is non-zero, STOP — the design's §1.2 premise is wrong and the plan needs revisiting.

- [ ] **Step 4: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "docs(renderer): correct g_transition_scroll's dead-code justification

The heap-reset it described was deleted in 4f91c1b; the comment survived
and two stages of planning treated the constraint as live.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YTKoioGE2kBeHM8Gdp2ppe"
```

---

### Task 2: DDR-heap high-water tracker

There is currently **no** way to observe DDR-heap pressure: `em.heap_used` is instantaneous, never reset per frame, with no peak tracker and no assert. The `[blitter inter]` line reads a *different region* (SDRAM INTER arena). Task 8's A/B needs this signal to say anything about #123's heap premise.

Tracked in the renderer, NOT in `blt_emitter` — that directory is re-synced from upstream (see Global Constraints).

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` (Impl member near the other `g_*` diag counters; sample site in `present()`; print site at `:4218-4233`)

**Interfaces:**
- Consumes: `d->em.heap_used`, `d->em.heap_cap` (existing `blt_emitter` fields, `blt_emitter.h:40-41`).
- Produces: `size_t heap_peak` on the renderer Impl, printed as `heap_peak=` in the `[blitter]` banner.

- [ ] **Step 1: Add the member**

In the `Impl` class, immediately after the existing `g_dropped_win` declaration (find it with `grep -n "g_dropped_win" patches/mister/mister_blitter_renderer.cpp` and add below the declaration, not the uses), add:

```cpp
  // [Stage 3a] DDR heap HIGH-WATER. em.heap_used is instantaneous and the heap is
  // never reset per frame, so a transient spike (e.g. two maps' sources co-resident
  // across a scroll edge) is invisible in a 60-frame diag sample. This is the ONLY
  // signal that can confirm or refute #123's heap premise -- note the [blitter inter]
  // line reads the SDRAM INTER arena, a DIFFERENT region, and cannot.
  size_t heap_peak = 0;
```

- [ ] **Step 2: Sample it every frame**

In `present()`, find the existing per-frame diag block. Sample **unconditionally** (not under `if (d->diag)`) so the peak is correct even if diag is enabled partway through a session — it is a single compare-and-store:

```cpp
  if (d->em.heap_used > d->heap_peak) d->heap_peak = d->em.heap_used;
```

Place it immediately before the `if (d->diag)` block that emits the `[blt f%02d]` per-frame line (find with `grep -n '\[blt f%02d\]' patches/mister/mister_blitter_renderer.cpp`).

- [ ] **Step 3: Print it**

At `:4218`, change the format string fragment:

```cpp
        "heap=%zu/%zu overflow=%d target_locked=%d alias_locked=%d "
```
to:
```cpp
        "heap=%zu/%zu heap_peak=%zu overflow=%d target_locked=%d alias_locked=%d "
```

and in the argument list at `:4227`, change:

```cpp
        d->em.cmd_count, d->em.heap_used, d->em.heap_cap, d->em.overflow,
```
to:
```cpp
        d->em.cmd_count, d->em.heap_used, d->em.heap_cap, d->heap_peak, d->em.overflow,
```

- [ ] **Step 4: Verify the format string and arguments still line up**

`printf` argument mismatches are silent at runtime and catastrophic in a diag path. Run:

```bash
g++ -fsyntax-only -std=c++17 -Wall -Wformat=2 -I patches/mister -I patches/mister/blitter \
  -I work/solarus/include -I build/armhf/include \
  -I work/solarus/libraries/win32/mingw32/include $(sdl2-config --cflags) \
  patches/mister/mister_blitter_renderer.cpp 2>&1 | grep -i "format" || echo "no format warnings"
```
Expected: `no format warnings`.

- [ ] **Step 5: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "feat(diag): track DDR heap high-water mark

em.heap_used is instantaneous and never reset per frame, so transient
spikes were invisible. This is the only signal that can speak to #123's
heap premise -- [blitter inter] reads the SDRAM INTER arena, not this.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YTKoioGE2kBeHM8Gdp2ppe"
```

---

### Task 3: Publish scroll offsets and the previous-map surface from engine truth

The renderer cannot derive this frame's scroll offset in time (see Background). Publish it from `Game::draw`, which runs before the map draws.

This is an **engine-side** change and therefore goes in the patch series, applied to pristine upstream. Follow the existing pattern in `patches/series/0004-fix-render-camera-tag-transition-hook-publish-camera.patch`.

**Files:**
- Create: `patches/series/0044-feat-render-publish-scroll-transition-offsets.patch`
- Which modifies: `work/solarus/include/solarus/graphics/Transition.h`, `work/solarus/src/graphics/TransitionScrolling.cpp`, `work/solarus/include/solarus/graphics/TransitionScrolling.h`, `work/solarus/src/core/Game.cpp`
- Modify: `patches/mister/mister_blitter_renderer.cpp` (new hook definitions)

**Interfaces:**
- Consumes: `Transition::get_previous_surface()`, `TransitionScrolling::current_map_dst_position`, `::previous_map_dst_position`, `::current_scrolling_position` (private members, `TransitionScrolling.h:63-65`).
- Produces, for Tasks 4-6:
  - `void mister_set_transition(bool active, bool needs_prev, int new_dx, int new_dy, int old_dx, int old_dy)` — replaces the 2-arg form.
  - `void mister_tag_prev_map_surface(const SurfaceImpl* s)` — tags the old-map surface, mirroring `mister_tag_camera_surface`.
  - File-scope in the renderer: `static int g_scroll_new_dx, g_scroll_new_dy, g_scroll_old_dx, g_scroll_old_dy;` and `static const SurfaceImpl* g_tagged_prev_map;`

- [ ] **Step 1: Confirm the series applies cleanly before you add to it**

Run:
```bash
bash scripts/build_engine.sh --patches-only 2>&1 | tail -20 || \
  echo "NOTE: if --patches-only is unsupported, inspect scripts/build_engine.sh for its patch-apply step and run that"
```
Expected: the series applies with no rejects. If `git am` fails, apply on the **host**, not in Docker — in-Docker `git am --3way` is known flaky (memory `solarus-docker-git-am-flaky-host-patch-workaround`).

- [ ] **Step 2: Add the virtual accessor to the Transition base**

In `work/solarus/include/solarus/graphics/Transition.h`, inside the public section of `class Transition`, add:

```cpp
#ifdef MISTER_NATIVE_VIDEO
    /**
     * \brief MiSTer: destination offsets of the two maps during a scrolling
     * transition, in screen pixels. Default {0,0,0,0} for every other transition.
     * Published from Game::draw BEFORE the map is drawn, so the fabric renderer
     * knows where to composite the camera surface this frame.
     */
    virtual void get_mister_scroll_offsets(int& new_dx, int& new_dy,
                                           int& old_dx, int& old_dy) const {
      new_dx = 0; new_dy = 0; old_dx = 0; old_dy = 0;
    }
#endif
```

- [ ] **Step 3: Override it in TransitionScrolling**

In `work/solarus/include/solarus/graphics/TransitionScrolling.h`, in the public section:

```cpp
#ifdef MISTER_NATIVE_VIDEO
    void get_mister_scroll_offsets(int& new_dx, int& new_dy,
                                   int& old_dx, int& old_dy) const override;
#endif
```

In `work/solarus/src/graphics/TransitionScrolling.cpp`, at the end of the file (before the closing namespace brace), add — note these are exactly the expressions `draw()` uses at `:221-222` and `:227-228`:

```cpp
#ifdef MISTER_NATIVE_VIDEO
void TransitionScrolling::get_mister_scroll_offsets(int& new_dx, int& new_dy,
                                                    int& old_dx, int& old_dy) const {
  const Point new_p = current_map_dst_position.get_xy() - current_scrolling_position.get_xy();
  const Point old_p = previous_map_dst_position.get_xy() - current_scrolling_position.get_xy();
  new_dx = new_p.x; new_dy = new_p.y;
  old_dx = old_p.x; old_dy = old_p.y;
}
#endif
```

- [ ] **Step 4: Extend the Game::draw hook**

In `work/solarus/src/core/Game.cpp`, change the forward declaration at `:56`:

```cpp
                    void mister_set_transition(bool, bool);
```
to:
```cpp
                    void mister_set_transition(bool, bool, int, int, int, int);
                    void mister_tag_prev_map_surface(const SurfaceImpl*);
```

and replace the call at `:616-618`:

```cpp
  Solarus::mister_set_transition(transition != nullptr,
      transition != nullptr && transition->needs_previous_surface());
```
with:
```cpp
  {
    int _sdx = 0, _sdy = 0, _odx = 0, _ody = 0;
    const bool _needs_prev = transition != nullptr && transition->needs_previous_surface();
    if (_needs_prev) {
      transition->get_mister_scroll_offsets(_sdx, _sdy, _odx, _ody);
      const Surface* _prev = transition->get_previous_surface();
      Solarus::mister_tag_prev_map_surface(_prev != nullptr ? &_prev->get_impl() : nullptr);
    } else {
      Solarus::mister_tag_prev_map_surface(nullptr);
    }
    Solarus::mister_set_transition(transition != nullptr, _needs_prev, _sdx, _sdy, _odx, _ody);
  }
```

- [ ] **Step 5: Update the renderer's hook definitions**

In `patches/mister/mister_blitter_renderer.cpp`, replace the `mister_set_transition` definition written in Task 1 with:

```cpp
static bool g_transition_scroll = false;  // scrolling transition (alias-disable)
// [Stage 3a] Scroll offsets, published from ENGINE TRUTH before the map draws.
// Deriving them from the promote blit is impossible: it arrives AFTER the camera's
// own draws in the same frame, so we would be a frame late.
static int g_scroll_new_dx = 0, g_scroll_new_dy = 0;
static int g_scroll_old_dx = 0, g_scroll_old_dy = 0;
static const SurfaceImpl* g_tagged_prev_map = nullptr;

void mister_set_transition(bool active, bool needs_prev,
                           int new_dx, int new_dy, int old_dx, int old_dy) {
  g_transition_scroll = active && needs_prev;   // only TransitionScrolling needs_previous_surface()
  g_scroll_new_dx = new_dx; g_scroll_new_dy = new_dy;
  g_scroll_old_dx = old_dx; g_scroll_old_dy = old_dy;
}
void mister_tag_prev_map_surface(const SurfaceImpl* s) { g_tagged_prev_map = s; }
```

Then find the existing declaration block that declares `mister_set_transition` for export (grep for `void mister_set_transition` in the header or the extern block near the top of the file) and update its signature to match, adding `mister_tag_prev_map_surface` alongside.

Also add to the surface-invalidation site at `:2567`, next to the existing `g_tagged_camera` line:

```cpp
  if (&surf == g_tagged_prev_map) g_tagged_prev_map = nullptr;  // drop the stale tag
```

- [ ] **Step 6: Regenerate the series patch**

```bash
git -C work/solarus add -A
git -C work/solarus commit -m "feat(render): publish scroll-transition offsets + previous-map surface"
git -C work/solarus format-patch -1 -o ../../patches/series/ \
  --start-number 44 --suffix=.patch
```
Verify the file created is `patches/series/0044-feat-render-publish-scroll-transition-offsets.patch`; rename if `format-patch` chose a different slug.

- [ ] **Step 7: Verify the series round-trips**

The CI has a patch round-trip gate that breaks under `diff.algorithm=patience` — pin myers (memory `solarus-ci-patch-roundtrip-and-astgrep-config`):

```bash
git -c diff.algorithm=myers -C work/solarus format-patch -1 --stdout | \
  diff -q - patches/series/0044-feat-render-publish-scroll-transition-offsets.patch && \
  echo "round-trip OK"
```
Expected: `round-trip OK`.

- [ ] **Step 8: Full container build**

```bash
scripts/docker_run.sh bash -c 'bash scripts/build_engine.sh; echo "BUILD_EXIT=$?"' 2>&1 | tee /tmp/build3a.log
grep BUILD_EXIT /tmp/build3a.log
```
Expected: `BUILD_EXIT=0`. Do **not** trust the shell exit code — grep is the gate.

- [ ] **Step 9: Commit**

```bash
git add patches/series/0044-feat-render-publish-scroll-transition-offsets.patch \
        patches/mister/mister_blitter_renderer.cpp
git commit -m "feat(render): publish scroll-transition offsets from engine truth

The renderer cannot derive the scroll offset in time: the promote blit
arrives after the camera's own draws. Publish from Game::draw, which runs
before current_map->draw().

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YTKoioGE2kBeHM8Gdp2ppe"
```

---

### Task 4: Add the `SOLARUS_SCROLLFAB` gate and the scrolled alias offset

With the flag ON, adopt the camera alias during a scroll and point it at the engine-published offset, so case-2 camera draws composite on-fabric at the scrolled position.

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` — Impl member; init in the ctor near the other flags (`:2500`); the four `!g_transition_scroll` alias sites (`:2594`, `:2617`, `:2708`, `:2807`); and `resident_begin_frame` (`:2863`, `:2872`)

**Interfaces:**
- Consumes: `g_scroll_new_dx/dy`, `g_transition_scroll` (Task 3).
- Produces: `bool scrollfab` on Impl; helper `bool scroll_bandaid_active() const` used by every former `!g_transition_scroll` site.

- [ ] **Step 1: Add the flag and the helper**

Next to the `spritech` member declaration, add:

```cpp
  // [Stage 3a / SOLARUS_SCROLLFAB] When ON, a scrolling transition composites on the
  // FABRIC at engine-published offsets instead of falling back to a software map
  // render. g_transition_scroll stays as the flag-OFF baseline so the two can be
  // A/B'd on hardware. Default OFF until that A/B lands (#122/#123).
  bool scrollfab = false;
  // The bandaid applies only when we are mid scroll AND the fabric path is off.
  bool scroll_bandaid_active() const { return g_transition_scroll && !scrollfab; }
```

In the constructor, immediately after the `spritech` init at `:2500`:

```cpp
  self->d->scrollfab = mister_flag_default_off("SOLARUS_SCROLLFAB");
  if (self->d->scrollfab)
    std::fprintf(stderr, "[MiSTer blitter] scroll fabric path ENABLED (SOLARUS_SCROLLFAB)\n");
```

- [ ] **Step 2: Route every bandaid site through the helper**

Replace `!g_transition_scroll` with `!d->scroll_bandaid_active()` (or `!scroll_bandaid_active()` where already inside Impl) at all **eight** sites below — six alias gates plus the `clear()` and `emit_draw` tests. With the flag OFF every one of these is byte-for-byte the old behavior.

`:2594` (in `clear()`):
```cpp
                 (d->alias_target == &dst && dst.get_width() == FB_W && !d->scroll_bandaid_active()));
```

`:2617` (in `emit_draw`'s caller):
```cpp
  bool alias = !d->blitter_off() && !root && d->alias_target == &dst &&
```
— inspect the following line and replace its `!g_transition_scroll` term with `!d->scroll_bandaid_active()`.

`:2708` (alias adoption in `draw()`):
```cpp
  if (d->camera_tag && g_tagged_camera && !d->scroll_bandaid_active() && d->alias_target != g_tagged_camera) {
```

`:2737` (promote-skip):
```cpp
    if (&src == d->alias_target && d->alias_drawn_this_frame && !d->scroll_bandaid_active()) {
```

`:2758` (promote-lock):
```cpp
    if (!d->alias_target && !d->scroll_bandaid_active() && d->looks_like_promote(src, infos)) {
```

`:2807` (case-2 alias composite):
```cpp
  if (dst.get_width() == FB_W && d->alias_target == &dst && !d->scroll_bandaid_active()) {
```

`:2863` and `:2872` (in `resident_begin_frame`):
```cpp
  if (d->camera_tag && g_tagged_camera && !d->scroll_bandaid_active() &&
      d->alias_target != g_tagged_camera) {
```
```cpp
  if (!d->res_enabled || d->blitter_off() || d->scroll_bandaid_active()) {
```

- [ ] **Step 3: Drive the alias offset from the published scroll offset**

The two adoption sites currently hard-code `alias_off_x = alias_off_y = 0`. With the fabric path on during a scroll, they must carry the scroll offset instead. Replace the body at `:2709-2710`:

```cpp
    d->alias_target = g_tagged_camera;
    d->alias_off_x = 0; d->alias_off_y = 0;   // full-screen camera composites at (0,0)
```
with:
```cpp
    d->alias_target = g_tagged_camera;
    // [Stage 3a] Normally the full-screen camera composites at (0,0). During a
    // SCROLL with SOLARUS_SCROLLFAB on, the new map is drawn at an animating offset
    // published from engine truth this frame -- composite there instead. clip_to_fb
    // (emit_draw / sprite_channel_push) drops the half that is off-screen.
    if (d->scrollfab && g_transition_scroll) {
      d->alias_off_x = g_scroll_new_dx; d->alias_off_y = g_scroll_new_dy;
    } else {
      d->alias_off_x = 0; d->alias_off_y = 0;
    }
```

Apply the identical replacement at `:2865-2866` in `resident_begin_frame`.

- [ ] **Step 4: Re-adopt every frame during a scroll**

Both adoption sites are guarded by `d->alias_target != g_tagged_camera`, so once adopted they stop updating — but during a scroll the offset changes every frame. Add immediately after each of the two adoption blocks:

```cpp
  // [Stage 3a] The adoption guard above fires once; the scroll offset changes every
  // frame, so refresh it unconditionally while scrolling.
  if (d->scrollfab && g_transition_scroll && d->alias_target == g_tagged_camera) {
    d->alias_off_x = g_scroll_new_dx; d->alias_off_y = g_scroll_new_dy;
  }
```

- [ ] **Step 5: Type-check**

```bash
g++ -fsyntax-only -std=c++17 -I patches/mister -I patches/mister/blitter \
  -I work/solarus/include -I build/armhf/include \
  -I work/solarus/libraries/win32/mingw32/include $(sdl2-config --cflags) \
  patches/mister/mister_blitter_renderer.cpp
```
Expected: no output, exit 0.

- [ ] **Step 6: Verify the flag-OFF path is unchanged**

```bash
grep -c "g_transition_scroll" patches/mister/mister_blitter_renderer.cpp
```
Expected: exactly `7` — the declaration, the setter, and the five `scrollfab &&` uses in Steps 3-4. Every *gating* site must now read `scroll_bandaid_active()`. Confirm no bare `!g_transition_scroll` gate survives:

```bash
grep -n "!g_transition_scroll" patches/mister/mister_blitter_renderer.cpp || echo "none left (correct)"
```
Expected: `none left (correct)`.

- [ ] **Step 7: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "feat(render): SOLARUS_SCROLLFAB gate + scrolled alias offset

Adopts the camera alias during a scroll and points it at the engine-
published offset, so camera draws composite on-fabric at the scrolled
position. Default OFF; g_transition_scroll remains the A/B baseline.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YTKoioGE2kBeHM8Gdp2ppe"
```

---

### Task 5: Emit the old map as a fabric blit

With Task 4 the NEW map composites on-fabric. The OLD map still arrives as a root draw and would go to the Stage 1 overlay. Route it to the fabric instead: its pixels never change during the scroll, so the `handles` cache keeps the source resident after the first frame — one upload for the whole transition.

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` — case (1) in `draw()`, before the overlay routing at `:2769`

**Interfaces:**
- Consumes: `g_tagged_prev_map`, `g_scroll_old_dx/dy` (Task 3); `d->scrollfab` (Task 4); existing `d->emit_draw(src, infos, off_x, off_y)`.
- Produces: diag counter `long g_scroll_oldmap_blits = 0;` on Impl.

- [ ] **Step 1: Add the counter**

Next to `g_sprite_blits`:

```cpp
  long g_scroll_oldmap_blits = 0;   // [Stage 3a] old-map blits routed to the fabric
```

- [ ] **Step 2: Insert the old-map branch**

In `draw()`, inside case (1) (`if (d->is_fpga_target(dst))`), **after** the promote-skip and promote-lock blocks and **before** the Stage 1 overlay routing comment at `:2769`, insert:

```cpp
    // [Stage 3a / SOLARUS_SCROLLFAB] The OLD map during a scrolling transition.
    // TransitionScrolling blits previous_map_surface onto the root at an animating
    // offset; without this it would fall into the overlay channel and be re-composited
    // in software every frame. Its pixels do NOT change during the scroll, so the
    // handles cache keeps the uploaded source resident: one upload for the whole
    // transition, then a fabric blit per frame at the engine-published offset.
    // Position comes from g_scroll_old_dx/dy rather than infos.dst_rectangle() so the
    // old and new maps are guaranteed to move against the SAME frame's offsets.
    if (d->scrollfab && g_transition_scroll && g_tagged_prev_map && &src == g_tagged_prev_map) {
      if (d->emit_draw(src, infos, g_scroll_old_dx, g_scroll_old_dy)) {
        if (d->diag) d->g_scroll_oldmap_blits++;
        return;
      }
      // Not expressible on the fabric (upload failure / escape): fall through to the
      // overlay so the old map is still PRESENT, just composited in software. Logged
      // by the existing escape counters.
    }
```

- [ ] **Step 3: Print the counter**

In the `[blitter]` banner, extend the format string added in Task 2 with ` scroll_oldmap=%ld` at the end (before the `\n`) and add `d->g_scroll_oldmap_blits` as the final argument, after `d->g_spr_dropped`.

- [ ] **Step 4: Type-check with format checking**

```bash
g++ -fsyntax-only -std=c++17 -Wall -Wformat=2 -I patches/mister -I patches/mister/blitter \
  -I work/solarus/include -I build/armhf/include \
  -I work/solarus/libraries/win32/mingw32/include $(sdl2-config --cflags) \
  patches/mister/mister_blitter_renderer.cpp 2>&1 | grep -i "format" || echo "no format warnings"
```
Expected: `no format warnings`.

- [ ] **Step 5: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "feat(render): emit the scroll old-map blit on the fabric

previous_map_surface is static during the scroll, so the handles cache
keeps it resident: one upload for the transition, one blit per frame at
the engine-published offset. Falls through to overlay if inexpressible.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YTKoioGE2kBeHM8Gdp2ppe"
```

---

### Task 6: Suppress the redundant overlay composite during a scroll

With Tasks 4-5 both maps composite on the fabric. The root surface may still receive the two blits' *software* renders through the overlay path, which would double-composite and under-dim (the #124 mechanism). Verify and, if so, suppress.

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` — case (1) overlay routing

**Interfaces:**
- Consumes: everything from Tasks 4-5.
- Produces: no new symbols.

- [ ] **Step 1: Determine whether a redundant overlay draw actually occurs**

Read the overlay routing block in case (1) (from `:2769` to the end of case 1). Establish, by reading the code, whether the two `return` statements added in Tasks 4-5 already prevent the old/new map blits from reaching the overlay.

Expected: the new map is handled by the pre-existing promote-skip at `:2737` (which returns), and the old map by Task 5's branch (which returns). If **both** already return, this task is a no-op — record that finding and skip to Step 3.

**Do not add suppression code speculatively.** If the reads show both paths return, adding a guard would be dead code.

- [ ] **Step 2: If a path does reach the overlay, guard it**

Only if Step 1 found a reachable path, add immediately before the overlay routing:

```cpp
    // [Stage 3a] During a fabric-composited scroll both maps are already on the
    // fabric (promote-skip + the old-map branch above). Anything else reaching here
    // is genuine screen-space content (HUD/dialog) and still belongs in the overlay.
```
and narrow the specific reachable condition found in Step 1. Document in the commit message exactly which path was reachable and why.

- [ ] **Step 3: Record the finding**

Append to `docs/superpowers/plans/2026-07-19-retained-scene-stage3a-transition-bandaid.md` under a new `## Task 6 finding` heading: whether a redundant overlay composite was reachable, with the file:line evidence. This matters for Task 8's interpretation — a double-composite would present as under-dimmed scroll frames, which could otherwise be misread as #122.

- [ ] **Step 4: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp docs/superpowers/plans/2026-07-19-retained-scene-stage3a-transition-bandaid.md
git commit -m "fix(render): confirm no double-composite of scroll maps via overlay

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YTKoioGE2kBeHM8Gdp2ppe"
```

---

### Task 7: Host test — scrolled alias offset and old-map routing

Models the engine-side decision logic against the emitter, in the style of the existing host tests. It does **not** compile the renderer (the existing suite doesn't either) — it pins the offset arithmetic and routing decisions that Tasks 3-5 introduce.

**Files:**
- Create: `patches/mister/test_scrollalias.cpp`
- Create: `patches/mister/build_test_scrollalias.sh`
- Modify: `patches/mister/build_host_tests.sh`

**Interfaces:**
- Consumes: `blt_emitter` API (`blt_emitter.h`) and the reference model (`blitter_ref.c`), as `test_spritelist.cpp` does.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Read an existing test to match its structure**

```bash
sed -n '1,60p' patches/mister/test_spritelist.cpp
cat patches/mister/build_test_spritelist.sh
```
Match its harness conventions (assert macro, `main` return, how it inits the emitter). The code below assumes a `CHECK(cond, msg)` macro in that style; **if the existing tests use a different macro name, use theirs.**

- [ ] **Step 2: Write the failing test**

Create `patches/mister/test_scrollalias.cpp`:

```cpp
// [Stage 3a] Scroll-transition compositing: offset arithmetic + routing decisions.
// Models what mister_blitter_renderer does during a TransitionScrolling frame. The
// renderer is not compiled here (no host suite compiles it); this pins the decisions.
#include <cstdio>
#include <cstring>
#include "blitter/blt_emitter.h"

static int g_fail = 0;
#define CHECK(cond, msg) do { if (!(cond)) { \
  std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, (msg)); g_fail++; } } while (0)

// Mirrors TransitionScrolling::get_mister_scroll_offsets: the two offsets are
// (map_dst_position - current_scrolling_position), exactly as draw() computes them.
struct ScrollOffsets { int new_dx, new_dy, old_dx, old_dy; };
static ScrollOffsets scroll_offsets(int cur_dst_x, int cur_dst_y,
                                    int prev_dst_x, int prev_dst_y,
                                    int scroll_x, int scroll_y) {
  return ScrollOffsets{ cur_dst_x - scroll_x, cur_dst_y - scroll_y,
                        prev_dst_x - scroll_x, prev_dst_y - scroll_y };
}

// Screen is 320x240. A RIGHT scroll puts the previous map at (0,0) and the current
// map at (320,0) on the both-maps surface, scrolling x from 0 -> 320.
int main() {
  // 1. At scroll start the OLD map fills the screen and the NEW map is fully right.
  {
    ScrollOffsets o = scroll_offsets(320, 0, 0, 0, 0, 0);
    CHECK(o.old_dx == 0   && o.old_dy == 0, "start: old map at origin");
    CHECK(o.new_dx == 320 && o.new_dy == 0, "start: new map fully off-screen right");
  }
  // 2. Mid-scroll the two maps are adjacent and always exactly 320 apart.
  {
    ScrollOffsets o = scroll_offsets(320, 0, 0, 0, 160, 0);
    CHECK(o.old_dx == -160, "mid: old map scrolled half off left");
    CHECK(o.new_dx ==  160, "mid: new map scrolled half on from right");
    CHECK(o.new_dx - o.old_dx == 320, "mid: maps stay exactly one screen apart");
  }
  // 3. At scroll end the NEW map is at the origin -- the steady-state alias offset.
  {
    ScrollOffsets o = scroll_offsets(320, 0, 0, 0, 320, 0);
    CHECK(o.new_dx == 0 && o.new_dy == 0, "end: new map at origin (steady state)");
    CHECK(o.old_dx == -320, "end: old map fully off-screen left");
  }
  // 4. A DOWN scroll moves y, not x.
  {
    ScrollOffsets o = scroll_offsets(0, 240, 0, 0, 0, 120);
    CHECK(o.new_dx == 0 && o.old_dx == 0, "down: x untouched");
    CHECK(o.new_dy == 120 && o.old_dy == -120, "down: y split about the seam");
    CHECK(o.new_dy - o.old_dy == 240, "down: maps stay one screen apart");
  }
  // 5. Regression guard for the bandaid's justification (1): with the alias offset
  //    pinned to 0 (the pre-Stage-3a behavior) the new map never moves, which is
  //    exactly "only the old map scrolls away".
  {
    ScrollOffsets o = scroll_offsets(320, 0, 0, 0, 160, 0);
    const int aliased_at_zero = 0;
    CHECK(aliased_at_zero != o.new_dx,
          "bandaid repro: alias at 0 does not track the scrolling new map");
  }
  if (g_fail == 0) std::printf("test_scrollalias: all passed\n");
  return g_fail ? 1 : 0;
}
```

- [ ] **Step 3: Write the build script**

Create `patches/mister/build_test_scrollalias.sh`, modeled on `build_test_spritelist.sh` (read it first and match its compiler flags and include paths):

```bash
#!/usr/bin/env bash
# [Stage 3a] Scroll-transition offset arithmetic + routing decisions.
set -euo pipefail
cd "$(dirname "$0")"
out=$(mktemp -d)
g++ -std=c++17 -Wall -Wextra -O1 -I. -Iblitter \
    test_scrollalias.cpp -o "$out/test_scrollalias"
"$out/test_scrollalias"
rm -rf "$out"
```

Make it executable:
```bash
chmod +x patches/mister/build_test_scrollalias.sh
```

- [ ] **Step 4: Run it and verify it PASSES**

```bash
bash patches/mister/build_test_scrollalias.sh
```
Expected: `test_scrollalias: all passed`, exit 0.

This test pins arithmetic that Task 3 already implements, so it passes on first run. To confirm it has teeth, temporarily break it:

```bash
sed -i.bak 's/cur_dst_x - scroll_x/cur_dst_x + scroll_x/' patches/mister/test_scrollalias.cpp
bash patches/mister/build_test_scrollalias.sh || echo "correctly FAILED with the sign flipped"
mv patches/mister/test_scrollalias.cpp.bak patches/mister/test_scrollalias.cpp
```
Expected: `correctly FAILED with the sign flipped`, then the restore.

- [ ] **Step 5: Register it in the suite**

In `patches/mister/build_host_tests.sh`, add to the comment list:
```
#   - build_test_scrollalias.sh : Stage 3a scroll-transition offsets + routing
```
and add before the final `echo`:
```bash
bash build_test_scrollalias.sh
```

- [ ] **Step 6: Run the whole suite**

```bash
bash patches/mister/build_host_tests.sh
```
Expected: ends with `== all host tests passed ==`.

- [ ] **Step 7: Commit**

```bash
git add patches/mister/test_scrollalias.cpp patches/mister/build_test_scrollalias.sh \
        patches/mister/build_host_tests.sh
git commit -m "test: pin scroll-transition offset arithmetic (Stage 3a)

Includes a regression guard reproducing the bandaid's justification (1):
an alias pinned at 0 does not track the scrolling new map.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YTKoioGE2kBeHM8Gdp2ppe"
```

---

### Task 8: Hardware A/B — the acceptance gate

**This task does not land code. It produces a validation record and a verdict on #122 and #123.** It is the gate the design specifies; nothing in Stage 3a is "done" until the operator has looked at a scroll.

**Files:**
- Create: `docs/superpowers/2026-XX-XX-stage3a-hw-validation.md` (dated the day it runs)

**Interfaces:**
- Consumes: the engine built in Task 3 Step 8, plus Tasks 4-6.
- Produces: a verdict recorded in the doc; a decision on whether `g_transition_scroll` can be deleted.

- [ ] **Step 1: Build and stage the engine**

```bash
scripts/docker_run.sh bash -c 'bash scripts/build_engine.sh; echo "BUILD_EXIT=$?"' 2>&1 | tee /tmp/build3a-final.log
grep BUILD_EXIT /tmp/build3a-final.log
cp build/armhf/solarus-run build/armhf/libsolarus.so.1.6.5 deploy/games/Solarus/
```
Expected: `BUILD_EXIT=0`. `deploy.py` ships from `deploy/`, which is **not** auto-refreshed.

- [ ] **Step 2: Deploy and verify by sha1**

```bash
./deploy.py --no-rbf --diag
ssh root@192.168.20.81 'sha1sum /media/fat/games/solarus/solarus-run /media/fat/games/solarus/libs/libsolarus.so.1.6.5'
sha1sum deploy/games/Solarus/solarus-run build/armhf/libsolarus.so.1.6.5
```
Expected: matching sha1s. **`deploy.py` exit 0 says nothing about which files moved** — a Stage 1 run reported success having updated only `solarus-run`. If they differ, `rm` the remote file first (FAT cannot overwrite an open exe) and redeploy.

- [ ] **Step 3: Confirm the core**

No RTL changed in Stage 3a, so the existing `Solarus_20260719.rbf` is correct. Confirm which core is loaded before drawing any conclusion — both RBFs are on the device, and the older one has no `sprite_unit` arm for opcode 10.

Ask the operator to confirm the loaded core, or check `version.txt` / the OSD. **Do not proceed on an assumption.**

- [ ] **Step 4: Launch safely and capture the BASELINE (flag OFF)**

Leave `/media/fat/config/Solarus.s0` **empty**; two concurrent engines wedge the host. Launch detached with the private `S0_FILE` override, logging to `/media/fat/logs/Solarus/` (never `/tmp`, wiped on restart):

```bash
ssh root@192.168.20.81 'cd /media/fat/games/solarus && \
  SOLARUS_BLITTER_DIAG=1 SOLARUS_SCROLLFAB=0 \
  setsid sh solarus_run.sh > /media/fat/logs/Solarus/scroll_off.log 2>&1 </dev/null &'
```

Have the **operator** walk to the pinned scroll targets from the Stage 2 session — **map 8→9, then 9→3** — and cross each edge. **Never blind-inject joypad input.**

Record from the operator: does the scroll show a black flicker (#123)? A held/duplicated frame (#122)? Anything else?

- [ ] **Step 5: Capture the FABRIC path (flag ON)**

```bash
ssh root@192.168.20.81 'kill -9 $(pidof solarus-run)'   # busybox has no pkill
ssh root@192.168.20.81 'cd /media/fat/games/solarus && \
  SOLARUS_BLITTER_DIAG=1 SOLARUS_SCROLLFAB=1 \
  setsid sh solarus_run.sh > /media/fat/logs/Solarus/scroll_on.log 2>&1 </dev/null &'
```

Confirm the flag actually took effect — the launcher echoes flags in effect:
```bash
ssh root@192.168.20.81 'grep "scroll fabric path" /media/fat/logs/Solarus/scroll_on.log'
```
Expected: `[MiSTer blitter] scroll fabric path ENABLED (SOLARUS_SCROLLFAB)`. If absent, the flag did not reach the engine — fix that before collecting any data.

Operator crosses the **same two edges**.

- [ ] **Step 6: Pull the logs and extract the objective signals**

```bash
mkdir -p docs/superpowers/stage3a-hw
scp root@192.168.20.81:/media/fat/logs/Solarus/scroll_o{ff,n}.log docs/superpowers/stage3a-hw/
grep -o "heap=[0-9]*/[0-9]* heap_peak=[0-9]*" docs/superpowers/stage3a-hw/scroll_on.log | tail -20
grep -o "overflow=[0-9]*" docs/superpowers/stage3a-hw/scroll_on.log | sort | uniq -c
grep -o "esc_overflow=[0-9]*" docs/superpowers/stage3a-hw/scroll_on.log | sort | uniq -c
grep -o "scroll_oldmap=[0-9]*" docs/superpowers/stage3a-hw/scroll_on.log | tail -5
```

**Interpretation — state these explicitly in the record:**
- `heap_peak` **is** the #123 heap-premise test. If it stays far below `heap_cap` across a scroll edge, the bandaid's justification (2) was unreachable in the current build, confirming the code reading.
- `scroll_oldmap` > 0 proves Task 5's branch actually fired. If it is 0 with the flag ON, the old map is still going to the overlay and the A/B is measuring the wrong thing.
- **Do NOT cite the `[blitter inter]` line for any heap claim** — it reads the SDRAM INTER arena, a different region. This exact confusion is why the tracker in Task 2 exists.

- [ ] **Step 7: Write the validation record**

Create `docs/superpowers/2026-XX-XX-stage3a-hw-validation.md` following the structure of `docs/superpowers/2026-07-19-stage2-hw-validation.md`, including its **"What is NOT established"** section. Required content:

- deployed artifact sha1s and the confirmed core;
- the operator's verbatim observations for flag OFF and flag ON, on both edges;
- an **explicit verdict on #122 and on #123** — closed / still open / changed. If the evidence does not support a verdict, say so; do not manufacture one;
- `heap_peak` across the scroll edge, with the reading spelled out;
- `scroll_oldmap`, `overflow`, `esc_overflow` counts;
- whether `g_transition_scroll` can now be deleted.

- [ ] **Step 8: Commit the record**

```bash
git add docs/superpowers/2026-XX-XX-stage3a-hw-validation.md docs/superpowers/stage3a-hw/
git commit -m "docs: Stage 3a HW validation record

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YTKoioGE2kBeHM8Gdp2ppe"
```

---

## After this plan

Do **not** do these as part of Stage 3a:

- **Delete `g_transition_scroll` and `SOLARUS_SCROLLFAB`, making the fabric path unconditional.** Only after Task 8's verdict is positive, as a follow-up.
- **Flip `SOLARUS_SCROLLFAB` default-ON.** Same gate.
- **Stage 3b** (`TilemapChannel` + `tilemap_unit`) — planned separately once 3a's findings are in, per the operator's decision to plan 3a alone.

## Risks

| Risk | Signal | Response |
|---|---|---|
| The camera surface's pixels are needed by something other than the promote blit during a scroll | Visual corruption on the *new* map with the flag ON | Fall back to flag OFF; the alias offset assumption in Task 4 is wrong |
| `previous_map_surface` is re-rendered mid-scroll, so the `handles` cache re-uploads every frame | `heap_peak` climbing across the edge; `reuploads` rising | Task 5's "static during scroll" premise is wrong — reconsider |
| Engine hook lands too late in the frame | Scroll visibly lags by one frame with the flag ON | Verify `Game.cpp:616` still precedes `current_map->draw()` at `:642` |
| Double-composite via the overlay | Under-dimmed scroll frames (the #124 mechanism) | Task 6 exists to find this before the HW session |
| A misread of which core is loaded | Garbage that looks like a Stage 3a bug | Task 8 Step 3 — confirm, never assume |
