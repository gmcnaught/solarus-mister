// tb_comp_pipeline.sv — standalone check of comp_pipeline against a behavioural DDR.
// Copyright (C) 2026 — GPL-3.0
//
// Drives comp_pipeline directly (no blitter_top) for two blits:
//   (1) a small COPY blit  — assert the dest qwords land the source pixels.
//   (2) a CONST_ALPHA blit — assert the blended result vs the golden formula.
// The DDR model mirrors tb_blitter_copy: single-beat reads with latency +
// backpressure, garbage on mem_dout except the dready beat, byte-enable writes.
`timescale 1ns/1ps
`default_nettype none
`include "comp_defs.vh"
`include "blitter_defs.vh"
module tb_comp_pipeline;
  localparam [28:0] WBASE = 29'h07400000;     // window base (qword) shared by FB+SRC
  localparam        MEMQW = 32'h202000;
  localparam [15:0] BG = 16'h8410;

  reg clk=0, rst=1; always #5 clk=~clk;

  // comp_pipeline command interface
  reg        blit_start;
  reg  [7:0] c_opcode, c_blend, c_format, c_flags, c_alpha;
  reg [31:0] c_src_off;
  reg [15:0] c_src_stride, c_src_x, c_src_y, c_w, c_h, c_colorkey, c_color;
  reg signed [15:0] c_dst_x, c_dst_y;
  reg [31:0] target_base;
  wire       blit_done;

  // mem master
  wire [31:0] m_addr; wire m_rd, m_wr; wire [63:0] m_din; wire [7:0] m_be;
  reg  [63:0] m_dout; reg m_dready;

  reg [63:0] mem [0:MEMQW-1];
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat; reg [1:0] bp=0;
  always @(posedge clk) bp <= bp+2'd1;
  wire m_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  integer i;

  comp_pipeline dut(
    .clk(clk), .rst(rst),
    .blit_start(blit_start),
    .c_opcode(c_opcode), .c_blend(c_blend), .c_format(c_format), .c_flags(c_flags),
    .c_src_off(c_src_off), .c_src_stride(c_src_stride), .c_src_x(c_src_x), .c_src_y(c_src_y),
    .c_w(c_w), .c_h(c_h), .c_colorkey(c_colorkey), .c_alpha(c_alpha), .c_color(c_color),
    .c_dst_x(c_dst_x), .c_dst_y(c_dst_y), .target_base(target_base),
    .mem_addr(m_addr), .mem_rd(m_rd), .mem_wr(m_wr), .mem_din(m_din), .mem_be(m_be),
    .mem_dout(m_dout), .mem_dout_ready(m_dready), .mem_busy(m_busy),
    .blit_done(blit_done));

  always @(posedge clk) begin
    m_dready <= 1'b0; m_dout <= 64'hDEAD_BEEF_DEAD_BEEF;
    if (rst) begin rbeats<=0; rlat<=0; end
    else begin
      if (rlat!=3'd0) rlat<=rlat-3'd1;
      else if (rbeats!=8'd0) begin
        if (bp==2'd2) begin m_dout<=mem[raddr-WBASE]; m_dready<=1'b1; raddr<=raddr+29'd1; rbeats<=rbeats-8'd1; end
      end else if (!m_busy) begin
        if (m_rd) begin rbeats<=8'd1; raddr<=m_addr[28:0]; rlat<=3'd3; end
        else if (m_wr) for(i=0;i<8;i=i+1) if(m_be[i]) mem[(m_addr[28:0]-WBASE)][i*8 +:8]<=m_din[i*8 +:8];
      end
    end
  end

  // golden const-alpha blend (matches comp_mixer / blend565)
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

  integer errs=0, x, y, to;
  // FB qword window index for (dx,dy): 8 + ((dy*320+dx)>>2). lane = (..)%4.
  function [15:0] getpx(input integer dx, input integer dy);
    getpx = mem[8 + ((dy*320+dx)>>2)][((dy*320+dx)%4)*16 +: 16];
  endfunction
  task ckpix(input integer dx, input integer dy, input [15:0] exp, input [127:0] tag);
    reg [15:0] got; begin got=getpx(dx,dy);
      if (got!==exp) begin errs=errs+1; $display("  MISMATCH %0s (%0d,%0d): got %h exp %h",tag,dx,dy,got,exp); end
      else $display("  ok %0s (%0d,%0d) = %h",tag,dx,dy,got);
    end endtask

  task run_blit; begin
    @(posedge clk); blit_start<=1'b1; @(posedge clk); blit_start<=1'b0;
    to=0; while(!blit_done && to<500000) begin @(posedge clk); to=to+1; end
    repeat(4) @(posedge clk);
  end endtask

`ifdef PROBE
  always @(posedge clk) if(!rst) begin
    if (dut.db_cw_we) $display("[%0t] CW we x=%0d row=%0d pix=%h", $time, dut.db_cw_x, dut.db_cw_row, dut.db_cw_pix);
    if (dut.db_fl_valid) $display("[%0t] FL idx=%0d qw=%h be=%h", $time, dut.db_fl_idx, dut.db_fl_qw, dut.db_fl_be);
    if (dut.mem_wr && !dut.mem_busy) $display("[%0t] MEMWR addr=%h be=%h din=%h", $time, dut.mem_addr, dut.mem_be, dut.mem_din);
    if (dut.mx_in_valid) $display("[%0t] MXIN src=%h dst=%h mode=%0d", $time, dut.mx_in_src, dut.mx_in_dst, dut.mx_in_mode);
  end
`endif

  initial begin
    for(i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    blit_start=0;
    target_base = `FB0_QW;     // BUF0 = WBASE+8 in this window
    // fill FB with BG
    for(i=0;i<`FB_QWORDS;i=i+1) mem[8+i]={4{BG}};

    // ── COPY source: 8x4 sprite, px(x,y)=0x1000+y*8+x, stride 16B (2 qw/row) ──
    // SRC heap window: SRC_QW - WBASE = 0x201000 - ... actually SRC_QW=0x07601000;
    // index into mem = SRC_QW - WBASE = 0x201000.
    for(y=0;y<4;y=y+1) for(x=0;x<8;x=x+1)
      mem[32'h201000 + y*2 + (x>>2)][(x%4)*16 +: 16] = 16'h1000 + y*8 + x;
    // ── ALPHA source @ SRC+0x80 bytes = qw 0x201010: 2x2 solid REDS ──
    mem[32'h201010]={16'hF800,16'hF800,16'hF800,16'hF800};
    mem[32'h201011]={16'hF800,16'hF800,16'hF800,16'hF800};

    repeat(8) @(posedge clk); rst<=0; repeat(2) @(posedge clk);

    // ── BLIT 1: COPY 8x4 to (20,10) ──
    c_opcode=8'd3; c_blend=8'd0; c_format=8'd0; c_flags=8'd0;
    c_src_off=32'd0; c_src_stride=16'd16; c_src_x=16'd0; c_src_y=16'd0;
    c_w=16'd8; c_h=16'd4; c_colorkey=16'd0; c_alpha=8'd0; c_color=16'd0;
    c_dst_x=16'd20; c_dst_y=16'd10;
    run_blit;
    $display("=== COPY done (to=%0d) ===", to);
    ckpix(20,10, 16'h1000, "copy-tl"); ckpix(27,10, 16'h1007, "copy-tr");
    ckpix(20,13, 16'h1018, "copy-bl"); ckpix(27,13, 16'h101F, "copy-br");
    ckpix(24,11, 16'h100C, "copy-mid");
    ckpix(19,10, BG, "copy-leftbg"); ckpix(28,10, BG, "copy-rightbg");

    // ── BLIT 2: CONST_ALPHA 2x2 REDS @ (60,60), alpha=128, over BG ──
    c_opcode=8'd3; c_blend=8'd2; c_format=8'd0; c_flags=8'd0;
    c_src_off=32'h80; c_src_stride=16'd4; c_src_x=16'd0; c_src_y=16'd0;
    c_w=16'd2; c_h=16'd2; c_colorkey=16'd0; c_alpha=8'd128; c_color=16'd0;
    c_dst_x=16'd60; c_dst_y=16'd60;
    run_blit;
    $display("=== ALPHA done (to=%0d) ===", to);
    ckpix(60,60, ref_blend(16'hF800, BG, 8'd128), "alpha00");
    ckpix(61,60, ref_blend(16'hF800, BG, 8'd128), "alpha10");
    ckpix(60,61, ref_blend(16'hF800, BG, 8'd128), "alpha01");
    ckpix(61,61, ref_blend(16'hF800, BG, 8'd128), "alpha11");

    if (errs==0) $display("RESULT: PASS"); else $display("RESULT: FAIL (errs=%0d)", errs);
    $finish;
  end
  initial begin #50000000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
