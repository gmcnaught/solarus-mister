// tb_snap_gate.sv — [ring-dbuf tear-guard] Task 4 gate: at most ONE WORK->DDR3
// snapshot START per reader vblank window.
//
// Context: Tasks 1-3 gave the command FSM two banks, so the host can build frame
// S+1's ring while the fabric composites frame S -- publish times are now
// composite-COMPLETION times, which can compress (a slow frame followed by a
// fast one lets two snapshots complete inside one scan window). The second
// snapshot would overwrite the DDR3 buffer the reader is still scanning: a
// visible tear the host's ~60fps SUBMISSION cap cannot see. blitter_top.sv's
// S_SNAP_GATE closes this by holding a second snapshot until the reader's own
// vblank tick opens a fresh window, counting each such deferral in
// snap_deferred_cnt (published C_STATUS[31:24]).
//
// Two things this TB must prove -- and the SECOND is the one that matters most,
// because it is the thing that protects against recreating the retired
// S_SNAP_WAIT vblank-gate disaster (PR #138: that gate ran on EVERY frame and
// cost ~16.7ms/frame in the critical path):
//
//   1. GATE FIRES WHEN IT MUST. Two 1-command frames submitted back-to-back
//      (BANK_EN=1, both pending before either completes) with vsync held
//      STATIC: the first snapshot fires immediately (no vblank tick has
//      happened yet, but the sentinel reset lets the very first-ever snapshot
//      through free). The second must NOT start until the TB explicitly pulses
//      a vsync edge; C_STATUS[31:24] must then read exactly 1.
//
//   2. GATE IS A NO-OP IN STEADY STATE. With vsync ticking normally and two
//      frames spaced well apart (mirroring the real host's pacing), the cycle
//      count from p_blit_done to snap_start must be IDENTICAL to a control
//      measurement (the first, definitely-ungated snapshot from part 1) -- a
//      real cycle-count comparison, not an assertion-free comment -- and
//      C_STATUS[31:24] must stay 0 throughout.
//
// Harness: copied from tb_ring_dbuf.sv's DDR-model + blitter_top instantiation
// preamble (Task 3's TB; itself copied from tb_tilemap.sv), same getpx()/
// set_ctrl()/wr_fill()/wait_done()/ckcolor() helpers. The free-running vs
// toggle mirrors tb_ring_dbuf's (the "copy the vs toggling block from
// tb_scan_qworddup.sv" instruction in the brief refers to a TB retired with the
// SDRAM scanout path; tb_ring_dbuf's own block is the current in-repo
// equivalent and is reused verbatim, gated so part 1 can also hold vs
// perfectly static). Part 1 additionally drives a single controlled vsync
// pulse through the SAME vs_sync resolved-stage synchronizer blitter_top
// already has (vs -> vs_sync[2:0] -> vs_rise) -- no second edge detector is
// added anywhere in this TB or in the RTL it exercises.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
module tb_snap_gate;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h8000;   // ctrl/ring/source-heap window
  localparam [31:0] BLTCTRL0 = `BLTCTRL_QW - WBASE;                 // 0x200000
  localparam [31:0] RING0    = `RING_QW    - WBASE;                 // 0x200008
  localparam [31:0] BLTCTRL1 = BLTCTRL0 + `BANK_QW_STRIDE;          // 0x210000
  localparam [31:0] RING1    = RING0    + `BANK_QW_STRIDE;          // 0x210008

  reg clk=0, rst=1; always #5 clk=~clk;

  // ---- vsync stimulus -------------------------------------------------------
  // vs is driven by exactly ONE always block below (auto free-run OR a manual
  // one-shot pulse request), so there is never more than one procedural driver.
  reg vs=0;
  reg vs_auto=1'b0;        // part 2: free-running toggle (mirrors tb_ring_dbuf's vsc block)
  reg vs_pulse_req=1'b0;   // part 1: one-shot manual pulse (held vsync otherwise)
  integer vsc=0;
  always @(posedge clk) begin
    if (vs_auto) begin
      vsc <= vsc + 1;
      if (vsc >= 256) begin vs <= ~vs; vsc <= 0; end
    end else begin
      vs <= vs_pulse_req;
    end
  end
  task pulse_vsync; begin
    // One rising edge into the 3-FF vs_sync chain (vs_rise = ~vs_sync[2] &
    // vs_sync[1], the EXISTING resolved-stage detector) -- generous margin
    // either side so exactly one vs_rise pulse (and one vsync_cnt increment)
    // is guaranteed regardless of where in its cycle vs_sync currently sits.
    vs_pulse_req <= 1'b1; repeat(6) @(posedge clk);
    vs_pulse_req <= 1'b0; repeat(6) @(posedge clk);
  end endtask

  wire [31:0] bt_addr; wire b_rd, b_we; wire [63:0] b_din; wire [7:0] b_be; wire bt_idle;
  wire [7:0]  bt_burst;
  reg  d_dready; reg [63:0] d_dout;

  // ---- P_SRC: never asserts (OP_FILL's is_fill path skips the source prefetch). ----
  wire [26:0] s_src_addr; wire s_src_rd;

  // on-chip dest framebuffer [FB-in-BRAM]
  wire fb_wr_en; wire [14:0] fb_wr_qw; wire [1:0] fb_wr_lane; wire [15:0] fb_wr_pix;
  wire fb_rd_en; wire [14:0] fb_rd_qw; wire [63:0] fb_rd_qword;
  comp_fbram fbram(.clk(clk),
    .wr_en(fb_wr_en), .wr_qw(fb_wr_qw), .wr_lane(fb_wr_lane), .wr_pix(fb_wr_pix),
    .rd_en(fb_rd_en), .rd_qw(fb_rd_qw), .rd_qword(fb_rd_qword));

  // ---- behavioral DDR (single-beat reads, latency + backpressure) ----
  // (declared BEFORE the blitter_top instantiation below, which wires d_busy
  // into .mem_busy -- matches tb_ring_dbuf.sv's ordering.)
  reg [63:0] mem [0:MEMQW-1];
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat; reg [1:0] bp=0;
  always @(posedge clk) bp <= bp+2'd1;
  wire d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  integer i;

  blitter_top blt(.clk(clk), .rst(rst), .vs(vs),
    .mem_addr(bt_addr), .mem_rd(b_rd), .mem_wr(b_we), .mem_burstcnt(bt_burst),
    .mem_din(b_din), .mem_be(b_be),
    .mem_dout(d_dout), .mem_dout_ready(d_dready), .mem_busy(d_busy),
    .p0_addr(s_src_addr), .p0_rd(s_src_rd), .p0_dout(64'd0), .p0_ok(1'b0),
    .src_sdram_ok(1'b1), .stage_barrier_busy(1'b0),
    .fb_wr_en(fb_wr_en), .fb_wr_qw(fb_wr_qw), .fb_wr_lane(fb_wr_lane), .fb_wr_pix(fb_wr_pix),
    .fb_rd_en(fb_rd_en), .fb_rd_qw(fb_rd_qw), .fb_rd_qword(fb_rd_qword),
    .idle(bt_idle));

  always @(posedge clk) begin
    d_dready <= 1'b0;
    d_dout   <= 64'hDEAD_BEEF_DEAD_BEEF;
    if (rst) begin rbeats<=0; rlat<=0; end
    else begin
      if (rlat != 3'd0) rlat <= rlat - 3'd1;
      else if (rbeats != 8'd0) begin
        if (bp == 2'd2) begin
          d_dout <= mem[raddr-WBASE];
          d_dready <= 1'b1; raddr <= raddr + 29'd1; rbeats <= rbeats - 8'd1;
        end
      end else if (!d_busy) begin
        if (b_rd) begin rbeats<=bt_burst; raddr<=bt_addr[28:0]; rlat<=3'd3; end
        else if (b_we) for(i=0;i<8;i=i+1) if(b_be[i]) mem[(bt_addr[28:0]-WBASE)][i*8 +:8]<=b_din[i*8 +:8];
      end
    end
  end

  function [15:0] getpx(input integer dx, input integer dy);
    integer idx;
    begin
      idx = dy*80 + (dx>>2);
      getpx = ((dx&3)==0)?fbram.bank0[idx]:((dx&3)==1)?fbram.bank1[idx]:
              ((dx&3)==2)?fbram.bank2[idx]:fbram.bank3[idx];
    end
  endfunction

  // ---- ctrl-block writers (per-frame fields only; SUBMIT/DONE are global) ----
  task set_ctrl(input integer ctrl_base, input integer ncmds);
    begin
      mem[ctrl_base+1] = ncmds;   // C_CMDCOUNT
      mem[ctrl_base+2] = 64'd0;   // C_TARGET = BUF0
      mem[ctrl_base+3] = 64'd0;   // C_CLEAR (unused: flags bit0=0, ring has an explicit FILL)
      mem[ctrl_base+4] = 64'd0;   // C_FLAGS = 0
      mem[ctrl_base+7] = 64'd0;   // C_SRCSEL/C_PIPE = 0
    end
  endtask

  // one full-screen OP_FILL(color) + OP_END, 4 qwords/command -- the "1-command
  // frame" the brief asks for.
  task wr_fill(input integer ring_base, input [15:0] color);
    begin
      mem[ring_base+0] = {32'd0, 8'd0, 8'd0, 8'd0, 8'd2};        // op=FILL(2), blend/fmt/flags=0, src_off=0
      mem[ring_base+1] = {16'd240, 16'd320, 16'd0, 16'd0};       // h=240 w=320 src_x=0 stride=0
      mem[ring_base+2] = {16'd0, 16'd0, 16'd0, 16'd0};           // dst_y=0 dst_x=0 _=0 src_y=0
      mem[ring_base+3] = {{16'd0, color}, {8'd0, 8'd0, 16'd0}};  // color, alpha=0, colorkey=0
      mem[ring_base+4] = 64'd1;                                  // op=END(1)
    end
  endtask

  integer to;
  task wait_done(input integer target, input [199:0] tag);
    begin
      to = 0;
      while (mem[BLTCTRL0+5][31:0] !== target[31:0] && to < 2_000_000) begin
        @(posedge clk); to = to + 1;
      end
      if (mem[BLTCTRL0+5][31:0] !== target[31:0])
        $display("  WEDGE %0s: C_DONE never reached %0d (stuck at %0d, to=%0d)",
                 tag, target, mem[BLTCTRL0+5][31:0], to);
      // C_DONE (S_WR_DONE) and C_STATUS (S_WR_STATUS, incl. snap_deferred_cnt in
      // bits[31:24]) are two SEPARATE sequential bus writes -- C_DONE becomes
      // visible in mem[] first. Settle a few extra cycles so callers that then
      // check C_STATUS never race the second write.
      repeat(30) @(posedge clk);
    end
  endtask

  integer to2;
  task wait_state(input [5:0] target, input [199:0] tag);
    begin
      to2 = 0;
      while (blt.state !== target && to2 < 2_000_000) begin
        @(posedge clk); to2 = to2 + 1;
      end
      if (blt.state !== target)
        $display("  WEDGE %0s: state never reached %0d (stuck at %0d, to=%0d)",
                 tag, target, blt.state, to2);
    end
  endtask

  integer errs;
  task ckcolor(input [15:0] exp, input [199:0] tag);
    reg [15:0] got;
    begin
      got = getpx(0,0);
      if (got !== exp) begin
        $display("  MISMATCH %0s: fb(0,0)=%h expected %h", tag, got, exp);
        errs = errs + 1;
      end else
        $display("  ok %0s: fb(0,0)=%h", tag, got);
    end
  endtask

  // ---- p_blit_done -> snap_start cycle-delta instrumentation ----
  // (hierarchical peeks into blt.*, same established pattern as tb_tilemap.sv/
  // tb_spritelist.sv's blt.state/blt.pipe_start references -- simulation-only,
  // not synthesized.)
  integer cyc;
  always @(posedge clk or posedge rst) if (rst) cyc <= 0; else cyc <= cyc + 1;
  reg p_blit_done_q;
  wire p_blit_done_rise = blt.p_blit_done & ~p_blit_done_q;
  always @(posedge clk or posedge rst) if (rst) p_blit_done_q <= 1'b0; else p_blit_done_q <= blt.p_blit_done;
  integer t_pipe_done, t_snap;
  always @(posedge clk) begin
    if (p_blit_done_rise) t_pipe_done <= cyc;
    if (blt.snap_start)   t_snap      <= cyc;
  end

  localparam [15:0] COLOR_A = 16'h5555;   // part1 frame1 (bank1, ungated -- the control)
  localparam [15:0] COLOR_B = 16'hAAAA;   // part1 frame2 (bank0, gated)
  localparam [15:0] COLOR_C = 16'h3333;   // part2 frame3
  localparam [15:0] COLOR_D = 16'h7777;   // part2 frame4

  integer delta_baseline, delta3, delta4;

  initial begin
    errs = 0;
    for (i=0; i<MEMQW; i=i+1) mem[i] = 64'd0;

    repeat(8) @(posedge clk); rst<=0;
    repeat(4) @(posedge clk);

    // ══════════════════════════════════════════════════════════════════════
    // Part 1: gate fires when it must. vs held STATIC throughout (vs_auto=0,
    // vs_pulse_req=0) -- no vblank tick occurs until this test explicitly
    // requests one.
    // ══════════════════════════════════════════════════════════════════════
    // Two 1-command frames, BOTH pending before either composites (mirrors
    // tb_ring_dbuf's frame-collapse setup): seq1->bank1 (parity of done+1=
    // (0+1)&1=1), seq2->bank0 (parity of done+1=(1+1)&1=0).
    set_ctrl(BLTCTRL0, 2); wr_fill(RING0, COLOR_A);
    set_ctrl(BLTCTRL1, 2); wr_fill(RING1, COLOR_B);
    mem[BLTCTRL0+0] = {32'h0000_0001, 32'd2};   // BANK_EN=1, submit=2

    // Frame 1 (bank1): the very first snapshot the fabric ever issues. The
    // window-free sentinel (snap_last_vs reset to 16'hFFFF != vsync_cnt's
    // reset 0) means this MUST fire immediately, gate or no gate -- confirms
    // the gate does not spuriously hold up an ungated first frame.
    wait_done(1, "P1_F1");
    ckcolor(COLOR_B, "P1_F1_bank1");   // frame "1" = bank1 (parity of done+1=(0+1)&1=1)
    delta_baseline = t_snap - t_pipe_done;
    $display("[part1] frame1 (ungated, the control) blit_done->snap_start = %0d cyc",
             delta_baseline);
    if (mem[BLTCTRL0+6][31:24] !== 8'd0) begin
      $display("  MISMATCH P1_F1: C_STATUS[31:24]=%0d, expected 0 (frame1 must never be gated)",
               mem[BLTCTRL0+6][31:24]);
      errs = errs + 1;
    end else
      $display("  ok P1_F1: C_STATUS[31:24]=0 (not gated, as expected)");

    // Frame 2 (bank0) is now the one FSM is compositing (it started as soon as
    // frame 1's C_DONE/C_STATUS published). vsync_cnt has not moved since
    // frame 1's snapshot latched snap_last_vs, so frame 2's window is NOT
    // free: it must detour into S_SNAP_GATE and hold there.
    wait_state(blt.S_SNAP_GATE, "P1_F2_gate_entry");

    // Hold check: with vs still static, snap_start must not fire and C_DONE
    // must not advance past 1 for a solid stretch of cycles.
    for (i=0; i<500; i=i+1) begin
      @(posedge clk);
      if (blt.snap_start) begin
        $display("  MISMATCH P1_F2_HOLD @cyc=%0d: snap_start fired while window NOT free", cyc);
        errs = errs + 1;
      end
      if (mem[BLTCTRL0+5][31:0] !== 32'd1) begin
        $display("  MISMATCH P1_F2_HOLD @cyc=%0d: C_DONE=%0d, expected to stay 1 while gated",
                 mem[BLTCTRL0+5][31:0], cyc);
        errs = errs + 1;
      end
    end
    $display("[part1] held 500 cycles in S_SNAP_GATE: no snap_start, C_DONE pinned at 1");

    // Now open the window: exactly one vsync edge.
    pulse_vsync();

    wait_done(2, "P1_F2");
    ckcolor(COLOR_A, "P1_F2_bank0");
    if (mem[BLTCTRL0+6][31:24] !== 8'd1) begin
      $display("  MISMATCH P1_F2: C_STATUS[31:24]=%0d, expected exactly 1 deferral",
               mem[BLTCTRL0+6][31:24]);
      errs = errs + 1;
    end else
      $display("  ok P1_F2: C_STATUS[31:24]=1 -- gate fired exactly once, as required");

    // ══════════════════════════════════════════════════════════════════════
    // Part 2: gate is a no-op in steady state. Fresh reset so snap_deferred_cnt
    // restarts at 0 (lets "stays 0" be a literal assertion), vsync now ticks
    // NORMALLY (vs_auto=1, tb_ring_dbuf's free-running toggle), and the two
    // frames are spaced well beyond one full toggle period -- exactly the
    // "host paces submissions, fabric never backlogs" case the gate must be
    // invisible in.
    // ══════════════════════════════════════════════════════════════════════
    rst<=1; repeat(8) @(posedge clk); rst<=0; repeat(4) @(posedge clk);
    for (i=0; i<MEMQW; i=i+1) mem[i] = 64'd0;
    vs_auto <= 1'b1;

    set_ctrl(BLTCTRL0, 2); wr_fill(RING0, COLOR_C);
    mem[BLTCTRL0+0] = {32'd0, 32'd1};   // BANK_EN=0, submit=1
    wait_done(1, "P2_F3");
    ckcolor(COLOR_C, "P2_F3");
    delta3 = t_snap - t_pipe_done;

    // Spacing >> one vsync toggle period (512 cyc) so frame4 unambiguously
    // starts in a fresh window, same as real ~60fps-paced submissions.
    repeat(700) @(posedge clk);

    set_ctrl(BLTCTRL0, 2); wr_fill(RING0, COLOR_D);
    mem[BLTCTRL0+0] = {32'd0, 32'd2};   // BANK_EN=0, submit=2
    wait_done(2, "P2_F4");
    ckcolor(COLOR_D, "P2_F4");
    delta4 = t_snap - t_pipe_done;

    $display("[part2] steady-state deltas: frame3=%0d frame4=%0d (control=%0d)",
             delta3, delta4, delta_baseline);

    // The real, load-bearing "no re-creation of the retired S_SNAP_WAIT
    // disaster" measurement: steady-state latency must EXACTLY match the
    // known-ungated control from part 1, not merely "be fast enough".
    if (delta3 !== delta_baseline) begin
      $display("  MISMATCH P2_F3: delta=%0d cyc != control %0d cyc -- gate added latency!",
               delta3, delta_baseline);
      errs = errs + 1;
    end else
      $display("  ok P2_F3: delta=%0d cyc == control (zero added latency)", delta3);

    if (delta4 !== delta_baseline) begin
      $display("  MISMATCH P2_F4: delta=%0d cyc != control %0d cyc -- gate added latency!",
               delta4, delta_baseline);
      errs = errs + 1;
    end else
      $display("  ok P2_F4: delta=%0d cyc == control (zero added latency)", delta4);

    if (mem[BLTCTRL0+6][31:24] !== 8'd0) begin
      $display("  MISMATCH P2: C_STATUS[31:24]=%0d, expected 0 (steady state must never defer)",
               mem[BLTCTRL0+6][31:24]);
      errs = errs + 1;
    end else
      $display("  ok P2: C_STATUS[31:24] stayed 0 through both steady-state frames");

    if (errs==0) $display("TB_SNAP_GATE: PASS");
    else         $display("TB_SNAP_GATE: FAIL (%0d mismatches)", errs);
    $finish;
  end

  initial begin #100_000_000 $display("TB_SNAP_GATE: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire
