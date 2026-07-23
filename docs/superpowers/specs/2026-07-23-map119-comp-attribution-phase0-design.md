# Map 119 compositor attribution + gated cull — design

**Date:** 2026-07-23
**Branch:** `feat/map119-tiled-fill`
**Depends on:** COMPTRACE attribution (PR #140), bgfill probe (PR #140,
`SOLARUS_BGFILLPROBE`), ship RBF `Solarus_20260723.rbf` (Stage 5 Phase 2).
**Supersedes premise:** the "comp is ~96% overdraw" lever assumption — refuted by
direct capture (see Motivation).

## Motivation — what the COMPTRACE capture actually showed

One settled-scene COMPTRACE capture of map 119 standing (`from_dungeon_10`, ship
RBF, `docs/superpowers/data/stage5/comptrace-map119.log`) attributes the composited
dst-area by category. Corrected to steady state (the build-frame capture includes a
transient full-screen transition-fade `fill` — `blend=BLEND op<255`, present in
*both* captured blocks; the two tilemap/overlay categories are frame-invariant for a
static standing scene, so the fade fill is subtracted analytically, not by re-capture):

| category | dst-px | % steady | note |
|---|---|---|---|
| tilemap | 249,616 | 76.2% | 11,764 host logical cells (10,393 are 8×8); layers 0/1 (ratio 1) + parallax layer 2 (ratio 2), all `BLT_BLEND_COLORKEY` |
| overlay | 76,800 | 23.4% | one full-screen `BLT_BLEND_PALPHA` RMW, every frame |
| sprite | 1,344 | 0.4% | negligible |

- **Steady comp = 14.93ms (72% of fabric_hw 20.66ms), comp_cyc ≈ 1,469,672.**
- **Cross-check ratio = 0.53** (`traced dst-px 327,760 / modeled 617,509 @2.38 cyc/px`).
  A ratio well below 1.0 means **dst-area accounts for only ~half of comp's
  cycles**; the other ~half is per-cell/per-run/per-blend overhead the dst-area
  model does not capture. **comp is NOT overdraw-bound.** A pure overlap/overdraw
  cull is therefore capped at roughly half of comp.

### Two fabric facts found while scoping the RTL

Reading `fpga/rtl/blitter_top.sv` (the `BLT_OP_TILEMAP` grid walker):

1. **Horizontal run-coalescing already exists.** The walker issues one `run×8 × 8`
   blit per run of identical adjacent patterns (`g_run` = 1..16 cells, line
   1191/1202). The "merge tilemap runs into wider blits" RTL idea is already spent.
   The 11,764 figure is the host *logical* cell count, not the fabric blit count.
2. **Empty cells are walked one at a time.** An empty cell costs a `GRID_BUF`
   memory fetch (`S_GRID_FETCH`) + `S_GRID_DECODE`, advancing a single column, with
   no blit (lines 1171–1182). Sparse upper parallax layers (mostly-empty grids) pay
   a fetch-per-empty-cell tax. Each non-empty run additionally pays a CFT/FRT
   resolve (`S_TLR_CFT`/`S_TLR_FRT`).

So there are **two grounded but unranked reducible levers** — the tilemap
empty-walk/resolve overhead (RTL) and the full-screen PALPHA overlay RMW (engine) —
and the dst-area attribution cannot say which owns comp's non-overdraw half.
Committing an RBF (or an engine cull) to the wrong one is the same blind-build trap
that the bgfill measure-first probe already caught once (bgfill NO-GO). Hence a
measurement gate.

## Approach — measure-gated two phases

### Phase 0 — attribute comp's 14.9ms (no RBF)

Goal: **rank** the reducible slices well enough to pick the Phase-1 lever — rough
magnitudes, not exact ms. Three cheap, hardware-safe measurements.

**0.1 Overlay PALPHA cost — engine A/B (direct).** A temporary default-off probe
`SOLARUS_OVERLAYNOCOMP` (cached-getenv; same convention as `SOLARUS_COMPTRACE`)
skips **only** the final `blt_blit(...PALPHA...)` in `emit_overlay_composite` (HUD
vanishes — acceptable for a perf probe). Standing map-119 A/B (off vs on); `Δcomp` =
the overlay's exact comp ms. This is the one slice measurable directly and cleanly.

**0.2 Tilemap grid stats — engine dump (no RBF).** Dump the real map-119 `GRID_BUF`
the host builds, per layer: non-empty cell count, empty-cell count walked, and a
run-length histogram. This exposes the empty-cell density and run count that drive
the fabric walk — what dst-area could not see.

**0.3 Fabric cycle model — analytic, calibrated by one sim run.** Cost each FSM
phase from the RTL: empty cell ≈ fetch+decode cycles (no blit); non-empty run ≈
CFT/FRT resolve + `run_w×8` px through the issue-interval-1 comp_pipeline + drain.
Confirm the per-state cycle constants with a **single** `tb_tilemap`/
`tb_comp_pipeline` sim run (no hardware — calibration only, not a full grid replay;
this is what keeps Phase 0 from ballooning). Then:
`tilemap ms = comp − overlay − sprite`, split into **empty-walk / resolve /
pixel-blit** via (grid stats × calibrated constants).

**Phase 0 deliverable / gate:** comp's 14.9ms broken into
`{overlay-PALPHA, tilemap-empty-walk, tilemap-resolve, tilemap-pixels, sprite}`,
ranked. A positive-if-zero case: overlay `Δcomp ≈ 0` (fabric already early-outs
transparent PALPHA src) *eliminates* the overlay lever and points Phase 1 at the
tilemap — a useful result, not a failure.

### Phase 1 — the gated cull (branch-not-designed until Phase 0)

Committing a lever before the ranking is the trap. Candidate levers, pre-scoped,
each shipped behind its own default-off `SOLARUS_*` flag (cached-getenv, no-op when
unset) so it is independently A/B-able:

| Phase 0 says biggest slice is… | Phase 1 lever | cost |
|---|---|---|
| overlay-PALPHA | **overlay shrink-to-dirty-rect** — emit the overlay blit clipped to the root's non-transparent bbox, not full 320×240 | engine-only, current RBF |
| tilemap empty-walk | **empty-run skipping** — encode empty spans so the walk skips N empty cells per decode | RTL, RBF + HW re-val |
| tilemap resolve | **resolve caching / wider coalesce** — cache last-pid CFT/FRT across adjacent runs, or lift the 16-cell `g_run` cap | RTL, RBF |
| tilemap pixels (true overdraw) | **occlusion cull** of fully-covered lower-layer runs (host-side) | engine-only |

**Success criterion — the combination A/B.** Neither lever alone is expected to move
fps (map 119 is vsync-paced at 30; 16.7ms is a hard threshold, not a continuum).
The real test is the **both** leg: the Phase-1 lever **+** `SOLARUS_BGFILLPROBE`
(PR 140's 3.8ms) together. Success = `fabric_hw < 16.7ms` **AND** `[blitter timing]
fps` climbs toward 60 with `sleep` *not* absorbing the saving. If it holds,
productionize **both** as an additive pair (the real bgfill op + the Phase-1 cull).

**Stop condition (documented NO-GO).** If Phase 0 shows the biggest slice is small
enough that no single lever + bgfill can plausibly cross 16.7ms, Phase 1 is a
documented NO-GO: map 119 stays 30fps, we bank the attribution, and do not chase
sub-ms levers. A legitimate outcome, same as the bgfill NO-GO.

## Testing & validation

**Phase 0 correctness (host + sim, pre-hardware):**
- **Overlay-off probe** — host test asserting the gate skips *only* the final PALPHA
  composite emit (all other frame commands byte-identical off vs on), and that unset
  is a true no-op (emitter output unchanged).
- **Grid-stats dump** — host test on a known synthetic grid (dense + sparse layers)
  asserting empty/non-empty/run-length counts match hand-computed expectations.
- **Fabric cycle calibration** — extend `tb_tilemap` with per-state cycle counters;
  assert counted cycles-per-empty-cell and cycles-per-run match the FSM cost model.

**Phase 0 result validity (hardware):** overlay A/B on the fixed map-119 spot,
standing, single-engine discipline. Cross-check that
`overlay ms + derived tilemap ms + sprite ≈ comp 14.9ms` — if the slices do not sum
to comp, the model is wrong; stop and fix before Phase 1.

**Phase 1 validation (per lever):**
- Engine-only lever → host test (no-op-when-unset + correctness), HW A/B, and an
  operator **visual HUD/scene check** (never self-declare visual correctness —
  `solarus-no-self-declared-visual-validation`).
- RTL lever → fabric TB proves cycle reduction **and** bit-exact composite output in
  sim first, then RBF build + STA/fit + operator HW A/B.
- Both → the combination A/B against 16.7ms is the final gate.

**Standing discipline throughout:** every capture kills the auto-launch daemons +
prior engine first (two-engine wedge), logs under `/media/fat/logs`, pins the ship
RBF `Solarus_20260723.rbf`. Build via the host-apply + `SOLARUS_SKIP_APPLY=1`
Docker-compile workaround; deploy refreshes `deploy/` from `build/armhf` before
`deploy.py --no-rbf`; verify the new symbol + mtime in the built lib.

## Cross-refs

- Capture + analyzer: `docs/superpowers/data/stage5/comptrace-map119.log`,
  `docs/superpowers/data/stage5/comptrace-map119-report.txt`,
  `scripts/perf/comp_overdraw.py`.
- Runbook (Task 4 of the attribution plan):
  `docs/superpowers/plans/2026-07-23-map119-comptrace-runbook.md`.
- bgfill NO-GO precedent + numbers:
  `docs/superpowers/2026-07-22-map119-bgfillprobe-attribution.md`.
- Fabric grid walker: `fpga/rtl/blitter_top.sv` (`S_GRID_*`, `g_run`),
  `fpga/rtl/comp_pipeline.sv`, `fpga/sim/tb_tilemap.sv`.
- Memory: `solarus-map119-bgfill-attribution`, `solarus-quest-tilemap-census`,
  `fpga-comp-pipeline-cycle-profile`.
