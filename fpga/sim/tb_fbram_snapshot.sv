// tb_fbram_snapshot.sv — unit test for fbram_snapshot, the vblank work->scan copy
// controller for the double-buffered comp_fbram. Drives the REAL comp_fbram: the work
// buffer is filled via the composite write port; the scanout (snapshot) buffer must be
// EMPTY (X) until a snapshot runs, then bit-exact equal to the work buffer afterward.
// This proves the tear-free decoupling: scanout content changes only at snapshot time.
// Copyright (C) 2026 — GPL-3.0
`timescale 1ns/1ps
`default_nettype none
module tb_fbram_snapshot;
  localparam integer NQW = 16;     // small framebuffer for a fast test
  localparam integer AW  = 15;

  reg clk=0; always #5 clk=~clk;
  reg rst=1;

  // composite write into the work buffer
  reg          wr_en=0; reg [AW-1:0] wr_qw=0; reg [1:0] wr_lane=0; reg [15:0] wr_pix=0;
  // work read port: muxed between (unused here) composite RMW and the snapshot controller
  wire         snap_rd_en;  wire [AW-1:0] snap_rd_qw;  wire [63:0] rd_qword;
  // scan read port (verification)
  reg          scan_rd_en=0; reg [AW-1:0] scan_rd_qw=0; wire [63:0] scan_rd_qword;
  // snapshot write port (driven by the controller)
  wire         snap_we; wire [AW-1:0] snap_qw; wire [63:0] snap_qword;

  reg          start=0; wire busy;

  comp_fbram #(.FB_QWORDS(NQW), .AW(AW)) u_fbram(
    .clk(clk),
    .wr_en(wr_en), .wr_qw(wr_qw), .wr_lane(wr_lane), .wr_pix(wr_pix),
    .rd_en(snap_rd_en), .rd_qw(snap_rd_qw), .rd_qword(rd_qword),
    .scan_rd_en(scan_rd_en), .scan_rd_qw(scan_rd_qw), .scan_rd_qword(scan_rd_qword),
    .snap_we(snap_we), .snap_qw(snap_qw), .snap_qword(snap_qword));

  fbram_snapshot #(.FB_QWORDS(NQW), .AW(AW)) u_snap(
    .clk(clk), .rst(rst), .start(start), .busy(busy),
    .rd_en(snap_rd_en), .rd_qw(snap_rd_qw), .rd_qword(rd_qword),
    .snap_we(snap_we), .snap_qw(snap_qw), .snap_qword(snap_qword));

  integer errs=0; integer q, l, guard;

  function [15:0] vexp(input integer qq, input integer ll);
    vexp = 16'((qq*4 + ll) ^ 16'h5A3C);
  endfunction

  task wr1(input integer qq, input integer ll);
    begin
      @(negedge clk); wr_en<=1; wr_qw<=qq[AW-1:0]; wr_lane<=ll[1:0]; wr_pix<=vexp(qq,ll);
      @(negedge clk); wr_en<=0;
    end
  endtask

  task scanrd(input integer qq);
    begin
      @(negedge clk); scan_rd_en<=1; scan_rd_qw<=qq[AW-1:0];
      @(negedge clk); scan_rd_en<=0;
    end
  endtask

  initial begin
    @(negedge clk); rst<=0; @(negedge clk);

    // 1) Fill the WORK buffer (composite port) with a known pattern.
    for (q=0; q<NQW; q=q+1) for (l=0; l<4; l=l+1) wr1(q, l);

    // 2) Before any snapshot, the scanout buffer is empty: scan reads must be X.
    scanrd(5);
    if (scan_rd_qword === {vexp(5,3),vexp(5,2),vexp(5,1),vexp(5,0)}) begin
      errs=errs+1; $display("PRE-SNAP scan q5 already equals work (no decoupling)"); end

    // 3) Run a snapshot: pulse start, wait for busy to fall.
    @(negedge clk); start<=1; @(negedge clk); start<=0;
    if (!busy) begin errs=errs+1; $display("BUSY did not assert after start"); end
    guard=0;
    while (busy) begin @(negedge clk); guard=guard+1;
      if (guard>10000) begin $display("RESULT: FAIL (SNAP busy hung)"); $finish; end
    end

    // 4) After the snapshot, the scanout buffer is bit-exact equal to the work buffer.
    for (q=0; q<NQW; q=q+1) begin
      scanrd(q);
      for (l=0; l<4; l=l+1)
        if (scan_rd_qword[l*16 +: 16] !== vexp(q,l)) begin
          errs=errs+1;
          $display("POST-SNAP q=%0d lane=%0d got %h exp %h", q, l, scan_rd_qword[l*16+:16], vexp(q,l));
        end
    end

    if (errs==0) $display("RESULT: PASS"); else $display("RESULT: FAIL errs=%0d", errs);
    $finish;
  end

  initial begin #2000000; $display("RESULT: FAIL TIMEOUT"); $finish; end
endmodule
`default_nettype wire
