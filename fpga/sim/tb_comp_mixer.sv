`timescale 1ns/1ps
`default_nettype none
`include "comp_defs.vh"
module tb_comp_mixer;
  reg clk=0; always #5 clk=~clk;
  reg in_valid=0; reg [15:0] in_src, in_dst, in_key; reg [7:0] in_mode, in_fmt, in_alpha;
  wire out_valid, out_we; wire [15:0] out_pix;
  comp_mixer dut(.clk(clk), .in_valid(in_valid), .in_src(in_src), .in_dst(in_dst),
    .in_mode(in_mode), .in_fmt(in_fmt), .in_key(in_key), .in_alpha(in_alpha),
    .out_valid(out_valid), .out_pix(out_pix), .out_we(out_we));

  // GOLDEN: pure-function reference per the frozen semantics.
  function [16:0] gref; // {we, pix16}
    input [15:0] s, d, key; input [7:0] mode, fmt, alpha;
    reg [4:0] sr,dr; reg [5:0] sg,dg; reg [4:0] sb,db; reg [7:0] a; reg [3:0] a4;
    reg [16:0] tr,tg,tb_;
    reg [16:0] divr,divg,divb; // intermediates for COMP_DIV255 (Icarus can't part-select macro exprs)
    begin
      sr=s[15:11]; sg=s[10:5]; sb=s[4:0]; dr=d[15:11]; dg=d[10:5]; db=d[4:0];
      a4 = s[15:12];
      if (mode==`COMP_COPY)      gref = {1'b1, s};
      else if (mode==`COMP_KEY)  gref = (s==key) ? 17'h0_0000 : {1'b1, s};
      else begin // CONST_ALPHA or PALPHA
        a = (mode==`COMP_PA) ? {a4,a4} : alpha;
        if (mode==`COMP_PA && a4==4'd0) gref = 17'h0_0000;       // fully transparent → skip
        else begin
          tr = sr*a + dr*(8'd255-a); tg = sg*a + dg*(8'd255-a); tb_ = sb*a + db*(8'd255-a);
          divr = `COMP_DIV255(tr); divg = `COMP_DIV255(tg); divb = `COMP_DIV255(tb_);
          gref = {1'b1, divr[4:0], divg[5:0], divb[4:0]};
        end
      end
    end
  endfunction

  integer i; integer errs=0; reg [16:0] g; reg [16:0] q [0:7]; integer qh=0,qt=0; // pipeline shadow
  // push golden into a delay queue so we compare against the LAT-delayed output
  task drive; input [15:0] s,d,key; input [7:0] mode,fmt,alpha; begin
    in_valid<=1; in_src<=s; in_dst<=d; in_key<=key; in_mode<=mode; in_fmt<=fmt; in_alpha<=alpha;
    q[qt]<=gref(s,d,key,mode,fmt,alpha); qt<=(qt+1)%8;
  end endtask

  initial begin
    @(negedge clk);
    // back-to-back stream across all modes proves issue-interval 1 + correctness
    drive(16'hF800,16'h001F,16'h07E0,`COMP_COPY,`COMP_RGB565,8'd0);  @(negedge clk);
    drive(16'h07E0,16'h0000,16'h07E0,`COMP_KEY ,`COMP_RGB565,8'd0);  @(negedge clk); // keyed → skip
    drive(16'hFFFF,16'h0000,16'h0000,`COMP_CA  ,`COMP_RGB565,8'd128);@(negedge clk);
    drive(16'h8ABC,16'h1234,16'h0000,`COMP_PA  ,`COMP_ARGB4444,8'd0);@(negedge clk);
    in_valid<=0;
    // drain + compare each emitted pixel to the queued golden
    for (i=0;i<8;i=i+1) begin
      @(negedge clk);
      if (out_valid) begin
        g = q[qh]; qh=(qh+1)%8;
        if (out_we !== g[16] || (g[16] && out_pix !== g[15:0])) begin
          errs=errs+1; $display("MISMATCH i=%0d we=%b/%b pix=%h/%h", i, out_we, g[16], out_pix, g[15:0]);
        end
      end
    end
    if (errs==0) $display("RESULT: PASS"); else $display("RESULT: FAIL errs=%0d", errs);
    $finish;
  end
endmodule
