// tb_comp_latency_drop.sv — reproduce the "partial-tile / bgcolor fill" bug.
//
// Hypothesis: the compositor drops trailing pixels of a source blit under certain
// P_SRC fetch-latency conditions (variable cache hit/miss latency drives the
// prefetch/overlap timing). A tile that renders fine at cache-hit latency loses
// pixels when its source rows arrive slower — leaving the destination (background)
// showing through. Position/sequence-dependent on HW because cache state varies.
//
// This TB submits ONE fully-opaque (alpha=255) BLEND blit, 8 wide x 16 tall
// (16 rows > COMP_BAND_H=8 => TWO chunks, exercising the chunk transition + the
// Task-3c ping-pong prefetch), with a UNIQUE source pixel per (x,y). Every dst
// pixel MUST equal its source pixel. Any pixel left at BG = a DROP = the bug.
//
// LAT is the (uniform) P_SRC latency; sweep it via -DLAT=<n>. Cache-hit is ~3-4;
// a miss is tens of cycles. Run at several LAT values to find the drop threshold.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
module tb_comp_latency_drop;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h10000;
  localparam [15:0] BG = 16'h8410;
`ifdef LAT
  localparam integer LAT = `LAT;
`else
  localparam integer LAT = 16;
`endif
  localparam integer BW = 8, BH = 16;          // blit 8x16 (2 chunks of 8 rows)
  localparam integer DSTX = 40, DSTY = 40;

  reg clk=0, rst=1; always #5 clk=~clk;
  wire [31:0] bt_addr; wire b_rd, b_we; wire [63:0] b_din; wire [7:0] b_be; wire bt_idle;
  reg  d_dready; reg [63:0] d_dout;
  reg [63:0] mem [0:MEMQW-1];
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat; reg [1:0] bp=0;
  always @(posedge clk) bp <= bp+2'd1;
  wire d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  integer i;

  // ── P_SRC cache-ok source model, VARIABLE per-read latency ──────────────────
  // Only ONE read is outstanding at a time (fabric pulses p0_rd, waits for p0_ok).
  // Model: on a read rising edge, latch addr + pick a latency, count down, then
  // assert p0_ok for one cycle. VARMODE picks the latency pattern per read:
  //   0 = uniform LAT
  //   1 = alternate short(3)/long(LAT)   (cache hit/miss ping-pong)
  //   2 = one slow read every 3rd, else fast(3)
`ifdef VARMODE
  localparam integer VARMODE = `VARMODE;
`else
  localparam integer VARMODE = 1;
`endif
  localparam [28:0] SRC_WIN = `SRC_QW - WBASE;
  wire [26:0] s_src_addr; wire s_src_rd;
  reg  [63:0] s_src_dout; reg s_src_ok=1'b0;
  reg         s_rd_d;
  reg [26:0]  pend_addr;
  reg [15:0]  cd;               // countdown to p0_ok
  reg         busy;
  integer     rdcnt=0;
  function integer pick_lat(input integer n);
    case (VARMODE)
      0: pick_lat = LAT;
      1: pick_lat = (n & 1) ? LAT : 3;
      default: pick_lat = ((n % 3)==0) ? LAT : 3;
    endcase
  endfunction
  always @(posedge clk) s_rd_d <= s_src_rd;
  always @(posedge clk) begin
    s_src_ok <= 1'b0;
    if (s_src_rd & ~s_rd_d) begin        // read rising edge: start a new fetch
      pend_addr <= s_src_addr;
      cd        <= 16'(pick_lat(rdcnt));
      busy      <= 1'b1;
      rdcnt     <= rdcnt + 1;
    end else if (busy) begin
      if (cd <= 16'd1) begin
        s_src_dout <= mem[SRC_WIN + (pend_addr >> 3)];
        s_src_ok   <= 1'b1;
        busy       <= 1'b0;
      end else cd <= cd - 16'd1;
    end
  end

  wire [7:0] bt_burst;
  wire fb_wr_en; wire [14:0] fb_wr_qw; wire [1:0] fb_wr_lane; wire [15:0] fb_wr_pix;
  wire fb_rd_en; wire [14:0] fb_rd_qw; wire [63:0] fb_rd_qword;
  comp_fbram fbram(.clk(clk),
    .wr_en(fb_wr_en), .wr_qw(fb_wr_qw), .wr_lane(fb_wr_lane), .wr_pix(fb_wr_pix),
    .rd_en(fb_rd_en), .rd_qw(fb_rd_qw), .rd_qword(fb_rd_qword));
  reg vs=0; always #1000 vs=~vs;
  blitter_top blt(.clk(clk), .rst(rst), .vs(vs),
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

  // unique nonzero source pixel per (x,y) — never BG, so a drop is unambiguous.
  function [15:0] srcpix(input integer x, input integer y);
    srcpix = 16'h1000 + y*16 + x;   // in [0x1000, 0x1100), != BG(0x8410)
  endfunction

  integer x,y,errs=0,dropped=0;
  initial begin
    for(i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    for(i=0;i<`FB_QWORDS;i=i+1) begin
      fbram.bank0[i]=BG; fbram.bank1[i]=BG; fbram.bank2[i]=BG; fbram.bank3[i]=BG; end
    mem[32'h200007]=64'd2;  // C_PIPE
    mem[32'h200000]=64'd1; mem[32'h200001]=64'd3; mem[32'h200002]=64'd0;   // 3 cmds: prime, test, END
    mem[32'h200003]={48'd0,BG}; mem[32'h200004]=64'd0; mem[32'h200005]=64'd0;
    // cmd0 PRIMING BLIT: wide 40x9 opaque alpha at (0,0), source @ 0x400 bytes. Changes
    // the linebuffer/cache/bank state before the test blit — reproduces the cross-blit
    // context that makes the SAME tile render differently by position on HW.
    mem[32'h200008]={32'd0, 8'd0,8'd0,8'd2,8'd3};
    mem[32'h200009]={16'd9,16'd40,16'd0,16'd80};                    // h=9 w=40 stride=80B
    mem[32'h20000A]={16'd0,16'd0,16'd0,16'd0};                      // dst=(0,0)
    mem[32'h20000B]={32'h0000_0400,8'd255,16'd0};                   // src_off=0x400, alpha=255
    // cmd1: ALPHA BLIT, alpha=255 (opaque), src_off=0, w=BW h=BH stride=BW*2, dst=(DSTX,DSTY)
    mem[32'h20000C]={32'd0, 8'd0,8'd0,8'd2,8'd3};                   // op=BLIT(3) blend=ALPHA(2)
    mem[32'h20000D]={16'(BH),16'(BW),16'd0,16'(BW*2)};             // h,w,src_x,stride(bytes)
    mem[32'h20000E]={16'(DSTY),16'(DSTX),16'd0,16'd0};             // dst_y,dst_x,src_y
    mem[32'h20000F]={16'd0,16'd0,8'd255,16'd0};                    // alpha=255 @[23:16]
    mem[32'h200010]=64'd1;                                         // cmd2 END
    // test-blit source: row y at qw (SRC_WIN + y*(BW*2/8)) ; BW=8 -> 2 qw/row
    for(y=0;y<BH;y=y+1) for(x=0;x<BW;x=x+1)
      mem[(SRC_WIN + y*(BW*2/8) + (x>>2))][(x%4)*16 +: 16] = srcpix(x,y);
    // priming-blit source @ 0x400 bytes = qw 0x80: 40x9 nonzero
    for(y=0;y<9;y=y+1) for(x=0;x<40;x=x+1)
      mem[(SRC_WIN + 29'h80 + y*10 + (x>>2))][(x%4)*16 +: 16] = 16'h2000 + y*40 + x;
  end

  task ckpix(input integer dx, input integer dy, input [15:0] exp);
    integer idx; reg [15:0] got;
    begin
      idx = dy*`FB_ROW_QW + (dx>>2);
      case (dx & 3)
        0: got = fbram.bank0[idx];
        1: got = fbram.bank1[idx];
        2: got = fbram.bank2[idx];
        default: got = fbram.bank3[idx];
      endcase
      if (got!==exp) begin
        errs=errs+1; if (got===BG) dropped=dropped+1;
        $display("  MISMATCH (%0d,%0d): got %h exp %h%s",dx,dy,got,exp, (got===BG)?"  <-- DROPPED (bg shows through)":"");
      end
    end
  endtask

  integer to;
  initial begin
    repeat(8) @(posedge clk); rst<=0;
    to=0; while(mem[32'h200005][31:0]!==mem[32'h200000][31:0] && to<3000000) begin @(posedge clk); to=to+1; end
    repeat(20) @(posedge clk);
    $display("=== LAT=%0d  blit %0dx%0d @ (%0d,%0d)  done_seq=%0d submit=%0d ===",
             LAT, BW, BH, DSTX, DSTY, mem[32'h200005][31:0], mem[32'h200000][31:0]);
    for(y=0;y<BH;y=y+1) for(x=0;x<BW;x=x+1) ckpix(DSTX+x, DSTY+y, srcpix(x,y));
    $display("errs=%0d dropped(bg-through)=%0d", errs, dropped);
    if (mem[32'h200005][31:0]==mem[32'h200000][31:0] && errs==0) $display("RESULT: PASS (all %0d px composited)", BW*BH);
    else $display("RESULT: FAIL — %0d/%0d px wrong (%0d dropped to background) at LAT=%0d", errs, BW*BH, dropped, LAT);
    $finish;
  end
  initial begin #80000000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
