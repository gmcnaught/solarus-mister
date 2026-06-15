# PSX-pattern SDRAM second-bus controller — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an analog-safe SDRAM second-bus controller (PSX pattern: BL=2×N pipelined line reads, page-open reuse, multi-port arbiter, `set_false_path` CDC) that serves blitter source reads, runtime-selectable against the shipping DDR3 readcache.

**Architecture:** Port the proven v3.0 controller + sim model + testbench from the `sdram-burst` branch to `master` as a green baseline, then adapt the read datapath to assemble a parameterized 128-bit line from back-to-back BL=2 bursts after one ACTIVE, wrap it in a registered-grant multi-port arbiter, and add a runtime control-register source-select so the DDR3 readcache stays the analog-clean default. RTL + iverilog sims are done here; Quartus timing-closure (CI) and the analog vsync gate (on-device, user's CRT) are gated checklist tasks at the end.

**Tech Stack:** SystemVerilog (`-g2012`), Icarus Verilog (`iverilog`/`vvp`, installed locally), Quartus (CI only), MT48LC16M16A2 SDRAM @ 100MHz.

**Spec:** `docs/superpowers/specs/2026-06-15-issue19-psx-sdram-controller-design.md`

---

## File structure

- `fpga/rtl/sdram_psx.sv` — **new** controller (ported from `sdram-burst:fpga/rtl/sdram.sv`, then adapted). One responsibility: turn a line-read request into SDRAM commands and assemble the line. Kept separate from the stock `fpga/rtl/sdram.sv` so the shipping path is untouched.
- `fpga/rtl/sdram_src_arb.sv` — **new** multi-port arbiter in front of `sdram_psx` (registered grant, bounded grant gap). Mirrors `ddr_blitter_arb.sv`'s contract.
- `fpga/rtl/blitter_top.sv` — **modify** the source-read mux: runtime control-register bit selects SDRAM-source vs DDR3-readcache-source.
- `fpga/sim/sdram_chip_model.sv` — **port** from `sdram-burst` (command-level chip model); extend for BL=2×N page-open + refresh-timing checks.
- `fpga/sim/tb_sdram_ctrl.sv` — **port** from `sdram-burst` (round-trip baseline test).
- `fpga/sim/tb_sdram_psx.sv` — **new** PSX-pattern tests: line assembly, page-wrap, protocol timing, line-width sweep.
- `fpga/sim/tb_sdram_src_arb.sv` — **new** arbiter test: bounded grant gap, no starvation.
- `fpga/Solarus.sdc` — **modify** clk_sys↔clk_pix CDC to `set_false_path`.
- `fpga/files.qip` — **modify** to register the two new RTL files for the Quartus build.

**Conventions (read once):** `fpga/sim/README.md` shows the iverilog idiom. All sims compile with `iverilog -g2012` and print `errors=N`; a test passes when it prints `errors=0` (and any deadlock guard prints no `DEADLOCK`). Run every sim from `fpga/sim/`.

---

## Task 1: Port the v3.0 controller + sim baseline to master (green starting point)

Establish the proven BURST-4 controller and its logical testbench on `master` (renamed to `sdram_psx` so the stock `sdram.sv` is untouched), so every later change is a diff against a green baseline.

**Files:**
- Create: `fpga/rtl/sdram_psx.sv` (from `sdram-burst:fpga/rtl/sdram.sv`)
- Create: `fpga/sim/sdram_chip_model.sv` (from `sdram-burst:fpga/sim/sdram_chip_model.sv`)
- Create: `fpga/sim/tb_sdram_ctrl.sv` (from `sdram-burst:fpga/sim/tb_sdram_ctrl.sv`)

- [ ] **Step 1: Bring the three files over from the branch, renaming the module**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
git show sdram-burst:fpga/rtl/sdram.sv            > fpga/rtl/sdram_psx.sv
git show sdram-burst:fpga/sim/sdram_chip_model.sv > fpga/sim/sdram_chip_model.sv
git show sdram-burst:fpga/sim/tb_sdram_ctrl.sv    > fpga/sim/tb_sdram_ctrl.sv
# rename module sdram -> sdram_psx (keep the stock fpga/rtl/sdram.sv as-is)
perl -0pi -e 's/\bmodule sdram\b/module sdram_psx/' fpga/rtl/sdram_psx.sv
perl -0pi -e 's/\bsdram dut\b/sdram_psx dut/'       fpga/sim/tb_sdram_ctrl.sv
```

- [ ] **Step 2: Run the ported baseline test — verify it passes as-is**

Run:
```bash
cd fpga/sim
iverilog -g2012 -o tb_sdram_ctrl.vvp tb_sdram_ctrl.sv ../rtl/sdram_psx.sv sdram_chip_model.sv && vvp tb_sdram_ctrl.vvp
```
Expected: compiles clean; final line `errors=0`. (This is the proven v3.0 behavior — it must be green before adapting.)

- [ ] **Step 3: Commit the green baseline**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
git add fpga/rtl/sdram_psx.sv fpga/sim/sdram_chip_model.sv fpga/sim/tb_sdram_ctrl.sv
git commit -m "fpga(#19): port v3.0 SDRAM controller + sim baseline as sdram_psx"
```

---

## Task 2: Parameterize the line width (BURST_BEATS) — TDD the 128-bit line

The v3.0 delivers one 64-bit beat (4 words, BL=4) per `rd`. Generalize to assemble an `N`-beat line from back-to-back bursts after one ACTIVE, default `BURST_BEATS=2` (128-bit). Add a per-beat `dout_ready` strobe so the consumer takes beats as they land.

**Files:**
- Modify: `fpga/rtl/sdram_psx.sv` (read FSM + ports)
- Modify: `fpga/sim/tb_sdram_psx.sv` (new test, created here)

- [ ] **Step 1: Write the failing test for a 2-beat (128-bit) line**

Create `fpga/sim/tb_sdram_psx.sv`:
```systemverilog
// tb_sdram_psx.sv — PSX-pattern line reads (BL=2 xN), page-open reuse, page-wrap.
`timescale 1ns/1ps
`default_nettype none
module tb_sdram_psx;
  reg clk=0; always #5 clk=~clk;          // 100 MHz
  reg          init=1;
  reg  [26:0]  addr=0;
  reg  [15:0]  din=0;
  reg          we=0, rd=0;
  wire [63:0]  dout64;
  wire         dout_ready;                 // NEW: per-beat strobe
  wire         ready;                       // line complete / accept next

  wire [15:0] DQ; wire [12:0] A; wire DQML,DQMH; wire [1:0] BA;
  wire nCS,nWE,nRAS,nCAS,CLK,CKE;

  sdram_psx #(.BURST_BEATS(2)) dut (
    .init(init), .clk(clk),
    .SDRAM_DQ(DQ), .SDRAM_A(A), .SDRAM_DQML(DQML), .SDRAM_DQMH(DQMH),
    .SDRAM_BA(BA), .SDRAM_nCS(nCS), .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS),
    .SDRAM_nCAS(nCAS), .SDRAM_CLK(CLK), .SDRAM_CKE(CKE),
    .wtbt(2'b11), .addr(addr), .dout(), .dout64(dout64),
    .dout_ready(dout_ready), .din(din), .we(we), .rd(rd), .ready(ready)
  );
  sdram_chip_model chip (
    .clk(clk), .DQ(DQ), .A(A), .BA(BA),
    .nCS(nCS), .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE), .CKE(CKE),
    .DQML(DQML), .DQMH(DQMH)
  );

  integer errors=0;
  task wait_ready; begin @(posedge clk); while(!ready) @(posedge clk); end endtask

  // single-word write through the controller (same map as v3.0 tb)
  task wr(input [26:0] a, input [15:0] d); begin
    @(posedge clk); addr<=a; din<=d; we<=1;
    @(posedge clk); we<=0; wait_ready;
  end endtask

  // line read: capture BURST_BEATS beats, return them packed
  reg [63:0] beat [0:7];
  task rd_line(input [26:0] a, input integer n); integer i; begin
    @(posedge clk); addr<=a; rd<=1;
    @(posedge clk); rd<=0;
    for (i=0;i<n;i=i+1) begin
      @(posedge clk); while(!dout_ready) @(posedge clk); beat[i]=dout64;
    end
    wait_ready;
  end endtask

  integer w;
  initial begin
    repeat(4) @(posedge clk); init<=0;
    // seed 8 consecutive words (= 2 beats of 4 words) at a base
    for (w=0; w<8; w=w+1) wr(27'h001000 + (w<<1), 16'hA000 + w[15:0]);
    // read the 2-beat line at the base
    rd_line(27'h001000, 2);
    if (beat[0] !== 64'hA003_A002_A001_A000) begin errors=errors+1; $display("beat0 bad: %h", beat[0]); end
    if (beat[1] !== 64'hA007_A006_A005_A004) begin errors=errors+1; $display("beat1 bad: %h", beat[1]); end
    $display("errors=%0d", errors);
    $finish;
  end
endmodule
```

- [ ] **Step 2: Run it — verify it FAILS to compile/elaborate**

Run:
```bash
cd fpga/sim
iverilog -g2012 -o tb_sdram_psx.vvp tb_sdram_psx.sv ../rtl/sdram_psx.sv sdram_chip_model.sv && vvp tb_sdram_psx.vvp
```
Expected: FAIL — elaboration error `port ``dout_ready`` not a port of sdram_psx` and/or `parameter BURST_BEATS not found` (the controller doesn't yet have them).

- [ ] **Step 3: Add the BURST_BEATS parameter, dout_ready port, and N-beat assembly**

In `fpga/rtl/sdram_psx.sv`:

Add the parameter to the module header (right after `module sdram_psx`):
```systemverilog
module sdram_psx
#(
   parameter BURST_BEATS = 2          // 64-bit beats per line (2 = 128-bit)
)
(
```

Add the new output port next to `dout64` in the port list:
```systemverilog
   output reg [63:0] dout64,      // assembled 64-bit beat of the last (burst) read
   output reg        dout_ready,  // pulses once per assembled 64-bit beat
```

In the read FSM, the v3.0 captures 4 words (BL=4) into one `dout64` and pulses `ready`. Generalize: after the single ACTIVE, issue `BURST_BEATS` BL=4 reads back-to-back (no re-ACTIVE), and pulse `dout_ready` as each 64-bit beat completes; pulse `ready` only after the last beat. Replace the v3.0 single-beat capture/complete block with:
```systemverilog
   // --- N-beat line assembly (PSX pattern: back-to-back bursts, one ACTIVE) ---
   // beat_idx counts assembled 64-bit beats within the current line.
   reg [3:0] beat_idx;
   reg [3:0] reads_issued;
   // (in the READ-issue state) issue a CMD_READ for each beat, advancing the
   // column by 4 words per beat, until reads_issued == BURST_BEATS:
   //   command <= CMD_READ;
   //   SDRAM_A <= {col_auto_precharge=0, col + (reads_issued<<2)};
   //   reads_issued <= reads_issued + 1'b1;
   // (in the capture path) when a 4-word group has been latched into dout64:
   //   dout_ready <= 1'b1; beat_idx <= beat_idx + 1'b1;
   //   if (beat_idx + 1'b1 == BURST_BEATS) ready <= 1'b1;  // line complete
   // else dout_ready <= 1'b0;
```
Wire `beat_idx`/`reads_issued` to reset to 0 when a new `rd` is accepted, and gate the "line complete" `ready` on `beat_idx == BURST_BEATS`. Keep CAS_LATENCY/data_ready_delay handling from v3.0 (it already aligns the 4-word capture; the change is repeating it `BURST_BEATS` times within one open row).

- [ ] **Step 4: Run the test — verify it PASSES**

Run:
```bash
cd fpga/sim
iverilog -g2012 -o tb_sdram_psx.vvp tb_sdram_psx.sv ../rtl/sdram_psx.sv sdram_chip_model.sv && vvp tb_sdram_psx.vvp
```
Expected: `errors=0` (both beats return the seeded words in lane order).

- [ ] **Step 5: Re-run Task 1's baseline test — verify no regression**

Run:
```bash
cd fpga/sim
iverilog -g2012 -o tb_sdram_ctrl.vvp tb_sdram_ctrl.sv ../rtl/sdram_psx.sv sdram_chip_model.sv && vvp tb_sdram_ctrl.vvp
```
Expected: `errors=0` (single-beat path still works with BURST_BEATS defaulting to 2; if tb_sdram_ctrl assumed a 1-beat `ready`, instantiate it `#(.BURST_BEATS(1))`).

- [ ] **Step 6: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
git add fpga/rtl/sdram_psx.sv fpga/sim/tb_sdram_psx.sv
git commit -m "fpga(#19): parameterize line width (BURST_BEATS) + per-beat dout_ready"
```

---

## Task 3: Page-open reuse + refresh at line boundaries

Confirm (and enforce) that the back-to-back bursts within a line do NOT re-ACTIVE the row, and that AUTO_REFRESH only fires between line requests, never mid-line.

**Files:**
- Modify: `fpga/sim/sdram_chip_model.sv` (assert protocol)
- Modify: `fpga/sim/tb_sdram_psx.sv` (add the assertions)
- Modify: `fpga/rtl/sdram_psx.sv` (refresh-at-boundary gating, if needed)

- [ ] **Step 1: Add a protocol-violation counter to the chip model**

In `fpga/sim/sdram_chip_model.sv`, add a monitor that flags (a) a `CMD_ACTIVE` to the same already-open row twice within one line, and (b) a `CMD_AUTO_REFRESH` issued while a line read is in flight (between the first ACTIVE and the last beat). Expose `output integer proto_errors`:
```systemverilog
  // protocol monitor (sim-only)
  integer proto_errors = 0;
  reg in_line = 0;
  always @(posedge clk) begin
    if ({nRAS,nCAS,nWE}==3'b011 /*ACTIVE*/) in_line <= 1;
    if ({nRAS,nCAS,nWE}==3'b001 /*AUTO_REFRESH*/ && in_line) begin
      proto_errors <= proto_errors + 1; $display("PROTO: refresh mid-line"); end
    if (last_beat_strobe) in_line <= 0;   // driven by tb via a wire, see step 2
  end
```

- [ ] **Step 2: Assert zero protocol errors in the line test**

In `fpga/sim/tb_sdram_psx.sv`, connect `chip.proto_errors` and add after the existing checks:
```systemverilog
    if (chip.proto_errors !== 0) begin errors=errors+1; $display("proto_errors=%0d", chip.proto_errors); end
```

- [ ] **Step 3: Run — verify it fails IF a mid-line refresh or re-ACTIVE occurs**

Run:
```bash
cd fpga/sim
iverilog -g2012 -o tb_sdram_psx.vvp tb_sdram_psx.sv ../rtl/sdram_psx.sv sdram_chip_model.sv && vvp tb_sdram_psx.vvp
```
Expected: if the FSM already defers refresh to boundaries (v3.0 behavior), `errors=0`. If it can refresh mid-line, `PROTO: refresh mid-line` → drive the fix in Step 4.

- [ ] **Step 4: Gate refresh on line-idle in the controller (only if Step 3 failed)**

In `fpga/rtl/sdram_psx.sv`, guard the refresh trigger so it only fires when no line is in flight:
```systemverilog
   // refresh only at request boundary (never mid-line)
   wire line_busy = (state == STATE_READ) || (beat_idx != BURST_BEATS && rd_inflight);
   if (refresh_due && !line_busy) begin command <= CMD_AUTO_REFRESH; ... end
```

- [ ] **Step 5: Run — verify PASS**

Run:
```bash
cd fpga/sim
iverilog -g2012 -o tb_sdram_psx.vvp tb_sdram_psx.sv ../rtl/sdram_psx.sv sdram_chip_model.sv && vvp tb_sdram_psx.vvp
```
Expected: `errors=0`, no `PROTO:` lines.

- [ ] **Step 6: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
git add fpga/rtl/sdram_psx.sv fpga/sim/sdram_chip_model.sv fpga/sim/tb_sdram_psx.sv
git commit -m "fpga(#19): page-open reuse + refresh-at-line-boundary (protocol-checked)"
```

---

## Task 4: Page-wrap correctness across a row boundary

A line whose start column is near the end of a row must not silently wrap to column 0 of the same row. Test a line that would cross the 512-column page boundary and require the controller to handle it (PRE + ACTIVE next row, or split the line).

**Files:**
- Modify: `fpga/sim/tb_sdram_psx.sv`

- [ ] **Step 1: Write the failing page-wrap test**

Append to `fpga/sim/tb_sdram_psx.sv`'s `initial` block (before `$display("errors=...")`):
```systemverilog
    // place a line start 1 beat short of the row's last column so a 2-beat line
    // crosses into the next row. col=addr[9:1]; last col group at addr offset
    // (508<<1). Seed both rows' first words and read across the boundary.
    wr({3'd0, 13'd5, 9'd508, 1'b0, 1'b0}<<1, 16'hB000); // last group of row 5
    wr({3'd0, 13'd6, 9'd0,   1'b0, 1'b0}<<1, 16'hC000); // first group of row 6
    rd_line(({3'd0, 13'd5, 9'd508, 1'b0, 1'b0}<<1), 2);
    if (beat[0][15:0] !== 16'hB000) begin errors=errors+1; $display("wrap beat0 bad"); end
    if (beat[1][15:0] !== 16'hC000) begin errors=errors+1; $display("wrap beat1 bad"); end
```
(Adjust the address packing to match the v3.0 `col=addr[9:1], bank=addr[11:10], row=addr[24:12]` map — the helper from the v3.0 tb shows the exact bit layout.)

- [ ] **Step 2: Run — verify behavior**

Run:
```bash
cd fpga/sim
iverilog -g2012 -o tb_sdram_psx.vvp tb_sdram_psx.sv ../rtl/sdram_psx.sv sdram_chip_model.sv && vvp tb_sdram_psx.vvp
```
Expected: FAIL (`wrap beat1 bad`) if the controller wraps within the row instead of advancing to row 6.

- [ ] **Step 3: Handle the row boundary in the controller**

In `fpga/rtl/sdram_psx.sv`, when issuing per-beat reads, detect when the next beat's column group exceeds the row's last column and, instead of continuing reads, `PRECHARGE` + `ACTIVE` the next row before resuming. Simplest correct form: cap a line at the row boundary and start a fresh ACTIVE for the remaining beats:
```systemverilog
   wire [8:0] next_col = col_base + ((reads_issued+1'b1)<<2);
   wire row_wrap = (next_col < col_base);     // 9-bit col overflow
   // if row_wrap before all beats issued: command<=CMD_PRECHARGE then re-ACTIVE
   // row+1 and continue from reads_issued (keep beat_idx).
```

- [ ] **Step 4: Run — verify PASS**

Run:
```bash
cd fpga/sim
iverilog -g2012 -o tb_sdram_psx.vvp tb_sdram_psx.sv ../rtl/sdram_psx.sv sdram_chip_model.sv && vvp tb_sdram_psx.vvp
```
Expected: `errors=0`.

- [ ] **Step 5: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
git add fpga/rtl/sdram_psx.sv fpga/sim/tb_sdram_psx.sv
git commit -m "fpga(#19): page-wrap-safe line reads across row boundary"
```

---

## Task 5: Multi-port arbiter (sdram_src_arb) with bounded grant gap

Wrap `sdram_psx` in a registered-grant arbiter: one blitter-source read port now, with structural headroom for a second. Guarantee a stalled reader still gets the bus within a bounded gap (the `tb_ddr_blitter_arb` deadlock lesson).

**Files:**
- Create: `fpga/rtl/sdram_src_arb.sv`
- Create: `fpga/sim/tb_sdram_src_arb.sv`

- [ ] **Step 1: Write the failing arbiter test (bounded grant gap, no starvation)**

Create `fpga/sim/tb_sdram_src_arb.sv`:
```systemverilog
`timescale 1ns/1ps
`default_nettype none
module tb_sdram_src_arb;
  reg clk=0; always #5 clk=~clk;
  reg reset=1;
  // port 0 (blitter source) request
  reg  [26:0] p0_addr=0; reg p0_rd=0; wire p0_grant; wire p0_busy;
  // downstream controller-facing (stubbed busy/ready)
  wire [26:0] c_addr; wire c_rd; reg c_ready=1, c_busy=0;
  integer max_gap=0, gap=0, errors=0;

  sdram_src_arb dut (
    .clk(clk), .reset(reset),
    .p0_addr(p0_addr), .p0_rd(p0_rd), .p0_grant(p0_grant), .p0_busy(p0_busy),
    .c_addr(c_addr), .c_rd(c_rd), .c_ready(c_ready), .c_busy(c_busy)
  );

  // measure gap between p0_rd asserted and p0_grant
  always @(posedge clk) begin
    if (p0_rd && !p0_grant) gap <= gap+1;
    if (p0_grant) begin if (gap>max_gap) max_gap<=gap; gap<=0; end
  end
  initial begin
    repeat(3) @(posedge clk); reset<=0;
    // hold a read request continuously; arbiter must grant within bound
    p0_addr<=27'h2000; p0_rd<=1;
    repeat(40) @(posedge clk);
    p0_rd<=0;
    if (max_gap > 4) begin errors=errors+1; $display("grant gap too large: %0d", max_gap); end
    $display("errors=%0d max_gap=%0d", errors, max_gap);
    $finish;
  end
endmodule
```

- [ ] **Step 2: Run — verify it FAILS (module missing)**

Run:
```bash
cd fpga/sim
iverilog -g2012 -o tb_sdram_src_arb.vvp tb_sdram_src_arb.sv ../rtl/sdram_src_arb.sv && vvp tb_sdram_src_arb.vvp
```
Expected: FAIL — `Unknown module type: sdram_src_arb`.

- [ ] **Step 3: Implement the arbiter**

Create `fpga/rtl/sdram_src_arb.sv`:
```systemverilog
// sdram_src_arb.sv — registered-grant arbiter in front of sdram_psx.
// One source port now; add p1_* the same way for a second consumer later.
`default_nettype none
module sdram_src_arb (
   input  wire        clk,
   input  wire        reset,
   // port 0 (blitter source reads)
   input  wire [26:0] p0_addr,
   input  wire        p0_rd,
   output reg         p0_grant,
   output wire        p0_busy,
   // controller-facing
   output reg  [26:0] c_addr,
   output reg         c_rd,
   input  wire        c_ready,
   input  wire        c_busy
);
   assign p0_busy = c_busy;
   always @(posedge clk) begin
      if (reset) begin c_rd<=0; p0_grant<=0; c_addr<=0; end
      else begin
         c_rd     <= 0;
         p0_grant <= 0;
         // single port: grant whenever the controller can accept and p0 asks.
         if (p0_rd && !c_busy) begin
            c_addr   <= p0_addr;
            c_rd     <= 1;
            p0_grant <= 1;
         end
      end
   end
endmodule
```

- [ ] **Step 4: Run — verify PASS**

Run:
```bash
cd fpga/sim
iverilog -g2012 -o tb_sdram_src_arb.vvp tb_sdram_src_arb.sv ../rtl/sdram_src_arb.sv && vvp tb_sdram_src_arb.vvp
```
Expected: `errors=0 max_gap=<=4`.

- [ ] **Step 5: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
git add fpga/rtl/sdram_src_arb.sv fpga/sim/tb_sdram_src_arb.sv
git commit -m "fpga(#19): sdram_src_arb registered-grant arbiter (bounded grant gap)"
```

---

## Task 6: Cache-line-width sweep (confirm/tune the 128-bit default)

Profile cycles/line for 64/128/256-bit against a representative read pattern, so the `BURST_BEATS` default is data-backed, not guessed.

**Files:**
- Create: `fpga/sim/tb_sdram_sweep.sv`

- [ ] **Step 1: Write the sweep harness**

Create `fpga/sim/tb_sdram_sweep.sv` that instantiates `sdram_psx` three times (`#(.BURST_BEATS(1))`, `(2)`, `(4)`), drives each with the same trace of sequential + strided line reads (mimicking a tile-row blit walk), and counts clk cycles from first `rd` to last `ready` per line. Print:
```systemverilog
    $display("SWEEP beats=1 cyc/line=%0d", c1);
    $display("SWEEP beats=2 cyc/line=%0d", c2);
    $display("SWEEP beats=4 cyc/line=%0d", c4);
    $display("errors=0");
```
Use the same `sdram_chip_model` per instance. Reuse the `rd_line`/`wait_ready` tasks from `tb_sdram_psx.sv` (copy them in; tasks are not shared across files).

- [ ] **Step 2: Run the sweep**

Run:
```bash
cd fpga/sim
iverilog -g2012 -o tb_sdram_sweep.vvp tb_sdram_sweep.sv ../rtl/sdram_psx.sv sdram_chip_model.sv && vvp tb_sdram_sweep.vvp
```
Expected: three `SWEEP beats=… cyc/line=…` lines + `errors=0`. **Record the numbers in the spec's validation section.** Confirm 128-bit (beats=2) is at/near the cyc/px knee; if 256-bit is materially better AND the trace's run-lengths support it, change the controller's default `BURST_BEATS` to 4 and note why.

- [ ] **Step 3: Commit the sweep + recorded result**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
git add fpga/sim/tb_sdram_sweep.sv docs/superpowers/specs/2026-06-15-issue19-psx-sdram-controller-design.md
git commit -m "fpga(#19): cache-line-width sweep + record cyc/line result"
```

---

## Task 7: Source-select integration into the blitter (runtime control register)

Add a control-register bit that routes blitter source reads through `sdram_src_arb`→`sdram_psx` instead of the DDR3 readcache, defaulting to DDR3 (analog-clean baseline). The blitter already reads control words from the BLTCTRL region (`blitter_top.sv` `mem_rd`/`mem_addr` against `BLTCTRL_QW`); reuse that path for the select bit.

**Files:**
- Modify: `fpga/rtl/blitter_top.sv` (source-read mux + read the select bit)
- Modify: `fpga/rtl/blitter_defs.vh` (define the new control-word offset/bit)
- Modify: `fpga/Solarus.sv` (instantiate `sdram_src_arb` + `sdram_psx`, wire the SDRAM pins)
- Modify: `fpga/sim/tb_blitter_system.sv` (assert both source paths return identical pixels)

- [ ] **Step 1: Define the select control bit**

In `fpga/rtl/blitter_defs.vh`, add (follow the existing `C_*` offset style):
```systemverilog
`define C_SRCSEL 4   // BLTCTRL word: bit0 = 1 -> SDRAM source, 0 -> DDR3 readcache (default)
```

- [ ] **Step 2: Write the failing equivalence test**

In `fpga/sim/tb_blitter_system.sv`, add a case that runs the SAME blit twice — once with `C_SRCSEL=0` (DDR3) and once with `=1` (SDRAM, seeded with identical source bytes) — and asserts the composited output pixels are byte-identical:
```systemverilog
    run_blit_ddr3();  capture(out_ddr3);
    run_blit_sdram(); capture(out_sdram);
    if (out_ddr3 !== out_sdram) begin errors=errors+1; $display("source paths differ"); end
```

- [ ] **Step 3: Run — verify it FAILS (no SDRAM path yet)**

Run:
```bash
cd fpga/sim
iverilog -g2012 -o tb_blitter_system.vvp tb_blitter_system.sv ../rtl/blitter_top.sv ../rtl/sdram_psx.sv ../rtl/sdram_src_arb.sv sdram_chip_model.sv && vvp tb_blitter_system.vvp
```
Expected: FAIL — `source paths differ` or elaboration error (mux/select not wired).

- [ ] **Step 4: Wire the source-read mux in blitter_top**

In `fpga/rtl/blitter_top.sv`, latch the select bit alongside the other control words (add a read of `BLTCTRL_QW+`C_SRCSEL`` in the control-fetch FSM, like `C_FLAGS`), and route the source-read request/return through either the existing DDR3 path or the new `sdram_src_arb` based on the latched bit. Keep writes and scanout on DDR3 unchanged.

- [ ] **Step 5: Run — verify PASS**

Run:
```bash
cd fpga/sim
iverilog -g2012 -o tb_blitter_system.vvp tb_blitter_system.sv ../rtl/blitter_top.sv ../rtl/sdram_psx.sv ../rtl/sdram_src_arb.sv sdram_chip_model.sv && vvp tb_blitter_system.vvp
```
Expected: `errors=0` (both source paths produce identical pixels).

- [ ] **Step 6: Instantiate in the top level + register files for the build**

In `fpga/Solarus.sv`, instantiate `sdram_src_arb` + `sdram_psx`, connect the `SDRAM_*` pins (already present in `sys`/the QSF), and feed the select bit. In `fpga/files.qip`, add `fpga/rtl/sdram_psx.sv` and `fpga/rtl/sdram_src_arb.sv`.

- [ ] **Step 7: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
git add fpga/rtl/blitter_top.sv fpga/rtl/blitter_defs.vh fpga/Solarus.sv fpga/files.qip fpga/sim/tb_blitter_system.sv
git commit -m "fpga(#19): runtime source-select (DDR3 default / SDRAM) + top-level wiring"
```

---

## Task 8: CDC change + timing closure (CI-gated)

Replace the marginal CDC constraint and confirm the build closes with more margin than v3.0's +0.076ns. **Quartus runs in CI, not locally.**

**Files:**
- Modify: `fpga/Solarus.sdc`

- [ ] **Step 1: Switch the clk_sys↔clk_pix CDC to set_false_path**

In `fpga/Solarus.sdc`, replace the `set_clock_groups -async` between `clk_sys` and `clk_pix` with explicit `set_false_path -from [get_clocks clk_sys] -to [get_clocks clk_pix]` and the reverse (PSX-equivalent; keep any existing same-domain constraints). Leave a comment referencing the spec's CDC section.

- [ ] **Step 2: Commit + push; trigger the CI Quartus build**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
git add fpga/Solarus.sdc
git commit -m "fpga(#19): clk_sys<->clk_pix CDC set_false_path (analog-margin)"
git push -u origin issue19-psx-sdram-controller
```
Then trigger/await the FPGA build workflow (`gh run watch` on the RBF build).

- [ ] **Step 3: Read the timing report — GATE**

Download the build's timing summary. **Gate:** worst-slack on the video path > **+0.076ns** (better than v3.0). Record the worst-slack path. If it regressed, add targeted pipelining/constraints and rebuild before any device step.

- [ ] **Step 4: Commit any timing fixups**

```bash
git add -A && git commit -m "fpga(#19): timing fixups to clear +0.076ns margin"
```

---

## Task 9: On-device analog bring-up + roll diagnosis (USER-GATED — counters lie about analog)

**This task requires the user at the analog/CRT display. Do not claim success from counters/HDMI/sims.** Build PSX, diagnose the roll on THIS build (the agreed sequencing).

- [ ] **Step 1: Deploy the RBF + the SDRAM-source-capable engine to the device**

Download the CI RBF and deploy (per CLAUDE.md deploy recipe). Keep `C_SRCSEL=0` (DDR3) as the boot default.

- [ ] **Step 2: Baseline — confirm analog clean with SDRAM idle**

User watches the analog/CRT: with `C_SRCSEL=0`, confirm the picture is stable (no roll). This proves the new build is analog-clean before turning SDRAM on.

- [ ] **Step 3: Toggle SDRAM source live; observe analog**

Flip `C_SRCSEL=1` at runtime (the control-register write). User reports: does the analog roll appear? Does HDMI stay clean while analog rolls? (HDMI-clean + analog-roll → localizes to the clk_pix/analog path.)

- [ ] **Step 4: Vary burst rate / inject idle gaps**

If it rolls: reduce SDRAM activity (smaller `BURST_BEATS` / inserted idle) and observe whether the roll lessens (tests the power-transient hypothesis vs a fixed timing path).

- [ ] **Step 5: Correlate with the worst-slack path from Task 8**

Match the observed behavior to the timing report's worst-slack path (ascal vs a controller-created clk_sys→clk_pix path). This pins the mechanism.

- [ ] **Step 6: Decide outcome**

- If **analog clean** with SDRAM active → the bus is shippable; record the cyc/px win vs DDR3 readcache; consider flipping the default (separate decision with the user).
- If it **rolls** → record the diagnosed mechanism + the fix path (constraint/pipeline/PLL isolation per the spec's open questions) as the next iteration. Do NOT flip the default.

- [ ] **Step 7: Post results to #19 + update the spec's validation section**

```bash
gh issue comment 19 --body-file <results>
git add docs/superpowers/specs/2026-06-15-issue19-psx-sdram-controller-design.md
git commit -m "docs(#19): record on-device analog bring-up + roll diagnosis result"
```

---

## Notes for the executor

- **RTL steps are diffs against ported code, not greenfield.** The testbenches in each task are complete, runnable code (they are the TDD drivers). The `sdram_psx.sv` controller edits are concrete fragments applied against the v3.0 file ported in Task 1 — read that file first; the fragments show exactly what to add/change and where. Do not expect a full module reproduction per step.
- **Sims are the gate for Tasks 1–7.** Each must print `errors=0` before its commit.
- **Tasks 8–9 are gated** on CI (Quartus) and the user (analog). Do not mark them done from local sims.
- The stock `fpga/rtl/sdram.sv` and the DDR3 readcache path are **never modified** — they remain the analog-clean default/fallback.
- Address-map bit layout is the v3.0 `col=addr[9:1], bank=addr[11:10], row=addr[24:12]` — copy the exact packing helper from `sdram-burst:fpga/sim/tb_sdram_ctrl.sv` rather than re-deriving.
- If a ported file references a module not yet on master (e.g. `sdram_selftest`), it is out of scope — do not bring it over; only the three Task-1 files are needed.
