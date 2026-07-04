# Wiring the native scanout through MiSTer's `video_mixer` (screen-shader chain)

**Status:** design / integration plan (not yet implemented).
**Scope:** FPGA only — `fpga/Solarus.sv` + `fpga/rtl/openbor_video_top.sv` + `CONF_STR`.
**Does NOT touch:** `comp_pipeline`, `comp_mixer`, `comp_fbram`, SDRAM/arbiter, the
blit command ABI, or any host/engine code.

## Why

This is item 1 of the FPGA-shader feasibility assessment: the "screen shader"
family that Solarus would normally do in GLSL — **scanlines, shadow mask, gamma,
HQ2x/scandoubler scaling** — already exists in the shared MiSTer video pipeline
this core forks from. It is simply **not wired into the Solarus native scanout
path today**. Lighting it up is integration wiring against proven, timing-closed
shared modules — not new datapath, not new DSP, and off the razor-thin `clk_sys`
critical path (the whole chain runs on `CLK_VIDEO ≈ 53.693 MHz`).

Getting this in delivers the CRT/scanline/scaling look end users associate with
"Solarus shaders" with the lowest possible risk, and is a prerequisite framing for
any later per-pixel effect stage in the compositor.

## Current state (what's bypassed)

The native reader (`openbor_video_top`) produces 320×240 RGB at Genesis H40 timing
(~15.7 kHz H rate, `ce_pix ≈ 6.7 MHz`) and drives the core's VGA outputs **directly**:

`fpga/Solarus.sv`:
```
229  assign VGA_SL = 0;                         // <-- scanlines/shadowmask disabled
...
975  assign VGA_DE  = NATIVE_VID_ACTIVE ? nv_de : ~(HBlank | VBlank);
976  assign VGA_HS  = NATIVE_VID_ACTIVE ? nv_hs : HSync;
977  assign VGA_VS  = NATIVE_VID_ACTIVE ? nv_vs : VSync;
978  assign VGA_R   = nv_active ? nv_r : (NATIVE_VID_ACTIVE ? 8'd0 : comp_v);
979  assign VGA_G   = nv_active ? nv_g : ...
980  assign VGA_B   = nv_active ? nv_b : ...
```

Consequences:
- **Scanlines + shadow mask are off.** `sys_top.v` already instantiates them
  downstream (`scanlines VGA_scanlines` @1384, driven by the core's `VGA_SL`;
  `shadowmask HDMI_shadowmask` @1160), but they are gated on `VGA_SL[1:0]`, which
  the core forces to `0`.
- **No gamma correction.** `gamma_corr` lives inside `video_mixer` (GAMMA=1) and
  needs `gamma_bus` from `hps_io`; the core never instantiates `video_mixer` and
  never wires `gamma_bus`.
- **No HQ2x / core-side scandoubler.** Also inside `video_mixer`.

## Where the shared modules live

| Effect | Module | Where it runs | Control input |
|---|---|---|---|
| Scanlines | `fpga/sys/scanlines.v` (`VGA_scanlines` in `sys_top.v:1384`) | `sys_top` (downstream of core VGA) | core `VGA_SL[1:0]` |
| Shadow mask (HDMI) | `fpga/sys/shadowmask.sv` (`HDMI_shadowmask` in `sys_top.v:1160`) | `sys_top` (HDMI path) | OSD / framework |
| Gamma | `fpga/sys/gamma_corr.sv` (inside `video_mixer`, GAMMA=1) | core, on `CLK_VIDEO` | `gamma_bus` from `hps_io` |
| Scandoubler / HQ2x | `fpga/sys/scandoubler.v` + `fpga/sys/hq2x.sv` (inside `video_mixer`) | core, on `CLK_VIDEO` | `scandoubler`, `hq2x` |

`video_mixer.sv` interface (this repo's variant does **gamma → scandoubler/hq2x**;
scanlines + shadowmask are applied later in `sys_top`):
```
video_mixer #(.LINE_LENGTH, .HALF_DEPTH, .GAMMA) (
  CLK_VIDEO, CE_PIXEL(out), ce_pix(in),
  scandoubler, hq2x, gamma_bus,
  R, G, B,                       // DWIDTH+1 each (8bpc when HALF_DEPTH=0)
  HSync, VSync, HBlank, VBlank,  // POSITIVE pulses — note: separate blanks
  HDMI_FREEZE, freeze_sync,
  VGA_R, VGA_G, VGA_B, VGA_VS, VGA_HS, VGA_DE);
```

The one impedance mismatch: `video_mixer` wants **separate HBlank/VBlank positive
pulses**, but `openbor_video_top` only exposes the combined `vga_de`. The blanks
already exist inside the wrapper (`tim_hblank`/`tim_vblank`, `openbor_video_top.sv:120-121`)
— they just need to be surfaced as ports.

## Plan

Two independent phases. Phase 1 alone gives scanlines + shadow mask with a
near-zero diff; Phase 2 adds gamma + HQ2x/scandoubler.

### Phase 1 — Scanlines + shadow mask (minimal, no new modules) — **IMPLEMENTED**

`sys_top` already does the work; the core only had to stop forcing `VGA_SL=0` and
expose an OSD option. Landed on this branch:

1. **`CONF_STR` (`fpga/Solarus.sv`)** — scanlines option added next to the CRT
   position options:
   ```
   "O9A,Scanlines,None,25%,50%,75%;",     // status bits [10:9]
   ```
   Bit choice note: the draft suggested bits 6–8, but those are already taken by the
   debug `led` field (`wire [2:0] led = status[8:6];`). Bits 9–10 are free (used
   bits: 4 PAL, 5 FB, 6–8 led, 12–14 H-pos, 15–17 V-pos).

2. **Un-hardwire `VGA_SL`** — `sys/scanlines.v` decodes `VGA_SL[1:0]` directly as
   intensity (0=off, 1=25%, 2=50%, 3=75%), so the OSD field maps 1:1 with no
   re-encoding:
   ```verilog
   assign VGA_SL = status[10:9];
   ```

3. Shadow mask needs no core change beyond the framework's own HDMI mask OSD
   (already present in `sys_top`); confirm it appears in the video-options menu.

**Caveat.** Scanlines are meaningful on a doubled/scaled image. On HDMI the `ascal`
scaler path applies them correctly; on raw 15 kHz analog without doubling they
darken alternate source lines. If the analog look matters, Phase 2's scandoubler
is the fix. This is why Phase 2 exists even though Phase 1 "just works" on HDMI.

### Phase 2 — Gamma + HQ2x/scandoubler via `video_mixer`

1. **Expose the blanks from the native wrapper.** In
   `fpga/rtl/openbor_video_top.sv` add outputs and pass the existing timing
   signals through:
   ```verilog
   output wire vga_hblank,
   output wire vga_vblank,
   ...
   assign vga_hblank = tim_hblank;   // already generated @120
   assign vga_vblank = tim_vblank;   // already generated @121
   ```
   (`vga_hs`/`vga_vs` are already `tim_hsync`/`tim_vsync` — `openbor_video_top.sv:193-194`.)

2. **Declare the new wires + instantiate `video_mixer`** in `fpga/Solarus.sv`,
   between the native reader outputs and the final VGA assigns:
   ```verilog
   wire nv_hbl, nv_vbl;              // new: from native_video
   wire [7:0] mx_r, mx_g, mx_b;
   wire mx_hs, mx_vs, mx_de;
   wire hq2x_en = /* status bit */;

   video_mixer #(.LINE_LENGTH(400), .HALF_DEPTH(0), .GAMMA(1)) mixer (
     .CLK_VIDEO (CLK_VIDEO),
     .ce_pix    (ce_pix_gen),
     .CE_PIXEL  (CE_PIXEL),          // drive CE_PIXEL from the mixer output
     .scandoubler(forced_scandoubler),
     .hq2x      (hq2x_en),
     .gamma_bus (gamma_bus),         // new hps_io port, see step 4
     .R(nv_r), .G(nv_g), .B(nv_b),
     .HSync(nv_hs), .VSync(nv_vs), .HBlank(nv_hbl), .VBlank(nv_vbl),
     .HDMI_FREEZE(1'b0), .freeze_sync(),
     .VGA_R(mx_r), .VGA_G(mx_g), .VGA_B(mx_b),
     .VGA_HS(mx_hs), .VGA_VS(mx_vs), .VGA_DE(mx_de));
   ```
   Note: `CE_PIXEL` is currently assigned from `ce_pix_gen` (`Solarus.sv:227`) — with
   the mixer it becomes the mixer's output (the scandoubler doubles the pixel rate),
   so remove the old `assign CE_PIXEL = ce_pix_gen;` and feed `ce_pix_gen` in as
   `ce_pix`.

3. **Re-point the final VGA assigns** (`Solarus.sv:975-980`) at the mixer outputs,
   preserving the `nv_active` black-gate:
   ```verilog
   assign VGA_DE = NATIVE_VID_ACTIVE ? mx_de : ~(HBlank | VBlank);
   assign VGA_HS = NATIVE_VID_ACTIVE ? mx_hs : HSync;
   assign VGA_VS = NATIVE_VID_ACTIVE ? mx_vs : VSync;
   assign VGA_R  = nv_active ? mx_r : (NATIVE_VID_ACTIVE ? 8'd0 : comp_v);
   assign VGA_G  = nv_active ? mx_g : ...;
   assign VGA_B  = nv_active ? mx_b : ...;
   ```
   (`nv_active` still gates to black outside active video; the mixer sits inside the
   `NATIVE_VID_ACTIVE` branch only.)

4. **Wire `gamma_bus`** through the `hps_io` instance (`Solarus.sv:289`): declare
   `wire [21:0] gamma_bus;` and add `.gamma_bus(gamma_bus)` to the `hps_io` port
   map (standard MiSTer framework port; present in the shared `hps_io.sv`).

5. **`CONF_STR`** — add HQ2x and gamma-enable OSD options on free status bits and
   drive `hq2x_en` / the gamma menu accordingly. (Gamma table load is handled by the
   framework over `gamma_bus` once the option is exposed.)

## Files touched

| File | Change |
|---|---|
| `fpga/Solarus.sv` | un-hardwire `VGA_SL`; instantiate `video_mixer`; re-point final VGA assigns; wire `gamma_bus`; `CONF_STR` options; `CE_PIXEL` from mixer |
| `fpga/rtl/openbor_video_top.sv` | expose `vga_hblank`/`vga_vblank` (pass-through of existing `tim_hblank`/`tim_vblank`) |

No changes to the compositor, SDRAM, arbiter, scanout reader internals, command
ABI, or host/engine code.

## Risk / verification

- **Timing:** the entire mixer chain runs on `CLK_VIDEO`, not the razor-thin
  `clk_sys` (~98.44 MHz, slack "works by silicon luck" per the SDC notes). These are
  shared, timing-proven MiSTer modules used by every arcade core. Low risk — but
  re-run Quartus STA and confirm the `CLK_VIDEO`/HDMI PLL paths still close (the
  `comp_fbram` history shows the HDMI PLL path is the one to watch).
- **Functional:** verify on HW per the existing bring-up recipe — boot a quest,
  toggle each OSD option (scanlines 25/50/75, HQ2x on/off, gamma), and confirm the
  frame counter (`0x3A000000`) still advances and video stays synced. Capture a
  title-screen screenshot per option as in the 2026-06-12 validation.
- **Analog vs HDMI:** confirm both the HDMI (ascal) and analog (scandoubler) paths
  look right; scanlines without Phase 2's scandoubler only make sense post-scale.
- **Phase 1 is independently shippable** and reversible (one `assign` + one
  `CONF_STR` line); land it first, then add Phase 2.

## Relation to deeper FPGA "shaders"

This wires the *existing* fixed-function post-process chain. A *programmable*
per-pixel effect (gamma curve / palette LUT / tint modes beyond the current
source color-mod) would instead go in the compositor at one of its two II=1
insertion points — pre-blend source transform (`comp_pipeline.sv:260-262`) or a
new post-blend/scan-time stage — and is a separate, larger piece of work with real
`clk_sys` timing cost. See the feasibility assessment for that path; this doc is
deliberately the low-risk, high-value first step.
