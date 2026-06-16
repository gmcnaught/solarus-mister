// tb_sdram_psx.sv — PSX-pattern line reads: BURST_BEATS beats (each a BL=4 read,
// 4 words) assembled after one ACTIVE. BURST_BEATS=2 => 128-bit line. Page-open reuse.
`timescale 1ns/1ps
`default_nettype none
module tb_sdram_psx;
  reg clk=0; always #5 clk=~clk;          // 100 MHz
  reg          init=1;
  reg  [26:0]  addr=0;
  reg  [15:0]  din=0;
  reg          we=0, rd=0;
  wire [63:0]  dout64;
  wire         dout_ready;                 // NEW: per-beat strobe
  wire         ready;                       // line complete / accept next

  wire [15:0] DQ; wire [12:0] A; wire DQML,DQMH; wire [1:0] BA;
  wire nCS,nWE,nRAS,nCAS,CLK,CKE;

  sdram_psx #(.BURST_BEATS(2)) dut (
    .init(init), .clk(clk),
    .SDRAM_DQ(DQ), .SDRAM_A(A), .SDRAM_DQML(DQML), .SDRAM_DQMH(DQMH),
    .SDRAM_BA(BA), .SDRAM_nCS(nCS), .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS),
    .SDRAM_nCAS(nCAS), .SDRAM_CLK(CLK), .SDRAM_CKE(CKE),
    .wtbt(2'b11), .addr(addr), .dout(), .dout64(dout64),
    .dout_ready(dout_ready), .din(din), .din64(64'd0), .we(we), .we_burst(1'b0), .rd(rd), .ready(ready)
  );
  sdram_chip_model chip (
    .clk(clk), .DQ(DQ), .A(A), .BA(BA),
    .nCS(nCS), .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE), .CKE(CKE),
    .DQML(DQML), .DQMH(DQMH), .proto_errors()  // read hierarchically as chip.proto_errors
  );

  integer errors=0;
  task wait_ready; begin @(posedge clk); while(!ready) @(posedge clk); end endtask

  // single-word write through the controller (same map as v3.0 tb)
  task wr(input [26:0] a, input [15:0] d); begin
    @(posedge clk); addr<=a; din<=d; we<=1;
    @(posedge clk); we<=0; wait_ready;
  end endtask

  // line read: capture BURST_BEATS beats, return them packed
  reg [63:0] beat [0:7];
  task rd_line(input [26:0] a, input integer n); integer i; begin
    @(posedge clk); addr<=a; rd<=1;
    @(posedge clk); rd<=0;
    for (i=0;i<n;i=i+1) begin
      @(posedge clk); while(!dout_ready) @(posedge clk); beat[i]=dout64;
    end
    wait_ready;
  end endtask

  integer w;
  initial begin
    repeat(4) @(posedge clk); init<=0;
    // let controller startup finish before the first access (same as tb_sdram_ctrl):
    // without this the first write collides with the tail of the init sequence.
    wait_ready; repeat(4) @(posedge clk);
    // seed 8 consecutive words (= 2 beats of 4 words) at a base
    for (w=0; w<8; w=w+1) wr(27'h001000 + (w<<1), 16'hA000 + w[15:0]);
    // read the 2-beat line at the base
    rd_line(27'h001000, 2);
    if (beat[0] !== 64'hA003_A002_A001_A000) begin errors=errors+1; $display("beat0 bad: %h", beat[0]); end
    if (beat[1] !== 64'hA007_A006_A005_A004) begin errors=errors+1; $display("beat1 bad: %h", beat[1]); end

    // Scenario 2: drive MANY back-to-back line reads so enough cycles elapse for
    // at least one AUTO_REFRESH to fire BETWEEN lines (refresh trigger fires when
    // refresh_count > cycles_per_refresh=780 at idle). This proves refresh lands
    // at a line boundary, not mid-line — exercising the proto monitor's
    // AUTO_REFRESH-in-flight check across a refresh window. Re-read the same line
    // each time; every read still round-trips and is invariant-checked.
    for (w=0; w<200; w=w+1) begin
      rd_line(27'h001000, 2);
      if (beat[0] !== 64'hA003_A002_A001_A000) begin errors=errors+1; $display("s2 beat0 bad@%0d: %h", w, beat[0]); end
      if (beat[1] !== 64'hA007_A006_A005_A004) begin errors=errors+1; $display("s2 beat1 bad@%0d: %h", w, beat[1]); end
    end

    // Scenario 3: PAGE-WRAP line read crossing a ROW boundary at the 1024-col boundary.
    // 64MB map: byte = (row<<13) | (bank<<11) | (col<<1).
    //   row5 col 1020+k -> (5<<13) | ((1020+k)<<1) = 0xA000 | (0x7F8 + 2k) = 0xA7F8 + 2k
    //   row6 col 0+k     -> (6<<13) | (k<<1)        = 0xC000 + 2k
    // rows 5 & 6 differ in {row[12],row[3:0]} (00101 / 00110), so the chip model's
    // 17-bit storage key keeps them separate.
    for (w=0; w<4; w=w+1) wr(27'h00_A7F8 + (w<<1), 16'h5000 + w[15:0]); // row5 cols1020..1023
    for (w=0; w<4; w=w+1) wr(27'h00_C000 + (w<<1), 16'h6000 + w[15:0]); // row6 cols0..3
    rd_line(27'h00_A7F8, 2);
    if (beat[0] !== 64'h5003_5002_5001_5000) begin errors=errors+1; $display("wrap beat0 bad: %h", beat[0]); end
    if (beat[1] !== 64'h6003_6002_6001_6000) begin errors=errors+1; $display("wrap beat1 bad: %h", beat[1]); end

    // Scenario 4 (Task #31): prove the 64MB map reaches PAST the 32MB boundary.
    // 64MB column-low map: col=addr[10:1] (10b/1024), bank=addr[12:11], row=addr[25:13]
    //   byte_addr = (row<<13) | (bank<<11) | (col<<1)
    // 4a — TOP ROW BIT (addr[25]): write distinct values at row0 and at the address
    // with addr[25]=1 (row 0x1000, bank0, col0). Under the OLD 32MB map row=addr[24:12]
    // IGNORES addr[25], so 0x000_0000 and 0x200_0000 would ALIAS to the same cell -> the
    // second read returns the first's value (this is the RED failure on the old map).
    wr(27'h000_0000, 16'h1111);            // 64MB map: row0    bank0 col0
    wr(27'h200_0000, 16'h2222);            // 64MB map: row4096 bank0 col0 (addr[25]=1)
    rd_line(27'h000_0000, 1);
    if (beat[0][15:0] !== 16'h1111) begin errors=errors+1; $display("s4a lo bad: %h", beat[0][15:0]); end
    rd_line(27'h200_0000, 1);
    if (beat[0][15:0] !== 16'h2222) begin errors=errors+1; $display("s4a hi bad: %h", beat[0][15:0]); end

    // 4b — 10TH COLUMN BIT (col[9], addr[10]): within one row/bank, col0 vs col512 must
    // be distinct cells. 64MB map: row1=addr[25:13]=1 -> base 1<<13 = 0x2000;
    // col512 -> +(512<<1)=+0x400. Proves the new column bit is decoded.
    wr(27'h00_2000, 16'hC0C0);             // row1 bank0 col0
    wr(27'h00_2400, 16'hC512);             // row1 bank0 col512
    rd_line(27'h00_2000, 1);
    if (beat[0][15:0] !== 16'hC0C0) begin errors=errors+1; $display("s4b col0 bad: %h", beat[0][15:0]); end
    rd_line(27'h00_2400, 1);
    if (beat[0][15:0] !== 16'hC512) begin errors=errors+1; $display("s4b col512 bad: %h", beat[0][15:0]); end

    if (chip.proto_errors !== 0) begin errors=errors+1; $display("proto_errors=%0d", chip.proto_errors); end
    // non-vacuous: scenario 2 must have actually triggered >=1 AUTO_REFRESH, else the
    // refresh-in-flight invariant was never exercised.
    if (chip.refresh_seen < 1) begin errors=errors+1; $display("refresh path not exercised (refresh_seen=%0d)", chip.refresh_seen); end
    else $display("refresh_seen=%0d (refresh path exercised, all at line boundaries)", chip.refresh_seen);
    $display("errors=%0d", errors);
    $finish;
  end
endmodule
