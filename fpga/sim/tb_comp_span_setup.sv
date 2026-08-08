// tb_comp_span_setup.sv — testbench for comp_span_setup (clip/flip → row spans)
// Copyright (C) 2026 — GPL-3.0
`timescale 1ns/1ps
`default_nettype none
`include "fb_geom.vh"
module tb_comp_span_setup;
  reg clk=0; always #5 clk=~clk;
  reg start=0; reg signed [15:0] c_dst_x, c_dst_y; reg [15:0] c_w,c_h; reg [7:0] c_flags;
  reg [15:0] c_vp_w = 16'(`FB_W);
  wire span_valid, span_last, done; wire [15:0] span_dst_x, span_dst_y, span_len, span_src_x0, span_src_y;
  comp_span_setup dut(.clk(clk), .rst(1'b0), .start(start), .c_vp_w(c_vp_w), .c_dst_x(c_dst_x), .c_dst_y(c_dst_y),
    .c_w(c_w), .c_h(c_h), .c_flags(c_flags),
    .span_valid(span_valid), .span_dst_x(span_dst_x), .span_dst_y(span_dst_y),
    .span_len(span_len), .span_src_x0(span_src_x0), .span_src_y(span_src_y),
    .span_last(span_last), .done(done));
  integer nspan, errs=0;
  task run_case; input signed [15:0] dx,dy; input [15:0] w,h; input [7:0] fl;
    begin
      c_dst_x<=dx; c_dst_y<=dy; c_w<=w; c_h<=h; c_flags<=fl; nspan=0;
      @(negedge clk); start<=1; @(negedge clk); start<=0;
      while (!done) begin @(negedge clk); if (span_valid) nspan=nspan+1; end
    end
  endtask
  initial begin
    @(negedge clk);
    run_case(16'sd20,16'sd10,16'd8,16'd4,8'd0); if (nspan!==4) begin errs=errs+1; $display("A nspan=%0d",nspan); end
    run_case(-16'sd3,16'sd5,16'd10,16'd1,8'd0);
      if (nspan!==1 || span_dst_x!==16'd0 || span_len!==16'd7 || span_src_x0!==16'd3)
        begin errs=errs+1; $display("B nspan=%0d dx=%0d len=%0d sx0=%0d",nspan,span_dst_x,span_len,span_src_x0); end
    // C: entirely off the RIGHT edge. Anchored to FB_W so it stays a fully-clipped
    // case whatever the framebuffer width is (it was a bare 400, which stopped being
    // off-screen the moment FB_W went 320 -> 416).
    run_case(16'sd`FB_W,16'sd10,16'd8,16'd4,8'd0); if (nspan!==0) begin errs=errs+1; $display("C nspan=%0d",nspan); end
    // D: straddles the right edge — 8 wide starting 3 px before it, so 3 px survive.
    run_case(16'sd`FB_W-16'sd3,16'sd10,16'd8,16'd1,8'd0);
      if (nspan!==1 || span_len!==16'd3) begin errs=errs+1; $display("D nspan=%0d len=%0d",nspan,span_len); end
    // E: VIEWPORT clip. A 320-wide quest inside a 416 framebuffer must clip at 320,
    //    NOT at FB_W -- otherwise draws that never went through the host's clip_to_fb
    //    spill into the right pillar (observed on HW as one column at x=368).
    c_vp_w = 16'd320;
    run_case(16'sd318,16'sd10,16'd8,16'd1,8'd0);
      if (nspan!==1 || span_len!==16'd2)
        begin errs=errs+1; $display("E nspan=%0d len=%0d (want 1/2)",nspan,span_len); end
    // F: fully outside the viewport but inside the framebuffer -> zero spans.
    run_case(16'sd330,16'sd10,16'd8,16'd1,8'd0);
      if (nspan!==0) begin errs=errs+1; $display("F nspan=%0d (want 0)",nspan); end
    c_vp_w = 16'(`FB_W);

    if (errs==0) $display("RESULT: PASS"); else $display("RESULT: FAIL errs=%0d",errs);
    $finish;
  end
endmodule
