// tb_sdram_burst_arb.sv — TDD test for sdram_burst_arb (Task 2: scan read path).
//
// Seeds SDRAM the way jtframe's own read regressions do
// (ver/sdram/burst_sdram_64mb): preload the mt48lc16m16a2 model's bank array
// directly, then read it back through the controller. This keeps the read-path
// test independent of the (Task 3) write path.
//
//   1. Preload u_sdram.Bank3[TEST_WORD_ADDR .. +15] = W0..W15.
//   2. Issue scan_rd with scan_burst=4 (4 qwords = 16 jtframe 16-bit words).
//   3. Assert the 4 assembled scan_dout64 beats equal the expected qwords.
//
// Expected qwords (little-endian, first 16-bit word in [15:0]):
//   Q0 = { W3,  W2,  W1,  W0  }   ...   Q3 = { W15, W14, W13, W12 }
//
// Passes when RESULT: PASS is printed; fails with RESULT: FAIL.
`timescale 1ns/1ps

module tb_sdram_burst_arb;

localparam integer PERIOD   = 10;   // 100 MHz system clock period (ns)
localparam integer AW       = 23;
localparam integer HF       = 1;

// ---------------------------------------------------------------------------
// Clocks and reset (same convention as the jtframe burst tests)
// ---------------------------------------------------------------------------
reg clk;
reg clk_sdram;
reg rst;

initial begin
    clk       = 0;
    clk_sdram = 0;
    forever begin
        #(PERIOD/2) clk_sdram = ~clk_sdram;
        #5          clk       =  clk_sdram;
    end
end

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
reg  [26:0] scan_addr;
reg         scan_rd;
reg  [ 7:0] scan_burst;
wire        scan_busy;
wire [63:0] scan_dout64;
wire        scan_dready;
wire        init_out;

// SDRAM physical pins
wire [15:0] sdram_dq;
wire [12:0] sdram_a;
wire        sdram_dqml;
wire        sdram_dqmh;
wire [ 1:0] sdram_ba;
wire        sdram_nwe;
wire        sdram_ncas;
wire        sdram_nras;
wire        sdram_ncs;
wire        sdram_cke;

// ---------------------------------------------------------------------------
// DUT — sdram_burst_arb (read-only; contains the jtframe_burst_sdram instance)
// ---------------------------------------------------------------------------
sdram_burst_arb #(
    .AW      ( AW ),
    .HF      ( HF )
) dut (
    .clk        ( clk        ),
    .rst        ( rst        ),
    .init       ( init_out   ),

    .scan_addr  ( scan_addr  ),
    .scan_rd    ( scan_rd    ),
    .scan_burst ( scan_burst ),
    .scan_busy  ( scan_busy  ),
    .scan_dout64( scan_dout64),
    .scan_dready( scan_dready),

    .sdram_dq   ( sdram_dq   ),
    .sdram_a    ( sdram_a    ),
    .sdram_dqml ( sdram_dqml ),
    .sdram_dqmh ( sdram_dqmh ),
    .sdram_ba   ( sdram_ba   ),
    .sdram_nwe  ( sdram_nwe  ),
    .sdram_ncas ( sdram_ncas ),
    .sdram_nras ( sdram_nras ),
    .sdram_ncs  ( sdram_ncs  ),
    .sdram_cke  ( sdram_cke  )
);

// ---------------------------------------------------------------------------
// SDRAM chip model (64MB geometry: col_bits=10, matching jtframe's 64mb test)
// ---------------------------------------------------------------------------
mt48lc16m16a2 #(
    .addr_bits ( 13 ),
    .col_bits  ( 10 )
) u_sdram (
    .Clk        ( clk_sdram   ),
    .Cke        ( sdram_cke   ),
    .Dq         ( sdram_dq    ),
    .Addr       ( sdram_a     ),
    .Ba         ( sdram_ba    ),
    .Cs_n       ( sdram_ncs   ),
    .Ras_n      ( sdram_nras  ),
    .Cas_n      ( sdram_ncas  ),
    .We_n       ( sdram_nwe   ),
    .Dqm        ( {sdram_dqmh, sdram_dqml} ),
    .downloading( 1'b0        ),
    .VS         ( 1'b0        ),
    .frame_cnt  ( 0           )
);

// ---------------------------------------------------------------------------
// Test data: 16 words (4 qwords)
// ---------------------------------------------------------------------------
localparam [15:0]
    W0  = 16'hA001, W1  = 16'hA002, W2  = 16'hA003, W3  = 16'hA004,
    W4  = 16'hA005, W5  = 16'hA006, W6  = 16'hA007, W7  = 16'hA008,
    W8  = 16'hA009, W9  = 16'hA00A, W10 = 16'hA00B, W11 = 16'hA00C,
    W12 = 16'hA00D, W13 = 16'hA00E, W14 = 16'hA00F, W15 = 16'hA010;

reg [15:0] seed_words [0:15];

// Expected qwords (little-endian: first word in [15:0])
localparam [63:0]
    Q0_EXP = {W3,  W2,  W1,  W0 },
    Q1_EXP = {W7,  W6,  W5,  W4 },
    Q2_EXP = {W11, W10, W9,  W8 },
    Q3_EXP = {W15, W14, W13, W12};

// Byte address: bank=3 (bits[26:25]), 24-bit word offset in bits[24:1], bit[0]=byte.
// (Full 27-bit concat: 2 + 24 + 1 = 27, so the bank lands in [26:25] as intended.)
localparam [26:0] TEST_BYTE_ADDR = {2'd3, 24'h000080, 1'b0};
localparam [AW-1:0] TEST_WORD_ADDR = TEST_BYTE_ADDR[AW:1];  // == jt_addr the arb presents

// ---------------------------------------------------------------------------
// Test sequence
// ---------------------------------------------------------------------------
integer i;
integer timeout_cnt;
integer word_idx;
reg [63:0] captured [0:3];
reg result_ok;

initial begin
    seed_words[0]=W0;   seed_words[1]=W1;   seed_words[2]=W2;   seed_words[3]=W3;
    seed_words[4]=W4;   seed_words[5]=W5;   seed_words[6]=W6;   seed_words[7]=W7;
    seed_words[8]=W8;   seed_words[9]=W9;   seed_words[10]=W10; seed_words[11]=W11;
    seed_words[12]=W12; seed_words[13]=W13; seed_words[14]=W14; seed_words[15]=W15;

    rst        = 1'b1;
    scan_addr  = 27'd0;
    scan_rd    = 1'b0;
    scan_burst = 8'd0;
    result_ok  = 1'b1;

    repeat (20) @(posedge clk);
    rst = 1'b0;

    // Wait for SDRAM init to complete (init deasserts)
    begin : wait_init
        for (i = 0; i < 25_000; i = i + 1) begin
            @(posedge clk);
            if (!init_out) disable wait_init;
        end
        $display("RESULT: FAIL — timed out waiting for SDRAM init");
        $finish;
    end

    repeat (8) @(posedge clk);

    // -----------------------------------------------------------------------
    // SEED: preload bank 3 directly (jtframe read-test methodology). Controller
    // word address X maps flat to Bank3[X] (proven by ver/sdram/burst_sdram_64mb,
    // where the file loaded into Bank3 matches reads at the same flat address).
    // -----------------------------------------------------------------------
    for (i = 0; i < 16; i = i + 1)
        u_sdram.Bank3[TEST_WORD_ADDR + i] = seed_words[i];

    // -----------------------------------------------------------------------
    // SCAN READ: 4 qwords starting at TEST_BYTE_ADDR
    // -----------------------------------------------------------------------
    @(negedge clk);
    scan_addr  = TEST_BYTE_ADDR;
    scan_burst = 8'd4;      // 4 qwords = 16 jtframe 16-bit words
    scan_rd    = 1'b1;

    // Collect the 4 qword beats of THIS burst. The scan_dready pulses occur
    // DURING S_READ (while scan_busy is still high), so monitor immediately
    // after asserting scan_rd — do NOT wait for scan_busy to clear first (it
    // only clears after all pulses are done). Drop scan_rd the moment the 4th
    // qword is captured so the FSM returns to IDLE instead of re-firing the
    // held-rd burst.
    word_idx = 0;
    begin : collect_qwords
        for (timeout_cnt = 0; timeout_cnt < 5000; timeout_cnt = timeout_cnt + 1) begin
            @(posedge clk);
            if (scan_dready) begin
                captured[word_idx] = scan_dout64;
                word_idx = word_idx + 1;
                if (word_idx == 4) begin
                    scan_rd = 1'b0;
                    disable collect_qwords;
                end
            end
        end
        if (word_idx < 4) begin
            $display("RESULT: FAIL — only %0d of 4 qwords received", word_idx);
            $finish;
        end
    end

    // -----------------------------------------------------------------------
    // Verify
    // -----------------------------------------------------------------------
    if (captured[0] !== Q0_EXP) begin
        $display("RESULT: FAIL — Q0 got %016h expected %016h", captured[0], Q0_EXP);
        result_ok = 1'b0;
    end
    if (captured[1] !== Q1_EXP) begin
        $display("RESULT: FAIL — Q1 got %016h expected %016h", captured[1], Q1_EXP);
        result_ok = 1'b0;
    end
    if (captured[2] !== Q2_EXP) begin
        $display("RESULT: FAIL — Q2 got %016h expected %016h", captured[2], Q2_EXP);
        result_ok = 1'b0;
    end
    if (captured[3] !== Q3_EXP) begin
        $display("RESULT: FAIL — Q3 got %016h expected %016h", captured[3], Q3_EXP);
        result_ok = 1'b0;
    end

    if (result_ok)
        $display("RESULT: PASS");
    else
        $display("RESULT: FAIL");

    $finish;
end

// Safety timeout
initial begin
    #20_000_000;
    $display("RESULT: FAIL — global simulation timeout");
    $finish;
end

endmodule
