// tb_sdram_ctrl.sv — validate the REAL rtl/sdram.sv (burst-4 read + column-low
// address map) against a command-level chip model (sdram_chip_model.sv).
//
// Proves (logically, not silicon-timing):
//   * write/read use the SAME address map (round-trip coherent),
//   * a burst read returns the 4 consecutive words as one 64-bit beat in the
//     right lane order (word k -> dout64[k*16 +: 16]),
//   * beats at different rows/banks/columns all round-trip,
//   * the FSM makes progress (no deadlock; ready handshake works).
`timescale 1ns/1ps
`default_nettype none

module tb_sdram_ctrl;
  reg clk=0; always #5 clk=~clk;   // 100 MHz

  reg         init=1;
  reg  [26:0] addr=0;
  reg  [15:0] din=0;
  reg         we=0, rd=0;
  wire [15:0] dout;
  wire [63:0] dout64;
  wire        ready;

  // SDRAM chip nets
  wire [15:0] DQ;
  wire [12:0] A;
  wire        DQML, DQMH;
  wire [1:0]  BA;
  wire        nCS, nWE, nRAS, nCAS, CLK, CKE;

  // BURST_BEATS=1: this tb predates the line-width param and expects ONE `ready`
  // pulse per single-beat read (legacy behavior).
  sdram_psx #(.BURST_BEATS(1)) dut (
    .init(init), .clk(clk),
    .SDRAM_DQ(DQ), .SDRAM_A(A), .SDRAM_DQML(DQML), .SDRAM_DQMH(DQMH),
    .SDRAM_BA(BA), .SDRAM_nCS(nCS), .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS),
    .SDRAM_nCAS(nCAS), .SDRAM_CLK(CLK), .SDRAM_CKE(CKE),
    .wtbt(2'b11), .addr(addr), .dout(dout), .dout64(dout64),
    .dout_ready(), .din(din), .din64(64'd0), .we(we), .we_burst(1'b0), .rd(rd), .ready(ready)
  );

  sdram_chip_model chip (
    .clk(clk), .DQ(DQ), .A(A), .BA(BA),
    .nCS(nCS), .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE), .CKE(CKE),
    .DQML(DQML), .DQMH(DQMH)
  );

  integer errors=0;

  task wait_ready; begin
    @(posedge clk);
    while (!ready) @(posedge clk);
  end endtask

  // single-word write through the controller
  task wr(input [26:0] a, input [15:0] d); begin
    @(posedge clk); addr<=a; din<=d; we<=1;
    @(posedge clk); we<=0;
    wait_ready;
  end endtask

  // one burst read of the beat at byte address a (8-byte aligned)
  task rdbeat(input [26:0] a, output [63:0] beat); begin
    @(posedge clk); addr<=a; rd<=1;
    @(posedge clk); rd<=0;
    wait_ready;
    beat = dout64;
  end endtask

  task check_beat(input [26:0] base, input [63:0] exp);
    reg [63:0] got;
    begin
      rdbeat(base, got);
      if (got !== exp) begin
        $display("  FAIL beat @%h: got %h exp %h", base, got, exp);
        errors = errors + 1;
      end else
        $display("  ok   beat @%h = %h", base, got);
    end
  endtask

  // a few beat byte-bases chosen to exercise different col/bank/row fields:
  //   col = a[9:1], bank = a[11:10], row = a[24:12]
  localparam [26:0] B0 = 27'h0000000; // row0 bank0 col0
  localparam [26:0] B1 = 27'h0000010; // row0 bank0 col8   (same row, diff col)
  localparam [26:0] B2 = 27'h0000400; // row0 bank1 col0   (diff bank)
  localparam [26:0] B3 = 27'h0123450 & 27'h7FFFFF8; // some high row/bank/col, beat-aligned

  reg [63:0] beat;
  integer k;
  initial begin
    repeat (4) @(posedge clk);
    init<=0;

    // wait for controller startup to finish (ready stays high at idle)
    wait_ready; repeat (4) @(posedge clk);

    // write 4 distinct words into each beat (word k = base_tag + k)
    write_beat(B0, 16'hA000);
    write_beat(B1, 16'hB000);
    write_beat(B2, 16'hC000);
    write_beat(B3, 16'hD000);

    $display("[tb_sdram_ctrl] burst readback:");
    check_beat(B0, beat_of(16'hA000));
    check_beat(B1, beat_of(16'hB000));
    check_beat(B2, beat_of(16'hC000));
    check_beat(B3, beat_of(16'hD000));

    if (errors==0) $display("RESULT: PASS (burst-4 read + column-low map round-trip)");
    else           $display("RESULT: FAIL (%0d errors)", errors);
    $finish;
  end

  // helper: a beat whose 4 words are tag+0, tag+1, tag+2, tag+3
  function [63:0] beat_of(input [15:0] tag);
    beat_of = {tag+16'd3, tag+16'd2, tag+16'd1, tag};
  endfunction

  task write_beat(input [26:0] base, input [15:0] tag);
    integer j;
    begin
      for (j=0;j<4;j=j+1) wr(base + j*2, tag + j[15:0]);
    end
  endtask

  // safety timeout
  initial begin #500000; $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
