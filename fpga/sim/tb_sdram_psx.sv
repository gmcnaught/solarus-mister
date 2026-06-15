// tb_sdram_psx.sv — PSX-pattern line reads: BURST_BEATS beats (each a BL=4 read,
// 4 words) assembled after one ACTIVE. BURST_BEATS=2 => 128-bit line. Page-open reuse.
`timescale 1ns/1ps
`default_nettype none
module tb_sdram_psx;
  reg clk=0; always #5 clk=~clk;          // 100 MHz
  reg          init=1;
  reg  [26:0]  addr=0;
  reg  [15:0]  din=0;
  reg          we=0, rd=0;
  wire [63:0]  dout64;
  wire         dout_ready;                 // NEW: per-beat strobe
  wire         ready;                       // line complete / accept next

  wire [15:0] DQ; wire [12:0] A; wire DQML,DQMH; wire [1:0] BA;
  wire nCS,nWE,nRAS,nCAS,CLK,CKE;

  sdram_psx #(.BURST_BEATS(2)) dut (
    .init(init), .clk(clk),
    .SDRAM_DQ(DQ), .SDRAM_A(A), .SDRAM_DQML(DQML), .SDRAM_DQMH(DQMH),
    .SDRAM_BA(BA), .SDRAM_nCS(nCS), .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS),
    .SDRAM_nCAS(nCAS), .SDRAM_CLK(CLK), .SDRAM_CKE(CKE),
    .wtbt(2'b11), .addr(addr), .dout(), .dout64(dout64),
    .dout_ready(dout_ready), .din(din), .we(we), .rd(rd), .ready(ready)
  );
  sdram_chip_model chip (
    .clk(clk), .DQ(DQ), .A(A), .BA(BA),
    .nCS(nCS), .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE), .CKE(CKE),
    .DQML(DQML), .DQMH(DQMH), .proto_errors()  // read hierarchically as chip.proto_errors
  );

  integer errors=0;
  task wait_ready; begin @(posedge clk); while(!ready) @(posedge clk); end endtask

  // single-word write through the controller (same map as v3.0 tb)
  task wr(input [26:0] a, input [15:0] d); begin
    @(posedge clk); addr<=a; din<=d; we<=1;
    @(posedge clk); we<=0; wait_ready;
  end endtask

  // line read: capture BURST_BEATS beats, return them packed
  reg [63:0] beat [0:7];
  task rd_line(input [26:0] a, input integer n); integer i; begin
    @(posedge clk); addr<=a; rd<=1;
    @(posedge clk); rd<=0;
    for (i=0;i<n;i=i+1) begin
      @(posedge clk); while(!dout_ready) @(posedge clk); beat[i]=dout64;
    end
    wait_ready;
  end endtask

  integer w;
  initial begin
    repeat(4) @(posedge clk); init<=0;
    // let controller startup finish before the first access (same as tb_sdram_ctrl):
    // without this the first write collides with the tail of the init sequence.
    wait_ready; repeat(4) @(posedge clk);
    // seed 8 consecutive words (= 2 beats of 4 words) at a base
    for (w=0; w<8; w=w+1) wr(27'h001000 + (w<<1), 16'hA000 + w[15:0]);
    // read the 2-beat line at the base
    rd_line(27'h001000, 2);
    if (beat[0] !== 64'hA003_A002_A001_A000) begin errors=errors+1; $display("beat0 bad: %h", beat[0]); end
    if (beat[1] !== 64'hA007_A006_A005_A004) begin errors=errors+1; $display("beat1 bad: %h", beat[1]); end

    // Scenario 2: drive MANY back-to-back line reads so enough cycles elapse for
    // at least one AUTO_REFRESH to fire BETWEEN lines (refresh trigger fires when
    // refresh_count > cycles_per_refresh=780 at idle). This proves refresh lands
    // at a line boundary, not mid-line — exercising the proto monitor's
    // AUTO_REFRESH-in-flight check across a refresh window. Re-read the same line
    // each time; every read still round-trips and is invariant-checked.
    for (w=0; w<200; w=w+1) begin
      rd_line(27'h001000, 2);
      if (beat[0] !== 64'hA003_A002_A001_A000) begin errors=errors+1; $display("s2 beat0 bad@%0d: %h", w, beat[0]); end
      if (beat[1] !== 64'hA007_A006_A005_A004) begin errors=errors+1; $display("s2 beat1 bad@%0d: %h", w, beat[1]); end
    end

    if (chip.proto_errors !== 0) begin errors=errors+1; $display("proto_errors=%0d", chip.proto_errors); end
    // non-vacuous: scenario 2 must have actually triggered >=1 AUTO_REFRESH, else the
    // refresh-in-flight invariant was never exercised.
    if (chip.refresh_seen < 1) begin errors=errors+1; $display("refresh path not exercised (refresh_seen=%0d)", chip.refresh_seen); end
    else $display("refresh_seen=%0d (refresh path exercised, all at line boundaries)", chip.refresh_seen);
    $display("errors=%0d", errors);
    $finish;
  end
endmodule
