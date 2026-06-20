// tb_comp_src_linebuf.sv — testbench for comp_src_linebuf (on-chip source line buffer).
// Copyright (C) 2026 — GPL-3.0
`timescale 1ns/1ps
`default_nettype none
module tb_comp_src_linebuf;
  reg clk=0; always #5 clk=~clk;
  reg fill_we=0; reg [63:0] fill_qw; reg [9:0] fill_idx;
  reg serve_req=0; reg [15:0] serve_x, serve_w; reg serve_hflip;
  wire serve_valid; wire [15:0] serve_pix;
  comp_src_linebuf dut(.clk(clk), .fill_we(fill_we), .fill_qw(fill_qw), .fill_idx(fill_idx),
    .serve_req(serve_req), .serve_x(serve_x), .serve_w(serve_w), .serve_hflip(serve_hflip),
    .serve_valid(serve_valid), .serve_pix(serve_pix));
  integer i, errs=0;
  initial begin
    @(negedge clk);
    // fill 8 px (px value = 0x100+x), packed 4/qword
    for (i=0;i<2;i=i+1) begin
      fill_we<=1; fill_idx<=i[9:0];
      // 16-bit casts: under Icarus 13 the unsized integer sums need a defined
      // width inside the concatenation (values are unchanged for i in 0..1).
      fill_qw<={16'(16'h0103+(i*4)),16'(16'h0102+(i*4)),16'(16'h0101+(i*4)),16'(16'h0100+(i*4))};
      @(negedge clk);
    end
    fill_we<=0;
    // serve x=0..7 unflipped
    for (i=0;i<8;i=i+1) begin
      serve_req<=1; serve_x<=i[15:0]; serve_w<=16'd8; serve_hflip<=0; @(negedge clk);
      @(negedge clk);
      if (serve_pix !== (16'h0100+i)) begin errs=errs+1; $display("UNFLIP x=%0d got %h",i,serve_pix); end
    end
    // serve flipped: x=0 should read px w-1=7
    serve_req<=1; serve_x<=16'd0; serve_w<=16'd8; serve_hflip<=1; @(negedge clk); @(negedge clk);
    if (serve_pix !== 16'h0107) begin errs=errs+1; $display("FLIP got %h",serve_pix); end
    if (errs==0) $display("RESULT: PASS"); else $display("RESULT: FAIL errs=%0d",errs);
    $finish;
  end
endmodule
