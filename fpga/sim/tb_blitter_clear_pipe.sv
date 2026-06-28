// tb_blitter_clear_pipe.sv — validate CLEAR-before-list routed through comp_pipeline
// as a full-screen FILL into comp_fbram [FB-in-BRAM]. The control-block CLEAR flag
// (bit0) used to drive blitter_top's bm_* SDRAM clear loop; it now dispatches a
// FILL(clear_color) over the whole 320x240 to comp_pipeline -> comp_fbram.
//
// TEST 1: CLEAR=blue only (cmd list = END). Whole FB must become blue.
// TEST 2: CLEAR=red + a FILL(green rect). FB = red everywhere except the rect = green.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
module tb_blitter_clear_pipe;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h10000;  // [#52] tracks SRC_QW heap base
  localparam [15:0] BLUE = 16'h001F, RED = 16'hF800, GREEN = 16'h07E0, JUNK = 16'hA5A5;

  reg clk=0, rst=1; always #5 clk=~clk;
  reg vs=0; always #1000 vs=~vs;   // free-running vblank so the per-frame work->scan snapshot fires
  wire [31:0] bt_addr; wire b_rd, b_we; wire [63:0] b_din; wire [7:0] b_be; wire bt_idle;
  wire [7:0] bt_burst;
  reg  d_dready; reg [63:0] d_dout;
  reg [63:0] mem [0:MEMQW-1];
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat; reg [1:0] bp=0;
  always @(posedge clk) bp <= bp+2'd1;
  wire d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  integer i;

  // P_SRC tied off: FILL/CLEAR never read a source.
  wire [26:0] s_src_addr; wire s_src_rd;

  // on-chip dest framebuffer [FB-in-BRAM]
  wire fb_wr_en; wire [14:0] fb_wr_qw; wire [1:0] fb_wr_lane; wire [15:0] fb_wr_pix;
  wire fb_rd_en; wire [14:0] fb_rd_qw; wire [63:0] fb_rd_qword;
  comp_fbram fbram(.clk(clk),
    .wr_en(fb_wr_en), .wr_qw(fb_wr_qw), .wr_lane(fb_wr_lane), .wr_pix(fb_wr_pix),
    .rd_en(fb_rd_en), .rd_qw(fb_rd_qw), .rd_qword(fb_rd_qword),
    .scan_rd_en(1'b0), .scan_rd_qw(15'd0), .scan_rd_qword());

  blitter_top blt(.clk(clk), .rst(rst), .vs(vs),
    .mem_addr(bt_addr), .mem_rd(b_rd), .mem_wr(b_we), .mem_burstcnt(bt_burst),
    .mem_din(b_din), .mem_be(b_be),
    .mem_dout(d_dout), .mem_dout_ready(d_dready), .mem_busy(d_busy),
    .p0_addr(s_src_addr), .p0_rd(s_src_rd), .p0_dout(64'd0), .p0_ok(1'b0),
    .fb_wr_en(fb_wr_en), .fb_wr_qw(fb_wr_qw), .fb_wr_lane(fb_wr_lane), .fb_wr_pix(fb_wr_pix),
    .fb_rd_en(fb_rd_en), .fb_rd_qw(fb_rd_qw), .fb_rd_qword(fb_rd_qword),
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

  integer errs=0, x, y, to, qw, lane;
  function [15:0] getpx(input integer dx, input integer dy);
    begin
      qw = dy*80 + (dx>>2); lane = dx & 3;
      getpx = (lane==0) ? fbram.bank0[qw] : (lane==1) ? fbram.bank1[qw] :
              (lane==2) ? fbram.bank2[qw] : fbram.bank3[qw];
    end
  endfunction
  task ckpix(input integer dx, input integer dy, input [15:0] exp, input [127:0] tag);
    reg [15:0] got; begin got=getpx(dx,dy);
      if (got!==exp) begin errs=errs+1; $display("  MISMATCH %0s (%0d,%0d): got %h exp %h",tag,dx,dy,got,exp); end
    end
  endtask

  // Pre-fill comp_fbram with JUNK so a successful CLEAR must overwrite every pixel.
  task junkfill; begin
    for(i=0;i<`FB_QWORDS;i=i+1) begin
      fbram.bank0[i]=JUNK; fbram.bank1[i]=JUNK; fbram.bank2[i]=JUNK; fbram.bank3[i]=JUNK; end
  end endtask

  task await_submit(input [31:0] n);
    begin
      to=0; while(mem[32'h200005][31:0]!==n && to<3000000) begin @(posedge clk); to=to+1; end
      repeat(10) @(posedge clk);
    end
  endtask

  initial begin
    for(i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    mem[32'h200007]=64'd2;   // C_PIPE
    junkfill;

    // ---- TEST 1: CLEAR=blue, cmd list = END only ----
    mem[32'h200000]=64'd1;   // submit=1
    mem[32'h200001]=64'd1;   // cmd_count=1 (END)
    mem[32'h200002]=64'd0;   // target_buf=0
    mem[32'h200003]={48'd0,BLUE};  // clear_color=blue
    mem[32'h200004]=64'd1;   // flags = CLEAR
    mem[32'h200005]=64'd0;   // done=0
    mem[32'h200008]=64'd1;   // cmd0 = END

    repeat(8) @(posedge clk); rst<=0;
    await_submit(32'd1);
    $display("=== TEST1 CLEAR=blue (to=%0d) ===", to);
    ckpix(0,0,    BLUE, "t1-tl");   ckpix(319,0,   BLUE, "t1-tr");
    ckpix(0,239,  BLUE, "t1-bl");   ckpix(319,239, BLUE, "t1-br");
    ckpix(160,120,BLUE, "t1-mid");  ckpix(7,7,     BLUE, "t1-near");

    // ---- TEST 2: CLEAR=red + FILL(green rect 64x48 @ (128,96)) ----
    junkfill;
    mem[32'h200001]=64'd2;          // cmd_count=2 (FILL + END)
    mem[32'h200003]={48'd0,RED};    // clear_color=red
    mem[32'h200004]=64'd1;          // flags = CLEAR
    // cmd0 FILL green rect: op=FILL(2), color in cmd_qw[3][47:32], dst=(128,96) 64x48
    mem[32'h200008]=64'h0000_0000_0000_0002;       // op=FILL
    mem[32'h200009]={16'd48,16'd64,32'd0};         // h=48 w=64
    mem[32'h20000A]={16'd96,16'd128,32'd0};        // dst_y=96 dst_x=128
    mem[32'h20000B]={16'd0,GREEN,32'd0};           // color=green
    mem[32'h20000C]=64'd1;                          // cmd1 END
    mem[32'h200000]=64'd2;          // submit=2
    await_submit(32'd2);
    $display("=== TEST2 CLEAR=red + FILL green (to=%0d) ===", to);
    // cleared red everywhere outside the rect
    ckpix(0,0,    RED, "t2-bg-tl");  ckpix(319,239, RED, "t2-bg-br");
    ckpix(127,96, RED, "t2-bg-left");ckpix(192,96,  RED, "t2-bg-right"); // x=128..191 is the rect
    ckpix(128,95, RED, "t2-bg-above");
    // green inside the rect [128..191] x [96..143]
    ckpix(128,96, GREEN, "t2-rect-tl"); ckpix(191,96,  GREEN, "t2-rect-tr");
    ckpix(128,143,GREEN, "t2-rect-bl"); ckpix(191,143, GREEN, "t2-rect-br");
    ckpix(160,120,GREEN, "t2-rect-mid");

    if (errs==0) $display("RESULT: PASS"); else $display("RESULT: FAIL (errs=%0d)", errs);
    $finish;
  end
  initial begin #80000000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
