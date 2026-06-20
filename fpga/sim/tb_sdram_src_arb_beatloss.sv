`timescale 1ns/1ps
`default_nettype none
// tb_sdram_src_arb_beatloss.sv — #34 directed repro of the S_SRC_SDRAM_WAIT wedge.
//
// The controller stub asserts c_ready=1 / c_busy=0 ALWAYS (ready for the next
// command) but delivers the SRC read's data beat (c_dready) GAP cycles LATER — the
// HW separation the faithful sdram_psx sim never shows. A SCAN client requests the
// instant the SRC read is granted, so a buggy arbiter (releases owner on c_ready)
// hands the bus to SCAN before the SRC beat arrives -> p0_dready is masked off
// (owner!=2) -> the SRC beat is lost -> the P_SRC client (mirroring blitter
// S_SRC_SDRAM_WAIT) starves. PASS requires the P_SRC client to receive its beat.
module tb_sdram_src_arb_beatloss;
  reg clk=0; always #5 clk=~clk;
  reg reset=1;

  localparam [26:0] SRC_ADDR  = 27'h0001000;
  localparam [26:0] SCAN_ADDR = 27'h0400000;
  localparam [63:0] SRC_DATA  = 64'hCAFED00D_12345678;
  localparam integer GAP = 3;            // cycles c_ready leads c_dready
  localparam integer WATCHDOG = 200;     // cycles before declaring starvation

  // P_SRC client (mirrors blitter_top S_SRC_SDRAM_WAIT)
  reg  [26:0] p0_addr = SRC_ADDR;
  reg         p0_rd = 0;
  wire        p0_grant, p0_busy, p0_dready;
  wire [63:0] p0_dout64;

  // P_SCAN preemptor
  reg  [26:0] scan_addr = SCAN_ADDR;
  reg         scan_rd = 0;
  reg  [7:0]  scan_burst = 8'd1;
  wire        scan_busy, scan_dready;
  wire [63:0] scan_dout64;

  // P_DST unused here
  wire        dst_busy, dst_dready; wire [63:0] dst_dout64;

  // controller stub
  wire [26:0] c_addr; wire c_rd, c_we, c_we_burst;
  wire [15:0] c_din;  wire [63:0] c_din64;
  reg         c_ready = 1, c_busy = 0;
  reg         c_dready = 0; reg [63:0] c_dout64_r = 0;

  integer errors = 0;

  sdram_src_arb dut (
    .clk(clk), .reset(reset),
    .scan_addr(scan_addr), .scan_rd(scan_rd), .scan_burst(scan_burst),
    .scan_busy(scan_busy), .scan_dout64(scan_dout64), .scan_dready(scan_dready),
    .p0_addr(p0_addr), .p0_rd(p0_rd), .p0_grant(p0_grant), .p0_busy(p0_busy),
    .p0_we(1'b0), .p0_din(16'd0), .p0_waddr(27'd0), .p0_we_burst(1'b0), .p0_din64(64'd0),
    .p0_dready(p0_dready), .p0_dout64(p0_dout64),
    .dst_addr(27'd0), .dst_rd(1'b0), .dst_we(1'b0), .dst_din(16'd0),
    .dst_we_burst(1'b0), .dst_din64(64'd0),
    .dst_busy(dst_busy), .dst_dout64(dst_dout64), .dst_dready(dst_dready),
    .c_addr(c_addr), .c_rd(c_rd), .c_we(c_we), .c_din(c_din),
    .c_we_burst(c_we_burst), .c_din64(c_din64),
    .c_ready(c_ready), .c_busy(c_busy), .c_dready(c_dready), .c_dout64(c_dout64_r)
  );

  // --- controller stub: deliver the SRC read's beat GAP cycles after it issues ---
  reg        src_armed = 0;
  reg [7:0]  src_cnt = 0;
  always @(posedge clk) begin
    c_dready <= 1'b0;
    if (reset) begin src_armed <= 0; src_cnt <= 0; end
    else begin
      if (c_rd && (c_addr == SRC_ADDR) && !src_armed) begin
        src_armed <= 1'b1; src_cnt <= GAP[7:0];
      end
      if (src_armed) begin
        if (src_cnt == 0) begin
          c_dready <= 1'b1; c_dout64_r <= SRC_DATA; src_armed <= 1'b0;
        end else src_cnt <= src_cnt - 8'd1;
      end
    end
  end

  // --- P_SRC client: issue one read, drop p0_rd on !p0_busy, await p0_dready ----
  reg p0_done = 0; reg [63:0] p0_data = 0;
  always @(posedge clk) begin
    if (reset) begin p0_done <= 0; end
    else begin
      if (p0_rd && !p0_busy) p0_rd <= 1'b0;   // accepted; drop request
      if (p0_dready) begin p0_done <= 1'b1; p0_data <= p0_dout64; end
    end
  end

  // --- SCAN preemptor: request the cycle AFTER the SRC read is granted ----------
  always @(posedge clk) if (p0_grant) scan_rd <= 1'b1;

  // --- stimulus -----------------------------------------------------------------
  integer w;
  initial begin
    repeat(3) @(posedge clk); reset <= 0;
    @(posedge clk);
    p0_rd <= 1'b1;                 // kick off the SRC read (SCAN idle, so SRC wins)
    // wait for completion or watchdog
    for (w = 0; w < WATCHDOG; w = w + 1) begin
      @(posedge clk);
      if (p0_done) w = WATCHDOG;   // exit early on success
    end

    if (!p0_done) begin
      errors = errors + 1;
      $display("FAIL: P_SRC starved in S_SRC_SDRAM_WAIT — beat lost (owner released before c_dready)");
    end else if (p0_data !== SRC_DATA) begin
      errors = errors + 1;
      $display("FAIL: P_SRC got a beat but wrong data %h (exp %h)", p0_data, SRC_DATA);
    end

    $display("errors=%0d", errors);
    if (errors == 0) $display("RESULT: PASS");
    else             $display("RESULT: FAIL");
    $finish;
  end

  initial begin #100000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
