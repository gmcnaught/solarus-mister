# BGPLANE base-layer-only bake: fixing cross-layer occlusion (bug #1)

## Problem

`SOLARUS_BGPLANE` (Phase 3b, PR #77) bakes every map layer's non-animated
tiles into a single flattened SDRAM plane, and replays it with one full-frame
opaque `blt_blit` COPY per frame, latched to fire once (on whichever layer
`Entities::draw()` processes first this frame).

Because the COPY is a single opaque blit covering the whole framebuffer, and
it fires before any layer's entities have drawn, it erases the layer
ordering the engine otherwise respects: hero/NPC/enemy sprites always paint
in front of *every* static tile, even ones that live on a layer above the
hero and are meant to occlude it (tree canopy, doorframes, anything using
Solarus's normal "higher layer draws later, covers what's below" model).

Symptom, reported directly: walking under tree canopy or through a doorway
no longer hides the hero the way it did before BGPLANE was enabled.

## Root cause

Flattening every layer's statics into one plane throws away the layer
boundary information that made per-layer occlusion work in the first place.
There is no single point in the frame where "blit the whole merged plane
opaquely" is safe *except* the very start of the frame, before anything else
has drawn — but occluding content living on a higher layer needs to draw
**after** the hero's own layer, not merged in with it.

## Design

Restrict the flattened-plane optimization to exactly one layer per map: the
**base layer**, defined as `map.get_min_layer()` — the literal first layer
`Entities::draw()`'s per-layer loop processes each frame. This is the only
layer where an opaque full-framebuffer blit is provably safe: nothing has
been drawn to the framebuffer yet when it fires, regardless of the layer's
numeric sign or magnitude, and regardless of whether neighboring layers have
animated (non-static) content that would otherwise get erased.

Every other layer keeps using the existing per-bucket tile-list replay
(`res_emit_static_bucket_`), which already respects gaps/transparency
correctly and already fires at the right point within that layer's own draw
step (animated-after-static, per the two prior fixes in this session). That
path is not new — it's what every layer already used before BGPLANE existed;
this design just stops the flattened plane from overriding it for anything
but the base layer.

If the base layer itself has zero recorded static tiles (all its content is
animated, or it has no content at all), the per-layer-plane optimization
does not engage for that map at all. There is no fallback to "the next layer
with content" — any layer other than the true first-processed one may have
earlier-layer content already drawn before it, which an opaque COPY would
destroy. Correctness over performance, per the explicit priority for this
fix: an unbaked map just uses the per-bucket path everywhere, same as
BGPLANE being off.

### Determining the base layer

`map.get_min_layer()` must be threaded in explicitly from `Entities.cpp`
(which already has it as the per-layer loop's start bound) — the renderer
currently only receives opaque `map_id`/`tileset_id` tokens, with no layer
range. It is **not** inferred from which layers have recorded static
buckets: that would misidentify the base layer whenever the true min layer
has no static tiles but does have animated content (e.g. a parallax pattern
on layer -1 with the actual ground tiles one layer up) — treating layer 0 as
"base" in that case would erase layer -1's already-drawn animated content
the moment its opaque COPY fired.

### Components changed

- `Renderer::resident_begin_frame(map_id, tileset_id)` gains a `min_layer`
  parameter. `Entities::draw()` passes `map.get_min_layer()` (already in
  scope as the loop's start bound).
- `MisterBlitterRenderer::Impl` stores it as `bg_base_layer`.
- `res_arm_()`: the plane's bounding box (`mw`/`mh`/`min_x`/`min_y`) is
  computed only from `res_static_buckets` entries where
  `.layer == bg_base_layer`. Currently it also folds in every other layer's
  static buckets plus the animated buckets' extents (`res_buckets`) — both
  of those go away; the plane only ever needs to cover the base layer's own
  static content.
- `bake_background_plane_step()`: same filter when painting each cell — skip
  buckets whose `.layer != bg_base_layer`.
- `resident_emit_static_layer(int layer)`: the flattened-plane COPY path
  (`bgplane_enabled && bg_plane_valid`) only applies when
  `layer == bg_base_layer`. Every other layer always takes the per-bucket
  fallback, unconditionally (not gated on `bgplane_enabled` at all — those
  layers were never part of the bake to begin with).
- `Renderer::resident_static_before_animated()` gains a `layer` parameter;
  returns true only when `layer == bg_base_layer` (and the plane is valid).
  For every other layer it's false, matching the per-bucket path's existing
  correct (animated-after-static) ordering — no special-casing needed there.

### Data flow

Unchanged shape, narrower scope: one bake, one SDRAM allocation, one COPY
per frame — all keyed to whichever single layer is the map's base, instead
of merging every layer together. Everything above the base layer draws
through the same per-bucket path it already used before BGPLANE existed.

### Testing

- Host: extend `tests/bgplane_geom_test.cpp` to assert only base-layer
  buckets are folded into the plane's bounding box / bake, and add a case
  where the base layer has no static content (the optimization should
  no-op cleanly, not misfire onto another layer).
- HW: 
  1. Confirm the canopy/doorframe occlusion bug is actually fixed on a real
     map with that setup (find one in Mystery of Solarus DX).
  2. Re-confirm bug #2 (parallax paint order) and the background-color bake
     fix from this session still hold with BGPLANE on.
  3. Record the `fabric_hw` diag counter to report the real perf number
     against the ~7ms full-flatten figure and the ~20ms pre-BGPLANE
     baseline, since restricting to one layer gives up some of the original
     win in exchange for correctness.

## Deferred: full per-layer planes with real transparency

A fuller fix would give every layer its own baked plane and keep all of
them on the fast COPY path, using genuine per-pixel alpha so higher layers'
planes only overwrite pixels they actually cover. Investigated during this
session:

- The **read/composite side already exists and is HW-validated**:
  `BLT_BLEND_PALPHA` + `BLT_FMT_ARGB4444` (`comp_pipeline.sv`) is exactly
  this primitive — per-pixel source-over blend where `A4==0` is skip-write.
  It's the same path already used for every normal alpha-blended tile/sprite
  in the game. Reusing it for per-layer plane compositing would need zero
  new RTL.
- The **write/bake side does not exist**: `comp_pipeline.sv`'s writeback
  stage is RGB565-only — it expands an ARGB4444 *source* before blending,
  but there's no path for the *destination* (WORK / what `OP_BGPLANE_WRITE`
  streams to SDRAM) to ever be ARGB4444. Baking a plane that preserves "was
  anything drawn here" as real per-pixel alpha needs new writeback-stage
  RTL, comparable in scope to past additions like the ADD/MULTIPLY blend
  modes or the colormod pipeline stage — a dedicated design/sim/HW-validate
  cycle, not a quick patch.

Not pursued this iteration (correctness-first priority, smaller footprint
available now). Worth revisiting as a separate follow-up project if BGPLANE
becomes the shipped default and the base-layer-only restriction's perf
tradeoff turns out to matter in practice.
