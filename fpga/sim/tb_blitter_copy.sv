// tb_blitter_copy.sv — validate the COPY/BLIT source path (#004) and, specifically,
// the two timing-fix changes in blitter_top: (1) REGISTERED INCREMENTAL source
// addressing (src_byte_cur += 2/px, +stride/row; one multiply in S_BSETUP), and
// (2) pixel reads from the REGISTERED rd_data, not live mem_dout.
//
// The behavioral DDR drives mem_dout to GARBAGE except on the single dout_ready
// beat cycle — so anything that reads mem_dout a cycle late (the old latent bug)
// gets 0xDEAD..., failing this test; only the rd_data capture survives.
//
// Scenario: an 8x4 source sprite (px(x,y)=0x1000+y*8+x) at SRC region, COPY'd to
// dst (20,10). Checks the four corners landed at the right framebuffer qwords.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
module tb_blitter_copy;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = 32'h202000;

  reg clk=0, rst=1; always #5 clk=~clk;

  wire [31:0] bt_addr; wire b_rd, b_we; wire [63:0] b_din; wire [7:0] b_be; wire bt_idle;
  reg  d_dready; reg [63:0] d_dout;

  // behavioral DDR: single-beat reads w/ latency + backpressure; mem_dout is
  // GARBAGE except during the dready beat.
  reg [63:0] mem [0:MEMQW-1];
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat; reg [1:0] bp=0;
  always @(posedge clk) bp <= bp+2'd1;
  wire d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  integer i;

  blitter_top blt(.clk(clk), .rst(rst),
    .mem_addr(bt_addr), .mem_rd(b_rd), .mem_wr(b_we), .mem_din(b_din), .mem_be(b_be),
    .mem_dout(d_dout), .mem_dout_ready(d_dready), .mem_busy(d_busy), .idle(bt_idle));

  always @(posedge clk) begin
    d_dready <= 1'b0;
    d_dout   <= 64'hDEAD_BEEF_DEAD_BEEF;   // invalid unless a beat is being returned
    if (rst) begin rbeats<=0; rlat<=0; end
    else begin
      if (rlat != 3'd0) rlat <= rlat - 3'd1;
      else if (rbeats != 8'd0) begin
        if (bp == 2'd2) begin
          d_dout <= mem[raddr-WBASE]; d_dready <= 1'b1;
          raddr <= raddr + 29'd1; rbeats <= rbeats - 8'd1;
        end
      end else if (!d_busy) begin
        if (b_rd) begin rbeats<=8'd1; raddr<=bt_addr[28:0]; rlat<=3'd3; end
        else if (b_we) for(i=0;i<8;i=i+1) if(b_be[i]) mem[(bt_addr[28:0]-WBASE)][i*8 +:8]<=b_din[i*8 +:8];
      end
    end
  end

  integer x,y;
  integer errs=0;
  initial begin
    for(i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    // control block @ BLTCTRL (window 0xE000)
    mem[32'h200000]=64'd1;   // submit=1
    mem[32'h200001]=64'd2;   // cmd_count=2 (BLIT + END)
    mem[32'h200002]=64'd0;   // target_buf=0 (BUF0)
    mem[32'h200003]=64'd0;   // clear_color
    mem[32'h200004]=64'd0;   // flags = 0 (NO clear)
    mem[32'h200005]=64'd0;   // done=0
    // cmd0 BLIT @ ring 0xE008 : op=3, src_off=0, stride=16, w=8, h=4, dst=(20,10)
    mem[32'h200008]=64'h0000_0000_0000_0003;                 // opcode=BLIT, blend=COPY
    mem[32'h200009]={16'd4,16'd8,16'd0,16'd16};               // h=4 w=8 src_x=0 stride=16
    mem[32'h20000A]={16'd10,16'd20,16'd0,16'd0};              // dst_y=10 dst_x=20 src_y=0
    mem[32'h20000B]=64'd0;
    mem[32'h20000C]=64'd1;                                    // cmd1 END
    // 8x4 source sprite @ SRC region (window 0xF000), stride 16B = 2 qw/row
    for(y=0;y<4;y=y+1) for(x=0;x<8;x=x+1)
      mem[32'h201000 + y*2 + (x>>2)][(x%4)*16 +: 16] = 16'h1000 + y*8 + x;
  end

  integer to;
  initial begin
    repeat(8) @(posedge clk); rst<=0;
    // run until done_seq == submit_seq, or timeout
    to=0;
    while (mem[32'h200005][31:0] !== mem[32'h200000][31:0] && to<2000000) begin @(posedge clk); to=to+1; end
    repeat(10) @(posedge clk);
    $display("=== done_seq=%0d submit=%0d (to=%0d) ===", mem[32'h200005][31:0], mem[32'h200000][31:0], to);
    // dst corners: (20,10)->0x1000 ; (27,10)->0x1007 ; (20,13)->0x1018 ; (27,13)->0x101F
    // dst_qw window = 8 + ((dy*320+dx)>>2); lane = (dy*320+dx)&3
    check(20,10, 16'h1000); check(27,10, 16'h1007);
    check(20,13, 16'h1018); check(27,13, 16'h101F);
    check(24,11, 16'h100C);   // middle pixel (x=4,y=1) -> 0x1000+8+4
    if (mem[32'h200005][31:0]==mem[32'h200000][31:0] && errs==0) $display("RESULT: PASS");
    else $display("RESULT: FAIL (errs=%0d)", errs);
    $finish;
  end
  task check(input integer dx, input integer dy, input [15:0] exp);
    integer idx; reg [15:0] got;
    begin
      idx = 8 + ((dy*320+dx) >> 2);
      got = mem[idx][((dy*320+dx)%4)*16 +: 16];
      if (got !== exp) begin errs=errs+1; $display("  MISMATCH (%0d,%0d): got %h exp %h", dx,dy,got,exp); end
      else $display("  ok (%0d,%0d) = %h", dx,dy,got);
    end
  endtask
  initial begin #50000000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
