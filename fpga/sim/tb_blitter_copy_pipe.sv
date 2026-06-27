// tb_blitter_copy_pipe.sv (C_PIPE=1 equivalence: comp_pipeline burst path BIT-EXACT to the
// legacy FSM) — validate the COPY/BLIT source path (#004) and, specifically,
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
module tb_blitter_copy_pipe;
  localparam [28:0] WBASE = 29'h07400000;
  // [#52] derive from SRC_QW so the array always covers the heap base + source data;
  // a hardcoded value silently broke when the ring grew (heap base moved up).
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h8000;  // SRC_WIN + 256 KiB src headroom

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

  // ── P_SRC cache-ok source model (single source pipeline) ────────────────────
  // [collapse-single-source] The per-blit source read is hardwired to SDRAM
  // (src_in_sdram=1), so comp_pipeline fetches source rows through p0_* — NOT the
  // DDR mem_* path. Serve them from the SAME SRC window (mem[0x201000 + heap_qw])
  // so the existing source-data population below is unchanged. p0_addr is the
  // heap byte offset; heap_qw = p0_addr>>3; mem index = (SRC_QW-WBASE) + heap_qw.
  localparam P_SRC_LAT = 3;
  localparam [28:0] SRC_WIN = `SRC_QW - WBASE;   // 0x201000
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
        if (b_rd) begin rbeats<=bt_burst; raddr<=bt_addr[28:0]; rlat<=3'd3; end
        else if (b_we) for(i=0;i<8;i=i+1) if(b_be[i]) mem[(bt_addr[28:0]-WBASE)][i*8 +:8]<=b_din[i*8 +:8];
      end
    end
  end

  integer x,y;
  integer errs=0;
  initial begin
    for(i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    mem[32'h200007]=64'd2;  // C_PIPE: bit1 -> route via comp_pipeline (Spec A)
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
    // 8x4 source sprite @ SRC region (src_off=0 -> SRC_WIN), stride 16B = 2 qw/row.
    // [#52] use SRC_WIN (not a hardcoded 0x201000) so it tracks the heap base.
    for(y=0;y<4;y=y+1) for(x=0;x<8;x=x+1)
      mem[SRC_WIN + y*2 + (x>>2)][(x%4)*16 +: 16] = 16'h1000 + y*8 + x;
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
      idx = dy*80 + (dx>>2);   // comp_fbram qword; lane = dx[1:0]
      got = ((dx&3)==0) ? fbram.bank0[idx] : ((dx&3)==1) ? fbram.bank1[idx] :
            ((dx&3)==2) ? fbram.bank2[idx] : fbram.bank3[idx];
      if (got !== exp) begin errs=errs+1; $display("  MISMATCH (%0d,%0d): got %h exp %h", dx,dy,got,exp); end
      else $display("  ok (%0d,%0d) = %h", dx,dy,got);
    end
  endtask
  initial begin #50000000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
