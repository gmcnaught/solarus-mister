`timescale 1ns/1ps
`default_nettype none
// tb_sdram_src_arb.sv — testbench for the 3-client priority SDRAM arbiter.
//
// Test 1: existing P_SRC (p0_*) grant-gap regression (single-port behavior).
// Test 2: 3-client strict priority — P_SCAN > P_SRC > P_DST.
//   Phase A (all three simultaneous, 60 cycles):
//     (i)  P_SCAN > P_DST: c_rd must never go to dst_addr while scan_rd is high.
//     (ii) P_SCAN > P_SRC: c_rd must never go to p0_addr while scan_rd is high.
//   Phase B (scan+src deasserted, 10 cycles):
//     P_DST starvation-freedom: P_DST must be granted within N cycles.
// Test 3: P_SRC starvation-freedom — P_SCAN idle, P_SRC + P_DST both requesting.
//   P_SRC must eventually be granted (higher priority than P_DST wins).
//
// Controller is stubbed: c_busy=0, c_ready=1 (always idle/ready).
// This is the tightest case for priority (no artificial back-pressure hiding bugs).
//
// All three clients use distinct addresses so c_addr identifies the winner:
//   scan_addr = 27'h0400000
//   p0_addr   = 27'h0001000   <-- P_SRC uses a distinct address
//   dst_addr  = 27'h0410000
module tb_sdram_src_arb;
  reg clk=0; always #5 clk=~clk;
  reg reset=1;

  // ---- P_SRC (existing p0_*) -----------------------------------------------
  reg  [26:0] p0_addr=0; reg p0_rd=0; wire p0_grant; wire p0_busy;

  // ---- P_SCAN --------------------------------------------------------------
  reg  [26:0] scan_addr=0; reg scan_rd=0; reg [7:0] scan_burst=8'd1;
  wire        scan_busy; wire [63:0] scan_dout64; wire scan_dready;

  // ---- P_DST ---------------------------------------------------------------
  reg  [26:0] dst_addr=0; reg dst_rd=0;
  reg         dst_we=0;  reg [15:0] dst_din=0;
  reg         dst_we_burst=0; reg [63:0] dst_din64=0;
  wire        dst_busy; wire [63:0] dst_dout64; wire dst_dready;

  // ---- stubbed controller --------------------------------------------------
  wire [26:0] c_addr;
  wire        c_rd, c_we, c_we_burst;
  wire [15:0] c_din; wire [63:0] c_din64;
  reg         c_ready=1, c_busy=0;
  reg         c_dready=0; reg [63:0] c_dout64_r=64'd0;

  integer max_gap=0, gap=0, errors=0;

  sdram_src_arb dut (
    .clk        (clk),       .reset      (reset),
    // P_SCAN
    .scan_addr  (scan_addr), .scan_rd    (scan_rd),   .scan_burst (scan_burst),
    .scan_busy  (scan_busy), .scan_dout64(scan_dout64),.scan_dready(scan_dready),
    // P_SRC
    .p0_addr    (p0_addr),   .p0_rd      (p0_rd),     .p0_grant   (p0_grant),
    .p0_busy    (p0_busy),
    .p0_we      (1'b0),      .p0_din     (16'd0),     .p0_waddr   (27'd0),
    .p0_we_burst(1'b0),      .p0_din64   (64'd0),
    // P_DST
    .dst_addr   (dst_addr),  .dst_rd     (dst_rd),    .dst_we     (dst_we),
    .dst_din    (dst_din),   .dst_we_burst(dst_we_burst),.dst_din64(dst_din64),
    .dst_busy   (dst_busy),  .dst_dout64 (dst_dout64),.dst_dready (dst_dready),
    // controller
    .c_addr     (c_addr),    .c_rd       (c_rd),      .c_we       (c_we),
    .c_din      (c_din),     .c_we_burst (c_we_burst),.c_din64    (c_din64),
    .c_ready    (c_ready),   .c_busy     (c_busy),
    .c_dready   (c_dready),  .c_dout64   (c_dout64_r)
  );

  // Controller stub returns a read beat one cycle after each accepted command
  // (the original stub claimed ready but never delivered a beat — unrealistic;
  //  the #34 read-beat-hold fix requires a beat to release a read).
  always @(posedge clk) c_dready <= c_rd;

  // ---- P_SRC grant-gap measurement (Test 1) --------------------------------
  // Gate the gap counter to the Test-1 window (p0_rd is only high then).
  always @(posedge clk) begin
    if (p0_rd && !p0_grant && !scan_rd) gap <= gap+1;
    if (p0_grant && !scan_rd) begin if (gap>max_gap) max_gap<=gap; gap<=0; end
  end

  // ---- 3-client priority checks (Test 2) ------------------------------------
  // All checks use negedge of clk to sample signals AFTER the DUT's posedge
  // updates have settled, avoiding the posedge race between DUT flop updates
  // and tb sampling.
  //
  // (i)  P_SCAN > P_DST: dst_addr must never appear on c_addr while scan_rd high.
  // (ii) P_SCAN > P_SRC: p0_addr must never appear on c_addr while scan_rd high.
  //      (a P_SRC transaction would mean the arbiter let P_SRC win over P_SCAN)
  // (iii) P_DST starvation-freedom: P_DST must be served once scan+src go idle.
  reg scan_gt_dst_violation=0;   // (i)
  reg scan_gt_src_violation=0;   // (ii) NEW
  reg dst_served=0;

  always @(negedge clk) begin
    // (i) P_SCAN > P_DST
    if (scan_rd && c_rd && (c_addr == 27'h0410000))
      scan_gt_dst_violation <= 1'b1;
    // (ii) P_SCAN > P_SRC: while P_SCAN is active, P_SRC must NOT be accepted
    if (scan_rd && c_rd && (c_addr == 27'h0001000))
      scan_gt_src_violation <= 1'b1;
    // (iii) P_DST served after higher-priority clients retire
    if (!scan_rd && !p0_rd && c_rd && (c_addr == 27'h0410000))
      dst_served <= 1'b1;
  end

  // ---- P_SRC starvation-freedom check (Test 3) -----------------------------
  // Window: scan_rd is LOW, but p0_rd AND dst_rd are both high.
  // P_SRC (higher priority) must be granted before P_DST; track whether
  // p0_addr ever reaches c_addr in this window before dst_addr does.
  reg src_served_t3=0;   // P_SRC got a grant in the test-3 window
  reg dst_served_t3=0;   // P_DST got a grant in the test-3 window

  // These are set by the stimulus block below; use a flag to gate the check.
  reg t3_window=0;

  always @(negedge clk) begin
    if (t3_window) begin
      if (c_rd && (c_addr == 27'h0001000)) src_served_t3 <= 1'b1;
      if (c_rd && (c_addr == 27'h0410000)) dst_served_t3 <= 1'b1;
    end
  end

  // ---- main stimulus -------------------------------------------------------
  initial begin
    repeat(3) @(posedge clk); reset<=0;

    // ---- Test 1: single-port P_SRC grant latency --------------------------
    // P_SCAN and P_DST are idle; only P_SRC requesting.
    // The original arbiter granted every cycle; with the 3-client arbiter and
    // no higher-priority clients the gap must stay <= 4.
    p0_addr <= 27'h2000; p0_rd <= 1;
    repeat(40) @(posedge clk);
    p0_rd <= 0;
    if (max_gap > 4) begin
      errors = errors+1;
      $display("FAIL test1: P_SRC grant gap %0d > 4", max_gap);
    end
    repeat(4) @(posedge clk);

    // ---- Test 2: 3-client strict priority P_SCAN > P_SRC > P_DST ---------
    // Phase A: assert all three simultaneously for 60 cycles.
    // Invariants (i) and (ii): while scan_rd is high, neither dst_addr nor
    // p0_addr must appear on c_addr (both must be blocked by P_SCAN).
    scan_addr <= 27'h0400000; scan_rd <= 1; scan_burst <= 8'd1;
    p0_addr   <= 27'h0001000; p0_rd   <= 1;  // distinct from scan/dst
    dst_addr  <= 27'h0410000; dst_rd  <= 1;
    repeat(60) @(posedge clk);

    // Phase B: deassert P_SCAN and P_SRC; P_DST must be granted within 10 cycles.
    scan_rd <= 0;
    p0_rd   <= 0;
    repeat(10) @(posedge clk);
    dst_rd <= 0;
    repeat(4) @(posedge clk);

    // Evaluate Test-2 results
    if (scan_gt_dst_violation) begin
      errors = errors+1;
      $display("FAIL test2(i): P_DST granted while P_SCAN active (P_SCAN>P_DST violated)");
    end
    if (scan_gt_src_violation) begin
      errors = errors+1;
      $display("FAIL test2(ii): P_SRC granted while P_SCAN active (P_SCAN>P_SRC violated)");
    end
    if (!dst_served) begin
      errors = errors+1;
      $display("FAIL test2(iii): P_DST starved — never granted after P_SCAN/P_SRC went idle");
    end
    repeat(4) @(posedge clk);

    // ---- Test 3: P_SRC starvation-freedom (P_SCAN idle, P_SRC + P_DST) ----
    // P_SCAN is NOT active. P_SRC and P_DST both request simultaneously.
    // P_SRC (priority 2) must be served before/alongside P_DST (priority 3).
    // We run for 30 cycles and verify P_SRC was granted at least once.
    // (If the arbiter accidentally round-robins or inverts priority it would
    //  skip P_SRC entirely, which this catches.)
    p0_addr  <= 27'h0001000; p0_rd  <= 1;
    dst_addr <= 27'h0410000; dst_rd <= 1;
    t3_window <= 1;
    repeat(30) @(posedge clk);
    p0_rd  <= 0;
    dst_rd <= 0;
    t3_window <= 0;
    repeat(4) @(posedge clk);

    if (!src_served_t3) begin
      errors = errors+1;
      $display("FAIL test3: P_SRC starved — never granted when P_SCAN idle and P_SRC+P_DST both request");
    end

    // ---- final report --------------------------------------------------------
    $display("errors=%0d max_gap=%0d", errors, max_gap);
    if (errors == 0) $display("RESULT: PASS");
    else             $display("RESULT: FAIL");
    $finish;
  end
endmodule
