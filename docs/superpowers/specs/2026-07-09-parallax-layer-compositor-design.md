# Per-layer ARGB4444 plane bake: fixing the base-layer-parallax perf cliff

## Problem

PR #79 (`docs/superpowers/specs/2026-07-08-bgplane-base-layer-occlusion-design.md`)
restricted `SOLARUS_BGPLANE`'s flattened-plane optimization to a map's base
layer (`map.get_min_layer()`) to fix cross-layer occlusion, and disqualifies
the optimization for the *entire map* whenever the base layer has any
parallax content (`scroll_ratio != 1`) — confirmed on Mystery of Solarus DX
map 119, where the parallax pattern shares `layer = 0` with the map's own
`min_layer = 0` static ground.

Disqualification doesn't just cost the parallax layer its speedup — it falls
back to per-bucket `BLT_OP_TILELIST` replay for *every* layer, including the
base layer's own static ground, which is the specific case BGPLANE (PR #77)
exists to accelerate. HW-measured `fabric_hw`: map 4 (BGPLANE fully engaged)
~9.2ms; map 119 (disqualified) ~52.8ms — over 3x the 16.7ms/60fps budget,
worse than the ~20ms pre-BGPLANE baseline PR #77 was built to beat.

Correctness is non-negotiable (per explicit project priority), so the fix
must not reintroduce bug #1 (cross-layer occlusion) or bug #2 (parallax
paint order) while recovering the performance the disqualification gives up.

## Root cause

The disqualification exists because the baked plane has no way to represent
"nothing was drawn here." It bakes as opaque RGB565, filling gaps with the
tileset's background color (`patch 0033`,
`MisterBlitterRenderer::Impl::bg_clear_rgb565`) so the plane's later
full-frame COPY never leaves stale pixels behind. An unconditionally opaque
COPY can only be safe as the *first* thing drawn on its layer — which is
exactly backwards from the general paint-order rule the engine already
established for everything else on a layer.

`patches/series/0031-fix-render-emit-static-tile-list-after-animated-ops-.patch`
fixed this general rule: animated ops (including parallax, `scroll_ratio !=
1`) draw first, then the static/holed content draws second and occludes
through the gaps — "matching the engine's original per-cell compositing
order" (animated tile, then a holed non-animated cell painted on top). The
base-layer plane is the *one* exception to that rule today, forced to fire
first solely because an all-opaque COPY can't safely go second: it would
erase whatever animated content (including parallax) already drew.

Both problems — "let gaps show what's underneath" and "let the plane draw
after parallax like everything else" — are solved by the same capability:
real per-pixel transparency on the baked plane. This was identified but
deferred in the bug #1 design ("Deferred: full per-layer planes with real
transparency") as out of scope for that fix.

## Design

Generalize the single base-layer-only RGB565 plane into **one bake per
layer that has static content**, keyed by layer instead of hardcoded to
`bg_base_layer`, baked as **ARGB4444** (alpha=15 where a static tile
actually covers a pixel, alpha=0 where it doesn't) instead of RGB565 with a
background-color fill. The read-back COPY switches from plain `BLEND_COPY`
to `BLT_BLEND_PALPHA` — the fabric's existing, HW-validated per-pixel-alpha
blend path (`comp_pipeline.sv`), already used for every alpha-blended
sprite/tile in the game today. No new blend hardware; the new RTL is
narrowly the writeback side (below).

Every layer's plane COPY moves to fire in the position patch 0031 already
established for the per-bucket path: after that layer's animated ops, not
before. This removes the base layer's "must fire first" special case
entirely — with alpha-punched gaps, the plane COPY only overwrites pixels it
actually covers, so it's safe to fire in the same relative position as
everything else, uniformly across all layers. The scroll_ratio
disqualification scan in `res_arm_()` is deleted outright: a layer's plane
no longer needs to know or care what's drawn underneath it, parallax or
otherwise.

### Per-pixel, not per-tile, coverage

Coverage must be tracked per pixel, not per tile. A static tile that itself
uses colorkey/blend skipping (e.g. a decorative tile with transparent
cutouts) must leave those skipped source pixels at alpha=0, not alpha=15
just because a tile was nominally placed there. This falls out of the
existing per-cell bake mechanics with no new special-casing: the per-cell
clear (`bake_background_plane_step()`'s `blt_fill` before painting each
cell, currently filling to `bg_clear_rgb565`) becomes an alpha=0 clear
instead, and the writeback only marks a pixel alpha=15 when the compositor
actually wrote a value while painting that cell — the same KEY/blend skip
logic that already exists for normal tile painting, just now also observed
by the writeback stage. This is strictly more correct than today's
all-or-nothing per-tile-rect opacity model.

### Removing patch 0033

The tileset-background-color-baking workaround (`patch
0033-fix-render-bake-the-tileset-background-color-into-em.patch`) becomes
unnecessary and should be removed as part of this work. `Game::draw`
already fills the whole framebuffer with the map's background color as its
first draw call each frame (`fill_with_color(background_color)`, the same
site `mister_set_background_color` mirrors) before any layer draws. Once
gaps bake as real alpha=0 instead of a copied-in background color, the
plane's PALPHA COPY simply leaves that pre-existing fill alone wherever it
has no content — no separate background-color tracking needed on the bake
side at all.

### Components changed

- `Renderer::resident_begin_frame` / `MisterBlitterRenderer::Impl`: the
  single `bg_*` field set (`bg_base_layer`, `bg_plane_sdram_base`,
  `bg_map_w/h`, `bg_origin_x/y`, `bg_plane_valid`, `bg_clear_rgb565`)
  becomes a per-layer table. `bg_clear_rgb565` and the background-color
  plumbing (`mister_set_background_color`'s bake-side consumer) are
  removed; the background-color publish itself stays, since `Game::draw`
  still needs it for the per-frame fill.
- `res_arm_()`: bounds computation (`compute_bgplane_bounds()`,
  `patches/mister/blitter/bgplane_bounds.h` — already parametrized by
  layer, per its multi-layer-filtering test coverage) runs once per
  eligible layer instead of once for `bg_base_layer` only. The
  scroll_ratio scan/disqualification is deleted.
- `bake_background_plane_step()`: per-cell clear becomes alpha=0; tile
  painting is unchanged (existing blend/key logic already produces correct
  per-pixel results, now also captured by the writeback pack below);
  iterates cells across whichever layer(s) are currently baking rather
  than a single fixed layer.
- `resident_emit_static_layer(layer)`: COPY becomes `BLT_BLEND_PALPHA`;
  fires after that layer's animated ops (`resident_emit_layer_op`) for
  every layer uniformly. The `layer != bg_base_layer` fallback condition
  is replaced by a per-layer bake-validity check (see Error handling).
- Fabric (`comp_pipeline.sv`, `blitter_top.sv`): `OP_BGPLANE_WRITE`'s
  writeback mux gains an ARGB4444 pack mode — new but scoped RTL,
  comparable in size to prior additions like the ADD/MULTIPLY blend modes
  or the colormod pipeline stage (per the original deferred-work
  estimate). The read side needs no new RTL: `BLT_BLEND_PALPHA` +
  `BLT_FMT_ARGB4444` already exists and is HW-validated.
- SDRAM budget: N per-layer planes instead of 1. Each is bounded by
  `map_width × map_height × 2 bytes` (worst case ~320×240×2 = 150 KiB for a
  single-screen map; larger maps scale with their own dimensions, same as
  today's single plane) and typical maps have a handful of layers —
  trivial against the 128 MB SDRAM module already hosting whole-quest
  atlas residency (#66).

### Data flow

Unchanged shape per layer (one bake, one SDRAM plane allocation, one COPY
per frame), repeated per eligible layer instead of singled out for the base
layer. Baking stays incremental (cells/frame budget, unchanged pacing
model), now sequenced across layers rather than just one.

## Error handling / fallback

Disqualification becomes **per-layer, not per-map** — strictly finer
isolation than today's blanket scroll_ratio scan. Each layer's plane bake
carries its own readiness/validity state (today's single `bg_plane_valid`
gate, generalized to one per layer): mid-bake, allocation overflow, or any
other disqualifying condition falls back to per-bucket replay
(`res_emit_static_bucket_`) for *that layer only*, leaving every other
layer's fast path untouched. There is no whole-map fallback path left in
the design — a map with one problematic layer still gets the speedup on
every other layer.

## Testing

- **Host:** extend `tests/bgplane_bounds_test.cpp`'s existing multi-layer
  coverage to confirm per-layer bounds computation still holds when driven
  for more than one layer per map (largely confirming existing behavior,
  not new test infrastructure — `compute_bgplane_bounds()` is already
  layer-parametrized).
- **RTL sim:** extend `fpga/sim/tb_bgplane_write_pipe.sv` and
  `tb_bgplane_equivalence.sv` for the new ARGB4444 writeback pack (alpha=0
  vs alpha=15 correctness, including the colorkey-skip case above) and the
  `BLT_BLEND_PALPHA` read-back COPY (bit-exact vs. today's opaque-COPY
  result for the always-covered case, as a regression gate for existing
  base-layer-only maps).
- **HW validation matrix:**
  1. Map 4 (today's working case): canopy/doorframe occlusion still
     correct, background color still correct *without* patch 0033,
     `fabric_hw` at least as good as today's ~9.2ms.
  2. Map 119 (the disqualified case): parallax renders behind ground
     correctly (screenshot comparison against the known-good pre-BGPLANE
     result), `fabric_hw` drops from ~52.8ms toward the map-4 ballpark
     (target: comfortably under the 16.7ms/60fps budget).
  3. A map with occluding static content on a non-base layer, to validate
     the generalization beyond the two known single-layer cases (find or
     construct one in Mystery of Solarus DX).
  4. Forced per-layer bake failure (artificially small allocation) —
     confirm fallback isolates to that one layer without corrupting any
     other layer's plane.
  5. Regression sweep against the existing perf-campaign map set
     (idlepark/staticpark etc.) — this touches core resident rendering
     paths broadly enough to warrant a full soak, not just the two bug
     maps.

## Considered and rejected

- **Reserved-colorkey plane bake (reuse existing `BLEND_KEY`, zero new
  RTL).** `BLEND_KEY`/`c_colorkey` already exists in `comp_pipeline.sv` for
  sprite colorkey transparency; baking empty cells as a reserved sentinel
  value and reading back with `BLEND_KEY` would need no new hardware at
  all. Rejected because it isn't correctness-safe by construction: any
  legitimate tile pixel that happens to equal the sentinel is silently
  treated as transparent — a real rendering bug, not a performance
  tradeoff. Making it safe requires a load-time scan disqualifying (with
  per-layer fallback + logging) any tileset that actually contains the
  sentinel color, which is more host-side complexity than the ARGB4444
  approach for a mechanism with a real, if narrow, correctness footgun the
  chosen approach doesn't have.
- **Steal a bit from RGB565 green as a dedicated per-pixel opacity flag.**
  Collision-free like the chosen approach (a dedicated bit, not a color
  value), but needs new, non-standard pack/unpack RTL on *both* the
  writeback and read sides — unlike ARGB4444, which reuses the existing
  `BLT_FMT_ARGB4444` unpack logic on the read side entirely unchanged.
  Binary-only transparency (opaque/transparent) versus ARGB4444's 16 alpha
  levels, for a larger net-new RTL surface. Viable fallback if the ARGB4444
  writeback mux proves harder to land than expected, but not the first
  choice.
- **Reorder the whole pipeline to keep every layer in ARGB4444 until final
  scene presentation.** Solves a broader problem than the one that's
  actually broken: normal per-entity/per-tile compositing during a frame
  already composites correctly today via the single persistent WORK
  image's RMW model (PR #49, FB-in-BRAM) — only the flattened plane's
  all-or-nothing COPY is unsafe. Keeping every layer as a separate
  full-frame ARGB4444 buffer until a final merge step means N on-chip
  M10K framebuffers instead of today's 2 (WORK + SCAN), a real BRAM budget
  risk, to solve a problem the chosen approach already solves with zero
  additional full-frame buffers. Rejected as disproportionate scope for
  the actual gap identified.

## Open question for the implementation plan

Whether `OP_BGPLANE_WRITE`'s ARGB4444 pack mode needs a dedicated
`blitter_top.sv` op variant or can be a mode bit on the existing op — a
design-doc-vs-implementation-plan boundary question, left for the plan's
RTL task breakdown rather than resolved here.
