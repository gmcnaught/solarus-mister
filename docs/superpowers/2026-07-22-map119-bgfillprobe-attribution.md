# Map 119 background-fill attribution — Phase 0 results + decision

**Date:** 2026-07-23 (HW A/B)
**Spec:** `docs/superpowers/specs/2026-07-22-map119-tiled-fill-design.md`
**Plan:** `docs/superpowers/plans/2026-07-22-map119-bgfill-probe.md`
**Probe:** `SOLARUS_BGFILLPROBE` (engine-only, current ship RBF `Solarus_20260723.rbf`, no rebuild)
**Decision: NO-GO on the Phase-1 tiled-pattern-fill RTL op.**

## Stale-premise correction (found while capturing the baseline)

The design spec was built on `ab-p2-map119.txt` showing **fabric_hw 30.3 ms / comp 14.9 ms
(49%) / 19.6 fps**. That file was the **regressed intermediate Phase-2 build** (before the
vblank-gate-removal fix). The **actual current ship** (`Solarus_20260723.rbf`) measures:

- **fps 29.5, fabric_hw 20.63 ms, comp 14.89 ms (72%), non-comp ~5.74 ms.**

So the "~15 ms non-comp slice" the whole tiled-fill idea targeted **does not exist on the
ship** — non-comp is only ~5.7 ms, and the compositor (comp) is now 72% of fabric. Measuring
first is exactly what caught this.

## A/B result (standing, map 119, `from_dungeon_10`)

| metric | OFF (baseline) | ON (probe) | Δ |
|---|---|---|---|
| **fps** | 29.5 | 29.5 | **0** |
| fabric_hw | 20.63 ms | 16.83 ms | −3.80 ms (−18%) |
| comp | 14.89 ms | 13.88 ms | −1.01 ms |
| non-comp (fabric−comp) | 5.74 ms | 2.95 ms | −2.79 ms (−49%) |
| sleep | 8.8 ms | 12.4 ms | +3.6 ms |
| p0 BLEND | ~1734 | ~1785 | ~unchanged |

Probe active (`BGFILL PROBE ENABLED` = 1), engine ALIVE. Carved regions (diag):
`layer=0 pid=0 fill=[0,248 640×504]` (the ground), `layer=1 pid=142 [-40,240 704×520]`,
`layer=2 pid=239 [-8,-16 1152×1032]`. Data: `docs/superpowers/data/stage5/ab-bgfill-off-map119.txt`,
`ab-bgfill-on-map119.txt`.

## Interpretation

1. **map 119 is NOT fabric-bound at its operating point — it is vsync-paced to 30 fps.**
   fps is 29.5 in *both* legs; the 3.8 ms fabric saving went straight into `sleep`
   (8.8→12.4 ms). `pipeline_ceiling` is ~45 fps, well above 29.5. The engine targets 60,
   can't fit the pipeline in the 16.7 ms budget, and falls back to the 30 fps vsync
   submultiple — so shaving fabric time below the ceiling yields **zero** fps until it
   crosses the 16.7 ms threshold.

2. **Even the probe's upper bound doesn't cross 16.7 ms.** The probe replaces the fills with
   the cheapest possible op (one solid `BLT_OP_FILL`, no source fetch) and *over*-removes
   (its layer-2 bbox `1152×1032` is larger than the map). Yet fabric_hw only reaches
   16.83 ms — still above the 16.7 ms needed for 60 fps. A *real* tiled-fill op is strictly
   more expensive than the solid-fill probe (it still fetches + writes the sky/ground
   texture), so it would land higher and also stay >16.7 ms.

3. **The wall is the compositor, not the per-cell walk.** With all three big fills removed,
   comp is still 13.88 ms and non-comp 2.95 ms → 16.83 ms floor. comp (the full-screen
   multi-layer composite: decorations, sprites, and the last full-screen overlay blit)
   dominates. The tiled-fill op attacks non-comp (per-cell FRT resolution), which is only
   ~5.7 ms total and can't get the frame under budget on its own.

4. **Confounder resolved:** `BLT_OP_FILL` **is** counted under `comp` (comp dropped 1.0 ms,
   not just non-comp), and the fill is cheaper than the per-cell composite it replaced in
   both halves. GRIDOV-neutrality is consistent: the fills were already gridded (≈1 command),
   so BLEND count barely moved; the cost was fabric cell-walk + comp blend, not host commands.

## Decision gate

Spec gate: *non-comp drops ≥ 3–4 ms (~10%+ fps) → GO.* Measured: non-comp −2.79 ms (below the
bar) and **fps +0%**. → **NO-GO.** The measure-first probe prevented an RTL cycle that would
have delivered ≈0 fps on map 119.

## What this redirects toward (next investigation, not this plan)

Any real 60 fps lever for map 119 must cut the **compositor** (`comp` ~14 ms) to get the
pipeline under 16.7 ms — e.g. reducing overdraw or the cost of the full-screen per-pixel-alpha
overlay composite emitted last each frame — not the per-cell fill walk. This is a fabric
comp-throughput question, separate from the Phase-0 hypothesis, and should get its own
measure-first pass (start by attributing comp: how much is the overlay full-screen blit vs
sprites vs decoration layers).

## Cross-refs

[[solarus-stage5-fabric-fetch-bound-source-cache]] (Phase 1 cut comp 54→15 ms),
[[solarus-parallax-fabric-bound-perf]] (superseded: map 119 is vsync-paced at 30 on the ship,
not fabric-saturated), [[solarus-stage5-phase2-fb-ddr3-planned]] (the ship build measured here).
