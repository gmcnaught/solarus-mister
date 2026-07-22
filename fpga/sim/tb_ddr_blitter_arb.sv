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
  // tbd_done: this file hosts several independent top-level TBs (tb_deadlock,
  // tb_burst, tb_3way) and iverilog's $finish is GLOBAL -- it halts the WHOLE
  // simulation the instant ANY one of them calls it, not just the caller. So
  // each TB below signals completion via a `done` latch instead of calling
  // $finish itself; tb_arb_finish_gate (end of file) waits for every TB's
  // latch before issuing the one real $finish, so a fast TB (tb_burst
  // completes in ~1.5us) can never silently truncate a slower one again.
  reg tbd_done = 1'b0;
  initial begin : tbd_main
    r_burst=0;r_addr=0;r_rd=0;r_din=0;r_be=8'hFF;r_we=0;
    repeat(6)@(posedge clk); reset<=0;
    for(n=0;n<150;n=n+1) begin
      repeat(300)@(posedge clk);            // reader idle -> producer fills
      gap=0;
      while(r_busy) begin @(posedge clk); gap=gap+1; if(gap>5000) begin $display("DEADLOCK: reader stuck %0d cyc",gap); tbd_done<=1'b1; disable tbd_main; end end
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
    tbd_done <= 1'b1;
  end
  initial begin #60000000 if (!tbd_done) begin $display("RESULT: FAIL (timeout/hang)"); tbd_done<=1'b1; end end
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
  // tbb_done: see tbd_done comment in tb_deadlock -- $finish is GLOBAL across
  // this file's several independent top-level TBs, so signal completion via
  // a latch and let tb_arb_finish_gate (end of file) issue the one real
  // $finish once every TB (incl. tb_3way) has actually finished.
  reg tbb_done = 1'b0;
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
    tbb_done <= 1'b1;
  end
  initial begin #200000 if (!tbb_done) begin $display("RESULT: FAIL (timeout/hang in tb_burst)"); tbb_done<=1'b1; end end
endmodule
`default_nettype wire

// ---------------------------------------------------------------------------
// tb_3way — Stage 5 Phase 2 hardening: ALL THREE masters (reader/scanout/
// blitter) contending concurrently against one shared behavioral DDR model.
//
// Prior TBs in this file (tb_deadlock, tb_burst) only ever drive TWO masters
// (reader+blitter); the scanout leg (scn_*, added when ddr_blitter_arb grew
// from 2 to 3 masters for the FB->DDR3 scanout adapter) has never been
// exercised alongside a live reader AND a live blitter at the same time. This
// TB closes that gap.
//
// Workload (each master gets its OWN disjoint memory region so any beat
// misrouting between grants shows up immediately as a data mismatch, not a
// silent pass):
//   reader  (highest prio, default owner): short 1-4 beat bursts, fixed addr
//            R_BASE, with a real idle gap between bursts (periodic, NOT
//            saturated) -- this is what lets scanout/blitter make progress.
//   scanout (mid prio, read-only): fixed 80-beat line bursts (LINE_QW, see
//            ddr3_scan_adapter.sv), fixed addr S_BASE, re-issued back-to-back
//            continuously (active-scan line fetching never idles on its own).
//   blitter (lowest prio): periodic 4-16 beat bursts, fixed addr B_BASE, with
//            a modest idle gap, holding blt_rd asserted while it waits its
//            turn (real borrow behaviour).
//
// Assertions (see the RESULT: line + FAIL: lines for which, if any, tripped):
//   1. No deadlock: every master completes >= its minimum transaction count
//      within the run window (bounded by a hard watchdog).
//   2. Data integrity: every beat returned to a master's own grant equals
//      that master's own region's expected content (proves no cross-routing
//      under 3-way contention).
//   3. Scanout burst integrity: every scanout burst returns EXACTLY 80 beats
//      on scn_grant with the grant never dropping mid-burst (checked by
//      confirming scn_grant has released within 1 cycle of the 80th beat --
//      i.e. no beat was stolen/short/over-run).
//   4. Blitter not starved: despite sitting below scanout AND the reader,
//      the blitter completes >= B_MIN bursts (B_MIN>0) in the window; its
//      max grant-wait gap is reported (informational).
//   5. Priority sanity: the reader's max wait from "wants the bus" to
//      "granted" is bounded well under one worst-case foreign burst
//      (scanout's 80 beats + DDR latency + FSM overhead) -- i.e. the reader
//      is never stuck behind more than the ONE burst in flight when it
//      asks, exactly as the arbiter's request-gated-grant design promises.
// ---------------------------------------------------------------------------
`default_nettype none
module tb_3way;
  reg clk = 0, reset = 1;
  always #5 clk = ~clk;
  integer cyc = 0;
  always @(posedge clk) if (!reset) cyc <= cyc + 1;
  reg done = 1'b0;

  // ---- reader (rdr_*) ----
  reg  [7:0]  r_burst = 8'd0;
  reg  [28:0] r_addr  = 29'd0;
  reg         r_rd    = 1'b0;
  reg  [63:0] r_din   = 64'd0;
  reg  [7:0]  r_be    = 8'hFF;
  reg         r_we    = 1'b0;
  wire        r_busy, r_grant;

  // ---- scanout (scn_*, read-only) ----
  reg  [7:0]  s_burst = 8'd0;
  reg  [28:0] s_addr  = 29'd0;
  reg         s_rd    = 1'b0;
  wire        s_busy, s_grant;

  // ---- blitter (blt_*) ----
  reg  [7:0]  b_burst = 8'd0;
  reg  [28:0] b_addr  = 29'd0;
  reg         b_rd    = 1'b0;
  reg  [63:0] b_din   = 64'd0;
  reg  [7:0]  b_be    = 8'hFF;
  reg         b_we    = 1'b0;
  wire        b_busy, b_grant;

  // ---- shared DDR (f2h) port ----
  reg         d_busy = 1'b0, d_dready = 1'b0;
  reg  [63:0] d_dout = 64'd0;
  wire [7:0]  dd_burst;
  wire [28:0] dd_addr;
  wire        dd_rd, dd_we;
  wire [63:0] dd_din;
  wire [7:0]  dd_be;
  wire [2:0]  dbg_w;

  ddr_blitter_arb #(.ENABLE(1'b1)) dut (
    .clk(clk), .reset(reset),
    .rdr_burstcnt(r_burst), .rdr_addr(r_addr), .rdr_rd(r_rd), .rdr_din(r_din),
    .rdr_be(r_be), .rdr_we(r_we), .rdr_busy(r_busy), .rdr_grant(r_grant),
    .blt_burstcnt(b_burst), .blt_addr(b_addr), .blt_rd(b_rd), .blt_din(b_din),
    .blt_be(b_be), .blt_we(b_we), .blt_busy(b_busy), .blt_grant(b_grant),
    .scn_burstcnt(s_burst), .scn_addr(s_addr), .scn_rd(s_rd),
    .scn_busy(s_busy), .scn_grant(s_grant),
    .ddram_busy(d_busy), .ddram_dout_ready(d_dready),
    .ddram_burstcnt(dd_burst), .ddram_addr(dd_addr), .ddram_rd(dd_rd),
    .ddram_din(dd_din), .ddram_be(dd_be), .ddram_we(dd_we), .dbg(dbg_w)
  );

  // ---- disjoint per-master memory regions (indices are addr - BASE) ----
  localparam [28:0] BASE   = 29'h07400000;
  localparam [28:0] R_BASE = BASE;                 // reader region:  idx 0..15
  localparam [28:0] S_BASE = BASE + 29'h0000_1000;  // scanout region: idx 4096..4175
  localparam [28:0] B_BASE = BASE + 29'h0000_2000;  // blitter region: idx 8192..8207
  localparam integer R_IDX = 0;
  localparam integer S_IDX = 4096;
  localparam integer B_IDX = 8192;
  localparam integer SCN_LEN = 80;                  // LINE_QW (ddr3_scan_adapter.sv)

  reg [63:0] mem [0:16383];
  integer mi;
  initial begin
    for (mi = 0; mi < 16; mi = mi + 1)
      mem[R_IDX + mi] = 64'hAAAA_0000_0000_0000 | mi[15:0];
    for (mi = 0; mi < SCN_LEN; mi = mi + 1)
      mem[S_IDX + mi] = 64'hBBBB_0000_0000_0000 | mi[15:0];
    for (mi = 0; mi < 16; mi = mi + 1)
      mem[B_IDX + mi] = 64'hCCCC_0000_0000_0000 | mi[15:0];
  end

  // Behavioral DDR model (same shape as tb_deadlock/tb_burst): one outstanding
  // command at a time, ddram_busy held from accept through full drain,
  // fixed 3-cycle latency then one beat/cycle back-to-back.
  reg [7:0]  beats_left;
  reg [28:0] baddr;
  reg [2:0]  lat_left;
  always @(posedge clk) begin
    d_dready <= 1'b0;
    if (reset) begin
      d_busy <= 1'b0; beats_left <= 8'd0; lat_left <= 3'd0;
    end else if (!d_busy) begin
      if (dd_rd) begin
        beats_left <= dd_burst; baddr <= dd_addr; lat_left <= 3'd3; d_busy <= 1'b1;
      end else if (dd_we) begin
        mem[dd_addr - BASE] <= dd_din; d_busy <= 1'b1; lat_left <= 3'd2;
      end
    end else if (lat_left != 0) begin
      lat_left <= lat_left - 3'd1;
    end else if (beats_left != 0) begin
      d_dready   <= 1'b1;
      d_dout     <= mem[baddr - BASE];
      baddr      <= baddr + 29'd1;
      beats_left <= beats_left - 8'd1;
      if (beats_left == 8'd1) d_busy <= 1'b0;
    end else begin
      d_busy <= 1'b0;
    end
  end

  // ---- reader driver: periodic short bursts w/ real idle gaps ----
  integer r_bursts = 0, r_errors = 0, r_maxwait = 0;
  initial begin : reader_proc
    integer k, r_len, r_gap, r_waitstart;
    r_addr = R_BASE; r_burst = 0; r_rd = 0; r_din = 0; r_be = 8'hFF; r_we = 0;
    @(negedge reset); repeat(3) @(posedge clk);
    while (!done) begin
      r_gap = 50 + (r_bursts % 5) * 10;          // 50,60,70,80,90 cyc idle gap
      repeat(r_gap) @(posedge clk);
      r_len = 1 + (r_bursts % 4);                 // 1,2,3,4-beat bursts
      r_waitstart = cyc;
      while (r_busy) @(posedge clk);
      r_addr <= R_BASE; r_burst <= r_len[7:0]; r_rd <= 1'b1;
      @(posedge clk);
      while (!(r_grant && !d_busy)) @(posedge clk);
      r_rd <= 1'b0;
      if ((cyc - r_waitstart) > r_maxwait) r_maxwait = cyc - r_waitstart;
      for (k = 0; k < r_len; k = k + 1) begin
        @(posedge clk);
        while (!(d_dready && r_grant)) @(posedge clk);
        if (d_dout !== mem[R_IDX + k]) begin
          r_errors = r_errors + 1;
          $display("FAIL: reader beat mismatch idx=%0d got=%h exp=%h", k, d_dout, mem[R_IDX+k]);
        end
      end
      r_bursts = r_bursts + 1;
    end
  end

  // ---- scanout driver: fixed 80-beat line bursts, back-to-back ----
  integer s_bursts = 0, s_errors = 0;
  initial begin : scan_proc
    integer k;
    s_addr = S_BASE; s_burst = 0; s_rd = 0;
    @(negedge reset); repeat(3) @(posedge clk);
    while (!done) begin
      s_addr <= S_BASE; s_burst <= SCN_LEN[7:0]; s_rd <= 1'b1;
      @(posedge clk);
      while (dut.state !== dut.G_SCN_RD) @(posedge clk);
      s_rd <= 1'b0;
      for (k = 0; k < SCN_LEN; k = k + 1) begin
        @(posedge clk);
        while (!(d_dready && s_grant)) @(posedge clk);
        if (d_dout !== mem[S_IDX + k]) begin
          s_errors = s_errors + 1;
          $display("FAIL: scanout beat mismatch idx=%0d got=%h exp=%h", k, d_dout, mem[S_IDX+k]);
        end
      end
      // grant must have released within one cycle of the 80th beat: proves
      // the burst was exactly LINE_QW long and the grant wasn't over-held.
      @(posedge clk);
      if (s_grant) begin
        s_errors = s_errors + 1;
        $display("FAIL: scanout grant still held past beat %0d (over-run / not released)", SCN_LEN);
      end
      s_bursts = s_bursts + 1;
    end
  end

  // ---- blitter driver: periodic 4-16 beat bursts, real idle gaps ----
  integer b_bursts = 0, b_errors = 0, b_maxgap = 0;
  initial begin : blt_proc
    integer k, b_len, b_gap, b_waitstart;
    b_addr = B_BASE; b_burst = 0; b_rd = 0; b_din = 0; b_be = 8'hFF; b_we = 0;
    @(negedge reset); repeat(4) @(posedge clk);
    while (!done) begin
      b_gap = 20 + (b_bursts % 4) * 10;          // 20,30,40,50 cyc idle gap
      repeat(b_gap) @(posedge clk);
      b_len = 4 + (b_bursts % 5) * 3;             // 4,7,10,13,16-beat bursts
      b_waitstart = cyc;
      // NOTE: do not gate on blt_busy here -- blt_busy is asserted whenever
      // state is anything other than G_BLT/G_BLT_WR (i.e. almost always,
      // until the blitter is ALREADY granted), so waiting on it first would
      // never release. Just assert b_rd (as the real borrowing master does)
      // and hold it until the arbiter grants a slot, exactly like tb_burst's
      // own blitter driver above (which likewise never waits on blt_busy).
      b_addr <= B_BASE; b_burst <= b_len[7:0]; b_rd <= 1'b1;
      @(posedge clk);
      while (dut.state !== dut.G_BLT_RD) @(posedge clk);
      b_rd <= 1'b0;
      if ((cyc - b_waitstart) > b_maxgap) b_maxgap = cyc - b_waitstart;
      for (k = 0; k < b_len; k = k + 1) begin
        @(posedge clk);
        while (!(d_dready && b_grant)) @(posedge clk);
        if (d_dout !== mem[B_IDX + k]) begin
          b_errors = b_errors + 1;
          $display("FAIL: blitter beat mismatch idx=%0d got=%h exp=%h", k, d_dout, mem[B_IDX+k]);
        end
      end
      b_bursts = b_bursts + 1;
    end
  end

  // ---- run window, final tally, verdict ----
  reg tb3_done = 1'b0;
  localparam integer RUN_CYCLES = 30000;
  // Reader-wait bound (assertion 5): the worst case is the reader asking
  // right after some OTHER master has just started its burst, so it must
  // wait out that whole burst. The longest possible foreign burst is the
  // scanout's SCN_LEN(80) beats + 3-cycle DDR latency + a few cycles of FSM
  // command/settle overhead. Double it for margin -> generous but still a
  // real bound (an actual starvation bug would blow through this easily).
  localparam integer READER_WAIT_BOUND = 2 * (SCN_LEN + 3 + 10);
  localparam integer R_MIN = 100;   // reader bursts expected over the window
  localparam integer S_MIN = 50;    // scanout line-bursts expected
  localparam integer B_MIN = 5;     // blitter bursts expected despite low prio

  integer errs;
  initial begin
    reset = 1'b1; repeat(6) @(posedge clk); reset <= 1'b0;
    repeat(RUN_CYCLES) @(posedge clk);
    done = 1'b1;
    repeat(300) @(posedge clk);   // drain grace: let any in-flight burst finish

    $display("=== tb_3way: reader bursts=%0d errors=%0d maxwait=%0d | scanout bursts=%0d errors=%0d | blitter bursts=%0d errors=%0d maxgap=%0d ===",
             r_bursts, r_errors, r_maxwait, s_bursts, s_errors, b_bursts, b_errors, b_maxgap);

    errs = 0;
    if (r_bursts < R_MIN) begin
      errs = errs + 1;
      $display("FAIL: reader completed only %0d bursts (min %0d) — progress/deadlock", r_bursts, R_MIN);
    end
    if (s_bursts < S_MIN) begin
      errs = errs + 1;
      $display("FAIL: scanout completed only %0d bursts (min %0d) — progress/deadlock", s_bursts, S_MIN);
    end
    if (b_bursts < B_MIN) begin
      errs = errs + 1;
      $display("FAIL: blitter completed only %0d bursts (min %0d) — starved under contention", b_bursts, B_MIN);
    end
    if (r_errors != 0) begin
      errs = errs + 1;
      $display("FAIL: reader data-integrity errors=%0d", r_errors);
    end
    if (s_errors != 0) begin
      errs = errs + 1;
      $display("FAIL: scanout data-integrity/burst-length errors=%0d", s_errors);
    end
    if (b_errors != 0) begin
      errs = errs + 1;
      $display("FAIL: blitter data-integrity errors=%0d", b_errors);
    end
    if (r_maxwait > READER_WAIT_BOUND) begin
      errs = errs + 1;
      $display("FAIL: reader max wait %0d cyc exceeds bound %0d cyc — priority inversion", r_maxwait, READER_WAIT_BOUND);
    end

    if (errs == 0)
      $display("RESULT: PASS (3way contention: rdr=%0d/scn=%0d/blt=%0d bursts, 0 data errors, rdr_maxwait=%0d/%0d cyc, blt_maxgap=%0d cyc)",
                r_bursts, s_bursts, b_bursts, r_maxwait, READER_WAIT_BOUND, b_maxgap);
    else
      $display("RESULT: FAIL (%0d assertion(s) failed in tb_3way)", errs);
    tb3_done <= 1'b1;
  end
  initial begin #2000000 if (!tb3_done) begin $display("RESULT: FAIL (timeout/hang in tb_3way)"); tb3_done<=1'b1; end end
endmodule
`default_nettype wire

// ---------------------------------------------------------------------------
// tb_arb_finish_gate — coordinates this file's THREE independent top-level
// testbenches (tb_deadlock, tb_burst, tb_3way). iverilog/vvp's $finish is a
// GLOBAL system task: it halts the ENTIRE simulation the instant any one
// process calls it, not just the calling module's. Before this gate existed,
// tb_burst (the fastest of the three, completing in ~1.5us) silently cut off
// tb_deadlock before it ever printed its own RESULT line -- and would have
// done the same to tb_3way, which needs tens of thousands of cycles to drive
// meaningful 3-way contention. Each TB above now sets a `done` latch instead
// of calling $finish itself; this gate waits for all three latches (via
// ordinary hierarchical reference -- Icarus resolves sibling top-level module
// names as valid hierarchy roots) and only then performs the single real
// $finish, so every TB's verdict genuinely gets to run and print.
// ---------------------------------------------------------------------------
`default_nettype none
module tb_arb_finish_gate;
  initial begin
    wait (tb_deadlock.tbd_done && tb_burst.tbb_done && tb_3way.tb3_done);
    $finish;
  end
  // hard backstop: should be unreachable (each TB above has its own, shorter,
  // internal watchdog that latches `done` on timeout) -- just don't let vvp
  // hang forever if that ever regresses.
  initial begin #70000000 $display("RESULT: FAIL (finish-gate timeout/hang)"); $finish; end
endmodule
`default_nettype wire
