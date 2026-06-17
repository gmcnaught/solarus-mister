# VRAM Framebuffer Relocation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the blitter framebuffer off the HPS-shared f2h DDR bus onto the dedicated SDRAM bus — the blitter composites into an SDRAM framebuffer and the scanout reads it from SDRAM — so the scanout deadline is served by a deterministic bus and the issue #34 contention dissolves.

**Architecture:** A 3-client priority arbiter (`sdram_src_arb`) fronts the single `sdram_psx` controller: scanout read (strict highest), blitter source read, blitter dest read/write. An address-decode demux in `Solarus.sv` (new `vram_demux.sv` module) redirects the vendored blitter's FB-region `mem_*` accesses to the SDRAM dest port; everything else stays on DDR. The scanout reader becomes dual-bus: framebuffer line-fetch from SDRAM, control/joy/vsync/audio/cart still on DDR. The ARM-side persistence carry-forward `memcpy` becomes a fabric full-screen FB→FB blit.

**Tech Stack:** SystemVerilog (Quartus / Cyclone V, M10K BRAM), Icarus Verilog (`iverilog -g2012`) for sims, C++ (`mister_blitter_renderer.cpp` + `blt_emitter`) for the host side. Source spec: `docs/superpowers/specs/2026-06-17-vram-framebuffer-relocation-design.md`.

## Global Constraints

- **Do NOT edit the vendored `fpga/rtl/blitter_top.sv`** (header: "edit upstream + re-copy"). All blitter dest redirection happens in the integration layer.
- **SDRAM chip:** `AS4C32M16` 64 MB; row=`addr[25:13]`, col=`addr[10:1]`; addresses are **byte** addresses, 27-bit (`[26:0]`), `addr[0]=0` for 16-bit mode.
- **SDRAM FB map:** FB0 = `0x0400000`, FB1 = `0x0440000`, stride = 640 B/line, one buffer = 153,600 B (`0x25800`) in a `0x40000` slot. Source-texture heap occupies `0x000000..0x3FFFFF` (must not overrun `0x400000`).
- **Blitter DDR FB qword bases (decode these):** `FB0_QW = 29'h07400008`, `FB1_QW = 29'h07408008`, `FB_QWORDS = 19200`. (From `fpga/rtl/blitter_defs.vh`.)
- **Source path unchanged:** per-command mux `src_in_sdram = srcsel && (c_flags & F_SRC_SDRAM)`; `C_SRCSEL` master-enable stays 1.
- **Full commit:** no DDR-framebuffer fallback path; the DDR-FB scanout read path and the ARM carry-forward memcpy are deleted.
- **TDD / sim-first:** every RTL task writes/extends the testbench and watches it FAIL before implementing. Commit after each green task.
- Commit messages end with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## File Structure

- **Create** `fpga/rtl/vram_defs.vh` — SDRAM FB byte bases + blitter DDR FB qword bases (shared by demux + reader + `Solarus.sv`).
- **Create** `fpga/rtl/vram_demux.sv` — address-decode demux: blitter `mem_*` → DDR (`blt_*`) or SDRAM (`P_DST`). Novel logic; the bulk of the new RTL.
- **Modify** `fpga/rtl/sdram_src_arb.sv` — grow from 1 client to a 3-client fixed-priority arbiter (P_SCAN > P_SRC > P_DST).
- **Modify** `fpga/rtl/openbor_video_reader.sv` — add an SDRAM read master; route only the line-fetch states to it; `buf_base_addr` → SDRAM FB base.
- **Modify** `fpga/Solarus.sv` — instantiate `vram_demux`; wire the 3 arbiter clients (reader P_SCAN, blitter src P_SRC, demux P_DST); delete the reader's DDR-FB line-fetch wiring.
- **Modify** `patches/mister/mister_blitter_renderer.cpp` (+ `blt_emitter` API) — replace the ARM carry-forward `memcpy` with a full-screen FB_prev→FB_cur `OP_BLIT`; ensure `C_SRCSEL` master-enable = 1.
- **Create** `fpga/sim/tb_vram_demux.sv` — demux unit test.
- **Create** `fpga/sim/tb_scanout_sdram.sv` — scanout-from-SDRAM datapath test (clone of `tb_scanout_linebuf.sv`).
- **Modify** `fpga/sim/tb_sdram_src_arb.sv` — 3-client priority + no-starvation assertions.
- **Modify** `fpga/sim/tb_blitter_system.sv` — dst→SDRAM regression (+ carry-forward copy check).

---

## Task 1: 3-client priority SDRAM arbiter

Grow `sdram_src_arb` (today: one port `p0` carrying blitter source reads + staging writes) into a fixed-priority arbiter over the single `sdram_psx` command interface, with **P_SCAN** (scanout read, strict highest), **P_SRC** (= today's `p0`), **P_DST** (blitter dest read/write from the demux).

**Files:**
- Modify: `fpga/rtl/sdram_src_arb.sv`
- Test: `fpga/sim/tb_sdram_src_arb.sv`

**Interfaces:**
- Produces (to `Solarus.sv` and the demux/reader):
  - `P_SCAN`: `scan_addr[26:0]`, `scan_rd`, `scan_burst[7:0]`, `scan_busy`, `scan_dout64[63:0]`, `scan_dready`.
  - `P_SRC`: the existing `p0_*` ports, renamed only if convenient (keep `p0_*` to avoid churn).
  - `P_DST`: `dst_addr[26:0]`, `dst_rd`, `dst_we` (16-bit word write), `dst_din[15:0]`, `dst_we_burst`, `dst_din64[63:0]`, `dst_busy`, `dst_dout64[63:0]`, `dst_dready`.
- Consumes: the `c_*` controller-facing port to `sdram_psx` (unchanged signature).
- **Priority:** P_SCAN > P_SRC > P_DST. A granted read burst is held until its last beat (`c_ready`/beat count) before re-arbitrating, so beats are never interleaved between clients.

- [ ] **Step 1: Read the current arbiter and tb to learn the controller handshake**

Run: `sed -n '36,90p' fpga/rtl/sdram_src_arb.sv` and `sed -n '1,60p' fpga/sim/tb_sdram_src_arb.sv`
Expected: confirm the single-port grant uses `c_busy` to gate acceptance and routes `c_rd`/`c_we`/`c_we_burst`; note how the existing tb drives `p0_*` and models `sdram_psx`/`c_ready`.

- [ ] **Step 2: Add the failing 3-client priority test**

Append to `fpga/sim/tb_sdram_src_arb.sv` a scenario that drives all three clients and asserts ordering + no starvation. Add inside the module:

```systemverilog
  // ---- 3-client priority assertions (Task 1) ----------------------------
  // Drive P_SCAN + P_SRC + P_DST simultaneously; P_SCAN must win every grant
  // while it is requesting, and P_DST must still eventually be served (no
  // starvation) once P_SCAN goes idle.
  integer scan_grants = 0, dst_grants = 0;
  task drive_three_clients;
    begin
      // assert all three requests
      scan_rd = 1'b1; scan_addr = 27'h0400000; scan_burst = 8'd80;
      p0_rd   = 1'b1; p0_addr   = 27'h0001000;          // P_SRC
      dst_rd  = 1'b1; dst_addr  = 27'h0410000;          // P_DST
      // observe: while scan_rd, no dst read is accepted by the controller
      repeat (200) begin
        @(posedge clk);
        if (c_rd && c_addr == 27'h0410000 && scan_busy_active)
          begin $display("RESULT: FAIL (P_DST served while P_SCAN active)"); $finish; end
      end
      scan_rd = 1'b0;                                    // P_SCAN idle -> P_DST must drain
      repeat (400) @(posedge clk);
      if (dst_grants == 0) begin $display("RESULT: FAIL (P_DST starved)"); $finish; end
    end
  endtask
```

Add a `scan_busy_active` helper wire (`= scan_rd | (controller mid-scan-burst)`) and increment `scan_grants`/`dst_grants` on the respective grant strobes. Wire the new `scan_*`/`dst_*` ports to the DUT instance (they don't exist yet → the tb won't compile, which is the failing state).

- [ ] **Step 3: Run the test to confirm it fails (ports undefined)**

Run:
```bash
cd fpga/sim
iverilog -g2012 -o arb.vvp tb_sdram_src_arb.sv ../rtl/sdram_src_arb.sv ../rtl/sdram_psx.sv sdram_chip_model.sv
```
Expected: FAIL — `port ``scan_rd`` is not a port of` / unknown ports (the 3-client ports don't exist yet).

- [ ] **Step 4: Implement the 3-client priority arbiter**

Rewrite `fpga/rtl/sdram_src_arb.sv`'s port list + grant logic. Keep `p0_*` (= P_SRC) and the `c_*` controller port; add `scan_*` and `dst_*`. Replace the single-port grant `always` with a registered-grant priority FSM:

```systemverilog
  // owner: 0=none,1=SCAN,2=SRC,3=DST. A read burst HOLDS the owner until its
  // last beat returns (track outstanding beats via scan_burst / 1-beat src+dst).
  reg [1:0] owner;
  reg [7:0] beats_left;           // outstanding read beats for the held owner
  wire any_busy = c_busy;
  wire scan_req = scan_rd;
  wire src_req  = p0_rd | p0_we | p0_we_burst;
  wire dst_req  = dst_rd | dst_we | dst_we_burst;

  always @(posedge clk) begin
    if (reset) begin owner<=2'd0; beats_left<=8'd0; c_rd<=0; c_we<=0; c_we_burst<=0; end
    else begin
      c_rd<=0; c_we<=0; c_we_burst<=0;
      if (beats_left != 8'd0) begin
        if (c_ready) beats_left <= beats_left - 8'd1;  // drain the held read burst
      end else if (!any_busy) begin
        // re-arbitrate (strict priority): SCAN > SRC > DST
        if (scan_req) begin
          owner<=2'd1; c_addr<=scan_addr; c_rd<=1'b1; beats_left<=scan_burst;
        end else if (src_req) begin
          owner<=2'd2;
          if (p0_rd) begin c_addr<=p0_addr; c_rd<=1'b1; beats_left<=8'd1; end
          else if (p0_we_burst) begin c_addr<=p0_waddr; c_din64<=p0_din64; c_we_burst<=1'b1; end
          else begin c_addr<=p0_waddr; c_din<=p0_din; c_we<=1'b1; end
        end else if (dst_req) begin
          owner<=2'd3;
          if (dst_rd) begin c_addr<=dst_addr; c_rd<=1'b1; beats_left<=8'd1; end
          else if (dst_we_burst) begin c_addr<=dst_addr; c_din64<=dst_din64; c_we_burst<=1'b1; end
          else begin c_addr<=dst_addr; c_din<=dst_din; c_we<=1'b1; end
        end else owner<=2'd0;
      end
    end
  end

  // route the controller's read beats back to the OWNER. `c_dready`/`c_dout64`
  // are the controller's per-beat strobe/data — match the exact names sdram_psx
  // exposes (the existing single-port code already consumes them).
  assign scan_dready = c_dready & (owner==2'd1);   assign scan_dout64 = c_dout64;
  assign p0_grant    = (owner==2'd2);              // existing P_SRC read beat is
  assign p0_dready   = c_dready & (owner==2'd2);   // routed to bs_src_* in Solarus.sv
  assign dst_dready  = c_dready & (owner==2'd3);   assign dst_dout64  = c_dout64;
  assign scan_busy   = (owner!=2'd1) | c_busy;
  assign p0_busy     = (owner!=2'd2) | c_busy;
  assign dst_busy    = (owner!=2'd3) | c_busy;
```

Note: `sps_dready`/`sps_dout64` are the controller's per-beat strobe/data (currently `c_ready`-adjacent in `sdram_psx`). Match the exact controller beat signal names used in the existing single-port routing — verify against `sdram_psx.sv`'s `dout_ready`/`dout64`.

- [ ] **Step 5: Run the test to verify it passes**

Run:
```bash
cd fpga/sim
iverilog -g2012 -o arb.vvp tb_sdram_src_arb.sv ../rtl/sdram_src_arb.sv ../rtl/sdram_psx.sv sdram_chip_model.sv
vvp arb.vvp
```
Expected: existing single-port assertions still PASS; `RESULT: PASS` with no "P_DST served while P_SCAN active" and no "P_DST starved".

- [ ] **Step 6: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
git add fpga/rtl/sdram_src_arb.sv fpga/sim/tb_sdram_src_arb.sv
git commit -m "feat(#34): 3-client priority SDRAM arbiter (scanout > src > dst)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: VRAM defs header + integration demux module

**Files:**
- Create: `fpga/rtl/vram_defs.vh`
- Create: `fpga/rtl/vram_demux.sv`
- Test: `fpga/sim/tb_vram_demux.sv`

**Interfaces:**
- Consumes: blitter `mem_*` (qword-addressed, `[31:0]` carrying a 29-bit range), the DDR `blt_*` port of `ddr_blitter_arb`, and the SDRAM arbiter `P_DST` port (Task 1).
- Produces: transparent routing — FB-region accesses → SDRAM (translated byte address), all else → DDR. Read `dout`/`dout_ready` routed back from the bus the read went to. Full-qword writes (all 4 lanes) → SDRAM burst write; partial writes → serialized 16-bit word writes.

- [ ] **Step 1: Create the defs header**

Create `fpga/rtl/vram_defs.vh`:
```systemverilog
`ifndef VRAM_DEFS_VH
`define VRAM_DEFS_VH
// SDRAM framebuffer (VRAM) BYTE addresses. Scanout reads FB here; the Solarus.sv
// demux redirects the blitter's DDR FB writes here. 64MB AS4C32M16.
//   0x000000..0x3FFFFF = source-texture heap (existing #19 staging mirror)
`define SDRAM_FB0_BASE  27'h0400000   // FB0  (320x240 RGB565 = 0x25800 B; 0x40000 slot)
`define SDRAM_FB1_BASE  27'h0440000   // FB1
`define SDRAM_FB_STRIDE 27'd640       // 320 px * 2 B = one scanline
// Blitter DDR FB qword bases (MUST MATCH blitter_defs.vh FB0_QW/FB1_QW). The demux
// decodes these and remaps to the SDRAM bases above; the reader uses the SDRAM bases.
`define FB_DDR0_QW   29'h07400008
`define FB_DDR1_QW   29'h07408008
`define FB_QWORDS    29'd19200        // 320*240*2/8
`endif
```

- [ ] **Step 2: Verify the source-heap extent does not overrun FB0**

Run: `grep -nE 'SRC_QW|heap|0x3B400000|3F8000' fpga/rtl/blitter_defs.vh`
Expected: the SDRAM staging mirror occupies the DDR SRC-heap offset range (~`0x3F8000` ≈ 4.06 MiB), i.e. below `0x400000`. Confirm `SDRAM_FB0_BASE = 0x400000` clears it. If the heap is larger, bump `SDRAM_FB0_BASE`/`FB1` up (and note it) before continuing.

- [ ] **Step 3: Write the failing demux unit test**

Create `fpga/sim/tb_vram_demux.sv`:
```systemverilog
`timescale 1ns/1ps
`default_nettype none
`include "../rtl/vram_defs.vh"
module tb_vram_demux;
  reg clk=0; always #5 clk=~clk;
  reg reset=1;

  // blitter side
  reg  [31:0] blt_addr=0; reg blt_rd=0, blt_wr=0; reg [63:0] blt_din=0; reg [7:0] blt_be=0;
  wire [63:0] blt_dout; wire blt_dready; wire blt_busy;
  // DDR side (behavioral)
  wire [28:0] ddr_addr; wire ddr_rd, ddr_wr; wire [63:0] ddr_din; wire [7:0] ddr_be;
  reg  [63:0] ddr_dout=64'hD00D_D00D_D00D_D00D; reg ddr_dready=0; reg ddr_busy=0;
  // SDRAM side (behavioral 16-word memory)
  wire [26:0] sd_addr; wire sd_rd, sd_we, sd_we_burst; wire [15:0] sd_din; wire [63:0] sd_din64;
  reg  [63:0] sd_dout64=64'hBEEF_BEEF_BEEF_BEEF; reg sd_dready=0; reg sd_busy=0;
  reg [15:0] sdmem [0:1<<20];

  vram_demux dut(.clk(clk),.reset(reset),
    .blt_addr(blt_addr),.blt_rd(blt_rd),.blt_wr(blt_wr),.blt_din(blt_din),.blt_be(blt_be),
    .blt_dout(blt_dout),.blt_dout_ready(blt_dready),.blt_busy(blt_busy),
    .ddr_addr(ddr_addr),.ddr_rd(ddr_rd),.ddr_wr(ddr_wr),.ddr_din(ddr_din),.ddr_be(ddr_be),
    .ddr_dout(ddr_dout),.ddr_dout_ready(ddr_dready),.ddr_busy(ddr_busy),
    .sd_addr(sd_addr),.sd_rd(sd_rd),.sd_din(sd_din),.sd_we(sd_we),
    .sd_din64(sd_din64),.sd_we_burst(sd_we_burst),
    .sd_dout64(sd_dout64),.sd_dready(sd_dready),.sd_busy(sd_busy));

  integer errs=0;
  // model the SDRAM 16-bit word writes
  always @(posedge clk) begin
    if (sd_we)        sdmem[sd_addr[20:1]] <= sd_din;
    if (sd_we_burst)  begin
      sdmem[sd_addr[20:1]+0]<=sd_din64[15:0];  sdmem[sd_addr[20:1]+1]<=sd_din64[31:16];
      sdmem[sd_addr[20:1]+2]<=sd_din64[47:32]; sdmem[sd_addr[20:1]+3]<=sd_din64[63:48];
    end
  end

  initial begin
    repeat(4) @(posedge clk); reset=0; @(posedge clk);

    // 1) NON-FB write routes to DDR (RING region), NOT SDRAM
    blt_addr=32'h07600008; blt_wr=1; blt_din=64'h1; blt_be=8'hFF; @(posedge clk);
    if (!ddr_wr || sd_we || sd_we_burst) begin $display("FAIL: ring write not on DDR"); errs=errs+1; end
    blt_wr=0; @(posedge clk);

    // 2) FB0 full-qword write routes to SDRAM as a BURST write, address remapped
    blt_addr={3'd0,`FB_DDR0_QW};               // first qword of FB0
    blt_wr=1; blt_din=64'hAAAA_BBBB_CCCC_DDDD; blt_be=8'hFF; @(posedge clk);
    if (!sd_we_burst || ddr_wr) begin $display("FAIL: FB full-qword not a SDRAM burst"); errs=errs+1; end
    if (sd_addr !== `SDRAM_FB0_BASE) begin $display("FAIL: FB0 base addr remap %h", sd_addr); errs=errs+1; end
    blt_wr=0; @(posedge clk);

    // 3) FB1 single-pixel (one lane) write -> a SINGLE 16-bit SDRAM word at lane col
    blt_addr={3'd0,`FB_DDR1_QW + 29'd5};        // qword 5 of FB1
    blt_wr=1; blt_din=64'h0000_0000_1234_0000; blt_be=8'h0C; @(posedge clk); // lane1 (bytes 2-3)
    // expect one sd_we to SDRAM_FB1_BASE + 5*8 + 1*2 (col word = qw*4 + lane)
    @(posedge clk);
    if (sdmem[(`SDRAM_FB1_BASE + 5*8 + 1*2) >> 1] !== 16'h1234) begin
      $display("FAIL: FB1 lane write wrong word"); errs=errs+1; end
    blt_wr=0; @(posedge clk);

    // 4) FB read routes to SDRAM, dout returns from sd_dout64
    sd_dout64=64'hCAFE_CAFE_CAFE_CAFE;
    blt_addr={3'd0,`FB_DDR0_QW + 29'd10}; blt_rd=1; @(posedge clk); blt_rd=0;
    sd_dready=1; @(posedge clk); sd_dready=0;
    if (blt_dout !== 64'hCAFE_CAFE_CAFE_CAFE) begin $display("FAIL: FB read dout not from SDRAM"); errs=errs+1; end

    // 5) NON-FB read routes to DDR, dout returns from ddr_dout
    blt_addr=32'h07600008; blt_rd=1; @(posedge clk); blt_rd=0;
    ddr_dready=1; @(posedge clk); ddr_dready=0;
    if (blt_dout !== 64'hD00D_D00D_D00D_D00D) begin $display("FAIL: ring read dout not from DDR"); errs=errs+1; end

    if (errs==0) $display("RESULT: PASS"); else $display("RESULT: FAIL (%0d)", errs);
    $finish;
  end
endmodule
`default_nettype wire
```

- [ ] **Step 4: Run to confirm it fails (no module yet)**

Run:
```bash
cd fpga/sim
iverilog -g2012 -o demux.vvp tb_vram_demux.sv ../rtl/vram_demux.sv
```
Expected: FAIL — `Unable to find ... vram_demux` (the module doesn't exist).

- [ ] **Step 5: Implement `vram_demux.sv`**

Create `fpga/rtl/vram_demux.sv`:
```systemverilog
`default_nettype none
`include "vram_defs.vh"
// Address-decode demux: routes the vendored blitter's mem_* between the DDR
// arbiter (blt_* port) and the SDRAM arbiter (P_DST). FB0/FB1 region -> SDRAM
// (byte-address remapped); everything else -> DDR. Single outstanding mem_*
// access (blitter is simple per-pixel), so a 1-deep "which bus" latch routes
// the read beat back. Full-qword writes (all 4 lanes) -> SDRAM burst write;
// partial writes -> serialized 16-bit word writes (1..4).
module vram_demux (
  input  wire        clk, reset,
  // blitter mem_* (qword-addressed)
  input  wire [31:0] blt_addr,
  input  wire        blt_rd, blt_wr,
  input  wire [63:0] blt_din,
  input  wire [7:0]  blt_be,
  output reg  [63:0] blt_dout,
  output reg         blt_dout_ready,
  output wire        blt_busy,
  // DDR side (ddr_blitter_arb blt_* port)
  output wire [28:0] ddr_addr,
  output wire        ddr_rd, ddr_wr,
  output wire [63:0] ddr_din,
  output wire [7:0]  ddr_be,
  input  wire [63:0] ddr_dout,
  input  wire        ddr_dout_ready,
  input  wire        ddr_busy,
  // SDRAM side (arbiter P_DST)
  output reg  [26:0] sd_addr,
  output reg         sd_rd,
  output reg  [15:0] sd_din,
  output reg         sd_we,
  output reg  [63:0] sd_din64,
  output reg         sd_we_burst,
  input  wire [63:0] sd_dout64,
  input  wire        sd_dready,
  input  wire        sd_busy
);
  wire [28:0] qw = blt_addr[28:0];
  wire in_fb0 = (qw >= `FB_DDR0_QW) && (qw < (`FB_DDR0_QW + `FB_QWORDS));
  wire in_fb1 = (qw >= `FB_DDR1_QW) && (qw < (`FB_DDR1_QW + `FB_QWORDS));
  wire is_fb  = in_fb0 | in_fb1;
  wire [28:0] off_qw  = in_fb1 ? (qw - `FB_DDR1_QW) : (qw - `FB_DDR0_QW);
  wire [26:0] fb_base = in_fb1 ? `SDRAM_FB1_BASE : `SDRAM_FB0_BASE;
  wire [26:0] qw_byte = fb_base + {off_qw[23:0], 3'b000};   // *8

  // DDR passthrough (non-FB)
  assign ddr_addr = qw;
  assign ddr_rd   = blt_rd & ~is_fb;
  assign ddr_wr   = blt_wr & ~is_fb;
  assign ddr_din  = blt_din;
  assign ddr_be   = blt_be;

  // full-qword detect (all four 16-bit lanes enabled)
  wire all_lanes = (blt_be == 8'hFF);

  // partial-write serializer: walk lanes 0..3, emit a 16-bit write per enabled lane
  localparam S_IDLE=2'd0, S_RDLAT=2'd1, S_WLANES=2'd2;
  reg [1:0]  st;
  reg [1:0]  lane;
  reg        rd_on_sdram;            // last read routed to SDRAM?

  wire lane_en = blt_be[lane*2] | blt_be[lane*2+1];

  assign blt_busy = ddr_busy & ~is_fb ? ddr_busy : (st != S_IDLE) | (is_fb & sd_busy);

  always @(posedge clk) begin
    if (reset) begin
      st<=S_IDLE; lane<=2'd0; sd_rd<=0; sd_we<=0; sd_we_burst<=0;
      blt_dout_ready<=0; rd_on_sdram<=0;
    end else begin
      sd_rd<=0; sd_we<=0; sd_we_burst<=0; blt_dout_ready<=0;
      case (st)
        S_IDLE: begin
          if (is_fb & blt_rd & ~sd_busy) begin
            sd_addr<=qw_byte; sd_rd<=1'b1; rd_on_sdram<=1'b1; st<=S_RDLAT;
          end else if (is_fb & blt_wr & ~sd_busy) begin
            if (all_lanes) begin
              sd_addr<=qw_byte; sd_din64<=blt_din; sd_we_burst<=1'b1;  // one burst
            end else begin
              lane<=2'd0; st<=S_WLANES;                                 // serialize
            end
          end else if (~is_fb & blt_rd) begin
            rd_on_sdram<=1'b0;   // DDR read; dout routed below
          end
        end
        S_RDLAT: begin
          if (sd_dready) begin blt_dout<=sd_dout64; blt_dout_ready<=1'b1; st<=S_IDLE; end
        end
        S_WLANES: begin
          if (!sd_busy) begin
            if (lane_en) begin
              sd_addr<= qw_byte + {off_lane(lane)};
              sd_din <= blt_din[lane*16 +: 16];
              sd_we  <= 1'b1;
            end
            if (lane==2'd3) st<=S_IDLE; else lane<=lane+2'd1;
          end
        end
      endcase
      // DDR read beat -> blitter (when the outstanding read was DDR)
      if (ddr_dout_ready & ~rd_on_sdram) begin blt_dout<=ddr_dout; blt_dout_ready<=1'b1; end
    end
  end

  // lane (0..3) -> byte offset within the qword (2 bytes per 16-bit word)
  function [26:0] off_lane(input [1:0] l); off_lane = {25'd0, l, 1'b0}; endfunction
endmodule
`default_nettype wire
```

> Reference implementation — iterate against `tb_vram_demux.sv` until green. Watch: `blt_busy` must hold during the multi-lane serialize so the blitter stalls; the read-route latch (`rd_on_sdram`) must select the right `dout` source.

- [ ] **Step 6: Run to verify PASS**

Run:
```bash
cd fpga/sim
iverilog -g2012 -o demux.vvp tb_vram_demux.sv ../rtl/vram_demux.sv
vvp demux.vvp
```
Expected: `RESULT: PASS`.

- [ ] **Step 7: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
git add fpga/rtl/vram_defs.vh fpga/rtl/vram_demux.sv fpga/sim/tb_vram_demux.sv
git commit -m "feat(#34): vram_demux — route blitter FB accesses to SDRAM, else DDR

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Scanout reader dual-bus (line fetch from SDRAM)

Add an SDRAM read master to `openbor_video_reader.sv` and move ONLY the framebuffer line-fetch onto it; everything else (control-word poll, joystick, vsync writeback, audio, cart) stays on the DDR master.

**Files:**
- Modify: `fpga/rtl/openbor_video_reader.sv`
- Test: `fpga/sim/tb_scanout_sdram.sv` (clone of `tb_scanout_linebuf.sv`)

**Interfaces:**
- Produces: new reader ports `sdram_addr[26:0]`, `sdram_rd`, `sdram_burst[7:0]`, `sdram_dout64[63:0]`, `sdram_dready`, `sdram_busy` (→ arbiter P_SCAN).
- Consumes: SDRAM FB bases from `vram_defs.vh`.
- Unchanged: the position-addressed line-buffer read side, `frame_ready`/`preloading`/`stale_vblank_count`, `active_buffer` sync, and ALL DDR-master states.

- [ ] **Step 1: Clone the datapath tb to source FB from SDRAM**

Create `fpga/sim/tb_scanout_sdram.sv` from `tb_scanout_linebuf.sv` with these changes:
- Seed the framebuffer into a behavioral SDRAM model at `SDRAM_FB0_BASE` (byte `0x400000`), 640 B/line, 4 px/qword, instead of the DDR window.
- Connect the reader's new `sdram_*` master to the behavioral SDRAM (deliver `sdram_burst` beats with a small latency); keep the DDR master feeding the control word (`VCTRL`) so the frame-trigger/sync logic still runs.
- Keep the PIXEL-EXACT phase (every active pixel == `fb[vcount][hcount]`). The UNDERFLOW phase is optional here (covered by `tb_scanout_linebuf`); the point of this tb is the SDRAM read path + address map.

```systemverilog
// header note
// tb_scanout_sdram.sv — scanout reads the framebuffer from SDRAM (P_SCAN path).
// FB seeded at SDRAM_FB0_BASE; control word still on the DDR master. Proves the
// reader's new SDRAM read master + the SDRAM FB address map are pixel-exact.
`include "../rtl/vram_defs.vh"
```
Seed task:
```systemverilog
  // SDRAM byte model: word-addressed 16-bit cells
  reg [15:0] sdram [0:1<<22];
  task seed_fb_sdram;
    integer yy,xx; reg [26:0] b;
    begin
      for (yy=0; yy<240; yy=yy+1)
        for (xx=0; xx<320; xx=xx+1) begin
          b = `SDRAM_FB0_BASE + yy*`SDRAM_FB_STRIDE + xx*2;
          sdram[b>>1] = fbpix(yy, xx);
        end
    end
  endtask
```
SDRAM read responder (assemble 64-bit beats = 4 words, deliver `sdram_burst` beats):
```systemverilog
  reg [7:0] sbeats=0; reg [26:0] saddr=0; reg [2:0] slat=0;
  assign sdram_busy = (sbeats!=0)||(slat!=0);
  always @(posedge ddr_clk) begin
    sdram_dready<=0;
    if (slat!=0) slat<=slat-1;
    else if (sbeats!=0) begin
      sdram_dout64 <= {sdram[(saddr>>1)+3],sdram[(saddr>>1)+2],
                       sdram[(saddr>>1)+1],sdram[(saddr>>1)+0]};
      sdram_dready<=1; saddr<=saddr+27'd8; sbeats<=sbeats-1;
    end else if (sdram_rd) begin sbeats<=sdram_burst; saddr<=sdram_addr; slat<=3'd2; end
  end
```

- [ ] **Step 2: Run the new tb against the CURRENT reader to confirm it fails**

Run:
```bash
cd fpga/sim
iverilog -g2012 -o scsd.vvp tb_scanout_sdram.sv ../rtl/openbor_video_reader.sv ../rtl/openbor_video_timing.sv dcfifo_stub.sv
```
Expected: FAIL — the reader has no `sdram_*` ports yet (unknown ports), so the tb won't elaborate. (This is the failing state.)

- [ ] **Step 3: Add the SDRAM read master ports + reroute the line fetch**

Edit `fpga/rtl/openbor_video_reader.sv`:

(a) Add to the port list (near the DDR master ports, lines ~37-48):
```systemverilog
    // SDRAM framebuffer read master (P_SCAN) — line fetch only
    input  wire        sdram_busy,
    output reg  [26:0] sdram_addr,
    output reg  [7:0]  sdram_burst,
    output reg         sdram_rd,
    input  wire [63:0] sdram_dout64,
    input  wire        sdram_dready,
```

(b) Add the include at the top: `` `include "vram_defs.vh" ``.

(c) In `ST_CHECK_CTRL`, change `buf_base_addr` to the SDRAM FB base (byte). Replace the two `buf_base_addr <= ctrl_word[0] ? BUF1_ADDR : BUF0_ADDR;` style assignment with:
```systemverilog
                    buf_base_addr <= ctrl_word[0] ? `SDRAM_FB1_BASE : `SDRAM_FB0_BASE;
```
and widen `buf_base_addr` to `reg [26:0]` (it was `[28:0]` DDR qword; now a 27-bit SDRAM byte base).

(d) In `ST_READ_LINE`, issue to the SDRAM master instead of the DDR master:
```systemverilog
            ST_READ_LINE: begin
                if (!sdram_busy && !fifo_aclr_ddr_active) begin
                    sdram_addr   <= buf_base_addr + ({18'd0, display_line} * `SDRAM_FB_STRIDE);
                    sdram_burst  <= LINE_BURST;       // 80 beats
                    sdram_rd     <= 1'b1;
                    beat_count   <= 7'd0;
                    timeout_cnt  <= 20'd0;
                    state        <= ST_WAIT_LINE;
                end
            end
```
Add `if (!sdram_busy) sdram_rd <= 1'b0;` to the per-cycle defaults (mirror the existing `ddr_rd` deassert).

(e) In the beat-capture block, capture from the SDRAM master:
```systemverilog
        if (state == ST_WAIT_LINE && sdram_dready) begin
            lb_we      <= 1'b1;
            lb_waddr   <= {display_line[0], beat_count};
            lb_wdata   <= sdram_dout64;
            beat_count <= beat_count + 7'd1;
            timeout_cnt<= 20'd0;
        end
```
(`ST_WAIT_LINE`'s exit condition on `beat_count == LINE_BURST` is unchanged.)

(f) Reset block: add `sdram_addr<=27'd0; sdram_burst<=8'd0; sdram_rd<=1'b0;`. Leave all DDR-master states (`ST_POLL_CTRL`, `ST_WAIT_CTRL`, joystick, vsync, audio, cart) untouched.

- [ ] **Step 4: Run the new tb to verify pixel-exact PASS**

Run:
```bash
cd fpga/sim
iverilog -g2012 -o scsd.vvp tb_scanout_sdram.sv ../rtl/openbor_video_reader.sv ../rtl/openbor_video_timing.sv dcfifo_stub.sv
vvp scsd.vvp
```
Expected: `PIXEL-EXACT: checked=<large> errs=0` → `RESULT: PASS`.

- [ ] **Step 5: Confirm the DDR-path datapath tb no longer applies / is replaced**

Run: `grep -l 'ST_READ_LINE\|ddr_dout_ready' fpga/sim/tb_scanout_linebuf.sv`
The old `tb_scanout_linebuf.sv` feeds the line fetch over the DDR master, which no longer drives the line fetch. Update it to drive the `sdram_*` master too (same change as the new tb) OR retire it in favor of `tb_scanout_sdram.sv`. Decision: **retire `tb_scanout_linebuf.sv`** (the underflow no-drift property is re-asserted in `tb_scanout_sdram.sv` by adding the same starve phase against the SDRAM responder). Port the UNDERFLOW phase into `tb_scanout_sdram.sv` and `git rm fpga/sim/tb_scanout_linebuf.sv`.

- [ ] **Step 6: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
git add fpga/rtl/openbor_video_reader.sv fpga/sim/tb_scanout_sdram.sv
git rm fpga/sim/tb_scanout_linebuf.sv
git commit -m "feat(#34): scanout reads framebuffer from SDRAM (dual-bus reader)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Solarus.sv integration

Wire `vram_demux`, the 3-client arbiter, and the reader's SDRAM master; delete the reader's DDR-FB line-fetch wiring.

**Files:**
- Modify: `fpga/Solarus.sv`

**Interfaces:**
- Consumes: Task 1 arbiter (`scan_*`, `dst_*`, `p0_*`), Task 2 `vram_demux`, Task 3 reader `sdram_*`.

- [ ] **Step 1: Add the demux between the blitter and `ddr_blitter_arb`**

In `fpga/Solarus.sv`, instantiate `vram_demux` taking `blt_mem_*` (lines ~489-518), driving a new DDR-side bus `bd_*` into `ddr_blitter_arb.blt_*` (replacing the direct `blt_mem_*` → `blitter_arb.blt_*` wiring at lines ~533-537), and driving the arbiter `dst_*` port:
```systemverilog
vram_demux vdemux (
  .clk(clk_sys), .reset(RESET),
  .blt_addr(blt_mem_addr), .blt_rd(blt_mem_rd), .blt_wr(blt_mem_wr),
  .blt_din(blt_mem_din), .blt_be(blt_mem_be),
  .blt_dout(blt_demux_dout), .blt_dout_ready(blt_demux_dready), .blt_busy(blt_busy_w),
  .ddr_addr(bd_addr), .ddr_rd(bd_rd), .ddr_wr(bd_wr), .ddr_din(bd_din), .ddr_be(bd_be),
  .ddr_dout(DDRAM_DOUT), .ddr_dout_ready(DDRAM_DOUT_READY & blt_grant_w), .ddr_busy(blt_arb_busy),
  .sd_addr(dst_addr), .sd_rd(dst_rd), .sd_din(dst_din), .sd_we(dst_we),
  .sd_din64(dst_din64), .sd_we_burst(dst_we_burst),
  .sd_dout64(dst_dout64), .sd_dready(dst_dready), .sd_busy(dst_busy)
);
```
Point `blitter.mem_dout`/`mem_dout_ready`/`mem_busy` at the demux (`blt_demux_dout`/`blt_demux_dready`/`blt_busy_w`). Route `ddr_blitter_arb.blt_*` from `bd_*` instead of `blt_mem_*`.

- [ ] **Step 2: Wire the 3 arbiter clients**

Update the `src_arb` instance (lines ~387-408) to the 3-client form: keep `p0_*` (blitter source) as P_SRC; add `scan_*` (from the reader) and `dst_*` (from the demux). Connect the reader's new `sdram_*` master to `scan_*`:
```systemverilog
  .scan_addr(rdr_sdram_addr), .scan_rd(rdr_sdram_rd), .scan_burst(rdr_sdram_burst),
  .scan_busy(rdr_sdram_busy), .scan_dout64(rdr_sdram_dout64), .scan_dready(rdr_sdram_dready),
  .dst_addr(dst_addr), .dst_rd(dst_rd), .dst_we(dst_we), .dst_din(dst_din),
  .dst_we_burst(dst_we_burst), .dst_din64(dst_din64),
  .dst_busy(dst_busy), .dst_dout64(dst_dout64), .dst_dready(dst_dready),
```

- [ ] **Step 3: Connect the reader's SDRAM master + drop its DDR-FB line fetch**

In the `openbor_video_reader reader (...)` instance (`openbor_video_top.sv:121` or wherever it is instantiated in the build — confirm with grep), add the `sdram_*` connections to `rdr_sdram_*` and leave the DDR master (`nv_ddr_*`) connected as today (it now carries only control/joy/vsync/audio/cart). The reader RTL already stopped issuing line reads on the DDR master (Task 3), so no DDR-FB read wiring remains to delete — verify `nv_ddr_rd` is no longer asserted for line fetches by inspection.

- [ ] **Step 4: Declare the new nets**

Add `wire`s: `bd_addr[28:0]`, `bd_rd`, `bd_wr`, `bd_din[63:0]`, `bd_be[7:0]`; `blt_demux_dout[63:0]`, `blt_demux_dready`; `dst_addr[26:0]`, `dst_rd`, `dst_we`, `dst_din[15:0]`, `dst_we_burst`, `dst_din64[63:0]`, `dst_busy`, `dst_dout64[63:0]`, `dst_dready`; `rdr_sdram_addr[26:0]`, `rdr_sdram_rd`, `rdr_sdram_burst[7:0]`, `rdr_sdram_busy`, `rdr_sdram_dout64[63:0]`, `rdr_sdram_dready`.

- [ ] **Step 5: Elaboration check (the integration smoke test)**

Run (Icarus elaboration of the integrated RTL — no Quartus needed for a syntax/port check):
```bash
cd fpga
iverilog -g2012 -y rtl -o /tmp/solarus_elab.vvp Solarus.sv 2>&1 | tee /tmp/elab.log
```
Expected: no port-mismatch / undeclared-net errors for the touched modules. (Top-level `Solarus.sv` may reference MiSTer framework modules not in `rtl/` — those unresolved-module warnings are expected; the goal is zero errors on `vram_demux`, `sdram_src_arb`, `openbor_video_reader` ports.) Per the build-CI memory, `.*` port connections can hide mismatches — explicitly verify each new connection by name.

- [ ] **Step 6: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
git add fpga/Solarus.sv
git commit -m "feat(#34): wire vram_demux + 3-client arbiter + reader SDRAM master in Solarus.sv

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Blitter-system regression — dest → SDRAM

Prove the blitter composites correctly when its dest is redirected to SDRAM through the demux + arbiter, and that a full-screen COPY (the carry-forward, Task 6) reproduces its source.

**Files:**
- Modify: `fpga/sim/tb_blitter_system.sv`

- [ ] **Step 1: Read the current system tb to learn its harness**

Run: `sed -n '1,80p' fpga/sim/tb_blitter_system.sv`
Expected: identify how it instantiates `blitter_top` + the fake reader + ref-model comparison, and where the blitter's `mem_*` connects.

- [ ] **Step 2: Insert the demux + SDRAM model on the blitter dest path**

Modify `tb_blitter_system.sv` to route `blitter_top.mem_*` through `vram_demux` (Task 2) into a behavioral SDRAM model for FB-region accesses, while non-FB accesses keep the existing DDR behavioral memory. Assert the composited FB pixels in SDRAM match the C ref model over the existing v1 command set.

- [ ] **Step 3: Add the carry-forward copy assertion**

Add a command-stream case: a full-screen `OP_BLIT` with `src = FB1 (SDRAM)`, `dst = FB0 (SDRAM)`, COPY. Pre-seed FB1 in the SDRAM model with a known pattern; after the blit, assert FB0 == FB1 pixel-for-pixel.

```systemverilog
  // carry-forward copy: FB1 -> FB0, full screen, COPY
  // (emit via the same command-injection path tb_blitter_system uses)
  // then:
  for (cy=0; cy<240; cy=cy+1) for (cx=0; cx<320; cx=cx+1)
    if (sdram_fb0_px(cy,cx) !== sdram_fb1_px(cy,cx)) begin
      $display("FAIL: carry-forward copy mismatch @%0d,%0d", cx, cy); errs=errs+1; end
```

- [ ] **Step 4: Run the regression**

Run:
```bash
cd fpga/sim
iverilog -g2012 -o sys.vvp tb_blitter_system.sv ../rtl/blitter_top.sv ../rtl/vram_demux.sv \
  ../rtl/ddr_blitter_arb.sv ../rtl/sdram_src_arb.sv ../rtl/sdram_psx.sv sdram_chip_model.sv
vvp sys.vvp
```
Expected: `RESULT: PASS` — PHASE1/2/3 (composite) pixel-exact vs ref model AND carry-forward copy match.

- [ ] **Step 5: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
git add fpga/sim/tb_blitter_system.sv
git commit -m "test(#34): blitter-system regression with dest->SDRAM + carry-forward copy

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Fabric carry-forward + C++ host changes

Replace the ARM DDR→DDR carry-forward `memcpy` with a fabric full-screen FB_prev→FB_cur `OP_BLIT`, and ensure `C_SRCSEL` master-enable = 1 (full VRAM).

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp`
- Modify: `blt_emitter` source (find with grep below) — add an FB-region COPY helper if one does not exist.

**Interfaces:**
- Consumes: the existing emitter blit/copy API (`blt_blit_copy` / `blt_begin_frame`), the bg-cache FB-region source addressing model.

- [ ] **Step 1: Locate the emitter API + the FB-region source addressing**

Run:
```bash
grep -rnE 'blt_blit_copy|blt_begin_frame|blt_stage|src_off|F_SRC_SDRAM|sdram' patches/mister/*.c* patches/mister/*.h 2>/dev/null | head -40
grep -rn 'blt_emitter' patches/mister gmloader 2>/dev/null | head
```
Expected: find the emitter file + how `blt_blit_copy` expresses a source handle/offset (the bg-cache path reads a non-heap SDRAM region — that is the model for FB-as-source).

- [ ] **Step 2: Replace the ARM carry-forward memcpy with a fabric copy**

In `mister_blitter_renderer.cpp` ~L722-727, replace:
```cpp
        if (vid && !clear_requested && em.submit_seq != 0) {
          const uint32_t cur_off  = target_buf ? 0x00040040u : 0x00000040u;
          const uint32_t prev_off = target_buf ? 0x00000040u : 0x00040040u;
          std::memcpy((void*)(vid + cur_off), (const void*)(vid + prev_off),
                      (size_t)FB_W * FB_H * 2u);
          if (diag) g_carryfwd++;
        } else if (diag && clear_requested) {
```
with a fabric full-screen copy emitted at frame start (begin_frame with clear=0, then a COPY blit of the previous FB into the current target):
```cpp
        if (!clear_requested && em.submit_seq != 0) {
          // Fabric carry-forward: copy the previously-committed FB into this
          // target buffer in SDRAM (the ARM cannot write SDRAM). Source = prev FB,
          // dst = target FB; the demux redirects both to SDRAM. F_SRC_SDRAM set so
          // the blitter reads the prev FB from SDRAM.
          blt_begin_frame(&em, target_buf, /*clear=*/0, /*clear_color=*/0x0000);
          blt_blit_fb_copy(&em, /*src_buf=*/!target_buf);   // full-screen FB->FB
          if (diag) g_carryfwd++;
        } else {
          if (diag && clear_requested) g_hwclear++;
          blt_begin_frame(&em, target_buf, /*clear=*/clear_requested ? 1 : 0,
                          /*clear_color=*/0x0000);
        }
```
(The non-carry-forward `blt_begin_frame` at the end of the `else` branch replaces the old unconditional call at L731-732.)

- [ ] **Step 3: Add the `blt_blit_fb_copy` emitter helper**

In the emitter source, add a helper that emits a full-screen `OP_BLIT` COPY whose source is the OTHER display buffer's FB region with `F_SRC_SDRAM` set (so the blitter reads it from SDRAM), dst = the current target FB (the demux sends the write to SDRAM):
```c
// Full-screen FB->FB copy (persistence carry-forward). src_buf selects the
// source display buffer (0/1); dst is the frame's current target_buf. The src
// offset is the FB's DDR qword base (the demux remaps to SDRAM); F_SRC_SDRAM
// makes the blitter read it from SDRAM.
void blt_blit_fb_copy(blt_emitter* em, int src_buf) {
  blt_cmd c; memset(&c, 0, sizeof c);
  c.opcode = OP_BLIT;
  c.flags  = F_SRC_SDRAM;
  c.src_off = src_buf ? FB1_OFF : FB0_OFF;   // FB region offsets the demux decodes
  c.src_stride = FB_W * 2; c.src_x = 0; c.src_y = 0;
  c.w = FB_W; c.h = FB_H; c.dst_x = 0; c.dst_y = 0;
  blt_emit(em, &c);
}
```
Match the exact `blt_cmd` field names + emit function the emitter already uses (from Step 1). Define `FB0_OFF`/`FB1_OFF` to the FB region offsets the demux decodes (DDR qword bases minus the ring base, however the emitter expresses dst/src offsets today).

- [ ] **Step 4: Force `C_SRCSEL` master-enable = 1**

At `mister_blitter_renderer.cpp:1541`, the `C_SRCSEL` write is gated on `stage_enabled` (the `SOLARUS_SDRAM_SRC` env). For full VRAM the framebuffer is ALWAYS in SDRAM, so staging+SDRAM source must always be on. Set `stage_enabled = true` unconditionally (or remove the env gate) and write `C_SRCSEL` bit0 = 1 always:
```cpp
  d->stage_enabled = true;   // full VRAM: framebuffer + sources always in SDRAM
```
(Line ~1037; remove the `getenv("SOLARUS_SDRAM_SRC")` gate.)

- [ ] **Step 5: Type-check the renderer**

Use the renderer native type-check recipe (memory: `fpga-renderer-native-typecheck`):
```bash
g++ -fsyntax-only -std=c++17 -I<solarus includes> -I<glm> patches/mister/mister_blitter_renderer.cpp
```
Expected: no errors. (Fetch the exact include paths from the memory entry.)

- [ ] **Step 6: Build the engine (armhf) and confirm the symbol is gone**

The full proof is the armhf engine build (per CLAUDE.md `scripts/build_engine.sh`). At minimum confirm the carry-forward memcpy is gone and the fabric copy is present:
```bash
grep -n 'memcpy((void\*)(vid' patches/mister/mister_blitter_renderer.cpp || echo "carry-forward memcpy removed"
grep -n 'blt_blit_fb_copy' patches/mister/mister_blitter_renderer.cpp
```
Expected: "carry-forward memcpy removed" + a `blt_blit_fb_copy` call.

- [ ] **Step 7: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
git add patches/mister/mister_blitter_renderer.cpp <emitter file>
git commit -m "feat(#34): fabric carry-forward (FB->FB blit); C_SRCSEL always on for VRAM

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Build RBF + HW validation (MANUAL — gated, not auto-run)

**This task runs on real hardware and is the real proof per spec §6. Do NOT run it as part of automated execution — flag the user for a hands-on session.**

- [ ] **Step 1: Build the RBF in CI**

```bash
gh workflow run build-rbf.yml -f runner=linux
gh run watch
```
Watch the fit report for the new logic (demux + 3rd arbiter port): M10K inference unchanged, timing not regressed (per the build-CI memory, RBF builds even with negative slack — check slack explicitly). Download when green: `gh run download <run-id> -n solarus-rbf`.

- [ ] **Step 2: Refresh `deploy/` from the engine build, then deploy**

Per the memory `fpga-deploy-refresh-from-build-armhf`: `cp build/armhf/libsolarus.so.1.6.5 deploy/libs/` first (deploy ships from `deploy/`, which is gitignored and not auto-refreshed), then `./deploy.py --host 192.168.20.81`.

- [ ] **Step 3: Validate scanout-from-SDRAM on a moving scene**

Boot a quest with scrolling/motion. Confirm: stable image, **no vertical scroll, no wedge/freeze**, analog clean. Capture via camera (counters lie about video). This is the success criterion.

- [ ] **Step 4: Confirm no live escapes**

Watch the diag counter `g_escapes` over intro/title/menus/overworld/pause. Expected 0 (the deleted DDR-FB fallback assumption). If any escape fires (blank frame), record which op and file follow-up to bring it onto fabric.

- [ ] **Step 5: Record HW outcome**

Update memory (`fpga-sdram-source-f2h-scanout-contention.md`) + flip the spec status to HW-VALIDATED (or capture the failure mode for the next cycle).

---

## Task 8: Docs + memory update

**Files:**
- Modify: `docs/frame-dataflow.md`
- Modify: `docs/superpowers/specs/2026-06-17-vram-framebuffer-relocation-design.md` (status)
- Modify: memory `fpga-sdram-source-f2h-scanout-contention.md` + `MEMORY.md` index

- [ ] **Step 1: Update the dataflow diagram**

In `docs/frame-dataflow.md`, move the framebuffer (`FB`) from the DDR3 subgraph into the SDRAM subgraph; redraw `COMP -- write composited pixels --> FB` and `FB --> SCAN` as SDRAM edges; note the demux and the fabric carry-forward. Match the existing mermaid style.

- [ ] **Step 2: Flip the spec status**

Change the spec header `**Status:**` to `IMPLEMENTED in RTL + sims green (DATE). HW validation pending.` with the plan path.

- [ ] **Step 3: Update memory**

Append one line to `memory/fpga-sdram-source-f2h-scanout-contention.md` recording that #34 is resolved at the root by relocating the framebuffer to SDRAM (blitter dest + scanout both on the dedicated bus; f2h carries no scanout pixels); sims green; HW pending. Update the matching one-liner in `MEMORY.md`. Link `[[fpga-jtframe-reference]]`.

- [ ] **Step 4: Commit docs**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
git add docs/frame-dataflow.md docs/superpowers/specs/2026-06-17-vram-framebuffer-relocation-design.md
git commit -m "docs(#34): VRAM framebuffer relocation implemented — dataflow + spec status

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```
(The memory dir is outside the repo — write those files but do not git-add them.)

---

## Self-Review Notes (already applied)

- **Spec §4.1/§4.2 (map + 3-client arbiter):** Task 1 (arbiter) + Task 2 Step 1 (defs) + the map verification (Task 2 Step 2).
- **Spec §4.3 (reader dual-bus):** Task 3 — line fetch → SDRAM, control/IO stays DDR, line buffer + sync unchanged.
- **Spec §4.4 (demux):** Task 2 (`vram_demux` + unit test) + Task 4 (wiring); per-pixel `be`→word + full-qword burst write covered by `tb_vram_demux` cases 2-3.
- **Spec §4.5 (removals):** Task 3 (DDR-FB scanout path) + Task 6 (ARM carry-forward memcpy). Per-command source mux preserved (Task 6 Step 4 keeps `F_SRC_SDRAM`).
- **Spec §4.6 (fabric carry-forward):** Task 6 (renderer + emitter) + Task 5 Step 3 (copy assertion).
- **Spec §6 (testing):** arbiter (T1), demux (T2), scanout-from-SDRAM (T3), blitter-system regression + carry-forward (T5), HW (T7).
- **Spec §7 (FB-as-source for carry-forward, no vendored edit):** Task 6 Step 1 confirms the emitter can express an FB source offset before assuming no blitter RTL change.
- **Type consistency:** `scan_*`/`dst_*`/`p0_*` (arbiter), `sd_*`/`blt_*`/`ddr_*` (demux), `sdram_*` (reader) names used identically across the tasks that produce and consume them.
