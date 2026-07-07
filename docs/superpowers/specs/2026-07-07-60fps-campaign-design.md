# 60fps campaign — phased engine + fabric design

**Date:** 2026-07-07 · **Status:** approved-pending-review · **Target branch:** per-phase feature branches off `master`

## Goal

Reach **60 fps standing at the heavy village save spot** (Mystery of Solarus DX,
the campaign's reproducible A/B location), with smooth pacing, **without any
gameplay/semantic change**. Threading (concurrency on the second A9 core) is in
scope; LOD, update throttling, and tick-rate changes are **out of scope**.

Success criteria:
- ≥ 55–60 fps standing at the save spot with diag flags OFF.
- Pacing: FASTPACE vblank skips ≈ 0/60 at target fps; worst-frame jitter under
  ~2× median period (today: 63–83 ms spikes on a 38 ms median).
- Behavior-neutral: HW A/B at the same spot shows identical gameplay (enemy
  speed/AI, cut-grass, dialogues); every lever ships behind a `SOLARUS_*` flag,
  default OFF until HW-validated (then baked ON, the IDLEPARK pattern).

## Baseline (measured 2026-07-07, diag ON, standing at save spot)

| Metric | Value |
|---|---|
| fps / period | 25.5–27 / 37–39 ms |
| Bound | **A9** (fabric wait only 2.7–3.6 ms/frame) |
| A9 busy | 30–33.5 ms/frame |
| `eng_cpp` (update steps) | 18.6–21.5 ms = entities 9.4–11.7 + hero ~2.3 + tileset ~1.4 + sound ~2 + other ~3.5 |
| steps/frame × per-step | 3.7–3.9 × ~5.2 ms |
| A9 per-frame (non-step: draw/emit/Lua/present glue) | **~10.7 ms — largely unattributed by banners** |
| entities detail | enemy 5–7 ms (27 upd; move = integ 2.3–3.2 + obstacle 1.2–2.4); walls 0.6–0.9 (≈113 upd), NPC ~1.5 (≈42), teletransporter ~0.5 (≈73), door, destination (≈46) |
| fabric_hw | **19.9 ms/frame, comp% = 82%** (runs concurrent with A9) |
| jitter / fastpace skips | 63–83 ms / 26–36 per 60 frames |

## Budget model (why both A9 and fabric must move)

Solarus runs game logic at a fixed 100 Hz; at F fps the engine runs `100/F`
update steps per displayed frame (catch-up). Equilibrium frame time:

```
T = perframe / (1 − per_step/10)          (ms)
```

where `perframe` is ALL non-step time (A9 draw/emit/glue + fabric wait + sleep).
Today: `(10.7 + 3.3 + 3.7) / (1 − 0.52) ≈ 37 ms` ⇒ ~27 fps. ✓

For T = 16.7 ms (60 fps) the design targets:
- **per_step ≤ ~4.0 ms** (from 5.2) — Phase 1
- **A9 per-frame ≤ ~6 ms** (from 10.7) — Phase 2
- **fabric ≤ 16.7 ms** (from 19.9; it overlaps the A9, but must fit the frame) — Phase 3

With per_step 4.0 and perframe 6: `T = 6/0.6 = 10 ms` of A9 per frame — margin
for the fabric snapshot cadence and for heavier rooms than the benchmark spot.
The catch-up coupling makes per-step cuts pay super-linearly: as fps rises,
steps/frame falls (3.8 → 1.67 at 60 fps).

## Phase 0 — gprof attribution (no code change)

~10.7 ms/frame of A9 time and ~0.9 ms/step of `other` are invisible to the
curated banners. Aim every later lever with a whole-program profile first.

- Build: CI workflow `build-engine-gprof.yml` (or locally
  `SOLARUS_GPROF=1 scripts/build_engine.sh` in the Docker image). `-pg` is on
  compile+link of **both** `solarus-run` and `libsolarus` (where all the code
  lives); LTO forced OFF.
- Capture: deploy instrumented engine, `SOLARUS_GPROF=1` in `diag.env`
  (`solarus_run.sh` sets `GMON_OUT_PREFIX=/media/fat/logs/Solarus/gmon.out`),
  drive to the save spot, stand ≥ 60 s, then **SIGTERM** (never `kill -9` —
  gmon.out is written by the atexit hook). Pull `gmon.out.<pid>`, run
  `scripts/gprof_report.sh`.
- Deliverable: ranked attribution of (a) the ~10.7 ms per-frame share (emit vs
  Lua VM vs present/pacing vs glue), (b) `other` 3.5 ms/frame inside eng_cpp,
  (c) sound 2 ms, (d) anything unexpected. Feeds the Phase 1 lever list and the
  Phase 2 descope decision.
- Caveats (accepted): mcount overhead inflates small hot functions — gprof
  **ranks** levers, only banners produce A/B fps numbers; verify the flat
  profile actually attributes into libsolarus symbols (if it comes back empty,
  fall back to targeted banner injections instead — do not trust a silent
  profile).

Gate: written attribution table; Phase 1 lever list confirmed/amended.

## Phase 1 — per-step cuts (single-thread, proven IDLEPARK pattern)

Target: per_step 5.2 → ≤ 4.0 ms (stretch 3.5). Expected alone: ~26 → ~33–38 fps.

1. **1a Static-entity park** (`SOLARUS_STATICPARK`): ~230 of ~390 per-tick
   updates are walls (113), teletransporters (73), destinations (46) whose
   `update()` is a provable no-op (no movement, no animated sprite, no timers).
   Park them out of the update walk exactly like IDLEPARK parked idle
   destructibles: park-on-idle-classification, wake hooks on any mutation
   (enable/disable, movement attach, sprite attach, dynamic property change).
   Doors are **excluded** unless proven idle (they animate on open/close).
   Est. ~1.5–2.5 ms/frame of entities cost.
2. **1b Enemy move-bookkeeping** (`SOLARUS_GROUNDCACHE`, `SOLARUS_OBSTPRUNE`):
   the enemy "integ" cost (2.3–3.2 ms) is `notify_position_changed` per move —
   quadtree already fat-AABB'd (PR #65); remaining levers: skip
   `update_ground_below` when the entity's ground-point stayed inside the same
   ground cell (cache cell + ground result), and prune the obstacle-test funnel
   (1.2–2.4 ms) via early-out on the cached traversability of the current cell
   row/column. Behavior identical: caches invalidated on map/tile mutation.
3. **1c Sound + `other` per gprof** — sound update is ~0.5 ms/step on the main
   thread even with mixing on core 1; gprof decides whether it's OpenAL source
   bookkeeping (movable to the audio thread as Phase 2b) or cheap-enable logic.
   **Phase 0 result: main-thread sound is only ~0.4 ms** (the ~2 ms banner is the
   separate core-1 `audio_thread_main`, 1.92 %) — 1c is cheap-enable logic, not a
   hog; deprioritise, and Phase 2b is largely already true.

**Phase 0 additions (from `docs/superpowers/2026-07-07-gprof-attribution.md`,
LD_PROFILE at the save spot):**

4. **1d Kill the Lua-console spin-thread** — the daemon launches the engine with
   stdin = `/dev/null`, so the Lua-console `getline()` loop EOFs instantly and
   busy-polls `MainLoop::is_exiting()` **173 M calls/run** (profile ranks #2–#3;
   report line: *"F1 — Lua-console stdin thread spins a whole A9 core"*). It is a
   separate thread (not main-thread ms) but burns a core that contends with the
   core-1 audio thread and the future emit worker. Fix: add **`-lua-console=no`**
   (verified spelling, `work/solarus/src/main/Main.cpp:70`) to `solarus_run.sh`.
   Win = frees ~a core of contention; **frame-time effect unknown until HW A/B.**
5. **1e Z-sorted-visible-list cache** — the quadtree `get_elements` + Z-order
   sort/unique/insert family is the **#1 main-thread cost (~6.6 ms est.)**;
   `Entities::draw` re-runs the z-sorted visible-entity retrieval **every frame**
   even when standing still (constant camera + entity set). Cache the sorted list,
   invalidate on entity add/remove/move or camera move. Report line:
   *"Z-sorted visible-entity retrieval for draw ~2.5–3.5 ms — pure waste while
   standing."* Also reframes 1b: gprof puts most enemy "integ" cost in this
   quadtree-reinsert/sort family, confirming 1b's churn thesis at the family level.
6. **1f `userdata_has_field` negative-result cache + NDEBUG** — `userdata_has_field`
   ×3 rows ~2.0 % (~1.5 ms est., report line F/§`other`): Solarus probes "does this
   userdata have field X" in C++ every frame even when no script defines it; cache
   the per-(type,field) negative result. **Near-free companion:** build with
   `NDEBUG` — `Debug::check_assertion` is 0.80 % **in the shipping build** (report
   line F2), ~0.6 ms/frame of live asserts (mostly pixel-transparency bounds checks).
   Pixel-precise collision itself (`is_pixel_transparent` + `PixelBits`, ~1.1 ms,
   report line F3) is a further candidate.

Each lever: host-testable pure parts TDD'd, HW A/B same-spot, gated
default-OFF, baked ON only after validation.

Gate: banners show per_step ≤ 4.0 with no behavior deltas; fps ≥ 33.

## Phase 2 — emit/present worker on core 1 (`SOLARUS_EMIT_THREAD`)

Target: A9 per-frame 10.7 → ≤ 6 ms.

Design: decouple **command translation + ring I/O + pacing** from the main
thread. Main thread (update + draw, including all Lua) records draws into a
compact **record buffer** (cached malloc'd memory, cheap appends — not the
uncached DDR ring). `present()` becomes: swap record buffers, signal worker,
return. The worker (pinned core 1, beside the audio thread — both light):
translate records → blit commands → uncached ring writes → submit → FASTPACE
vblank pacing wait. Backpressure: exactly one frame in flight — `present(N+1)`
blocks until the worker finished frame N (bounded memory, bounded latency).

Correctness constraints:
- **No Lua on the worker.** All Lua (`on_draw` etc.) runs during main-thread
  draw *recording*; the worker only sees renderer-level records. Single
  `lua_State` untouched.
- **Surface lifetime:** sources are SDRAM-resident whole-quest atlases (PR #66)
  — stable. The residency **forget-hook** must drain the worker before an atlas
  slot is recycled. Dynamic uploads (text/HUD STAGE data) are copied by value
  into the record buffer, or force a synchronous flush (rare path).
- **Latency:** adds ≤ 1 frame of input-to-photon latency. Validate feel on HW;
  if unacceptable, fall back to offloading only the pacing wait + ring submit
  (smaller win, near-zero latency cost).

Descope rule (from Phase 0): if gprof shows emit+present < ~4 ms of the 10.7
(i.e. the bulk is Lua/glue that can't move), shrink this phase to the
pacing-wait offload and put the savings hunt back into Phase 1c.
**Phase 0 TRIGGERS this rule:** LD_PROFILE attributes only **~2.4 ms emit +
<0.3 ms present** of the 10.7; the rest is Lua boundary (~4.8 ms, single
`lua_State`, main-thread-locked) + per-frame z-sorted draw retrieval
(~2.5–3.5 ms, better killed by cache **1e** than by a thread) + the out-of-DSO
fabric wait. **Shrink Phase 2 to the pacing-wait/ring-submit offload** and move
the savings hunt to Phase 1 (1e/1f).

Gate: banners show A9 per-frame ≤ 6 ms; soak ≥ 10 min with zero ring
overflow/fatal; dialogues/menus/transitions clean (the #68 lesson: mid-run
surface paths are the fragile ones).

## Phase 3 — fabric under 16.7 ms

Runs **in parallel** with Phases 1–2 (independent RTL work).

1. **3a SRCFILL/composite overlap** (the documented next lever from the
   throughput session): double-buffered `comp_src_linebuf` so SRCFILL(span N+1)
   overlaps composite(N). SRCFILL is 44–59% of comp cycles; est. 16.3 →
   ~12.5–13 ms. Method: tb_profile cyc/px before/after, gating sims bit-exact,
   timing closure (colormod-era recipe), HW A/B via `[blitter hwperf]`.
2. **3b Background-plane cache (gated escalation).** Only if post-3a fabric
   > 16.7 ms on target scenes: compose the static tile layers once per
   camera region into an SDRAM plane; per-frame work collapses to one opaque
   full-screen COPY (~2 ms) + dynamic sprites (est. total ~5–8 ms). Requires a
   compositor→SDRAM writeback path (removed in PR #49) **or** a one-time A9
   composition at map-load. Big win, big scope — decide with 3a data in hand.

Gate: `[blitter hwperf]` fabric_hw ≤ 16.7 ms at the save spot AND on the
heaviest known 8×8-tile overworld screen.

## Measurement protocol (all phases)

Same save spot, standing still, ≥ 5 consecutive 60-frame windows of
`[blitter timing|hwperf|engcpp|enttype|entphase|entsplit]`; A/B = flag off vs
on, same session where possible. Final acceptance runs with **diag OFF**
(banners themselves cost A9 time). Relaunch via `touch
/media/fat/config/Solarus.s0`; joypad injection recipe in memory
`solarus-joypad-inject-hw`.

## Risks

| Risk | Mitigation |
|---|---|
| gprof profile empty for .so / skewed by mcount | Treat as ranking only; fall back to banner injections |
| Static-park wakes missed (stale collision/teleport) | Wake-hook checklist per entity class + gameplay soak (enter/exit doors, teleport, toggle dynamic tiles) |
| Emit-thread races (ring, residency forget-hook) | One-frame-in-flight design, drain-before-forget, 10-min soaks, flag default-OFF |
| Added input latency (Phase 2) | HW feel check; fallback = pacing-wait-only offload |
| 3b writeback path re-adds removed RTL complexity | Gated: only if 3a misses budget; A9-compose-at-load alternative |
| Benchmark overfit to the village spot | Gate Phase 3 (and final acceptance) on the heaviest 8×8 overworld screen too |

## Out of scope

Off-screen LOD / update throttling, 50 Hz logic tick, any gameplay-visible
change, OpenGL/shader paths, software-path (`SOLARUS_SW`) revival.
