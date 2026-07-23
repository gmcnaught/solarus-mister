# Map 119 parallax perf — productize GRIDOV as the coalescing lever

**Date:** 2026-07-23
**Branch:** `feat/map119-tiled-fill`
**Status:** design approved (approach: productize directly; scope: global default-on + broad validation)

## Goal

Cut map 119's compositor cost toward the 16.7 ms / 60 fps threshold by
replacing its ~11,764 uncoalesced resident-replay blits/frame with the
existing `SOLARUS_GRIDOV` decompose→grid path — which obtains 2D
run-coalescing for free — validated pixel-correct and shipped default-on.

## Background — the measured bottleneck

Map 119 is the quest's only real parallax scene, vsync-paced at 30 fps.
Phase-0 attribution (`docs/superpowers/specs/2026-07-23-map119-comp-attribution-phase0-design.md`)
sized `comp` ≈ 14.89 ms as:

| slice | cost | mechanism |
|---|---|---|
| **tilemap (resident tile-list replay)** | **~12.9 ms (87%)** | 11,764 blits/frame, **one blit per tile, no coalescing** |
| overlay (full-screen PALPHA) | ~1.96 ms (13%) | measured via overlay-off A/B |
| sprite / fill | ~0 ms | negligible |

The COMPTRACE cross-check (0.53) splits the ~12.9 ms tilemap slice roughly in
half: **~5–7 ms per-tile overhead** (recoverable by coalescing) and **~5–7 ms
raw pixel writes** (~3.25× parallax overdraw; NOT coalescable). The coalescing
half is the single biggest reducible chunk.

## Root cause — why parallax lands on the uncoalesced path

Confirmed in `patches/mister/mister_blitter_renderer.cpp`:

- Per static bucket, `res_arm_()` builds a grid and calls `blt_grid_build_ov`
  (`:3323`), which sets `overlapped=1` when two tiles paint the same 8 px cell
  (`grid_build.h:47-48`).
- map 119's composited **parallax items overlap within the bucket** — the code
  comments name map 119 explicitly (`:3344-3349`, `:2504-2506`). With
  `SOLARUS_GRIDOV` **off (today's default)** the overlapping bucket `continue`s
  to `grid_ok=false` → `resident_emit_static_layer()` (`:3590-3611`) takes the
  resident TILELIST replay branch (`res_emit_static_bucket_`, `:3489-3509`),
  which emits **one 12-byte entry per tile with no run-merging** (`b.hw_count`
  = raw entry count, `:3275`).
- `SOLARUS_GRIDOV=1` instead **decomposes** the overlapping bucket into K
  non-overlapping paint-order sub-layer grids (`blt_grid_decompose`,
  `grid_decompose.h:19`; emit at `:3357-3413`), each an `OP_TILEMAP` grid.
- **Coalescing is intrinsic to the grid structure**, not to any content:
  `blt_grid_build_ov` pass 2 (`grid_build.h:53-75`) bakes a per-cell run length
  into the cell word, and the fabric walker issues one `run×8`-wide blit per run
  (`blitter_top.sv:411-416`, `S_GRID_SLICE` `c_w <= g_run << 3`). So **any
  content expressed as a grid coalesces for free** — including the decomposed
  sub-layers. GRIDOV is exactly the mechanism that recovers the ~5–7 ms.

**Consequence:** the lever is not new code — it is validating and enabling an
existing, deliberately-off, unvalidated path.

## Two gates on GRIDOV today

1. **Correctness prerequisite (hard).** The `OP_TILEMAP` `blt_grid_list`
   emitter is missing its SDRAM-source mux on this branch — gridded tiles read
   the atlas from the DDR3 heap instead of staged SDRAM = **garbage** (the
   "door-roof garbage" class, `solarus-tilemap-grid-sdram-mux-bug` memory). The
   fix is `6be6a28` on `origin/master`, **not on `feat/map119-tiled-fill`**
   (verified: `git merge-base --is-ancestor 6be6a28 HEAD` → NO; branch is 31
   behind / 24 ahead). Its decompose companions `25c1fa3` and `88c6385` **are**
   present. GRIDOV pixels are garbage until `6be6a28` lands here.
2. **Unvalidated default.** GRIDOV is `getenv`-presence-gated (`:2512`),
   deliberately NOT `mister_flag_default_on` ("an opt-in lever, not a validated
   default"). We have never confirmed its pixels on map 119 or elsewhere.

## Approach — productize directly (5 tasks)

Chosen over a cheap count-only pre-check: land the prerequisite, validate
pixels, and get a real fps number in one cycle. Task 2's instrument surfaces
the coalescing win/cost early *inside* that cycle rather than as a separate
pre-check.

### Task 1 — land the SDRAM-mux prerequisite

- **Cherry-pick `6be6a28`** onto `feat/map119-tiled-fill` (single commit, not
  the full 31-behind sync — minimizes conflict surface and blast radius).
- This is the exact fix the concurrent **door-roof rendering session** owns —
  coordinate timing so the two sessions don't both move it. If that session has
  already merged it to master under a different SHA, cherry-pick whatever SHA
  carries the `blt_grid_list` SDRAM mux and note it.
- **Verify** with the existing grid cross-check host test
  (`bash tests/run_tests.sh` — the grid-walk equivalence / SDRAM-mux test that
  ships with `6be6a28`). Expect PASS.

### Task 2 — instrument the decomposition (win + cost)

The decompose path **already logs** `[blitter gridov] layer=%d K=%d bytes=%u`
per bucket (`:3411`) — K sub-layers and GRID_BUF bytes are free. What is missing
is **Σ coalesced runs** across the K sub-layers (the fabric blit count that
replaces the 11,764 resident blits). GRIDSTATS already computes runs per grid via
`blt_grid_stats` (`grid_stats.h`).

- With `SOLARUS_GRIDOV=1 SOLARUS_GRIDSTATS=1`, ensure GRIDSTATS emits its
  `nonempty/empty/runs` line **for each decomposed sub-layer grid** (not only
  for natively-griddable buckets). If the existing GRIDSTATS emit site only
  covers `grid_ok` buckets, extend it to also walk the K sub-layer grids of a
  GRIDOV-decomposed bucket. Reuse `blt_grid_stats`; no new walk logic.
- **Deliverable metric:** Σruns across all map-119 buckets (target: well under
  11,764) and Σ GRID_BUF bytes (must fit the 2 MiB `GRID_BUF_BYTES`, `:458`).

### Task 3 — flip GRIDOV to a validated default-on

- Change `:2512` from `std::getenv("SOLARUS_GRIDOV") != nullptr` to
  `mister_flag_default_on("SOLARUS_GRIDOV")` (returns true unless the value
  starts with `'0'`; `SOLARUS_GRIDOV=0` forces off). Matches how the other
  channels ship.
- Update the adjacent comment (`:2510-2511`) from "opt-in lever, not a validated
  default" to reflect the validated default-on status + this spec.
- **Keep every graceful fallback** so worst case degrades to today's resident
  replay, never garbage or crash: `pid==0xFFFF` tokenless (`:3315/3320`),
  `blt_grid_build_ov` bounds violation (`:3323-3325`), decompose K==-1 >
  `BLT_GRIDOV_MAXK`=8 (`:3368`), GRID_BUF full mid-decompose (`:3404`), and
  final allocation failure (`:3417-3422`).

### Task 4 — HW pixel-correctness validation (operator's eyes)

Default-on decomposes **every overlapping bucket quest-wide**, not just map 119.
Per `solarus-no-self-declared-visual-validation`, the operator (user) confirms
visual correctness — I do not self-declare. Validation matrix, GRIDOV-on:

| scene | why it's in the matrix |
|---|---|
| map 119 parallax | the target scene |
| door-roofs (interior) | the overlap case `6be6a28` targets — highest-risk pixels |
| interior walls | overlapping static tiles, non-parallax |
| plain overworld | broad regression check for the global default flip |

Any garbage on any scene is a **blocker** → do not ship default-on (Task 5 gate).

### Task 5 — fps A/B + combination + decision gate

Standing map 119, fixed spot `("119","from_dungeon_10")`, single-engine
discipline, same ship RBF (`Solarus_20260723.rbf`):

- **Leg A (baseline):** `SOLARUS_GRIDOV=0` — resident replay.
- **Leg B (lever):** GRIDOV on (default). Read `comp`, `fabric_hw`, `fps` from
  the `[blitter hwperf]` banner.
- **Combination:** GRIDOV on + bgfill (`SOLARUS_BGFILLPROBE` / PR #140's 3.8 ms
  fabric cut) — the stacked path toward 60 fps.
- Reuse `scripts/perf/bgfillprobe_ab.sh` as the A/B harness template.

**Decision:**
- GRIDOV-on **pixel-correct on all Task-4 scenes** AND (alone or with bgfill)
  crosses / meaningfully approaches 16.7 ms / 60 fps → **keep default-on**, ship.
- Correct but a net win short of the threshold → keep default-on if it's a clear
  net win; document the residual against the 60 fps wall.
- Garbage on any scene, or a regression → **revert to opt-in** (`getenv` gate),
  document a NO-GO with the failing scene, keep the prerequisite fix.

## Risks

- **GRID_BUF budget.** `GRID_BUF_BYTES` = 2 MiB ≈ 1.5× a single worst-case map
  (`:458`); it does NOT hold two full worst-case maps co-resident. A bucket
  decomposing into K≤8 sub-layers multiplies that bucket's grid bytes by K.
  Default-on quest-wide raises the ceiling on other maps too. Mitigation: the
  GRID_BUF-full fallback is graceful (→ replay, no garbage), and Task 2's
  `bytes=` metric surfaces pressure. If map 119 (or a validation map) overflows,
  the fix is a GRID_BUF size bump (the `:458` comment already flags ≥3 MiB for
  the two-map scroll case) — a follow-up, not a blocker for the perf finding.
- **Branch divergence.** 31 commits behind origin/master. Cherry-picking the
  single `6be6a28` avoids a disruptive full sync but may conflict; if it does,
  resolve minimally against `blt_grid_list` only.
- **Concurrent door-roof session** owns `6be6a28`. Coordinate the cherry-pick so
  both sessions don't move the same fix.
- **Coalescing may not materialize** (the risk taken on by skipping the
  count-only pre-check): if parallax is too overlap-dense, decompose yields high
  K with poor per-sub-layer coalescing and Σruns stays near 11,764 — no win.
  Task 2 surfaces this before Task 5's fps A/B; a documented NO-GO is the
  outcome if so.

## Out of scope

- The ~5–7 ms pixel/overdraw half of the tilemap slice (occlusion cull) — a
  separate, harder lever with its own hard floor.
- Overlay-shrink (< 1.96 ms recoverable) — minor additive, not worth its own RTL.
- Any per-map / per-bucket GRIDOV scoping mechanism — global default-on chosen.

## Cross-refs

- Phase-0 attribution + sizing:
  `docs/superpowers/specs/2026-07-23-map119-comp-attribution-phase0-design.md`.
- SDRAM-mux bug: `solarus-tilemap-grid-sdram-mux-bug` memory; fix `6be6a28`.
- GRIDOV code: `mister_blitter_renderer.cpp` `res_arm_()` (`:3298-3436`),
  `resident_emit_static_layer()` (`:3590-3611`), `BLT_GRIDOV_MAXK`=8 (`:718`),
  `blt_grid_decompose` (`grid_decompose.h`), `blt_grid_build_ov` /
  `blt_grid_stats` (`grid_build.h`, `grid_stats.h`).
- A/B harness: `scripts/perf/bgfillprobe_ab.sh`; single-engine launch:
  `scripts/perf/stage5_device_launch.sh`.
- Visual-validation rule: `solarus-no-self-declared-visual-validation` memory.
