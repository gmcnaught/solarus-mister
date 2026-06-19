// tb_blitter_coalesce.sv — stress the SOURCE read cache + DESTINATION write-coalesce
// against the per-pixel-lane semantics they replace. Covers the cases most likely to
// break qword coalescing:
//   (A) UNALIGNED dst start (leading/trailing partial qwords) — partial BE.
//   (B) COLORKEY skip in the MIDDLE of a qword — skipped lane must NOT be written
//       (background preserved), neighbours in the same qword must be.
//   (C) HFLIP — adjacent dst pixels read DECREASING source bytes (still 4/qword).
//   (D) OVERLAPPING blits to the SAME framebuffer qword — second blit must read the
//       first blit's committed pixels (cache invalidation per blit).
// The DDR model is the same garbage-on-mem_dout backpressured single-beat model.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
module tb_blitter_coalesce_pipe;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = 32'h202000;
  localparam [15:0] BG = 16'h1234, KEY = 16'hAAAA;

  reg clk=0, rst=1; always #5 clk=~clk;
  wire [31:0] bt_addr; wire b_rd, b_we; wire [63:0] b_din; wire [7:0] b_be; wire bt_idle;
  reg  d_dready; reg [63:0] d_dout;
  reg [63:0] mem [0:MEMQW-1];
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat; reg [1:0] bp=0;
  always @(posedge clk) bp <= bp+2'd1;
  wire d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  integer i;

  wire [7:0] bt_burst;
  blitter_top blt(.clk(clk), .rst(rst),
    .mem_addr(bt_addr), .mem_rd(b_rd), .mem_wr(b_we), .mem_burstcnt(bt_burst),
    .mem_din(b_din), .mem_be(b_be),
    .mem_dout(d_dout), .mem_dout_ready(d_dready), .mem_busy(d_busy), .idle(bt_idle));

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

  integer errs=0, x, y, to;
  task fillfb(input [15:0] v); begin
    for(i=0;i<`FB_QWORDS;i=i+1) mem[8+i]={4{v}};
  end endtask
  function [15:0] getpx(input integer dx, input integer dy);
    getpx = mem[8 + ((dy*320+dx)>>2)][((dy*320+dx)%4)*16 +: 16];
  endfunction
  task ckpix(input integer dx, input integer dy, input [15:0] exp, input [127:0] tag);
    reg [15:0] got; begin got=getpx(dx,dy);
      if (got!==exp) begin errs=errs+1; $display("  MISMATCH %0s (%0d,%0d): got %h exp %h",tag,dx,dy,got,exp); end
    end
  endtask
  task run_until_done; begin
    rst<=1; repeat(4) @(posedge clk); rst<=0;
    to=0; while(mem[32'h200005][31:0]!==mem[32'h200000][31:0] && to<3000000) begin @(posedge clk); to=to+1; end
    repeat(8) @(posedge clk);
  end endtask

  initial begin
    for(i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    mem[32'h200007]=64'd2;  // C_PIPE: bit1 -> route via comp_pipeline (Spec A)

    // ---- TEST A: COPY a 7-wide row to dst x=1 (unaligned, spans 3 qwords w/ partials) ----
    fillfb(BG);
    mem[32'h200000]=64'd1; mem[32'h200001]=64'd2; mem[32'h200002]=64'd0;
    mem[32'h200003]=0; mem[32'h200004]=64'd0; mem[32'h200005]=64'd0;   // no clear
    mem[32'h200008]={32'd0,8'd0,8'd0,8'd0,8'd3};        // BLIT COPY
    mem[32'h200009]={16'd1,16'd7,16'd0,16'd14};         // h=1 w=7 stride=14
    mem[32'h20000A]={16'd5,16'd1,16'd0,16'd0};          // dst=(1,5)
    mem[32'h20000B]=0; mem[32'h20000C]=64'd1;
    for(x=0;x<7;x=x+1) mem[32'h201000 + (x*2)/8][((x*2)%8)*8 +:16] = 16'h2000+x;
    run_until_done;
    $display("=== TEST A unaligned COPY done (to=%0d) ===", to);
    for(x=0;x<7;x=x+1) ckpix(1+x,5, 16'h2000+x, "A-copy");
    ckpix(0,5, BG, "A-leadbg"); ckpix(8,5, BG, "A-trailbg");

    // ---- TEST B: COLORKEY a 4-wide row at dst x=0 with the MIDDLE pixel keyed ----
    fillfb(BG);
    mem[32'h200000]=64'd2; mem[32'h200005]=64'd0;       // new submit seq
    mem[32'h200008]={32'd0,8'd0,8'd0,8'd1,8'd3};        // BLIT blend=KEY(1)
    mem[32'h200009]={16'd1,16'd4,16'd0,16'd8};          // h=1 w=4 stride=8
    mem[32'h20000A]={16'd9,16'd0,16'd0,16'd0};          // dst=(0,9)
    mem[32'h20000B]={16'd0,16'd0,8'd0,KEY};             // colorkey=KEY
    mem[32'h20000C]=64'd1;
    mem[32'h201000]={16'h3003, KEY, 16'h3001, 16'h3000}; // px2 keyed (skip)
    run_until_done;
    $display("=== TEST B colorkey-skip done (to=%0d) ===", to);
    ckpix(0,9,16'h3000,"B0"); ckpix(1,9,16'h3001,"B1");
    ckpix(2,9,BG,"B-keyed-bg"); ckpix(3,9,16'h3003,"B3");

    // ---- TEST C: HFLIP COPY a 5-wide row ----
    fillfb(BG);
    mem[32'h200000]=64'd3; mem[32'h200005]=64'd0;
    mem[32'h200008]={32'd0,8'd0,8'd0,8'd0, 8'h03};      // BLIT COPY
    mem[32'h200008][31:24]=8'h01;                        // flags=HFLIP
    mem[32'h200009]={16'd1,16'd5,16'd0,16'd10};         // h=1 w=5 stride=10
    mem[32'h20000A]={16'd11,16'd2,16'd0,16'd0};         // dst=(2,11)
    mem[32'h20000B]=0; mem[32'h20000C]=64'd1;
    for(x=0;x<5;x=x+1) mem[32'h201000 + (x*2)/8][((x*2)%8)*8 +:16] = 16'h4000+x;
    run_until_done;
    $display("=== TEST C HFLIP done (to=%0d) ===", to);
    // dst (2+i) gets source col (w-1-i) = 4-i
    for(x=0;x<5;x=x+1) ckpix(2+x,11, 16'h4000+(4-x), "C-hflip");

    // ---- TEST D: two OVERLAPPING COPY blits to the same qword (row 13, x 0..3) ----
    fillfb(BG);
    mem[32'h200000]=64'd4; mem[32'h200005]=64'd0;
    mem[32'h200001]=64'd3;                               // 3 cmds: blit, blit, END
    // blit1: writes x0..3 = 0x5000..0x5003
    mem[32'h200008]={32'd0,8'd0,8'd0,8'd0,8'd3};
    mem[32'h200009]={16'd1,16'd4,16'd0,16'd8};
    mem[32'h20000A]={16'd13,16'd0,16'd0,16'd0};
    mem[32'h20000B]=0;
    mem[32'h201000]={16'h5003,16'h5002,16'h5001,16'h5000};
    // blit2: overwrites ONLY x1..2 = 0x6001,0x6002 (must read+preserve x0,x3 from DDR)
    // src_off=128 bytes -> SRC window qword 0x201010.
    mem[32'h20000C]={32'd128,8'd0,8'd0,8'd0,8'd3};
    mem[32'h20000D]={16'd1,16'd2,16'd0,16'd4};
    mem[32'h20000E]={16'd13,16'd1,16'd0,16'd0};          // dst=(1,13)
    mem[32'h20000F]=0;
    mem[32'h201010]={32'd0,16'h6002,16'h6001};           // src @ qword (off 128)
    mem[32'h200010]=64'd1;                                // END at ring idx 2 (qw 0x200010)
    run_until_done;
    $display("=== TEST D overlap done (to=%0d) ===", to);
    ckpix(0,13,16'h5000,"D0-keep"); ckpix(1,13,16'h6001,"D1-new");
    ckpix(2,13,16'h6002,"D2-new"); ckpix(3,13,16'h5003,"D3-keep");

    if (errs==0) $display("RESULT: PASS"); else $display("RESULT: FAIL (errs=%0d)", errs);
    $finish;
  end
  initial begin #200000000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
