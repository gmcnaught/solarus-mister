# Design spec: synchronous load-time bgplane bake

**Date:** 2026-07-15
**Branch context:** `feat/bgplane-default-on`
**Status:** approved design, pre-implementation

## Problem

On entering an overworld map with `SOLARUS_BGPLANE` on, the base ground layer
renders **several frames of garbage before "settling"** to the correct picture.
Upper (sparse) layers draw correctly on frame 1; only the heavy base layer
misbehaves.

### Root cause (traced, not assumed)

There are two distinct "base color" paths, and only the second is at fault:

1. The tileset `background_color` (e.g. `zsdx` tileset 1: `{72,152,72}`) is
   *already* emitted every frame as a single full-screen `BLT_OP_FILL`
   (`mister_blitter_renderer.cpp:2354`, `is_map_bg_fill`). This is fast and not
   the problem. A "new solid-color layer opcode" is therefore unnecessary —
   `BLT_OP_FILL` already offloads a whole-rect single-RGB565 fill to the fabric.

2. The base **tile** layer (map 119 layer 0 = **750 tiles**, green shows through
   its gaps) is baked into an ARGB4444 plane by `bake_background_plane_step()`,
   which advances **one cell per `present()`** (`:556`, `:2976`). A plane only
   becomes `valid` after every cell is baked (`:2585-2587`). Until then,
   `resident_emit_static_layer()` falls back to **replaying every static tile of
   that layer, every frame** (`:3499-3504`). That heavy transient — hundreds of
   tiles/frame across the whole map — is what corrupts the frame until the bake
   completes and the layer collapses to a single cheap COPY (steady state
   confirmed in the HW diag log: `valid=1`, `cmdcnt=32`).

The bake grid is FB-sized (320×240) cells over the map; map 119 (640×752) is
~8 cells/layer, so the settle is ~8 frames/layer, ~16 total — the observed
"several frames."

## Goal

Eliminate the settle window: every layer's plane is `valid` before the first
gameplay content frame, so that frame emits the steady-state single-COPY-per-
layer picture directly. No per-tile fallback, no garbage.

## Non-goals

- No new blitter opcode. `BLT_OP_FILL` and `OP_BGPLANE_WRITE` are sufficient.
- No change to steady-state gameplay rendering (already correct and cheap).
- No detection of "uniform-color layers" (rejected: the base layer is 750
  textured tiles, not one color; the only uniform thing, `background_color`, is
  already a FILL — such detection would be dead code).
- No change to the non-`bgplane` (per-bucket replay) path.

## Design

### Insertion point

The bake is armed in `res_arm_` (`:3237-3260`): per layer it allocates the plane
SDRAM and sets `baking=true, valid=false, bake_cell_idx=0`. `res_arm_` runs once
per resident rebuild (map change), inside `resident_begin_frame`'s rebuild
branch.

`resident_begin_frame` runs at the **top of `Entities::draw()`, before any real
map content is emitted this frame** (`:2506-2512`), and the frame's command list
is fresh at that point. Today the sig branch does
`if (d->bgplane_enabled) bake_background_plane_step();` — one cell. We replace
that, on the first frame where any plane is still `baking`, with a **synchronous
full bake** that drives every plane to `valid` before this frame emits content.

### Mechanism (reuses existing pieces)

New method, e.g. `bake_all_planes_sync()`, invoked from the sig branch when any
plane is `baking`:

1. Loop, accumulating bake work into the current command list:
   - For the next still-`baking` cell, append the existing per-cell body
     (clear-WORK FILL → `BLT_F_BGCOV` coverage-clear → `OP_TILELIST` cell-paint →
     `OP_BGPLANE_WRITE` to SDRAM) — the same code `bake_background_plane_step`
     already emits, factored so both callers share it.
   - Pack cells until the 512 KB ring nears capacity (the one-cell-per-frame
     limit only existed to protect the *gameplay* frame's ring budget; a
     dedicated bake submit has the whole ring). Track command headroom and cut a
     batch before overflow.
   - **End the batch's list with a full-screen `background_color` FILL** (display
     safety — see below).
   - `submit_and_drain()` (`:1155`) — publish + block until the fabric finishes
     the batch (writes the SDRAM plane, snapshots flat green).
2. Repeat until every plane reports `valid` (mirror the completion test at
   `:2985`).
3. `blt_begin_frame(...)` to restart a clean command list, then return so this
   frame's normal content loop emits the real picture — now with all planes
   `valid`, i.e. one COPY per layer.

Only the first post-arm frame pays this; subsequent frames see all planes
`valid` and skip straight to the steady state.

### Display safety (the load-bearing detail)

The fabric snapshots WORK→SCAN once per submitted list (`:2515`). A bake batch
leaves cell-paint scribble in WORK, so its snapshot would flash garbage — the
same failure class the in-frame ordering avoids by re-drawing after the bake.
**Each bake batch ends its command list with a full-screen `background_color`
FILL**, so every intermediate snapshot is flat green (the tileset's own
background), never garbage. `background_color` is available host-side via the
`g_bg_color_r/g/b` published in `mister_set_background_color` (`:180-183`).

User-visible effect: map transition → ~1–2 frames of flat `background_color` →
the finished map. Replaces "several frames of garbage" with a clean, brief,
correctly-colored hold.

### Edge cases

- **Map too large for a bounded number of bake batches:** synchronous baking
  still works (just more batches = a few more flat-green frames); no correctness
  issue. Keep the existing incremental single-step path intact as a fallback if a
  bounded batch budget is exceeded, so we never regress or stall.
- **`blt_alloc` FAIL for a plane** (`:3243`): already falls back to per-bucket
  replay for that layer; unchanged. The sync loop simply skips layers with no
  `bg_planes` entry.
- **Source atlases:** whole-quest preloaded to SDRAM at boot (#66), so always
  staged before any per-map bake.
- **Mid-emit submit hygiene:** `submit_and_drain` calls `blt_end_frame`; after
  the loop we must `blt_begin_frame` again before returning so the real content
  emits into a fresh list (and the frame's later `present()` submits normally).

## Affected code

- `patches/mister/mister_blitter_renderer.cpp`
  - `resident_begin_frame` sig branch (`:2535`) — swap the single-step call for
    the synchronous full bake on the first post-arm frame.
  - `bake_background_plane_step` (`:2639`) — factor the per-cell body so
    `bake_all_planes_sync()` reuses it verbatim; keep the incremental entry as
    the oversized-map fallback.
  - New `bake_all_planes_sync()` (or equivalent) using `submit_and_drain`
    (`:1155`) and the `background_color` FILL.

No RTL change (uses existing `OP_TILELIST`, `OP_BGPLANE_WRITE`, `BLT_OP_FILL`,
`submit_and_drain` doorbell). No wire/opcode change.

## Testing

- **Sim (host/ref):** extend an existing bake test to assert that after a
  synchronous drive, a plane's readback is CLUT/ARGB4444-correct AND the plane is
  `valid` with zero intervening per-bucket fallback emits (i.e. the first content
  frame's command count is the steady-state count, not the fallback count).
- **Host unit:** given N armed planes, `bake_all_planes_sync()` drives all to
  `valid` in a bounded number of `submit_and_drain` batches, and each batch's
  command list ends with a `background_color` FILL.
- **HW (operator gate, required):** walk into the overworld (map 119 route) and
  confirm: no garbage frames on entry — at most a brief flat-green hold, then the
  correct map. Repeat across several map transitions (the `#84` teleport route).
  Do NOT self-declare visual correctness — operator verdict only
  (`[[solarus-no-self-declared-visual-validation]]`).

## Risks

- **Frame-time spike on the first post-arm frame:** the whole bake now lands in
  one frame instead of ~16. It's a one-time load cost per map entry (drained
  synchronously, tens of ms), during a moment the player expects a transition —
  acceptable, but measure it.
- **`submit_and_drain` wedge:** it spins ~1 s then gives up if the fabric wedges
  (`:1165-1166`). The sync loop must tolerate a drain timeout without hanging the
  engine (fall back to leaving remaining planes `baking` → incremental path picks
  them up next frame).
