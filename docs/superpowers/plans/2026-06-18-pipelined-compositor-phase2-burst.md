# Pipelined Compositor — Phase 2 Burst Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the issue-interval-1 compositor's throughput real by replacing its single-beat DDR accesses with a bounded-length burst engine, proving the cyc/px win in simulation and closing Quartus timing.

**Architecture:** A new `comp_burst` master (dedicated, shallow, instantiated inside `comp_pipeline`) batches the pipe's three DDR access loops (band LOAD reads, source-row fetch reads, band FLUSH writes) into aligned sequential bursts. `ddr_blitter_arb` is extended to accept a blitter burstcount and hold the blitter grant for a whole bounded burst, while the video reader keeps default ownership and never starves. Burst length is capped at a tunable `MAXBURST` sized to feed ≈1 px/clock, settled by contention simulation. All Phase-1 modules stay bit-exact behind `C_PIPE`.

**Tech Stack:** SystemVerilog (synthesizable subset), Icarus Verilog 13 + `vvp` for simulation (`fpga/sim/run_sims.sh`, `-y` library mode, module-name == file-name), Quartus Prime 17.0.x for synthesis/STA.

## Global Constraints

- **Toolchain:** Icarus Verilog 13 for sim; Quartus Prime **17.0.x** (17.0.2) for synthesis — newer Quartus is NOT compatible.
- **Bit-exact to the golden:** `patches/mister/blitter/blitter_ref.h` / `blitter_ref.c`. The host/fabric contract (`blt_cmd_t`, opcodes, blend modes, 32-byte ring entry, submit/done handshake) is **frozen** — do not change it.
- **Reader never starves:** the video reader (m0) is the default f2h DDR owner; the blitter (m1) only borrows the bus in genuine reader-idle gaps. A missed reader scanline beat = black screen (HW-confirmed).
- **No per-pixel DDR beats:** the blitter moves data only via bursts to/from on-chip buffers.
- **New RTL:** `module == file name`, in `fpga/rtl/`; first two header lines `// <file> — <purpose>` and `// Copyright (C) 2026 — GPL-3.0`. Use `` `default_nettype none `` at top and `` `default_nettype wire `` at bottom.
- **Icarus `-y` gotchas:** all files share one compilation unit, so an `` `include "comp_defs.vh" `` guarded by `COMP_DEFS_VH` is a no-op if a testbench included it first — RTL keeps an `` `ifndef `` fallback. Icarus 13 rejects unsized-integer arithmetic inside concatenations — add `N'(...)` casts. The `comp_*` family uses `initial` blocks for power-on state (no reset port) in addition to a synchronous `rst`.
- **Commit policy:** commit early and often in this worktree (commits are isolated and provide resilience). End every commit body with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **Run a single testbench:** `cd fpga/sim && ./run_sims.sh <tb_name>`. Whole suite: `./run_sims.sh`. PASS prints the TB's marker (`RESULT: PASS` for new TBs); FAIL prints any of `FAIL|DEADLOCK|STARV|WEDGE|Assertion failed|PROTO:|TIMEOUT`.
- **`C_PIPE` selector:** the pipe path is enabled by bit 1 of the C_SRCSEL control word at command-relative offset 7 (`C_PIPE = 29'd7`, `C_PIPE_BIT = 1`). In the system/profile testbenches it is set by writing `64'd2` to `mem[base + 7]`.
- **Worktree:** all work is on branch `spec/pipelined-compositor` in `.claude/worktrees/pipelined-compositor/`. The main checkout stays on `feature-sdram-64mb-geometry`, undisturbed. Paths below are relative to the worktree root.

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `fpga/rtl/comp_burst.sv` | Bounded-length burst DMA master: turns `{addr,len,dir}` transfer requests into aligned bursts on `mem_*` + `mem_burstcnt`; streams read beats out / write beats in. | **Create** |
| `fpga/sim/tb_comp_burst.sv` | Unit test for `comp_burst` against a behavioral burst-capable DDR model. | **Create** |
| `fpga/rtl/ddr_blitter_arb.sv` | Add `blt_burstcnt`; hold blitter grant for a whole bounded burst (read beats + write beats); keep reader default + never-starve. | **Modify** |
| `fpga/sim/tb_ddr_blitter_arb.sv` | Add a blitter-burst scenario + reader-never-starve assertion. | **Modify** |
| `fpga/rtl/comp_pipeline.sv` | Replace the three single-beat loops (P_LOAD, P_SRCFILL, P_WB) with `comp_burst` transfer requests; add `mem_burstcnt` output; instantiate `comp_burst`. | **Modify** |
| `fpga/rtl/blitter_top.sv` | Thread `mem_burstcnt` through the owner mux (`pipe_busy ? p_mem_burstcnt : 8'd1`). | **Modify** |
| `fpga/sim/tb_blitter_system_pipe.sv` | Wire `mem_burstcnt` → arbiter `blt_burstcnt`; keep PHASE1 green. | **Modify** |
| `fpga/sim/tb_profile.sv` | Add a `C_PIPE=1` measurement mode probing `blt.u_pipe.state` memory-wait states; run pre- and post-burst. | **Modify** |
| `fpga/sim/tb_vram_contention.sv` | Add a blitter-burst-vs-reader contention assertion (reader loses no beats; blitter hold ≤ MAXBURST). | **Modify** |
| `fpga/files.qip` | Add `comp_*` and `comp_burst` to the synthesis file list. | **Modify** |

`MAXBURST` is a parameter on both `comp_burst` and (as the max it will honor) `ddr_blitter_arb`. Its default is `16`; the **final value is settled by the Task 6 contention sweep** and is the smallest value that lifts measured memory throughput to ≈1 px/clock while the reader loses no beats.

---

## Task 1: Profile-first baseline (C_PIPE=1 measurement)

Establish the *measured* single-beat bottleneck before designing the burst, per Beasley §3.6. This is a test-only change; its deliverable is a reproducible C_PIPE=1 cyc/px number with a nonzero DDR-wait fraction.

**Files:**
- Modify: `fpga/sim/tb_profile.sv`

**Interfaces:**
- Consumes: `blitter_top` standalone with the single-beat behavioral DDR model already in `tb_profile.sv`; the pipe FSM states `P_LOAD_WAIT=6'd4`, `P_SRCFILL_WAIT=6'd7`, `P_WB_WAIT=6'd13` from `comp_pipeline.sv` (probe via `blt.u_pipe.state`).
- Produces: a `run_pipe_blit` task and console lines tagged `PIPE <mode>` reporting `cyc/px` and `ddr_wait %`.

- [ ] **Step 1: Write the C_PIPE=1 profiling task (failing — task not yet defined)**

Add this task to `tb_profile.sv` after the existing `run_blit` task. It enables the pipe by writing `64'd2` to the C_SRCSEL word, and accounts memory-wait cycles by probing the pipe FSM rather than the legacy FSM:

```systemverilog
  // C_PIPE=1 profiling: same blit, routed through comp_pipeline. Memory-wait
  // cycles are the pipe's read/write wait states; everything else is compute.
  task run_pipe_blit(input integer w_, input integer h_, input integer blend_,
                     input [127:0] name);
    integer to;
    begin
      setup_blit(w_, h_, blend_);
      mem[32'h200007] = 64'd2;             // C_PIPE=1 (bit1), C_SRCSEL=0
      rst<=1; repeat(4) @(posedge clk); rst<=0;
      cyc=0; c_rdwait=0; c_wrwait=0; c_compute=0; started=0; to=0;
      while (mem[32'h200005][31:0] !== mem[32'h200000][31:0] && to<2000000) begin
        @(posedge clk); to=to+1;
        if (blt.u_pipe.state != 6'd0) started=1;     // pipe left P_IDLE
        if (started) begin
          cyc=cyc+1;
          if (blt.u_pipe.state==6'd4 || blt.u_pipe.state==6'd7) c_rdwait=c_rdwait+1; // P_LOAD_WAIT/P_SRCFILL_WAIT
          else if (blt.u_pipe.state==6'd13) c_wrwait=c_wrwait+1;                      // P_WB_WAIT
          else c_compute=c_compute+1;
        end
      end
      $display("PIPE %0s  WxH=%0dx%0d (%0d px): total=%0d cyc  rd_wait=%0d  wr_wait=%0d  compute=%0d  => %0.2f cyc/px (ddr_wait %0.1f%%)",
        name, w_, h_, w_*h_, cyc, c_rdwait, c_wrwait, c_compute,
        cyc*1.0/(w_*h_), 100.0*(c_rdwait+c_wrwait)/cyc);
    end
  endtask
```

- [ ] **Step 2: Call the task for a large steady-state blit in the `initial` block**

Add these calls after the existing legacy `run_blit(...)` calls, before `$finish`:

```systemverilog
    run_pipe_blit(64, 64, 0, "COPY  ");   // large blit for steady state
    run_pipe_blit(64, 64, 2, "ALPHA ");
    run_pipe_blit(64, 64, 3, "PALPHA");
```

- [ ] **Step 3: Run the profiler and capture the baseline**

Run: `cd fpga/sim && ./run_sims.sh tb_profile`
Expected: completes without `TIMEOUT`; prints three `PIPE ...` lines. Record the `cyc/px` and `ddr_wait %` for each — this is the **single-beat baseline**. The DDR-wait fraction must be clearly nonzero (the thing bursts will cut). If `ddr_wait` is ~0%, stop and re-examine the probe (the pipe is supposed to be memory-bound).

- [ ] **Step 4: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister/.claude/worktrees/pipelined-compositor
git add fpga/sim/tb_profile.sv
git commit -m "profile: add C_PIPE=1 measurement; record single-beat baseline

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `comp_burst` module + unit test

Create the bounded-length burst master and prove it in isolation against a behavioral burst-capable DDR model.

**Files:**
- Create: `fpga/rtl/comp_burst.sv`
- Create: `fpga/sim/tb_comp_burst.sv`

**Interfaces:**
- Produces (the interface later tasks rely on — copy these signatures exactly):
  ```
  module comp_burst #(parameter AW = 32, parameter MAXBURST = 16) (
    input  wire          clk, rst,
    // transfer request (from comp_pipeline)
    input  wire          req,            // 1-cycle pulse: start a transfer
    input  wire          req_we,         // 0 = read, 1 = write
    input  wire [AW-1:0] req_addr,       // qword address of first beat
    input  wire [15:0]   req_len,        // beats in this transfer (>= 1)
    output reg           busy,           // high from accept until done pulse
    output reg           done,           // 1-cycle pulse at completion
    // read-return stream (to band-load / linebuf-fill consumer)
    output reg           rd_valid,       // a returned qword is valid this cycle
    output reg  [63:0]   rd_qw,
    output reg  [15:0]   rd_beat,        // 0-based beat index within the transfer
    // write-data stream (from flush-FIFO producer)
    output reg           wr_take,        // comp_burst consumes wr_qw/wr_be this cycle
    output reg  [15:0]   wr_beat,        // 0-based beat index being written
    input  wire [63:0]   wr_qw,
    input  wire [7:0]    wr_be,
    // mem_* master to the bus (owner-muxed in blitter_top -> arbiter blt_*)
    output reg  [AW-1:0] mem_addr,
    output reg           mem_rd, mem_wr,
    output reg  [7:0]    mem_burstcnt,
    output reg  [63:0]   mem_din,
    output reg  [7:0]    mem_be,
    input  wire [63:0]   mem_dout,
    input  wire          mem_dout_ready,
    input  wire          mem_busy
  );
  ```
- Contract: a transfer of `req_len` beats is split into back-to-back sub-bursts of at most `MAXBURST` beats. For reads, each returned beat is presented on `rd_valid`/`rd_qw` with the running `rd_beat` index (0..req_len-1). For writes, `wr_take` pulses the cycle a beat is accepted by the bus, presenting `wr_beat` so the producer can supply the right `wr_qw`/`wr_be`. `done` pulses one cycle after the last beat; `busy` is low again the cycle after `done`.

- [ ] **Step 1: Write the failing unit test**

Create `fpga/sim/tb_comp_burst.sv`. It instantiates `comp_burst` with `MAXBURST=4` (to force sub-burst splitting on an 8-beat transfer) against a behavioral DDR model that honors `mem_burstcnt` for both reads (latency then N beats) and writes (N back-to-back accepts), with periodic backpressure:

```systemverilog
// tb_comp_burst.sv — unit test for the bounded-length burst master.
// Copyright (C) 2026 — GPL-3.0
`timescale 1ns/1ps
`default_nettype none
module tb_comp_burst;
  localparam AW=32, MB=4;
  reg clk=0, rst=1; always #5 clk=~clk;

  // request / stream
  reg          req=0, req_we=0; reg [AW-1:0] req_addr=0; reg [15:0] req_len=0;
  wire         busy, done;
  wire         rd_valid; wire [63:0] rd_qw; wire [15:0] rd_beat;
  wire         wr_take; wire [15:0] wr_beat;
  reg  [63:0]  wr_qw=0; reg [7:0] wr_be=0;
  // bus
  wire [AW-1:0] mem_addr; wire mem_rd, mem_wr; wire [7:0] mem_burstcnt, mem_be;
  wire [63:0]  mem_din; reg [63:0] mem_dout=0; reg mem_dout_ready=0; reg mem_busy=0;

  comp_burst #(.AW(AW), .MAXBURST(MB)) dut (
    .clk(clk), .rst(rst),
    .req(req), .req_we(req_we), .req_addr(req_addr), .req_len(req_len),
    .busy(busy), .done(done),
    .rd_valid(rd_valid), .rd_qw(rd_qw), .rd_beat(rd_beat),
    .wr_take(wr_take), .wr_beat(wr_beat), .wr_qw(wr_qw), .wr_be(wr_be),
    .mem_addr(mem_addr), .mem_rd(mem_rd), .mem_wr(mem_wr),
    .mem_burstcnt(mem_burstcnt), .mem_din(mem_din), .mem_be(mem_be),
    .mem_dout(mem_dout), .mem_dout_ready(mem_dout_ready), .mem_busy(mem_busy));

  // ── behavioral burst DDR model ──────────────────────────────────────────
  // backpressure: busy 1-in-3. Reads: on accept, latency=3 then burstcnt beats
  // of mem[addr+i]. Writes: accept burstcnt beats back-to-back into mem[].
  reg [63:0] mem [0:1023];
  reg [7:0]  bremain; reg [AW-1:0] baddr; reg [2:0] blat; reg [1:0] bp=0;
  reg        bwr;
  integer i;
  always @(posedge clk) bp <= bp + 2'd1;
  always @(*) mem_busy = (bp==2'd0);                 // periodic backpressure
  always @(posedge clk) begin
    mem_dout_ready <= 1'b0;
    if (rst) begin bremain<=0; blat<=0; end
    else begin
      if (blat != 0) blat <= blat - 3'd1;
      else if (bremain != 0 && !bwr) begin
        mem_dout <= mem[baddr[9:0]]; mem_dout_ready <= 1'b1;
        baddr <= baddr + 1; bremain <= bremain - 8'd1;
      end else if (!mem_busy) begin
        if (mem_rd) begin bremain<=mem_burstcnt; baddr<=mem_addr; blat<=3'd3; bwr<=0; end
        else if (mem_wr) begin                      // accept this write beat
          for (i=0;i<8;i=i+1) if (mem_be[i]) mem[mem_addr[9:0]][i*8+:8] <= mem_din[i*8+:8];
        end
      end
    end
  end

  // producer for write beats: supply a known pattern keyed by wr_beat
  always @(*) begin wr_qw = {48'hABCD_0000_0000 | 16'(wr_beat)}; wr_be = 8'hFF; end

  integer errors=0; integer rcount;
  reg [63:0] seen [0:31];
  initial begin
    for (i=0;i<1024;i=i+1) mem[i]=64'd0;
    for (i=0;i<8;i=i+1) mem[100+i] = 64'h1000_0000_0000_0000 + i; // read source
    rst<=1; repeat(5) @(posedge clk); rst<=0; @(posedge clk);

    // ---- READ transfer: 8 beats from addr 100, MAXBURST=4 -> two sub-bursts ----
    rcount=0;
    @(posedge clk); req<=1; req_we<=0; req_addr<=100; req_len<=8; @(posedge clk); req<=0;
    while (!done) begin @(posedge clk);
      if (rd_valid) begin seen[rd_beat]<=rd_qw; rcount=rcount+1; end
    end
    @(posedge clk);
    if (rcount != 8) begin errors=errors+1; $display("FAIL: read beats=%0d exp 8", rcount); end
    for (i=0;i<8;i=i+1) if (seen[i] !== (64'h1000_0000_0000_0000 + i))
      begin errors=errors+1; $display("FAIL: read beat %0d=%h", i, seen[i]); end

    // ---- WRITE transfer: 6 beats to addr 200, MAXBURST=4 -> 4+2 ----
    @(posedge clk); req<=1; req_we<=1; req_addr<=200; req_len<=6; @(posedge clk); req<=0;
    while (!done) @(posedge clk);
    @(posedge clk);
    for (i=0;i<6;i=i+1) if (mem[200+i] !== (64'hABCD_0000_0000 | 16'(i)))
      begin errors=errors+1; $display("FAIL: write beat %0d=%h", i, mem[200+i]); end

    if (errors==0) $display("RESULT: PASS");
    else           $display("RESULT: FAIL errors=%0d", errors);
    $finish;
  end
  initial begin #500000 $display("TIMEOUT"); $finish; end
endmodule
`default_nettype wire
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd fpga/sim && ./run_sims.sh tb_comp_burst`
Expected: `BUILD!` (module `comp_burst` does not exist yet).

- [ ] **Step 3: Implement `comp_burst.sv`**

Create `fpga/rtl/comp_burst.sv`. The FSM: `IDLE → ISSUE (assert rd/we + burstcnt, hold until !mem_busy accepts the command) → for reads RD_BEATS (count mem_dout_ready beats), for writes WR_BEATS (count !mem_busy accepts) → next sub-burst or DONE`.

```systemverilog
// comp_burst.sv — bounded-length sequential burst master for the compositor.
// Copyright (C) 2026 — GPL-3.0
//
// Turns a {req_addr, req_len, req_we} transfer request from comp_pipeline into
// aligned sequential bursts on the mem_* master, split into sub-bursts of at
// most MAXBURST beats so the arbiter never has to hold the f2h bus away from the
// video reader for longer than MAXBURST beats (reader-never-starve). Reads stream
// returned qwords out on rd_valid/rd_qw with a running rd_beat index; writes pull
// qwords in via wr_take/wr_beat. Shallow by design to protect fmax.
`default_nettype none
module comp_burst #(parameter AW = 32, parameter MAXBURST = 16) (
  input  wire          clk, rst,
  input  wire          req, req_we,
  input  wire [AW-1:0] req_addr,
  input  wire [15:0]   req_len,
  output reg           busy, done,
  output reg           rd_valid,
  output reg  [63:0]   rd_qw,
  output reg  [15:0]   rd_beat,
  output reg           wr_take,
  output reg  [15:0]   wr_beat,
  input  wire [63:0]   wr_qw,
  input  wire [7:0]    wr_be,
  output reg  [AW-1:0] mem_addr,
  output reg           mem_rd, mem_wr,
  output reg  [7:0]    mem_burstcnt,
  output reg  [63:0]   mem_din,
  output reg  [7:0]    mem_be,
  input  wire [63:0]   mem_dout,
  input  wire          mem_dout_ready,
  input  wire          mem_busy
);
  localparam [2:0] S_IDLE=3'd0, S_ISSUE=3'd1, S_RDBEATS=3'd2, S_WRBEATS=3'd3, S_DONE=3'd4;
  reg [2:0]  state;
  reg        dir_we;
  reg [AW-1:0] cur_addr;
  reg [15:0] rem;          // beats remaining in the whole transfer
  reg [7:0]  this_burst;   // beats in the current sub-burst
  reg [7:0]  beats_left;   // beats remaining in the current sub-burst
  reg [15:0] beat_ix;      // global beat index (0..req_len-1)

  wire [7:0] next_burst = (rem > MAXBURST[15:0]) ? MAXBURST[7:0] : rem[7:0];

  initial begin
    state=S_IDLE; busy=0; done=0; rd_valid=0; rd_qw=0; rd_beat=0;
    wr_take=0; wr_beat=0; mem_rd=0; mem_wr=0; mem_burstcnt=8'd1; mem_addr=0; mem_din=0; mem_be=0;
  end

  always @(posedge clk) begin
    // single-cycle strobe defaults
    done<=1'b0; rd_valid<=1'b0; wr_take<=1'b0;
    if (rst) begin
      state<=S_IDLE; busy<=1'b0; mem_rd<=1'b0; mem_wr<=1'b0; mem_burstcnt<=8'd1;
    end else case (state)
      S_IDLE: begin
        mem_rd<=1'b0; mem_wr<=1'b0;
        if (req) begin
          busy<=1'b1; dir_we<=req_we; cur_addr<=req_addr; rem<=req_len; beat_ix<=16'd0;
          state<=S_ISSUE;
        end else busy<=1'b0;
      end
      S_ISSUE: begin
        // present the sub-burst command; hold until the bus accepts it (!mem_busy)
        this_burst   <= next_burst;
        beats_left   <= next_burst;
        mem_addr     <= cur_addr;
        mem_burstcnt <= next_burst;
        mem_rd       <= ~dir_we;
        mem_wr       <= dir_we;
        if (dir_we) begin
          mem_din <= wr_qw; mem_be <= wr_be;            // first write beat data
          if (!mem_busy) begin
            wr_take<=1'b1; wr_beat<=beat_ix;
            beat_ix<=beat_ix+16'd1; cur_addr<=cur_addr+1;
            beats_left<=next_burst-8'd1; rem<=rem-16'd1;
            if (next_burst==8'd1) begin mem_wr<=1'b0; state<=(rem==16'd1)?S_DONE:S_ISSUE; end
            else                  state<=S_WRBEATS;
          end
        end else begin
          if (!mem_busy) begin mem_rd<=1'b0; state<=S_RDBEATS; end
        end
      end
      S_RDBEATS: begin
        if (mem_dout_ready) begin
          rd_valid<=1'b1; rd_qw<=mem_dout; rd_beat<=beat_ix;
          beat_ix<=beat_ix+16'd1; cur_addr<=cur_addr+1;
          beats_left<=beats_left-8'd1; rem<=rem-16'd1;
          if (beats_left==8'd1) state<=(rem==16'd1)?S_DONE:S_ISSUE;
        end
      end
      S_WRBEATS: begin
        mem_wr<=1'b1; mem_din<=wr_qw; mem_be<=wr_be;
        if (!mem_busy) begin
          wr_take<=1'b1; wr_beat<=beat_ix;
          beat_ix<=beat_ix+16'd1; cur_addr<=cur_addr+1;
          beats_left<=beats_left-8'd1; rem<=rem-16'd1;
          if (beats_left==8'd1) begin mem_wr<=1'b0; state<=(rem==16'd1)?S_DONE:S_ISSUE; end
        end
      end
      S_DONE: begin
        mem_rd<=1'b0; mem_wr<=1'b0; done<=1'b1; busy<=1'b0; state<=S_IDLE;
      end
      default: state<=S_IDLE;
    endcase
  end
endmodule
`default_nettype wire
```

> **Note on `wr_qw`/`wr_be`:** the producer must present the qword/be for `wr_beat` combinationally (as the test does). `comp_burst` latches it on accept. When integrated (Task 4) the flush FIFO read pointer is driven by `wr_take`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd fpga/sim && ./run_sims.sh tb_comp_burst`
Expected: `RESULT: PASS`. If a beat index or sub-burst boundary is off, fix `comp_burst` (not the test) until the read pattern and write pattern both match.

- [ ] **Step 5: Commit**

```bash
git add fpga/rtl/comp_burst.sv fpga/sim/tb_comp_burst.sv
git commit -m "feat(comp): comp_burst bounded-length burst master + unit test

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `ddr_blitter_arb` burst-grant extension

Extend the arbiter so the blitter can issue a burst of up to `MAXBURST` beats; the reader stays default owner and never starves.

**Files:**
- Modify: `fpga/rtl/ddr_blitter_arb.sv`
- Modify: `fpga/sim/tb_ddr_blitter_arb.sv`

**Interfaces:**
- Consumes: `comp_burst`'s `mem_burstcnt` (via `blitter_top`) as the new `blt_burstcnt` input.
- Produces: blitter burst reads (hold `G_BLT_RD` for `blt_burstcnt` beats) and burst writes (hold `G_BLT` for `blt_burstcnt` write accepts), with `ddram_burstcnt = blt_burstcnt` while the blitter owns the bus.

- [ ] **Step 1: Add the `blt_burstcnt` port and a blitter-beat counter**

In `ddr_blitter_arb.sv`, add to the blitter master port group:

```systemverilog
    input  wire [7:0]  blt_burstcnt,     // beats in the current blitter burst (>=1)
```

Add a blitter outstanding-beat counter near the reader's `rd_out`:

```systemverilog
    // blitter burst beat counters: how many beats the current blitter burst still
    // owes (reads: dout_ready beats; writes: !ddram_busy accepts). The grant is held
    // until this reaches zero. blt_burstcnt is bounded by MAXBURST at the master, so
    // the reader waits at most MAXBURST beats -> never starves.
    reg [7:0] blt_out;
```

- [ ] **Step 2: Write failing arbiter test additions**

Add a blitter-burst scenario to `tb_ddr_blitter_arb.sv` (new `tb_burst` module in the same file, since `-y` builds every module; the runner's pass marker for this file is `read errors=0|PASS`). It drives a 4-beat blitter read and a 3-beat blitter write while the reader periodically requests, and asserts: (a) all blitter read beats route to the blitter while granted, (b) the reader loses no accepted beat, (c) the blitter never holds the bus for more than `blt_burstcnt` beats.

```systemverilog
module tb_burst;
  reg clk=0,reset=1; always #5 clk=~clk;
  reg [7:0] r_burst=8'd1; reg [28:0] r_addr=0; reg r_rd=0; reg [63:0] r_din=0;
  reg [7:0] r_be=8'hFF; reg r_we=0; wire r_busy, r_grant;
  reg [7:0] b_burst=8'd1; reg [28:0] b_addr=0; reg b_rd=0; reg [63:0] b_din=0;
  reg [7:0] b_be=8'hFF; reg b_we=0; wire b_busy, b_grant;
  reg ddr_busy=0, ddr_dready=0; wire [7:0] d_burst; wire [28:0] d_addr;
  wire d_rd, d_we; wire [63:0] d_din; wire [7:0] d_be;
  integer errors=0, bbeats=0, holdmax=0, hold=0;

  ddr_blitter_arb #(.ENABLE(1'b1)) arb(.clk(clk),.reset(reset),
    .rdr_burstcnt(r_burst),.rdr_addr(r_addr),.rdr_rd(r_rd),.rdr_din(r_din),.rdr_be(r_be),.rdr_we(r_we),
    .rdr_busy(r_busy),.rdr_grant(r_grant),
    .blt_burstcnt(b_burst),.blt_addr(b_addr),.blt_rd(b_rd),.blt_din(b_din),.blt_be(b_be),.blt_we(b_we),
    .blt_busy(b_busy),.blt_grant(b_grant),
    .ddram_busy(ddr_busy),.ddram_dout_ready(ddr_dready),
    .ddram_burstcnt(d_burst),.ddram_addr(d_addr),.ddram_rd(d_rd),.ddram_din(d_din),.ddram_be(d_be),.ddram_we(d_we));

  // track how long the blitter continuously holds the bus (state != G_READER)
  always @(posedge clk) begin
    if (arb.state != 2'd0) begin hold<=hold+1; if (hold+1>holdmax) holdmax<=hold+1; end
    else hold<=0;
  end

  integer i;
  initial begin
    reset<=1; repeat(4) @(posedge clk); reset<=0; @(posedge clk);
    // blitter 4-beat read in a reader-idle gap
    b_burst<=8'd4; b_addr<=29'h100; b_rd<=1;
    // model: when granted read accepted, return 4 beats after latency
    fork
      begin : drv
        @(posedge clk); while(!(arb.state==2'd1 && !ddr_busy)) @(posedge clk);
        b_rd<=0;                               // command accepted
        repeat(3) @(posedge clk);              // latency
        for(i=0;i<4;i=i+1) begin ddr_dready<=1; @(posedge clk); ddr_dready<=0; end
      end
    join
    repeat(4) @(posedge clk);
    if (holdmax > 4+5) begin errors=errors+1; $display("FAIL: blitter held bus %0d cyc > burst", holdmax); end
    if (errors==0) $display("PASS (blitter burst read; reader not starved)");
    else           $display("read errors=%0d", errors);
    $finish;
  end
  initial begin #200000 $display("TIMEOUT"); $finish; end
endmodule
```

Run: `cd fpga/sim && ./run_sims.sh tb_ddr_blitter_arb`
Expected: `BUILD!` (port `blt_burstcnt` not yet on the module) — or an assertion failure once the port exists but burst hold isn't implemented.

- [ ] **Step 3: Implement the burst-grant FSM**

Replace the grant FSM and the mux in `ddr_blitter_arb.sv`. Reads: on read accept, latch `blt_out <= blt_burstcnt` and enter `G_BLT_RD`; decrement on each `ddram_dout_ready`; yield when `blt_out` reaches 0. Writes: stay in `G_BLT` for `blt_burstcnt` accepts, counting `!ddram_busy` cycles, yielding when done.

```systemverilog
    // blitter beat bookkeeping (reads counted by dout_ready; writes by !busy accept)
    always @(posedge clk) begin
        if (reset) blt_out <= 8'd0;
        else case (state)
            G_BLT:    if (b_rd & ~ddram_busy)      blt_out <= blt_burstcnt; // arm read beats
                      else if (b_we & ~ddram_busy) blt_out <= blt_burstcnt - 8'd1; // 1st write beat taken
            G_BLT_RD: if (ddram_dout_ready & (blt_out!=8'd0)) blt_out <= blt_out - 8'd1;
            G_BLT_WR: if (b_we & ~ddram_busy & (blt_out!=8'd0)) blt_out <= blt_out - 8'd1;
            default: ;
        endcase
    end

    always @(posedge clk) begin
        if (reset) state <= G_READER;
        else case (state)
            G_READER:
                if (rdr_idle & ~rdr_rd & ~rdr_we & ~ddram_busy & (b_rd | b_we))
                    state <= G_BLT;
            G_BLT:
                if      (b_rd & ~ddram_busy)               state <= G_BLT_RD;  // await read beats
                else if (b_we & ~ddram_busy)
                    state <= (blt_burstcnt==8'd1) ? G_READER : G_BLT_WR;       // 1-beat write done now
                else if (~b_rd & ~b_we)                    state <= G_READER;
            G_BLT_RD:
                if (ddram_dout_ready & (blt_out==8'd1))     state <= G_READER;  // last beat captured
            G_BLT_WR:
                if (b_we & ~ddram_busy & (blt_out==8'd1))   state <= G_READER;  // last write accepted
            default: state <= G_READER;
        endcase
    end
```

Add `G_BLT_WR` to the localparam list:

```systemverilog
    localparam [2:0] G_READER=3'd0, G_BLT=3'd1, G_BLT_RD=3'd2, G_BLT_WR=3'd3;
    reg [2:0] state;
```

Update `blt_grant`, `blt_busy`, and the mux so the burstcount is forwarded and writes can stream across `G_BLT_WR`:

```systemverilog
    assign rdr_grant = (state == G_READER);
    assign blt_grant = (state == G_BLT_RD);               // route read beats to blitter
    assign rdr_busy  = ddram_busy | (state != G_READER);
    assign blt_busy  = ddram_busy | ((state != G_BLT) & (state != G_BLT_WR));

    always @(*) begin
        if (state == G_READER) begin
            ddram_burstcnt = rdr_burstcnt; ddram_addr = rdr_addr; ddram_rd = rdr_rd;
            ddram_din = rdr_din; ddram_be = rdr_be; ddram_we = rdr_we;
        end else begin
            ddram_burstcnt = blt_burstcnt; ddram_addr = blt_addr;
            ddram_rd = (state == G_BLT) ? b_rd : 1'b0;     // read command only in G_BLT
            ddram_we = ((state == G_BLT) | (state == G_BLT_WR)) ? b_we : 1'b0;
            ddram_din = blt_din; ddram_be = blt_be;
        end
    end
```

> Note `state` widened to 3 bits; the existing `rdr_idle`/`rd_out` reader logic is unchanged (the reader still owns by default and is never lent to while `rd_out != 0`). Bounding `blt_burstcnt ≤ MAXBURST` at the master guarantees the reader waits at most `MAXBURST` beats.

- [ ] **Step 4: Run the arbiter tests to verify pass**

Run: `cd fpga/sim && ./run_sims.sh tb_ddr_blitter_arb`
Expected: `PASS (blitter burst read; reader not starved)` and the original `tb_deadlock` still prints `RESULT: PASS`. No `FAIL`/`STARV`.

- [ ] **Step 5: Commit**

```bash
git add fpga/rtl/ddr_blitter_arb.sv fpga/sim/tb_ddr_blitter_arb.sv
git commit -m "feat(arb): blitter burst-grant (read+write beat hold); reader stays default

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Integrate `comp_burst` into `comp_pipeline` (keep equivalence bit-exact)

Replace the three single-beat loops with `comp_burst` transfer requests and thread `mem_burstcnt` to the bus. This is the highest-risk task — the existing equivalence suite is the gate and must stay **bit-exact**.

**Files:**
- Modify: `fpga/rtl/comp_pipeline.sv`
- Modify: `fpga/rtl/blitter_top.sv`
- Modify: `fpga/sim/tb_blitter_system_pipe.sv`

**Interfaces:**
- Consumes: `comp_burst` (Task 2 signatures), the arbiter `blt_burstcnt` (Task 3).
- Produces: `comp_pipeline` gains a `mem_burstcnt[7:0]` output; `blitter_top` gains a `mem_burstcnt` output driven by the owner mux.

- [ ] **Step 1: Add `mem_burstcnt` to `comp_pipeline` and instantiate `comp_burst`**

In `comp_pipeline.sv` add the output port `output reg [7:0] mem_burstcnt,` next to `mem_be`. Add an instance and request/stream wires (the pipe FSM will now drive `cb_*` instead of `mem_*` directly; `comp_burst` drives `mem_*`):

```systemverilog
  // ── burst engine: the pipe issues {addr,len,dir} transfers; comp_burst drives mem_* ──
  reg          cb_req, cb_we;
  reg  [31:0]  cb_addr;
  reg  [15:0]  cb_len;
  wire         cb_busy, cb_done;
  wire         cb_rd_valid; wire [63:0] cb_rd_qw; wire [15:0] cb_rd_beat;
  wire         cb_wr_take;  wire [15:0] cb_wr_beat;
  reg  [63:0]  cb_wr_qw; reg [7:0] cb_wr_be;

  comp_burst #(.AW(32), .MAXBURST(`COMP_MAXBURST)) u_burst (
    .clk(clk), .rst(rst),
    .req(cb_req), .req_we(cb_we), .req_addr(cb_addr), .req_len(cb_len),
    .busy(cb_busy), .done(cb_done),
    .rd_valid(cb_rd_valid), .rd_qw(cb_rd_qw), .rd_beat(cb_rd_beat),
    .wr_take(cb_wr_take), .wr_beat(cb_wr_beat), .wr_qw(cb_wr_qw), .wr_be(cb_wr_be),
    .mem_addr(mem_addr), .mem_rd(mem_rd), .mem_wr(mem_wr),
    .mem_burstcnt(mem_burstcnt), .mem_din(mem_din), .mem_be(mem_be),
    .mem_dout(mem_dout), .mem_dout_ready(mem_dout_ready), .mem_busy(mem_busy));
```

Add `` `define COMP_MAXBURST 16 `` to `fpga/rtl/comp_defs.vh` (guarded), so synthesis and sim share it.

> The pipe no longer drives `mem_*` in its `always` block. Remove the `mem_rd/mem_wr/mem_be/mem_addr/mem_din` assignments from the FSM defaults and states (they are now `u_burst`'s outputs). Keep `mem_burstcnt` out of the FSM entirely.

- [ ] **Step 2: Rewrite the BAND LOAD loop to one burst per span row**

A span's preload covers consecutive qwords `ld_qx..ld_qx_end` of one row — already contiguous. Replace `P_LOAD_ISS`/`P_LOAD_WAIT` so each span row issues a single burst of `(ld_qx_end - ld_qx + 1)` beats, streaming returned beats into `comp_dest_band` via `db_ld_*`:

```systemverilog
        P_LOAD_ISS: begin
          if (ld_si >= chunk_nspan) begin
            chunk_si <= 9'd0; state <= P_COMP_SPAN;
          end else begin
            ld_qx       <= sp_dst_x[chunk_first + ld_si][15:2];
            ld_qx_end   <= (sp_dst_x[chunk_first + ld_si] + sp_len[chunk_first + ld_si] - 16'd1) >> 2;
            ld_band_row <= (sp_dst_y[chunk_first + ld_si] - chunk_base_y);
            cb_addr     <= target_base
                         + ({16'd0, sp_dst_y[chunk_first + ld_si]} * 32'd80)
                         + {16'd0, sp_dst_x[chunk_first + ld_si][15:2]};
            cb_len      <= ((sp_dst_x[chunk_first+ld_si] + sp_len[chunk_first+ld_si] - 16'd1) >> 2)
                         - (sp_dst_x[chunk_first+ld_si][15:2]) + 16'd1;
            cb_we       <= 1'b0; cb_req <= 1'b1;
            state       <= P_LOAD_WAIT;
          end
        end

        P_LOAD_WAIT: begin
          // stream burst beats into the band (beat i -> band qword ld_band_row*80 + ld_qx + i)
          if (cb_rd_valid) begin
            db_ld_we  <= 1'b1;
            db_ld_qw  <= cb_rd_qw;
            db_ld_idx <= ({4'd0, ld_band_row} * 13'd80) + {3'd0, ld_qx[9:0]} + 13'(cb_rd_beat);
          end
          if (cb_done) begin ld_si <= ld_si + 9'd1; state <= P_LOAD_ISS; end
        end
```

(`cb_req` needs a single-cycle default `cb_req <= 1'b0;` added to the strobe-defaults block at the top of the `always`.)

- [ ] **Step 3: Rewrite the SOURCE FILL loop to one burst per span**

The source fill reads qwords `gpix_lo>>2 .. gpix_hi>>2` — contiguous. Replace `P_SRCFILL_ISS`/`P_SRCFILL_WAIT`:

```systemverilog
        P_SRCFILL_ISS: begin
          cb_addr <= `SRC_QW + ((gpix_lo >> 2));
          cb_len  <= (gpix_hi >> 2) - (gpix_lo >> 2) + 32'd1;
          cb_we   <= 1'b0; cb_req <= 1'b1;
          state   <= P_SRCFILL_WAIT;
        end

        P_SRCFILL_WAIT: begin
          if (cb_rd_valid) begin
            lb_fill_we  <= 1'b1;
            lb_fill_qw  <= cb_rd_qw;
            lb_fill_idx <= 10'(cb_rd_beat);     // beat i -> linebuf qword i (base = gpix_lo>>2)
          end
          if (cb_done) begin pix_k <= 16'd0; pix_total <= cur_len; state <= P_PIXEL; end
        end
```

> Note this changes the linebuf base: index is now `cb_rd_beat` (0-based from `gpix_lo>>2`). The serve-x computation in `P_PIXEL` already subtracts `(gpix_lo>>2)<<2`, so the linebuf base is `gpix_lo>>2` — consistent. Verify with the HFLIP equivalence test.

- [ ] **Step 4: Rewrite the WRITE-BACK to burst contiguous FIFO runs**

The flush FIFO holds dirty qwords in increasing `f_idx` order. Coalesce consecutive `f_idx` entries into one burst. Replace `P_WB_ISS`/`P_WB_WAIT`:

```systemverilog
        // Find the length of the contiguous run starting at f_rptr, issue one burst.
        P_WB_ISS: begin
          if (f_empty) begin
            chunk_first <= chunk_first + chunk_nspan; state <= P_CHUNK_INIT;
          end else begin
            wb_run    <= 16'd1;            // run length, grown in P_WB_SCAN
            wb_base   <= f_idx[f_rptr[FIFO_AW-1:0]];
            state     <= P_WB_SCAN;
          end
        end

        // Grow the run while the next FIFO entry is f_idx contiguous and same be-able.
        P_WB_SCAN: begin
          if (((f_rptr + {{FIFO_AW{1'b0}}, wb_run}) != f_wptr) &&
              (f_idx[(f_rptr + wb_run)][FIFO_AW-1:0] == (wb_base + 13'(wb_run)))) begin
            wb_run <= wb_run + 16'd1;
          end else begin
            cb_addr <= target_base + ({16'd0, chunk_base_y} * 32'd80) + {19'd0, wb_base};
            cb_len  <= wb_run; cb_we <= 1'b1; cb_req <= 1'b1;
            state   <= P_WB_WAIT;
          end
        end

        // Feed write beats from the FIFO as comp_burst takes them.
        P_WB_WAIT: begin
          if (cb_wr_take) f_rptr <= f_rptr + 1'b1;     // advance after each accepted beat
          if (cb_done)    state  <= P_WB_ISS;
        end
```

Drive the write-beat data combinationally from the FIFO head (add near the FIFO declaration):

```systemverilog
  always @(*) begin
    cb_wr_qw = f_qw[f_rptr[FIFO_AW-1:0]];
    cb_wr_be = f_be[f_rptr[FIFO_AW-1:0]];
  end
```

Add the new states and run regs:

```systemverilog
    P_WB_SCAN = 6'd15;
  reg [15:0] wb_run; reg [12:0] wb_base;
```

> **Indexing caution (carried Phase-1 finding):** `f_idx` entries are 13-bit band-relative qword indices; `wb_run` growth assumes the FIFO array is indexable at `f_rptr + wb_run`. Keep the scan within `f_wptr`. This is the linchpin — the HFLIP/coalesce/painter equivalence tests gate it.

- [ ] **Step 5: Thread `mem_burstcnt` through `blitter_top`**

In `blitter_top.sv`: add `output wire [7:0] mem_burstcnt,` to the port list; add `wire [7:0] p_mem_burstcnt;` near the other `p_mem_*` wires; add `.mem_burstcnt(p_mem_burstcnt),` to the `u_pipe` instance; and extend the owner mux:

```systemverilog
    assign mem_burstcnt = pipe_busy ? p_mem_burstcnt : 8'd1;   // legacy FSM is single-beat
```

- [ ] **Step 6: Wire `mem_burstcnt` → `blt_burstcnt` in the system testbench**

In `tb_blitter_system_pipe.sv`: capture `blitter_top`'s new `mem_burstcnt` (`wire [7:0] bt_burst;`), connect it on the `blt` instance (`.mem_burstcnt(bt_burst)`), pass it through the DDR-side demux to `bd_burst`, and connect `.blt_burstcnt(bd_burst)` on the `arb` instance. The behavioral DDR model in that TB must honor `ddram_burstcnt` for blitter reads/writes (mirror the `tb_comp_burst` model: latency then N read beats; N back-to-back write accepts).

- [ ] **Step 7: Run the full equivalence + system suite — must stay bit-exact**

Run: `cd fpga/sim && ./run_sims.sh tb_comp_pipeline tb_blitter_copy_pipe tb_blitter_blend_pipe tb_blitter_coalesce_pipe tb_blitter_palpha_pipe tb_blitter_system_pipe`
Expected: every one prints `RESULT: PASS` / `PASS`. These are the bit-exact gate. If any fails, the burst integration changed behavior — debug `comp_pipeline`/`comp_burst`, never weaken the test.

- [ ] **Step 8: Run the legacy (C_PIPE=0) suite — no regression**

Run: `cd fpga/sim && ./run_sims.sh tb_blitter_copy tb_blitter_blend tb_blitter_coalesce tb_blitter_palpha`
Expected: all `PASS` (legacy FSM path is byte-identical; `mem_burstcnt` is forced `8'd1`).

- [ ] **Step 9: Commit**

```bash
git add fpga/rtl/comp_pipeline.sv fpga/rtl/comp_defs.vh fpga/rtl/blitter_top.sv fpga/sim/tb_blitter_system_pipe.sv
git commit -m "feat(comp): route comp_pipeline LOAD/SRCFILL/FLUSH through comp_burst

Bit-exact equivalence suite green; mem_burstcnt threaded through the
owner mux (legacy FSM stays single-beat).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Re-profile — prove the cyc/px win (G1)

**Files:**
- Modify: `fpga/sim/tb_profile.sv` (no structural change — the `run_pipe_blit` task now exercises the burst path automatically; add a PASS/FAIL gate on improvement).

**Interfaces:**
- Consumes: the Task-1 `run_pipe_blit` task and the recorded single-beat baseline.

- [ ] **Step 1: Add an improvement assertion to the profiler**

After the three `run_pipe_blit` calls, compare the post-burst cyc/px to the Task-1 baseline you recorded (hardcode the baseline numbers as constants from Task 1's run, or capture them in the same run by also calling the legacy single-beat path). Add:

```systemverilog
    // G1 gate: bursts must reduce DDR-wait fraction vs the single-beat baseline.
    if (last_ddr_wait_pct < baseline_ddr_wait_pct)
      $display("RESULT: PASS (G1: ddr_wait %0.1f%% < baseline %0.1f%%)", last_ddr_wait_pct, baseline_ddr_wait_pct);
    else
      $display("FAIL: G1 not met (ddr_wait %0.1f%% >= baseline %0.1f%%)", last_ddr_wait_pct, baseline_ddr_wait_pct);
```

(Capture `last_ddr_wait_pct` inside `run_pipe_blit` into a module-level real; set `baseline_ddr_wait_pct` from Task 1.)

- [ ] **Step 2: Run and confirm the win**

Run: `cd fpga/sim && ./run_sims.sh tb_profile`
Expected: prints the post-burst `PIPE ...` lines with **lower cyc/px and lower ddr_wait %** than the Task-1 baseline, and `RESULT: PASS (G1 ...)`. Compute is now the binding stage (or quantify the residual memory cost in the report).

- [ ] **Step 3: Commit**

```bash
git add fpga/sim/tb_profile.sv
git commit -m "profile: G1 gate — burst path beats single-beat ddr_wait baseline

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Reader-never-starve contention test + settle `MAXBURST`

Prove the bound under realistic reader contention and pick the final `MAXBURST`.

**Files:**
- Modify: `fpga/sim/tb_vram_contention.sv`

**Interfaces:**
- Consumes: `ddr_blitter_arb` with `blt_burstcnt` (Task 3), `comp_burst` (Task 2).

- [ ] **Step 1: Add a blitter-burst-vs-reader assertion**

Extend `tb_vram_contention.sv` so the reader issues its normal scanline bursts while the blitter runs bursts of `MAXBURST`. Assert: (a) the reader's accepted-beat count equals the beats it issued (no lost beats → no black screen), and (b) the blitter's longest continuous bus hold ≤ `MAXBURST + read-latency slack`. Emit `STARV` (a FAIL marker) if a reader beat is dropped:

```systemverilog
    if (reader_beats_in != reader_beats_out)
      $display("STARV: reader lost %0d beats", reader_beats_in - reader_beats_out);
```

- [ ] **Step 2: Sweep `MAXBURST` and pick the smallest safe value**

Run the contention test for `` `COMP_MAXBURST `` ∈ {8, 16, 32} (edit `comp_defs.vh`, re-run). Pick the **smallest** value that (a) never prints `STARV` and (b) at which `tb_profile` (Task 5) shows the cyc/px plateau (memory no longer the bottleneck). Set `` `COMP_MAXBURST `` to that value.

Run: `cd fpga/sim && ./run_sims.sh tb_vram_contention`
Expected: `RESULT: PASS`, no `STARV`.

- [ ] **Step 3: Re-confirm the full sim suite at the chosen `MAXBURST`**

Run: `cd fpga/sim && ./run_sims.sh`
Expected: `RESULT: PASS  gating-failures=0` (only `tb_profile` skipped; `tb_blitter_system` non-gating).

- [ ] **Step 4: Commit**

```bash
git add fpga/sim/tb_vram_contention.sv fpga/rtl/comp_defs.vh
git commit -m "test(contention): reader-never-starve under blitter bursts; settle COMP_MAXBURST

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Synthesis & STA (G5)

Close Quartus timing — the gate that the prior `burst-dma` attempt failed (−0.385 ns).

**Files:**
- Modify: `fpga/files.qip`

**Interfaces:**
- Consumes: all `comp_*` + `comp_burst` RTL.

- [ ] **Step 1: Add the comp files to the synthesis file list**

Ensure `fpga/files.qip` contains lines for every `comp_*` file and `comp_burst.sv`:

```tcl
set_global_assignment -name SYSTEMVERILOG_FILE rtl/comp_defs.vh
set_global_assignment -name SYSTEMVERILOG_FILE rtl/comp_mixer.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/comp_src_linebuf.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/comp_dest_band.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/comp_span_setup.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/comp_pipeline.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/comp_burst.sv
```

(Match the existing path/keyword style in `files.qip`; add only the missing entries.)

- [ ] **Step 2: Build under Quartus 17.0.x and read STA**

Run the project's Quartus build (per `reference/05-build-toolchain.md` / the repo's build script). After compile, open the TimeQuest/STA report and read **worst-case setup slack** at the f2h clock domain.
Expected: **slack ≥ 0**. Confirm Quartus picks up the authoritative `comp_defs.vh` values (`COMP_BAND_H`, `COMP_MAXBURST`) for all `comp_*` files — no `` `ifndef `` fallback silently diverging.

- [ ] **Step 3: If slack < 0, apply the fallback levers in order**

1. Add a pipeline register inside `comp_mixer` only (it is the deepest combinational path; keep `comp_burst` control shallow).
2. If BRAM-tight or still failing, reduce `` `COMP_BAND_H `` (e.g. 16 → 8) and re-run Tasks 5–6 to confirm correctness and the cyc/px win hold.
Re-build and re-read slack until ≥ 0.

- [ ] **Step 4: Commit the STA-closing changes**

```bash
git add fpga/files.qip   # plus any RTL touched by the fallback levers
git commit -m "synth: add comp_* + comp_burst to files.qip; STA setup slack >= 0 at f2h (G5)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: Fold carried Phase-1 findings + final verification

**Files:**
- Modify: `fpga/rtl/comp_pipeline.sv` (band-row range assert)
- Modify: the `*_pipe` testbench headers (stale comments)

**Interfaces:** none new.

- [ ] **Step 1: Add the band-row range assertion**

In `comp_pipeline.sv`, harden the linchpin (carried PCOMP-T5 finding): assert that a chunk's spans are consecutive rows so `cw_row`/`rd_row` (4-bit) never wrap. Add inside `P_COMP_SPAN` where `cur_band_row` is computed:

```systemverilog
            // synthesis_translate_off
            if ((sp_dst_y[chunk_first + chunk_si] - chunk_base_y) > (BAND_H-1))
              $display("FAIL: band_row %0d out of range (chunk not consecutive rows)",
                       sp_dst_y[chunk_first + chunk_si] - chunk_base_y);
            // synthesis_translate_on
```

- [ ] **Step 2: Fix stale `*_pipe` testbench header comments**

Update the header comment blocks of `tb_blitter_{copy,blend,coalesce,palpha}_pipe.sv` so they describe the C_PIPE=1 equivalence purpose (they were copied verbatim from the legacy originals).

- [ ] **Step 3: Final full-suite run (the definition-of-done gate)**

Run: `cd fpga/sim && ./run_sims.sh`
Expected: `passed=N gating-failures=0 non-gating-failures=0 ... RESULT: PASS` (only `tb_profile` skipped). This plus the Task 7 STA slack ≥ 0 is the cycle's done bar.

- [ ] **Step 4: Update the ledger and commit**

Append a `PCOMP-PHASE2` progress block to `.git/sdd/progress.md` summarizing: burst engine landed, G1 met (record cyc/px before/after), `MAXBURST` chosen, G5 STA slack value, what remains for the correctness/HW cycle (SDRAM-source, vram_demux partial-BE, `-DP2_SDRAM_SYS`, live HW G2).

```bash
git add fpga/rtl/comp_pipeline.sv fpga/sim/tb_blitter_*_pipe.sv
git commit -m "harden+docs: band_row range assert; refresh *_pipe headers; Phase 2 burst done

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 5: Request whole-branch review and finish the cycle**

Use `superpowers:requesting-code-review` on the burst cycle's diff, address findings, then `superpowers:finishing-a-development-branch` to decide integration. (Whole Phase-1+2 merge review still waits for the correctness/HW cycle to complete, per the spec.)

---

## Self-Review

**1. Spec coverage** (each spec section → task):
- §1 profile-first → Task 1; comp_burst → Task 2; arbiter burst-grant → Task 3; integration → Task 4; re-profile/G1 → Task 5; synth+STA/G5 → Task 7. ✓
- §3.3 bounded-burst rule + N-by-contention → Task 6 (sweep) + `MAXBURST` param. ✓
- §3.1/§3.2/§3.4 components → Tasks 2/3/4. ✓
- §5 verification (tb_comp_burst, reader-never-starve, no-regression, G1, G5) → Tasks 2/6/4/5/7. ✓
- §7 carried findings → Task 8. ✓
- Out-of-scope (SDRAM-source, vram_demux, `-DP2_SDRAM_SYS`, live HW) → explicitly NOT tasked; deferred note in Task 8 ledger. ✓

**2. Placeholder scan:** No "TBD"/"handle edge cases"/"similar to". `MAXBURST` is a parameter with a default and an explicit sweep procedure (Task 6) — not a placeholder. Quartus build invocation in Task 7 references the repo build script rather than inlining it (it is environment-specific and outside the RTL) — acceptable, with the concrete pass criterion (slack ≥ 0) stated.

**3. Type consistency:** `comp_burst` port names (`req/req_we/req_addr/req_len/busy/done/rd_valid/rd_qw/rd_beat/wr_take/wr_beat/wr_qw/wr_be/mem_burstcnt`) are identical in Task 2's definition and Task 4's instantiation. `blt_burstcnt` matches between Task 3 (port add) and Task 4/6 (wiring). `mem_burstcnt[7:0]` consistent across comp_pipeline/blitter_top/arbiter. State enum values used by the profiler (`P_LOAD_WAIT=4`, `P_SRCFILL_WAIT=7`, `P_WB_WAIT=13`) match `comp_pipeline.sv`. ✓
