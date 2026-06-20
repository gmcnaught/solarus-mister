// tb_sdram_sweep.sv — Cache-line-width sweep for sdram_psx.
//
// Instantiates sdram_psx THREE times with BURST_BEATS = 1, 2, 4.
// Each instance has its own sdram_chip_model (separate SDRAM nets).
// The same 16-line-read trace is applied to all three instances.
// Cycle counts are summed over the 16 reads; cyc/line = total / 16.
//
// Metric: fixed 16 line-read REQUESTS at the same start addresses.
// BURST_BEATS=4 fetches 256-bit per request (more data, more cycles)
// but the comparison meaningful metric is cyc/pixel = cyc/line / (beats*4).
//
// Address design:
//   16 lines across 2 rows (8 lines per row), sequential 16-word strides.
//   Row 0 (row bits[1:0]=00): lines 0..7
//   Row 4 (row bits[1:0]=00 -> CONFLICT!) — use row 1 (bits[1:0]=01): lines 8..15
//   Each line starts at column = line_within_row * 16 (to leave room for beats=4=16 words).
//   byte_addr = (row<<12) | (bank<<10) | (col<<1)  (bank=0 throughout)
//
// Chip model storage key: {row[1:0], bank[1:0], col[8:0]} = 13 bits.
// Row 0: row[1:0]=2'b00, Row 1: row[1:0]=2'b01 — these are distinct.
// Each line's 16 words occupy columns col_base .. col_base+15 within one row.
//   line 0: row 0, cols 0..15   -> byte addr 0x000000 + 0x000
//   line 1: row 0, cols 16..31  -> byte addr 0x000000 + 0x020
//   ...
//   line 7: row 0, cols 112..127-> byte addr 0x000000 + 0x0E0
//   line 8: row 1, cols 0..15   -> byte addr 0x001000 + 0x000
//   ...  (row addr bits: addr[24:12]; row 1 => addr[24:12]=13'd1 => bit offset 0x1000)
//
// Seeding: write 16 words (2*col+0..2*col+30 bytes) per line at each row.
// All three instances seeded identically.
// Correctness check: first beat of line 0 must match seeded value 16'hAA00.
//
// Print:
//   SWEEP beats=1 cyc/line=<N>
//   SWEEP beats=2 cyc/line=<N>
//   SWEEP beats=4 cyc/line=<N>
//   errors=<N>
`timescale 1ns/1ps
`default_nettype none

module tb_sdram_sweep;

  // =========================================================================
  // Clock
  // =========================================================================
  reg clk = 0;
  always #5 clk = ~clk;   // 100 MHz

  // =========================================================================
  // Address helper: build byte address for (row, col) in bank 0
  //   addr[24:12] = row, addr[11:10] = bank (0), addr[9:1] = col, addr[0]=0
  // =========================================================================
  function [26:0] line_addr(input [12:0] row, input [8:0] col);
    line_addr = {2'b00, row, 2'b00, col, 1'b0};
  endfunction

  // =========================================================================
  // Shared error counter and sweep results
  // =========================================================================
  integer errors = 0;
  integer cyc1 = 0, cyc2 = 0, cyc4 = 0;   // total cycles per instance

  // =========================================================================
  // --- Instance A: BURST_BEATS = 1 ----------------------------------------
  // =========================================================================
  reg          initA = 1;
  reg  [26:0]  addrA = 0;
  reg  [15:0]  dinA  = 0;
  reg          weA = 0, rdA = 0;
  wire [63:0]  dout64A;
  wire         dout_readyA;
  wire         readyA;

  wire [15:0] DQA; wire [12:0] AA; wire DQMLA, DQMHA; wire [1:0] BAA;
  wire nCSA, nWEA, nRASA, nCASA, CLKA, CKEA;

  sdram_psx #(.BURST_BEATS(1)) dutA (
    .init(initA), .clk(clk), .clk_sdram(clk),
    .SDRAM_DQ(DQA), .SDRAM_A(AA), .SDRAM_DQML(DQMLA), .SDRAM_DQMH(DQMHA),
    .SDRAM_BA(BAA), .SDRAM_nCS(nCSA), .SDRAM_nWE(nWEA), .SDRAM_nRAS(nRASA),
    .SDRAM_nCAS(nCASA), .SDRAM_CLK(CLKA), .SDRAM_CKE(CKEA),
    .wtbt(2'b11), .addr(addrA), .dout(), .dout64(dout64A),
    .dout_ready(dout_readyA), .din(dinA), .din64(64'd0), .we(weA), .we_burst(1'b0), .rd(rdA), .ready(readyA)
  );
  sdram_chip_model chipA (
    .clk(clk), .DQ(DQA), .A(AA), .BA(BAA),
    .nCS(nCSA), .nRAS(nRASA), .nCAS(nCASA), .nWE(nWEA), .CKE(CKEA),
    .DQML(DQMLA), .DQMH(DQMHA), .proto_errors()
  );

  // =========================================================================
  // --- Instance B: BURST_BEATS = 2 ----------------------------------------
  // =========================================================================
  reg          initB = 1;
  reg  [26:0]  addrB = 0;
  reg  [15:0]  dinB  = 0;
  reg          weB = 0, rdB = 0;
  wire [63:0]  dout64B;
  wire         dout_readyB;
  wire         readyB;

  wire [15:0] DQB; wire [12:0] AB; wire DQMLB, DQMHB; wire [1:0] BAB;
  wire nCSB, nWEB, nRASB, nCASB, CLKB, CKEB;

  sdram_psx #(.BURST_BEATS(2)) dutB (
    .init(initB), .clk(clk), .clk_sdram(clk),
    .SDRAM_DQ(DQB), .SDRAM_A(AB), .SDRAM_DQML(DQMLB), .SDRAM_DQMH(DQMHB),
    .SDRAM_BA(BAB), .SDRAM_nCS(nCSB), .SDRAM_nWE(nWEB), .SDRAM_nRAS(nRASB),
    .SDRAM_nCAS(nCASB), .SDRAM_CLK(CLKB), .SDRAM_CKE(CKEB),
    .wtbt(2'b11), .addr(addrB), .dout(), .dout64(dout64B),
    .dout_ready(dout_readyB), .din(dinB), .din64(64'd0), .we(weB), .we_burst(1'b0), .rd(rdB), .ready(readyB)
  );
  sdram_chip_model chipB (
    .clk(clk), .DQ(DQB), .A(AB), .BA(BAB),
    .nCS(nCSB), .nRAS(nRASB), .nCAS(nCASB), .nWE(nWEB), .CKE(CKEB),
    .DQML(DQMLB), .DQMH(DQMHB), .proto_errors()
  );

  // =========================================================================
  // --- Instance C: BURST_BEATS = 4 ----------------------------------------
  // =========================================================================
  reg          initC = 1;
  reg  [26:0]  addrC = 0;
  reg  [15:0]  dinC  = 0;
  reg          weC = 0, rdC = 0;
  wire [63:0]  dout64C;
  wire         dout_readyC;
  wire         readyC;

  wire [15:0] DQC; wire [12:0] AC; wire DQMLC, DQMHC; wire [1:0] BAC;
  wire nCSC, nWEC, nRASC, nCASC, CLKC, CKEC;

  sdram_psx #(.BURST_BEATS(4)) dutC (
    .init(initC), .clk(clk), .clk_sdram(clk),
    .SDRAM_DQ(DQC), .SDRAM_A(AC), .SDRAM_DQML(DQMLC), .SDRAM_DQMH(DQMHC),
    .SDRAM_BA(BAC), .SDRAM_nCS(nCSC), .SDRAM_nWE(nWEC), .SDRAM_nRAS(nRASC),
    .SDRAM_nCAS(nCASC), .SDRAM_CLK(CLKC), .SDRAM_CKE(CKEC),
    .wtbt(2'b11), .addr(addrC), .dout(), .dout64(dout64C),
    .dout_ready(dout_readyC), .din(dinC), .din64(64'd0), .we(weC), .we_burst(1'b0), .rd(rdC), .ready(readyC)
  );
  sdram_chip_model chipC (
    .clk(clk), .DQ(DQC), .A(AC), .BA(BAC),
    .nCS(nCSC), .nRAS(nRASC), .nCAS(nCASC), .nWE(nWEC), .CKE(CKEC),
    .DQML(DQMLC), .DQMH(DQMHC), .proto_errors()
  );

  // =========================================================================
  // Tasks for instance A (BURST_BEATS=1)
  // =========================================================================
  task wait_readyA; begin @(posedge clk); while (!readyA) @(posedge clk); end endtask

  task wrA(input [26:0] a, input [15:0] d); begin
    @(posedge clk); addrA <= a; dinA <= d; weA <= 1;
    @(posedge clk); weA <= 0; wait_readyA;
  end endtask

  reg [63:0] beatA [0:7];
  task rd_lineA(input [26:0] a, input integer n); integer i; begin
    @(posedge clk); addrA <= a; rdA <= 1;
    @(posedge clk); rdA <= 0;
    for (i = 0; i < n; i = i + 1) begin
      @(posedge clk); while (!dout_readyA) @(posedge clk); beatA[i] = dout64A;
    end
    wait_readyA;
  end endtask

  // =========================================================================
  // Tasks for instance B (BURST_BEATS=2)
  // =========================================================================
  task wait_readyB; begin @(posedge clk); while (!readyB) @(posedge clk); end endtask

  task wrB(input [26:0] a, input [15:0] d); begin
    @(posedge clk); addrB <= a; dinB <= d; weB <= 1;
    @(posedge clk); weB <= 0; wait_readyB;
  end endtask

  reg [63:0] beatB [0:7];
  task rd_lineB(input [26:0] a, input integer n); integer i; begin
    @(posedge clk); addrB <= a; rdB <= 1;
    @(posedge clk); rdB <= 0;
    for (i = 0; i < n; i = i + 1) begin
      @(posedge clk); while (!dout_readyB) @(posedge clk); beatB[i] = dout64B;
    end
    wait_readyB;
  end endtask

  // =========================================================================
  // Tasks for instance C (BURST_BEATS=4)
  // =========================================================================
  task wait_readyC; begin @(posedge clk); while (!readyC) @(posedge clk); end endtask

  task wrC(input [26:0] a, input [15:0] d); begin
    @(posedge clk); addrC <= a; dinC <= d; weC <= 1;
    @(posedge clk); weC <= 0; wait_readyC;
  end endtask

  reg [63:0] beatC [0:7];
  task rd_lineC(input [26:0] a, input integer n); integer i; begin
    @(posedge clk); addrC <= a; rdC <= 1;
    @(posedge clk); rdC <= 0;
    for (i = 0; i < n; i = i + 1) begin
      @(posedge clk); while (!dout_readyC) @(posedge clk); beatC[i] = dout64C;
    end
    wait_readyC;
  end endtask

  // =========================================================================
  // Main stimulus: sequential (one instance at a time to keep
  // the address muxing straightforward).
  //
  // Trace: 16 line reads across 2 rows (8 per row), stride 16 words (=32 bytes).
  //   Row 0 (row=0, row[1:0]=2'b00): lines 0..7, col_base = line*16
  //   Row 1 (row=1, row[1:0]=2'b01): lines 8..15, col_base = (line-8)*16
  //
  // Seed words: pattern 16'hAA00 + line*16 + word_within_line
  //   e.g., line 0 word 0 = 16'hAA00, line 0 word 1 = 16'hAA01, ...
  //         line 1 word 0 = 16'hAA10, ...
  // This gives unique greppable seeded values without complex arithmetic.
  // =========================================================================

  localparam integer N_LINES  = 16;   // fixed request count for the comparison
  localparam integer N_WORDS  = 16;   // words seeded per line (covers beats=4: 4*4=16)

  // Precompute line byte-addresses (same for all 3 instances):
  //   row 0: lines 0..7  -> addr = line_addr(0, line*16)
  //   row 1: lines 8..15 -> addr = line_addr(1, (line-8)*16)
  reg [26:0] line_base [0:N_LINES-1];
  integer    li, wi;
  integer    t_start;

  initial begin
    // Compute addresses
    for (li = 0; li < 8; li = li + 1)
      line_base[li]   = line_addr(13'd0, (li * 16));
    for (li = 8; li < 16; li = li + 1)
      line_base[li]   = line_addr(13'd1, ((li - 8) * 16));

    // -----------------------------------------------------------------------
    // De-assert init together, then wait for all three to be ready
    // -----------------------------------------------------------------------
    repeat(4) @(posedge clk);
    initA <= 0; initB <= 0; initC <= 0;
    // Wait for each controller to finish its startup sequence
    wait_readyA; repeat(4) @(posedge clk);
    wait_readyB; repeat(4) @(posedge clk);
    wait_readyC; repeat(4) @(posedge clk);

    // -----------------------------------------------------------------------
    // Seed instance A (BURST_BEATS=1): same trace, 16 words per line
    // Pattern: word_val = 16'hAA00 + li*16 + wi
    // -----------------------------------------------------------------------
    for (li = 0; li < N_LINES; li = li + 1) begin
      for (wi = 0; wi < N_WORDS; wi = wi + 1) begin
        wrA(line_base[li] + (wi << 1), 16'hAA00 + (li * 16) + wi);
      end
    end

    // -----------------------------------------------------------------------
    // Seed instance B (BURST_BEATS=2): same values
    // -----------------------------------------------------------------------
    for (li = 0; li < N_LINES; li = li + 1) begin
      for (wi = 0; wi < N_WORDS; wi = wi + 1) begin
        wrB(line_base[li] + (wi << 1), 16'hAA00 + (li * 16) + wi);
      end
    end

    // -----------------------------------------------------------------------
    // Seed instance C (BURST_BEATS=4): same values
    // -----------------------------------------------------------------------
    for (li = 0; li < N_LINES; li = li + 1) begin
      for (wi = 0; wi < N_WORDS; wi = wi + 1) begin
        wrC(line_base[li] + (wi << 1), 16'hAA00 + (li * 16) + wi);
      end
    end

    // -----------------------------------------------------------------------
    // SWEEP A: BURST_BEATS = 1 (1 beat = 4 words = 64-bit per request)
    // Correctness probe: read line 0 FIRST and capture beat before the loop
    // overwrites it.
    // -----------------------------------------------------------------------
    rd_lineA(line_base[0], 1);
    if (beatA[0] !== 64'hAA03_AA02_AA01_AA00) begin
      errors = errors + 1;
      $display("A beat0 bad: %h (expected AA03_AA02_AA01_AA00)", beatA[0]);
    end
    // Now run the full timed sweep (includes line 0 again — consistent metric)
    for (li = 0; li < N_LINES; li = li + 1) begin
      t_start = $time;
      rd_lineA(line_base[li], 1);   // 1 beat per line
      cyc1 = cyc1 + (($time - t_start) / 10);  // 10ns per cycle
    end

    // -----------------------------------------------------------------------
    // SWEEP B: BURST_BEATS = 2 (2 beats = 8 words = 128-bit per request)
    // -----------------------------------------------------------------------
    rd_lineB(line_base[0], 2);
    if (beatB[0] !== 64'hAA03_AA02_AA01_AA00) begin
      errors = errors + 1;
      $display("B beat0 bad: %h (expected AA03_AA02_AA01_AA00)", beatB[0]);
    end
    for (li = 0; li < N_LINES; li = li + 1) begin
      t_start = $time;
      rd_lineB(line_base[li], 2);   // 2 beats per line
      cyc2 = cyc2 + (($time - t_start) / 10);
    end

    // -----------------------------------------------------------------------
    // SWEEP C: BURST_BEATS = 4 (4 beats = 16 words = 256-bit per request)
    // -----------------------------------------------------------------------
    rd_lineC(line_base[0], 4);
    if (beatC[0] !== 64'hAA03_AA02_AA01_AA00) begin
      errors = errors + 1;
      $display("C beat0 bad: %h (expected AA03_AA02_AA01_AA00)", beatC[0]);
    end
    for (li = 0; li < N_LINES; li = li + 1) begin
      t_start = $time;
      rd_lineC(line_base[li], 4);   // 4 beats per line
      cyc4 = cyc4 + (($time - t_start) / 10);
    end

    // -----------------------------------------------------------------------
    // Results
    // -----------------------------------------------------------------------
    $display("SWEEP beats=1 cyc/line=%0d", cyc1 / N_LINES);
    $display("SWEEP beats=2 cyc/line=%0d", cyc2 / N_LINES);
    $display("SWEEP beats=4 cyc/line=%0d", cyc4 / N_LINES);
    $display("errors=%0d", errors);
    $finish;
  end
endmodule
`default_nettype wire
