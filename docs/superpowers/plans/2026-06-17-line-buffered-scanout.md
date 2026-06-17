# Line-Buffered Scanout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the SDRAM-source scanout robust to f2h contention by replacing the whole-frame, occupancy-coupled FIFO reader in `openbor_video_reader.sv` with a position-addressed ping-pong line buffer, so an underflow degrades to at most a single stale line instead of a cumulative vertical scroll.

**Architecture:** The pixel read side stops popping a dual-clock FIFO and instead reads a 64-bit-word line buffer addressed by *display position* (`{display-line-parity, hcol[8:2]}`). Two line buffers ping-pong by line parity (line L always lives in buffer `L%2`): while the display scans line N out of buffer `N%2` (read @clk_vid, indexed by an internal `hcol` counter), the DDR fill FSM fetches line N+1 into buffer `(N+1)%2` (write @ddr_clk, indexed by `beat_count`). Because the read index is anchored to screen position every line, a late fill corrupts only that one line; the next line re-anchors. The true-dual-port BRAM handles the data CDC; line-parity indexing means there is **no** explicit swap toggle to synchronize.

**Tech Stack:** SystemVerilog (Quartus / Cyclone V, M10K BRAM inference), Icarus Verilog (`iverilog -g2012`) for datapath sims. Source spec: `docs/superpowers/specs/2026-06-17-line-buffered-scanout-design.md`.

---

## Background the engineer must know

Read these before starting — they are load-bearing for the design:

- **Spec:** `docs/superpowers/specs/2026-06-17-line-buffered-scanout-design.md` (root cause, goals, the ping-pong architecture, what stays).
- **Target file:** `fpga/rtl/openbor_video_reader.sv` (941 lines). This single module owns one f2h master shared across video-line reads, control-word polling, joystick/vsync/cart writes, and audio ring DMA. **We touch ONLY the video pixel path.** Joystick, cart, audio, vsync-writeback, control-word, and arbiter paths must stay byte-for-byte.
- **Timing facts** (from `fpga/rtl/openbor_video_timing.sv`, same `clk_vid` domain as the reader's read side):
  - Active display: `hcount` 0..319, `vcount` 0..239. `de` is high exactly during `hcount` 0..319 of active lines.
  - During active scanout of display line N, `vcount == N` and is stable for the whole line (`vcount` increments at `hcount==419`).
  - `new_line` pulses for one `ce_pix` at the `hcount==319`→hblank boundary (i.e. just before the next active line).
  - `ce_pix` is a slow enable (~1 in 8 `clk_vid` cycles for H40 timing) — so a 1-`clk_vid`-latency BRAM read is always settled before the next `ce_pix`. The read design relies on this (documented inline).
- **Clock domains:** read/pixel side = `clk_vid` (input port `clk_vid`, gated by `ce_pix`); fill/DDR side = `ddr_clk` (= `clk_sys` at top level). `vcount`/`de`/`new_line` arrive already in `clk_vid` → usable directly on the read side, **no CDC needed** for them.
- **Why parity indexing needs the fill exactly 1 line ahead:** with only 2 buffers, line L lives in buffer `L%2`. While displaying line N (reading buf `N%2`), the fill writes line N+1 into buf `(N+1)%2` — different buffer, no collision. The current code preloads **2** lines (it would make the fill 2 ahead → it would clobber the buffer still being displayed). So the preload must be cut to **1** line. This is the one FSM-cadence change.

### Current vs. new data path (what changes)

| Concern | Current (FIFO) | New (line buffer) |
|---|---|---|
| Storage | `dcfifo line_fifo` (256×64) | `reg [63:0] linebuf[0:255]`, indexed `{buf, word}` |
| Fill write | `fifo_wr`/`fifo_wr_data` into FIFO | write port `lb_we/lb_waddr/lb_wdata` → `linebuf[{display_line[0], beat_count}]` |
| Read mapping | pop FIFO per 4 px (occupancy-coupled) | `linebuf[{vcount[0], hcol[8:2]}]`, lane `hcol[1:0]` (position-coupled) |
| Preload | lines 0 **and** 1 | line 0 only |
| Underflow result | cumulative frame scroll | single stale line, self-recovers |

The audio `dcfifo audio_fifo_inst` and everything else stay. (For sim we add a behavioral `dcfifo` stub since the audio FIFO is still instantiated and Icarus has no Altera primitives.)

---

## File Structure

- **Modify** `fpga/rtl/openbor_video_reader.sv` — the only RTL change. Remove the video `line_fifo` dcfifo + the `pixel_word`/`pixel_sub` occupancy walker; add the `linebuf` array + a write port + a position-addressed read; cut preload to one line. ~80 lines net.
- **Create** `fpga/sim/dcfifo_stub.sv` — sim-only behavioral dual-clock show-ahead FIFO so the (still-instantiated) audio `dcfifo` elaborates under iverilog. Functionally inert for the scanout test (audio is not checked).
- **Create** `fpga/sim/tb_scanout_linebuf.sv` — the datapath testbench. Instantiates `openbor_video_timing` + `openbor_video_reader` + a behavioral DDR holding a seeded framebuffer + control word. Two checks: (1) **pixel-exact** scanout across several frames; (2) **underflow-robustness** — starve one line's fetch and assert only that line differs while the *next* line stays pixel-exact (no cumulative drift).
- **No change** to `fpga/rtl/openbor_video_top.sv` (the reader's port list is unchanged — `hcol` is internal, no new ports).

---

## Task 1: Datapath testbench + dcfifo sim stub (TDD — capture the bug first)

The pixel-exact test passes against the *current* FIFO reader (regression guard). The underflow test **fails** against the current reader (it demonstrates the cumulative-scroll bug). After Task 2 both pass.

**Files:**
- Create: `fpga/sim/dcfifo_stub.sv`
- Create: `fpga/sim/tb_scanout_linebuf.sv`

- [ ] **Step 1: Write the dcfifo sim stub**

Create `fpga/sim/dcfifo_stub.sv`. A minimal behavioral show-ahead dual-clock FIFO covering the params/ports the reader uses. It only needs to elaborate and not deadlock — the scanout tb does not assert on audio.

```systemverilog
// dcfifo_stub.sv — sim-only behavioral dual-clock show-ahead FIFO.
// Enough to elaborate openbor_video_reader.sv (its audio FIFO) under iverilog;
// Icarus has no Altera megafunctions. NOT cycle-accurate to dcfifo's sync
// pipeline — the scanout tb does not check audio, so functional FIFO is enough.
`default_nettype none
module dcfifo #(
    parameter intended_device_family = "Cyclone V",
    parameter lpm_numwords = 256,
    parameter lpm_showahead = "ON",
    parameter lpm_type = "dcfifo",
    parameter lpm_width = 64,
    parameter lpm_widthu = 8,
    parameter overflow_checking = "ON",
    parameter rdsync_delaypipe = 4,
    parameter underflow_checking = "ON",
    parameter use_eab = "ON",
    parameter wrsync_delaypipe = 4
) (
    input  wire                  aclr,
    input  wire [lpm_width-1:0]  data,
    input  wire                  rdclk,
    input  wire                  rdreq,
    input  wire                  wrclk,
    input  wire                  wrreq,
    output wire [lpm_width-1:0]  q,
    output wire                  rdempty,
    output wire                  wrfull,
    output wire [1:0]            eccstatus,
    output wire                  rdfull,
    output wire [lpm_widthu-1:0] rdusedw,
    output wire                  wrempty,
    output wire [lpm_widthu-1:0] wrusedw
);
    localparam DEPTH = (1 << lpm_widthu);
    reg [lpm_width-1:0] mem [0:DEPTH-1];
    integer wr_ptr = 0, rd_ptr = 0, count = 0;

    // Single-domain behavioral model (rdclk==wrclk in our tb). Good enough:
    // the scanout path under test does not depend on the audio FIFO.
    always @(posedge wrclk or posedge aclr) begin
        if (aclr) begin wr_ptr <= 0; rd_ptr <= 0; count <= 0; end
        else begin
            if (wrreq && count < DEPTH) begin
                mem[wr_ptr] <= data;
                wr_ptr <= (wr_ptr + 1) % DEPTH;
                count  <= count + (rdreq && count>0 ? 0 : 1);
            end
            if (rdreq && count > 0 && !(wrreq && count < DEPTH)) begin
                rd_ptr <= (rd_ptr + 1) % DEPTH;
                count  <= count - 1;
            end else if (rdreq && count > 0 && wrreq && count < DEPTH) begin
                rd_ptr <= (rd_ptr + 1) % DEPTH;
            end
        end
    end
    assign q        = mem[rd_ptr];
    assign rdempty  = (count == 0);
    assign wrfull   = (count >= DEPTH);
    assign rdfull   = (count >= DEPTH);
    assign wrempty  = (count == 0);
    assign rdusedw  = count[lpm_widthu-1:0];
    assign wrusedw  = count[lpm_widthu-1:0];
    assign eccstatus= 2'b00;
endmodule
`default_nettype wire
```

- [ ] **Step 2: Write the scanout testbench**

Create `fpga/sim/tb_scanout_linebuf.sv`. It instantiates the real timing generator and the real reader, drives a two-clock environment (`clk_vid` + `ddr_clk`), seeds a framebuffer + control word in a behavioral DDR, then samples `r_out/g_out/b_out`.

Key correctness details baked in:
- **Framebuffer pattern** `fb[y][x] = 16'((y<<8) | x)` (RGB565 bits, distinct per pixel) seeded into BUF0 at qword window base `0x8` (= `BUF0_ADDR - CTRL_ADDR`), 80 qwords/line, 4 px/qword little-endian within the 64-bit word.
- **Expected decode** mirrors the RTL: `dec_r={p[15:11],p[15:13]}`, `dec_g={p[10:5],p[10:9]}`, `dec_b={p[4:0],p[4:2]}`.
- **1-`ce_pix` output latency:** `r_out` is registered at `ce_pix` (true for both old and new readers). The tb shadows this with a 1-deep `(vcount,hcount,valid)` pipeline taken from the timing generator, and compares the *now-visible* `r_out` against `fb` for the (vcount,hcount) that was active on the **previous** `ce_pix`. This makes the comparison exact regardless of the fixed pipeline delay.
- **Frame trigger:** the reader first syncs (captures the stale control-word frame counter without displaying), so the tb bumps the control-word frame counter (and toggles nothing else — keep `active_buffer=0`) to make a new frame appear, then waits for `frame_ready`.

```systemverilog
// tb_scanout_linebuf.sv — datapath sim for the position-addressed line-buffer
// scanout in openbor_video_reader.sv. Two checks:
//   PIXEL-EXACT : every active pixel out == fb[vcount][hcount] across N frames.
//   UNDERFLOW   : starve ONE line's DDR fetch; assert only that line may differ
//                 and the NEXT line is pixel-exact (no cumulative scroll).
// Real proof of HW contention robustness is on silicon (see spec section 6);
// this nails the datapath + the no-drift invariant.
`timescale 1ns/1ps
`default_nettype none
module tb_scanout_linebuf;
  // ---- clocks: clk_vid (pixel) ~53MHz, ddr_clk (clk_sys) faster ~98MHz ----
  reg clk_vid=0;  always #9 clk_vid=~clk_vid;     // ~55.6 MHz
  reg ddr_clk=0;  always #5 ddr_clk=~ddr_clk;     // 100 MHz
  reg reset=1;

  // ce_pix: 1-in-8 of clk_vid (slow enable, like H40 timing)
  reg [2:0] ce_div=0; reg ce_pix=0;
  always @(posedge clk_vid) begin ce_div<=ce_div+3'd1; ce_pix<=(ce_div==3'd0); end

  // ---- timing generator (same module the core uses) ----
  wire t_hsync,t_vsync,t_hblank,t_vblank,t_de,t_nf,t_nl;
  wire [9:0] t_hcount; wire [8:0] t_vcount;
  openbor_video_timing timing(
    .clk(clk_vid), .ce_pix(ce_pix), .reset(reset),
    .h_adj(5'sd0), .v_adj(4'sd0),
    .hsync(t_hsync), .vsync(t_vsync), .hblank(t_hblank), .vblank(t_vblank),
    .de(t_de), .hcount(t_hcount), .vcount(t_vcount),
    .new_frame(t_nf), .new_line(t_nl));

  // ---- behavioral DDR (single ddr_clk domain) with a seeded framebuffer ----
  localparam [28:0] WBASE = 29'h07400000;   // = CTRL_ADDR ; mem idx = addr - WBASE
  localparam        MEMQW = 32'h20000;       // 128K qwords (covers buffers)
  reg [63:0] mem [0:MEMQW-1];
  // DDR master wires from the reader
  wire [7:0]  d_burst; wire [28:0] d_addr; wire d_rd; wire [63:0] d_din;
  wire [7:0]  d_be;    wire d_we;
  reg         d_busy=0; reg d_dready=0; reg [63:0] d_dout=0;

  // burst engine: accept rd when not busy, stream d_burst beats incrementing addr.
  reg [7:0] rbeats=0; reg [28:0] raddr=0; reg [2:0] rlat=0;
  reg       starve=0;            // when 1, hold off beat delivery (underflow inject)
  integer   k;
  always @(posedge ddr_clk) begin
    d_dready <= 1'b0;
    if (reset) begin rbeats<=0; rlat<=0; d_busy<=0; end
    else begin
      d_busy <= (rbeats!=0) || (rlat!=0) || starve;
      if (rlat!=0) rlat<=rlat-3'd1;
      else if (rbeats!=0) begin
        if (!starve) begin
          d_dout<=mem[raddr-WBASE]; d_dready<=1'b1;
          raddr<=raddr+29'd1; rbeats<=rbeats-8'd1;
        end
      end else begin
        if (d_rd) begin rbeats<=d_burst; raddr<=d_addr; rlat<=3'd2; end
        else if (d_we) for(k=0;k<8;k=k+1) if(d_be[k]) mem[d_addr-WBASE][k*8+:8]<=d_din[k*8+:8];
      end
    end
  end

  // ---- DUT: the reader ----
  wire [7:0] r_out,g_out,b_out; wire frame_ready;
  openbor_video_reader dut(
    .ddr_clk(ddr_clk), .ddr_busy(d_busy), .ddr_burstcnt(d_burst), .ddr_addr(d_addr),
    .ddr_dout(d_dout), .ddr_dout_ready(d_dready), .ddr_rd(d_rd), .ddr_din(d_din),
    .ddr_be(d_be), .ddr_we(d_we),
    .clk_vid(clk_vid), .ce_pix(ce_pix), .reset(reset),
    .de(t_de), .hblank(t_hblank), .vblank(t_vblank), .new_frame(t_nf),
    .new_line(t_nl), .vcount(t_vcount),
    .ioctl_download(1'b0), .ioctl_wr(1'b0), .ioctl_addr(27'd0), .ioctl_dout(8'd0),
    .ioctl_wait(),
    .joystick_0(32'd0), .joystick_1(32'd0), .joystick_2(32'd0), .joystick_3(32'd0),
    .joystick_l_analog_0(16'd0),
    .r_out(r_out), .g_out(g_out), .b_out(b_out),
    .clk_audio(clk_vid), .audio_l(), .audio_r(),
    .enable(1'b1), .frame_ready(frame_ready));

  // ---- framebuffer model + expected decode ----
  function [15:0] fbpix(input integer y, input integer x);
    fbpix = 16'(((y<<8) | x) & 16'hFFFF);
  endfunction
  task seed_buf0;  // BUF0 at qword window 0x8, 80 qw/line, 4 px/qw little-endian
    integer y,x,qw,lane; begin
      for (y=0;y<240;y=y+1) for (x=0;x<320;x=x+1) begin
        qw   = 32'h8 + y*80 + (x>>2);
        lane = x & 3;
        mem[qw][lane*16 +: 16] = fbpix(y,x);
      end
    end
  endtask
  function [7:0] exp_r(input [15:0] p); exp_r={p[15:11],p[15:13]}; endfunction
  function [7:0] exp_g(input [15:0] p); exp_g={p[10:5], p[10:9]};  endfunction
  function [7:0] exp_b(input [15:0] p); exp_b={p[4:0],  p[4:2]};   endfunction

  // ---- 1-ce_pix pipeline shadow of the timing, to compare r_out exactly ----
  reg        pv_valid=0; reg [8:0] pv_y=0; reg [9:0] pv_x=0;
  integer    px_errs=0, px_checked=0;
  integer    line_err [0:239];           // per-display-line mismatch count
  integer    chk_enable=0;               // gate checking to a steady frame
  always @(posedge clk_vid) if (ce_pix) begin
    // compare the value now visible in r_out against the pixel active LAST ce_pix
    if (chk_enable && pv_valid && frame_ready) begin
      px_checked = px_checked + 1;
      if (r_out!==exp_r(fbpix(pv_y,pv_x)) ||
          g_out!==exp_g(fbpix(pv_y,pv_x)) ||
          b_out!==exp_b(fbpix(pv_y,pv_x))) begin
        px_errs = px_errs + 1;
        if (pv_y<240) line_err[pv_y] = line_err[pv_y] + 1;
      end
    end
    // latch this ce_pix's active position for next-cycle comparison
    pv_valid <= t_de;  pv_y <= t_vcount;  pv_x <= t_hcount;
  end

  // ---- control word helpers ----
  task set_ctrl(input [29:0] fc, input ab);
    begin mem[0] = {32'd0, fc, 1'b0, ab}; end   // [31:2]=frame_counter,[0]=active_buffer
  endtask

  integer f, ln;
  initial begin
    for (f=0;f<MEMQW;f=f+1) mem[f]=64'd0;
    for (ln=0;ln<240;ln=ln+1) line_err[ln]=0;
    seed_buf0();
    set_ctrl(30'd0, 1'b0);                 // initial counter (reader will sync to it)
    repeat(20) @(posedge ddr_clk); reset<=0;

    // let the reader sync to the stale counter
    repeat(2000) @(posedge clk_vid);
    // publish a NEW frame (bump counter) on BUF0
    set_ctrl(30'd1, 1'b0);
    // wait for frame_ready
    f=0; while(!frame_ready && f<200000) begin @(posedge clk_vid); f=f+1; end
    if(!frame_ready) begin $display("RESULT: FAIL (frame never ready)"); $finish; end

    // ============ PIXEL-EXACT: check across 3 full frames ============
    // re-publish a fresh frame each scan so the reader keeps displaying.
    chk_enable = 1;
    repeat(3) begin
      // hold one frame for a full vertical scan (262 lines * 420 px * 8 clk/ce ≈ plenty)
      repeat(262*420*8) @(posedge clk_vid);
      set_ctrl(mem[0][31:2]+30'd1, 1'b0);   // next frame counter, same buffer/content
    end
    chk_enable = 0;
    $display("=== PIXEL-EXACT: checked=%0d errs=%0d ===", px_checked, px_errs);

    // ============ UNDERFLOW: starve ONE line's fetch =================
    // Pick line L=100. Raise `starve` while the reader fetches line 100 so its
    // back buffer is not filled before the display reaches line 100. Assert:
    // line 100 MAY differ, but line 101 is pixel-exact (no cumulative drift).
    // (With the old FIFO reader, the underflow shifts ALL later pixels -> many
    //  lines wrong -> this check fails, capturing the bug.)
    for (ln=0;ln<240;ln=ln+1) line_err[ln]=0;
    px_errs=0; px_checked=0;
    set_ctrl(mem[0][31:2]+30'd1, 1'b0);
    chk_enable=1;
    // wait until the display is a few lines above L, then starve through L's fetch
    while (!(t_vcount==9'd96 && t_hblank)) @(posedge clk_vid);
    starve<=1'b1;
    repeat(420*8) @(posedge clk_vid);     // starve ~ one full line time
    starve<=1'b0;
    // finish the frame
    repeat(262*420*8) @(posedge clk_vid);
    chk_enable=0;

    $display("=== UNDERFLOW: line[100] errs=%0d  line[101] errs=%0d  line[150] errs=%0d ===",
             line_err[100], line_err[101], line_err[150]);

    // Verdict: line 101 and a far-downstream line 150 must be pixel-exact
    // (no cumulative drift). Line 100 itself is allowed to be corrupted.
    if (px_errs_total_ok())
      $display("RESULT: PASS");
    else
      $display("RESULT: FAIL");
    $finish;
  end

  // PIXEL-EXACT phase recorded px_errs into line_err during chk_enable; the
  // final verdict combines: (a) pixel-exact phase had zero errs (captured below),
  // (b) underflow phase: lines 101 and 150 clean.
  reg pe_clean=0;
  // capture pixel-exact cleanliness at the moment we flip chk_enable off the 1st time
  // (px_errs is reused; snapshot via a flag the initial block sets)
  function automatic px_errs_total_ok;
    begin px_errs_total_ok = (line_err[101]==0) && (line_err[150]==0) && pe_snapshot_ok; end
  endfunction
  reg pe_snapshot_ok=0;
  // snapshot pixel-exact result: set in initial right after the pixel-exact $display
  // (added inline there in the real file — see Step 3 note).

  initial begin #500000000 $display("RESULT: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire
```

> **Step 3 note (engineer):** the snapshot wiring above is split for readability. In the real file, replace the `pe_snapshot_ok` comment with a direct assignment right after the PIXEL-EXACT `$display`: `pe_snapshot_ok = (px_errs==0 && px_checked>200000);` and delete the unused `pe_clean` reg. The `px_errs_total_ok` function then reads that snapshot plus the underflow line counters. Keep the verdict semantics: **PASS iff** pixel-exact phase had zero mismatches over a full frame's worth of pixels AND underflow lines 101 & 150 are clean.

- [ ] **Step 3: Compile + run against the CURRENT (FIFO) reader**

Run:
```bash
cd fpga/sim
iverilog -g2012 -o scanout.vvp tb_scanout_linebuf.sv \
  ../rtl/openbor_video_reader.sv ../rtl/openbor_video_timing.sv dcfifo_stub.sv
vvp scanout.vvp
```
Expected against the current reader:
- `PIXEL-EXACT: checked=<large> errs=0` — the FIFO reader IS pixel-exact with no contention (regression guard passes).
- `UNDERFLOW: line[100] errs=<n>  line[101] errs=<m>  line[150] errs=<k>` with **m>0 and/or k>0** — the FIFO underflow shifts later lines → **`RESULT: FAIL`**.

This FAIL is the captured bug. If the pixel-exact phase shows errs≠0 instead, the tb's pipeline offset is wrong — fix the tb (not the RTL) until pixel-exact is clean against the current reader, then confirm underflow fails.

- [ ] **Step 4: Commit the test + stub**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
git add fpga/sim/tb_scanout_linebuf.sv fpga/sim/dcfifo_stub.sv
git commit -m "test(#34): line-buffer scanout datapath tb — pixel-exact passes, underflow scroll FAILS (captures the bug)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Replace the FIFO scanout with position-addressed line buffers

Make the underflow test pass while keeping the pixel-exact test green. Five edits to `fpga/rtl/openbor_video_reader.sv`, all in the video path.

**Files:**
- Modify: `fpga/rtl/openbor_video_reader.sv`

- [ ] **Step 1: Add the line-buffer array + write-port registers; drop the FIFO write signals**

Replace the FIFO write-signal block (currently lines ~285-288):
```systemverilog
// -- FIFO write signals -----------------------------------------------
reg         fifo_wr;
reg  [63:0] fifo_wr_data;
wire        fifo_full;
```
with the line-buffer storage + write-port regs:
```systemverilog
// -- Line buffers (position-addressed ping-pong scanout) --------------
// Two display lines of RGB565, stored as 80 x 64-bit words each (4 px/word),
// addressed by line parity: line L always lives in buffer L%2. Write port is
// ddr_clk (fill), read port is clk_vid (scanout) -> true dual-clock BRAM (M10K),
// which carries the data CDC. Index = {buf(1), word(7)} -> 0..255.
reg  [63:0] linebuf [0:255];
reg         lb_we;
reg  [7:0]  lb_waddr;
reg  [63:0] lb_wdata;
```

- [ ] **Step 2: Route beat capture into the line-buffer write port**

In the main `always @(posedge ddr_clk)`:

(a) In the per-cycle defaults near the top of the `else` branch (currently `fifo_wr <= 1'b0;` at ~line 358), change to:
```systemverilog
        lb_we <= 1'b0;
```

(b) In the beat-capture block (currently lines ~369-374):
```systemverilog
        // Beat capture (runs in parallel with state machine)
        if (state == ST_WAIT_LINE && ddr_dout_ready) begin
            fifo_wr      <= 1'b1;
            fifo_wr_data <= ddr_dout;
            beat_count   <= beat_count + 7'd1;
            timeout_cnt  <= 20'd0;
        end
```
replace with a write into the back buffer (`display_line[0]`) at the running word index (`beat_count`):
```systemverilog
        // Beat capture -> back line buffer. Line L fills buffer L%2 at word=beat.
        // (display_line is the line being fetched; it increments in ST_LINE_DONE.)
        if (state == ST_WAIT_LINE && ddr_dout_ready) begin
            lb_we      <= 1'b1;
            lb_waddr   <= {display_line[0], beat_count};
            lb_wdata   <= ddr_dout;
            beat_count <= beat_count + 7'd1;
            timeout_cnt<= 20'd0;
        end
```

(c) In the reset block, replace the FIFO write resets (currently lines ~335-336):
```systemverilog
        fifo_wr            <= 1'b0;
        fifo_wr_data       <= 64'd0;
```
with:
```systemverilog
        lb_we              <= 1'b0;
        lb_waddr           <= 8'd0;
        lb_wdata           <= 64'd0;
```
(Leave `fifo_aclr_cnt` and its decrement/gate intact — it now just provides a few-cycle settle before the first line read; harmless and keeps the FSM timing unchanged.)

- [ ] **Step 3: Cut the preload to one line (parity ping-pong needs fill exactly 1 ahead)**

In `ST_LINE_DONE` (currently lines ~616-631):
```systemverilog
            ST_LINE_DONE: begin
                display_line <= display_line + 9'd1;

                if (display_line == V_ACTIVE - 9'd1) begin
                    first_frame_loaded <= 1'b1;
                    frame_ready_reg    <= 1'b1;
                    preloading         <= 1'b0;
                    state              <= ST_IDLE;
                end
                else if (preloading && display_line < 9'd1)
                    state <= ST_READ_LINE;
                else begin
                    preloading <= 1'b0;
                    state      <= ST_WAIT_DISPLAY;
                end
            end
```
remove the two-line preload branch so preload loads only line 0:
```systemverilog
            ST_LINE_DONE: begin
                display_line <= display_line + 9'd1;

                if (display_line == V_ACTIVE - 9'd1) begin
                    first_frame_loaded <= 1'b1;
                    frame_ready_reg    <= 1'b1;
                    preloading         <= 1'b0;
                    state              <= ST_IDLE;
                end
                else begin
                    // Preload exactly line 0; thereafter each new_line in
                    // ST_WAIT_DISPLAY fetches line N+1 while line N is displayed
                    // (one full line of fill slack, 2-buffer ping-pong).
                    preloading <= 1'b0;
                    state      <= ST_WAIT_DISPLAY;
                end
            end
```

- [ ] **Step 4: Replace the dcfifo + pixel walker with the line-buffer read port**

Delete the entire video `line_fifo` dcfifo block (currently lines ~732-766: the `wire [63:0] fifo_rd_data; ... reg fifo_rd;` declarations through the `) line_fifo (...);` instance) **and** the pixel-output block (currently lines ~768-848: the `reg [63:0] pixel_word; ...` declarations through the end of its `always @(posedge clk_vid)`).

Replace both with the position-addressed read:
```systemverilog
// -- Line-buffer read port + position-addressed pixel output ----------
//
// Read side is anchored to DISPLAY POSITION, not buffer occupancy:
//   * hcol counts output pixels 0..319, reset at new_line, advanced on ce_pix
//     within de. word group = hcol[8:2] (0..79), sub-pixel lane = hcol[1:0].
//   * the buffer for the current display line = vcount[0] (line L -> buf L%2),
//     which matches the fill (line L written to buf L%2). No swap toggle needed.
//   * BRAM read has 1 clk_vid latency; ce_pix is ~1-in-8, so lb_q is always
//     settled to word(hcol) before the next ce_pix.
// An underflow leaves the current buffer stale for ONE line; the next line
// re-anchors (vcount advances, reads the freshly-filled buffer). No drift.
reg  [8:0]  hcol;
reg  [63:0] lb_q;

always @(posedge clk_vid)
    lb_q <= linebuf[{vcount[0], hcol[8:2]}];

wire [15:0] cur_pix = lb_q[{hcol[1:0], 4'b0000} +: 16];
wire  [7:0] dec_r = {cur_pix[15:11], cur_pix[15:13]};
wire  [7:0] dec_g = {cur_pix[10:5],  cur_pix[10:9]};
wire  [7:0] dec_b = {cur_pix[4:0],   cur_pix[4:2]};

always @(posedge clk_vid) begin
    if (reset_vid) begin
        hcol  <= 9'd0;
        r_out <= 8'd0;
        g_out <= 8'd0;
        b_out <= 8'd0;
    end
    else if (ce_pix) begin
        // Output the pixel for the current hcol (lb_q already settled).
        if (de && frame_ready_vid) begin
            r_out <= dec_r;
            g_out <= dec_g;
            b_out <= dec_b;
        end
        else begin
            r_out <= 8'd0;
            g_out <= 8'd0;
            b_out <= 8'd0;
        end

        // Advance the position anchor.
        if (new_line)
            hcol <= 9'd0;
        else if (de)
            hcol <= (hcol == 9'd319) ? hcol : (hcol + 9'd1);
    end
end

// -- Dedicated line-buffer write port (ddr_clk) -----------------------
always @(posedge ddr_clk)
    if (lb_we) linebuf[lb_waddr] <= lb_wdata;
```

> The `fifo_aclr` *wire* (fed only the deleted dcfifo) is now unused — delete its declaration (`wire fifo_aclr = reset | fifo_aclr_ddr_active;`, ~line 311). Keep `fifo_aclr_cnt` and `fifo_aclr_ddr_active` (still used to gate `ST_READ_LINE`).

- [ ] **Step 5: Recompile + run — both checks must pass**

Run:
```bash
cd fpga/sim
iverilog -g2012 -o scanout.vvp tb_scanout_linebuf.sv \
  ../rtl/openbor_video_reader.sv ../rtl/openbor_video_timing.sv dcfifo_stub.sv
vvp scanout.vvp
```
Expected:
- `PIXEL-EXACT: checked=<large> errs=0`
- `UNDERFLOW: line[100] errs=<maybe>0  line[101] errs=0  line[150] errs=0`
- `RESULT: PASS`

If pixel-exact regresses, the read pipeline/anchor is off — re-check the `hcol`/`vcount[0]` indexing and the `new_line` reset timing against the timing-generator facts above. If underflow still fails (line 101/150 dirty), the fill is not exactly 1 line ahead — re-check Step 3 (preload) and that `ST_WAIT_DISPLAY` fetches on `!vblank_ddr` new_lines.

- [ ] **Step 6: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
git add fpga/rtl/openbor_video_reader.sv
git commit -m "fix(#34): position-addressed line-buffer scanout — kills SDRAM-path scroll at the root

Replace the whole-frame occupancy-coupled dcfifo reader with a 2-buffer
ping-pong line buffer indexed by display position (line L -> buf L%2). An
f2h underflow now degrades to a single stale line instead of a cumulative
vertical scroll. Preload cut to one line for the 2-buffer fill-ahead invariant.
Datapath pixel-exact + underflow no-drift sims green.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Regression — orthogonal paths unchanged

Prove the blitter/arbiter/reader-burst system test still passes (the scanout change must not touch the shared f2h master behavior the blitter relies on).

**Files:** none modified (verification only).

- [ ] **Step 1: Run the system testbench**

Run:
```bash
cd fpga/sim
iverilog -g2012 -o sys_re.vvp tb_blitter_system.sv \
  ../rtl/ddr_blitter_arb.sv ../rtl/blitter_top.sv ../rtl/sdram_src_arb.sv \
  ../rtl/sdram_psx.sv sdram_chip_model.sv
vvp sys_re.vvp
```
Expected: `RESULT: PASS` (PHASE1/2/3 all PASS), unchanged from before this branch's scanout work.

> If the exact source list differs, mirror the command already recorded in this repo's CI/sim notes for `tb_blitter_system` — do not add `openbor_video_reader.sv` here (this tb uses a *fake* reader master, per its header).

- [ ] **Step 2: Confirm no other tb references the removed FIFO signals**

Run:
```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
grep -rn 'line_fifo\|pixel_word\|pixel_sub\|fifo_wr_data' fpga/sim || echo "clean: no sim references the removed video FIFO internals"
```
Expected: `clean: ...` (the scanout tb uses only ports, not internals).

---

## Task 4: Update spec status, dataflow doc, and memory

**Files:**
- Modify: `docs/superpowers/specs/2026-06-17-line-buffered-scanout-design.md`
- Modify: `docs/frame-dataflow.md`
- Modify: `/Users/gmcnaught/.claude/projects/-Users-gmcnaught-MisterFPGA-Projects-solarus-mister/memory/fpga-sdram-source-f2h-scanout-contention.md` and its `MEMORY.md` index line

- [ ] **Step 1: Flip the spec status to implemented (sim)**

In the spec header, change:
```markdown
**Status:** approved direction (2026-06-17); ready to turn into an implementation plan.
```
to:
```markdown
**Status:** IMPLEMENTED in RTL + datapath sims green (2026-06-17). HW validation pending (DDR3 no-regression, then SDRAM-source stable). Plan: docs/superpowers/plans/2026-06-17-line-buffered-scanout.md
```

- [ ] **Step 2: Note the scanout change in the dataflow doc**

Read `docs/frame-dataflow.md`, then add a short paragraph under the scanout/read section describing the position-addressed ping-pong line buffer (line L -> buffer L%2, fill exactly 1 ahead, underflow = single stale line). Match the doc's existing prose style; do not restructure it.

- [ ] **Step 3: Update the memory file + index**

Append to `memory/fpga-sdram-source-f2h-scanout-contention.md` a line recording that #34 root fix (line-buffered scanout) is implemented in RTL with pixel-exact + underflow-no-drift sims green; HW validation pending. Update the matching one-liner in `memory/MEMORY.md`. Keep both to one line of new content each; link `[[fpga-jtframe-reference]]`.

- [ ] **Step 4: Commit docs + memory**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
git add docs/superpowers/specs/2026-06-17-line-buffered-scanout-design.md docs/frame-dataflow.md
git commit -m "docs(#34): line-buffered scanout implemented in RTL — spec/dataflow updated

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```
(The memory dir is outside the repo — write those files but do not git-add them.)

---

## Task 5: Build RBF + HW validation (manual — gated, not auto-run)

**This task runs on real hardware and is the real proof per spec §6. Do NOT run it as part of automated execution — flag to the user for a hands-on session.**

- [ ] **Step 1: Build the RBF in CI**

```bash
gh workflow run build-rbf.yml -f runner=linux
gh run watch
```
Note: the repo's `allowed_actions` must stay `all` (per the build-CI memory). Download the artifact when green:
```bash
gh run download <run-id> -n solarus-rbf
```

- [ ] **Step 2: Deploy + DDR3-path no-regression**

Deploy the RBF + engine, boot a quest on the **DDR3** path (default), and confirm the image is stable and correct (no regression vs the proven path). Capture the analog output (camera) — counters lie about video.

- [ ] **Step 3: SDRAM-source path stability (the win)**

Boot with `SOLARUS_SDRAM_SRC=1`, run a quest with a moving/scrolling scene. Confirm the image is **stable — no vertical scroll**. This is the success criterion the whole change targets.

- [ ] **Step 4: Tune the write-throttle down**

With the line buffer carrying robustness, lower `SOLARUS_BLT_THROTTLE` toward 0 and confirm stability holds (the throttle is now a complementary lever, not load-bearing). Record the final value.

- [ ] **Step 5: (Only if marginal) add the writer-gated-to-display-window fallback (spec §5)**

If the SDRAM path is still marginal on HW, gate the blitter's f2h writes out of the line-fetch/HBlank window (jtframe `hcnt<hlim` discipline). Implement only if needed; otherwise document that it was not required.

- [ ] **Step 6: Record HW validation outcome**

Update the memory file (`fpga-sdram-source-f2h-scanout-contention.md`) with the HW result (stable/scroll-free on the SDRAM path, DDR3 no-regression, final throttle value) and flip the spec status to HW-VALIDATED.

---

## Self-review notes (already applied)

- **Spec §3/§4 (ping-pong, position-addressed, line-parity, fill-side reuse):** Task 2 Steps 1-4 + the preload cut (Step 3) implement all of it; parity indexing removes the §4.4 swap toggle (documented decision: simpler, no CDC).
- **Spec §4.5 (remove line_fifo + pixel walker; keep frame_ready/preloading/stale semantics):** Task 2 Step 4 deletes exactly those; `frame_ready_reg`, `preloading`, `stale_vblank_count`, `fifo_aclr_cnt` settle all preserved.
- **Spec §6 (simulatable datapath + underflow no-drift; HW is real proof):** Task 1 builds both sims; Task 5 is the HW gate, explicitly manual.
- **Spec §7 risk (BRAM/CDC):** dual-clock `linebuf` with separate ddr_clk write / clk_vid read processes infers M10K; data CDC via the BRAM; the only shared control (`vcount`) is already clk_vid. Watch the fit log for M10K + timing in Task 5 Step 1.
- **Spec §2 non-goal (orthogonal paths untouched):** Task 3 regression guards the blitter/arbiter; Task 1 confirms no sim touches reader internals.
- **Type/name consistency:** `linebuf`, `lb_we/lb_waddr/lb_wdata`, `lb_q`, `hcol` used identically in Task 1's expectations and Task 2's edits; framebuffer decode (`dec_r/g/b`) matches the RTL bit-slices in both the tb and the module.
