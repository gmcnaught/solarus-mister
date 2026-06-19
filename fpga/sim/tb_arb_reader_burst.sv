// tb_arb_reader_burst.sv — regression for the SCANOUT-BLACK bug.
//
// The video reader issues f2h BURST reads with a multi-cycle command->first-beat
// LATENCY. A "cycles since last beat" guard wrongly counts that latency as idle and
// lends the bus to the blitter MID-FETCH, so the reader loses its scanline beats ->
// black screen (HW-confirmed: bypassing the arbiter restored the picture). This
// test holds the blitter asking for the bus the whole time, issues a reader burst
// with a 12-cycle first-beat latency (> the old GUARD=8), and asserts the arbiter
// NEVER grants the blitter until the reader's burst has fully drained, and that the
// reader receives EVERY beat. FAILs the guard-only arbiter; PASSes beat-tracking.
`timescale 1ns/1ps
`default_nettype none
module tb_arb_reader_burst;
  reg clk=0, reset=1; always #5 clk=~clk;

  reg [7:0] r_burst; reg[28:0] r_addr; reg r_rd; reg[63:0] r_din; reg[7:0] r_be; reg r_we;
  wire r_busy, r_grant;
  reg [28:0] b_addr; reg b_rd; reg[63:0] b_din; reg[7:0] b_be; reg b_we;
  wire b_busy, b_grant;
  wire[7:0] d_burst; wire[28:0] d_addr; wire d_rd; wire[63:0] d_din; wire[7:0] d_be; wire d_we;
  reg d_dready=0; reg[63:0] d_dout=0;
  // PIPELINED bridge: BUSY is LOW during a read's first-beat latency (it can accept
  // more commands) — this is the real f2h behaviour that lets a "cycles-idle" guard
  // wrongly lend the bus mid-fetch. d_busy stays low; the model serves one read.
  wire d_busy = 1'b0;

  ddr_blitter_arb #(.ENABLE(1'b1)) dut(.clk(clk),.reset(reset),
    .rdr_burstcnt(r_burst),.rdr_addr(r_addr),.rdr_rd(r_rd),.rdr_din(r_din),.rdr_be(r_be),.rdr_we(r_we),
    .rdr_busy(r_busy),.rdr_grant(r_grant),
    .blt_burstcnt(8'd1),.blt_addr(b_addr),.blt_rd(b_rd),.blt_din(b_din),.blt_be(b_be),.blt_we(b_we),
    .blt_busy(b_busy),.blt_grant(b_grant),
    .ddram_busy(d_busy),.ddram_dout_ready(d_dready),
    .ddram_burstcnt(d_burst),.ddram_addr(d_addr),.ddram_rd(d_rd),.ddram_din(d_din),.ddram_be(d_be),.ddram_we(d_we));

  // DDR: latch ONE read, wait a 12-cycle first-beat latency (busy LOW throughout),
  // then stream `beats` back-to-back beats. Ignores further reads while serving.
  reg [7:0] beats; reg [4:0] lat; reg serving;
  always @(posedge clk) begin
    d_dready <= 1'b0;
    if (reset) begin beats<=0; lat<=0; serving<=0; end
    else if (serving) begin
      if (lat != 0) lat <= lat - 5'd1;                              // latency (busy low)
      else if (beats != 0) begin
        d_dready<=1'b1; d_dout<=64'hCAFE_0000_0000_0000 | {56'd0,beats};
        beats<=beats-8'd1; if (beats==8'd1) serving<=0;
      end
    end
    else if (d_rd) begin serving<=1'b1; beats<=d_burst; lat<=5'd12; end
  end

  integer i, reader_beats, stolen;
  initial begin
    r_burst=0;r_addr=0;r_rd=0;r_din=0;r_be=8'hFF;r_we=0;
    b_addr=29'd100;b_rd=0;b_din=0;b_be=8'hFF;b_we=0;
    repeat(6) @(posedge clk); reset<=0;
    repeat(4) @(posedge clk);
    // reader issues one 8-beat burst FIRST (it's the continuously-fetching master)
    @(posedge clk); r_addr<=29'h08000; r_burst<=8'd8; r_rd<=1'b1;
    @(posedge clk); r_rd<=1'b0;
    // NOW, DURING the reader's first-beat latency, the blitter wants the bus
    b_rd <= 1'b1;
    // now watch: until the reader has received all 8 beats, the blitter must NOT be
    // granted (state must stay G_READER). Count reader beats + any theft.
    reader_beats=0; stolen=0;
    for (i=0; i<200 && reader_beats<8; i=i+1) begin
      @(posedge clk);
      if (b_grant) stolen=stolen+1;                  // blitter got the bus mid-fetch!
      if (d_dready && r_grant) reader_beats=reader_beats+1;
      if (d_dready && !r_grant) stolen=stolen+1;      // a beat arrived but reader not granted
    end
    $display("=== reader_beats=%0d (expect 8)  stolen=%0d (expect 0) ===", reader_beats, stolen);
    if (reader_beats==8 && stolen==0) $display("RESULT: PASS");
    else $display("RESULT: FAIL (arbiter lent the bus during the reader's burst -> scanout black)");
    $finish;
  end
  initial begin #100000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
