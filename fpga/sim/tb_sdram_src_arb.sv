`timescale 1ns/1ps
`default_nettype none
module tb_sdram_src_arb;
  reg clk=0; always #5 clk=~clk;
  reg reset=1;
  // port 0 (blitter source) request
  reg  [26:0] p0_addr=0; reg p0_rd=0; wire p0_grant; wire p0_busy;
  // downstream controller-facing (stubbed busy/ready)
  wire [26:0] c_addr; wire c_rd; reg c_ready=1, c_busy=0;
  integer max_gap=0, gap=0, errors=0;

  sdram_src_arb dut (
    .clk(clk), .reset(reset),
    .p0_addr(p0_addr), .p0_rd(p0_rd), .p0_grant(p0_grant), .p0_busy(p0_busy),
    .p0_we(1'b0), .p0_din(16'd0), .p0_waddr(27'd0),   // write port idle (read-only test)
    .c_addr(c_addr), .c_rd(c_rd), .c_we(), .c_din(), .c_ready(c_ready), .c_busy(c_busy)
  );

  // measure gap between p0_rd asserted and p0_grant
  always @(posedge clk) begin
    if (p0_rd && !p0_grant) gap <= gap+1;
    if (p0_grant) begin if (gap>max_gap) max_gap<=gap; gap<=0; end
  end
  initial begin
    repeat(3) @(posedge clk); reset<=0;
    // hold a read request continuously; arbiter must grant within bound
    p0_addr<=27'h2000; p0_rd<=1;
    repeat(40) @(posedge clk);
    p0_rd<=0;
    if (max_gap > 4) begin errors=errors+1; $display("grant gap too large: %0d", max_gap); end
    $display("errors=%0d max_gap=%0d", errors, max_gap);
    $finish;
  end
endmodule
