# Stage 5 lever — grid overlap decomposition (K-grid) — design

**Date:** 2026-07-21
**Status:** design approved (brainstorm), pending spec review → implementation plan
**Supersedes:** the Stage 5 plan's assumed "RTL `tilemap_unit` prefetch" lever, which the
`2026-07-21-stage5-decision.md` measurement refuted (map 119 never walks the grid — it falls back
to per-tile replay). This spec defines the *real* lever the decision doc deferred.

## 1. Goal

Make map 119's parallax layers composite on the fabric via the existing grid-walk instead of the
per-tile BLEND replay, by teaching the **host** to decompose an overlapping static bucket into K
non-overlapping single-pid sub-grids. **Zero RTL change.** Gated `SOLARUS_GRIDOV`, default-off.

**Target:** the measured limiter — map 119 standing, ~1739 BLEND tiles/frame → `K × buckets`
grid-walk commands; fabric comp (~54 ms) collapses toward the design's one-command-per-scrolling-layer
budget. Success = a measured fps/period improvement on map 119 at `from_dungeon_10`, no correctness
regression (operator's eyes), flag-off reproducing the committed baseline exactly.

**Non-goals.** No multi-pid-per-cell cell-format change. No RTL/Quartus/timing/seed sweep (the grid
walk already composites single-pid grids with per-command blend). No new scene beyond map 119. No
change to non-overlapping buckets (they already grid) or to the replay path itself (kept as the
fallback when K exceeds GRID_BUF).

## 2. Why this is host-only (verified against current code)

- The `BLT_OP_TILEMAP` command already carries `blend[15:8]` in its command word; `blitter_top.sv`
  forwards `c_blend` to `comp_pipeline` for the TILEMAP op. Blended grids already composite in HW.
- `mister_blitter_renderer.cpp:3273` already emits `blt_grid_list(&em, tex, b.blend, b.key, 255,
  b.flags, …)` — the bucket's blend mode is already passed. **Blend is not the blocker.**
- The *sole* blocker is `mister_blitter_renderer.cpp:3087` `if (overlapped) continue;` — an
  overlapping bucket abandons the grid and replays. `blt_grid_build_ov` (grid_build.h:47-48) sets
  `overlapped=1` because a single-pid cell can only keep the last painter's-order tile.

Replacing that one fallback with a decomposition reuses `blt_grid_build`, `blt_grid_list`, the
GRID_BUF allocator, and the whole RTL grid walk unchanged.

## 3. The decomposition (correctness by construction)

**Greedy paint-order coloring.** Process the bucket's tiles in painter's (emission) order. Assign
each tile to the **lowest-indexed sub-layer whose already-placed tiles do not share any 8px cell**
with it. Emit sub-layer 0 first, then 1, … at composite time.

- **Correctness:** two tiles that overlap share ≥1 cell, so they land in different sub-layers, and
  the earlier (painter's-order) tile gets the lower index → composited first → the later tile paints
  on top. Non-overlapping tiles may share a sub-layer (disjoint pixels → no interference). This
  reproduces the replay path's painter's-order result exactly.
- **K = max overlap depth** (max tiles covering any single cell) = the greedy coloring's color count.
  Expected 2–3 for parallax; bounded and measured (§6).
- Each sub-layer is, by definition, non-overlapping → `blt_grid_build` (the existing NULL-overlapped
  entry) builds it with no changes.

## 4. Component boundaries

| Unit | Responsibility | Interface | Depends on |
|---|---|---|---|
| **`grid_decompose.h`** (new, blitter/) | greedy paint-order split of a `blt_grid_tile_t[]` into K non-overlapping sub-lists | `blt_grid_decompose(const blt_grid_tile_t*, size_t n, uint16_t gw, uint16_t gh, /*out*/ int *sublayer_of_tile, int max_k) -> int K` (or −1 if K would exceed `max_k`) | `grid_cell.h` cell dims only; pure, no allocator, no DDR |
| **`StaticBucket`** (renderer) | hold up to K grids | `grid_off[BLT_GRIDOV_MAXK]`, `grid_w`, `grid_h`, `uint8_t n_grids`, `bool grid_ok` | grid alloc |
| **res_arm_ overlap branch** (renderer:3087) | on overlap: decompose → per sub-layer build+alloc+copy K grids → `grid_ok=true,n_grids=K`; on K-over-budget or GRID_BUF-full: keep `grid_ok=false` → replay (unchanged graceful fallback) | consumes `grid_decompose.h`, `blt_grid_build`, `blt_grid_alloc_take` | GRID_BUF |
| **static emit** (renderer:3266) | if `grid_ok`: emit `n_grids` `blt_grid_list` commands, sub-layer 0..K-1, each with `b.blend`/`b.key`/`b.flags` | `blt_grid_list` | ring |

`BLT_GRIDOV_MAXK` (e.g. 8) bounds the per-bucket grid count and GRID_BUF blast radius; a bucket
needing more sub-layers than `max_k`, or whose K grids don't fit GRID_BUF, falls back to replay — no
worse than today.

## 5. Gating + fallback

- `SOLARUS_GRIDOV` env, **default-off**, parsed in the ctor next to `tilemapch`. With it off, the
  `if (overlapped) continue;` behavior is byte-for-byte the current build (true no-op → clean A/B and
  unchanged ship default until HW-proven).
- With it on, overlapping buckets decompose; every existing graceful fallback (tokenless entry,
  bounds violation, GRID_BUF full, K > max_k) still routes that bucket to replay. Never wrong, only
  slower on the tail.
- Requires `SOLARUS_TILEMAPCH` on (the grid emit is gated on `tilemapch && grid_ok`) — the shipping
  default. `SOLARUS_GRIDOV` only widens which buckets set `grid_ok`.

## 6. Testing

- **Host, bit-exact (the objective bar):** a test that builds a synthetic overlapping bucket, runs
  the replay reference (`blt_ref_*` per-tile composite) into a framebuffer, runs the K-grid path
  (`blt_grid_decompose` → K× `blt_ref_tilemap`) into a second framebuffer, and asserts the two are
  **pixel-identical**. Covers 2-deep and 3-deep overlap, painter's-order dominance, and disjoint
  tiles sharing a sub-layer. In `tests/run_tests.sh`, models engine-side logic (no renderer compile).
- **Decomposition unit tests:** K equals max stack depth; overlapping tiles get distinct ordered
  sub-layers; K > max_k returns −1 (→ replay).
- **Sizing census (Phase 1 of the plan):** a `[blitter gridov]` diag reporting per-bucket K and total
  GRID_BUF bytes on map 119, to confirm K is small and K×grids fit the 2 MB GRID_BUF (map-119 grid ≈
  80×94×4 ≈ 30 KB; K≈3 × 6 buckets ≈ 540 KB).
- **HW A/B:** capture map 119 `from_dungeon_10` with `SOLARUS_GRIDOV` off then on (reuse the Stage 5
  harness). Off = committed baseline (11.8 fps, BLEND=1739). On: `[blitter p0]` BLEND collapses,
  `[blitter hwperf]` fabric_hw drops, fps/period improves. Operator confirms map 119 renders correctly
  standing + moving (never self-declared).

## 7. Risks

| Risk | Mitigation |
|---|---|
| K larger than expected → GRID_BUF pressure | `max_k` bound + per-bucket GRID_BUF check already present → replay fallback; census (§6) measures real K first |
| Decomposition mis-orders overlapping tiles → wrong pixels | greedy in paint order is correct by construction; the bit-exact host test vs replay is the gate |
| Blended sub-grids composite differently than replay | replay and grid both drive the same `comp_pipeline` blend; the bit-exact test covers it; if a blend mode diverges, that bucket can be excluded (replay) |
| flag-off not a true no-op | the change is confined to the `overlapped` branch; off path is untouched; regression check = off reproduces baseline |
| Win smaller than hoped (grid walk still pays per-pixel BLEND) | measured, not assumed — HW A/B is the gate; even a partial fabric-cost cut is a real result the decision doc records |

## 8. Open items (resolve in the plan)

- `BLT_GRIDOV_MAXK` value (start 8; tune from the census).
- Whether `StaticBucket` stores a fixed `grid_off[MAXK]` or a small dynamic vector (prefer fixed
  array — StaticBucket has no default-member-init and lives in a hot rebuild path).
- Exact `[blitter gridov]` census fields.

## References
- `docs/superpowers/2026-07-21-stage5-decision.md` — the measurement that selected this lever.
- `patches/mister/mister_blitter_renderer.cpp:3064-3118` (build/overlap-fallback), `:3266-3280` (emit).
- `patches/mister/blitter/grid_build.h` (overlap detection), `grid_cell.h` (single-pid format),
  `blt_emitter.h` (`blt_grid_list`), `blitter_ref.h` (`blt_ref_tilemap` golden walk).
- CLAUDE.md tilemap-channel note (overlap fallback, GRID_BUF-relative `cells_off`).
