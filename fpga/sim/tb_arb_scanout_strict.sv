// tb_arb_scanout_strict.sv — SCANOUT-STRICT priority regression (issue #19).
//
// The HW bug: with SOLARUS_SDRAM_SRC=1 the blitter STAGES sources DDR3->SDRAM,
// which means heavy, CONTINUOUS blitter DDR3 *read* traffic. The original arbiter
// lends the bus to the blitter the instant the reader has a gap, then commits to
// the blitter's single-beat read (G_BLT -> G_BLT_RD) and holds the bus for the
// whole DDR3 read latency. While the blitter beat is in flight the scanout reader
// is `rdr_busy` and (because the real reader gates rdr_rd on !rdr_busy) cannot even
// ASSERT its request. Under continuous staging this repeats every scanline fetch:
// the scanout's grant latency balloons -> scanout FIFO underflows -> BLACK overworld.
//
// This test models exactly that load:
//   * BLITTER: requests CONTINUOUSLY (single-beat reads, back-to-back) — heavy stage.
//   * SCANOUT (reader): periodically wants an 80-beat burst; it gates rdr_rd on
//     !rdr_busy (faithful to the real openbor_video_reader).
//   * DDR model: realistic multi-cycle read latency for BOTH masters; busy stays
//     low during a read's first-beat latency (pipelined f2h) so the arbiter sees a
//     plausibly-idle bus during the blitter read window.
//
// Asserts:
//   (A) SCANOUT grant latency (cycles from when scanout WANTS the bus until it is
//       granted + accepted) stays within a SMALL bound, even under continuous
//       blitter demand. This FAILS the lend-then-commit arbiter (latency ~= the
//       blitter read latency, repeated) and PASSES the scanout-strict arbiter.
//   (B) the BLITTER still makes forward progress (completes many reads) — no
//       deadlock / livelock from the stricter priority (it gets the scanout gaps).
//   (C) every scanout burst beat is delivered correctly (no misrouting).
`timescale 1ns/1ps
`default_nettype none
module tb_arb_scanout_strict;
  reg clk=0, reset=1; always #5 clk=~clk;

  // scanout reader (m0)
  reg [7:0] r_burst=0; reg[28:0] r_addr=0; reg r_rd=0; reg[63:0] r_din=0; reg[7:0] r_be=8'hFF; reg r_we=0;
  wire r_busy, r_grant;
  // blitter (m1) — heavy continuous staging reads
  reg [28:0] b_addr=29'h07410000; reg b_rd=0; reg[63:0] b_din=0; reg[7:0] b_be=8'hFF; reg b_we=0;
  wire b_busy, b_grant;
  // DDRAM
  wire[7:0] d_burst; wire[28:0] d_addr; wire d_rd; wire[63:0] d_din; wire[7:0] d_be; wire d_we;
  reg d_dready=0; reg[63:0] d_dout=0;
  // pipelined f2h: busy LOW during a read's first-beat latency (matches tb_arb_reader_burst)
  wire d_busy = 1'b0;

  ddr_blitter_arb #(.ENABLE(1'b1)) dut(.clk(clk),.reset(reset),
    .rdr_burstcnt(r_burst),.rdr_addr(r_addr),.rdr_rd(r_rd),.rdr_din(r_din),.rdr_be(r_be),.rdr_we(r_we),
    .rdr_busy(r_busy),.rdr_grant(r_grant),
    .blt_addr(b_addr),.blt_rd(b_rd),.blt_din(b_din),.blt_be(b_be),.blt_we(b_we),
    .blt_busy(b_busy),.blt_grant(b_grant),
    .ddram_busy(d_busy),.ddram_dout_ready(d_dready),
    .ddram_burstcnt(d_burst),.ddram_addr(d_addr),.ddram_rd(d_rd),.ddram_din(d_din),.ddram_be(d_be),.ddram_we(d_we));

  // ---- pipelined DDR model: busy LOW during a read's first-beat latency. Serves
  // ONE outstanding read at a time (command latency LAT, then streams `beats`).
  // Realistic LAT so the blitter read window is wide (this is what starves scanout
  // in the buggy arbiter). busy goes high only when a burst is actively in flight
  // would over-constrain; instead keep busy low (pipelined) and let the arbiter's
  // beat tracking gate lending — matches tb_arb_reader_burst's faithful model.
  localparam integer LAT = 50;            // realistic f2h DDR3 first-beat latency
  reg [7:0] beats=0; reg [5:0] lat=0; reg serving=0; reg [28:0] saddr;
  reg [63:0] mem [0:131071];
  integer mi; initial begin for(mi=0;mi<131072;mi=mi+1) mem[mi]=64'd0;
    for(mi=0;mi<2048;mi=mi+1) mem[mi]=64'hBEEF_0000_0000_0000 | mi; end
  always @(posedge clk) begin
    d_dready <= 1'b0;
    if (reset) begin beats<=0; lat<=0; serving<=0; end
    else if (serving) begin
      if (lat != 0) lat <= lat - 6'd1;
      else if (beats != 0) begin
        d_dready<=1'b1; d_dout<=mem[saddr-29'h07400000]; saddr<=saddr+29'd1;
        beats<=beats-8'd1; if (beats==8'd1) serving<=0;
      end
    end
    else if (d_rd) begin serving<=1'b1; beats<=d_burst; saddr<=d_addr; lat<=LAT[5:0]; end
    else if (d_we) begin /* accept write (1-cyc) */ end
  end

  // ---- BLITTER: hammer single-beat reads continuously (model heavy staging). It
  // (re)asserts b_rd whenever it isn't currently being served, and drops it for the
  // accept cycle, immediately re-requesting — i.e. it ALWAYS wants the bus.
  reg [31:0] blt_done=0;
  always @(posedge clk) begin
    if (reset) begin b_rd<=1'b0; blt_done<=0; end
    else begin
      if (b_grant && d_dready) begin            // blitter beat delivered -> one read done
        blt_done <= blt_done + 32'd1;
        b_rd <= 1'b1;                            // immediately want another (continuous)
      end else if (!b_busy && b_rd) begin
        // command was accepted (left G_BLT); deassert for the in-flight read, the
        // grant-route will deliver the beat, then we re-assert above.
        b_rd <= 1'b0;
      end else if (!b_rd) begin
        b_rd <= 1'b1;                            // keep asking
      end
    end
  end

  // ---- SCANOUT measurement: periodically WANT the bus, gate rdr_rd on !rdr_busy
  // (faithful real-reader pattern), measure grant latency, verify every beat.
  integer want_cyc, lat_cyc, maxlat=0, n, k, errs=0, bursts=0;
  // Deadline budget: the scanout-strict arbiter cannot abort a blitter single-beat
  // read already in flight (that would desync the f2h beat — the original hazard),
  // so the irreducible worst case is ONE in-flight blitter read (~LAT + a few cyc).
  // The BUGGY lend-then-commit arbiter exceeds this because after each blitter beat
  // it returns to G_READER and immediately RE-LENDS to the (continuously-asking)
  // blitter before the busy-gated scanout can grab the freed cycle -> latency grows
  // well past one transaction. Budget = LAT + small margin: met by scanout-strict,
  // blown by the buggy re-lend.
  localparam integer SCANOUT_DEADLINE = LAT + 12;
  initial begin
    repeat(8) @(posedge clk); reset<=0;
    repeat(20) @(posedge clk);                 // let the blitter ramp into continuous load
    for (n=0; n<60; n=n+1) begin
      // the scanout now WANTS the bus. start the latency clock.
      lat_cyc = 0;
      // gate-on-busy: assert rd only when the arbiter shows the bus free to us.
      while (r_busy) begin @(posedge clk); lat_cyc=lat_cyc+1;
        if (lat_cyc>5000) begin $display("RESULT: FAIL (SCANOUT STARVED %0d cyc)",lat_cyc); $finish; end end
      r_addr<=29'h07408000; r_burst<=8'd80; r_rd<=1'b1;
      @(posedge clk); lat_cyc=lat_cyc+1;
      // wait for our command to be accepted (granted + bus free for us)
      while (!(r_grant && !r_busy)) begin
        // re-assert if a transient busy forced us off (shouldn't, scanout-strict)
        @(posedge clk); lat_cyc=lat_cyc+1;
        if (lat_cyc>5000) begin $display("RESULT: FAIL (SCANOUT cmd never accepted)"); $finish; end
      end
      r_rd<=1'b0;
      if (lat_cyc > maxlat) maxlat = lat_cyc;
      // drain the 80-beat burst, checking each beat routes to scanout intact
      for (k=0;k<80;k=k+1) begin @(posedge clk);
        while(!(d_dready && r_grant)) @(posedge clk);
        if (d_dout !== mem[(29'h07408000-29'h07400000)+k]) errs=errs+1; end
      bursts=bursts+1;
      repeat(50) @(posedge clk);               // gap between scanline fetches
    end
    $display("=== scanout bursts=%0d  errs=%0d  max grant latency=%0d cyc (deadline=%0d)  blitter reads=%0d ===",
             bursts, errs, maxlat, SCANOUT_DEADLINE, blt_done);
    if (errs!=0)                  $display("RESULT: FAIL (scanout beat misrouted)");
    else if (maxlat>SCANOUT_DEADLINE) $display("RESULT: FAIL (scanout grant latency %0d > deadline %0d -> underflow risk)", maxlat, SCANOUT_DEADLINE);
    else if (blt_done < 32'd10)   $display("RESULT: FAIL (blitter starved/deadlock: only %0d reads)", blt_done);
    else                          $display("RESULT: PASS (scanout bounded latency %0d, blitter progressed %0d reads)", maxlat, blt_done);
    $finish;
  end
  initial begin #50000000 $display("RESULT: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire
