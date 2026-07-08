# OSD-driven features: 320x224 crop, Restart Quest, FPS overlay

- **Date:** 2026-07-07
- **Status:** Design approved, awaiting implementation plan
- **Scope:** RTL (`fpga/Solarus.sv`) + engine (`patches/mister/mister_blitter_renderer.cpp`,
  `work/solarus/src/core/MainLoop.cpp`)
- **Reference:** [kimchiman52/sonic-mania-mister](https://github.com/kimchiman52/sonic-mania-mister)
  (`mister` branch) — architecturally close to solarus-mister (ARM-software engine,
  FPGA is display-only), but its ARM process is registered as MiSTer's `main=`
  binary and links Main_MiSTer's own `user_io_status_get/set()` directly. We have
  no equivalent bridge, so the reference's approach is adapted, not copied 1:1 —
  see "Why not copy the reference directly" per feature below.

## Problem

Three OSD-driven features are wanted, modeled on sonic-mania-mister:

1. An option to reduce the visible screen to 320x224 (retro-accurate crop).
2. An option to restart the current quest from the OSD.
3. An option to show a live FPS counter in the lower-right corner.

`Solarus.sv`'s `status[]` bits (CONF_STR-driven OSD state) are today consumed
**only inside the FPGA fabric** — e.g. `h_pos`/`v_pos` feed `openbor_video_top`
directly. Nothing bridges OSD state to the ARM-side `solarus-run` engine or to
`quest_manager.sh`. Two of the three features need that bridge; one doesn't.

## Goal

Ship all three as OSD `CONF_STR` entries in `Solarus.sv`, with minimal new
FPGA<->ARM plumbing, reusing existing primitives (Solarus's own `MainLoop`
reset call, the existing DDR3 control-block mmap, the existing `blt_fill`
FILL-rect drawing the `#72` load-progress bar already uses) instead of
replicating the reference's architecture where it doesn't fit.

## Non-goals

- No adjustable crop offset/scale — just an on/off 224-line window (sonic-mania
  exposes a "Crop Offset" fine-tune; not requested here).
- No "Detailed" FPS overlay tier (frame-time breakdown, HW perf counters) — just
  a number. Can be added later behind the same bit range if wanted.
- No true process-level cold restart (kill + re-exec `solarus-run`) — see
  Feature 2's rationale.
- No change to `VIDEO_ARX`/`VIDEO_ARY` aspect-ratio handling beyond what
  `video_freak` needs to express the crop.

## Shared infrastructure

Needed by Restart and FPS Overlay (not by Crop, which is FPGA-only).

- **New CONF_STR bits** in `Solarus.sv` (next free after `v_pos` at `[17:15]`):
  ```
  "O[20],FPS Overlay,Off,On;",
  "T[19],Restart Quest;",
  ```
  (bit 18 is Feature 1's Vertical Crop toggle — see below.)
- **New read-only register `C_OSD` at offset `0x40`** in the existing DDR3
  control block (`patches/mister/mister_blitter_renderer.cpp`; sits after the
  existing `C_SRCSEL = 0x38`). Written every `clk_sys` cycle by `Solarus.sv`:
  - bit0 = raw level of `status[19]` (Restart toggle)
  - bit1 = raw level of `status[20]` (FPS Overlay on/off)
- The renderer already mmaps this control block and polls it once per frame
  (existing `C_STATUS` read for HW perf counters). It gains a `C_OSD` read at
  the same point, exposed via a small static accessor,
  `MisterBlitterRenderer::osd_flags()`, so both the renderer's own draw path
  (Feature 3) and `MainLoop` (Feature 2) can query it without a second mmap.

## Feature 1 — 320x224 display crop (FPGA-only)

**Why not copy the reference directly:** sonic-mania-mister's "Vertical Crop"
option is built on the stock MiSTer `sys/video_freak.sv` + framework `ascal`
scaler pipeline. `Solarus.sv` drives `VGA_R/G/B/HS/VS/DE` **directly** from its
own timing generator (`openbor_video_top`/`openbor_video_reader`) and never
adopts `video_freak.sv` — so the reference's CONF_STR shape applies, but the
RTL integration is new work, not a copy-paste.

Confirmed viable: `fpga/sys/sys_top.v` already instantiates the framework's
`ascal` HDMI scaler unconditionally, fed from `hde_emu` which traces back to
`VGA_DE`. Since `VGA_DE = NATIVE_VID_ACTIVE ? nv_de : ...` and
`NATIVE_VID_ACTIVE` is hardwired on, `ascal` already scales whatever `nv_de`
says is active — so gating `nv_de` via `video_freak` reaches real HDMI output
through the existing scaler, with no changes to `ascal`/`sys_top.v` itself.
`video_freak.sv` already exists in `fpga/sys/` (unused Template_MiSTer
boilerplate) — this is its first use in this core.

### Design

- `status[18]` = Vertical Crop On/Off: `"O[18],Vertical Crop (224p),Disabled,Enabled;"`.
- Rename the current `nv_de` feed into a `vga_de_raw` wire; instantiate
  `video_freak` in `Solarus.sv`, feeding it `vga_de_raw` + fixed `CROP_SIZE`/
  `CROP_OFF` constants sized for a 224-line window (8 lines blanked top and
  bottom of the existing 240-line active area) — no user-adjustable offset.
- `video_freak`'s output DE and adjusted `VIDEO_ARX`/`VIDEO_ARY` replace the
  current fixed assigns (`VIDEO_ARX = 13'd4`, `VIDEO_ARY = 13'd3`) when crop is
  enabled, feeding `ascal` the same way `h_pos`/`v_pos` already feed sync-pulse
  timing.
- Isolated to DE/ARX/ARY wiring — does not touch the FB-in-BRAM compositor,
  SDRAM residency, or blitter command datapath.

## Feature 2 — Restart Quest (in-engine reset, not process relaunch)

**Why not copy the reference directly:** sonic-mania-mister's wrapper process
kills and re-execs the whole game binary on `T[22]`. That pattern exists
because their wrapper *is* the OS-level launcher process. For us, a
kill+relaunch would go through `quest_manager.sh`, re-run the full SDRAM
asset-residency preload (`preload_quest_assets()` — the whole-quest upfront
stage that's had a real history of fragility, per prior residency/stale-pointer
work), and tear down/recreate the DDR3 mmap and SDL/engine state for no
functional benefit, when Solarus's own engine already has an equivalent
in-process primitive.

### Design

- `MainLoop::set_resetting()` (`work/solarus/src/core/MainLoop.cpp:340`)
  already exists and is used internally: it stops the current `Game` and
  returns to the title/initial screen. This *is* solarus-mister's "restart the
  current quest," with no process boundary crossed.
- `Solarus.sv`: `T[19]` toggle -> `C_OSD` bit0 (per shared infra above).
- `MainLoop::run()`'s per-frame loop (same location as the existing
  `mister_prof` diagnostic block, `MainLoop.cpp:~465`) reads
  `MisterBlitterRenderer::osd_flags()` bit0 once per frame, edge-detects a
  rising transition (0->1), and calls `set_resetting()`.
- No process exit; `preloaded` stays `true`; no `quest_manager.sh` change
  needed at all.

## Feature 3 — FPS overlay, lower-right corner (live-toggle, number only)

**Why not copy the reference directly:** sonic-mania-mister reads its FPS-
overlay level once at launch via an env var (`SONIC_MANIA_FPS_OVERLAY`) written
by their wrapper from `user_io_status_get()` before exec — "live updates are
not wired" by their own admission. We have the `C_OSD` channel already for
Restart, so live toggling costs little extra and is strictly better UX.

### Design

- `status[20]` -> `C_OSD` bit1 (per shared infra above), polled live each
  frame — flipping the OSD option takes effect immediately, no restart needed.
- **FPS source:** `MainLoop.cpp` already computes a rolling-average FPS every
  30 frames from `CLOCK_MONOTONIC` deltas (`mister_prof` diagnostic block,
  `MainLoop.cpp:~465-481`), currently only used for an stderr log line. This
  gets generalized into an always-on, cheap accumulator (same 30-frame window)
  exposed via a getter, independent of the `mister_prof` flag.
- **Rendering:** no font/atlas dependency. Digits are drawn as small filled
  rectangles (7-segment style) via the existing `blt_fill()` primitive — the
  same primitive the `#72` load-progress bar uses. Unlike the load bar (which
  paints a standalone begin/submit frame), the FPS digits are emitted into the
  *normal* per-frame draw stream, after the game's own draws and before
  submit, so they overlay on top in the bottom-right corner.

## Testing / validation plan

- **Crop:** HW visual check (224 visible lines, symmetric top/bottom
  blanking), confirm no scanout tear/timing regression to the FB-in-BRAM
  tear-free snapshot path, confirm `h_pos`/`v_pos` still work combined with
  crop enabled.
- **Restart:** confirm return-to-title behavior matches Solarus's existing
  internal reset, repeated-restart soak (no leak/crash across N triggers),
  confirm SDRAM-resident assets are untouched (no re-preload, no stale-pointer
  regression).
- **FPS overlay:** confirm live on/off toggle, confirm the number tracks known
  load variation (drops in heavy areas, per the Phase 1 profiling baseline in
  `docs/superpowers/2026-07-07-gprof-attribution.md`).
- Bit allocations (`status[18:20]`, `C_OSD` bits 0-1) get a comment block in
  `Solarus.sv` mirroring the existing `h_pos`/`v_pos` documentation style.

## Open questions for the implementation plan

- Exact `CROP_SIZE`/`CROP_OFF` constant values for `video_freak` to produce a
  224-line window (needs checking `video_freak.sv`'s parameter semantics
  against the existing 320x240 `openbor_video_timing.sv` `V_ACTIVE`/blanking
  numbers).
- Exact digit geometry/position for the FPS overlay (bottom-right corner
  margin, digit size) — small, self-contained decision, doesn't affect the
  architecture above.
