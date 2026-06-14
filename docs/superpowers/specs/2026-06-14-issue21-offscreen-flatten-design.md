# #21 — Off-screen-path background flatten (static + scrolling → ~60fps)

**Issue:** #21 (epic `solarus-fpga-renderer`)
**Date:** 2026-06-14
**Status:** design approved, pre-implementation

## Goal

Cut the overworld's 6× per-frame composite to ~2× by flattening the static map
background, on the **correct off-screen fabric path** introduced by #18
(`C_TARGET=2` compose into the fixed cache region), for both **static** scenes
and **scrolling** gameplay, reaching ~60fps. Replace the retired alias-path
snapshot, validate engine-side by counters, and (after a visual gate) ship it
default-on.

### Why this lever
HW-measured: the overworld is **fabric-bound** — fabric ~44ms / A9 ~5ms per frame
(`60fps-bottleneck-hunt.md` P2 result). The fabric recomposites 6 full-screen
static layers every frame even though the composited background is 100% identical
frame-to-frame (param-stab) except the hero. Cutting 6×→~2× (one opaque cache copy
+ dynamic blits) is the ~3× the frame-time budget needs: fabric ~44ms → ~15ms →
~60fps. This is an **engine-side** restructure (emit fewer/cheaper blits),
counter-validatable on the working readcache RBF.

## Current state (what already exists)

Most of the machinery is coded in `patches/mister/mister_blitter_renderer.cpp`,
but was built and measured against the **old alias-path snapshot** (render
static-only into the visible framebuffer, then memcpy fb→bg_cache) and pre-#18:

- Plain bg-cache (`SOLARUS_BGCACHE`, **default-on**): standing 22→~45fps.
- Scroll-aware cache (`SOLARUS_SCROLLCACHE`, env-gated, **off** by default):
  walking 21→~30fps (never reached 60).
- State machine `BG_LEARN → BG_SNAPSHOT → BG_ACTIVE` exists.
- #18 replaced the snapshot with an **off-screen `C_TARGET=2` compose** into the
  fixed cache region (`OFF_BGCACHE = 0x3BF00000`, matches fabric `CACHE_QW`); no
  display flip, so no static-only flicker frame.
- Scroll path exists: ACTIVE blits the cache **shifted** by the camera delta
  (`blt_blit_copy(bg_handle, -cur_dx, -cur_dy)`) and recomposites only the
  newly-revealed edge strips via `emit_draw_clipped` + `in_uncovered_margin`.

So #21 is **complete + correct + perform + validate on the off-screen path**, not
a green-field build.

## Architecture (the off-screen path — unchanged by this work)

- **SNAPSHOT**: emit the static (cacheable) blits with `C_TARGET=2`. The fabric
  routes the destination to the cache region and does NOT flip the display; the
  previous complete frame stays on screen, so no static-only frame is ever shown.
  `clear=1` starts the cache fresh.
- **ACTIVE**: per frame, `blt_begin_frame(target_buf, clear=0)` →
  one opaque `copy(bg_cache, -cur_dx, -cur_dy)` as the frame base → then
  **dynamic-only** blits composite on top. Cacheable static blits are skipped
  (plain cache) or contribute only their clipped edge strip (scroll cache).
- **Fallback (always correct)**: static-set param-hash change (scene change) or
  scroll shift past `MAXSHIFT` (96px) → return to LEARN = the full 6× composite.
  Scroll never stabilizes the unshifted hash, so the plain cache safely stays in
  LEARN while walking; the scroll cache handles walking via the shifted copy.

Cacheable classification: a blit is cacheable when `dw >= 128 || dh >= 128`
(large static map-background cells); the hero sheet and HUD are dynamic. The
static-set hash uses **map coords** for the scroll cache (scroll-invariant) and
**screen coords** for the plain cache (so scrolling perturbs the hash → LEARN).

## Work — Gap A (static scenes)

1. **Retire alias-path remnants** so the off-screen path is the only path: audit
   and remove the dead visible-frame memcpy snapshot and the `SOLARUS_ALIAS_SW`
   static-camera aliasing where it is now superseded. Keep only what the
   off-screen path needs.
2. **Re-validate static scenes** (standing / rooms / menus / dialogs) on the
   off-screen path via counters: overdraw 6×→~2×, fabric ~44→~15ms, `escape==0`,
   fps→~60.
3. **Double-buffer coherence**: confirm ACTIVE's per-frame opaque copy correctly
   re-bases the background in *both* display buffers (no stale-hero smear) now
   that the snapshot no longer writes a display buffer.

## Work — Gap B (scrolling — the real perf push, 30→~60)

Scroll-path per-frame costs: the full-screen opaque cache copy (~unavoidable
base), clipped edge-cell recomposite (cheap *if strips stay minimal*), and
**re-snapshot churn at `MAXSHIFT=96`** (a full static recomposite every ~96px of
scroll → periodic hitch). Levers, in order:

1. **Confirm edge strips are truly minimal** — a 512px cell must contribute only
   its ~|shift|px revealed edge, not silently re-emit the whole cell. This is the
   most likely cause of the 30fps cap. Verify via the per-frame composited-pixel /
   `alias_blits` counters while walking.
2. **Make re-snapshot rarer / non-blocking** — enlarge the off-screen cache toward
   a map-view+margin surface so margin-crosses are infrequent; ensure `present()`
   does not stall the displayed frame waiting on the re-snapshot's `C_DONE`.
3. **Re-measure walking fps** after each lever (counter-only). ~60 is the
   *target, not a hard requirement* — take the clearly worthwhile levers (1) and
   (2), then stop at the point of diminishing returns and document the achieved
   walking fps. Do not chase the last few fps with disproportionate complexity.

## Validation & rollout

- **This session (no monitor — autonomous-block rule):** engine-only `.so`
  changes deployed on the working readcache RBF (no RBF change → analog stays
  clean). Validate by **counters only**: fps (diag-window rate), overdraw factor,
  `escape==0`. Commit before each experiment for rollback. **Counters lie about
  display health** — they do NOT certify render correctness.
- **Deferred visual gate (user, at the monitor):** scroll z-order, edge seams,
  re-snapshot hitches, and dialog / scene-transition / overworld-entry
  correctness. Required before trusting render.
- **Default-on flip:** only after the visual pass — set `SOLARUS_SCROLLCACHE=1`
  (and keep `SOLARUS_BGCACHE=1`) in `games/Solarus/solarus_run.sh`.

## Out of scope (YAGNI, evidence-based)

- **Ring command double-buffer** — the #21 title pairs it with the flatten, but
  the P2 result measured its ceiling at **+2.5fps** (A9 emit is only 5ms; the
  frame is fabric-bound). Dropped per that evidence.
- **Solarus-core flatten** — the alternative of flattening static map layers at
  the Solarus map-rendering level (touches core z-order). Not pursued; this work
  stays at the blit-stream / off-screen-cache level (lower risk, no core changes).

## Success criteria

- Static scenes ~60fps on the off-screen path; `escape==0`; overdraw ~2×.
- Walking fps materially above the prior ~30. ~60 is a target, NOT a hard
  requirement: stop at diminishing returns and document the achieved fps.
- Alias-path snapshot remnants removed; off-screen path is the only flatten path.
- Counter-validated this session; **visual gate passed by the user** before
  default-on.
- `SOLARUS_SCROLLCACHE` flipped default-on in `solarus_run.sh` post-validation.
