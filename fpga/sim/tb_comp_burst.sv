// tb_comp_burst.sv — unit test for the bounded-length burst master.
// Copyright (C) 2026 — GPL-3.0
`timescale 1ns/1ps
`default_nettype none
module tb_comp_burst;
  localparam AW=32, MB=4;
  reg clk=0, rst=1; always #5 clk=~clk;

  // request / stream
  reg          req=0, req_we=0; reg [AW-1:0] req_addr=0; reg [15:0] req_len=0;
  wire         busy, done;
  wire         rd_valid; wire [63:0] rd_qw; wire [15:0] rd_beat;
  wire         wr_take; wire [15:0] wr_beat;
  reg  [63:0]  wr_qw=0; reg [7:0] wr_be=0;
  // bus
  wire [AW-1:0] mem_addr; wire mem_rd, mem_wr; wire [7:0] mem_burstcnt, mem_be;
  wire [63:0]  mem_din; reg [63:0] mem_dout=0; reg mem_dout_ready=0; reg mem_busy=0;

  comp_burst #(.AW(AW), .MAXBURST(MB)) dut (
    .clk(clk), .rst(rst),
    .req(req), .req_we(req_we), .req_addr(req_addr), .req_len(req_len),
    .busy(busy), .done(done),
    .rd_valid(rd_valid), .rd_qw(rd_qw), .rd_beat(rd_beat),
    .wr_take(wr_take), .wr_beat(wr_beat), .wr_qw(wr_qw), .wr_be(wr_be),
    .mem_addr(mem_addr), .mem_rd(mem_rd), .mem_wr(mem_wr),
    .mem_burstcnt(mem_burstcnt), .mem_din(mem_din), .mem_be(mem_be),
    .mem_dout(mem_dout), .mem_dout_ready(mem_dout_ready), .mem_busy(mem_busy));

  // ── behavioral burst DDR model ──────────────────────────────────────────
  // backpressure: busy 1-in-3. Reads: on accept, latency=3 then burstcnt beats
  // of mem[addr+i]. Writes: accept burstcnt beats back-to-back into mem[].
  reg [63:0] mem [0:1023];
  reg [7:0]  bremain; reg [AW-1:0] baddr; reg [2:0] blat; reg [1:0] bp=0;
  reg        bwr;
  integer i;
  always @(posedge clk) bp <= bp + 2'd1;
  always @(*) mem_busy = (bp==2'd0);                 // periodic backpressure
  always @(posedge clk) begin
    mem_dout_ready <= 1'b0;
    if (rst) begin bremain<=0; blat<=0; end
    else begin
      if (blat != 0) blat <= blat - 3'd1;
      else if (bremain != 0 && !bwr) begin
        mem_dout <= mem[baddr[9:0]]; mem_dout_ready <= 1'b1;
        baddr <= baddr + 1; bremain <= bremain - 8'd1;
      end else if (!mem_busy) begin
        if (mem_rd) begin bremain<=mem_burstcnt; baddr<=mem_addr; blat<=3'd3; bwr<=0; end
        else if (mem_wr) begin                      // accept this write beat
          for (i=0;i<8;i=i+1) if (mem_be[i]) mem[mem_addr[9:0]][i*8+:8] <= mem_din[i*8+:8];
        end
      end
    end
  end

  // producer for write beats: supply a known pattern keyed by wr_beat
  always @(*) begin wr_qw = {48'hABCD_0000_0000 | 16'(wr_beat)}; wr_be = 8'hFF; end

  integer errors=0; integer rcount;
  reg [63:0] seen [0:31];
  initial begin
    for (i=0;i<1024;i=i+1) mem[i]=64'd0;
    for (i=0;i<8;i=i+1) mem[100+i] = 64'h1000_0000_0000_0000 + i; // read source
    rst<=1; repeat(5) @(posedge clk); rst<=0; @(posedge clk);

    // ---- READ transfer: 8 beats from addr 100, MAXBURST=4 -> two sub-bursts ----
    rcount=0;
    @(posedge clk); req<=1; req_we<=0; req_addr<=100; req_len<=8; @(posedge clk); req<=0;
    while (!done) begin @(posedge clk);
      if (rd_valid) begin seen[rd_beat]<=rd_qw; rcount=rcount+1; end
    end
    @(posedge clk);
    if (rcount != 8) begin errors=errors+1; $display("FAIL: read beats=%0d exp 8", rcount); end
    for (i=0;i<8;i=i+1) if (seen[i] !== (64'h1000_0000_0000_0000 + i))
      begin errors=errors+1; $display("FAIL: read beat %0d=%h", i, seen[i]); end

    // ---- WRITE transfer: 6 beats to addr 200, MAXBURST=4 -> 4+2 ----
    @(posedge clk); req<=1; req_we<=1; req_addr<=200; req_len<=6; @(posedge clk); req<=0;
    while (!done) @(posedge clk);
    @(posedge clk);
    for (i=0;i<6;i=i+1) if (mem[200+i] !== (64'hABCD_0000_0000 | 16'(i)))
      begin errors=errors+1; $display("FAIL: write beat %0d=%h", i, mem[200+i]); end

    if (errors==0) $display("RESULT: PASS");
    else           $display("RESULT: FAIL errors=%0d", errors);
    $finish;
  end
  initial begin #500000 $display("TIMEOUT"); $finish; end
endmodule
`default_nettype wire
