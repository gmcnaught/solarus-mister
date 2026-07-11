// tb_blitter_mul_pipe.sv — v2 escape elimination: MULTIPLY blend (blend_mode=5)
// bit-exact to the C golden blt_mul565, for BOTH BLIT and FILL, through the
// comp_pipeline burst path (C_PIPE=1).
//
//   out_ch = round(src_ch * dst_ch / chan_max)   (R/B max 31, G max 63)
//
// DIVIDE-FREE EXACT reduction the RTL MUST match (== blt_mul565 / div31/div63):
//   R,B: t=src*dst; out = ((t+16) + ((t+16)>>5)) >> 5     (== round(t/31))
//   G  : t=src*dst; out = ((t+32) + ((t+32)>>6)) >> 6     (== round(t/63))
//
// INTEGRATION NOTE (Workstream B): assumes comp_pipeline/comp_mixer gain a
// MULTIPLY mode selected by c_blend==5 (cmd_qw[0][15:8]). Pre-B the mixer
// default leaves dst unwritten -> these checks FAIL (expected).
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
module tb_blitter_mul_pipe;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h10000;  // [#52] tracks SRC_QW heap base
  localparam [15:0] BG = 16'hAD55, SRCP = 16'h8C73, FILLC = 16'hC618;

  reg clk=0, rst=1; always #5 clk=~clk;
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
  // on-chip dest framebuffer [FB-in-BRAM] — comp_pipeline composites here now.
  wire fb_wr_en; wire [14:0] fb_wr_qw; wire [1:0] fb_wr_lane; wire [15:0] fb_wr_pix;
  wire fb_rd_en; wire [14:0] fb_rd_qw; wire [63:0] fb_rd_qword;
  comp_fbram fbram(.clk(clk),
    .wr_en(fb_wr_en), .wr_qw(fb_wr_qw), .wr_lane(fb_wr_lane), .wr_pix(fb_wr_pix),
    .rd_en(fb_rd_en), .rd_qw(fb_rd_qw), .rd_qword(fb_rd_qword));
  blitter_top blt(.clk(clk), .rst(rst),
    .mem_addr(bt_addr), .mem_rd(b_rd), .mem_wr(b_we), .mem_burstcnt(bt_burst),
    .mem_din(b_din), .mem_be(b_be),
    .mem_dout(d_dout), .mem_dout_ready(d_dready), .mem_busy(d_busy),
    .p0_addr(s_src_addr), .p0_rd(s_src_rd), .p0_dout(s_src_dout), .p0_ok(s_src_ok),
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

  // reference multiply (matches blt_mul565: divide-free round(t/max))
  function [15:0] ref_mul(input [15:0] s, input [15:0] d);
    integer sr,sg,sb,dr,dg,db,tr,tg,tb,mr,mg,mb,orr,ogg,obb;
    begin
      sr=s[15:11]; sg=s[10:5]; sb=s[4:0]; dr=d[15:11]; dg=d[10:5]; db=d[4:0];
      tr=sr*dr; mr=tr+16; orr=(mr+(mr>>5))>>5;
      tg=sg*dg; mg=tg+32; ogg=(mg+(mg>>6))>>6;
      tb=sb*db; mb=tb+16; obb=(mb+(mb>>5))>>5;
      ref_mul={orr[4:0],ogg[5:0],obb[4:0]};
    end
  endfunction

  integer x,y,errs=0;
  initial begin
    for(i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    // seed the on-chip FB with BG (CLEAR no longer reaches comp_fbram post-cutover).
    for(i=0;i<`FB_QWORDS;i=i+1) begin
      fbram.bank0[i]=BG; fbram.bank1[i]=BG; fbram.bank2[i]=BG; fbram.bank3[i]=BG; end
    mem[32'h200007]=64'd2;  // C_PIPE
    mem[32'h200000]=64'd1; mem[32'h200001]=64'd3; mem[32'h200002]=64'd0;
    mem[32'h200003]={48'd0,BG}; mem[32'h200004]=64'd0; mem[32'h200005]=64'd0;  // no CLEAR: FB pre-seeded BG (Phase 0a)
    // cmd0 MUL BLIT: blend=5, src_off=0, w=2 h=2 stride=4, dst=(40,40)
    mem[32'h200008]={32'd0, 8'd0,8'd0,8'd5,8'd3};   // op=BLIT blend=MUL(5)
    mem[32'h200009]={16'd2,16'd2,16'd0,16'd4};
    mem[32'h20000A]={16'd40,16'd40,16'd0,16'd0};
    mem[32'h20000B]=64'd0;
    // cmd1 MUL FILL: blend=5, color=FILLC, dst=(50,50)
    mem[32'h20000C]={32'd0, 8'd0,8'd0,8'd5,8'd2};   // op=FILL blend=MUL(5)
    mem[32'h20000D]={16'd2,16'd2,16'd0,16'd0};
    mem[32'h20000E]={16'd50,16'd50,16'd0,16'd0};
    mem[32'h20000F]={16'd0, FILLC, 16'd0, 16'd0};
    mem[32'h200010]=64'd1;                            // END
    mem[(SRC_WIN + 29'h00)]={SRCP,SRCP,SRCP,SRCP};            // 2x2 solid SRCP
  end

  task ckpix(input integer dx, input integer dy, input [15:0] exp, input [127:0] tag);
    integer idx; reg [15:0] got;
    begin
      idx = dy*80 + (dx>>2);   // comp_fbram qword; lane = dx[1:0]
      got = ((dx&3)==0) ? fbram.bank0[idx] : ((dx&3)==1) ? fbram.bank1[idx] :
            ((dx&3)==2) ? fbram.bank2[idx] : fbram.bank3[idx];
      if (got!==exp) begin errs=errs+1; $display("  MISMATCH %0s (%0d,%0d): got %h exp %h",tag,dx,dy,got,exp); end
      else $display("  ok %0s (%0d,%0d) = %h",tag,dx,dy,got);
    end
  endtask

  integer to;
  initial begin
    repeat(8) @(posedge clk); rst<=0;
    to=0; while(mem[32'h200005][31:0]!==mem[32'h200000][31:0] && to<3000000) begin @(posedge clk); to=to+1; end
    repeat(10) @(posedge clk);
    $display("=== done_seq=%0d submit=%0d (to=%0d) ===", mem[32'h200005][31:0], mem[32'h200000][31:0], to);
    ckpix(40,40, ref_mul(SRCP, BG),  "mul-blit");
    ckpix(41,41, ref_mul(SRCP, BG),  "mul-blit");
    ckpix(50,50, ref_mul(FILLC, BG), "mul-fill");
    ckpix(51,51, ref_mul(FILLC, BG), "mul-fill");
    if (mem[32'h200005][31:0]==mem[32'h200000][31:0] && errs==0) $display("RESULT: PASS");
    else $display("RESULT: FAIL (errs=%0d)", errs);
    $finish;
  end
  initial begin #80000000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
