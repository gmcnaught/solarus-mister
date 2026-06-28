// tb_blitter_snapshot_pipe.sv — integration test for the vblank work->scan snapshot in
// blitter_top (double-buffered comp_fbram). Composites a frame (COPY of an 8x4 sprite),
// then drives a vblank rising edge; blitter_top must run a work->scan snapshot so the
// SCANOUT buffer (sbank*) becomes bit-exact equal to the WORK buffer (bank*). Before the
// snapshot the scan buffer is untouched (decoupled) — proving tear-free behaviour.
// Copyright (C) 2026 — GPL-3.0
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
module tb_blitter_snapshot_pipe;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h10000;  // [#52] tracks SRC_QW heap base

  reg clk=0, rst=1; always #5 clk=~clk;
  reg vs=0;   // vblank (synced) into blitter_top

  wire [31:0] bt_addr; wire b_rd, b_we; wire [63:0] b_din; wire [7:0] b_be; wire bt_idle;
  reg  d_dready; reg [63:0] d_dout;

  reg [63:0] mem [0:MEMQW-1];
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat; reg [1:0] bp=0;
  always @(posedge clk) bp <= bp+2'd1;
  wire d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  integer i;

  // P_SRC cache-ok source model (single source pipeline), as in tb_blitter_copy_pipe.
  localparam P_SRC_LAT = 3;
  localparam [28:0] SRC_WIN = `SRC_QW - WBASE;
  wire [26:0] s_src_addr; wire s_src_rd;
  reg  [63:0] s_src_dout; reg s_src_ok=1'b0;
  reg         s_rd_d;
  reg [26:0]  s_lat_addr [0:P_SRC_LAT-1];
  reg         s_lat_v    [0:P_SRC_LAT-1];
  integer     sli;
  always @(posedge clk) s_rd_d <= s_src_rd;
  always @(posedge clk) begin
    s_src_ok <= 1'b0;
    s_lat_v   [0] <= s_src_rd & ~s_rd_d;
    s_lat_addr[0] <= s_src_addr;
    for (sli = 1; sli < P_SRC_LAT; sli = sli + 1) begin
      s_lat_v   [sli] <= s_lat_v   [sli-1];
      s_lat_addr[sli] <= s_lat_addr[sli-1];
    end
    if (s_lat_v[P_SRC_LAT-1]) begin
      s_src_dout <= mem[SRC_WIN + (s_lat_addr[P_SRC_LAT-1] >> 3)];
      s_src_ok   <= 1'b1;
    end
  end

  wire [7:0] bt_burst;
  wire fb_wr_en; wire [14:0] fb_wr_qw; wire [1:0] fb_wr_lane; wire [15:0] fb_wr_pix;
  wire fb_rd_en; wire [14:0] fb_rd_qw; wire [63:0] fb_rd_qword;
  wire fb_snap_we; wire [14:0] fb_snap_qw; wire [63:0] fb_snap_qword;

  comp_fbram fbram(.clk(clk),
    .wr_en(fb_wr_en), .wr_qw(fb_wr_qw), .wr_lane(fb_wr_lane), .wr_pix(fb_wr_pix),
    .rd_en(fb_rd_en), .rd_qw(fb_rd_qw), .rd_qword(fb_rd_qword),
    .scan_rd_en(1'b0), .scan_rd_qw(15'd0), .scan_rd_qword(),
    .snap_we(fb_snap_we), .snap_qw(fb_snap_qw), .snap_qword(fb_snap_qword));

  blitter_top blt(.clk(clk), .rst(rst), .vs(vs),
    .mem_addr(bt_addr), .mem_rd(b_rd), .mem_wr(b_we), .mem_burstcnt(bt_burst),
    .mem_din(b_din), .mem_be(b_be),
    .mem_dout(d_dout), .mem_dout_ready(d_dready), .mem_busy(d_busy),
    .p0_addr(s_src_addr), .p0_rd(s_src_rd), .p0_dout(s_src_dout), .p0_ok(s_src_ok),
    .fb_wr_en(fb_wr_en), .fb_wr_qw(fb_wr_qw), .fb_wr_lane(fb_wr_lane), .fb_wr_pix(fb_wr_pix),
    .fb_rd_en(fb_rd_en), .fb_rd_qw(fb_rd_qw), .fb_rd_qword(fb_rd_qword),
    .fb_snap_we(fb_snap_we), .fb_snap_qw(fb_snap_qw), .fb_snap_qword(fb_snap_qword),
    .idle(bt_idle));

  always @(posedge clk) begin
    d_dready <= 1'b0;
    d_dout   <= 64'hDEAD_BEEF_DEAD_BEEF;
    if (rst) begin rbeats<=0; rlat<=0; end
    else begin
      if (rlat != 3'd0) rlat <= rlat - 3'd1;
      else if (rbeats != 8'd0) begin
        if (bp == 2'd2) begin
          d_dout <= mem[raddr-WBASE]; d_dready <= 1'b1;
          raddr <= raddr + 29'd1; rbeats <= rbeats - 8'd1;
        end
      end else if (!d_busy) begin
        if (b_rd) begin rbeats<=bt_burst; raddr<=bt_addr[28:0]; rlat<=3'd3; end
        else if (b_we) for(i=0;i<8;i=i+1) if(b_be[i]) mem[(bt_addr[28:0]-WBASE)][i*8 +:8]<=b_din[i*8 +:8];
      end
    end
  end

  integer x,y;
  integer errs=0, to, sg;
  initial begin
    for(i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    mem[32'h200007]=64'd2;   // C_PIPE
    mem[32'h200000]=64'd1;   // submit=1
    mem[32'h200001]=64'd2;   // cmd_count=2 (BLIT + END)
    mem[32'h200002]=64'd0;   // target_buf=0
    mem[32'h200003]=64'd0;   // clear_color
    mem[32'h200004]=64'd0;   // flags=0 (no clear)
    mem[32'h200005]=64'd0;   // done=0
    mem[32'h200008]=64'h0000_0000_0000_0003;        // BLIT, COPY
    mem[32'h200009]={16'd4,16'd8,16'd0,16'd16};      // h=4 w=8 src_x=0 stride=16
    mem[32'h20000A]={16'd10,16'd20,16'd0,16'd0};     // dst=(20,10)
    mem[32'h20000B]=64'd0;
    mem[32'h20000C]=64'd1;                           // END
    for(y=0;y<4;y=y+1) for(x=0;x<8;x=x+1)
      mem[(SRC_WIN + 29'h00) + y*2 + (x>>2)][(x%4)*16 +: 16] = 16'h1000 + y*8 + x;
  end

  initial begin
    repeat(8) @(posedge clk); rst<=0;
    // 1) wait for the composite to finish (done_seq == submit)
    to=0;
    while (mem[32'h200005][31:0] !== mem[32'h200000][31:0] && to<2000000) begin @(posedge clk); to=to+1; end
    repeat(10) @(posedge clk);
    $display("=== composite done_seq=%0d submit=%0d (to=%0d) ===", mem[32'h200005][31:0], mem[32'h200000][31:0], to);

    // 2) before any vblank, the scan buffer must NOT yet mirror the work buffer.
    if (fbram.sbank0[10*80 + (20>>2)] === fbram.bank0[10*80 + (20>>2)]
        && fbram.bank0[10*80 + (20>>2)] !== 16'hxxxx) begin
      errs=errs+1; $display("  PRE-VBLANK scan already mirrors work (no decoupling)"); end

    // 3) drive a vblank rising edge → blitter_top runs the work->scan snapshot.
    @(posedge clk); vs<=1'b1;
    // give the snapshot time to stream the whole framebuffer (19200 qwords + slack)
    sg=0; while (blt.snap_busy !== 1'b1 && sg<100000) begin @(posedge clk); sg=sg+1; end
    sg=0; while (blt.snap_busy !== 1'b0 && sg<100000) begin @(posedge clk); sg=sg+1; end
    repeat(10) @(posedge clk);

    // 4) the scan buffer is now bit-exact equal to the work buffer at the blit corners.
    schk(20,10, 16'h1000); schk(27,10, 16'h1007);
    schk(20,13, 16'h1018); schk(27,13, 16'h101F);
    schk(24,11, 16'h100C);

    if (mem[32'h200005][31:0]==mem[32'h200000][31:0] && errs==0) $display("RESULT: PASS");
    else $display("RESULT: FAIL (errs=%0d)", errs);
    $finish;
  end

  // check scan buffer (sbank*) at pixel (dx,dy)
  task schk(input integer dx, input integer dy, input [15:0] exp);
    integer idx; reg [15:0] got;
    begin
      idx = dy*80 + (dx>>2);
      got = ((dx&3)==0) ? fbram.sbank0[idx] : ((dx&3)==1) ? fbram.sbank1[idx] :
            ((dx&3)==2) ? fbram.sbank2[idx] : fbram.sbank3[idx];
      if (got !== exp) begin errs=errs+1; $display("  SCAN MISMATCH (%0d,%0d): got %h exp %h", dx,dy,got,exp); end
      else $display("  scan ok (%0d,%0d) = %h", dx,dy,got);
    end
  endtask
  initial begin #80000000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
