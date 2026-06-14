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

## Stop-and-review triggers (per the user's instruction)
If counters are confounding (e.g., overdraw drops but fps doesn't, or fps rises but
escape>0), STOP, re-derive the end-to-end flow + assumptions here, then implement the
highest-likelihood frame-rate/pacing item. Commit before each experiment for rollback.
