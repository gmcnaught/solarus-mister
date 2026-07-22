# Stage 5 (A9 track) — `emit_walk` sub-leaf decision

**Date:** 2026-07-22
**Engine:** `libsolarus.so.1.6.5` sha1 `198e39a3…` (on-device; `[blitter walksplit]` banner
confirmed present in the deployed `.so`). **RBF** `Solarus_20260722.rbf` (current ship).
**Scenes:** map 3 town (save1, teleport `out_link_house`); map 119 parallax (save1, teleport
`from_dungeon_10`). Standing + moving (held DOWN).
**Raw:** `docs/superpowers/data/stage5-a9/walksplit-map{3,119}.txt`.

This doc is committed **before** any Phase-3 lever code — the anti-bias gate. The lever direction
below was selected from the capture, not pre-picked. The brainstorm's working prior (a per-sprite
resolution cache, because `sprite_push` "felt" like the hot path at ~80 µs/draw) was **refuted** by
the data.

## `[blitter walksplit]` decomposition (median of ≥3 windows)

| Sub-leaf (ms) | m3 standing | m3 moving | m119 standing | m119 moving |
|---|--:|--:|--:|--:|
| **walk** (= emit) | 5.1 | 5.8 | 4.0 | 4.0 |
| **engine_traversal** | **4.6** | **5.3** | **3.7** | **3.7** |
| sprite_push | 0.4 | 0.4 | 0.2 | 0.2 |
| resident_emit | 0.0 | 0.0 | 0.1 | 0.1 |
| overlay | 0.0 | 0.0 | 0.0 | 0.0 |

**Cross-checks (gate satisfied):**
- `walk` matches the same window's `[blitter emitsplit]` `emit` on every window (two independent
  measurements of the same quantity agree).
- `engine_traversal` (the residual) is **≥ 0 on every window** — no bracket is mis-scoped.

**Surrounding A9 context (median):**

| | m3 standing | m3 moving | m119 standing | m119 moving |
|---|--:|--:|--:|--:|
| fps | 31 | 33 | 29.5 | 29.2 |
| A9 total | 14.3 | 16.4 | 12.4 | 13.6 |
| — lua / eng_cpp `*` | 8.4 | 9.8 | 7.7 | 9.0 |
| — **emit (walk)** | 5.1 | 5.8 | 4.0 | 4.0 |
| — present | 0.6 | 0.7 | 0.6 | 0.7 |
| `[blitter hwperf]` verdict | **A9** | **A9** | **FABRIC** | **FABRIC** |
| fabric_hw | 12.2 | 12.2 | 20.3 | 20.3 |

`*` step-amplified. drawcat: `entities=60/fr, anim_tiles=0` (all tiles ride the resident channel).

## Findings

1. **`engine_traversal` is the whole story of `emit_walk`.** It is ~90 % of the walk on map 3
   (4.6–5.3 ms of a 5.1–5.8 ms walk) and ~93 % on map 119. `sprite_push` (0.2–0.4 ms),
   `resident_emit` (0.0–0.1 ms), and `overlay` (0.0 ms) are all negligible. `engine_traversal` is
   the Solarus `Entities::draw` per-drawable walk — the z-order sort + the per-drawable
   `Entity`/`Sprite::draw` logic + the virtual dispatch into `MisterBlitterRenderer::draw` — for the
   ~60 drawn entities/frame.

2. **The `sprite_push` (per-sprite resolution cache) hypothesis is REFUTED.** The resolved-blit
   resolution (`map_blend`/`upload`/channel buffer) is 0.4 ms on map 3 — caching it recovers almost
   nothing. Building it would have been wasted work; measure-first caught this.

3. **`engine_traversal` is MOTION-INDEPENDENT.** It is essentially equal standing vs moving (m3
   4.6→5.3, m119 3.7→3.7 — the small m3 rise tracks a busier moving scene, not camera motion per se).
   This **rules out the z-sort / visible-set cache** (lever 1e) as the Phase-3 lever: that cache is
   camera-keyed (invalidates every frame the camera moves), so it can only recover a cost that
   *disappears* when standing — and this cost does not. `DRAWCACHE` (patch 0022) already caches the
   visible-entity *collection*; the residual `engine_traversal` is the per-drawable **draw-walk +
   dispatch** that runs every displayed frame regardless of motion.

4. **`emit_walk` is the #2 raw A9 leaf, not #1 — deliberately.** Post-overlay-skip, `lua`/eng_cpp
   (8.4–9.8 ms, step-amplified) is the largest A9 leaf and `emit_walk` (5.1–5.8 ms) is second. The
   scope decision (recorded with the user) picked `emit_walk` because it is **per-frame** (a true fps
   multiplier; a per-displayed-frame cost raises fps ~1:1) and **correctness-safe** (draw traversal,
   not game logic), whereas `lua`/eng_cpp is step-amplified (self-deflates as fps rises) and
   correctness-risky (enemy AI / collision / movement — see `solarus-enemy-per-update-cost-simd`).

5. **Map 119 stays FABRIC-bound — this A9 arc will NOT raise its fps.** `hwperf` = FABRIC both
   states (fabric_hw 20.3 ms ≫ A9 12–14 ms; comp 14.7 ms @ ~72 % active, ~2.0 M cyc/frame). map 119's
   walksplit is reported here purely as the **control** confirming the same A9 sub-shape; its ~29 fps
   is gated on the FPGA compositor. Raising map 119 needs a **fabric/RTL lever** (new RBF), a separate
   track — the prior K-grid decomposition was perf-neutral and the P_SRC cache gave the partial win.

## Named limiter + selected Phase-3 direction

**Named limiter:** the **per-drawable draw-walk** — Solarus `Entities::draw` z-order sort + the
per-entity `Sprite::draw` computation + virtual dispatch, for ~60 drawn entities/frame, ~4.6–5.3 ms,
**per-displayed-frame and motion-independent**.

**Selected Phase-3 direction:** reduce the per-drawable draw-walk itself (motion-independent →
recovers on BOTH standing and moving map 3). NOT the standing-only z-sort/visible-set cache (ruled
out, finding 3), and NOT a per-sprite resolution cache (refuted, finding 2).

**Expected magnitude (UPPER BOUND):** the recoverable ceiling is ~4.6 ms (standing) / ~5.3 ms
(moving) of a 14.3 / 16.4 ms A9 budget. Because fps < 60, per-frame recovery raises fps ~1:1 but the
step-amplified `lua` leaf will grow slightly as the frame speeds up and partially eat the win; treat
any fps projection as an upper bound. If Phase 3 recovered half of `engine_traversal`, map 3 moving
A9 ~16.4 → ~13.8 ms (fps ~33 → ~38, upper bound).

**Correctness bar:** the draw-walk feeds Z-order; any caching/reordering lever must be **bit-exact vs
the current emission order** (host test) + operator visual gate (Z-fighting / missing-sprite check).
Never self-declared (`solarus-no-self-declared-visual-validation`).

**Required FIRST step of the Phase-3 plan — one more attribution probe.** `walksplit` cannot split
`engine_traversal` into (a) the Solarus z-order sort, (b) the per-drawable `Sprite::draw` frame/rect
computation, and (c) our virtual dispatch glue — and those have very different cut-ability (a is
cacheable/sortable-once; b is the genuine per-sprite engine cost; c is thin). ~75 µs/drawable is far
above bare virtual-dispatch cost, which points at (a)+(b) in the engine, but that must be **measured,
not assumed**. Phase 3 therefore opens with a finer bracket (sort vs per-`Sprite::draw` vs dispatch)
before committing the concrete optimization. This is the same measure-first discipline one level
deeper — do not pre-pick the mechanism.

## Deferred (NOT this arc — one-lever discipline)

- **`lua` / eng_cpp reduction** (8.4–9.8 ms, the #1 raw leaf; step-amplified, correctness-risky) —
  deferred behind the per-frame, correctness-safe `emit_walk` work.
- **Per-sprite resolution cache** — refuted (finding 2).
- **Z-sort / visible-set cache (lever 1e)** — ruled out for the operative case (finding 3);
  revisit only for a genuinely standing-heavy, camera-static scene.
- **Map 119 fabric lever** — separate RTL/RBF track (finding 5).

## References
- `docs/superpowers/data/stage5-a9/walksplit-map{3,119}.txt` — raw drills.
- `docs/superpowers/specs/2026-07-22-stage5-a9-emitwalk-decompose-design.md` — this arc's design.
- `docs/superpowers/2026-07-22-stage5-a9-decision.md` — prior (overlay-skip) decision; named
  `emit_walk` as the runner-up and first flagged the z-sort cache as standing-only.
- CLAUDE.md — Overlay channel (overlay now ~0 ms, confirming overlay-skip); resident tilemap channel
  (resident_emit ~0 ms, confirming the tile emit is cheap).
