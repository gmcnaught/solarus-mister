// Models the REAL reader: idles (no request) for a while, THEN gates its burst
// read on !busy (if(!ddr_busy) assert rd). With a request-gated-grant arbiter this
// deadlocks (reader stalled by grant can never assert rd). Asserts the reader
// always gets the bus within a bounded gap and reads correct data. The blitter
// port is tied idle here — this is purely the reader-deadlock/integrity regression
// (the blitter-borrow path is covered by tb_arb_borrow + tb_blitter_system).
`timescale 1ns/1ps
`default_nettype none
module tb_deadlock;
  reg clk=0,reset=1; always #5 clk=~clk;
  reg [7:0] r_burst; reg[28:0] r_addr; reg r_rd; reg[63:0] r_din; reg[7:0] r_be; reg r_we;
  wire r_busy,r_grant;
  wire[7:0] d_burst; wire[28:0] d_addr; wire d_rd; wire[63:0] d_din; wire[7:0] d_be; wire d_we;
  wire b_busy,b_grant;
  reg d_busy; reg d_dready; reg[63:0] d_dout;
  ddr_blitter_arb #(.ENABLE(1'b1)) dut(.clk(clk),.reset(reset),
    .rdr_burstcnt(r_burst),.rdr_addr(r_addr),.rdr_rd(r_rd),.rdr_din(r_din),.rdr_be(r_be),.rdr_we(r_we),
    .rdr_busy(r_busy),.rdr_grant(r_grant),
    .blt_burstcnt(8'd1),.blt_addr(29'd0),.blt_rd(1'b0),.blt_din(64'd0),.blt_be(8'd0),.blt_we(1'b0),
    .blt_busy(b_busy),.blt_grant(b_grant),
    .ddram_busy(d_busy),.ddram_dout_ready(d_dready),
    .ddram_burstcnt(d_burst),.ddram_addr(d_addr),.ddram_rd(d_rd),.ddram_din(d_din),.ddram_be(d_be),.ddram_we(d_we));
  // behavioral DDRAM with backpressure (busy can extend a few cycles)
  reg[63:0] mem[0:65535]; reg[7:0] beats; reg[28:0] baddr; reg[3:0] lat; integer i; integer seed=7;
  initial for(i=0;i<4096;i=i+1) mem[32776+i]=64'hC0DE_0000_0000_0000|i;
  always @(posedge clk) begin
    d_dready<=0;
    if(reset) begin d_busy<=0; beats<=0; lat<=0; end
    else if(!d_busy) begin
      if(d_rd) begin beats<=d_burst; baddr<=d_addr; lat<=2+($random(seed)%4+4)%4; d_busy<=1; end
      else if(d_we) begin mem[d_addr-29'h07400000]<=d_din; d_busy<=1; lat<=($random(seed)%3+3)%3; end
    end else if(lat!=0) lat<=lat-1;
    else if(beats!=0) begin d_dready<=1; d_dout<=mem[baddr-29'h07400000]; baddr<=baddr+1; beats<=beats-1; if(beats==1) d_busy<=0; end
    else d_busy<=0;
  end
  integer errors=0,maxgap=0,gap,k,n;
  initial begin
    r_burst=0;r_addr=0;r_rd=0;r_din=0;r_be=8'hFF;r_we=0;
    repeat(6)@(posedge clk); reset<=0;
    for(n=0;n<150;n=n+1) begin
      repeat(300)@(posedge clk);            // reader idle -> producer fills
      gap=0;
      while(r_busy) begin @(posedge clk); gap=gap+1; if(gap>5000) begin $display("DEADLOCK: reader stuck %0d cyc",gap); $finish; end end
      r_addr<=29'h07408008; r_burst<=8'd80; r_rd<=1'b1;   // gate-on-busy then request
      @(posedge clk);
      while(!(r_grant && !d_busy)) @(posedge clk);
      r_rd<=1'b0;
      if(gap>maxgap) maxgap=gap;
      for(k=0;k<80;k=k+1) begin @(posedge clk); while(!(d_dready&&r_grant)) @(posedge clk);
        if(d_dout!==mem[32776+k]) errors=errors+1; end
    end
    $display("=== %0d bursts, read errors=%0d, max grant gap=%0d cyc ===",n,errors,maxgap);
    if(errors==0 && n==150) $display("RESULT: PASS (reader never deadlocked, reads correct)");
    else $display("RESULT: FAIL");
    $finish;
  end
  initial begin #60000000 $display("RESULT: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire

// ---------------------------------------------------------------------------
// tb_burst — blitter burst-grant with CONCURRENT reader workload.
//
// Proves two properties:
//   (a) the blitter does not hold the bus longer than its burst allows
//       (holdmax <= burst_len + small FSM overhead)
//   (b) the reader loses NO accepted beat while the blitter borrows the bus —
//       r_issued beats must ALL return routed to r_grant (non-vacuous: the
//       reader DOES issue reads and receive beats in this test).
//
// Reader handshake: gates r_rd on ~r_busy (same as the real openbor_video_reader).
// DDR model: behavioral, busy during latency+drain; beats returned to the correct
// master through the arbiter's rdr_grant / blt_grant routing.
// ---------------------------------------------------------------------------
`default_nettype none
module tb_burst;
  reg clk=0,reset=1; always #5 clk=~clk;
  reg [7:0] r_burst=8'd1; reg [28:0] r_addr=0; reg r_rd=0; reg [63:0] r_din=0;
  reg [7:0] r_be=8'hFF; reg r_we=0; wire r_busy, r_grant;
  reg [7:0] b_burst=8'd1; reg [28:0] b_addr=0; reg b_rd=0; reg [63:0] b_din=0;
  reg [7:0] b_be=8'hFF; reg b_we=0; wire b_busy, b_grant;
  reg ddr_busy=0, ddr_dready=0; wire [7:0] d_burst; wire [28:0] d_addr;
  wire d_rd, d_we; wire [63:0] d_din; wire [7:0] d_be;
  integer errors=0, holdmax=0, hold=0;
  integer bbeats=0;           // reader beats issued (accepted read commands x burstcnt)
  integer r_returned=0;       // reader beats returned (dout_ready & r_grant)
  integer wbeats=0;           // blitter WRITE beats accepted (exercises G_BLT_WR)
  reg     saw_blt_wr=1'b0;    // arbiter actually entered the G_BLT_WR multi-beat write state

  ddr_blitter_arb #(.ENABLE(1'b1)) arb(.clk(clk),.reset(reset),
    .rdr_burstcnt(r_burst),.rdr_addr(r_addr),.rdr_rd(r_rd),.rdr_din(r_din),.rdr_be(r_be),.rdr_we(r_we),
    .rdr_busy(r_busy),.rdr_grant(r_grant),
    .blt_burstcnt(b_burst),.blt_addr(b_addr),.blt_rd(b_rd),.blt_din(b_din),.blt_be(b_be),.blt_we(b_we),
    .blt_busy(b_busy),.blt_grant(b_grant),
    .ddram_busy(ddr_busy),.ddram_dout_ready(ddr_dready),
    .ddram_burstcnt(d_burst),.ddram_addr(d_addr),.ddram_rd(d_rd),.ddram_din(d_din),.ddram_be(d_be),.ddram_we(d_we));

  // track how long the blitter continuously holds the bus (state != G_READER)
  always @(posedge clk) begin
    if (arb.state != 3'd0) begin hold<=hold+1; if (hold+1>holdmax) holdmax<=hold+1; end
    else hold<=0;
  end

  // count reader beats issued (accepted: state==G_READER & r_rd & ~ddr_busy)
  // and reader beats returned (dout_ready routed to reader via r_grant)
  always @(posedge clk) begin
    if (!reset) begin
      if (arb.state == 3'd0 && r_rd && !ddr_busy) bbeats <= bbeats + r_burst;
      if (ddr_dready && r_grant)                   r_returned <= r_returned + 1;
      if (d_we && !ddr_busy)                       wbeats <= wbeats + 1;   // blitter write beat accepted
      if (arb.state == 3'd3)                       saw_blt_wr <= 1'b1;      // G_BLT_WR entered
    end
  end

  // Behavioral DDR model: accepts one read at a time, adds latency, streams beats.
  // ddr_busy is HIGH from command accept through the full drain (prevents new commands).
  // DDR model: 3-cycle latency then back-to-back beats.
  // With a 4-beat blitter burst: 1 cycle G_BLT + 3 lat + 4 beats = 8 cyc max hold.
  reg [7:0] beats_left; reg [3:0] lat_left;
  always @(posedge clk) begin
    ddr_dready <= 1'b0;
    if (reset) begin ddr_busy<=0; beats_left<=0; lat_left<=0; end
    else if (!ddr_busy) begin
      if (d_rd) begin beats_left<=d_burst; lat_left<=4'd3; ddr_busy<=1; end
    end else if (lat_left != 0) begin
      lat_left <= lat_left - 4'd1;
    end else if (beats_left != 0) begin
      ddr_dready <= 1'b1;
      beats_left <= beats_left - 8'd1;
      if (beats_left == 8'd1) ddr_busy <= 1'b0;
    end else begin
      ddr_busy <= 1'b0;
    end
  end

  // Reader process: issue 3-beat reads whenever the bus is free (gate on ~r_busy),
  // concurrent with the blitter's 4-beat read below. Models real reader behaviour.
  integer r_done=0;
  initial begin
    r_burst=8'd3; r_addr=29'h200;
    // wait for reset to clear
    @(negedge reset); repeat(2) @(posedge clk);
    repeat(6) begin                           // 6 reader burst transactions (overlap both blitter bursts)
      while(r_busy) @(posedge clk);          // gate on ~r_busy (real reader pattern)
      r_rd<=1'b1; @(posedge clk);
      r_rd<=1'b0;
      repeat(20) @(posedge clk);             // pace between bursts
    end
    r_done=1;
  end

  integer i;
  initial begin
    reset<=1; repeat(4) @(posedge clk); reset<=0; @(posedge clk);
    // blitter 4-beat read — runs concurrently with reader workload above
    while(r_busy || ddr_busy) @(posedge clk);  // wait for a reader-idle gap
    b_burst<=8'd4; b_addr<=29'h100; b_rd<=1;
    // wait for blitter command to be accepted (state==G_BLT & ~ddr_busy)
    @(posedge clk); while(!(arb.state==3'd1 && !ddr_busy)) @(posedge clk);
    b_rd<=0;                                    // deassert after accept
    // wait for all 4 blitter beats to drain back (blt_out reaches 0)
    while(arb.blt_out != 8'd0) @(posedge clk);
    repeat(8) @(posedge clk);                  // settle: arbiter must have returned to G_READER

    // --- blitter 4-beat WRITE burst (exercises G_BLT_WR), concurrent with reader ---
    // For writes blt_we is HELD across the burst (each beat presents data), unlike a
    // read command. The arbiter holds the grant in G_BLT_WR for blt_burstcnt accepts.
    while(r_busy || ddr_busy) @(posedge clk);  // wait for a reader-idle gap
    b_burst<=8'd4; b_addr<=29'h180; b_din<=64'hCAFEF00D_00000000; b_be<=8'hFF; b_we<=1;
    @(posedge clk); while(arb.state==3'd0) @(posedge clk);  // wait until the burst is granted (leaves G_READER)
    while(arb.state != 3'd0) @(posedge clk);   // HOLD b_we through G_BLT/G_BLT_WR until burst done
    b_we<=0;                                    // burst complete (back to G_READER) -> release
    repeat(8) @(posedge clk);                  // settle back to G_READER

    // wait for reader to finish its bursts too
    while(!r_done) @(posedge clk);
    repeat(20) @(posedge clk);                 // let final reader beats drain

    // --- assertions ---
    if (holdmax > 4+5)
      begin errors=errors+1; $display("FAIL: blitter held bus %0d cyc > burst", holdmax); end
    if (bbeats == 0)
      begin errors=errors+1; $display("STARV: reader issued 0 beats — reader workload broken"); end
    if (r_returned != bbeats)
      begin errors=errors+1;
            $display("STARV: reader issued %0d beats but received %0d (delta=%0d)",
                     bbeats, r_returned, bbeats-r_returned); end
    // G_BLT_WR (write-burst) coverage: exactly 4 write beats accepted, and the
    // multi-beat write state was actually entered (not the 1-beat shortcut).
    if (wbeats != 4)
      begin errors=errors+1; $display("FAIL: blitter write beats=%0d exp 4", wbeats); end
    if (!saw_blt_wr)
      begin errors=errors+1; $display("FAIL: G_BLT_WR never entered (write burst untested)"); end

    if (errors==0)
      $display("PASS (blitter burst read+write; reader not starved; r_beats=%0d/%0d w_beats=%0d holdmax=%0d)",
               bbeats, r_returned, wbeats, holdmax);
    else
      $display("read errors=%0d", errors);
    $finish;
  end
  initial begin #200000 $display("TIMEOUT"); $finish; end
endmodule
`default_nettype wire
