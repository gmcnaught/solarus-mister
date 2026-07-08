# OSD-driven features: 320x224 crop, Restart Quest, FPS overlay — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship three OSD `CONF_STR` options in the Solarus MiSTer core — a 320x224
display crop, a "Restart Quest" trigger, and a live lower-right FPS overlay —
adapting (not copying) the reference implementations in
[kimchiman52/sonic-mania-mister](https://github.com/kimchiman52/sonic-mania-mister)
to this project's architecture.

**Architecture:** Crop is pure FPGA (`fpga/sys/video_freak.sv`, already compiled
into the project via `sys/sys.qip` but unused until now, gated by a new
`status[18]`). Restart and FPS Overlay both need one new FPGA->ARM signal path:
`blitter_top.sv`'s existing once-per-frame `S_WR_STATUS` write already emits a
`C_STATUS` register whose low 32 bits have always been hardwired to `0` and are
never read by the ARM side — repurposing those two dead bits (bit0=restart,
bit1=fps-on) gives the engine a live per-frame OSD read with **no new register,
no new bus-master FSM state, and no new DDR3 offset** (a cheaper mechanism than
the design doc's initial "new `C_OSD` register" sketch, found during planning —
see Task 1). Restart reuses Solarus's own existing `MainLoop::set_resetting()`.
FPS overlay reuses the engine's existing rolling-average FPS calculation
(currently gated behind a diagnostic-only flag) and draws digits with the same
`blt_fill()` FILL-rect primitive the `#72` load-progress bar already uses.

**Tech Stack:** SystemVerilog (Quartus 17.0.2 target, Cyclone V), C++17
(armhf cross-build via Docker), bash (patch-series tooling).

## Global Constraints

- Bit allocations: `status[18]` = Vertical Crop (224p) on/off, `status[19]` =
  Restart Quest (momentary toggle), `status[20]` = FPS Overlay on/off. These are
  the next free bits after the existing `v_pos` at `status[17:15]`.
- `C_STATUS` (control-block offset `0x30`) low32 bits: bit0 = raw `status[19]`
  level, bit1 = raw `status[20]` level. High32 continues to carry
  `perf_pipe_cyc` unchanged (existing behavior, do not disturb).
- No adjustable crop offset/scale, no "Detailed" FPS tier, no process-level
  restart (kill/re-exec) — see the approved design doc,
  `docs/superpowers/specs/2026-07-07-osd-driven-features-design.md`, for the
  full rationale on each non-goal.
- Engine-side edits to files under `patches/mister/` are the canonical source
  (copied verbatim into `work/solarus/...` by `scripts/apply_mister_files.sh`
  during every build — never hand-edit the copies under `work/solarus/src/...`
  for these files). Edits to files that are themselves part of upstream
  Solarus (e.g. `work/solarus/src/core/MainLoop.cpp`) are made directly in
  `work/solarus` and then exported into `patches/series/*.patch` via
  `scripts/export_patches.sh` — see Task 4.
- RTL changes have no local synthesis check available in this environment
  (Quartus is CI/Windows-runner only, per `docs/superpowers/specs/...`
  gotchas); validate via the existing CI workflows
  (`.github/workflows/verilator-lint.yml` is advisory and scoped to
  `fpga/rtl/**` only — it does not cover `fpga/Solarus.sv` or `fpga/sys/**` —
  `.github/workflows/build-rbf.yml` is the real Quartus synthesis gate) plus
  HW validation in Task 5.

---

### Task 1: RTL — OSD CONF_STR entries + FPGA→ARM status mirror (Restart + FPS bits)

**Files:**
- Modify: `fpga/Solarus.sv` (CONF_STR block ~line 254-265; status wire block
  ~line 837-841; `blitter_top` instantiation ~line 584-632)
- Modify: `fpga/rtl/blitter_top.sv` (module port list ~line 34-41; `S_WR_STATUS`
  state ~line 777-780)

**Interfaces:**
- Produces: `status[18]` (Vertical Crop, consumed by Task 2), `status[19]`
  (Restart, mirrored into `C_STATUS` low32 bit0), `status[20]` (FPS Overlay,
  mirrored into `C_STATUS` low32 bit1). `blitter_top` gains two new input
  ports: `osd_restart`, `osd_fps_on`.
- Consumes: nothing from other tasks (this is the foundational task).

This task adds all three CONF_STR entries together (single coherent edit to
the string literal) but only wires up the ARM-visible mirror for Restart and
FPS Overlay — `status[18]` (crop) is declared here and consumed in Task 2.

- [ ] **Step 1: Add the three CONF_STR entries**

In `fpga/Solarus.sv`, find the `CONF_STR` `localparam` (currently):

```systemverilog
localparam CONF_STR = {
	"Solarus;;",
	"SC0,SOL,Load Quest;",
	"-;",
	"OCE,H Position (CRT),0,+1,+2,+3,-3,-2,-1;",
	"OFH,V Position (CRT),0,+1,+2,+3,-3,-2,-1;",
	"-;",
	"J1,Sword,Action,Item 1,Item 2,Pause;",
	"jn,A,B,X,Y,Start;",
	"-;",
	"V,v",`BUILD_DATE 
};
```

Replace it with (note: this core uses MiSTer's compact single-letter bit
encoding, matching the existing `OCE`/`OFH` entries — `'0'-'9'`=bits 0-9,
`'A'-'Z'`=bits 10-35, so bit 18='I', 19='J', 20='K'):

```systemverilog
localparam CONF_STR = {
	"Solarus;;",
	"SC0,SOL,Load Quest;",
	"-;",
	"OCE,H Position (CRT),0,+1,+2,+3,-3,-2,-1;",
	"OFH,V Position (CRT),0,+1,+2,+3,-3,-2,-1;",
	"OI,Vertical Crop (224p),Disabled,Enabled;",
	"-;",
	"OK,FPS Overlay,Off,On;",
	"TJ,Restart Quest;",
	"-;",
	"J1,Sword,Action,Item 1,Item 2,Pause;",
	"jn,A,B,X,Y,Start;",
	"-;",
	"V,v",`BUILD_DATE 
};
```

- [ ] **Step 2: Declare the new status wires**

In `fpga/Solarus.sv`, find (in the `/////// VIDEO ///////` section):

```systemverilog
wire [2:0] h_pos = status[14:12];  // OSD H Position (CRT): 0..6 → 0,+1,+2,+3,-3,-2,-1
wire [2:0] v_pos = status[17:15];  // OSD V Position (CRT): 0..6 → 0,+1,+2,+3,-3,-2,-1
```

Add immediately after it:

```systemverilog
wire       crop_on     = status[18];  // OSD Vertical Crop (224p): 0=off, 1=on (Task 2: video_freak)
wire       osd_restart = status[19];  // OSD Restart Quest (momentary toggle); mirrored to ARM
                                       // via C_STATUS low32 bit0 (blitter_top S_WR_STATUS below)
wire       osd_fps_on  = status[20];  // OSD FPS Overlay: 0=off, 1=on; mirrored to ARM via
                                       // C_STATUS low32 bit1 (blitter_top S_WR_STATUS below)
```

- [ ] **Step 3: Add the two new ports to `blitter_top`**

In `fpga/rtl/blitter_top.sv`, find the module port list:

```systemverilog
module blitter_top #(
    parameter AW = 32
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          vs,          // scanout vblank (synced) — gates the work->scan snapshot
```

Replace with:

```systemverilog
module blitter_top #(
    parameter AW = 32
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          vs,          // scanout vblank (synced) — gates the work->scan snapshot
    // [OSD mirror] raw status[] levels sampled once per frame (S_WR_STATUS) into
    // C_STATUS low32 bits[1:0] — this reuses the control block's dead low32 (it
    // was always written 0 and never read by the ARM side) instead of adding a
    // new register/offset. See docs/superpowers/specs/2026-07-07-osd-driven-
    // features-design.md for why a new register was the original sketch.
    input  wire          osd_restart, // status[19]: Restart Quest (momentary toggle)
    input  wire          osd_fps_on,  // status[20]: FPS Overlay on/off
```

- [ ] **Step 4: Write the mirror bits in `S_WR_STATUS`**

In `fpga/rtl/blitter_top.sv`, find:

```systemverilog
            S_WR_STATUS: begin
                // low32 = status (0); high32 = compositor-busy (pipe_busy) cyc this frame.
                bm_wr<=1; bm_be<=8'hFF; bm_addr<=`BLTCTRL_QW+`C_STATUS;
                bm_din<={perf_pipe_cyc, 32'd0};
```

Replace with:

```systemverilog
            S_WR_STATUS: begin
                // low32 = OSD mirror bits (bit0=osd_restart, bit1=osd_fps_on; this word was
                // always 0 before and never read by the ARM side); high32 = compositor-busy
                // (pipe_busy) cyc this frame — unchanged.
                bm_wr<=1; bm_be<=8'hFF; bm_addr<=`BLTCTRL_QW+`C_STATUS;
                bm_din<={perf_pipe_cyc, 30'd0, osd_fps_on, osd_restart};
```

(Leave the rest of the state — the `wr_ret<=S_SNAP_WAIT; state<=S_WR_WAIT;`
lines that follow — untouched.)

- [ ] **Step 5: Wire the two new ports at the `blitter_top` instantiation**

In `fpga/Solarus.sv`, find (inside the `blitter_top blitter (...)` instantiation):

```systemverilog
	.vs             (fb_vs),
```

Replace with:

```systemverilog
	.vs             (fb_vs),
	.osd_restart    (osd_restart),
	.osd_fps_on     (osd_fps_on),
```

- [ ] **Step 6: Commit**

```bash
git add fpga/Solarus.sv fpga/rtl/blitter_top.sv
git commit -m "feat: OSD CONF_STR entries + FPGA->ARM status mirror for restart/FPS overlay"
```

No local synthesis check is available (see Global Constraints); this is
validated by CI (`build-rbf.yml`) and HW test in Task 5.

---

### Task 2: RTL — 320x224 display crop via `video_freak`

**Files:**
- Modify: `fpga/Solarus.sv` (fixed `VIDEO_ARX`/`VIDEO_ARY` assigns ~line
  232-235; status wire block, right after Task 1's additions ~line 841-845;
  final `VGA_DE` assign ~line 983)

**Interfaces:**
- Consumes: `crop_on` (`status[18]`, declared in Task 1 Step 2).
- Produces: nothing consumed by later tasks (self-contained).

`video_freak.sv` is already part of the compiled project (added via
`fpga/sys/sys.qip`, standard Template_MiSTer boilerplate — confirmed present
and unused by any core file today) along with its `sys_umul`/`sys_udiv`
dependencies (`fpga/sys/math.sv`, also already in `sys.qip`). No `.qip`/`.qsf`
changes are needed.

- [ ] **Step 1: Gate the fixed aspect-ratio assigns on the crop output**

In `fpga/Solarus.sv`, find:

```systemverilog
assign VGA_SL = 0;
assign VGA_F1 = 0;
// OpenBOR renders at 320x240. 4:3 aspect ratio.
assign VIDEO_ARX = 13'd4;
assign VIDEO_ARY = 13'd3;
assign VGA_SCALER= 0;
assign VGA_DISABLE = 0;
```

Replace with:

```systemverilog
assign VGA_SL = 0;
assign VGA_F1 = 0;
// OpenBOR renders at 320x240, 4:3 aspect ratio. When Vertical Crop (status[18])
// is off, freak_arx/freak_ary (video_freak, instantiated below near h_pos/v_pos)
// equal these same fixed values, so this is a no-op until the option is enabled.
assign VIDEO_ARX = NATIVE_VID_ACTIVE ? freak_arx : 13'd4;
assign VIDEO_ARY = NATIVE_VID_ACTIVE ? freak_ary : 13'd3;
assign VGA_SCALER= 0;
assign VGA_DISABLE = 0;
```

(Verilog continuous assigns aren't order-dependent, so referencing
`freak_arx`/`freak_ary` here before they're declared further down the file is
valid.)

- [ ] **Step 2: Instantiate `video_freak`**

In `fpga/Solarus.sv`, immediately after the status wires added in Task 1 Step 2
(`crop_on`/`osd_restart`/`osd_fps_on`), add:

```systemverilog
// [320x224 crop] video_freak recomputes VGA_DE + VIDEO_ARX/ARY for a 224-line
// active window. CROP_SIZE=0 is video_freak's own "disabled" convention (the
// same pattern sonic-mania-mister uses: `status[32] ? 12'd216 : 12'd0`) — tying
// it to crop_on gates the whole feature with no separate enable port. CROP_OFF
// is tied to 0: video_freak's internal math centers the window symmetrically at
// offset 0 (8 lines blanked top and bottom of the 240-line frame -> 224 visible).
// SCALE is tied to 0 (Normal / no integer rescale) — non-goal per the design doc;
// the framework's ascal (fpga/sys/sys_top.v) does the final HDMI scale from
// whatever VIDEO_ARX/ARY this produces, same as it already does for h_pos/v_pos.
wire [11:0] freak_crop_size = crop_on ? 12'd224 : 12'd0;
wire        vga_de_cropped;
wire [12:0] freak_arx, freak_ary;

video_freak video_freak
(
	.CLK_VIDEO    (CLK_VIDEO),
	.CE_PIXEL     (ce_pix_gen),
	.VGA_VS       (nv_vs),
	.HDMI_WIDTH   (HDMI_WIDTH),
	.HDMI_HEIGHT  (HDMI_HEIGHT),
	.VGA_DE       (vga_de_cropped),
	.VIDEO_ARX    (freak_arx),
	.VIDEO_ARY    (freak_ary),

	.VGA_DE_IN    (nv_de),
	.ARX          (12'd4),
	.ARY          (12'd3),
	.CROP_SIZE    (freak_crop_size),
	.CROP_OFF     (5'd0),
	.SCALE        (3'd0)
);
```

- [ ] **Step 3: Feed the cropped DE into `VGA_DE`**

In `fpga/Solarus.sv`, find:

```systemverilog
assign VGA_DE  = NATIVE_VID_ACTIVE ? nv_de    : ~(HBlank | VBlank);
assign VGA_HS  = NATIVE_VID_ACTIVE ? nv_hs    : HSync;
assign VGA_VS  = NATIVE_VID_ACTIVE ? nv_vs    : VSync;
```

Replace the first line only (leave `VGA_HS`/`VGA_VS` untouched — sync pulse
timing is unaffected by the crop, matching how `h_pos`/`v_pos` never touch
`VGA_DE` either):

```systemverilog
assign VGA_DE  = NATIVE_VID_ACTIVE ? vga_de_cropped : ~(HBlank | VBlank);
assign VGA_HS  = NATIVE_VID_ACTIVE ? nv_hs    : HSync;
assign VGA_VS  = NATIVE_VID_ACTIVE ? nv_vs    : VSync;
```

- [ ] **Step 4: Commit**

```bash
git add fpga/Solarus.sv
git commit -m "feat: 320x224 OSD vertical-crop option via video_freak"
```

---

### Task 3: Engine — FPS digit math, renderer state, and free-function bridge

**Files:**
- Create: `patches/mister/fps_overlay.h`
- Create: `tests/fps_overlay_test.c`
- Modify: `tests/run_tests.sh`
- Modify: `patches/mister/mister_blitter_renderer.h`
- Modify: `patches/mister/mister_blitter_renderer.cpp`
- Modify: `scripts/apply_mister_files.sh`

**Interfaces:**
- Consumes: `C_STATUS` register offset (`0x30`, existing constant in
  `mister_blitter_renderer.cpp`), low32 bit0/bit1 semantics from Task 1.
- Produces: `bool mister_osd_restart_requested();` and
  `void mister_set_fps(double fps);` (free functions, declared in
  `mister_blitter_renderer.h`, namespace `Solarus`) — consumed by Task 4's
  `MainLoop.cpp` edits.

- [ ] **Step 1: Write the pure FPS-overlay math header**

Create `patches/mister/fps_overlay.h`:

```c
// Pure FPS-overlay math + the 7-segment digit lookup table (OSD FPS Overlay
// feature). Header-only, no SDL/Solarus deps so it links into both
// mister_blitter_renderer.cpp and the host unit test.
#ifndef MISTER_FPS_OVERLAY_H
#define MISTER_FPS_OVERLAY_H

#include <stdint.h>

// 7-segment membership per digit 0-9. bit0=a(top) bit1=b(upper-right)
// bit2=c(lower-right) bit3=d(bottom) bit4=e(lower-left) bit5=f(upper-left)
// bit6=g(middle).
static const uint8_t FPSOV_SEGMENTS[10] = {
    0x3F, /* 0: a b c d e f       */
    0x06, /* 1: b c               */
    0x5B, /* 2: a b d e g         */
    0x4F, /* 3: a b c d g         */
    0x66, /* 4: b c f g           */
    0x6D, /* 5: a c d f g         */
    0x7D, /* 6: a c d e f g       */
    0x07, /* 7: a b c             */
    0x7F, /* 8: a b c d e f g     */
    0x6F, /* 9: a b c d f g       */
};

// Clamp a rolling FPS reading to the [0,99] range the 2-digit overlay can show.
// Rounds to nearest (e.g. 59.6 -> 60); values >= 99.5 saturate at 99.
static inline int fps_overlay_clamp(double fps)
{
    int v = (int)(fps + 0.5);
    if (v < 0)  return 0;
    if (v > 99) return 99;
    return v;
}

#endif // MISTER_FPS_OVERLAY_H
```

- [ ] **Step 2: Write the host unit test**

Create `tests/fps_overlay_test.c`:

```c
/* Host unit test for fps_overlay.h — the pure FPS-clamp math and the 7-segment
 * digit lookup table (OSD FPS Overlay feature). The renderer itself can't be
 * unit-tested on the host (pulls in SDL/Solarus), so only the branch-worthy
 * logic is factored out and exercised directly here, mirroring loadbar_test.c.
 *
 * Build+run (from repo root):
 *   cc -Wall -Wextra -O2 -I patches/mister \
 *       tests/fps_overlay_test.c -o /tmp/fps_overlay_test && /tmp/fps_overlay_test
 */
#include "fps_overlay.h"
#include <stdio.h>
#include <stdint.h>

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s (line %d)\n", msg, __LINE__); failures++; } \
} while (0)

int main(void)
{
    /* clamp: negative -> 0 */
    CHECK(fps_overlay_clamp(-5.0) == 0, "-5.0 -> 0");
    /* clamp: exact zero */
    CHECK(fps_overlay_clamp(0.0) == 0, "0.0 -> 0");
    /* round to nearest */
    CHECK(fps_overlay_clamp(59.6) == 60, "59.6 -> 60 (round)");
    CHECK(fps_overlay_clamp(59.4) == 59, "59.4 -> 59 (round)");
    /* in-range exact */
    CHECK(fps_overlay_clamp(99.0) == 99, "99.0 -> 99");
    /* saturate at the 2-digit ceiling */
    CHECK(fps_overlay_clamp(99.5) == 99, "99.5 -> 99 (saturate, would round to 100)");
    CHECK(fps_overlay_clamp(250.0) == 99, "250.0 -> 99 (saturate)");

    /* segment table: every entry must be a 7-bit value (bits 0-6 only) */
    for (int d = 0; d < 10; d++) {
        CHECK((FPSOV_SEGMENTS[d] & 0x80) == 0, "segment table entry is 7-bit");
    }
    /* spot-check known digit shapes */
    CHECK(FPSOV_SEGMENTS[0] == 0x3F, "digit 0 shape");
    CHECK(FPSOV_SEGMENTS[1] == 0x06, "digit 1 shape (2 segments: b,c)");
    CHECK(FPSOV_SEGMENTS[8] == 0x7F, "digit 8 shape (all 7 segments)");
    /* digit 1 must be exactly 2 segments lit (the classic "thin" digit) */
    int ones_bits = 0;
    for (int b = 0; b < 7; b++) if (FPSOV_SEGMENTS[1] & (1 << b)) ones_bits++;
    CHECK(ones_bits == 2, "digit 1 lights exactly 2 segments");
    /* digit 8 must light all 7 segments */
    int eight_bits = 0;
    for (int b = 0; b < 7; b++) if (FPSOV_SEGMENTS[8] & (1 << b)) eight_bits++;
    CHECK(eight_bits == 7, "digit 8 lights all 7 segments");

    if (failures) { printf("fps_overlay: %d FAILURES\n", failures); return 1; }
    printf("fps_overlay: all checks passed\n");
    return 0;
}
```

- [ ] **Step 3: Run the test to verify it passes**

```bash
cc -Wall -Wextra -O2 -I patches/mister tests/fps_overlay_test.c -o /tmp/fps_overlay_test && /tmp/fps_overlay_test
```

Expected: `fps_overlay: all checks passed`

- [ ] **Step 4: Register the test in `tests/run_tests.sh`**

In `tests/run_tests.sh`, find the final block:

```bash
echo "== loadbar (issue #72 progress-bar width math) =="
$CC -Wall -Wextra -O2 -I patches/mister \
    tests/loadbar_test.c \
    -o /tmp/loadbar_test
/tmp/loadbar_test

echo "All host tests passed."
```

Replace with:

```bash
echo "== loadbar (issue #72 progress-bar width math) =="
$CC -Wall -Wextra -O2 -I patches/mister \
    tests/loadbar_test.c \
    -o /tmp/loadbar_test
/tmp/loadbar_test

echo "== fps_overlay (OSD FPS overlay clamp + 7-segment digit table) =="
$CC -Wall -Wextra -O2 -I patches/mister \
    tests/fps_overlay_test.c \
    -o /tmp/fps_overlay_test
/tmp/fps_overlay_test

echo "All host tests passed."
```

- [ ] **Step 5: Add the header to the whole-file copy list**

In `scripts/apply_mister_files.sh`, find:

```bash
cp patches/mister/mister_blitter_renderer.cpp "$MDST/"
cp patches/mister/loadbar.h                 "$MDST/"
```

Replace with:

```bash
cp patches/mister/mister_blitter_renderer.cpp "$MDST/"
cp patches/mister/loadbar.h                 "$MDST/"
cp patches/mister/fps_overlay.h             "$MDST/"
```

- [ ] **Step 6: Declare the two free functions in the header**

In `patches/mister/mister_blitter_renderer.h`, find:

```cpp
// [residency] One-time whole-quest asset preload; call at quest-open (from MainLoop::run).
void mister_preload_quest_assets();

// [residency] Called from ~SurfaceImpl so the blitter cache never serves a freed-and-
// reused surface address (root cause of the render-corruption stale-pointer bug).
void mister_forget_surface(const Solarus::SurfaceImpl* p);

}  // namespace Solarus
```

Replace with:

```cpp
// [residency] One-time whole-quest asset preload; call at quest-open (from MainLoop::run).
void mister_preload_quest_assets();

// [residency] Called from ~SurfaceImpl so the blitter cache never serves a freed-and-
// reused surface address (root cause of the render-corruption stale-pointer bug).
void mister_forget_surface(const Solarus::SurfaceImpl* p);

// [OSD] True exactly once when the OSD "Restart Quest" toggle transitions off->on
// (edge-detection state lives in the renderer). Call once per frame from
// MainLoop::run(); false (never triggers) if the blitter renderer isn't active
// (SOLARUS_BLITTER unset / DDR map failed).
bool mister_osd_restart_requested();

// [OSD] Feed the current rolling FPS value to the renderer so it can draw the
// lower-right FPS overlay when the OSD "FPS Overlay" option is on. No-op if the
// blitter renderer isn't active.
void mister_set_fps(double fps);

}  // namespace Solarus
```

- [ ] **Step 7: Add renderer state + helper methods to `Impl`**

In `patches/mister/mister_blitter_renderer.cpp`, add the include near the
existing `loadbar.h` include:

```cpp
#include "loadbar.h"                  // issue #72: pure bar-width math
#include "fps_overlay.h"              // OSD FPS overlay: clamp + 7-seg digit table
```

Find the `[#72] load-progress-bar state` block:

```cpp
  // [#72] load-progress-bar state (set in preload_quest_assets, read in the drain seam)
  bool     loadbar_on     = false;   // cached SOLARUS_LOADBAR gate
  uint32_t preload_total  = 0;       // total PNGs to stage (pre-count)
  uint32_t preload_staged = 0;       // PNGs staged so far
  uint32_t loadbar_step   = 1;       // repaint the bar every N staged PNGs (~40 updates)
```

Add immediately after it:

```cpp
  // [OSD-restart] Edge-detect state for the OSD "Restart Quest" toggle (status[19],
  // mirrored into C_STATUS low32 bit0 by blitter_top's S_WR_STATUS write).
  bool prev_osd_restart = false;

  // [OSD-fps] Latest rolling FPS value (set by MainLoop via mister_set_fps() every
  // ~30 frames) and drawn in present() when the OSD "FPS Overlay" toggle
  // (status[20], mirrored into C_STATUS low32 bit1) is on.
  double fps_value = 0.0;
```

Find the `ddr_r32`/`ddr_w32` helpers:

```cpp
  void ddr_w32(uint32_t off, uint32_t v) {
    *reinterpret_cast<volatile uint32_t*>(ddr + off) = v;
  }
  uint32_t ddr_r32(uint32_t off) {
    return *reinterpret_cast<volatile uint32_t*>(ddr + off);
  }
```

Add immediately after it:

```cpp
  // [OSD-restart] True exactly once per off->on transition of C_STATUS low32 bit0.
  bool take_restart_edge() {
    if (!ddr) return false;
    bool cur = (ddr_r32(C_STATUS) & 0x1u) != 0;
    bool edge = cur && !prev_osd_restart;
    prev_osd_restart = cur;
    return edge;
  }

  // [OSD-fps] Whether the OSD "FPS Overlay" toggle is currently on (C_STATUS low32 bit1).
  bool fps_overlay_enabled() {
    return ddr && (ddr_r32(C_STATUS) & 0x2u) != 0;
  }
```

- [ ] **Step 8: Add the digit-drawing helpers**

In `patches/mister/mister_blitter_renderer.cpp`, find the loadbar geometry
constants:

```cpp
constexpr int FB_W = 320, FB_H = 240;

// [#72] Load-progress bar geometry (RGB565), bottom-right corner... (etc.)
```

Add new geometry/color constants immediately after the existing loadbar
constant block (before the `Video control word` comment that follows them):

```cpp
// [OSD-fps] FPS overlay geometry (RGB565), bottom-right corner of the 320x240 FB.
// 2 digits (0-99, per fps_overlay_clamp), 7-segment style, drawn as blt_fill rects.
static const int      FPSOV_DIGIT_W = 8;
static const int      FPSOV_DIGIT_H = 14;
static const int      FPSOV_SEG_T   = 2;    // segment thickness
static const int      FPSOV_GAP     = 2;    // gap between the two digits
static const int      FPSOV_MARGIN  = 4;    // margin from the FB's right/bottom edges
static const int      FPSOV_BG_PAD  = 2;    // background panel padding around the digits
static const uint16_t FPSOV_BG      = 0x0000;   // black background panel
static const uint16_t FPSOV_FG      = 0x07E0;   // green digits (RGB565)
```

Find `emit_loadbar_fills()`/`paint_loadbar()`:

```cpp
  void emit_loadbar_fills() {
    if (!loadbar_on) return;
    blt_fill(&em, 0, 0, FB_W, FB_H, LOADBAR_BG);
    blt_fill(&em, LOADBAR_TRACK_X, LOADBAR_TRACK_Y, LOADBAR_TRACK_W, LOADBAR_TRACK_H, LOADBAR_TRACK);
```

After the whole `paint_loadbar()` method that follows it (i.e. after its
closing `}`), add:

```cpp
  // [OSD-fps] Draw one 7-segment digit (0-9) via blt_fill segment rects.
  // (x,y) = top-left of the digit cell.
  void emit_fps_digit(int x, int y, int digit) {
    if (digit < 0 || digit > 9) return;
    uint8_t segs = FPSOV_SEGMENTS[digit];
    const int W = FPSOV_DIGIT_W, H = FPSOV_DIGIT_H, T = FPSOV_SEG_T;
    if (segs & 0x01) blt_fill(&em, x + 1,     y,             W - 2, T,       FPSOV_FG); // a
    if (segs & 0x02) blt_fill(&em, x + W - T, y + 1,         T,     H/2 - 1, FPSOV_FG); // b
    if (segs & 0x04) blt_fill(&em, x + W - T, y + H/2,       T,     H/2 - 1, FPSOV_FG); // c
    if (segs & 0x08) blt_fill(&em, x + 1,     y + H - T,     W - 2, T,       FPSOV_FG); // d
    if (segs & 0x10) blt_fill(&em, x,         y + H/2,       T,     H/2 - 1, FPSOV_FG); // e
    if (segs & 0x20) blt_fill(&em, x,         y + 1,         T,     H/2 - 1, FPSOV_FG); // f
    if (segs & 0x40) blt_fill(&em, x + 1,     y + (H-T)/2,   W - 2, T,       FPSOV_FG); // g
  }

  // [OSD-fps] Draw the 2-digit FPS readout (00-99) with a background panel, bottom-
  // right corner of the currently-open frame. Called from present() right before
  // blt_end_frame, so it overlays the game's own draws for this frame.
  void emit_fps_overlay_fills() {
    int fps = fps_overlay_clamp(fps_value);
    int tens = fps / 10, ones = fps % 10;
    const int total_w = FPSOV_DIGIT_W * 2 + FPSOV_GAP;
    const int x0 = FB_W - total_w - FPSOV_MARGIN;
    const int y0 = FB_H - FPSOV_DIGIT_H - FPSOV_MARGIN;
    blt_fill(&em, x0 - FPSOV_BG_PAD, y0 - FPSOV_BG_PAD,
             total_w + 2 * FPSOV_BG_PAD, FPSOV_DIGIT_H + 2 * FPSOV_BG_PAD, FPSOV_BG);
    emit_fps_digit(x0, y0, tens);
    emit_fps_digit(x0 + FPSOV_DIGIT_W + FPSOV_GAP, y0, ones);
  }
```

- [ ] **Step 9: Call the FPS overlay emission from `present()`**

In `patches/mister/mister_blitter_renderer.cpp`, find (in
`MisterBlitterRenderer::present`):

```cpp
  if (d->frame_active) {
    blt_end_frame(&d->em);
    d->ddr_w32(C_CMDCOUNT, (uint32_t)d->em.cmd_count);
```

Replace with:

```cpp
  if (d->frame_active) {
    if (d->fps_overlay_enabled()) d->emit_fps_overlay_fills();
    blt_end_frame(&d->em);
    d->ddr_w32(C_CMDCOUNT, (uint32_t)d->em.cmd_count);
```

- [ ] **Step 10: Define the free functions**

In `patches/mister/mister_blitter_renderer.cpp`, find:

```cpp
// [residency] Called from ~SurfaceImpl so the blitter cache never serves a freed-and-
// reused surface address (root cause of the render-corruption stale-pointer bug).
void mister_forget_surface(const Solarus::SurfaceImpl* p) {
  if (!p || !g_active_impl) return;
  g_active_impl->forget_surface(p);
}
```

Add immediately after it:

```cpp
// [OSD] See mister_blitter_renderer.h for contract.
bool mister_osd_restart_requested() {
  if (!g_active_impl) return false;
  return g_active_impl->take_restart_edge();
}

void mister_set_fps(double fps) {
  if (g_active_impl) g_active_impl->fps_value = fps;
}
```

- [ ] **Step 11: Run the full host test suite**

```bash
bash tests/run_tests.sh
```

Expected: every suite prints its "all checks passed"/success line, ending
with `All host tests passed.` (this does not compile
`mister_blitter_renderer.cpp` itself — that only cross-compiles in the armhf
Docker build, exercised in Task 5 — it validates the new pure-logic header and
that nothing else in the suite regressed).

- [ ] **Step 12: Commit**

```bash
git add patches/mister/fps_overlay.h tests/fps_overlay_test.c tests/run_tests.sh \
        patches/mister/mister_blitter_renderer.h patches/mister/mister_blitter_renderer.cpp \
        scripts/apply_mister_files.sh
git commit -m "feat: FPS overlay digit math + OSD restart/fps renderer bridge"
```

---

### Task 4: Engine — `MainLoop` wiring (restart trigger + always-on FPS accumulator)

**Files:**
- Modify: `work/solarus/src/core/MainLoop.cpp` (edited directly in the
  `work/solarus` git checkout, then exported)
- Create/regenerate: `patches/series/*.patch` (via `scripts/export_patches.sh`)

**Interfaces:**
- Consumes: `bool mister_osd_restart_requested()`, `void mister_set_fps(double fps)`
  (Task 3 Step 6), `MainLoop::set_resetting()` (existing,
  `work/solarus/src/core/MainLoop.cpp:340`).
- Produces: nothing consumed by later tasks.

`MainLoop.cpp` is an upstream Solarus file (not a `patches/mister/` whole-file
addition), so it's edited live in the `work/solarus` checkout and the diff is
captured as a new commit that `scripts/export_patches.sh` turns into a
`patches/series/*.patch` file — this is the project's existing authoring
workflow for edits to upstream files (see the header comment in
`scripts/export_patches.sh`).

- [ ] **Step 1: Ensure `work/solarus` is patched and up to date**

```bash
bash scripts/apply_patch_series.sh
```

Expected: ends with `[apply] OK` (clones/resets `work/solarus` to the pinned
upstream ref, applies all existing `patches/series/*.patch`, copies the
`patches/mister/**` whole-file additions from Task 3, runs the ast-grep gate).

- [ ] **Step 2: Add the restart-trigger check to the main loop**

In `work/solarus/src/core/MainLoop.cpp`, find (inside `MainLoop::run()`):

```cpp
    check_input();

    // 2. Update the world once, or several times (skipping some draws)
```

Replace with:

```cpp
    check_input();

    // [OSD] Restart Quest: edge-triggered on the OSD toggle (status[19], mirrored
    // through C_STATUS low32 bit0). Reuses Solarus's own in-engine reset — the
    // same effect as the internal Debug reset key, not a process relaunch.
    if (mister_osd_restart_requested()) {
      set_resetting();
    }

    // 2. Update the world once, or several times (skipping some draws)
```

- [ ] **Step 3: Add the always-on FPS accumulator**

In `work/solarus/src/core/MainLoop.cpp`, find the end of the existing
`mister_prof` diagnostic block:

```cpp
      if (++acc_n >= 30) {
        fprintf(stderr,
          "[MiSTer loop] fps=%.1f  logic=%.1fms  draw=%.1fms  steps/frame=%.1f\n",
          acc_period > 0 ? 1000.0 * acc_n / acc_period : 0.0,
          acc_logic / acc_n, acc_draw / acc_n, (double)acc_steps / acc_n);
        acc_logic = acc_draw = acc_period = 0; acc_steps = 0; acc_n = 0;
      }
    }

    // 4. Sleep if we have time, to save CPU and GPU cycles.
```

Replace with:

```cpp
      if (++acc_n >= 30) {
        fprintf(stderr,
          "[MiSTer loop] fps=%.1f  logic=%.1fms  draw=%.1fms  steps/frame=%.1f\n",
          acc_period > 0 ? 1000.0 * acc_n / acc_period : 0.0,
          acc_logic / acc_n, acc_draw / acc_n, (double)acc_steps / acc_n);
        acc_logic = acc_draw = acc_period = 0; acc_steps = 0; acc_n = 0;
      }
    }

    // [OSD-fps] Always-on rolling FPS counter, independent of the mister_prof
    // diagnostic flag above (the OSD toggle can flip live at any time) — feeds
    // the renderer's lower-right FPS overlay. Same 30-frame window as the
    // mister_prof block; a second small clock_gettime call per frame is cheap
    // and keeps this isolated from the existing diagnostic-only code above.
    {
      double fps_t = mister_ms();
      static double fps_acc_period = 0;
      static int fps_acc_n = 0;
      static double fps_last_t = 0;
      if (fps_last_t > 0) fps_acc_period += (fps_t - fps_last_t);
      fps_last_t = fps_t;
      if (++fps_acc_n >= 30) {
        double fps = fps_acc_period > 0 ? 1000.0 * fps_acc_n / fps_acc_period : 0.0;
        mister_set_fps(fps);
        fps_acc_period = 0; fps_acc_n = 0;
      }
    }

    // 4. Sleep if we have time, to save CPU and GPU cycles.
```

- [ ] **Step 4: Commit inside `work/solarus` and export the patch series**

```bash
cd work/solarus
git add -A
git commit -m "feat: MiSTer OSD restart trigger + always-on FPS accumulator"
cd ../..
bash scripts/export_patches.sh
```

Expected: `[export] regenerated N patches from work/solarus on v1.6` (N is one
more than before this task).

- [ ] **Step 5: Re-apply from scratch to confirm the exported patch round-trips**

```bash
bash scripts/apply_patch_series.sh
```

Expected: ends with `[apply] OK` — this resets `work/solarus` to pristine
upstream and re-applies every patch in `patches/series/` including the new
one, proving the exported patch is well-formed and applies cleanly (not just
that the live edit compiled).

- [ ] **Step 6: Commit the regenerated patch series**

```bash
git add patches/series/
git commit -m "chore: export MainLoop OSD restart/fps patch"
```

---

### Task 5: Full-stack build and HW validation

**Files:** none (build/deploy/test only)

**Interfaces:**
- Consumes: everything from Tasks 1-4.

- [ ] **Step 1: Cross-build the engine**

```bash
docker build -f Dockerfile.solarus-build -t solarus-armhf-build:bullseye .
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_engine.sh
```

Expected: build completes; `build/armhf/solarus-run` and
`build/armhf/libsolarus.so.1.6.5` exist and are newer than the source edits.

- [ ] **Step 2: Refresh the deploy artifacts**

```bash
cp build/armhf/solarus-run deploy/
cp build/armhf/libsolarus.so.1.6.5 deploy/libs/
strings deploy/libsolarus.so.1.6.5 | grep -c SOLARUS_BLT_THROTTLE
```

Expected: the `grep -c` prints a nonzero count (confirms the freshly-built
`.so`, not a stale one, per the project's known
`fpga-deploy-refresh-from-build-armhf` gotcha).

- [ ] **Step 3: Push the branch and let CI build the RBF**

```bash
git push -u origin HEAD
```

Watch `.github/workflows/build-rbf.yml` (the real Quartus synthesis gate —
`verilator-lint.yml` is advisory-only and doesn't cover `fpga/Solarus.sv` or
`fpga/sys/**`, so a clean lint run does not by itself confirm the RTL
synthesizes). Expected: the workflow succeeds and produces a downloadable
`solarus-rbf` artifact.

```bash
gh run download <run-id> -n solarus-rbf
```

- [ ] **Step 4: Deploy to hardware**

```bash
./deploy.py --host 192.168.20.81
```

Load the new `.rbf` from the MiSTer OSD (`_Other/`), then load the Solarus
core so `_handler.sh`/`quest_manager.sh` picks up the refreshed
`solarus-run`/`libsolarus.so.1.6.5`.

- [ ] **Step 5: HW-validate the 320x224 crop**

Pick a quest from the OSD, let it reach the overworld. Open the OSD, enable
"Vertical Crop (224p)". Expected: the visible image loses a symmetric ~8-line
band top and bottom (224 of 240 lines visible); `h_pos`/`v_pos` still work
normally with crop enabled; no scanout tear or garbage appears (the FB-in-BRAM
snapshot path is unaffected — this task never touched `comp_fbram`/the
blitter datapath, only `VGA_DE`/`VIDEO_ARX`/`VIDEO_ARY`). Toggle crop back off
and confirm the image returns to the full 240-line frame.

- [ ] **Step 6: HW-validate Restart Quest**

Start a quest, move the hero away from the starting position / open a menu.
Open the OSD, trigger "Restart Quest". Expected: the game returns to the
title/initial screen (matching Solarus's own internal reset — same behavior
as if the quest had called its own reset), with no crash, no black screen, and
no re-triggering of the SDRAM asset preload (check the log for the absence of
a second `preload_quest_assets` PNG-walk — the existing preload log line
should appear exactly once for the session). Repeat the trigger 5+ times in a
row (soak) to confirm no leak/crash across repeated resets.

- [ ] **Step 7: HW-validate the FPS overlay**

Open the OSD, enable "FPS Overlay". Expected: a 2-digit green number appears
in the bottom-right corner within ~0.5s (one 30-frame window), readable
against its black background panel, and updates roughly every half-second.
Walk into a known-heavy area (per the Phase 1 profiling baseline) and confirm
the number visibly drops; walk back to a light area and confirm it recovers.
Toggle the OSD option off mid-session and confirm the overlay disappears
immediately (same frame budget, no restart needed); toggle back on and
confirm it reappears.

- [ ] **Step 8: Record results**

If all three checks pass cleanly, this branch is ready for
`superpowers:finishing-a-development-branch`. If any HW check fails, drop back
to `superpowers:systematic-debugging` against the specific failing task rather
than re-deriving the whole feature.
