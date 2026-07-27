# OSD-style loading bar — design

**Date:** 2026-07-26
**Status:** approved, not yet implemented
**Scope:** engine-only (host-side drawing). No RTL, no new RBF, no emitter change.

## Problem

The `#72` load-progress bar works, but it does not look like MiSTer. It is three
`blt_fill` rects (`mister_blitter_renderer.cpp:1516-1522`): a full-screen black
clear, a 200×12 mid-grey track at (60, 150), and a white fill. Functional,
visually foreign to the platform.

The goal is cosmetic: make the preload screen read as a MiSTer core loading,
using MiSTer's own visual language.

## What was ruled out, and why

Recorded so these are not re-litigated.

### Driving the real OSD from the core — impossible

`fpga/sys/osd.v` holds `osd_buffer[4096]`, a raw **256×64 1-bit-per-pixel
bitmap**. Its only content source is `io_din`/`io_strobe` on `HPS_BUS`.
Main_MiSTer rasterizes the font, box and bar **on the ARM** and ships finished
bytes. There is no font ROM, no box drawing and no bar drawing anywhere in the
FPGA, and no core-side write port. `osd.v` is not even instantiated in
`Solarus.sv` — it lives in `sys_top.v` (`osd hdmi_osd`, line 1190), downstream
of the core's video output.

So no command-ring opcode, control register or RTL change can put content into
the real OSD.

### Asking Main_MiSTer to display progress — no such command

Verified on device (192.168.20.81) by dumping the `MiSTer_cmd` handler strings
from `/media/fat/MiSTer`. The complete command set is:

```
fb_cmd   video_mode   load_core   screenshot   scaled   volume   mute   unmute
```

There is no message, progress or OSD command. Main_MiSTer cannot be asked to
draw anything.

### Pre-baked atlas blob + `F`-type CONF_STR — the only authentic route, deferred

Main_MiSTer shows its own progress overlay only when *it* performs the file
transfer. That requires the atlases to be a file it streams: an offline bake
tool, an `F`-type `CONF_STR` entry (today's entry is `SC0,SOL,Load Quest` —
`Solarus.sv:258` — which mounts a path and streams nothing, per the comment on
line 288), and `jtframe_dwnld` writing into the `prog_*` port that
`sdram_fb_cache.sv:532` currently ties off dead.

It would also take DDR3 out of the atlas path entirely. It is rejected for now
only on cost: the engine would have to stop allocating atlas layout at runtime
and instead consume a baked layout manifest, which reaches into
`preload_quest_assets`, the perm allocator and PAL8 packing.

### `prog_en` as a performance lever — wrong lever

Investigated because `jtframe_dwnld` + `jtframe_board.v:220`
(`prog_en <= dwnld_busy | ioctl_cart`) is the jtcores pattern. It does not
apply here:

- `jtframe_burst_sdram`'s `prog_din` is **16 bits** (`jtframe_burst_sdram.v:51`).
  The existing STAGE path already writes a **full 64-bit qword per request**
  (one BL=4 burst, `blitter_top.sv:980-985`). Routing atlases through `prog_*`
  would be 4× the requests for the same bytes — a downgrade. jtcores use the
  prog port because the HPS ioctl byte stream is slow anyway, so SDRAM-side
  efficiency is irrelevant there.
- The exclusivity buys nothing. During whole-quest preload the compositor is not
  running, and `dst_*`/`scan_*` are tied off dead (Stage 5 Phase 2 moved scanout
  to DDR3), so STAGE is already the only live SDRAM channel.
- `prog_en` gates SDRAM, not DDR3, so it does not pause the DDR3 traffic either.

Note the stale comment at `blitter_top.sv:152` ("issue one 16-bit SDRAM word
write") — the FSM has not done that since the `#44` burst-write change.

### Bulk-STAGE performance work — parked, not rejected

Separately discovered and deliberately deferred: `blitter_top.sv:1546` sets
`mem_burstcnt = ... : 8'd1` for FSM traffic, so **every 8 bytes of atlas costs a
full DDR3 read round-trip**, fully serialized with the SDRAM write and with no
read-ahead.

A `BLT_OP_STAGE_BULK` opcode could collapse an entire preload batch into one
command with long burst reads. The enabler is verified: `e->alloc` (DDR3 bounce)
and `e->sdram_perm` are the same `blt_alloc` free-list allocator, called with the
same `r->size` in the same order, and during preload nothing is ever freed from
either — perm is grow-only, the bounce heap only reset wholesale. A free-list
allocator with no frees is a bump allocator, so **each batch is contiguous in
both DDR3 and perm SDRAM at matching relative offsets**, expressible as one copy.

Parked at the user's direction; the cosmetic issue was the real motivation. If
picked up later, the invariant needs a host-side assertion (every bounce-heap
allocation in a batch must also be staged to perm, else a gap silently shifts
everything after it).

## Design

Restyle the existing bar in place. `emit_loadbar_fills()`, `paint_loadbar()`,
the drain seam, the `SOLARUS_LOADBAR` gate and the forced repaint every
`preload_total/40` assets (`mister_blitter_renderer.cpp:1712, 1789`) all stay
unchanged. Only the drawing changes.

### Palette — derived from the RTL

`osd.v` declares `OSD_COLOR = 3'd4` and `sys_top.v:1190` instantiates it with no
parameter override, so that is the effective value. The blend (`osd.v:266-268`):

```verilog
R = {osd_pixel, osd_pixel, OSD_COLOR[2], din[23:19]}
G = {osd_pixel, osd_pixel, OSD_COLOR[1], din[15:11]}
B = {osd_pixel, osd_pixel, OSD_COLOR[0], din[7:3]}
```

Evaluated over a black background (`din = 0` — which is what a loading screen
is):

| element | `osd_pixel` | RGB888 | RGB565 |
|---|---|---|---|
| box background | 0 | (32, 0, 0) | `0x2000` |
| border / label / bar fill | 1 | (224, 192, 192) | `0xE618` |

`3'd4` is `3'b100`, so the tint bit lands on **red**: the OSD is a very dark
red-tinted box with warm off-white content, not the blue-grey it is often
remembered as. Two constants to change if it reads wrong on screen.

Because the OSD is 1bpp there are only ever these two colours. The bar's
unfilled track is box-background inside a foreground outline; filled cells are
solid foreground blocks. That two-tone discipline is most of what makes it read
as MiSTer.

### Geometry

`osd_buffer` is 256×64 but composites in **output** space with `multiscan`
vertical scaling, so it does not map 1:1 onto the core's 320×240 framebuffer.
The matching size cannot be derived from the RTL.

Starting point: a centred 256×64 box at (32, 88). Final size is settled by
screenshot comparison against a real OSD capture — a tuning step, not a computed
constant.

Inside the box:

- 1px foreground border.
- A `Loading...` label, 2× scale, horizontally centred in the upper half.
- A bar track inset 16px from each side (224px of usable interior), drawn as
  **discrete cells**: 32 cells of 6px with 1px gaps = `32 × 7 − 1 = 223`px. The
  blocky cell bar is the most recognisable OSD element and is what a 1bpp
  overlay forces anyway. 32 cells sits below the ~40-update repaint granularity,
  so cells advance one at a time rather than jumping.

### The `Loading...` label

The string is fixed, so this needs a **bitmap, not a font**: one hand-authored
1bpp strip, `LABEL_W = 80`, `LABEL_H = 8`, stored in `loadbar.h` as
`uint8_t[8][10]`, MSB-first per byte. Authored in the OSD's blocky idiom — it is
not a copy of Main_MiSTer's `charfont` glyphs, which are not available here.

Drawn by **extracting horizontal runs per row and emitting each as a
`blt_fill`**, the same technique `emit_fps_digit` already uses for 7-segment
digits (`mister_blitter_renderer.cpp:1689-1695`).

This is deliberately not an upload+blit. `blt_upload` allocates from the DDR3
bounce heap, which preload actively cycles via `blt_heap_reset` — an uploaded
label would be invalidated and need re-uploading every batch. Pure fills have
zero heap interaction, which keeps the loading screen independent of staging
state. Rendering at 2× is free: multiply the run coordinates.

Cost: worst case ~5 runs/row × 8 rows ≈ 40 fills for the label, plus ~40 for box
and cells. ~85 fills per bar frame × ~40 frames ≈ 3.4k commands across the whole
preload, against a 512 KB ring holding ~16k. Negligible.

### Header and tests

`patches/mister/loadbar.h` already exists and is registered in
`scripts/apply_mister_files.sh:22`, so this adds no new header and does not risk
the unregistered-header build failure documented in `CLAUDE.md`.

Added to it, both pure and unit-testable:

- `loadbar_cells_filled(cells, staged, total)` — replaces `loadbar_fill_w` with
  the same semantics (floor, clamp to `[0, cells]`, `total == 0` guard). The
  existing cases in `tests/loadbar_test.c` port across directly so the tested
  behaviour carries forward rather than being dropped.
- `loadbar_label_runs(row, out, max) -> int` — extracts `{x0, len}` runs for one
  bitmap row. Tests: known rows yield known runs; out-of-range row yields 0;
  `max` clamps.

## Verification

1. `bash tests/run_tests.sh` — cell math and run extraction.
2. Native type-check (both `-D` flags are mandatory, per `CLAUDE.md`):
   `g++ -fsyntax-only -std=c++17 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO ...`
3. Engine-only deploy (no RBF).
4. Capture during preload: `echo screenshot > /dev/MiSTer_cmd`, fetch via `scp`.
5. **Operator visual gate.** The user compares against a real OSD screenshot and
   judges whether it reads as MiSTer. Per the standing project rule, this is
   never self-declared correct.

## Risks

- **Box size/position will need iteration.** The OSD composites in output space,
  so the first screenshot is unlikely to match; expect one or two tuning passes.
- **The red tint may look wrong** even though it is derived from the RTL. If so,
  it is two constants.
- **Label legibility at 320×240.** 8px authored, rendered at 2× (16px) —
  if it reads poorly on a CRT, 3× still fits inside a 256-wide box.
