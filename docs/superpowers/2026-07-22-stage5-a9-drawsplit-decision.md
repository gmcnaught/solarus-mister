# Stage 5 (A9 track) — `[blitter drawsplit]` sub-leaf decision

**Date:** 2026-07-22
**Engine:** `libsolarus.so.1.6.5` (Task-1 build, drawsplit brackets live). **RBF**
`Solarus_20260722.rbf` (current ship). **Scene:** map 3 town (save1, teleport `out_link_house`).
Standing + moving (held DOWN). **Raw:** `docs/superpowers/data/stage5-a9/drawsplit-map3.txt`.

This is the **anti-bias gate** for the draw-walk arc: committed with (in fact before) the finding, and
trivially satisfied because the pre-picked lever was **refuted** — no lever code was written. The
plan's leading suspect (Lever A, the draw-hook probe cache, because `luahook` "should" dominate)
was **refuted by the data**, exactly as the predecessor arc refuted `sprite_push`.

## `[blitter drawsplit]` decomposition (median of 5 windows)

`engine_traversal = build + luahook + geom_est + loop_residual` (identity; `builtin = blit + push +
geom_est`, and on map 3 `blit=0` — all sprites batch through `sprite_channel_push`, so `push≈0.5`).
The `xcheck` matched `engine_traversal` on **every** window (probe is exact).

| Sub-leaf (ms/60fr) | m3 standing | m3 moving | what it is |
|---|--:|--:|---|
| **loop_residual** | **3.48** | **4.05** | draw-phase cost NOT in any bracket — see below. **Dominant.** |
| builtin | 0.92 | 1.01 | per-entity `Sprite::draw` geometry + our dispatch + sprite_push |
| — geom_est | 0.42 | 0.53 | geometry + dispatch only (builtin − blit − push) |
| build | 0.65 | 0.79 | `entities_to_draw` cull + z-sort — **one-shot** (see finding 3) |
| luahook | 0.56 | 0.67 | `on_pre_draw`/`on_post_draw` metafield probes — **REFUTED suspect** |
| (engine_traversal) | 5.14 | 5.92 | walksplit residual, for cross-check |

**Surrounding context (median):** fps ~31; A9 ~15 ms = lua ~8.6 + emit ~5.5 + present ~0.6;
`[blitter hwperf]` = **A9**-bound; `drawcat entities≈59/fr`, `anim_tiles=0`; `[blitter overlayid]
overlay_frames=60 skippable=60` (overlay upload fully skipped); `[blitter drawcache] hit=0 miss=1/60fr`.

## Findings

1. **`loop_residual` is the whole story — the per-drawable draw-walk is NOT the limiter.** The three
   *attributable* per-drawable components (build one-shot + luahook + builtin) sum to only ~2.1 ms
   standing / ~2.5 ms moving; the larger ~3.5–4.0 ms (68 %) is `loop_residual` — the draw-phase cost
   that is neither resident tiles, nor overlay-composite, nor the `entities_to_draw` build, nor the
   per-entity hooks, nor the per-entity `built_in_draw`. The decision doc's premise (the ~60-entity
   per-drawable walk) captured under half of `emit_walk`.

2. **Lever A (`luahook` draw-hook probe cache) is REFUTED.** `luahook` is 0.56–0.67 ms. Caching the
   ~120 `userdata_has_metafield` probes/frame recovers ≤0.6 ms of a ~15 ms A9 budget. The leading
   suspect the plan pre-weighted A toward is **wrong** — building it would have been wasted work.
   Measure-first caught it (second consecutive refuted prior; the gate is earning its cost).

3. **`build` (z-sort/cull) is one-shot, not per-frame — Lever C refuted.** `[blitter drawcache]
   hit=0 miss=1/60fr` proves DRAWCACHE (patch 0022) rebuilds the sorted set ~once/second; the 0.65 ms
   is that single rebuild amortised across 60 frames, ~0 on the other 59. There is no per-frame sort
   cost to recover.

4. **`builtin` (geometry + dispatch + push) is small — Lever B/D recover little.** 0.92–1.01 ms total
   for 59 entities, of which geom_est (geometry + dispatch) is only 0.42–0.53 ms and push ~0.5 ms.

5. **`loop_residual` is REAL shippable cost, not diagnostic tax.** Diag-on fps (31) ≈ shipping fps
   (map 3 town ~29–31), so the diag instrumentation adds <1 ms — the ~3.5 ms is not measurement
   overhead. Overlay is fully skipped (`skippable=60`), so it is not the overlay composite. It is
   genuine per-frame draw-phase work.

6. **Leading (UNPROVEN) hypothesis for `loop_residual`: the per-frame root-surface REPAINT.** Per
   CLAUDE.md, the overlay-skip lever skips the root's *convert+upload* when content is identical
   (`overlayid skippable=60` here) but the root is still *cleared and repainted every frame* by base
   SDL (HUD, dialog, Lua `game_on_draw`/`main_on_draw`). That repaint is CPU draw work counted inside
   `emit` but attributed to none of the drawsplit brackets → it lands in `loop_residual`. `Map::draw`
   scaffolding (camera-surface ops, layer iteration, per-entity visibility checks) is the other
   contributor. **This must be measured, not assumed** — same discipline one level deeper.

## Named limiter + selected direction

**Named limiter:** `loop_residual` — the per-frame draw-phase cost outside the per-entity draw,
~3.5 ms standing / ~4.0 ms moving, dominant (~68 % of `engine_traversal`), per-displayed-frame, real
(not diag tax). Prime suspect: the root-surface repaint that overlay-skip does not eliminate.

**Selected direction: STOP the Section-2 lever menu; open ONE more finer probe on `loop_residual`
before committing a mechanism.** The gate refuted Lever A and showed B/C/D each recover <1 ms, so the
plan's Task 3 (Lever A) does **not** execute. The real target (`loop_residual`) is currently
unattributed; picking a mechanism now would repeat exactly the pre-pick error this gate just caught.

**Required next step (measure-first, one level deeper):** a `[blitter drawresidsplit]` bracket that
splits `loop_residual` into (a) the root-surface repaint (base-SDL HUD/Lua `on_draw` into the root),
(b) `Map::draw` scaffolding + per-entity visibility checks, and (c) any remaining Lua `map_on_draw`/
FPS-overlay diag term. Then decide the mechanism from that capture. If (a) dominates, the likely
lever is extending overlay-skip from "skip upload" to "skip repaint" on content-identical frames
(correctness-gated: the stale-HUD guard must still force a repaint on change).

**Expected magnitude (upper bound):** `loop_residual` ~3.5–4.0 ms of a ~15 ms A9 budget; if the
root-repaint is most of it and skippable on static frames, that is the largest single per-frame A9
recovery identified in this arc (larger than the refuted A/B/C/D). Per-frame → raises fps ~1:1
(upper bound; step-amplified `lua` grows slightly as the frame speeds up).

## Refuted / deferred (this arc)

- **Lever A — draw-hook probe cache** — REFUTED (finding 2). Do not build.
- **Lever C — z-sort hoist** — REFUTED (finding 3, DRAWCACHE already one-shot).
- **Lever B / D — Sprite::draw geometry / dispatch** — small (finding 4); revisit only if the
  loop_residual drill dead-ends.
- **`lua`/eng_cpp** — still the #1 raw A9 leaf (~8.6 ms) but step-amplified + correctness-risky; stays
  deferred.
- **map 119** — fabric-bound control, separate RTL track.

## References
- `docs/superpowers/data/stage5-a9/drawsplit-map3.txt` — raw drill (standing + moving).
- `docs/superpowers/2026-07-22-stage5-a9-emitwalk-decision.md` — predecessor (named emit_walk).
- `docs/superpowers/specs/2026-07-22-stage5-a9-drawwalk-design.md` — this arc's design (probe →
  gate → lever menu); the gate outcome supersedes the Section-2 menu with a loop_residual drill.
- CLAUDE.md — Overlay channel + overlay content-identity skip (skips upload, not repaint — finding 6).
