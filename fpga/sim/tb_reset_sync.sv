// tb_reset_sync.sv — blitter_top reset sync (S_SYNC_*) + signed C_SUBMIT/C_DONE compare.
//
// DDR3 keeps the control block across core loads. Each case below releases reset
// onto a control block in some state and checks that the fabric (a) never
// composites anything the engine did not submit after the reset, and (b) leaves
// C_SUBMIT == C_DONE for the engine's origin sync to adopt.
//
//   1. runaway left behind: C_DONE ahead of C_SUBMIT      -> C_DONE := C_SUBMIT, 0 frames
//   2. stale-high C_SUBMIT, C_DONE behind                 -> C_DONE := C_SUBMIT, 0 frames
//   3. already consistent                                 -> no C_DONE write, sync_fix 0
//   4. first C_SUBMIT read after reset returns garbage    -> re-read corrects C_DONE, 0 frames
//   5. a real submit after the sync                       -> exactly 1 frame, right colour
//   6. C_DONE pushed ahead of C_SUBMIT while running      -> fabric idles (signed compare)
//
// Every bank-0 ring holds a full-screen FILL, so any composite shows up both as a
// pipe_start pulse and as a colour at fb(0,0). Harness from tb_ring_dbuf.sv.
// Compiled with -DBLT_SYNC_HOLDOFF=64 (run_sims.sh defines_for).
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
module tb_reset_sync;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h8000;
  localparam [31:0] BLTCTRL0 = `BLTCTRL_QW - WBASE;
  localparam [31:0] RING0    = `RING_QW    - WBASE;
  localparam integer SUB = 0, DONE = 5;      // qword offsets of C_SUBMIT / C_DONE

  reg clk=0, rst=1; always #5 clk=~clk;
  reg vs=0; integer vsc=0;
  always @(posedge clk) begin
    vsc <= vsc + 1;
    if (vsc >= 256) begin vs <= ~vs; vsc <= 0; end
  end

  wire [31:0] bt_addr; wire b_rd, b_we; wire [63:0] b_din; wire [7:0] b_be; wire bt_idle;
  wire [7:0]  bt_burst;
  reg  d_dready; reg [63:0] d_dout;

  reg [63:0] mem [0:MEMQW-1];
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat; reg [1:0] bp=0;
  always @(posedge clk) bp <= bp+2'd1;
  wire d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  integer i;

  wire [26:0] s_src_addr; wire s_src_rd;
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

  // corrupt_first_submit: the first C_SUBMIT read after it is armed returns garbage
  reg corrupt_first_submit = 1'b0;
  reg rd_is_submit;
  always @(posedge clk) begin
    d_dready <= 1'b0;
    d_dout   <= 64'hDEAD_BEEF_DEAD_BEEF;
    if (rst) begin rbeats<=0; rlat<=0; end
    else begin
      if (rlat != 3'd0) rlat <= rlat - 3'd1;
      else if (rbeats != 8'd0) begin
        if (bp == 2'd2) begin
          if (rd_is_submit && corrupt_first_submit) begin
            d_dout <= 64'h0000_0000_9E37_79B9;
            corrupt_first_submit <= 1'b0;
          end else
            d_dout <= mem[raddr-WBASE];
          d_dready <= 1'b1; raddr <= raddr + 29'd1; rbeats <= rbeats - 8'd1;
        end
      end else if (!d_busy) begin
        if (b_rd) begin
          rbeats<=bt_burst; raddr<=bt_addr[28:0]; rlat<=3'd3;
          rd_is_submit <= (bt_addr[28:0] == `BLTCTRL_QW + `C_SUBMIT);
        end
        else if (b_we) for(i=0;i<8;i=i+1) if(b_be[i]) mem[(bt_addr[28:0]-WBASE)][i*8 +:8]<=b_din[i*8 +:8];
      end
    end
  end

  // free-running counts of composites started and of C_DONE writes; each case
  // checks the change from a snapshot (f0/w0) taken when it starts
  integer frames_tot = 0, done_wr_tot = 0, f0, w0;
  always @(posedge clk) begin
    if (blt.pipe_start) frames_tot <= frames_tot + 1;
    if (b_we && !d_busy && bt_addr[28:0] == `BLTCTRL_QW + `C_DONE) done_wr_tot <= done_wr_tot + 1;
  end
  wire [31:0] n_frames  = frames_tot - f0;
  wire [31:0] n_done_wr = done_wr_tot - w0;

  function [15:0] getpx(input integer dx, input integer dy);
    integer idx;
    begin
      idx = dy*80 + (dx>>2);
      getpx = ((dx&3)==0)?fbram.bank0[idx]:((dx&3)==1)?fbram.bank1[idx]:
              ((dx&3)==2)?fbram.bank2[idx]:fbram.bank3[idx];
    end
  endfunction

  task wr_frame(input [15:0] color);   // bank 0: one full-screen FILL + END
    begin
      mem[BLTCTRL0+1] = 64'd2;         // C_CMDCOUNT
      mem[BLTCTRL0+2] = 64'd0; mem[BLTCTRL0+3] = 64'd0;
      mem[BLTCTRL0+4] = 64'd0; mem[BLTCTRL0+7] = 64'd0;
      mem[RING0+0] = {32'd0, 8'd0, 8'd0, 8'd0, 8'd2};
      mem[RING0+1] = {16'd240, 16'd320, 16'd0, 16'd0};
      mem[RING0+2] = 64'd0;
      mem[RING0+3] = {{16'd0, color}, 32'd0};
      mem[RING0+4] = 64'd1;
    end
  endtask

  integer errs;
  task check(input bit ok, input [511:0] tag);
    begin
      if (!ok) begin $display("  FAIL %0s", tag); errs = errs + 1; end
      else         $display("  ok   %0s", tag);
    end
  endtask

  // reset onto the control block as it is in mem[], then give the sync time to
  // finish (holdoff 64 + a few reads/writes) and the fabric time to misbehave
  task reset_and_settle;
    begin
      rst <= 1'b1; repeat(8) @(posedge clk);
      f0 = frames_tot; w0 = done_wr_tot;
      rst <= 1'b0;
      repeat(20000) @(posedge clk);
    end
  endtask

  localparam [15:0] POISON = 16'hF00F, GOOD = 16'h5A5A;

  initial begin
    errs = 0; f0 = 0; w0 = 0;
    for (i=0; i<MEMQW; i=i+1) mem[i] = 64'd0;
    wr_frame(POISON);

    $display("case 1: runaway left behind (C_SUBMIT=100, C_DONE=5000)");
    mem[BLTCTRL0+SUB] = 64'd100; mem[BLTCTRL0+DONE] = 64'd5000;
    reset_and_settle;
    check(mem[BLTCTRL0+DONE][31:0] == 32'd100, "C_DONE := C_SUBMIT");
    check(n_frames == 0,                       "no frame composited");
    check(blt.sync_fix == 8'd1,                "sync_fix == 1");
    check(getpx(0,0) !== POISON,              "fb not written with the stale frame");

    $display("case 2: stale-high C_SUBMIT (C_SUBMIT=7000, C_DONE=3)");
    mem[BLTCTRL0+SUB] = 64'd7000; mem[BLTCTRL0+DONE] = 64'd3;
    reset_and_settle;
    check(mem[BLTCTRL0+DONE][31:0] == 32'd7000, "C_DONE := C_SUBMIT");
    check(n_frames == 0,                        "no frame composited");
    check(getpx(0,0) !== POISON,              "fb not written with the stale frame");

    $display("case 3: consistent block (42/42)");
    mem[BLTCTRL0+SUB] = 64'd42; mem[BLTCTRL0+DONE] = 64'd42;
    reset_and_settle;
    check(n_done_wr == 0,       "no C_DONE write");
    check(blt.sync_fix == 8'd0, "sync_fix == 0");
    check(n_frames == 0,        "no frame composited");

    $display("case 4: first C_SUBMIT read after reset is garbage (block 0/0)");
    mem[BLTCTRL0+SUB] = 64'd0; mem[BLTCTRL0+DONE] = 64'd0;
    corrupt_first_submit = 1'b1;
    reset_and_settle;
    check(!corrupt_first_submit,                       "the corrupt read happened");
    check(mem[BLTCTRL0+DONE][31:0] == 32'd0,           "C_DONE back to C_SUBMIT (0)");
    check(blt.sync_fix == 8'd2,                        "sync_fix == 2 (wrote garbage, then corrected)");
    check(n_frames == 0,                               "no frame composited");

    $display("case 5: real submit after the sync");
    wr_frame(GOOD);
    mem[BLTCTRL0+SUB] = 64'd1;
    i = 0;
    while (mem[BLTCTRL0+DONE][31:0] != 32'd1 && i < 2_000_000) begin @(posedge clk); i = i + 1; end
    repeat(2000) @(posedge clk);
    check(mem[BLTCTRL0+DONE][31:0] == 32'd1, "C_DONE == 1");
    check(n_frames == 1,                     "exactly one frame composited");
    check(getpx(0,0) == GOOD,                "frame colour");
    check(((mem[BLTCTRL0+6] >> 16) & 64'hFF) == 64'd2, "C_STATUS[23:16] publishes sync_fix");

    $display("case 6: C_DONE ahead of C_SUBMIT while running (no reset)");
    f0 = frames_tot;
    mem[BLTCTRL0+DONE] = 64'd9;               // C_SUBMIT is 1
    repeat(50000) @(posedge clk);
    check(n_frames == 0,                        "fabric idles");
    check(mem[BLTCTRL0+DONE][31:0] == 32'd9,    "C_DONE unchanged");
    mem[BLTCTRL0+SUB] = 64'd10;               // host submits past it: one frame
    i = 0;
    while (mem[BLTCTRL0+DONE][31:0] != 32'd10 && i < 2_000_000) begin @(posedge clk); i = i + 1; end
    repeat(2000) @(posedge clk);
    check(n_frames == 1 && mem[BLTCTRL0+DONE][31:0] == 32'd10, "resumes on the next submit");

    if (errs == 0) $display("RESULT: PASS");
    else           $display("RESULT: FAIL (%0d)", errs);
    $finish;
  end
  initial begin #200_000_000; $display("RESULT: FAIL watchdog"); $finish; end
endmodule
`default_nettype wire
