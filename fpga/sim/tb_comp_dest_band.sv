// tb_comp_dest_band.sv — testbench for comp_dest_band (full-width on-chip dest band).
// Copyright (C) 2026 — GPL-3.0
`timescale 1ns/1ps
`default_nettype none
`include "comp_defs.vh"
module tb_comp_dest_band;
  reg clk=0; always #5 clk=~clk;
  reg ld_we=0; reg [63:0] ld_qw; reg [12:0] ld_idx;
  reg cw_we=0; reg [15:0] cw_x, cw_pix; reg [3:0] cw_row;
  reg flush_req=0; wire fl_valid, flush_done; wire [63:0] fl_qw; wire [7:0] fl_be; wire [12:0] fl_idx;
  reg [15:0] rd_x; reg [3:0] rd_row; wire [15:0] rd_dst;
  comp_dest_band dut(.clk(clk), .ld_we(ld_we), .ld_qw(ld_qw), .ld_idx(ld_idx),
    .cw_we(cw_we), .cw_x(cw_x), .cw_row(cw_row), .cw_pix(cw_pix),
    .rd_x(rd_x), .rd_row(rd_row), .rd_dst(rd_dst),
    .flush_req(flush_req), .fl_valid(fl_valid), .fl_qw(fl_qw), .fl_be(fl_be), .fl_idx(fl_idx),
    .flush_done(flush_done));
  integer errs=0; reg seen=0; reg seen_done=0; integer w=0;
  initial begin
    @(negedge clk);
    // PRELOAD qword 0 from DDR (the band is always preloaded before compositing):
    // lanes {3,2,1,0} = {4444,3333,2222,1111}.
    ld_we<=1; ld_idx<=13'd0; ld_qw<={16'h4444,16'h3333,16'h2222,16'h1111}; @(negedge clk);
    ld_we<=0; @(negedge clk);
    // composite px @ x=1,row0 = 0xAAAA and x=2,row0=0xBBBB (same qword 0, lanes 1 and 2)
    cw_we<=1; cw_x<=16'd1; cw_row<=4'd0; cw_pix<=16'hAAAA; @(negedge clk);
    cw_x<=16'd2; cw_pix<=16'hBBBB; @(negedge clk);
    cw_we<=0; @(negedge clk);
    flush_req<=1; @(negedge clk); flush_req<=0;
    repeat (20) begin
      @(negedge clk);
      if (fl_valid && fl_idx==13'd0) begin
        seen=1;
        // New contract: flush emits the FULL qword (fl_be=0xFF). Composited lanes
        // (1,2) are overwritten; preloaded lanes (0,3) are preserved.
        if (fl_be !== 8'hFF) begin errs=errs+1; $display("BE got %b",fl_be); end
        if (fl_qw !== 64'h4444_BBBB_AAAA_1111) begin errs=errs+1; $display("QW %h",fl_qw); end
      end
      if (flush_done) seen_done=1;
    end
    // flush walks the whole band (80*COMP_BAND_H qwords, ~1cyc each), so flush_done
    // arrives well after the 20-cyc dirty-emit window above.  Wait (bounded) for it
    // so the test FAILS if flush_done liveness is ever broken.
    while (!seen_done && w < 4000) begin
      @(negedge clk);
      if (flush_done) seen_done=1;
      w=w+1;
    end
    if (!seen) errs=errs+1;
    if (!seen_done) errs=errs+1;
    if (errs==0) $display("RESULT: PASS"); else $display("RESULT: FAIL errs=%0d",errs);
    $finish;
  end
endmodule
