# Fabric-offload blend overlays (dialogs + in-game blend menus)

**Date:** 2026-07-24
**Status:** Design approved; ready for implementation planning
**Approach chosen:** B — composite-offload + a contained PALPHA×opacity RTL change

## Problem

In-game dialogs halve fps whenever any dialog is on screen. Measured
(`docs/superpowers/2026-07-22-stage5-a9-arbror-den-decision.md`, FIFO-ablation
proven): the quest's `dialog_box:on_draw` rebuilds a full 320×240 surface every
frame — even when the text is fully revealed and static — and blends it onto the
root at opacity 216. That final **320×240 opacity-216 blend onto the root is a
software (A9) premultiplied-path op costing the bulk of ~29 ms/frame**; it runs
regardless of whether the dialog changed. Dialogs are pervasive (signs, NPCs,
item-gets, dungeon captions), so this is a game-wide penalty. The same cost class
applies to any **in-game blend menu** — a translucent pause/inventory menu drawn
over a live world (a menu that *promotes*, i.e. fully replaces the screen, is
already fabric-offloaded by patch 0044 / PR #148).

Today every such overlay is composited into the root in software, and the whole
root is then uploaded once as ARGB4444 and composited **last** by the fabric as a
single full-screen `PALPHA` blit.

### Cost split (drives the approach)

`dialog_box:on_draw` each frame does:
1. `dialog_surface:clear()` — a 320×240 memset (fast).
2. ~6 small sub-draws (box border pieces, 3 pre-rendered text-line surfaces,
   icon, arrows) onto `dialog_surface` (small).
3. `dialog_surface:draw(root)` at opacity 216 — a **320×240 premultiplied blend**
   (the dominant cost).

The dominant cost is the *compositing* (3), not the *building* (1)+(2). So the
fix offloads the compositing to the fabric and leaves the cheap building in
software.

## Goal / non-goals

**Goal.** A single, general **blend-overlay fabric layer** mechanism: any
full-screen surface a quest blends onto the root at partial opacity (dialog box,
translucent in-game menus) is composited as its *own fabric layer* instead of a
software blend-into-root. One path covers dialogs and in-game blend menus.

**Non-goals.**
- Pre-game menus and promote-style menus — already handled by patch 0044 / #148.
- The "skip the draw / decimate the overlay" lever (a separate, rejected
  approach). This design attacks the root cause (A9 software compositing).
- A second fabric render target to offload surface *building* (Approach C) — the
  building is the cheap part; not worth the RTL/BRAM.

## Success criteria

- With a dialog on screen, standing fps recovers toward the dialog-dismissed
  baseline (map 40 reference: ~14.5 fps → target near ~53 fps; expect roughly
  2× the current with-dialog fps).
- The dialog box looks **identical** to today (opacity 216 preserved).
- No regression to the root overlay, HUD, sprites, tiles, or promote menus.
- Validated by operator visual gate + bit-exact host test — never
  self-declared (`solarus-no-self-declared-visual-validation`).

## Architecture

Pull blend overlays out of the root and composite each as its own fabric layer,
emitted after the root overlay in draw order. The root keeps only opaque/HUD
content. Three cooperating pieces:

1. **Engine-truth gate** — Solarus core publishes dialog/pause state edges to the
   renderer (deterministic, no quest-Lua dependency, no pixel heuristic lottery).
2. **Renderer capture + route** — while gated, intercept the full-screen blend
   onto root, capture its source surface, and re-emit it as a fabric PALPHA layer
   with a content-hash-cached upload.
3. **RTL** — make the fabric's `PALPHA` blend honor the command's global opacity
   so the 216 look is exact (and the fabric gains the primitive #124 needs).

### 1. Engine-truth gate (new patches, modeled on 0044)

Solarus core already holds authoritative state and exposes exact edge points:
- `Game::is_dialog_enabled()`, `Game::start_dialog()` (`src/lua/GameApi.cpp`,
  `src/core/Game.cpp`).
- `Game::is_paused()`, `Game::set_paused()` (`src/lua/GameApi.cpp`).

Publish state edges to the renderer via new free functions modeled on
`mister_notify_menu_transition()` (patch 0044):
- `mister_notify_dialog_state(bool active)` — fired on dialog start and end.
- `mister_notify_pause_state(bool active)` — fired from `Game::set_paused()`.

These set/clear a renderer flag `blend_overlay_armed`. Authoritative C++ state is
the source of truth; the quest does **not** need to define `on_dialog_started` /
`on_paused`. Gate behind a default-ON env flag (project convention, e.g.
`SOLARUS_BLENDLAYER`) with `=0` restoring the software blend-into-root path as the
escape hatch.

Delivery: engine-side edges go in the git-am series (`patches/series/`), modeled
on 0044; the renderer bits are whole-file edits to
`patches/mister/mister_blitter_renderer.{cpp,h}`.

### 2. Renderer: capture + route

In `MisterBlitterRenderer::draw()` case-1 (`is_fpga_target(dst)` i.e. dst == root,
`mister_blitter_renderer.cpp` ~line 2884), when `blend_overlay_armed` **and** the
incoming draw is a full-screen quest-size non-opaque blit (e.g.
`dialog_surface:draw(root)` at opacity 216):

1. **Capture** `&src` as a `blend_layer` entry `{src, dst_rect, blend, opacity}`.
   `src` is stable — `dialog_box.lua` creates `dialog_surface` once at dialog
   start and reuses it. Multiple simultaneous overlays form an ordered list,
   captured in draw order.
2. **Do not** software-composite it into root (this removes the 320×240 software
   blend — the win).
3. **Upload** `src` ARGB4444, **cached via content-hash**: hash the surface pixels
   after the quest builds it; re-upload only on change. Static/fully-revealed
   dialog → cache hit; char-by-char reveal → hash changes → re-upload. This is the
   overlay stale-guard applied to the layer.
4. **Emit** in `emit_overlay_composite()` (~line 1524) as a fabric PALPHA blit at
   the captured opacity, **after** the root overlay, in capture order — preserving
   the software HUD-then-dialog Z-order.

HUD sub-region draws onto root during a dialog stay on root exactly as today; only
the full-screen blend is intercepted.

**Identification predicate** (gated — only evaluated while `blend_overlay_armed`):
`dst == root` AND `src` is quest-size (`FB_W × FB_H`) AND the blit is full-screen
AND blend is non-opaque (opacity < 255 or a translucent blend mode). The gate makes
this deterministic: the predicate is never evaluated on unrelated gameplay frames,
so there is no first-wins lock to strand (the failure mode patch 0044's memory
warns about).

### 3. RTL: PALPHA honors global opacity

Single change at `comp_pipeline.sv:252`, mirrored in `blitter_ref.c` (~line 288):

- Today: `feed_alpha = b_palpha ? pa_a8 : c_alpha` — global alpha ignored for
  PALPHA.
- New: `feed_alpha = b_palpha ? div255_round(pa_a8 * c_alpha) : c_alpha`, using
  the pipeline's existing divide-free `/255` reduction.

**Backward-compatible by construction:** the root overlay and every current PALPHA
caller pass `c_alpha = 255`, so `pa_a8 × 255/255 = pa_a8` — bit-identical to today.
Only a layer passing opacity < 255 (the dialog's 216) changes. `feed_skip`
(`pa_a4 == 0` → transparent, skip-write) is unchanged.

Requires a new RBF (ships engine + RBF together, per project convention).

**#124 (translucent menus under-dim the world):** this change gives the fabric the
primitive #124 needs (composite a translucent overlay at its true opacity). Treat
the actual #124 fix as a *secondary benefit to verify on HW*, not a guaranteed
side effect of this change alone.

## Correctness guards

1. **Z-order** — layers emitted after the root overlay, in capture order,
   preserving the software paint order (HUD drawn onto root first → root emitted
   first; dialog blit later → dialog layer emitted after).
2. **Escape fallback (never lose an overlay)** — if a layer's ARGB4444 upload
   fails (heap/stage exhaustion) or the draw isn't expressible on the fabric, fall
   through to today's `SDLRenderer::draw` into root so the overlay always appears
   (composited in software that frame). Counted by the existing escape counters;
   no new loss class.
3. **Disarm safety** — on the dialog-end / unpause edge, clear the captured
   layer(s). Once `is_dialog_enabled()` is false the engine stops issuing the
   dialog draw, so root reverts to HUD-only with no stranded layer. The
   `Game::draw` per-frame camera re-tag (patch 0004) repairs transition frames.
4. **Content-hash staleness guard** — never reuse a cached upload across a content
   change; char-by-char reveal and HUD-adjacent changes re-hash and re-upload.
5. **Surface-free on the fast path** — the interception adds no new intermediate
   surface (contrast Approach C); `dialog_surface` itself is the flattened source.

## Diagnostics

Add gated counters to the `SOLARUS_BLITTER_DIAG` banners (project convention):
layers captured/frame, layer upload cache hit/miss, escape count, and armed state
— mirroring the `[blitter overlay]` / `[blitter diag]` counters.

## Testing & validation

- **Host bit-exact (blitter suite, `tests/run_tests.sh`)** — PALPHA @ opacity 216
  over a known dst vs golden; regression that PALPHA @ 255 is byte-identical to
  pre-change.
- **Engine-model host test** — model the interception + layer ordering + escape
  fallback + content-hash cache decision (the repo's tests MODEL engine-side logic
  against the emitter/ref; they do not compile the renderer).
- **RTL sim** — extend the `comp_pipeline` PALPHA testbench for the ×opacity case;
  run STA + seed sweep (one multiply + reduce in an existing pipeline stage → low
  timing risk).
- **Wire constants** — no new opcodes/flags; `test_wire_constants.py` unaffected.
- **HW gate (operator, never self-declared)** — dialog must look identical at 216;
  #124 menu visual check; A/B fps capture with a dialog on screen (expect near the
  dialog-dismissed baseline). Diag levers: `SOLARUS_BLITTER_DIAG=1` layer/escape
  counters; `SOLARUS_BLENDLAYER=0` A/B against the software path.

## Rollout

- `SOLARUS_BLENDLAYER` default ON once HW-validated; `=0` restores the software
  blend-into-root path (escape hatch).
- Ships engine + new RBF together (deploy convention).

## Open items for the implementation plan

- Exact caller audit confirming no current PALPHA emit relies on a non-255
  `c_alpha` being ignored.
- Precise predicate thresholds for "full-screen quest-size non-opaque blit" and
  how a partial-height dialog box (box occupies a sub-rect but `dialog_surface` is
  full 320×240) is captured — the *source surface* is full-screen even though the
  visible box is a sub-rect, so the predicate keys on source size, not painted
  extent.
- Content-hash function choice + where it hooks relative to the quest build.
- Whether pause-menu overlays in the target quest(s) actually blend vs promote
  (confirm on HW; promote path already covered by #148).
