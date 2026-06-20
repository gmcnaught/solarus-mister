// tb_arb_borrow.sv — deterministic regression for the HW-observed blitter freeze.
//
// The bug: the arbiter's self-correct force-cleared rd_out=0 whenever the reader
// was idle (quiet>=QUIET_MAX). Because `quiet` resets one cycle AFTER the grant
// FSM leaves G_READER, reader_idle is still high on the cycle the blitter's
// borrowed READ is accepted -> rd_out is clobbered to 0 -> G_BLT_RD yields before
// the read beat returns -> blt_grant drops -> the beat is routed to the reader,
// never to the blitter -> blitter S_RD_WAIT hangs forever.
//
// This test sets up exactly that: hold the reader fully idle until reader_idle is
// asserted, THEN issue a single blitter read (multi-cycle DDR latency so the beat
// returns AFTER any premature yield). PASS iff the blitter receives its routed
// beat (blt_grant & dout_ready). With the buggy arbiter the beat is dropped (FAIL/
// timeout); with the state-gated self-correct it is delivered (PASS).
`timescale 1ns/1ps
`default_nettype none
module tb_arb_borrow;
  reg clk=0, reset=1; always #5 clk=~clk;

  // reader (m0) — held idle the entire test
  reg [7:0] r_burst=0; reg[28:0] r_addr=0; reg r_rd=0; reg[63:0] r_din=0; reg[7:0] r_be=8'hFF; reg r_we=0;
  wire r_busy, r_grant;
  // blitter (m1)
  reg [28:0] b_addr=0; reg b_rd=0; reg[63:0] b_din=0; reg[7:0] b_be=8'hFF; reg b_we=0;
  wire b_busy, b_grant;
  // DDRAM
  wire[7:0] d_burst; wire[28:0] d_addr; wire d_rd; wire[63:0] d_din; wire[7:0] d_be; wire d_we;
  reg d_busy=0; reg d_dready=0; reg[63:0] d_dout=0;

  ddr_blitter_arb #(.ENABLE(1'b1)) dut(.clk(clk),.reset(reset),
    .rdr_burstcnt(r_burst),.rdr_addr(r_addr),.rdr_rd(r_rd),.rdr_din(r_din),.rdr_be(r_be),.rdr_we(r_we),
    .rdr_busy(r_busy),.rdr_grant(r_grant),
    .blt_burstcnt(8'd1),.blt_addr(b_addr),.blt_rd(b_rd),.blt_din(b_din),.blt_be(b_be),.blt_we(b_we),
    .blt_busy(b_busy),.blt_grant(b_grant),
    .ddram_busy(d_busy),.ddram_dout_ready(d_dready),
    .ddram_burstcnt(d_burst),.ddram_addr(d_addr),.ddram_rd(d_rd),.ddram_din(d_din),.ddram_be(d_be),.ddram_we(d_we));

  // behavioral DDRAM: accept one read, busy for `lat` cycles, then one beat.
  reg[63:0] mem[0:65535]; reg[7:0] beats; reg[28:0] baddr; reg[3:0] lat; integer i;
  initial begin for(i=0;i<65536;i=i+1) mem[i]=64'd0; mem[29'h08008]=64'hABCD_1234_5678_9ABC; end
  always @(posedge clk) begin
    d_dready<=0;
    if(reset) begin d_busy<=0; beats<=0; lat<=0; end
    else if(!d_busy) begin
      if(d_rd) begin beats<=d_burst; baddr<=d_addr; lat<=4'd5; d_busy<=1; end   // 5-cycle read latency
      else if(d_we) begin mem[d_addr-29'h07400000]<=d_din; end
    end else if(lat!=0) lat<=lat-1;
    else if(beats!=0) begin d_dready<=1; d_dout<=mem[baddr-29'h07400000]; baddr<=baddr+1; beats<=beats-1; if(beats==1) d_busy<=0; end
    else d_busy<=0;
  end

  integer t; reg got;
  initial begin
    repeat(6)@(posedge clk); reset<=0;
    // hold reader idle long enough for quiet>=QUIET_MAX(200) -> reader_idle=1
    repeat(260)@(posedge clk);
    // issue ONE blitter read while the reader is idle (the race window)
    b_addr<=29'h07408008; b_rd<=1'b1;
    // wait for the arbiter to forward+DDR to accept the blitter read
    t=0; while(!(d_rd && !d_busy)) begin @(posedge clk); t=t+1; if(t>50) begin $display("RESULT: FAIL (blitter read never accepted)"); $finish; end end
    @(posedge clk); b_rd<=1'b0;                 // deassert after accept (like blitter_top S_RD_WAIT)
    // the beat must come back routed to the blitter
    got=1'b0;
    for(t=0;t<100 && !got;t=t+1) begin @(posedge clk); if(b_grant && d_dready) got=1'b1; end
    if(got && d_dout==64'hABCD_1234_5678_9ABC)
      $display("RESULT: PASS (blitter received its routed read beat: %h)", d_dout);
    else
      $display("RESULT: FAIL (read beat dropped -> blitter would hang in S_RD_WAIT)");
    $finish;
  end
  initial begin #2000000 $display("RESULT: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire
