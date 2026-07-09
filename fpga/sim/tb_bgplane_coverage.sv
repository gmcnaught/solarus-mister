// tb_bgplane_coverage.sv -- unit TB for bgplane_coverage.sv: proves paint-writes set
// bits, bake-FILL writes (wr_clear=1) clear bits, and the registered read matches
// comp_fbram's 1-cycle-later contract.
`timescale 1ns/1ps
`default_nettype none
module tb_bgplane_coverage;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  reg          wr_en, wr_clear, rd_en;
  reg  [14:0]  wr_qw, rd_qw;
  reg  [1:0]   wr_lane;
  wire [3:0]   rd_nibble;

  bgplane_coverage #(.AW(15)) dut (
    .clk(clk), .rst(rst),
    .wr_en(wr_en), .wr_qw(wr_qw), .wr_lane(wr_lane), .wr_clear(wr_clear),
    .rd_en(rd_en), .rd_qw(rd_qw), .rd_nibble(rd_nibble)
  );

  integer errs = 0;
  task check(input [3:0] got, input [3:0] want, input [255:0] msg);
    begin
      if (got !== want) begin
        $display("  FAIL %0s: got=%b want=%b", msg, got, want);
        errs = errs + 1;
      end
    end
  endtask

  task do_write(input [14:0] qw, input [1:0] lane, input clr);
    begin
      @(posedge clk);
      wr_en <= 1'b1; wr_qw <= qw; wr_lane <= lane; wr_clear <= clr;
      @(posedge clk);
      wr_en <= 1'b0;
    end
  endtask

  task do_read(input [14:0] qw, output [3:0] nib);
    begin
      @(posedge clk);
      rd_en <= 1'b1; rd_qw <= qw;
      @(posedge clk);
      rd_en <= 1'b0;
      @(posedge clk);          // registered: valid 1 cyc after the read pulse
      nib = rd_nibble;
    end
  endtask

  reg [3:0] got;
  initial begin
    wr_en=0; wr_clear=0; rd_en=0; wr_qw=0; wr_lane=0; rd_qw=0;
    repeat (4) @(posedge clk); rst <= 0; repeat (4) @(posedge clk);

    // fresh cell (post-rst, all-X in sim but never read before a clear in real use):
    // paint lane 2 of qword 100 -> bit set.
    do_write(15'd100, 2'd2, 1'b0);
    do_read(15'd100, got);
    check(got, 4'b0100, "lane2 set after paint write");

    // paint lane 0 of the SAME qword -> both bits now set, lane1/3 untouched (still 0
    // from the two do_write calls below establishing a known baseline first).
    do_write(15'd100, 2'd0, 1'b0);
    do_read(15'd100, got);
    check(got, 4'b0101, "lane0+lane2 set, lane1/3 still 0");

    // bake-FILL clear (wr_clear=1) on lane 2 -> only that bit clears.
    do_write(15'd100, 2'd2, 1'b1);
    do_read(15'd100, got);
    check(got, 4'b0001, "lane2 cleared by bake-FILL write, lane0 unaffected");

    // a different qword address is untouched by any of the above.
    do_read(15'd200, got);
    check(got, 4'b0000, "untouched qword reads all-zero after rst+clears elsewhere");

    if (errs == 0) $display("RESULT: PASS");
    else           $display("RESULT: FAIL (%0d mismatches)", errs);
    $finish;
  end

  initial begin #100000 $display("RESULT: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire
