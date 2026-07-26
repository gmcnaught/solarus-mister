// tb_ring_dbuf.sv — [ring-dbuf] Task 3 gate: command-bank double-buffer + C_DONE
// done+1 completion semantics.
//
// Proves two things blitter_top.sv's FSM must get right once a second command
// bank exists (Task 1 added the memory-map constants; this task adds the FSM
// logic that reads them):
//
//   1. FRAME-COLLAPSE FIX. With BANK_EN=1 and TWO frames pending at once
//      (C_SUBMIT=2 while C_DONE=0), the fabric must composite BOTH frames, one
//      at a time, publishing C_DONE=1 after the first and C_DONE=2 after the
//      second. The bank of the frame being STARTED is (done_reg+1)'s parity —
//      frame "1" (started when done_reg=0) reads bank 1, frame "2" (started
//      when done_reg=1) reads bank 0 — never submit_reg's parity, because the
//      host may already be a frame ahead of what the fabric is compositing. A
//      naive "C_DONE <= submit_reg" completion (the pre-fix behaviour) jumps
//      straight from 0 to 2 and the bank-1 frame's draws are silently dropped
//      — the whole point of this TB is to fail loudly on exactly that.
//   2. BANK_EN=0 COMPAT. An old engine that only ever writes the low 32 bits
//      of C_SUBMIT (bit32 reads as 0) must always be served from bank 0,
//      regardless of done_reg's parity. Two frames staged back-to-back in
//      bank 0 (seq 3, then seq 4) must both read bank 0. Bank 1 is left with
//      its STALE data from part 1 (a different fill colour) deliberately: if
//      the RTL forgot to gate the bank-select on bank_en, this phase would
//      read that stale bank-1 colour instead of the fresh bank-0 one, and the
//      colour check below would catch it.
//
// Harness: copied from tb_tilemap.sv's DDR-model + blitter_top instantiation
// preamble (the closest current-generation top-level TB) minus the grid/FRT/
// CFT machinery this TB doesn't need — OP_FILL never touches P_SRC (comp_
// pipeline's is_fill path skips the source-fill prefetch sub-FSM entirely), so
// p0_ok is tied low and never asserts. Readback is comp_fbram (FB-in-BRAM),
// same getpx() helper as tb_tilemap.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
module tb_ring_dbuf;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h8000;   // ctrl/ring/source-heap window
  // Window-relative (mem[]-indexed) control-block + ring bases for both banks.
  // BLTCTRL0/RING0 mirror tb_tilemap's 0x200000/0x200008; bank 1 sits exactly
  // BANK_QW_STRIDE above, per blitter_defs.vh's v5 layout.
  localparam [31:0] BLTCTRL0 = `BLTCTRL_QW - WBASE;                 // 0x200000
  localparam [31:0] RING0    = `RING_QW    - WBASE;                 // 0x200008
  localparam [31:0] BLTCTRL1 = BLTCTRL0 + `BANK_QW_STRIDE;          // 0x210000
  localparam [31:0] RING1    = RING0    + `BANK_QW_STRIDE;          // 0x210008

  reg clk=0, rst=1; always #5 clk=~clk;

  // free-running vblank (harmless for this TB: the WORK->DDR3 snapshot no
  // longer waits on it, see blitter_top.sv's S_SNAP_WAIT comment, but tb_tilemap
  // drives one and this keeps the harness identical).
  reg vs=0; integer vsc=0;
  always @(posedge clk) begin
    vsc <= vsc + 1;
    if (vsc >= 256) begin vs <= ~vs; vsc <= 0; end
  end

  wire [31:0] bt_addr; wire b_rd, b_we; wire [63:0] b_din; wire [7:0] b_be; wire bt_idle;
  wire [7:0]  bt_burst;
  reg  d_dready; reg [63:0] d_dout;

  // ---- behavioral DDR (single-beat reads, latency + backpressure) ----
  reg [63:0] mem [0:MEMQW-1];
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat; reg [1:0] bp=0;
  always @(posedge clk) bp <= bp+2'd1;
  wire d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  integer i;

  // ---- P_SRC: never asserts. OP_FILL's is_fill path in comp_pipeline skips
  // the source-fill prefetch sub-FSM entirely (no p0_rd), so a real source
  // model is unnecessary here — tie p0_ok low.
  wire [26:0] s_src_addr; wire s_src_rd;

  // on-chip dest framebuffer [FB-in-BRAM]
  wire fb_wr_en; wire [14:0] fb_wr_qw; wire [1:0] fb_wr_lane; wire [15:0] fb_wr_pix;
  wire fb_rd_en; wire [14:0] fb_rd_qw; wire [63:0] fb_rd_qword;
  comp_fbram fbram(.clk(clk),
    .wr_en(fb_wr_en), .wr_qw(fb_wr_qw), .wr_lane(fb_wr_lane), .wr_pix(fb_wr_pix),
    .rd_en(fb_rd_en), .rd_qw(fb_rd_qw), .rd_qword(fb_rd_qword));

  blitter_top blt(.clk(clk), .rst(rst), .vs(vs),
    .mem_addr(bt_addr), .mem_rd(b_rd), .mem_wr(b_we), .mem_burstcnt(bt_burst),
    .mem_din(b_din), .mem_be(b_be),
    .mem_dout(d_dout), .mem_dout_ready(d_dready), .mem_busy(d_busy),
    .p0_addr(s_src_addr), .p0_rd(s_src_rd), .p0_dout(64'd0), .p0_ok(1'b0),
    .src_sdram_ok(1'b1), .stage_barrier_busy(1'b0),
    .fb_wr_en(fb_wr_en), .fb_wr_qw(fb_wr_qw), .fb_wr_lane(fb_wr_lane), .fb_wr_pix(fb_wr_pix),
    .fb_rd_en(fb_rd_en), .fb_rd_qw(fb_rd_qw), .fb_rd_qword(fb_rd_qword),
    .idle(bt_idle));

  // DDR read/write engine (plain window; no GRID_BUF/FRT_BUF needed).
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

  // one full-screen OP_FILL(color) + OP_END, 4 qwords/command (matches the
  // 32-byte command layout tb_tilemap's wr_blits/wr_tilemap use).
  task wr_fill(input integer ring_base, input [15:0] color);
    begin
      mem[ring_base+0] = {32'd0, 8'd0, 8'd0, 8'd0, 8'd2};        // op=FILL(2), blend/fmt/flags=0, src_off=0
      mem[ring_base+1] = {16'd240, 16'd320, 16'd0, 16'd0};       // h=240 w=320 src_x=0 stride=0
      mem[ring_base+2] = {16'd0, 16'd0, 16'd0, 16'd0};           // dst_y=0 dst_x=0 _=0 src_y=0
      mem[ring_base+3] = {{16'd0, color}, {8'd0, 8'd0, 16'd0}};  // color, alpha=0, colorkey=0
      mem[ring_base+4] = 64'd1;                                  // op=END(1)
    end
  endtask

  // Backstop cycle bound: a legit FILL frame composites in well under 100k
  // cycles (320x240 comp_pipeline FILL, no source fetch), so 2,000,000 gives
  // generous margin per wait while still resolving (and printing the WEDGE
  // diagnostic) comfortably inside the top-level sim watchdog below, instead
  // of that blunt watchdog firing first and masking the more specific message.
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

  localparam [15:0] COLOR_A = 16'h5555;   // bank 0, part 1
  localparam [15:0] COLOR_B = 16'hAAAA;   // bank 1, part 1 (left stale through part 2 -- the compat poison)
  localparam [15:0] COLOR_C = 16'h3333;   // bank 0, part 2, first frame
  localparam [15:0] COLOR_D = 16'h7777;   // bank 0, part 2, second frame

  initial begin
    errs = 0;
    for (i=0; i<MEMQW; i=i+1) mem[i] = 64'd0;
    // submit=done=0 (mem[BLTCTRL0+0]/[+5] already 0 from the clear above)

    repeat(8) @(posedge clk); rst<=0;
    repeat(4) @(posedge clk);

    // ── Part 1: BANK_EN=1, two frames pending at once (frame-collapse gate) ──
    // seq 1 -> bank 1 (parity of done+1 = (0+1)&1 = 1), seq 2 -> bank 0
    // (parity of done+1 = (1+1)&1 = 0). Stage BOTH before the single submit
    // write so the fabric sees submit=2 while done=0 -- genuinely two frames
    // pending at once, not two back-to-back single-frame submits.
    set_ctrl(BLTCTRL0, 2); wr_fill(RING0, COLOR_A);
    set_ctrl(BLTCTRL1, 2); wr_fill(RING1, COLOR_B);
    mem[BLTCTRL0+0] = {32'h0000_0001, 32'd2};   // BANK_EN=1 (bit32), submit=2

    wait_done(1, "P1_SEQ1");
    // Exactly one frame composited so far, and it must be bank 1's colour --
    // the pre-fix "C_DONE<=submit_reg" completion would have jumped straight
    // to C_DONE=2 and this wait would only ever observe COLOR_A (bank 0,
    // frame "2"), never catching the collapse of frame "1".
    ckcolor(COLOR_B, "P1_SEQ1_bank1");

    wait_done(2, "P1_SEQ2");
    // Second frame landed too -- no collapse.
    ckcolor(COLOR_A, "P1_SEQ2_bank0");

    // ── Part 2: BANK_EN=0, two frames back-to-back, both must read bank 0 ──
    // Bank 1's ctrl/ring are left exactly as part 1 left them (COLOR_B, cmd
    // count 2) -- deliberately NOT re-written. If the bank-select ever forgot
    // to gate on bank_en (i.e. computed (done+1)&1 unconditionally), the
    // first frame here (done_reg=2 at start, parity=(2+1)&1=1) would
    // wrongly resolve to bank 1 and ckcolor would see the stale COLOR_B
    // instead of COLOR_C.
    set_ctrl(BLTCTRL0, 2); wr_fill(RING0, COLOR_C);
    mem[BLTCTRL0+0] = {32'd0, 32'd3};           // BANK_EN=0, submit=3
    wait_done(3, "P2_SEQ3");
    ckcolor(COLOR_C, "P2_SEQ3_bank0_compat");

    set_ctrl(BLTCTRL0, 2); wr_fill(RING0, COLOR_D);
    mem[BLTCTRL0+0] = {32'd0, 32'd4};           // BANK_EN=0, submit=4
    wait_done(4, "P2_SEQ4");
    ckcolor(COLOR_D, "P2_SEQ4_bank0_compat");

    if (errs==0) $display("TB_RING_DBUF: PASS");
    else         $display("TB_RING_DBUF: FAIL (%0d mismatches)", errs);
    $finish;
  end

  initial begin #100_000_000 $display("TB_RING_DBUF: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire
