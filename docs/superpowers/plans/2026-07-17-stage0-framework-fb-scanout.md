# Stage 0 — Framework FB Scanout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route the finished frame to HDMI/analog through the MiSTer framework framebuffer (ascal reading DDR3 `@FB_BASE`), fed by a new `fb_writeout` block that bursts the on-chip `comp_fbram` SCAN image to DDR3 once per frame via `blitter_top`'s existing `bm_` master — **additively**, leaving the current renderer, tile path, audio, input, and quest-load intact.

**Architecture:** After the existing per-frame WORK→SCAN snapshot, a new `fb_writeout` module linearly walks the (now tear-free) SCAN buffer via `comp_fbram`'s freed `scan_rd_*` port and presents each 64-bit qword under a hold-until-accept handshake. `blitter_top`'s `bm_` DDR3 FSM drains that stream into single-beat writes at `FB_BASE` (the reader's already-reserved, now-unused DDR3 `FB0` buffer). `MISTER_FB` is enabled so the framework's `ascal` reads `FB_BASE` and owns scaling + tear-free triple-buffering; `openbor_video_reader`/`openbor_video_timing` stay intact (audio/joystick/cart/vsync keep working, syncs keep driving ascal's front-end, ascal ignores the reader's pixel data in FB mode).

**Tech Stack:** SystemVerilog (Quartus 17.0.2 / Icarus Verilog `iverilog -g2012` for sim), the `fpga/sim/run_sims.sh` harness, C for host-model tests, the existing `blt_*` host suite (`tests/run_tests.sh`).

## Global Constraints

- **Compositor/DDR clock:** `comp_fbram`, `blitter_top`, and `DDRAM_*` all run on `clk_sys = 98.4375 MHz` (PLL `outclk_0`, `fpga/Solarus.sv:187`). No new clock domain is introduced in this stage.
- **Framebuffer format:** RGB565, 320×240, linear (`FB_STRIDE = 640` bytes = `FB_WIDTH*2`). One qword = 4 pixels; `FB_QWORDS = 19200`.
- **`FB_BASE = 0x3A000040`** (byte) — the reader's existing DDR3 `FB0` buffer (`FB0_QW = 29'h07400008` = `0x3A000040 >> 3`), reserved-safe and no longer read from DDR3 since scanout moved on-chip. `FB1` (`0x3A040040`) stays free for future double-buffering. Do **not** use the framework's generic `0x3000_0000` example region — reuse the already-mapped `FB0`.
- **`MISTER_FB_PALETTE` MUST stay unset.** Enabling `MISTER_FB` re-exposes ascal's `pal1_mem`; leaving `MISTER_FB_PALETTE` undefined keeps `.PALETTE("false")` and avoids the documented `pll_hdmi` divclk STA regression (`fpga/Solarus.qsf:13-18`, `fpga/sys/sys_top.v:723-741`). Re-verify STA regardless (Task 5).
- **`openbor_video_reader` and `openbor_video_timing` are NOT deleted in this stage.** The reader multiplexes joystick→ARM, cart/`ioctl`, audio-ring drain, and the vsync heartbeat on one DDR3 master; the timing block drives `CLK_VIDEO`/`CE_PIXEL`/`VGA_HS/VS/DE`, which ascal still needs for genlock even in FB mode. Touching either is out of scope for Stage 0.
- **DDR3 arbiter (`ddr_blitter_arb`) is NOT modified.** `fb_writeout` reaches DDR3 only through `blitter_top`'s existing `bm_` master — no third arbiter slot.
- **Sim:** every testbench prints `RESULT: PASS`/`RESULT: FAIL` and `$finish` (no `$fatal`); the runner greps `RESULT: PASS`. Build+run one TB with `cd fpga/sim && bash run_sims.sh <tb_name>`.
- **No NEON in the engine build; no OpenGL anywhere** (unchanged; this stage doesn't touch the engine build).

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `fpga/rtl/fb_writeout.sv` | Create | SCAN-walk + hold-until-accept qword presenter (adapted from `fbram_to_sdram.sv`'s read side; reads `scan_rd_*`, straight RGB565, linear index). |
| `fpga/sim/tb_fb_writeout.sv` | Create | Unit TB: fill SCAN via `snap_*`, run `fb_writeout`, check every qword's data + linear index. |
| `fpga/rtl/blitter_defs.vh` | Modify | Add `FB_BASE_QW`, `FB_W`, `FB_H`, `FB_STRIDE_B`, `FB_QWORDS`, `FB_FORMAT_RGB565`. |
| `fpga/rtl/blitter_top.sv` | Modify | Instantiate `fb_writeout`; add post-snapshot `S_FBW_*` states that pulse `start` and drain the qword stream into single-beat `bm_wr` writes at `` `FB_BASE_QW ``; mux `scan_rd_*` (fb_writeout vs the reader's scan adapter). Expose `FB_*` config outputs. |
| `fpga/sim/tb_fbw_blitter_drain.sv` | Create | Integration TB: drive `blitter_top`'s snapshot→FBW sequence, assert DDR3 single-beat writes land at `FB_BASE_QW + i` with SCAN data. |
| `fpga/Solarus.sv` | Modify | Wire `MISTER_FB` FB_* outputs (`FB_EN/FB_FORMAT/FB_WIDTH/FB_HEIGHT/FB_BASE/FB_STRIDE/FB_FORCE_BLANK`) from `blitter_top`; keep `openbor_video_timing` driving syncs. |
| `fpga/Solarus.qsf` | Modify | Add `set_global_assignment -name VERILOG_MACRO "MISTER_FB=1"`. Leave `MISTER_FB_PALETTE` unset. |
| `tests/fb_geom_test.c` + `tests/run_tests.sh` | Create/Modify | Host-model guard: assert the FB geometry constants (stride=W*2, qwords=W*H/4, byte size) are internally consistent and match `blitter_defs.vh`. |

---

## Task 1: `fb_writeout` module + unit test

**Files:**
- Create: `fpga/rtl/fb_writeout.sv`
- Test: `fpga/sim/tb_fb_writeout.sv`

**Interfaces:**
- Consumes: `comp_fbram` SCAN read port (`scan_rd_en`, `scan_rd_qw[14:0]` → `scan_rd_qword[63:0]`, registered 1-cycle latency).
- Produces: `fb_writeout` with ports —
  `input clk, rst, start; output reg busy;`
  `output reg scan_rd_en; output reg [AW-1:0] scan_rd_qw; input [63:0] scan_rd_qword;`
  `output reg wr_en; output reg [AW-1:0] wr_idx; output reg [63:0] wr_data; input consumer_ready;`
  Params `FB_QWORDS=19200, AW=15`. Semantics: on a 1-cycle `start`, walk qwords `0..FB_QWORDS-1` of SCAN; present each on `wr_en`/`wr_idx`/`wr_data` **held stable** until the cycle `consumer_ready=1`; `busy` drops the cycle the last qword is accepted. `wr_idx` is the linear qword index (consumer adds `` `FB_BASE_QW ``).

- [ ] **Step 1: Write the failing test** — `fpga/sim/tb_fb_writeout.sv`

```systemverilog
`timescale 1ns/1ps
module tb_fb_writeout;
  reg clk = 0; always #5 clk = ~clk;
  reg rst = 1;

`ifdef FBW_FULL
  localparam integer NQW = 19200;   // full 320x240 (nightly)
`else
  localparam integer NQW = 800;     // reduced default: fast, still exercises the skid
`endif
  localparam integer AW = 15;

  // Fill SCAN via comp_fbram's snapshot write port; read it back via scan_rd_*.
  reg          snap_we=0; reg [AW-1:0] snap_qw=0; reg [63:0] snap_qword=0;
  wire         scan_rd_en; wire [AW-1:0] scan_rd_qw; wire [63:0] scan_rd_qword;
  wire [63:0]  rd_qword_unused;   // WORK read port tied off

  reg          start; wire busy;
  wire         wr_en; wire [AW-1:0] wr_idx; wire [63:0] wr_data;

  comp_fbram #(.FB_QWORDS(NQW), .AW(AW)) u_fbram (
    .clk(clk),
    .wr_en(1'b0), .wr_qw({AW{1'b0}}), .wr_lane(2'b0), .wr_pix(16'b0),
    .rd_en(1'b0), .rd_qw({AW{1'b0}}), .rd_qword(rd_qword_unused),
    .scan_rd_en(scan_rd_en), .scan_rd_qw(scan_rd_qw), .scan_rd_qword(scan_rd_qword),
    .snap_we(snap_we), .snap_qw(snap_qw), .snap_qword(snap_qword)
  );

  fb_writeout #(.FB_QWORDS(NQW), .AW(AW)) dut (
    .clk(clk), .rst(rst), .start(start), .busy(busy),
    .scan_rd_en(scan_rd_en), .scan_rd_qw(scan_rd_qw), .scan_rd_qword(scan_rd_qword),
    .wr_en(wr_en), .wr_idx(wr_idx), .wr_data(wr_data), .consumer_ready(1'b1)
  );

  function [63:0] qexp(input integer q); qexp = {~q[15:0], q[15:0], 16'hA55A, q[15:0]}; endfunction

  integer i, errors, seen;
  reg prev_wr_en;
  reg [63:0] captured [0:NQW-1];
  reg [AW:0] captured_idx [0:NQW-1];
  reg captured_v [0:NQW-1];

  initial begin
    errors=0; seen=0; start=0;
    for (i=0;i<NQW;i=i+1) captured_v[i]=0;
    @(negedge clk); rst<=0; @(negedge clk);

    // Load SCAN with a known per-qword pattern.
    for (i=0;i<NQW;i=i+1) begin
      @(negedge clk); snap_we<=1; snap_qw<=i[AW-1:0]; snap_qword<=qexp(i);
    end
    @(negedge clk); snap_we<=0;

    // Kick the writeout.
    @(negedge clk); start<=1; @(negedge clk); start<=0;

    // Capture on the RISING edge of wr_en (each new presentation), tolerating
    // single-cycle refill bubbles in the 2-slot skid.
    prev_wr_en=1'b0;
    for (i=0; i<NQW*3 && busy; i=i+1) begin
      @(posedge clk);
      if (wr_en && !prev_wr_en) begin
        captured[seen]=wr_data; captured_idx[seen]=wr_idx; captured_v[seen]=1; seen=seen+1;
      end
      prev_wr_en=wr_en;
    end
    repeat (4) @(posedge clk);

    if (seen != NQW) begin $display("FAIL: presented %0d qwords, expected %0d", seen, NQW); errors=errors+1; end
    for (i=0;i<NQW;i=i+1) begin
      if (!captured_v[i]) begin $display("FAIL: qword %0d never presented", i); errors=errors+1; end
      else if (captured[i] !== qexp(i)) begin $display("FAIL: qword %0d data: got %h want %h", i, captured[i], qexp(i)); errors=errors+1; end
      else if (captured_idx[i] !== i[AW:0]) begin $display("FAIL: qword %0d idx: got %0d want %0d", i, captured_idx[i], i); errors=errors+1; end
    end
    $display("RESULT: %s", (errors==0) ? "PASS" : "FAIL");
    $finish;
  end
endmodule
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd fpga/sim && bash run_sims.sh tb_fb_writeout`
Expected: FAIL — iverilog cannot elaborate (`Unknown module type: fb_writeout`) → the runner reports a build failure for `tb_fb_writeout`.

- [ ] **Step 3: Write the module** — `fpga/rtl/fb_writeout.sv`

```systemverilog
// fb_writeout.sv -- once-per-frame SCAN -> consumer qword streamer for the
// MISTER_FB framebuffer path. On a `start` pulse it linearly walks the entire
// comp_fbram SCAN buffer (the tear-free post-snapshot image) and presents each
// 64-bit qword (4x RGB565 px) on a hold-until-accept port. The consumer
// (blitter_top's bm_ DDR3 master) writes wr_data to DDR3 at `FB_BASE_QW + wr_idx`.
//
// Read/present pipeline is the stalled-safe 2-slot skid from fbram_to_sdram.sv:
//   SLOT A = wr_en/wr_idx/wr_data, held stable until consumer_ready.
//   SLOT B = v1/a1 (+ v1_rdy), the next item staged one comp_fbram read ahead.
// Unlike fbram_to_sdram this reads scan_rd_* (not rd_*), emits straight RGB565
// (no ARGB4444 pack), and the destination is linear (no per-row stride jump).
// Copyright (C) 2026 -- GPL-3.0
`default_nettype none
module fb_writeout #(
    parameter integer FB_QWORDS = 19200,   // 320*240/4
    parameter integer AW        = 15
)(
    input  wire          clk,
    input  wire          rst,
    input  wire          start,            // 1-cyc pulse: begin SCAN->consumer copy
    output reg           busy,
    // comp_fbram SCAN read port (registered: data valid 1 cyc after en/qw)
    output reg           scan_rd_en,
    output reg [AW-1:0]  scan_rd_qw,
    input  wire [63:0]   scan_rd_qword,
    // qword stream to consumer; HELD until consumer_ready pulses
    output reg           wr_en,
    output reg [AW-1:0]  wr_idx,
    output reg [63:0]    wr_data,
    input  wire          consumer_ready
);
    localparam [AW:0] NQW = FB_QWORDS[AW:0];
    localparam [AW:0] ONE = {{(AW){1'b0}},1'b1};
    reg [AW:0] rptr, wcnt;
    reg        v1, v1_rdy;
    reg [AW-1:0] a1;

    wire slotA_empty = !wr_en;
    wire retiring    = wr_en && consumer_ready;
    wire move_b2a    = slotA_empty && v1 && v1_rdy;
    wire v1_free     = !v1 || move_b2a;
    wire [AW:0] wcnt_next = wcnt + (retiring ? ONE : {(AW+1){1'b0}});

    always @(posedge clk) begin
        if (rst) begin
            busy<=1'b0; scan_rd_en<=1'b0; wr_en<=1'b0;
            rptr<={(AW+1){1'b0}}; wcnt<={(AW+1){1'b0}}; v1<=1'b0; v1_rdy<=1'b0;
        end else begin
            scan_rd_en<=1'b0;
            if (!busy) begin
                v1<=1'b0; v1_rdy<=1'b0; wr_en<=1'b0;
                if (start) begin busy<=1'b1; rptr<={(AW+1){1'b0}}; wcnt<={(AW+1){1'b0}}; end
            end else begin
                if (retiring) begin
                    wcnt <= wcnt_next;
                    if (wcnt_next == NQW) busy <= 1'b0;
                end
                // SLOT A: a retire ALWAYS clears wr_en for a 1-cycle gap; hand off
                // SLOT B only from an already-empty SLOT A.
                if (retiring) begin
                    wr_en <= 1'b0;
                end else if (move_b2a) begin
                    wr_en   <= 1'b1;
                    wr_idx  <= a1;
                    wr_data <= scan_rd_qword;   // v1_rdy guarantees this holds a1's data
                end
                if (v1 && !v1_rdy) v1_rdy <= 1'b1;
                if (v1_free) begin
                    if (rptr < NQW) begin
                        scan_rd_en<=1'b1; scan_rd_qw<=rptr[AW-1:0];
                        v1<=1'b1; a1<=rptr[AW-1:0];
                        rptr<=rptr+ONE;
                    end else v1<=1'b0;
                    v1_rdy <= 1'b0;
                end
            end
        end
    end
endmodule
`default_nettype wire
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd fpga/sim && bash run_sims.sh tb_fb_writeout`
Expected:
```
tb_fb_writeout             PASS
...
RESULT: PASS
```

- [ ] **Step 5: Run the backpressure case (add a stalling-consumer variant)**

Add a second `` `ifdef ``-selected consumer model to the same TB, or a sibling `tb_fb_writeout_backpressure.sv`, that deasserts `consumer_ready` for random multi-cycle stretches (mirror `tb_fbram_to_sdram_backpressure.sv`) and asserts the captured stream is still exactly `qexp(0..NQW-1)` in order with no drops/dupes.
Run: `cd fpga/sim && bash run_sims.sh tb_fb_writeout_backpressure`
Expected: `RESULT: PASS`.

- [ ] **Step 6: Commit**

```bash
git add fpga/rtl/fb_writeout.sv fpga/sim/tb_fb_writeout.sv fpga/sim/tb_fb_writeout_backpressure.sv
git commit -m "feat(fpga): fb_writeout SCAN->consumer qword streamer + TBs (Stage 0)"
```

---

## Task 2: FB geometry constants + host guard

**Files:**
- Modify: `fpga/rtl/blitter_defs.vh`
- Create: `tests/fb_geom_test.c`
- Modify: `tests/run_tests.sh`

**Interfaces:**
- Produces (RTL macros, consumed by Tasks 3–4): `` `FB_W ``=320, `` `FB_H ``=240, `` `FB_QWORDS ``=19200, `` `FB_STRIDE_B ``=640, `` `FB_BASE_QW ``=`29'h07400008`, `` `FB_FORMAT_RGB565 `` (5-bit, confirmed against `sys_top.v` in Step 2).

- [ ] **Step 1: Confirm the RGB565 `FB_FORMAT` encoding against the framework**

Run: `grep -nE "fb_format|FB_FORMAT|565|1555|o_fb_format" fpga/sys/sys_top.v fpga/sys/ascal.vhd | head -30`
Expected: identify the bit that selects 565 vs 1555 within `[3]` and RGB vs BGR within `[4]`. Record the resulting 5-bit value for **16bpp / 565 / RGB** (the `[2:0]=100` 16bpp field is certain; pin `[3]`/`[4]` from the grep). Write it into the macro in Step 3 with a comment citing the `sys_top.v` line.

- [ ] **Step 2: Write the failing host test** — `tests/fb_geom_test.c`

```c
/* Host guard for the MISTER_FB geometry constants (Stage 0). Pure C, native.
 * Build+run: cc tests/fb_geom_test.c -o /tmp/fb_geom_test && /tmp/fb_geom_test
 * Keeps the RTL FB layout self-consistent and matched to a 320x240 RGB565 linear FB.
 */
#include <stdio.h>
#include <stdint.h>
static int failures = 0;
#define CHECK(c,m) do{ if(!(c)){ printf("FAIL: %s (line %d)\n", (m), __LINE__); failures++; } }while(0)

/* Mirror of fpga/rtl/blitter_defs.vh FB_* macros — MUST match. */
#define FB_W        320
#define FB_H        240
#define FB_STRIDE_B 640
#define FB_QWORDS   19200
#define FB_BASE_BYTE 0x3A000040u   /* == (FB_BASE_QW << 3) */
#define FB_BASE_QW   0x07400008u

int main(void){
    CHECK(FB_STRIDE_B == FB_W*2, "stride is width*2 (RGB565)");
    CHECK(FB_QWORDS   == (FB_W*FB_H)/4, "qwords = W*H/4 (4 px per 64-bit qword)");
    CHECK((FB_BASE_QW << 3) == FB_BASE_BYTE, "FB_BASE_QW is FB_BASE_BYTE>>3");
    /* 150 KiB frame must fit below the vsync heartbeat at 0x3A070000. */
    CHECK(FB_BASE_BYTE + (unsigned)FB_STRIDE_B*FB_H <= 0x3A070000u, "FB0 frame clears vsync word");
    printf("RESULT: %s\n", failures ? "FAIL" : "PASS");
    return failures != 0;
}
```

- [ ] **Step 3: Run it to verify it fails, then add the RTL macros**

Run: `cc tests/fb_geom_test.c -o /tmp/fb_geom_test && /tmp/fb_geom_test`
Expected first run: PASS is fine here (the test encodes the intended invariants); its real job is to lock them. Now add to `fpga/rtl/blitter_defs.vh` (near the existing video-region defines):

```verilog
// ---- MISTER_FB framebuffer (Stage 0) --------------------------------------
`define FB_W          16'd320
`define FB_H          16'd240
`define FB_STRIDE_B   14'd640          // FB_W*2, RGB565 linear
`define FB_QWORDS     15'd19200        // FB_W*FB_H/4
`define FB_BASE_QW    29'h07400008     // 0x3A000040 (reader FB0, now free) >> 3
`define FB_BASE_BYTE  32'h3A000040
`define FB_FORMAT_RGB565 5'b0_0_100    // [2:0]=100 16bpp; [3]=565,[4]=RGB per sys_top.v:<LINE>
```

- [ ] **Step 4: Add the test to the suite**

In `tests/run_tests.sh`, following the existing `echo "== ... =="` + compile + run pattern, append:

```bash
echo "== fb_geom (MISTER_FB layout guard) =="
cc tests/fb_geom_test.c -o /tmp/fb_geom_test && /tmp/fb_geom_test
```

- [ ] **Step 5: Run the suite**

Run: `bash tests/run_tests.sh`
Expected: ends with `All host tests passed.` (includes the new `== fb_geom ==` PASS line).

- [ ] **Step 6: Commit**

```bash
git add fpga/rtl/blitter_defs.vh tests/fb_geom_test.c tests/run_tests.sh
git commit -m "feat(fpga): FB_* geometry macros + host layout guard (Stage 0)"
```

---

## Task 3: Integrate `fb_writeout` into `blitter_top` (post-snapshot DDR3 drain)

**Files:**
- Modify: `fpga/rtl/blitter_top.sv`
- Create: `fpga/sim/tb_fbw_blitter_drain.sv`

**Interfaces:**
- Consumes: Task 1 `fb_writeout`; Task 2 `` `FB_BASE_QW ``. The `bm_` master regs (`bm_wr`, `bm_addr`, `bm_din`, `bm_be`, single-beat, `mem_burstcnt=8'd1`); the SCAN read port to `comp_fbram` (`scan_rd_*`), currently owned by `fbram_scan_adapter`.
- Produces: config outputs from `blitter_top` for Task 4 — `fb_en`, `fb_format[4:0]`, `fb_width[11:0]`, `fb_height[11:0]`, `fb_base[31:0]`, `fb_stride[13:0]`, `fb_force_blank`. Behavior: exactly one full-frame single-beat write burst of `` `FB_QWORDS `` qwords to `` `FB_BASE_QW + i `` per frame, sequenced strictly after the WORK→SCAN snapshot completes.

- [ ] **Step 1: Write the failing integration test** — `fpga/sim/tb_fbw_blitter_drain.sv`

Instantiate `blitter_top` (or a thin harness exposing its snapshot→FBW sequence and the `bm_*`/`mem_*` write master), preload `comp_fbram` SCAN via `snap_*` with `qexp(i)`, trigger one frame's end-of-frame path (assert the same `vs`/submit conditions that reach `S_STATUS_DONE`→snapshot today), and capture every `mem_wr` single-beat write. Assert: exactly `` `FB_QWORDS `` writes, the i-th at address `` `FB_BASE_QW + i `` carrying `qexp(i)`, and that the first FB write happens only after `snap_busy` has fallen (ordering). Print `RESULT: PASS/FAIL`; `$finish`. Model the capture/pattern helpers on `tb_fb_writeout.sv` and the master-observation style of `tb_scanout_fbram.sv`.

- [ ] **Step 2: Run to verify it fails**

Run: `cd fpga/sim && bash run_sims.sh tb_fbw_blitter_drain`
Expected: FAIL — no `S_FBW_*` states yet; either the FB writes never appear (`presented 0 ... expected 19200`) or the address/order assertion trips.

- [ ] **Step 3: Add the `fb_writeout` instance + SCAN mux**

In `fpga/rtl/blitter_top.sv`, near the `u_snap` instantiation (~line 1074) and the `fb_rd_*` mux (~line 1176), add:

```verilog
    // ---- MISTER_FB writeout (Stage 0): SCAN -> DDR3 @FB_BASE, once per frame ----
    wire        fbw_busy, fbw_scan_rd_en; wire [14:0] fbw_scan_rd_qw;
    wire        fbw_wr_en;  wire [14:0] fbw_wr_idx;  wire [63:0] fbw_wr_data;
    reg         fbw_start;      // 1-cycle trigger, pulsed after snapshot completes
    reg         fbw_accept;     // consumer_ready: pulses when bm_ writes fbw_wr_data

    fb_writeout #(.FB_QWORDS(`FB_QWORDS), .AW(15)) u_fbw (
        .clk(clk), .rst(rst), .start(fbw_start), .busy(fbw_busy),
        .scan_rd_en(fbw_scan_rd_en), .scan_rd_qw(fbw_scan_rd_qw),
        .scan_rd_qword(scan_rd_qword_from_fbram),   // comp_fbram scan_rd_qword
        .wr_en(fbw_wr_en), .wr_idx(fbw_wr_idx), .wr_data(fbw_wr_data),
        .consumer_ready(fbw_accept)
    );

    // SCAN read port mux: fb_writeout owns it while draining; else the reader's
    // fbram_scan_adapter (existing). fb_writeout runs after snapshot, when the
    // reader is between lines -- but gate cleanly anyway.
    assign scan_rd_en_to_fbram = fbw_busy ? fbw_scan_rd_en : rdr_scan_rd_en;
    assign scan_rd_qw_to_fbram = fbw_busy ? fbw_scan_rd_qw : rdr_scan_rd_qw;
```

(Rename the existing `comp_fbram` `scan_rd_*` wiring in `fpga/Solarus.sv:530-536` so the reader path becomes `rdr_scan_rd_*` and the muxed signals feed `comp_fbram`. If `blitter_top` does not currently see `scan_rd_qword`, thread it in as a new input port.)

- [ ] **Step 4: Add the `S_FBW_*` drain states**

Add states after the snapshot completes (the code path around `S_STATUS_DONE`/`S_SNAP_*`, ~lines 940-961). Add `localparam S_FBW_START=6'd46, S_FBW_DRAIN=6'd47;` (use free encodings) and:

```verilog
    // reached once snapshot has finished (snap_busy fell) instead of returning
    // straight to S_POLL_SUBMIT:
    S_FBW_START: begin
        fbw_start <= 1'b1;              // 1-cycle kick
        fbw_wptr  <= 15'd0;
        state     <= S_FBW_DRAIN;
    end
    S_FBW_DRAIN: begin
        fbw_start  <= 1'b0;
        fbw_accept <= 1'b0;
        // Present fb_writeout's held qword as a single-beat DDR3 write.
        if (fbw_wr_en && !fbw_accept) begin
            bm_wr   <= 1'b1;
            bm_be   <= 8'hFF;
            bm_addr <= `FB_BASE_QW + {14'd0, fbw_wr_idx};
            bm_din  <= fbw_wr_data;
            fbw_accept <= 1'b1;         // tell fb_writeout this qword is taken
        end else begin
            bm_wr <= 1'b0;
        end
        if (!fbw_busy) begin
            bm_wr <= 1'b0;
            state <= S_POLL_SUBMIT;     // frame fully written; resume normal loop
        end
    end
```

Wire the entry: where the snapshot-drain today returns to `S_POLL_SUBMIT`, route to `S_FBW_START` instead. Declare `reg [14:0] fbw_wptr;` (used for assertions/debug; the address uses `fbw_wr_idx` directly). Ensure `bm_wr`'s existing accept handshake (the cycle `mem`/arb grants the write) is what gates `fbw_accept` — if `bm_wr` is not single-cycle-accept, gate `fbw_accept` on the same grant signal the other `bm_wr` writes use, so a stalled DDR3 write holds `fbw_wr_*` stable (that is exactly what `fb_writeout`'s hold-until-accept contract expects).

- [ ] **Step 5: Run the integration test to verify it passes**

Run: `cd fpga/sim && bash run_sims.sh tb_fbw_blitter_drain`
Expected: `RESULT: PASS` (19200 writes at `` `FB_BASE_QW+i ``, data `qexp(i)`, all after `snap_busy` fell).

- [ ] **Step 6: Run the full PR-tier sim suite (no regressions)**

Run: `cd fpga/sim && bash run_sims.sh`
Expected: final line `RESULT: PASS`, `gating-failures=0`. In particular `tb_fbram_snapshot`, `tb_scanout_fbram`, `tb_fbram_to_sdram` still PASS (the SCAN mux and new states must not disturb them).

- [ ] **Step 7: Commit**

```bash
git add fpga/rtl/blitter_top.sv fpga/rtl/comp_fbram.sv fpga/Solarus.sv fpga/sim/tb_fbw_blitter_drain.sv
git commit -m "feat(fpga): blitter_top drains fb_writeout to DDR3 @FB_BASE post-snapshot (Stage 0)"
```

---

## Task 4: Enable `MISTER_FB` + wire the FB_* config outputs

**Files:**
- Modify: `fpga/Solarus.qsf`
- Modify: `fpga/Solarus.sv`

**Interfaces:**
- Consumes: Task 3's `blitter_top` config outputs (`fb_en/fb_format/fb_width/fb_height/fb_base/fb_stride/fb_force_blank`); Task 2 macros.
- Produces: the core's `emu` `FB_*` outputs driven so ascal reads `FB_BASE`.

- [ ] **Step 1: Enable the macro**

In `fpga/Solarus.qsf`, next to the existing macro lines (`MENU_CORE`, `SOLARUS_CORE`, `MISTER_DISABLE_PALETTE1`), add:

```
set_global_assignment -name VERILOG_MACRO "MISTER_FB=1"
```

Do **not** add `MISTER_FB_PALETTE` (keeps ascal `.PALETTE("false")`).

- [ ] **Step 2: Drive the FB_* ports**

In `fpga/Solarus.sv`, inside the existing `` `ifdef MISTER_FB `` region (ports at lines 64-91), add continuous assigns from `blitter_top`'s new outputs:

```verilog
`ifdef MISTER_FB
    assign FB_EN          = 1'b1;
    assign FB_FORMAT      = `FB_FORMAT_RGB565;
    assign FB_WIDTH       = `FB_W[11:0];
    assign FB_HEIGHT      = `FB_H[11:0];
    assign FB_BASE        = `FB_BASE_BYTE;
    assign FB_STRIDE      = `FB_STRIDE_B;
    assign FB_FORCE_BLANK = 1'b0;
`endif
```

Confirm `openbor_video_timing` still drives `CLK_VIDEO`/`CE_PIXEL`/`VGA_HS/VS/DE` at `FB_WIDTH`×`FB_HEIGHT` timing (it does today via `NATIVE_VID_ACTIVE`; no change, but verify the active-region size matches 320×240 so ascal's genlock front-end sees a consistent frame).

- [ ] **Step 3: Build the RBF (Quartus 17.0.2)**

Run the project's existing bitstream build (per repo/CI; e.g. `quartus_sh --flow compile fpga/Solarus` or the documented `scripts`/CI path).
Expected: compile completes; `FB_EN`/`FB_*` now present in the netlist (grep the fitter report for `FB_BASE`). Note any new critical warnings.

- [ ] **Step 4: Commit**

```bash
git add fpga/Solarus.qsf fpga/Solarus.sv
git commit -m "feat(fpga): enable MISTER_FB, drive FB_* from blitter_top (Stage 0)"
```

---

## Task 5: STA re-verification gate (the `pll_hdmi` regression)

**Files:** none (build/analysis gate).

- [ ] **Step 1: Read the timing report for the previously-fixed path**

After the Task 4 build, open the Quartus STA report and check `pll_hdmi`/divclk setup slack (the path `fpga/Solarus.qsf:13-18` says re-enabling palette drove ~-1.0 ns).
Expected: **non-negative** worst-case slack on that domain. Since `MISTER_FB_PALETTE` is unset, `pal1_mem` should stay excluded — confirm in the fitter report that `pal1_mem` is absent.

- [ ] **Step 2: If negative — seed sweep / confirm palette exclusion**

If slack is negative or `pal1_mem` reappears, verify `sys_top.v:723-741`'s ifdef nesting resolves to `.PALETTE("false")` under `MISTER_FB && !MISTER_FB_PALETTE`; if the framework forces palette on under `MISTER_FB`, add the equivalent of `MISTER_DISABLE_PALETTE1` for the FB branch (or gate it). Re-run a multi-seed fit (the "10-seed sweep" the QSF comment references) and take the worst slack.
Expected: worst-case slack ≥ 0 across seeds before proceeding to HW.

- [ ] **Step 3: Record the result**

Note the slack number and seed in the commit/PR description for the HW gate. No code commit unless Step 2 required a palette-gate change (then commit that with `fix(fpga): keep ascal PALETTE off under MISTER_FB (STA)`).

---

## Task 6: HW validation gate + pacing measurement

**Files:** possibly `patches/mister/mister_blitter_renderer.cpp` (only if Step 4 switches pacing).

- [ ] **Step 1: Deploy and confirm framework video**

Deploy the RBF + current engine (`./deploy.py`, per CLAUDE.md deploy recipe), load the Solarus core, launch a quest.
Expected (**user's eyes — do not self-declare**): the game renders on HDMI/analog via ascal (scaled, aspect-correct), not a black screen. Confirm the picture matches pre-migration content.

- [ ] **Step 2: Confirm the non-video services still work**

Verify audio plays, joypad input reaches the engine, and quest load/switch works (the reader FSM is untouched, so these should be unaffected — this step proves the additive change didn't disturb them).
Expected: audio + input + quest-load all functional.

- [ ] **Step 3: Measure the two spec §8 open items**

- `FB_LL` vs full triple-buffer: observe input latency / tearing with the framework's default (triple-buffer) — `FB_LL` is a framework input; note whether latency is acceptable or whether a low-latency mode is wanted (record for a follow-up; no core change needed to observe).
- DDR3 contention: watch for frame-rate dips vs the pre-migration build on a heavy scene (the FB write adds ~19200 single-beat writes/frame to `bm_`'s DDR3 traffic). Capture fps on the parallax overworld and a town scene.
Expected: fps within noise of the pre-migration build (the FB write is off the compositor's critical path, issued post-snapshot).

- [ ] **Step 4: Pacing — measure, then optionally simplify**

The reader still writes the `vsync_count` heartbeat, so current pacing (`ensure_frame()` `mister_blitter_renderer.cpp:1072-1102`) works unchanged. With ascal now triple-buffering, test whether promoting the existing free-run path (`present()` `:4203-4218`, `SOLARUS_NO_VSYNC` behavior) to default gives smoother pacing without tearing (ascal absorbs it).
Expected: decide from the measurement. If free-run is smoother and tear-free under ascal, flip the default (guard with an env for A/B) and commit `perf(engine): default to free-run pacing under framework triple-buffer (Stage 0)`; otherwise leave vsync pacing as-is and record the finding.

- [ ] **Step 5: Record Stage 0 outcome + carry measurements to Stage 1 planning**

Note in the PR: STA slack, ascal video confirmed, `FB_LL`/contention findings, pacing decision. These feed the Stage 1 (overlay channel) plan.

---

## Self-review notes

- **Spec coverage:** implements spec §3 (framework FB scanout) and §7 Stage 0, corrected for the four fabric findings (reader is a multiplexed service FSM → left intact; ascal needs live syncs → timing block kept; DDRAM fully arbitrated → piggyback `bm_`, no arb change; `MISTER_FB` reopens STA → Task 5 gate + palette kept off).
- **No wholesale reader deletion** — deferred to a later cleanup stage per the approved "leave intact, ignore pixels" decision.
- **Testability:** `fb_writeout` is fully unit-tested in iverilog (Task 1); integration is sim-checked (Task 3); geometry is host-guarded (Task 2); ascal behavior + pacing + contention are HW-gated (Tasks 5–6) because ascal lives in `fpga/sys` and is out of the repo's sim scope.
- **Open sub-items to pin during execution:** exact `FB_FORMAT` `[3]`/`[4]` bits (Task 2 Step 1); the precise `bm_wr` grant signal to gate `fbw_accept` on (Task 3 Step 4); whether `blitter_top` needs a new `scan_rd_qword` input port (Task 3 Step 3).
