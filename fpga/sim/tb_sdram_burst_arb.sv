// tb_sdram_burst_arb.sv — TDD test for sdram_burst_arb (Tasks 2 + 3).
//
// Test 1 (Task 2): scan read path.
//   Seeds SDRAM by preloading the mt48lc16m16a2 model's bank array directly
//   (jtframe's own read-test methodology), then reads back via scan_rd.
//   Verifies 4 assembled 64-bit qwords == expected.
//
// Test 2 (Task 3): P_DST write-burst + RMW read-back.
//   Writes 2 qwords (8 × 16-bit words) through the real write path, then
//   reads them back via dst_rd and asserts exact equality.
//   This is the RMW pattern that livelocked the old sdram_psx controller.
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
// DUT signals — P_SCAN
// ---------------------------------------------------------------------------
reg  [26:0] scan_addr;
reg         scan_rd;
reg  [ 7:0] scan_burst;
wire        scan_busy;
wire [63:0] scan_dout64;
wire        scan_dready;

// ---------------------------------------------------------------------------
// DUT signals — P_DST
// ---------------------------------------------------------------------------
reg  [26:0] dst_addr;
reg         dst_rd;
reg  [ 7:0] dst_burst;
reg         dst_we_burst;
reg  [ 7:0] dst_we_qcnt;
reg  [63:0] dst_din64;
wire        dst_busy;
wire [63:0] dst_dout64;
wire        dst_dready;
wire        dst_wr_accept;

// ---------------------------------------------------------------------------
// Misc
// ---------------------------------------------------------------------------
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
// DUT — sdram_burst_arb
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

    .dst_addr   ( dst_addr   ),
    .dst_rd     ( dst_rd     ),
    .dst_burst  ( dst_burst  ),
    .dst_we_burst( dst_we_burst ),
    .dst_we_qcnt( dst_we_qcnt  ),
    .dst_din64  ( dst_din64  ),
    .dst_busy   ( dst_busy   ),
    .dst_dout64 ( dst_dout64 ),
    .dst_dready ( dst_dready ),
    .dst_wr_accept( dst_wr_accept ),

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
// Test 1 data: 16 words (4 qwords) for scan read
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
// Test 2 data: 2 qwords to write + read back via dst path
// ---------------------------------------------------------------------------
// Use bank 2, offset 0x100 (different from scan test to avoid collision)
localparam [26:0] DST_BYTE_ADDR = {2'd2, 24'h000100, 1'b0};

// 2 qwords = 8 × 16-bit words (known patterns)
localparam [63:0]
    DQ0_WR = 64'hDEAD_BEEF_1234_5678,   // qword 0 to write
    DQ1_WR = 64'hCAFE_BABE_ABCD_EF01;   // qword 1 to write

// ---------------------------------------------------------------------------
// Common test variables
// ---------------------------------------------------------------------------
integer i;
integer timeout_cnt;
integer qword_idx;
reg [63:0] captured [0:3];
reg result_ok;

// ---------------------------------------------------------------------------
// Test sequence
// ---------------------------------------------------------------------------
initial begin
    // Init seed words for scan test
    seed_words[0]=W0;   seed_words[1]=W1;   seed_words[2]=W2;   seed_words[3]=W3;
    seed_words[4]=W4;   seed_words[5]=W5;   seed_words[6]=W6;   seed_words[7]=W7;
    seed_words[8]=W8;   seed_words[9]=W9;   seed_words[10]=W10; seed_words[11]=W11;
    seed_words[12]=W12; seed_words[13]=W13; seed_words[14]=W14; seed_words[15]=W15;

    rst          = 1'b1;
    scan_addr    = 27'd0;
    scan_rd      = 1'b0;
    scan_burst   = 8'd0;
    dst_addr     = 27'd0;
    dst_rd       = 1'b0;
    dst_burst    = 8'd0;
    dst_we_burst = 1'b0;
    dst_we_qcnt  = 8'd0;
    dst_din64    = 64'd0;
    result_ok    = 1'b1;

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

    // =======================================================================
    // TEST 1: Scan read path (Task 2 regression)
    // =======================================================================
    // SEED: preload bank 3 directly (jtframe read-test methodology).
    for (i = 0; i < 16; i = i + 1)
        u_sdram.Bank3[TEST_WORD_ADDR + i] = seed_words[i];

    // SCAN READ: 4 qwords starting at TEST_BYTE_ADDR
    @(negedge clk);
    scan_addr  = TEST_BYTE_ADDR;
    scan_burst = 8'd4;      // 4 qwords = 16 jtframe 16-bit words
    scan_rd    = 1'b1;

    // Collect the 4 qword beats
    qword_idx = 0;
    begin : collect_scan_qwords
        for (timeout_cnt = 0; timeout_cnt < 5000; timeout_cnt = timeout_cnt + 1) begin
            @(posedge clk);
            if (scan_dready) begin
                captured[qword_idx] = scan_dout64;
                qword_idx = qword_idx + 1;
                if (qword_idx == 4) begin
                    scan_rd = 1'b0;
                    disable collect_scan_qwords;
                end
            end
        end
        if (qword_idx < 4) begin
            $display("RESULT: FAIL — scan: only %0d of 4 qwords received", qword_idx);
            $finish;
        end
    end

    // Verify scan qwords
    if (captured[0] !== Q0_EXP) begin
        $display("RESULT: FAIL — scan Q0 got %016h expected %016h", captured[0], Q0_EXP);
        result_ok = 1'b0;
    end
    if (captured[1] !== Q1_EXP) begin
        $display("RESULT: FAIL — scan Q1 got %016h expected %016h", captured[1], Q1_EXP);
        result_ok = 1'b0;
    end
    if (captured[2] !== Q2_EXP) begin
        $display("RESULT: FAIL — scan Q2 got %016h expected %016h", captured[2], Q2_EXP);
        result_ok = 1'b0;
    end
    if (captured[3] !== Q3_EXP) begin
        $display("RESULT: FAIL — scan Q3 got %016h expected %016h", captured[3], Q3_EXP);
        result_ok = 1'b0;
    end

    // Wait for scan to go idle
    begin : wait_scan_idle
        for (timeout_cnt = 0; timeout_cnt < 1000; timeout_cnt = timeout_cnt + 1) begin
            @(posedge clk);
            if (!scan_busy) disable wait_scan_idle;
        end
    end

    repeat (8) @(posedge clk);

    // =======================================================================
    // TEST 2: P_DST write-burst + RMW read-back (Task 3)
    //
    // Protocol:
    //   a) Assert dst_we_burst=1, dst_addr=ADDR, dst_we_qcnt=2, dst_din64=DQ0
    //   b) Wait for dst_wr_accept to advance to DQ1
    //   c) Wait for dst_busy to deassert (write complete)
    //   d) Issue dst_rd=1, dst_addr=ADDR, dst_burst=2
    //   e) Collect 2 qwords from dst_dready / dst_dout64
    //   f) Assert DQ0 == DQ0_WR, DQ1 == DQ1_WR
    // =======================================================================

    // --- WRITE 2 qwords ---
    // Step 1: assert dst_we_burst to start the write.
    @(negedge clk);
    dst_addr     = DST_BYTE_ADDR;
    dst_we_qcnt  = 8'd2;         // 2 qwords = 8 × 16-bit words
    dst_din64    = DQ0_WR;       // first qword ready immediately
    dst_we_burst = 1'b1;

    // Step 2: once dst_busy asserts (arbiter accepted the write request and
    // left S_IDLE), immediately deassert dst_we_burst.  Keeping it asserted
    // past the first IDLE→S_WR_START transition would re-trigger another write
    // the instant the arbiter returns to S_IDLE after this write completes.
    begin : wait_wr_busy
        for (timeout_cnt = 0; timeout_cnt < 1000; timeout_cnt = timeout_cnt + 1) begin
            @(posedge clk);
            if (dst_busy) begin
                @(negedge clk);
                dst_we_burst = 1'b0;
                disable wait_wr_busy;
            end
        end
        $display("RESULT: FAIL — dst write: timed out waiting for dst_busy to assert");
        $finish;
    end

    // Step 3: wait for dst_wr_accept to signal qword-0 consumed; then present qword-1.
    begin : wait_wr_accept
        for (timeout_cnt = 0; timeout_cnt < 2000; timeout_cnt = timeout_cnt + 1) begin
            @(posedge clk);
            if (dst_wr_accept) begin
                // Arbiter consumed qword-0; present qword-1 on next negedge
                @(negedge clk);
                dst_din64 = DQ1_WR;
                disable wait_wr_accept;
            end
        end
        $display("RESULT: FAIL — dst write: timed out waiting for dst_wr_accept");
        $finish;
    end

    // Step 4: wait for arbiter to go idle (write complete)
    begin : wait_wr_done
        for (timeout_cnt = 0; timeout_cnt < 5000; timeout_cnt = timeout_cnt + 1) begin
            @(posedge clk);
            if (!dst_busy) begin
                dst_din64 = 64'd0;
                disable wait_wr_done;
            end
        end
        $display("RESULT: FAIL — dst write: timed out waiting for dst_busy to clear");
        $finish;
    end

    repeat (8) @(posedge clk);

    // --- READ BACK 2 qwords via dst_rd ---
    @(negedge clk);
    dst_addr  = DST_BYTE_ADDR;
    dst_burst = 8'd2;       // 2 qwords = 8 × 16-bit words
    dst_rd    = 1'b1;

    // Collect 2 qwords from dst_dready
    qword_idx = 0;
    begin : collect_dst_qwords
        for (timeout_cnt = 0; timeout_cnt < 5000; timeout_cnt = timeout_cnt + 1) begin
            @(posedge clk);
            if (dst_dready) begin
                captured[qword_idx] = dst_dout64;
                qword_idx = qword_idx + 1;
                if (qword_idx == 2) begin
                    dst_rd = 1'b0;
                    disable collect_dst_qwords;
                end
            end
        end
        if (qword_idx < 2) begin
            $display("RESULT: FAIL — dst read: only %0d of 2 qwords received", qword_idx);
            $finish;
        end
    end

    // Wait for dst to go idle
    begin : wait_dst_idle
        for (timeout_cnt = 0; timeout_cnt < 1000; timeout_cnt = timeout_cnt + 1) begin
            @(posedge clk);
            if (!dst_busy) disable wait_dst_idle;
        end
    end

    // Verify DST read-back == written qwords (RMW check)
    if (captured[0] !== DQ0_WR) begin
        $display("RESULT: FAIL — dst RMW Q0 got %016h expected %016h", captured[0], DQ0_WR);
        result_ok = 1'b0;
    end
    if (captured[1] !== DQ1_WR) begin
        $display("RESULT: FAIL — dst RMW Q1 got %016h expected %016h", captured[1], DQ1_WR);
        result_ok = 1'b0;
    end

    // =======================================================================
    // Report
    // =======================================================================
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

// ---------------------------------------------------------------------------
// Debug monitor: print detailed info at every jt_dok and SDRAM CMD events
// ---------------------------------------------------------------------------
`ifdef DEBUG_BURST_ARB
// Access internal signals from dut hierarchy
wire [2:0] dbg_state    = dut.state;
wire [1:0] dbg_beat_pos = dut.beat_pos;
wire [9:0] dbg_word_cnt = dut.word_cnt;
wire       dbg_jt_rd    = dut.jt_rd;
wire       dbg_jt_wr    = dut.jt_wr;
wire       dbg_jt_ack   = dut.jt_ack;
wire       dbg_jt_dok   = dut.jt_dok;
wire [15:0] dbg_jt_dout = dut.jt_dout;
wire [1:0]  dbg_wr_beat  = dut.wr_beat;
wire [9:0]  dbg_wr_wc    = dut.wr_word_cnt;

// Log every clk posedge when interesting
integer dbg_clk_cnt;
always @(posedge clk) begin
    dbg_clk_cnt <= dbg_clk_cnt + 1;
    if (dbg_state != 0 || dbg_jt_dok || dbg_jt_ack) begin
        $display("CLK#%0d@%0t st=%0d rd=%b wr=%b ack=%b dok=%b dout=%04h beat=%0d wc=%0d wbeat=%0d wwc=%0d",
            dbg_clk_cnt, $time,
            dbg_state, dbg_jt_rd, dbg_jt_wr, dbg_jt_ack, dbg_jt_dok,
            dbg_jt_dout, dbg_beat_pos, dbg_word_cnt,
            dbg_wr_beat, dbg_wr_wc);
    end
end

// Log SDRAM command events (monitors sdram_a/ba/nras/ncas/nwe at clk_sdram)
always @(posedge clk_sdram) begin
    if (!sdram_ncs) begin
        if (!sdram_nras && sdram_ncas && sdram_nwe)
            $display("  SDRAM_ACT @%0t ba=%0d row=%0d", $time, sdram_ba, sdram_a);
        else if (sdram_nras && !sdram_ncas && sdram_nwe)
            $display("  SDRAM_RD  @%0t ba=%0d col=%0d(0x%0h)", $time, sdram_ba, sdram_a & 13'h3ff, sdram_a & 13'h3ff);
        else if (sdram_nras && !sdram_ncas && !sdram_nwe)
            $display("  SDRAM_WR  @%0t ba=%0d col=%0d(0x%0h) dq=%04h", $time, sdram_ba, sdram_a & 13'h3ff, sdram_a & 13'h3ff, sdram_dq);
        else if (!sdram_nras && !sdram_ncas && !sdram_nwe)
            $display("  SDRAM_LMR @%0t a=%04h", $time, sdram_a);
        else if (!sdram_nras && !sdram_ncas && sdram_nwe)
            $display("  SDRAM_REF @%0t", $time);
        else if (!sdram_nras && sdram_ncas && !sdram_nwe)
            $display("  SDRAM_PRE @%0t ba=%0d a10=%b", $time, sdram_ba, sdram_a[10]);
    end
end

initial dbg_clk_cnt = 0;
`endif // DEBUG_BURST_ARB

endmodule
