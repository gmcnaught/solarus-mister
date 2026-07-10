# Fabric offload for software-composited title/menu scenes (behavioral full-FB alias)

**Date:** 2026-07-10
**Branch:** `worktree-title-fabric-alias` (from master `2db3c7d`)
**Status:** Design approved — ready for implementation plan
**Scope:** Engine + renderer only. **No RTL changes.**

## Problem

Two scenes run at ~20fps while normal gameplay runs 53–62fps: the **animated
title screen** and a **parallax map**. HW diagnostics (`SOLARUS_BLITTER_DIAG=1`)
show these are slow for *opposite* reasons:

| | Animated title | Parallax map |
|---|---|---|
| Bound by | **A9** (software composite) | **FABRIC** (compositor throughput) |
| fps | 18.9 | 14.4 |
| A9 / frame | **31.0ms** (emit=29.6, of which walk=25.4) | 25.7ms (lua=19.5, emit=4.0) |
| fabric comp% | **30% (idle)** | **91% (saturated)** |
| `alias_blits`/fr | **0** (all software) | ~11,780 (all on-fabric) |
| `offtarget`/fr | 11.5 (software composite) | 1 (negligible) |
| `reup` / fr | 150 KB whole-surface re-upload | 0 |
| comp cycles/fr | 0.9M | 6.0M |
| `escape` | 0 | 0 |

**This spec addresses ONLY the title-class case (A9 software compositing).** The
parallax map is already fully offloaded — its fix is *reducing* fabric throughput
(a separate track, out of scope here). `escape=0` on both confirms rotation/scale
(path 3) is not involved.

### Root cause (animated title), traced in `mister_blitter_renderer.cpp`

The title composites its background layers + scrolling clouds (535×298, alpha)
onto a **software-backed full-FB intermediate** (`0x4593828`, `tex=0`) — ~10
heavy full-frame draws/frame on the A9 — then uploads that whole surface
(150 KB/frame) and promotes it with one blit. The fabric sits 70% idle.

The fabric camera-alias offload (which already handles this exact
clear→repaint→promote pattern for the game camera) never engages because:

1. **A dead camera tag hijacks the alias.** `Game::draw` sets `g_tagged_camera`
   to a surface (`0x4ae5c58`) that receives **zero** draws (MoSDX's title runs
   over a map whose camera is not the visible content). `draw()` (line ~1799)
   adopts the tag as `alias_target`.
2. **The tag preempts the heuristic.** `looks_like_promote` detection is gated on
   `!alias_target` (line ~1849), so once the dead tag is adopted it never runs.
3. **The heuristic rejects software surfaces anyway.** `looks_like_promote`
   requires a texture-backed source (line ~1558) unless `SOLARUS_ALIAS_SW` is
   set; the intermediate is `tex=0`.

Net: a dead tag points the alias at an empty surface, the real full-frame
composite target is never latched, and all of it falls to the software path
(branch 3 of `draw()`, line ~1885). Note: the intermediate pointer `0x4593828`
is **stable** across all 60 captured frames — no pointer thrash for this scene,
so once latched it sticks.

## Goal

Engage the idle fabric for the title's full-FB software intermediate so its
per-sprite composite runs on-fabric (like the game camera), eliminating both the
~25ms/frame software composite and the 150 KB/frame whole-surface upload.

**Target (HW, animated title):** `alias_blits` 0 → ~10/fr, `offtarget` 690 → ~0,
`reup` 8.79 MB → ~0, A9 31ms → ~6ms, fps ~19 → ~60, `escape` stays 0.

## Non-goals

- Parallax-map fabric-throughput reduction (separate track).
- General fabric render-to-texture for arbitrary intermediate surfaces
  (Approach 3 — heavier, kept in reserve).
- Offloading the cheap small-surface menu assembly (e.g. the 201×48 menu box):
  its ~5 sub-draws/frame are cheap software and its final promote is *already*
  on-fabric. Left as-is.

## Design — behavioral full-FB alias (Approach 1)

Four components, all in `patches/mister/mister_blitter_renderer.cpp` (+ any
engine-side hook only if arbitration needs it; expected renderer-only).

### Component 1 — Software-tolerant, behaviorally-guarded promote detection

Replace the texture-backing gate in alias-eligibility with a **behavioral** gate.
A surface qualifies as an alias target when:

- it is FB-sized (`FB_W`×`FB_H`), and
- it is promoted to `fpga_target` as a 1:1, opaque, unrotated, unscaled,
  full-frame copy (existing `looks_like_promote` geometry checks), and
- **it was fully re-established this frame** — either hardware-cleared
  (`clear()` on it) **or** covered by a leading full-FB opaque draw
  (`dst_rectangle` == full FB, `blend == NONE`) before any incremental draws.

The "re-established each frame" test is the real invariant the `tex` gate was a
crude proxy for — it is exactly what prevents the draw-once static-menu →
black-frame bug documented at lines ~437–443. With it in place, the `tex`
requirement is dropped (software intermediates qualify). If a candidate is *not*
re-established each frame, it does **not** alias and falls back to the existing
upload + full-frame promote path (always correct).

### Component 2 — Live-target arbitration (a dead tag cannot win)

The camera tag stays authoritative **while its surface is actually drawn to**.
Arbitration rule:

- If `g_tagged_camera` received draws this frame → keep it as `alias_target`
  (unchanged gameplay behavior).
- If `g_tagged_camera` received **zero** draws this frame **and** a Component-1
  behavioral promote candidate is live → switch `alias_target` to the candidate
  (next frame, mirroring the existing "first-wins resolves next frame" latch).

This never steals the alias from a live tagged camera, so gameplay (camera
repainted every frame) is untouched.

### Component 3 — Per-frame draw tally + reset

Promote `alias_drawn_this_frame` (bool) to a small per-target tally sufficient to
distinguish "live" (>0 draws) from "dead" (0 draws) for both the tagged surface
and the behavioral candidate. Reset alongside the existing per-frame reset in
`ensure_frame` (line ~1007).

### Component 4 — Skip-promote correctness guard (reused, unchanged)

Keep the existing rule (lines ~1828–1848): skip the promote blit only when the
aliased surface was drawn this frame; otherwise emit it as a normal full-frame
blit of the surface's current (dirty-refreshed) pixels. With Component 1's
re-established gate this remains correct.

### Data flow (steady title frame, after change)

```
clear(intermediate)            -> re-established this frame (Component 1 gate)
draw(bg COPY -> intermediate)  -> composites into DDR FB at alias offset (fabric)
draw(clouds  -> intermediate)  -> composites into DDR FB (fabric, alpha)
... ~10 heavy draws/frame ...  -> all fabric alias_blits
promote(intermediate->fpga)    -> SKIPPED (content already in DDR FB, Component 4)
menu-box assembly (201x48)     -> cheap software (unchanged)
menu-box promote               -> already on-fabric (unchanged)
```

Fabric absorbs ~10 extra blits/frame trivially (was 30% utilized). The whole-
surface upload and the software composite both disappear.

## Rollout

Single env gate, repurposing `SOLARUS_ALIAS_SW`, **default ON** (opt-out for
debugging), matching the project's default-on-after-HW-validation pattern. If a
cleaner name is warranted, introduce `SOLARUS_SWALIAS` with the same semantics;
decide during implementation.

## Risks & mitigations

- **Aliased surface read back on CPU.** Once aliased, pixels live only in the DDR
  FB, not the SDL surface. The game camera already has this property and works;
  the title's promoted surface is the final screen composite (not read back).
  Scope aliasing to FB-sized promote targets; Component 4 guard applies. Low risk,
  called out explicitly.
- **False re-establish (smear).** Guarded by Component 1's per-frame
  clear-or-full-cover check; strictly safer than the current `tex`-only gate.
- **Gameplay regression.** Component 2 switches only when the tagged surface is
  dead (0 draws) — impossible during normal gameplay.

## Validation plan

1. **A/B on the animated title (HW).** Expect the target metrics above
   (`alias_blits` 0→~10, `offtarget` 690→~0, `reup`→~0, A9 31→~6ms, fps 19→~60,
   `escape`=0).
2. **Gameplay regression (HW).** Overworld + parallax: `alias_blits`, fps, and
   correctness unchanged (arbitration must not touch the live camera).
3. **Menu/dialog scenes.** Small menu boxes (201×48-class) still render correctly
   (software-assembled + fabric-promoted, unchanged).
4. **Visual.** Screenshot the title before/after: clouds, logo, menu box all
   correct — no smear, no black frame.

Deploy/validate on device `192.168.20.81`; diag at
`/media/fat/logs/Solarus/Solarus.diag.log`. Drive title→menu navigation via
joypad injection if needed.

## Open questions for implementation

- Confirm the animated-title promote geometry is a clean full-frame 1:1 blit of
  `0x4593828` (validate at first implementation checkpoint via the `rootblit`
  diag line for the cloud scene).
- Confirm whether arbitration can live entirely in the renderer or needs a small
  engine-side signal to identify "the tagged surface got no draws this frame"
  (expected renderer-only, since `draw()` already sees every draw's dst).
