// tb_blitter_snapshot_blend_pipe.sv — repro probe for the HW "static sprite garbage"
// bug. Alpha-blended sprites do a DEST read-modify-write through comp_fbram's work-read
// port — the port the double-buffer snapshot also borrows between frames. This drives
// TWO frames (each: CLEAR(BG) + ALPHA blit at a fixed dst), with a vblank work->scan
// snapshot BETWEEN them, and asserts the SECOND frame's blended pixel is still bit-exact.
// If the snapshot corrupts the following blend RMW, frame 2 mismatches.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
module tb_blitter_snapshot_blend_pipe;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h10000;  // [#52] tracks SRC_QW heap base
  localparam [15:0] BG = 16'h8410, REDS = 16'hF800;

  reg clk=0, rst=1; always #5 clk=~clk;
  reg vs=0; always #1000 vs=~vs;   // free-running vblank -> per-frame snapshot
  wire [31:0] bt_addr; wire b_rd, b_we; wire [63:0] b_din; wire [7:0] b_be; wire bt_idle;
  reg  d_dready; reg [63:0] d_dout;
  reg [63:0] mem [0:MEMQW-1];
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat; reg [1:0] bp=0;
  always @(posedge clk) bp <= bp+2'd1;
  wire d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  integer i;

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
    s_lat_v[0] <= s_src_rd & ~s_rd_d; s_lat_addr[0] <= s_src_addr;
    for (sli=1; sli<P_SRC_LAT; sli=sli+1) begin
      s_lat_v[sli] <= s_lat_v[sli-1]; s_lat_addr[sli] <= s_lat_addr[sli-1]; end
    if (s_lat_v[P_SRC_LAT-1]) begin
      s_src_dout <= mem[SRC_WIN + (s_lat_addr[P_SRC_LAT-1] >> 3)]; s_src_ok <= 1'b1; end
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
    d_dready <= 1'b0; d_dout <= 64'hDEAD_BEEF_DEAD_BEEF;
    if (rst) begin rbeats<=0; rlat<=0; end
    else begin
      if (rlat!=3'd0) rlat<=rlat-3'd1;
      else if (rbeats!=8'd0) begin
        if (bp==2'd2) begin d_dout<=mem[raddr-WBASE]; d_dready<=1'b1; raddr<=raddr+29'd1; rbeats<=rbeats-8'd1; end
      end else if (!d_busy) begin
        if (b_rd) begin rbeats<=bt_burst; raddr<=bt_addr[28:0]; rlat<=3'd3; end
        else if (b_we) for(i=0;i<8;i=i+1) if(b_be[i]) mem[(bt_addr[28:0]-WBASE)][i*8 +:8]<=b_din[i*8 +:8];
      end
    end
  end

  function [15:0] ref_blend(input [15:0] s, input [15:0] d, input [7:0] a);
    integer sr,sg,sb,dr,dg,db,ia,na,tr,tg,tb,orr,ogg,obb;
    begin
      sr=s[15:11]; sg=s[10:5]; sb=s[4:0]; dr=d[15:11]; dg=d[10:5]; db=d[4:0];
      ia=a; na=255-a;
      tr=sr*ia+dr*na; orr=(tr+128+((tr+128)>>8))>>8;
      tg=sg*ia+dg*na; ogg=(tg+128+((tg+128)>>8))>>8;
      tb=sb*ia+db*na; obb=(tb+128+((tb+128)>>8))>>8;
      ref_blend={orr[4:0],ogg[5:0],obb[4:0]};
    end
  endfunction

  integer errs=0, to, sg;
  task ckpix(input integer dx, input integer dy, input [15:0] exp, input [255:0] tag);
    integer idx; reg [15:0] got;
    begin
      idx = dy*80 + (dx>>2);
      got = ((dx&3)==0) ? fbram.bank0[idx] : ((dx&3)==1) ? fbram.bank1[idx] :
            ((dx&3)==2) ? fbram.bank2[idx] : fbram.bank3[idx];
      if (got!==exp) begin errs=errs+1; $display("  MISMATCH %0s (%0d,%0d): got %h exp %h",tag,dx,dy,got,exp); end
      else $display("  ok %0s (%0d,%0d) = %h",tag,dx,dy,got);
    end
  endtask

  // build one frame's command ring: CLEAR(BG) + ALPHA blit REDS@(60,60) alpha=128 + END
  task setup_frame(input [31:0] seq);
    begin
      mem[32'h200000]=seq; mem[32'h200001]=64'd2; mem[32'h200002]=64'd0;
      mem[32'h200003]={48'd0,BG}; mem[32'h200004]=64'd1; mem[32'h200005]=64'd0;  // flags=CLEAR(BG)
      mem[32'h200008]={32'h0000_0080, 8'd0,8'd0,8'd2,8'd3};   // ALPHA BLIT src_off=0x80
      mem[32'h200009]={16'd2,16'd2,16'd0,16'd4};              // h=2 w=2 stride=4
      mem[32'h20000A]={16'd60,16'd60,16'd0,16'd0};            // dst=(60,60)
      mem[32'h20000B]={16'd0,16'd0,8'd128,16'd0};             // alpha=128
      mem[32'h20000C]=64'd1;                                  // END
    end
  endtask

  task run_frame(input [31:0] seq);
    begin
      setup_frame(seq);
      to=0; while(mem[32'h200005][31:0]!==seq && to<3000000) begin @(posedge clk); to=to+1; end
      // let the post-frame work->scan snapshot fire + complete
      sg=0; while (blt.snap_busy!==1'b1 && sg<200000) begin @(posedge clk); sg=sg+1; end
      sg=0; while (blt.snap_busy!==1'b0 && sg<200000) begin @(posedge clk); sg=sg+1; end
      repeat(8) @(posedge clk);
    end
  endtask

  initial begin
    for(i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    for(i=0;i<`FB_QWORDS;i=i+1) begin
      fbram.bank0[i]=BG; fbram.bank1[i]=BG; fbram.bank2[i]=BG; fbram.bank3[i]=BG; end
    mem[32'h200007]=64'd2;  // C_PIPE
    mem[(SRC_WIN + 29'h10)]={REDS,REDS,REDS,REDS};   // alpha source 2x2 solid REDS
    mem[(SRC_WIN + 29'h11)]={REDS,REDS,REDS,REDS};

    repeat(8) @(posedge clk); rst<=0;

    // Frame 1: clear + alpha blit. Snapshot fires after.
    run_frame(32'd1);
    $display("=== after frame 1 (to=%0d) ===", to);
    ckpix(60,60, ref_blend(REDS, BG, 8'd128), "f1-alpha");

    // Frame 2: SAME clear + alpha blit, AFTER a snapshot ran. The blend RMW must still
    // read the freshly-cleared BG dest correctly (the snapshot must not have disturbed it).
    run_frame(32'd2);
    $display("=== after frame 2 (to=%0d) ===", to);
    ckpix(60,60, ref_blend(REDS, BG, 8'd128), "f2-alpha-after-snapshot");
    ckpix(61,60, ref_blend(REDS, BG, 8'd128), "f2-alpha-after-snapshot");

    if (errs==0) $display("RESULT: PASS"); else $display("RESULT: FAIL errs=%0d", errs);
    $finish;
  end
  initial begin #100000000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
