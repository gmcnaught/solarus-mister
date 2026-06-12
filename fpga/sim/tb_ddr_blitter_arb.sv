// Models the REAL reader: idles (no request) for a while, THEN gates its burst
// read on !busy (if(!ddr_busy) assert rd). With the buggy arbiter this deadlocks
// (reader stalled by grant can never assert rd). Asserts the reader always gets
// the bus within a bounded gap, reads correct data, and the producer progresses.
`timescale 1ns/1ps
`default_nettype none
module tb_deadlock;
  reg clk=0,reset=1; always #5 clk=~clk;
  reg [7:0] r_burst; reg[28:0] r_addr; reg r_rd; reg[63:0] r_din; reg[7:0] r_be; reg r_we;
  wire r_busy,r_grant;
  wire[7:0] d_burst; wire[28:0] d_addr; wire d_rd; wire[63:0] d_din; wire[7:0] d_be; wire d_we;
  reg d_busy; reg d_dready; reg[63:0] d_dout;
  ddr_blitter_arb #(.ENABLE(1'b1)) dut(.clk(clk),.reset(reset),
    .rdr_burstcnt(r_burst),.rdr_addr(r_addr),.rdr_rd(r_rd),.rdr_din(r_din),.rdr_be(r_be),.rdr_we(r_we),
    .rdr_busy(r_busy),.rdr_grant(r_grant),.ddram_busy(d_busy),.ddram_dout_ready(d_dready),
    .ddram_burstcnt(d_burst),.ddram_addr(d_addr),.ddram_rd(d_rd),.ddram_din(d_din),.ddram_be(d_be),.ddram_we(d_we));
  // behavioral DDRAM with backpressure (busy can extend a few cycles)
  reg[63:0] mem[0:65535]; reg[7:0] beats; reg[28:0] baddr; reg[3:0] lat; integer i; integer seed=7;
  initial for(i=0;i<4096;i=i+1) mem[32776+i]=64'hC0DE_0000_0000_0000|i;
  always @(posedge clk) begin
    d_dready<=0;
    if(reset) begin d_busy<=0; beats<=0; lat<=0; end
    else if(!d_busy) begin
      if(d_rd) begin beats<=d_burst; baddr<=d_addr; lat<=2+($random(seed)%4+4)%4; d_busy<=1; end
      else if(d_we) begin mem[d_addr-29'h07400000]<=d_din; d_busy<=1; lat<=($random(seed)%3+3)%3; end
    end else if(lat!=0) lat<=lat-1;
    else if(beats!=0) begin d_dready<=1; d_dout<=mem[baddr-29'h07400000]; baddr<=baddr+1; beats<=beats-1; if(beats==1) d_busy<=0; end
    else d_busy<=0;
  end
  integer errors=0,maxgap=0,gap,k,n;
  initial begin
    r_burst=0;r_addr=0;r_rd=0;r_din=0;r_be=8'hFF;r_we=0;
    repeat(6)@(posedge clk); reset<=0;
    for(n=0;n<150;n=n+1) begin
      repeat(300)@(posedge clk);            // reader idle -> producer fills
      gap=0;
      while(r_busy) begin @(posedge clk); gap=gap+1; if(gap>5000) begin $display("DEADLOCK: reader stuck %0d cyc",gap); $finish; end end
      r_addr<=29'h07408008; r_burst<=8'd80; r_rd<=1'b1;   // gate-on-busy then request
      @(posedge clk);
      while(!(r_grant && !d_busy)) @(posedge clk);
      r_rd<=1'b0;
      if(gap>maxgap) maxgap=gap;
      for(k=0;k<80;k=k+1) begin @(posedge clk); while(!(d_dready&&r_grant)) @(posedge clk);
        if(d_dout!==mem[32776+k]) errors=errors+1; end
    end
    $display("=== %0d bursts, read errors=%0d, max grant gap=%0d cyc ===",n,errors,maxgap);
    $display("CTRL=%h (producer frame counter; nonzero => frames completed)", mem[0]);
    $display("rect=%h (expect green 07E0x4)", mem[8+100*80+32]);
    if(errors==0 && mem[0][31:2]!=0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end
  initial begin #60000000 $display("RESULT: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire
