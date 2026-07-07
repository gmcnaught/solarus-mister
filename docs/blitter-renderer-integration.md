# Solarus ↔ FPGA blitter integration (MisterBlitterRenderer)

How the Solarus engine drives the FPGA hardware blitter, by mapping its
`Renderer` interface onto the engine-agnostic host emitter
(`patches/mister/blitter/`, vendored from the `mister-fpga-blitter` repo). This
is the **engine-specific binding**; the frame's journey through the fabric is
`docs/frame-dataflow.md`.

> **Status: the shipping default render path, HW-validated on the DE10-Nano.**
> `patches/mister/mister_blitter_renderer.{h,cpp}`, applied by the
> `patches/series/` git patch series. Engaged when `SOLARUS_BLITTER` is set
> (the launch script sets it) and the DDR map succeeds; otherwise the engine
> falls through to the plain `SDLRenderer`.

## Where it plugs in

`MisterBlitterRenderer` is a **subclass of `SDLRenderer`**. Patch
`0001-feat-mister-DDR-video-audio-hooks-blitter-renderer-*.patch` hooks
`SDLRenderer::create()`: when the blitter engages, it constructs and returns a
`MisterBlitterRenderer` instead of a plain `SDLRenderer`. The subclass inherits
the windowless software-surface plumbing (surface creation, texture decode,
the `SDLRenderer` singleton that `SDLSurfaceImpl` needs) and overrides
`clear`/`fill`/`draw`/`present` to emit blitter commands instead of
compositing on the CPU.

Why a `Renderer` backend and not a present-hook shim (the pattern the leaf
video/audio DDR copies use): the blitter must intercept the *compositing*
(`draw`/`fill`/`clear`), which is stateful and cross-cutting — the `Renderer`
is exactly the engine's extension point for that, and the inherited SDL path
remains available per-op for anything inexpressible.

## Surface model — SDRAM asset residency (#66)

Quest assets are **resident in SDRAM for the lifetime of the quest**, staged
once at load rather than lazily per surface:

- At quest load, `preload_quest_assets()` walks the quest's PNGs, decodes and
  converts each (RGB565, or **ARGB4444** for surfaces the blend analysis says
  need per-pixel alpha — preloading the wrong format would force a re-stage),
  and `STAGE`s them DDR3 → permanent SDRAM. A load-progress bar (#72,
  `SOLARUS_LOADBAR`) is painted while this runs. `SOLARUS_PRELOAD=0` falls back
  to lazy stage-on-first-draw.
- Immutable file-backed assets never re-upload. Mutable surfaces (CPU-drawn
  intermediates) are dirty-tracked and re-staged when they change.
- Map tiles don't go through per-draw emission at all: each layer's tiles are
  recorded once into per-layer **tile lists** in `TL_BUF` — the animated set
  (`SOLARUS_TILERESIDENT`) and the static set sourced directly from the
  resident atlas (`SOLARUS_TILESTATIC`) — and replayed by the fabric as one
  `BLT_OP_TILELIST` command per layer. This is what removed the A9's
  per-tile-draw emit cost (#52).

## Method mapping

| `Renderer` method | Blitter action |
|---|---|
| `clear(screen)` | `blt_begin_frame(target, clear=1, color)` |
| `fill(screen, color, where, mode)` | `blt_fill` (COPY/BLEND/ADD/MULTIPLY solid) |
| `draw(screen, src, infos)` | `blt_blit(src ref, region, dst, blend, key, alpha, flags)` — clipped host-side to the framebuffer bounds |
| `present(window)` | `blt_end_frame()` → publish ring + control block to DDR → doorbell |

Frame boundaries: Solarus has no explicit "begin frame", so `clear(screen)`
starts a blitter frame; if a frame's first screen op isn't a clear, a lazy
`blt_begin_frame(..., clear=0)` is issued. `present()` ends it.

### BlendMode / opacity → blend opcode

Everything Solarus's `BlendMode` + `DrawInfos.opacity` can express is native on
the fabric — nothing composites on the CPU:

| Engine state | Fabric blend |
|---|---|
| `NONE`, or `BLEND` fully opaque with no alpha/key | `BLT_BLEND_COPY` |
| `BLEND` + colorkey source | `BLT_BLEND_COLORKEY` |
| `BLEND` + `opacity < 255` | `BLT_BLEND_CONST_ALPHA` (± colorkey flag) |
| `BLEND` + per-pixel alpha source | `BLT_BLEND_PALPHA` (ARGB4444 source) |
| `ADD` / `MULTIPLY` | `BLT_BLEND_ADD` / `BLT_BLEND_MULTIPLY` |
| color modulation (tint) | fabric colormod stage |

Flips map to `BLT_F_HFLIP`/`VFLIP`. The rare genuinely inexpressible op
(rotation, non-integer scale) is serviced by the inherited SDL software path
for that surface (`SOLARUS_ALIAS_SW` widens this escape hatch for debugging);
in practice heavy-area frames run with **zero** software escapes.

## present(): publishing the frame

`present()` copies the command ring (~512 KiB capacity at DDR3 `0x3B000040`)
and control block to DDR, then stores the doorbell (`submit_seq`) **last** —
strongly-ordered device memory via `/dev/mem` `O_SYNC`+`MAP_SHARED`, so the
fabric never sees a doorbell before its commands. With the on-chip framebuffer
the engine keeps a **single persistent target** (`SOLARUS_BLITTER_SINGLEBUF=1`,
set by the launcher): there is no target ping-pong; the fabric's vblank
WORK→SCAN snapshot provides tear-free scanout. Frame pacing polls the reader's
`vsync_count` (`0x3A070000`); `SOLARUS_FASTPACE` (default ON) trims the
redundant half-frame barrier wait.

## Why this is the right altitude

The win isn't only cheaper pixels — it's removing the A9-side per-draw
traversal and SDL call overhead. A Solarus frame was thousands of tile draws
plus tens-to-hundreds of sprite draws; tile layers became one command each
(tile lists), and each remaining draw is a ~32-byte command emit instead of a
software blit. The fabric then sweeps the list at one pixel per clock.

## Bring-up questions, as answered on hardware

The original integration doc called out four unknowns; for the record:

1. **Target-surface selection** — resolved by camera-region tagging (the
   camera/screen surfaces are tagged and composited on the fabric;
   `SOLARUS_NO_CAMERA_TAG` disables for debugging).
2. **Per-pixel alpha** — no longer escapes: `BLT_BLEND_PALPHA` with ARGB4444
   sources, chosen at preload by blend analysis.
3. **Surfaces read back by the engine** — engine-side pixel readers (collision
   etc.) keep CPU copies; residency's forget-hooks keep stale fabric pointers
   from outliving their surfaces.
4. **DDR ordering / buffering vs scanout** — doorbell-last ordering plus the
   fabric vblank snapshot; the engine paces to `vsync_count`.

## Implemented files

- `patches/mister/mister_blitter_renderer.{h,cpp}` — the renderer backend
  (+ `loadbar.h`, `mister_idleskip.h`, `mister_idlepark.h` helpers).
- `patches/mister/blitter/` — vendored emitter + wire codec (from the
  `mister-fpga-blitter` repo; do not edit here).
- `patches/series/*.patch` — the git patch series that wires it all into the
  upstream tree (applied by `scripts/apply_patch_series.sh` from
  `scripts/build_engine.sh`).
