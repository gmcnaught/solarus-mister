# Load-progress bar during bulk SDRAM asset residency

- **Issue:** #72
- **Date:** 2026-07-07
- **Status:** Design approved, awaiting implementation plan
- **Scope:** engine-only (renderer C++); no RTL/fabric change

## Problem

`preload_quest_assets()` (one-time whole-quest SDRAM asset residency, PR #66) walks
the quest data tree and emits a long run of `BLT_OP_STAGE` copies for every image
file (~60 MiB / ~331 PNGs on Mystery of Solarus DX). This takes several seconds.

Throughout that window **nothing composites into the WORK framebuffer in BRAM**
(`comp_fbram`), yet the fabric's work→scan snapshot still fires on each submit. So
the scanout reader copies **dirty/uninitialized WORK BRAM → SCAN → screen**, showing
garbage for the entire load.

The load window is engine-controllable: the A9 is actively submitting command frames
the whole time, so the engine can paint the FB between/around stage batches.

## Goal

Replace the garbage with an accurate, monotonic **load-progress bar** for the
duration of the bulk asset load, with no fabric/RTL change and no font/atlas
dependency.

## Non-goals

- The pure-hardware window between core load/reset and the engine's first command
  frame (before the engine connects) is out of scope — this addresses only the
  engine-controlled preload window.
- Text rendering ("Loading...") is explicitly rejected: it needs a font/glyph
  surface staged to SDRAM first (chicken-and-egg ordering). The bar conveys the
  same "loading" signal with zero source-pixel dependency.

## Approach

Engine-only, built entirely from `blt_fill(em, x, y, w, h, rgb565)` FILL rects into
the WORK framebuffer. The existing `submit_and_drain()` → fabric snapshot path
carries the composited bar to the SCAN buffer, so scanout displays it. Gated behind
`SOLARUS_LOADBAR` (default-on / opt-out), matching the project's flag convention
(`mister_flag_default_on`).

### Components

1. **PNG pre-count.** A fast, directory-only pre-walk (same
   `QuestFiles::data_file_list_dir` recursion + `ends_with_png` filter as the stage
   loop, but **no** `Surface::create`/decode) yields `total`. Cheap — it only lists
   directory entries.

2. **`paint_loadbar(frac)` helper.** Composites one bar frame:
   - `blt_begin_frame(&em, target_buf, /*clear=*/1, /*clear_color=*/BG)` — clears the
     whole WORK FB to a solid background color.
   - `blt_fill(&em, TRACK_X, TRACK_Y, TRACK_W, TRACK_H, TRACK_COL)` — static track.
   - `blt_fill(&em, TRACK_X, TRACK_Y, (uint)(frac * TRACK_W), TRACK_H, FILL_COL)` —
     foreground, width proportional to `frac` (clamped `[0,1]`).
   - Geometry is fixed `static const` for the 320×240 FB: a track ~200×12 centered
     horizontally, at roughly `y = 150`. `frac == 0` draws just the track (no
     foreground rect) — still a clean frame.

3. **Integration into `preload_quest_assets()`.**
   - **Before** the stage loop: `paint_loadbar(0)` then `submit_and_drain()` → the
     garbage is killed at frame 0, not after the first drain.
   - Maintain a `staged` counter, incremented once per successfully staged PNG.
   - At each **existing** drain seam — the `submit_and_drain()` in the overflow-retry
     path of `preload_stage_one()` **and** the final flush — repaint the bar
     (`blt_fill`s for `staged/total`) into that draining frame before it submits.
     This piggybacks on submits that already happen, so there are **zero extra
     submits/snapshots** and no added load time. The bar advances in chunks (as many
     steps as there are drains, ~15–30 for a 60 MiB load).
   - Final flush paints `paint_loadbar(1.0)` → 100%.

### Data flow

```
pre-walk  ->  total
paint_loadbar(0) --submit--> fabric FILLs WORK --snapshot--> SCAN --> clean screen (0%)
stage loop: for each png { stage; staged++ }
   at drain seam: FILL bar(staged/total) into the draining frame --submit/snapshot--> advance
final flush: bar(1.0) --> snapshot --> 100%
first gameplay frame composites --> naturally overwrites the bar (no teardown)
```

## Edge cases / error handling

- `SOLARUS_LOADBAR=0`, or software path (`!ddr`), or `SOLARUS_PRELOAD=0` → skip the
  bar entirely; current behavior is unchanged. (Note: with `SOLARUS_PRELOAD=0` there
  is no bulk preload window, so no bar is needed.)
- `total == 0` → `paint_loadbar(0)` still paints a clean solid frame (bar at 0);
  guard the `frac` computation against divide-by-zero.
- Repaints are **idempotent** — each recomputes `frac` from `staged/total`, so a
  chunky/uneven drain cadence is fine and the bar is always monotonic.
- The bar lives only in BRAM WORK/SCAN. When the first real gameplay frame
  composites, it overwrites the bar naturally — no explicit teardown.
- `frac` clamped to `[0,1]` so a miscount (e.g. a PNG that fails `Surface::create`
  in the stage loop but was counted in the pre-walk) can't produce an over-wide rect.

## Testing

- **Native type-check:** existing g++ `-fsyntax-only` recipe for
  `mister_blitter_renderer.cpp` (see `fpga-renderer-native-typecheck` memory). The
  change uses only existing primitives (`blt_fill`, `blt_begin_frame`,
  `submit_and_drain`).
- **armhf Docker build gate:** `docker run --rm -v "$(pwd):/src" -w /src
  solarus-armhf-build:bullseye scripts/build_engine.sh` → `Built target solarus-run`.
  (clang `-fsyntax-only` is necessary but NOT sufficient — armhf gcc is the real
  gate.)
- **HW validation (DE10-Nano, MoSDX):**
  - No garbage on screen at any point during the bulk asset load.
  - Bar advances 0 → 100% monotonically.
  - Overworld renders normally once gameplay compositing takes over.
  - Screenshot mid-load: `echo screenshot > /dev/MiSTer_cmd` (load_core Solarus
    first so the fabric is live).

## Files touched

- `patches/mister/mister_blitter_renderer.cpp` — `preload_quest_assets()` +
  `paint_loadbar()` helper + PNG pre-count. Authored via the patch-series workflow
  (apply → edit → `export_patches.sh`); lands in the residency feature patch under
  `patches/series/`.
