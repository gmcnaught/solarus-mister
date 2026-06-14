# 60 fps bottleneck hunt — autonomous plan + end-to-end flow review

Goal: find and remove what keeps the Solarus overworld below 60 fps (16.67 ms/frame).
Current: readcache ~17.8 fps (~56 ms/frame) on clean analog; burst ~21 fps (analog-broken,
rolled back — see `sdram-burst-reintegration.md`). To hit 60 we need ~3.4× off the frame time.

## Hard constraint for this autonomous block
No human at the monitor. So:
- ALLOWED (no display needed): engine **counter** measurement (fps via diag-window-rate,
  overdraw factor, escape), **sim** (cycle profiling), **engine-side** changes deployed on the
  **working readcache RBF** (engine-only `.so` swap → RBF unchanged → analog stays clean).
- DEFERRED to the user: any **fabric/RBF** change (any RBF change risks analog) and any
  **render-correctness** judgement (counters LIE about display health — proven 2026-06-14).
- Device left on the working readcache core at all times.

## End-to-end frame flow (where 60 fps can be lost)
1. **Quest logic (Lua)** — runs at 100 Hz fixed timestep (decoupled from draw). Not the
   draw bottleneck unless script-heavy.
2. **Engine composite (A9)** — Solarus draws ~6 full-screen layers + sprites onto the camera
   surface each frame. In the blitter path, each draw becomes a blitter command EMITTED to the
   DDR ring (the A9 builds command words; pixels are composited by the fabric, not the A9).
3. **Ring submit + fabric wait** — the engine writes C_SUBMIT and (no-fallback engine) WAITS
   for C_DONE==submit_seq (the fabric finished compositing the frame into DDR).
4. **Fabric blit (FPGA)** — blitter_top walks the ring, reads sources (DDR3 readcache / SDRAM
   burst), composites 6× overdraw into the DDR framebuffer, flips the buffer.
5. **Scanout (FPGA)** — openbor_video_reader streams the framebuffer to VGA at the core's
   ~59.9 Hz; analog encode.
6. **Present pacing** — the engine loop's frame cadence vs the 59.9 Hz scanout (judder if
   unaligned).

## The ONE established lever (from the overdraw instrumentation)
HW-measured: the overworld is **6× visible overdraw = 6 full-screen static-source layers**
recomposited every frame ([[solarus-overworld-overdraw]]). Cutting that to ~1–2× (cache the
static-background composite, redraw only moving sprites) is the path toward 60 fps. It is an
ENGINE-side restructure (emit fewer/cheaper blits) → counter-validatable on readcache.

## Phases (this block)
- **P1 (this doc):** flow review + plan. DONE.
- **P2 — measure the split:** add per-frame timing diag (A9 emit time vs fabric C_DONE-wait vs
  present), + frame-time jitter (pacing). Build engine, deploy on readcache, read counters.
  Answers: is 56 ms A9-bound or fabric-wait-bound? Where does pacing jitter come from?
- **P3 — fabric cycle profile (sim):** extend tb_profile to the real 6-layer overworld blit
  mix → cycle-accurate per-phase cost (no device).
- **P4 — implement background cache (engine-side):** composite the 6 static layers once into a
  cached DDR region; per-frame copy + redraw moving sprites. Validate via the overdraw counter
  (6×→~2×) + fps counter. Commit. Flag for the user's VISUAL check before trusting render.
- **P5 — pacing:** if P2 shows jitter, align the present cadence to scanout / fix frame timing.

## P2 RESULT (2026-06-14) — overworld is FABRIC-BOUND; ring-pipeline is dead; background cache is THE lever
`[blitter timing]` on readcache, heavy overworld (alias_blits~630), 60-frame windows:
**fps=20.4, period=49ms | fabric=44ms (90%) A9=5ms (10%) sleep=0 | jitter~1ms | pipeline_ceiling=22.9fps.**
- The A9 emits the whole frame in **5 ms**; the **fabric takes 44 ms** to composite the 6×
  overdraw. Overwhelmingly **fabric-bound**.
- **Command-ring double-buffer pipelining is NOT worth it**: ceiling = max(A9,fabric)+sleep =
  ~44ms = 22.9fps (only +2.5fps), because A9 is already negligible. Drop that idea.
- Jitter ~1ms → pacing is fine; THROUGHPUT is the problem. (The free-running nanosleep cap
  never fires on the <60fps overworld; revisit pacing only once we're near 60.)
- Math to 60fps: fabric 44ms→<16.67ms = ~3× less fabric work. The **background-composite
  cache** (6 full-screen layer composites → 1 opaque bg copy + hero/HUD ≈ 2× overdraw, and an
  opaque copy is cheaper than a blend) cuts ~460k composited px → ~150k → ~15ms → ~60fps.
  This is THE lever and it's ENGINE-side (counter-validatable on readcache).
- Confound caught + fixed: armhf 32-bit `long` overflow in the ns counters (negative period).

## P2b — resolve the scroll question (gates the cache design), then P4 implement
Before building the cache, measure per-layer BLIT-PARAM stability (src-region+dst frame-to-
frame): static params → simple view cache; varying → scrolling map cache. Counter-only, no
monitor. Then implement P4.

## P2b RESULT (2026-06-14) — background is 100% cacheable (this scene); hero is the only mover
`[blitter paramstab]` on the heavy overworld: the **5 full-screen 320x240 layers + the 96x48
+ HUD bars are 100% stable** (composite identical frame-to-frame); the **535x298 hero sheet
is 2% stable** (varies every frame = animation/movement). So the background composite is fully
cacheable; only the hero (+occasional HUD) changes.
CAVEAT: the auto-loaded save sits in a STATIC-camera spot (no input = no scroll). During
active walking the bg layers' src-region scrolls → they'd go unstable → cache invalidates.
So the **simple static-bg cache wins in static scenes (rooms/menus/dialogs/standing); a
SCROLLING-MAP cache is needed to also win while walking.**

## P4 DESIGN — background-composite cache (the 60fps lever; ENGINE-side)
Goal: replace the per-frame 6× full-screen blend composite with (1 opaque bg copy + the
dynamic hero/HUD). Fabric 44ms → ~15ms → ~60fps (P2 math).

Mechanism (layered, build the simple one first, validate VISUALLY with the user):
1. **bg_cache buffer** in DDR (a 3rd 320x240 region beyond BUF0/BUF1, in the 0x3A region or
   the 0x3B command region's spare space).
2. **Classify** each source ptr static-bg vs dynamic using the param-stability hash (warm up
   ~30 frames; a src with a stable per-frame param-hash = static bg; the hero = dynamic).
3. **bg generation:** hash the ORDERED set of static-bg blits each frame. When it changes
   (scene change / scroll step), RE-COMPOSITE the static-bg blits into bg_cache (full cost,
   one frame). When unchanged, SKIP re-compositing them.
4. **Per frame:** emit `copy bg_cache → target framebuffer` (1 opaque full-screen blit, ~7
   cyc/px) as the frame base, THEN emit only the dynamic (hero/HUD) blits on top. Skip the 5
   static-bg blend blits entirely.
5. **Scroll handling (full 60fps everywhere):** when the bg param-hash changes by a small
   delta every frame (scrolling), bg_cache must be a MAP-sized (view+margin) surface composited
   once, window-blitted per frame at the scroll offset, recomposited only on margin-cross. This
   is the bigger version; do it only if the simple cache's static-scene win isn't enough.

Correctness risks (need the user's eyes): draw-order (bg must be classified+emitted correctly
vs the dynamic top), blend semantics (the bg copy must be opaque/exact), double-buffer
coherence (both framebuffers need the bg), cache invalidation timing. COUNTER-validate the
fabric-time drop (target ~15ms) + escape=0; the user validates render correctness.

## Implementation status (autonomous block)
DONE (no monitor): full diagnosis (P1-P2b) + all instrumentation, committed on `perf-60fps`.
DEFERRED to user (needs VISUAL validation): the P4 cache implementation — it is correctness-
critical and the auto-load can't exercise scrolling, so building it blind risks an
invisible-broken render. Ready to execute together with eyes on the screen.

## SOLARUS SOURCE RESEARCH 2026-06-14 (user hypothesis CONFIRMED)
Read the cloned Solarus 1.6 source (work/solarus/src). `Entities::draw()`
(entities/Entities.cpp ~line 1215) loops `for layer in [min_layer..max_layer]` and for
EACH layer draws: animated tiles (camera-overlapping) + `non_animated_regions[layer]->
draw_on_map()` + that layer's entities. `NonAnimatedRegions::draw_on_map()` blits the
layer's cached per-grid-cell tile surfaces (`optimized_tiles_surfaces`) for every cell
overlapping the camera — EVERY FRAME. So:
- Solarus caches the TILES (per-cell surfaces) but NOT the flattened multi-layer result.
- It composites all N map layers' tile surfaces onto the camera every frame even though the
  composited background is 100% identical frame-to-frame (param-stab) = the 6× overdraw.
- There IS already a `[MiSTer]` entity-cull mod here: the entity draw region was tightened
  from the stock 3×-camera (9× area) to camera+64px (SOLARUS_CULL_MARGIN) — matches the
  cull64 memory. (So the gross 9× entity overdraw was already cut; the remaining 6× is the
  per-layer TILE composite.)
- CAVEAT for flattening: entities interleave BETWEEN tile layers (layer0 tiles→layer0
  entities→layer1 tiles→...), so you can't blindly flatten all tile layers — but in this
  scene only the hero is dynamic, so the static layers+static-entities flatten cleanly.
=> Two equivalent fix sites for the SAME lever: (A) flatten the static map-background at the
SOLARUS level (composite the static layers once into a map-bg surface, blit once + dynamic
entities) — touches core map rendering + z-order correctness; (B) the MiSTer-renderer DDR
background cache (P4) — works at the blit-stream level, doesn't touch Solarus core. (B) is
lower-risk. Either needs VISUAL validation.

## ⚠️ ASSUMPTION UNDER TEST: is the blitter even faster than plain software?
The OSD/handler ships the SOFTWARE path (solarus_run.sh does NOT set SOLARUS_BLITTER). My
fabric-bound analysis was the BLITTER path. Memory says Solarus software overworld ~28-31fps
vs blitter readcache ~20fps → the blitter offload may be a NET REGRESSION on the heavy
overworld (it helped LIGHT screens). Measuring sw-vs-blitter fps directly (frame-counter
rate) to decide whether 60fps work targets SOFTWARE or the blitter.
RESULT (2026-06-14, heavy overworld, readcache RBF, frame-counter rate):
- **TRUE SOFTWARE (blitter off, confirmed renderer=0): 26 fps**
- **BLITTER: ~20 fps**
(My first "software" run was wrong — `SOLARUS_BLITTER=` empty-string is non-null so the
blitter stayed on; env -u gives the true 26.) So software is ~23% faster on this scene —
BUT both are OVERDRAW-bound (software does the same 6× composite on the ARM). 

DECISION (user, strategic): KEEP THE BLITTER. The point is OFFLOAD — the blitter runs the
A9 at only 5ms/frame (~idle) vs software using the full ARM; it's the reusable engine
(generalizes to gmloader/OpenBOR). The blitter is "slower" here only because the fabric does
the 6× overdraw inefficiently. Fix = the background cache (cut fabric 6×→~2×) → blitter
~20→~60fps WHILE the ARM stays free = the offload win realized + beats software. Do NOT
retreat to software (that puts compositing back on the ARM). The 26-vs-20 gap is just
headroom showing the fabric leaves a little on the table today; the 3× overdraw lever dwarfs it.

## Stop-and-review triggers (per the user's instruction)
If counters are confounding (e.g., overdraw drops but fps doesn't, or fps rises but
escape>0), STOP, re-derive the end-to-end flow + assumptions here, then implement the
highest-likelihood frame-rate/pacing item. Commit before each experiment for rollback.
