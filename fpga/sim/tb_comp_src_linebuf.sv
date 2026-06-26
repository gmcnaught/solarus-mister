// tb_comp_src_linebuf.sv — testbench for comp_src_linebuf (on-chip source line buffer).
// Copyright (C) 2026 — GPL-3.0
`timescale 1ns/1ps
`default_nettype none
module tb_comp_src_linebuf;
  reg clk=0; always #5 clk=~clk;
  reg fill_we=0; reg [63:0] fill_qw; reg [9:0] fill_idx;
  reg fill_bank=0;   // [Task 2] selects the bank the fill writes (0/1)
  reg serve_req=0; reg [15:0] serve_x, serve_w; reg serve_hflip;
  reg serve_bank=0;  // [Task 2] selects the bank the serve reads (0/1)
  wire serve_valid; wire [15:0] serve_pix;
  comp_src_linebuf dut(.clk(clk),
    .fill_we(fill_we), .fill_qw(fill_qw), .fill_idx(fill_idx), .fill_bank(fill_bank),
    .serve_req(serve_req), .serve_x(serve_x), .serve_w(serve_w), .serve_hflip(serve_hflip),
    .serve_bank(serve_bank),
    .serve_valid(serve_valid), .serve_pix(serve_pix));
  integer i, errs=0;
  reg [15:0] got0, got1;
  integer fail;

  // ── helper tasks ─────────────────────────────────────────────────────────────
  // do_fill: write one qword to a chosen bank at a given linebuf index (one fill_we pulse).
  task do_fill;
    input        bank;
    input  [9:0] idx;
    input [63:0] qw;
    begin
      @(negedge clk);
      fill_bank <= bank; fill_we <= 1; fill_idx <= idx; fill_qw <= qw;
      @(negedge clk);
      fill_we <= 0;
    end
  endtask

  // do_serve: assert serve_req for one cycle; sample serve_pix after 1-cycle read latency.
  // Uses the same two-negedge-wait pattern as the inline legacy tests above.
  task do_serve;
    input        bank;
    input [15:0] x, w;
    input        hf;
    output [15:0] result;
    begin
      @(negedge clk);
      serve_bank <= bank; serve_req <= 1; serve_x <= x; serve_w <= w; serve_hflip <= hf;
      @(negedge clk);
      @(negedge clk);
      result = serve_pix;
      serve_req <= 0; serve_bank <= 0;
    end
  endtask

  initial begin
    @(negedge clk);
    // ── legacy single-bank tests (bank=0 tied) ─────────────────────────────
    // fill 8 px (px value = 0x100+x), packed 4/qword
    for (i=0;i<2;i=i+1) begin
      fill_we<=1; fill_bank<=0; fill_idx<=i[9:0];
      // 16-bit casts: under Icarus 13 the unsized integer sums need a defined
      // width inside the concatenation (values are unchanged for i in 0..1).
      fill_qw<={16'(16'h0103+(i*4)),16'(16'h0102+(i*4)),16'(16'h0101+(i*4)),16'(16'h0100+(i*4))};
      @(negedge clk);
    end
    fill_we<=0;
    // serve x=0..7 unflipped
    for (i=0;i<8;i=i+1) begin
      serve_req<=1; serve_bank<=0; serve_x<=i[15:0]; serve_w<=16'd8; serve_hflip<=0; @(negedge clk);
      @(negedge clk);
      if (serve_pix !== (16'h0100+i)) begin errs=errs+1; $display("UNFLIP x=%0d got %h",i,serve_pix); end
    end
    // serve flipped: x=0 should read px w-1=7
    serve_req<=1; serve_bank<=0; serve_x<=16'd0; serve_w<=16'd8; serve_hflip<=1; @(negedge clk); @(negedge clk);
    if (serve_pix !== 16'h0107) begin errs=errs+1; $display("FLIP got %h",serve_pix); end
    serve_req<=0;

    // ── bank-independence test [Task 2] ────────────────────────────────────
    // Fill bank 0 qword-0 with Q0; fill bank 1 qword-0 with Q1 (different data).
    // Serve bank 0 x=0 → expect Q0's lane 0 (bits[15:0] = 0xDDDD).
    // Serve bank 1 x=0 → expect Q1's lane 0 (bits[15:0] = 0x4444).
    // No cross-bank bleed: bank1 write must not corrupt bank0 and vice versa.
    fail = 0;
    do_fill(1'b0, 10'd0, 64'hAAAA_BBBB_CCCC_DDDD);
    do_fill(1'b1, 10'd0, 64'h1111_2222_3333_4444);
    do_serve(1'b0, 16'd0, 16'd4, 1'b0, got0);   // lane0 of Q0 → expect 0xDDDD
    do_serve(1'b1, 16'd0, 16'd4, 1'b0, got1);   // lane0 of Q1 → expect 0x4444
    if (got0 !== 16'hDDDD) begin errs=errs+1; fail=1; $display("BANK0 x=0 got %h (exp DDDD)",got0); end
    if (got1 !== 16'h4444) begin errs=errs+1; fail=1; $display("BANK1 x=0 got %h (exp 4444)",got1); end
    if (!fail) $display("bank-independence: PASS");

    if (errs==0) $display("RESULT: PASS"); else $display("RESULT: FAIL errs=%0d",errs);
    $finish;
  end
endmodule
