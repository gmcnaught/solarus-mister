// tb_profile.sv — CYCLE-BUDGET PROFILER (analysis only, not a pass/fail correctness tb).
// Drives blitter_top standalone with the SAME behavioral DDR model used by
// tb_blitter_copy/blend (single-beat reads, rlat=3, bp 1-in-3 backpressure), runs
// a single blit of known WxH for each blend mode, and reports total cycles, cycles
// spent in DDR wait states (S_RD_WAIT=23, S_WR_WAIT=24) vs compute/FSM states, and
// the derived cycles-per-pixel. This quantifies compute-vs-bandwidth for the report.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
module tb_profile;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = 32'h202000;
  reg clk=0, rst=1; always #5 clk=~clk;

  wire [31:0] bt_addr; wire b_rd, b_we; wire [63:0] b_din; wire [7:0] b_be; wire bt_idle;
  reg  d_dready; reg [63:0] d_dout;
  reg [63:0] mem [0:MEMQW-1];
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat; reg [1:0] bp=0;
  always @(posedge clk) bp <= bp+2'd1;
  wire d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  integer i;

  blitter_top blt(.clk(clk), .rst(rst),
    .mem_addr(bt_addr), .mem_rd(b_rd), .mem_wr(b_we), .mem_din(b_din), .mem_be(b_be),
    .mem_dout(d_dout), .mem_dout_ready(d_dready), .mem_busy(d_busy), .idle(bt_idle));

  always @(posedge clk) begin
    d_dready <= 1'b0; d_dout <= 64'hDEAD_BEEF_DEAD_BEEF;
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

  // state probe (hierarchical) for accounting
  integer cyc, c_rdwait, c_wrwait, c_compute, started, ended;
  integer W, H, BLEND;
  integer x,y;

  task setup_blit(input integer w_, input integer h_, input integer blend_);
    begin
      for(i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
      mem[32'h200000]=64'd1; mem[32'h200001]=64'd2; mem[32'h200002]=64'd0;
      mem[32'h200003]=64'd0; mem[32'h200004]=64'd0; mem[32'h200005]=64'd0;
      // cmd0 BLIT op=3, blend=blend_, dst=(0,0), src_off=0, stride=w*2
      mem[32'h200008]={32'h0, 8'd0,8'd0, blend_[7:0], 8'd3};
      mem[32'h200009]={h_[15:0], w_[15:0], 16'd0, 16'(w_*2)};  // h w src_x stride
      mem[32'h20000A]={16'd0,16'd0,16'd0,16'd0};            // dst_y dst_x src_y
      mem[32'h20000B]={16'd0,16'd0, 8'd128 /*alpha*/,8'd0, 16'd0};
      mem[32'h20000C]=64'd1;                                // END
      // source sprite: non-key, non-zero-alpha pixels (top nibble set for PALPHA)
      for(y=0;y<h_;y=y+1) for(x=0;x<w_;x=x+1)
        mem[32'h201000 + (y*w_*2 + x*2)/8][((y*w_*2+x*2)%8)*8 +: 16] = 16'hF000 | (y*w_+x) | 16'h0111;
    end
  endtask

  task run_blit(input integer w_, input integer h_, input integer blend_, input [127:0] name);
    integer to;
    begin
      setup_blit(w_,h_,blend_);
      rst<=1; repeat(4) @(posedge clk); rst<=0;
      cyc=0; c_rdwait=0; c_wrwait=0; c_compute=0; started=0;
      to=0;
      while (mem[32'h200005][31:0] !== mem[32'h200000][31:0] && to<2000000) begin
        @(posedge clk); to=to+1;
        // count from first time we leave the polling states (state>=S_GOT_CMDCNT region)
        if (blt.state==6'd8 /*S_FETCH*/) started=1;
        if (started) begin
          cyc=cyc+1;
          if (blt.state==6'd23) c_rdwait=c_rdwait+1;
          else if (blt.state==6'd24) c_wrwait=c_wrwait+1;
          else c_compute=c_compute+1;
        end
      end
      $display("%0s  WxH=%0dx%0d (%0d px): total=%0d cyc  rd_wait=%0d  wr_wait=%0d  compute/FSM=%0d  => %0.2f cyc/px (ddr_wait %0.1f%%)",
        name, w_, h_, w_*h_, cyc, c_rdwait, c_wrwait, c_compute,
        cyc*1.0/(w_*h_), 100.0*(c_rdwait+c_wrwait)/cyc);
    end
  endtask

  initial begin
    d_dready=0;
    repeat(4) @(posedge clk);
    run_blit(32, 32, 0, "COPY  ");   // opaque copy
    run_blit(32, 32, 2, "ALPHA ");   // const-alpha blend
    run_blit(32, 32, 3, "PALPHA");   // per-pixel alpha blend
    // FILL: op=2
    begin : fillrun
      integer to;
      for(i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
      mem[32'h200000]=64'd1; mem[32'h200001]=64'd2; mem[32'h200004]=64'd0;
      mem[32'h200008]=64'h0000_0000_0000_0002;          // FILL
      mem[32'h200009]={16'd32,16'd32,32'd0};            // h=32 w=32
      mem[32'h20000A]=64'd0;
      mem[32'h20000B]={32'h0000_F800,32'd0};            // color
      mem[32'h20000C]=64'd1;
      rst<=1; repeat(4) @(posedge clk); rst<=0;
      cyc=0; c_rdwait=0; c_wrwait=0; c_compute=0; started=0; to=0;
      while (mem[32'h200005][31:0] !== mem[32'h200000][31:0] && to<2000000) begin
        @(posedge clk); to=to+1;
        if (blt.state==6'd8) started=1;
        if (started) begin cyc=cyc+1;
          if (blt.state==6'd23) c_rdwait=c_rdwait+1;
          else if (blt.state==6'd24) c_wrwait=c_wrwait+1;
          else c_compute=c_compute+1; end
      end
      $display("FILL    WxH=32x32 (1024 px): total=%0d cyc  rd_wait=%0d  wr_wait=%0d  compute/FSM=%0d  => %0.2f cyc/px (ddr_wait %0.1f%%)",
        cyc, c_rdwait, c_wrwait, c_compute, cyc/1024.0, 100.0*(c_rdwait+c_wrwait)/cyc);
    end
    $finish;
  end
  initial begin #200000000 $display("PROFILE TIMEOUT"); $finish; end
endmodule
`default_nettype wire
