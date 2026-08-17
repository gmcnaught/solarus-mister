// tb_fbram.sv — unit test for comp_fbram (on-chip FB-in-BRAM framebuffer, WORK-only).
// Checks: per-(qword,lane) write/read-back is bit-exact; a write to lane L leaves
// lanes != L untouched; the qword read is registered (1-cycle latency, not combinational).
// Copyright (C) 2026 — GPL-3.0
`timescale 1ns/1ps
`default_nettype none
`include "fb_geom.vh"
module tb_fbram;
  localparam integer AW       = $clog2(`FB_QWORDS);
  localparam integer NQW      = 16;   // exercise a handful of qwords (full depth = `FB_QWORDS)

  reg clk=0; always #5 clk=~clk;

  reg              wr_en=0;
  reg  [AW-1:0]    wr_qw=0;
  reg  [1:0]       wr_lane=0;
  reg  [15:0]      wr_pix=0;
  reg              rd_en=0;
  reg  [AW-1:0]    rd_qw=0;
  wire [63:0]      rd_qword;

  comp_fbram #(.FB_QWORDS(`FB_QWORDS), .AW(AW)) dut(
    .clk(clk), .wr_en(wr_en), .wr_qw(wr_qw), .wr_lane(wr_lane), .wr_pix(wr_pix),
    .rd_en(rd_en), .rd_qw(rd_qw), .rd_qword(rd_qword));

  integer errs=0; integer q, l;

  // Distinct value per (qword,lane); XOR-folded so high bits flip too (bijective → still unique).
  function [15:0] vexp(input integer qq, input integer ll);
    vexp = 16'((qq*4 + ll) ^ 16'hC3A5);
  endfunction

  // Write one pixel (one lane of one qword).
  task wr1(input integer qq, input integer ll);
    begin
      @(negedge clk);
      wr_en<=1; wr_qw<=qq[AW-1:0]; wr_lane<=ll[1:0]; wr_pix<=vexp(qq,ll);
      @(negedge clk); wr_en<=0;
    end
  endtask

  // Read a qword (registered: assert rd_en, one posedge latches, sample at next negedge)
  // and compare all four lanes against `exp_q` (the qword index whose values we expect).
  task rdchk(input integer qq, input integer exp_q);
    begin
      @(negedge clk); rd_en<=1; rd_qw<=qq[AW-1:0];
      @(negedge clk); rd_en<=0;   // a posedge elapsed → q regs latched → rd_qword valid now
      for (l=0; l<4; l=l+1)
        if (rd_qword[l*16 +: 16] !== vexp(exp_q,l)) begin
          errs=errs+1;
          $display("READ q=%0d lane=%0d got %h exp %h", qq, l, rd_qword[l*16 +: 16], vexp(exp_q,l));
        end
    end
  endtask

  initial begin
    @(negedge clk);

    // 1) Fill NQW qwords, all four lanes each.
    for (q=0; q<NQW; q=q+1)
      for (l=0; l<4; l=l+1) wr1(q, l);

    // 2) Read every qword back; assert bit-exact across all lanes.
    for (q=0; q<NQW; q=q+1) rdchk(q, q);

    // 3) Lane isolation: overwrite ONLY lane 2 of qword 5 with qword-9's lane-2 value,
    //    then confirm lane 2 changed and lanes {0,1,3} are still qword-5's values.
    @(negedge clk); wr_en<=1; wr_qw<=15'd5; wr_lane<=2'd2; wr_pix<=vexp(9,2);
    @(negedge clk); wr_en<=0;
    @(negedge clk); rd_en<=1; rd_qw<=15'd5;
    @(negedge clk); rd_en<=0;
    if (rd_qword[2*16 +: 16] !== vexp(9,2)) begin
      errs=errs+1; $display("ISO lane2 not written: got %h exp %h", rd_qword[2*16+:16], vexp(9,2)); end
    if (rd_qword[0*16 +: 16] !== vexp(5,0)) begin errs=errs+1; $display("ISO lane0 disturbed"); end
    if (rd_qword[1*16 +: 16] !== vexp(5,1)) begin errs=errs+1; $display("ISO lane1 disturbed"); end
    if (rd_qword[3*16 +: 16] !== vexp(5,3)) begin errs=errs+1; $display("ISO lane3 disturbed"); end

    // 4) Registered read latency: drive rd_qw=7 then immediately rd_qw=3. One cycle after the
    //    second address the output must STILL be qword-7 (data is one posedge behind the addr),
    //    and the cycle after that it becomes qword-3 — proving a 1-cycle pipeline, not combinational.
    @(negedge clk); rd_en<=1; rd_qw<=15'd7;   // request 7
    @(negedge clk);           rd_qw<=15'd3;   // request 3; posedge here latched 7 → output==7
    // sample now: output should be qword-7 (the previously latched address)
    for (l=0; l<4; l=l+1)
      if (rd_qword[l*16 +: 16] !== vexp(7,l)) begin
        errs=errs+1; $display("LAT expected qword-7 still on bus, lane %0d got %h", l, rd_qword[l*16+:16]); end
    @(negedge clk); rd_en<=0;  // posedge latched 3 → output==3 now
    for (l=0; l<4; l=l+1)
      if (rd_qword[l*16 +: 16] !== vexp(3,l)) begin
        errs=errs+1; $display("LAT expected qword-3 after 1 cyc, lane %0d got %h", l, rd_qword[l*16+:16]); end

    if (errs==0) $display("RESULT: PASS"); else $display("RESULT: FAIL errs=%0d", errs);
    $finish;
  end

  // safety net
  initial begin #100000; $display("RESULT: FAIL TIMEOUT"); $finish; end
endmodule
`default_nettype wire
