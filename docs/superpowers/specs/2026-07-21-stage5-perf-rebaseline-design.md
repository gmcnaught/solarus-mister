# Stage 5 — Performance Re-baseline + First Lever — design

**Date:** 2026-07-21
**Status:** design approved (brainstorm), pending spec review → implementation plan
**Supersedes/continues:** the retained-scene compositor roadmap
(`specs/2026-07-17-retained-scene-compositor-design.md`). Stages 1–4 (Overlay,
Sprite, Tilemap, Delete-dead-paths) are merged + HW-validated; the correctness
migration arc is closed. This stage opens the **performance** axis the master
design explicitly deferred (§5 "Simulation-bound … unchanged by rendering" +
§7 "Stage-3 acceptance measurement").

---

## 1. Goal

Establish an honest, reproducible performance baseline of the **completed**
retained-scene architecture on the canonical fabric-acceptance scene (map 119
parallax), confirm or refute the Stage 3b fabric win, and land the single
**limiting** lever end-to-end — host or RTL, whatever the data says —
HW-validated and gated.

This stage is deliberately narrow: **one scene, one decision, one lever.** It
values a measured win over breadth. Additional scenes and additional levers are
follow-up stages.

**Non-goals.** No new rendering feature. No broad multi-scene perf survey (map
119 only — it is the §7 acceptance scene and the one scene whose result both
validates the Stage 3b fabric fix and points at the next lever). No second lever
this stage. No scanout change (the direct `comp_fbram` path stays, per the master
design §3 and memory `solarus-scanout-avoid-ascal-direct-path`).

---

## 2. Why map 119, why now

The pre-tilemap HW profile (memory `solarus-parallax-fabric-bound-perf`,
2026-07-12) split MoSDX into two bottleneck classes:

- **Parallax map (map 119): FABRIC-bound** — ~14.7 fps, period ~68 ms, fabric
  ~35 ms saturated, `1,500 BLEND draws/frame` (parallax layers composited
  per-tile with BLEND every frame, **not** baked).
- **Dense town: A9-bound** — ~28.7 fps, A9 ~17 ms (emit 5.1 + eng_cpp 8.6).

Stage 3b's `BLT_OP_TILEMAP` grid-walk was **the** fabric-side fix for the
parallax saturation: static tile layers composite as one grid-walk command per
bucket instead of ~1,500 per-tile BLENDs. **It has never been perf-measured.**
The master design §7 named the acceptance test precisely — "measure
`tilemap_unit` cyc/px on the parallax overworld; target ≤ 3.0 cyc/px on a full
layer." That measurement is this stage's job.

Map 119 alone answers the pivotal question two ways at once:
1. Did the grid-walk collapse the fabric cost? (`[blitter p0]` BLEND count → near
   zero; `fabric_hw_ms` → well under budget.)
2. If yes, what limits map 119 *now* — fabric residual or the A9 sim/emit cost?
   That verdict selects the lever.

Per the tilemap census (`solarus-quest-tilemap-census`), map 119 is the quest's
**only real parallax scene**, so it is both the worst case and the acceptance
case.

---

## 3. Architecture — four gated phases

Each phase is a hard gate on the next. Phases 1–3 are host-only on the deployed
B2/B3 tilemap RBF (no RTL, no Quartus). Phase 4 may be host **or** RTL depending
on Phase 3's verdict.

```
Phase 1  Instrument   derive tilemap cyc/px from existing counters (host-only)
Phase 2  Measure      deploy current engine+RBF; capture map 119 standing+moving
Phase 3  Decide       apply the fork rule → name limiter → scope ONE lever → commit decision doc
Phase 4  Land+validate implement the lever gated (default-off); HW A/B; operator visual gate
```

### Phase 1 — Instrument (host-only, existing RBF)

The existing on-silicon attribution is **whole-fabric + whole-compositor**, not
per-op:

- `[blitter hwperf]` publishes, per 60-frame window: `fabric_hw ms` (total fabric
  busy, from `C_DONE+4`), `comp ms` (comp_pipeline subset, from `C_STATUS+4`),
  `comp%`, `cyc/frame`, and a FABRIC-or-A9-bound verdict
  (`patches/mister/mister_blitter_renderer.cpp` ~3685–3700, `FABRIC_HZ =
  98.4375e6`).

There is **no `tilemap_unit`-specific counter.** The §7 acceptance metric is
derived rather than added:

- **Derivation.** On a controlled **standing** map-119 frame, the compositor work
  is dominated by the static tilemap grid-walk. `cyc/px ≈ comp_cyc_per_frame ÷
  composited_tilemap_pixels`, where the pixel count is reconstructed from the grid
  dims × cell size reported by `[blitter resident]`. Cross-check against the §5
  budget (≤ 3.0). This needs **no RTL** — it reuses `C_STATUS+4` (comp cycles)
  already published every frame.
- **Escalation clause (bounded).** Add a dedicated fabric cyc/px counter (RTL →
  new RBF) **only if** the derived number lands ambiguously within **±0.3 of
  3.0** (i.e. the derivation can't cleanly say pass/fail). Above 3.3 or below 2.7
  the derivation is decisive and no RTL counter is built. This keeps the common
  case host-only.

**Deliverable:** a `[blitter tmperf]`-style derived line (or a small host
post-processing note over the captured banners) reporting map-119 tilemap cyc/px.
If a pure post-processing derivation over existing banners suffices, no engine
change is needed at all for Phase 1.

### Phase 2 — Measure (host-only, existing RBF)

**Scene:** map 119, two states.
- **Standing** — pure fabric composite cost; no scroll offset change, no sprite
  churn, no moving-tear vblank barrier. Isolates the fabric / tilemap grid-walk.
- **Moving** — held dpad direction; adds per-frame scroll offsets, sprite-list
  churn, and the anti-tearing vblank barrier. The standing→moving delta exposes
  the A9 emit + sim cost.

**Reproducible self-driven drive** (no operator needed for *capture*; operator
only for the final visual gate):
- Boot via the safe launch recipe (memory
  `solarus-two-engines-wedge-launch-recipe`): leave `/media/fat/config/Solarus.s0`
  **empty**, load the core, then launch with the `S0_FILE` override; log to
  `/media/fat/logs/Solarus/` (not `/tmp`, wiped on restart). Exactly one
  `solarus-run` on the fabric (two engines wedge the host).
- Drive with the held-open-FIFO `-lua-console=yes` harness (memory
  `solarus-84-luaconsole-teleport-repro`): `hero:teleport` to map 119 at a fixed
  destination for the standing sample; inject a held direction for the moving
  sample. Same map + same destination + same direction ⇒ reproducible A/B across
  builds.

**Metrics captured** (all already emitted; gate on `SOLARUS_BLITTER_DIAG`):

| Banner | Fields used |
|---|---|
| `[blitter timing]` | fps, period, **fabric ms, A9 ms**, sleep, pipeline_ceiling, jitter |
| `[blitter hwperf]` | **fabric_hw ms, comp ms, comp%, cyc/frame**, FABRIC-or-A9 verdict |
| `[blitter p0]` | draws, BLEND/ADD/MUL counts (confirm parallax now = `BLT_OP_TILEMAP`, not per-tile BLEND) |
| `[blitter engcpp]` | eng_cpp = entities/hero split (the A9 sim residual) |
| `[blitter resident]` | bucket / pattern / grid-vs-overlap-fallback counts (how many map-119 buckets took the grid path) |

Baseline is captured against **today's HEAD, no engine change**, so the numbers
are the true post-migration state. At least 3 clean 60-frame windows per state,
same spot, for stability.

### Phase 3 — Decide (the fork rule)

Applied to the **standing** numbers, with the **moving** delta as tiebreak:

| Data signature | Limiter | Lever family (Phase 4) |
|---|---|---|
| `fabric_hw_ms > a9_ms` AND still fabric-saturated (period well above the 16.7 ms budget on fabric alone) | **Fabric** — grid-walk fetch efficiency | **RTL: `tilemap_unit` prefetch** — burst multiple cells / wider linebuf / skip-transparent-run (§7: "lever = prefetch, never clock"). New RBF. |
| `a9_ms > fabric_hw_ms` AND `[blitter p0]` confirms BLEND collapsed (grid path live) | **A9** — split by `[blitter engcpp]` | **Host:** `eng_cpp/entities` dominant → enemy per-update lever (skip `quadtree->move` w/o cell-cross; cache `update_ground_below`; prune obstacle test — memory `solarus-enemy-per-update-cost-simd`). `emit` dominant → residual emit-walk collapse. |
| Fabric ≈ A9, both well under budget, fps already ~60 | **Neither** — win already banked by Stage 3b | No lever; stage closes as a *validation* of the migration and records the next-frontier scene (e.g. dense town) for a follow-up stage. |

**Anti-bias discipline:** the decision doc — raw banners, derived cyc/px vs 3.0,
verdict, and the one selected lever with its expected magnitude — is committed
**before** any lever code, so the measurement is not retrofitted to justify a
pre-picked lever.

**One lever only.** If two candidates appear, land only the highest-leverage one
(the leverage model: per-*step* cost pays super-linearly because Solarus runs a
fixed 100 Hz tick with MainLoop catch-up — fewer catch-up steps at higher fps).
A second lever is a follow-up stage.

### Phase 4 — Land + validate

**Gating (both branches).** New `SOLARUS_<LEVER>` env flag, **default-off**,
wired via the existing `mister_flag_*` convention. `=0` is a true no-op / exact
prior behavior, so A/B is clean and the ship default is unchanged until HW-proven.

**Host-branch path:**
host-test the pure logic in `tests/run_tests.sh` → `-std=c++11` type-check
(mandatory `-DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO`) → armhf Docker build
(`scripts/build_engine.sh`) → deploy `./deploy.py --no-rbf` → HW A/B same map-119
spot (flag off vs on) → operator visual gate (behavior-neutral: same movement/AI
at normal speed).

**RTL-branch path:**
`tilemap_unit`/grid-walk prefetch change → `fpga/sim` structural-diff vs a golden
grid-walk (bit-exact, the #24 60/60 pattern) → Quartus build → **STA timing
closure + seed sweep** (Cyclone V SE is near its ~100 MHz ceiling; negative-slack
builds have occurred — the RBF must close positive) → new
`Solarus_YYYYMMDD.rbf` → deploy engine+RBF → HW A/B → operator visual gate.

**Success bar:** a **measured** fps/period improvement on map 119 at the selected
state, with the limiter metric moved in the predicted direction (cyc/px down for
RTL; the dominant A9 sub-cost down for host), and no correctness regression under
the operator's eyes. The repo rule holds: **never self-declare visual
correctness** — the final gate is the operator.

---

## 4. Component boundaries

| Unit | Responsibility | Interface | Depends on |
|---|---|---|---|
| **Capture harness** (scripts) | boot map 119 reproducibly, drive standing+moving, collect banners | in: quest + teleport target + direction; out: raw banner logs | safe-launch recipe, lua-console FIFO harness, existing diag banners |
| **cyc/px derivation** (host post-process or `[blitter tmperf]`) | turn `comp cyc/frame` + grid dims into tilemap cyc/px | in: `[blitter hwperf]` + `[blitter resident]` lines; out: cyc/px vs 3.0 | existing `C_STATUS+4` counter (no RTL) |
| **Decision doc** (`docs/superpowers/`) | apply the fork rule, name the limiter, scope one lever | in: captured banners; out: committed verdict + lever scope | Phase 2 data only |
| **The lever** (host **or** RTL, TBD by Phase 3) | the one behavior-neutral optimization | gated `SOLARUS_<LEVER>` flag; `=0` = exact prior behavior | its branch's build/test chain |

Each is independently testable: the harness by "does it reach map 119 and emit
banners"; the derivation by a known synthetic banner set; the decision by the
committed data; the lever by its host test / fabric sim + HW A/B.

---

## 5. Testing strategy

- **Phase 1 (derivation):** validate the cyc/px formula against a synthetic
  `[blitter hwperf]`+`[blitter resident]` pair with known dims (unit-checkable,
  no hardware).
- **Phase 2 (capture):** reproducibility check — two independent runs at the same
  spot agree within window jitter; `[blitter p0]` BLEND count confirms the grid
  path is actually live (guards against measuring a fallback-replay scene by
  accident).
- **Phase 3 (decision):** the fork rule is deterministic given the numbers; the
  doc is the artifact.
- **Phase 4 (lever):**
  - Host branch: pure-logic host test in `tests/run_tests.sh`; `-std=c++11`
    type-check; armhf build links; HW A/B shows the predicted metric move + fps
    delta; operator visual gate.
  - RTL branch: `fpga/sim` bit-exact grid-walk vs golden (#24 60/60 pattern);
    positive STA across the seed sweep; HW A/B; operator visual gate.
- **Regression guard:** flag-off must reproduce the Phase-2 baseline numbers
  (proves `=0` is a true no-op).

---

## 6. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Derived cyc/px ambiguous near 3.0 | bounded escalation clause (±0.3) → add a dedicated fabric counter only then |
| Measuring a fallback-replay scene, not the grid path | `[blitter p0]` BLEND count + `[blitter resident]` grid/fallback split gate the capture as valid |
| Two engines wedge the host | safe-launch recipe: empty `Solarus.s0`, one engine, `S0_FILE` override, log to `/media/fat/logs` |
| RTL lever misses timing (Cyclone V SE ceiling) | STA + seed sweep is a hard gate; prefetch, never clock (§7); if it won't close, the lever is descoped and the decision doc records "fabric lever blocked on timing → revisit" |
| Self-declared visual correctness | operator-gated final check, per repo rule |
| Non-reproducible drive | fixed teleport destination + fixed held direction; ≥3 windows/state; two-run agreement check |

---

## 7. Open items (resolve during planning / execution)

- Fixed map-119 teleport **destination + held direction** for the standing/moving
  samples (pick during Phase 2 harness bring-up; record in the decision doc for
  future A/B reproducibility).
- Whether Phase 1 derivation is pure host post-processing over logs or a small
  `[blitter tmperf]` engine line (decide once the exact grid-dim fields available
  in `[blitter resident]` are confirmed — prefer no engine change if the logs
  already carry the dims).
- The precise A9 sub-lever (enemy vs emit) is intentionally left to Phase 3 —
  it is data-selected, not pre-decided.

## References

- `specs/2026-07-17-retained-scene-compositor-design.md` — master roadmap (§5
  buckets, §7 acceptance measurement) this stage continues.
- `patches/mister/mister_blitter_renderer.cpp` — `[blitter timing/hwperf/p0/engcpp/resident]`
  banners (~3370–3700); `C_DONE+4` / `C_STATUS+4` fabric counters (~1186).
- Memory `solarus-parallax-fabric-bound-perf` — the pre-tilemap map-119 = FABRIC-bound baseline.
- Memory `solarus-enemy-per-update-cost-simd` — the A9-branch lever candidates (move-dominant, quadtree/ground churn).
- Memory `solarus-quest-tilemap-census` — map 119 = the only real parallax scene.
- Memory `solarus-84-luaconsole-teleport-repro` — the self-driven teleport harness.
- Memory `solarus-two-engines-wedge-launch-recipe` — the safe single-engine launch.
- Memory `solarus-scanout-avoid-ascal-direct-path` — scanout stays direct (out of scope).
