`timescale 1ns/1ps
`default_nettype none
// tb_sdram_src_arb.sv — testbench for the 3-client priority SDRAM arbiter.
//
// Test 1: existing P_SRC (p0_*) grant-gap regression (single-port behavior).
// Test 2: 3-client strict priority — P_SCAN > P_SRC > P_DST.
//   - While scan_rd is asserted, the controller address must ALWAYS be scan_addr
//     (P_DST's address must never appear on c_addr when c_rd fires).
//   - Once scan_rd and p0_rd are idle, P_DST must be granted within N cycles
//     (no starvation).
// Controller is stubbed: c_busy=0, c_ready=1 (always idle/ready).
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
  // With c_busy=0 and c_ready=1 always the controller is perpetually idle,
  // so held_read clears on the very next cycle after a grant.  This is the
  // tightest case for priority (no artificial back-pressure hiding bugs).
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

  // ---- P_SRC grant-gap measurement (Test 1) --------------------------------
  // Gate the gap counter to the Test-1 window (p0_rd is only high then).
  always @(posedge clk) begin
    if (p0_rd && !p0_grant && !scan_rd) gap <= gap+1;
    if (p0_grant && !scan_rd) begin if (gap>max_gap) max_gap<=gap; gap<=0; end
  end

  // ---- 3-client priority check (Test 2) ------------------------------------
  // Detect: c_rd fired for DST's address while scan_rd was asserted.
  // Use negedge of clk to sample signals AFTER the DUT's posedge updates
  // have settled.  This avoids the posedge race between DUT flop updates
  // and tb sampling.
  reg priority_violation=0, dst_served=0;
  always @(negedge clk) begin
    if (scan_rd && c_rd && (c_addr == 27'h0410000))
      priority_violation <= 1'b1;
    if (!scan_rd && !p0_rd && c_rd && (c_addr == 27'h0410000))
      dst_served <= 1'b1;
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
    // Invariant: c_rd must never go to dst_addr while scan_rd is high.
    scan_addr <= 27'h0400000; scan_rd <= 1; scan_burst <= 8'd1;
    p0_addr   <= 27'h0001000; p0_rd   <= 1;
    dst_addr  <= 27'h0410000; dst_rd  <= 1;
    repeat(60) @(posedge clk);

    // Phase B: deassert P_SCAN and P_SRC; P_DST must be granted within 10 cycles.
    scan_rd <= 0;
    p0_rd   <= 0;
    repeat(10) @(posedge clk);
    dst_rd <= 0;
    repeat(4) @(posedge clk);

    if (priority_violation) begin
      errors = errors+1;
      $display("FAIL test2: P_DST granted while P_SCAN active (priority violation)");
    end
    if (!dst_served) begin
      errors = errors+1;
      $display("FAIL test2: P_DST starved — never granted after P_SCAN/P_SRC went idle");
    end

    // ---- final report -----------------------------------------------------
    $display("errors=%0d max_gap=%0d", errors, max_gap);
    if (errors == 0) $display("RESULT: PASS");
    else             $display("RESULT: FAIL");
    $finish;
  end
endmodule
