// tb_blitter_system.sv — full-system sim: arbiter + blitter_top + backpressuring
// DDR + a fake video reader. Preloads a real command list (CLEAR=blue + FILL red
// rect + END) into the DDR command ring, runs the blitter THROUGH the arbiter,
// and checks (a) the blitter composited the framebuffer correctly, (b) it wrote
// the video control word, and (c) the reader's concurrent burst reads are
// uncorrupted (no arbiter misrouting), with no hang. No Altera primitives.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"

module tb_blitter_system;
  localparam [28:0] WBASE = 29'h07400000;    // window base; mem index = addr-WBASE
  localparam        MEMQW = 32'h20000;       // 131072 qwords window

  reg clk=0, reset=1; always #5 clk=~clk;

  // ---- reader (m0) fake master ----
  reg [7:0] r_burst; reg[28:0] r_addr; reg r_rd; reg[63:0] r_din; reg[7:0] r_be; reg r_we;
  wire r_busy, r_grant;
  // ---- blitter (m1) <-> arbiter ----
  wire [28:0] b_addr; wire b_rd; wire[63:0] b_din; wire[7:0] b_be; wire b_we;
  wire b_busy, b_grant; wire [31:0] bt_addr; wire bt_idle;
  // ---- DDRAM ----
  wire [7:0] d_burst; wire[28:0] d_addr; wire d_rd; wire[63:0] d_din; wire[7:0] d_be; wire d_we;
  wire d_busy; reg d_dready; reg[63:0] d_dout;

  ddr_blitter_arb #(.ENABLE(1'b1)) arb(
    .clk(clk), .reset(reset),
    .rdr_burstcnt(r_burst), .rdr_addr(r_addr), .rdr_rd(r_rd), .rdr_din(r_din),
    .rdr_be(r_be), .rdr_we(r_we), .rdr_busy(r_busy), .rdr_grant(r_grant),
    .blt_addr(b_addr), .blt_rd(b_rd), .blt_din(b_din), .blt_be(b_be), .blt_we(b_we),
    .blt_busy(b_busy), .blt_grant(b_grant),
    .ddram_busy(d_busy), .ddram_dout_ready(d_dready),
    .ddram_burstcnt(d_burst), .ddram_addr(d_addr), .ddram_rd(d_rd),
    .ddram_din(d_din), .ddram_be(d_be), .ddram_we(d_we));

  blitter_top blt(
    .clk(clk), .rst(reset),
    .mem_addr(bt_addr), .mem_rd(b_rd), .mem_wr(b_we), .mem_din(b_din), .mem_be(b_be),
    .mem_dout(d_dout), .mem_dout_ready(d_dready & b_grant), .mem_busy(b_busy), .idle(bt_idle));
  assign b_addr = bt_addr[28:0];

  // ---- behavioral DDRAM with backpressure (busy 2/3) ----
  reg [63:0] mem [0:MEMQW-1];
  reg [1:0] bp=0; always @(posedge clk) bp <= (bp==2'd2)?2'd0:bp+2'd1;
  integer i;
  // BURST-capable f2h model: accept a command only when free AND no burst in
  // flight; a read of burstcnt N then streams N beats (gated by bp -> gaps),
  // incrementing the address. d_busy reflects backpressure OR a burst in flight.
  reg [7:0]  rbeats; reg [28:0] raddr; reg [2:0] rlat;
  assign d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  always @(posedge clk) begin
    d_dready <= 1'b0;
    if (reset) begin rbeats<=0; rlat<=0; end
    else begin
      if (rlat != 3'd0) rlat <= rlat - 3'd1;           // read command latency
      else if (rbeats != 8'd0) begin                    // stream burst beats
        if (bp == 2'd2) begin                           // beat gaps (backpressure)
          d_dout <= mem[raddr-WBASE]; d_dready <= 1'b1;
          raddr <= raddr + 29'd1; rbeats <= rbeats - 8'd1;
        end
      end else if (!d_busy) begin                       // accept a new command
        if (d_rd) begin rbeats <= d_burst; raddr <= d_addr; rlat <= 3'd3; end
        else if (d_we) for(i=0;i<8;i=i+1) if(d_be[i]) mem[(d_addr-WBASE)][i*8 +:8]<=d_din[i*8 +:8];
      end
    end
  end

  // ---- command list builder ----
  task wmem(input [31:0] idx, input [63:0] val); mem[idx]=val; endtask
  initial begin
    for(i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    // reader test region (BUF1 window 0x8008+) — producer never writes it
    for(i=0;i<2048;i=i+1) mem[32'h8008+i] = 64'hBEEF_0000_0000_0000 | i;
    // control block @ BLTCTRL (window 0xE000)
    wmem(32'hE000, 64'd1);          // submit_seq = 1
    wmem(32'hE001, 64'd2);          // cmd_count = 2 (FILL + END)
    wmem(32'hE002, 64'd0);          // target_buf = 0 (BUF0)
    wmem(32'hE003, 64'h001F);       // clear_color = blue
    wmem(32'hE004, 64'd1);          // flags = CLEAR
    wmem(32'hE005, 64'd0);          // done_seq = 0
    // ring @ 0xE008 : cmd0 = FILL red rect (128,96) 64x48 ; cmd1 = END
    // qw0={u32[1],u32[0]} opcode=2(FILL); qw1={h<<16|w}; qw2={dst_y<<16|dst_x}; qw3={color}
    wmem(32'hE008, 64'h0000_0000_0000_0002);                 // op=FILL
    wmem(32'hE009, {32'h0030_0040, 32'd0});                  // h=48(0x30) w=64(0x40) (u32[3]) , u32[2]=0
    wmem(32'hE00A, {32'h0060_0080, 32'd0});                  // dst_y=96(0x60) dst_x=128(0x80), u32[4]=0
    wmem(32'hE00B, {32'h0000_F800, 32'd0});                  // color=red 0xF800, u32[6]=0
    wmem(32'hE00C, 64'd1);                                   // cmd1 op=END
    wmem(32'hE00D, 64'd0); wmem(32'hE00E, 64'd0); wmem(32'hE00F, 64'd0);
  end

  // ---- concurrent reader: periodic 80-beat bursts, check every beat ----
  integer errs=0, nbursts=0, gap, k;
  task rd_burst(input [28:0] base);
    begin
      while(r_busy) @(posedge clk);
      r_addr<=base; r_burst<=8'd80; r_rd<=1'b1;     // 80-beat BURST read (like the real reader)
      @(posedge clk);
      gap=0; while(r_busy) begin @(posedge clk); gap=gap+1; if(gap>20000) begin $display("READER STARVED"); $finish; end end
      r_rd<=1'b0;
      for(k=0;k<80;k=k+1) begin @(posedge clk); while(!(d_dready && r_grant)) @(posedge clk);
        if(d_dout !== mem[(base-WBASE)+k]) errs=errs+1; end
      nbursts=nbursts+1;
    end
  endtask

  integer to;
  initial begin
    r_burst=0; r_addr=0; r_rd=0; r_din=0; r_be=8'hFF; r_we=0;
    repeat(8) @(posedge clk); reset<=0;
    // hammer the reader while the blitter composites in the gaps, until blitter done
    fork
      begin : reader_proc
        forever begin
          rd_burst(29'h07408008 + (nbursts%16)*80);
          repeat(300) @(posedge clk);   // idle gap > QUIET_MAX (like the real reader between scanlines)
        end
      end
      begin : wait_done
        to=0;
        while(mem[32'hE005][31:0] !== mem[32'hE000][31:0] && to<4000000) begin @(posedge clk); to=to+1; end
        disable reader_proc;
      end
    join
    repeat(20) @(posedge clk);
    $display("=== blitter done_seq=%0d submit=%0d ; reader bursts=%0d errs=%0d ===",
             mem[32'hE005][31:0], mem[32'hE000][31:0], nbursts, errs);
    $display("VCTRL      = %h (expect 4 = frame1|buf0)", mem[0][31:0]);
    $display("BUF0[0]    = %h (expect blue 001F x4)", mem[8]);
    // rect center px (128+8,96+8)=(136,104): idx=104*320+136=33416 -> qw=8354, +window8
    $display("rect px    = %h (expect red F800 x4)", mem[8 + (104*320+136)/4]);
    $display("non-rect   = %h (expect blue, px (8,8): idx=2568 qw=642)", mem[8 + (8*320+8)/4]);
    if (errs==0 && mem[32'hE005][31:0]==mem[32'hE000][31:0] && mem[0][31:0]==32'd4
        && mem[8]==64'h001F001F001F001F)
      $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end
  initial begin #200000000 $display("RESULT: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire
