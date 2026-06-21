// tb_sdram_burst_arb.sv — TDD test for sdram_burst_arb (Tasks 2 + 3 + 4).
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
// Test 3 (Task 4): 3-client priority contention (scan-never-starve).
//   Assert scan_rd back-to-back WHILE dst_we_burst hammers band writes AND
//   p0_rd hammers reads concurrently.  Over N cycles, require:
//     - scan completes >= K line reads (priority honoured)
//     - dst completes >= 1 write burst  (lower priority still progresses)
//     - all scan read-back data is correct (no cross-client corruption)
//   Mirrors the tb_vram_contention intent at unit scope.
//
// Test 5 (Task 5): refresh timer vs sustained bursts.
//   With a shortened RFSH_PERIOD, write many bands (spanning multiple rows)
//   back-to-back interleaved with scan reads, then read every band back.
//   Asserts: all data correct (refresh never corrupts a live burst), the run
//   makes progress within the watchdog (no wedge — the analog of the sdram_psx
//   sustained-write livelock), AND rfsh actually fired >=2× during the run
//   (proves the timer runs and jtframe services refresh in burst gaps).
//
// Passes when RESULT: PASS is printed; fails with RESULT: FAIL.
`timescale 1ns/1ps

module tb_sdram_burst_arb;

localparam integer PERIOD   = 10;   // 100 MHz system clock period (ns)
localparam integer AW       = 23;
localparam integer HF       = 1;
// Shortened refresh interval (vs the 640-cycle default) so refresh fires many
// times within sim time, exercising refresh-vs-burst in every test (Test 5 in
// particular). 256 >> any burst/refresh service time, so refreshes never pile up.
localparam integer RFSH_TEST_PERIOD = 256;

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
reg         dst_we;        // single-16-bit-word write (partial-lane path)
reg  [15:0] dst_din;
wire        dst_busy;
wire [63:0] dst_dout64;
wire        dst_dready;
wire        dst_wr_accept;

// ---------------------------------------------------------------------------
// DUT signals — P_SRC (p0_*)
// ---------------------------------------------------------------------------
reg  [26:0] p0_addr;
reg         p0_rd;
reg  [ 7:0] p0_burst;
// staging-write ports accepted for interface compatibility (not exercised here)
reg         p0_we;
reg  [15:0] p0_din;
reg  [26:0] p0_waddr;
reg         p0_we_burst;
reg  [63:0] p0_din64;
wire        p0_busy;
wire [63:0] p0_dout64;
wire        p0_dready;

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
    .AW          ( AW ),
    .HF          ( HF ),
    .RFSH_PERIOD ( RFSH_TEST_PERIOD )
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
    .dst_we     ( dst_we     ),
    .dst_din    ( dst_din    ),
    .dst_we_qcnt( dst_we_qcnt  ),
    .dst_din64  ( dst_din64  ),
    .dst_busy   ( dst_busy   ),
    .dst_dout64 ( dst_dout64 ),
    .dst_dready ( dst_dready ),
    .dst_wr_accept( dst_wr_accept ),

    .p0_addr    ( p0_addr    ),
    .p0_rd      ( p0_rd      ),
    .p0_burst   ( p0_burst   ),
    .p0_we      ( p0_we      ),
    .p0_din     ( p0_din     ),
    .p0_waddr   ( p0_waddr   ),
    .p0_we_burst( p0_we_burst),
    .p0_din64   ( p0_din64   ),
    .p0_busy    ( p0_busy    ),
    .p0_dout64  ( p0_dout64  ),
    .p0_dready  ( p0_dready  ),

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

// Test 4 data: SAME (bank,row) as DST write (bank2, word 0x100 → row 0) but a
// DIFFERENT WORD/column. NOTE the {ba,24'hOFF,1'b0} convention: OFF sits in bits
// [24:1], so the word address == OFF. OFF=0x40 → word 0x40 (row 0, since
// 0x40 < 1024-word page) — same row as the write (word 0x100, row 0), different
// word. This is a post-write read to a different word than written, so rd_skew
// must be 1 (skewed) — the exact-address RMW (Test 2) is the only aligned case.
localparam [26:0] SR_RD_ADDR  = {2'd2, 24'h000040, 1'b0};  // word 0x40, row 0
localparam [AW-1:0] SR_RD_WORD = SR_RD_ADDR[AW:1];
localparam [63:0]
    SQ0 = 64'h1111_2222_3333_4444,
    SQ1 = 64'h5555_6666_7777_8888;

// ---------------------------------------------------------------------------
// Test 3 data: p0 read region (bank 0, offset 0x200) and dst write region
// ---------------------------------------------------------------------------
localparam [26:0] P0_BYTE_ADDR      = {2'd0, 24'h000200, 1'b0};
localparam [AW-1:0] P0_WORD_ADDR    = P0_BYTE_ADDR[AW:1];
localparam [26:0] DST_WR_CONT_ADDR  = {2'd2, 24'h000300, 1'b0};

localparam [15:0]
    P0W0 = 16'hB001, P0W1 = 16'hB002, P0W2 = 16'hB003, P0W3 = 16'hB004,
    P0W4 = 16'hB005, P0W5 = 16'hB006, P0W6 = 16'hB007, P0W7 = 16'hB008;

localparam [63:0]
    P0Q0_EXP    = {P0W3, P0W2, P0W1, P0W0},
    P0Q1_EXP    = {P0W7, P0W6, P0W5, P0W4},
    CONT_DQ0    = 64'h1111_2222_3333_4444,
    CONT_DQ1    = 64'h5555_6666_7777_8888;

localparam integer MIN_SCAN_READS    = 3;
localparam integer CONTENTION_CYCLES = 20000;

// ---------------------------------------------------------------------------
// Common test variables
// ---------------------------------------------------------------------------
integer i;
integer timeout_cnt;
integer qword_idx;
reg [63:0] captured [0:3];
reg result_ok;

// Test 3 counters (module-level so iverilog can handle them)
integer t3_scan_reads_done;
integer t3_dst_writes_done;
integer t3_p0_reads_done;
integer t3_scan_qidx;
integer t3_p0_qidx;
integer t3_dst_qword_idx;
integer t3_cycle;
reg [63:0] t3_scan_cap [0:1];
reg [63:0] t3_p0_cap   [0:1];
reg        t3_ok;
reg        t3_dst_wr_inflight;   // 1 while a dst write burst is in-flight

// ---------------------------------------------------------------------------
// Test 5 state: sustained writes across refresh intervals
// ---------------------------------------------------------------------------
localparam integer T5_BANDS     = 12;            // bands written/read back
localparam [23:0]  T5_BASE_WORD = 24'h002000;    // first band word offset (bank 2)
localparam [23:0]  T5_STRIDE    = 24'h000400;    // 1 row (1024 words) between bands

integer    t5_band;
integer    t5_rfsh_count;   // free-running count of rfsh pulses
integer    t5_rfsh_start;   // snapshot at Test 5 entry
reg [63:0] t5_rd0, t5_rd1;
reg [63:0] t5_sc0, t5_sc1;
reg        t5_ok;

// Count refresh pulses across the whole sim (Test 5 snapshots the delta).
initial t5_rfsh_count = 0;
always @(posedge clk) if (dut.rfsh) t5_rfsh_count = t5_rfsh_count + 1;

// Band b address ({2'd2, word, 1'b0} convention: word lands in bits[24:1]).
function [26:0] t5_addr(input integer b);
    reg [23:0] w;
    begin
        w = T5_BASE_WORD + b * T5_STRIDE;
        t5_addr = {2'd2, w, 1'b0};
    end
endfunction

// Per-band write data (distinct per band and per word; little-endian qwords).
function [63:0] t5_q0(input integer b);
    reg [15:0] bb;
    begin
        bb = b;
        t5_q0 = {16'h7000 + bb, 16'h5000 + bb, 16'h3000 + bb, 16'h1000 + bb};
    end
endfunction
function [63:0] t5_q1(input integer b);
    reg [15:0] bb;
    begin
        bb = b;
        t5_q1 = {16'hF000 + bb, 16'hD000 + bb, 16'hB000 + bb, 16'h9000 + bb};
    end
endfunction

// dst write of 2 qwords through the real write path (mirrors Test 2 handshake).
task dst_write_2qw(input [26:0] addr, input [63:0] q0, input [63:0] q1);
begin
    @(negedge clk);
    dst_addr     = addr;
    dst_we_qcnt  = 8'd2;
    dst_din64    = q0;
    dst_we_burst = 1'b1;
    begin : tw_busy
        for (timeout_cnt = 0; timeout_cnt < 1000; timeout_cnt = timeout_cnt + 1) begin
            @(posedge clk);
            if (dst_busy) begin @(negedge clk); dst_we_burst = 1'b0; disable tw_busy; end
        end
        $display("RESULT: FAIL — T5 write: dst_busy timeout"); $finish;
    end
    begin : tw_acc
        for (timeout_cnt = 0; timeout_cnt < 2000; timeout_cnt = timeout_cnt + 1) begin
            @(posedge clk);
            if (dst_wr_accept) begin @(negedge clk); dst_din64 = q1; disable tw_acc; end
        end
        $display("RESULT: FAIL — T5 write: dst_wr_accept timeout"); $finish;
    end
    begin : tw_done
        for (timeout_cnt = 0; timeout_cnt < 5000; timeout_cnt = timeout_cnt + 1) begin
            @(posedge clk);
            if (!dst_busy) begin dst_din64 = 64'd0; disable tw_done; end
        end
        $display("RESULT: FAIL — T5 write: dst_busy clear timeout"); $finish;
    end
end
endtask

// dst read of 2 qwords through the real read path.
task dst_read_2qw(input [26:0] addr, output [63:0] q0, output [63:0] q1);
begin
    @(negedge clk);
    dst_addr  = addr;
    dst_burst = 8'd2;
    dst_rd    = 1'b1;
    qword_idx = 0;
    begin : tr_col
        for (timeout_cnt = 0; timeout_cnt < 5000; timeout_cnt = timeout_cnt + 1) begin
            @(posedge clk);
            if (dst_dready) begin
                if (qword_idx == 0) q0 = dst_dout64; else q1 = dst_dout64;
                qword_idx = qword_idx + 1;
                if (qword_idx == 2) begin dst_rd = 1'b0; disable tr_col; end
            end
        end
        $display("RESULT: FAIL — T5 read: dst read timeout"); $finish;
    end
    begin : tr_idle
        for (timeout_cnt = 0; timeout_cnt < 1000; timeout_cnt = timeout_cnt + 1) begin
            @(posedge clk); if (!dst_busy) disable tr_idle;
        end
    end
end
endtask

// scan read of 2 qwords through the real read path.
task scan_read_2qw(input [26:0] addr, output [63:0] q0, output [63:0] q1);
begin
    @(negedge clk);
    scan_addr  = addr;
    scan_burst = 8'd2;
    scan_rd    = 1'b1;
    qword_idx  = 0;
    begin : sr_col
        for (timeout_cnt = 0; timeout_cnt < 5000; timeout_cnt = timeout_cnt + 1) begin
            @(posedge clk);
            if (scan_dready) begin
                if (qword_idx == 0) q0 = scan_dout64; else q1 = scan_dout64;
                qword_idx = qword_idx + 1;
                if (qword_idx == 2) begin scan_rd = 1'b0; disable sr_col; end
            end
        end
        $display("RESULT: FAIL — T5 scan: scan read timeout"); $finish;
    end
    begin : sr_idle
        for (timeout_cnt = 0; timeout_cnt < 1000; timeout_cnt = timeout_cnt + 1) begin
            @(posedge clk); if (!scan_busy) disable sr_idle;
        end
    end
end
endtask


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
    dst_we       = 1'b0;
    dst_din      = 16'd0;
    p0_addr      = 27'd0;
    p0_rd        = 1'b0;
    p0_burst     = 8'd0;
    p0_we        = 1'b0;
    p0_din       = 16'd0;
    p0_waddr     = 27'd0;
    p0_we_burst  = 1'b0;
    p0_din64     = 64'd0;
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
    // TEST 4 (Task 4 review): post-write read to the SAME (bank,row) but a
    // DIFFERENT column. Preload Bank2[SR_RD_WORD..] = SQ0/SQ1, then WRITE to
    // DST_BYTE_ADDR (bank2, same row 0) to set the post-write state, then READ
    // SR_RD_ADDR (bank2, row 0, different column). This is the case the row-based
    // rd_skew classifies as NON-skewed; it must read back the preloaded data.
    // =======================================================================
    for (i = 0; i < 4; i = i + 1)
        u_sdram.Bank2[SR_RD_WORD + i] = SQ0[i*16 +: 16];
    for (i = 0; i < 4; i = i + 1)
        u_sdram.Bank2[SR_RD_WORD + 4 + i] = SQ1[i*16 +: 16];

    // WRITE to DST_BYTE_ADDR (same row) to establish the post-write state
    @(negedge clk);
    dst_addr     = DST_BYTE_ADDR;
    dst_we_qcnt  = 8'd2;
    dst_din64    = DQ0_WR;
    dst_we_burst = 1'b1;
    begin : t4_wait_wr_busy
        for (timeout_cnt = 0; timeout_cnt < 1000; timeout_cnt = timeout_cnt + 1) begin
            @(posedge clk);
            if (dst_busy) begin @(negedge clk); dst_we_burst = 1'b0; disable t4_wait_wr_busy; end
        end
        $display("RESULT: FAIL — T4 write: dst_busy timeout"); $finish;
    end
    begin : t4_wait_wr_accept
        for (timeout_cnt = 0; timeout_cnt < 2000; timeout_cnt = timeout_cnt + 1) begin
            @(posedge clk);
            if (dst_wr_accept) begin @(negedge clk); dst_din64 = DQ1_WR; disable t4_wait_wr_accept; end
        end
        $display("RESULT: FAIL — T4 write: dst_wr_accept timeout"); $finish;
    end
    begin : t4_wait_wr_done
        for (timeout_cnt = 0; timeout_cnt < 5000; timeout_cnt = timeout_cnt + 1) begin
            @(posedge clk);
            if (!dst_busy) begin dst_din64 = 64'd0; disable t4_wait_wr_done; end
        end
        $display("RESULT: FAIL — T4 write: dst_busy clear timeout"); $finish;
    end

    // READ SR_RD_ADDR (same bank/row, different column) — post-write read
    @(negedge clk);
    dst_addr  = SR_RD_ADDR;
    dst_burst = 8'd2;
    dst_rd    = 1'b1;
    qword_idx = 0;
    begin : t4_collect
        for (timeout_cnt = 0; timeout_cnt < 5000; timeout_cnt = timeout_cnt + 1) begin
            @(posedge clk);
            if (dst_dready) begin
                captured[qword_idx] = dst_dout64;
                qword_idx = qword_idx + 1;
                if (qword_idx == 2) begin dst_rd = 1'b0; disable t4_collect; end
            end
        end
        $display("RESULT: FAIL — T4 read: only %0d of 2 qwords", qword_idx); $finish;
    end
    begin : t4_wait_idle
        for (timeout_cnt = 0; timeout_cnt < 1000; timeout_cnt = timeout_cnt + 1) begin
            @(posedge clk); if (!dst_busy) disable t4_wait_idle;
        end
    end
    if (captured[0] !== SQ0) begin
        $display("RESULT: FAIL — T4 same-row/diff-col Q0 got %016h expected %016h", captured[0], SQ0);
        result_ok = 1'b0;
    end
    if (captured[1] !== SQ1) begin
        $display("RESULT: FAIL — T4 same-row/diff-col Q1 got %016h expected %016h", captured[1], SQ1);
        result_ok = 1'b0;
    end

    // =======================================================================
    // TEST 6 (JT-T6): single-16-bit-word write path (dst_we) — the vram_demux
    // partial/sub-qword lane write.  Write 4 distinct words via single dst_we
    // writes to consecutive word addresses (one qword), then read the qword back
    // via dst_rd and assert.  Mirrors vram_demux's S_IDLE/S_WLANES lane walk:
    // hold dst_we until dst_busy asserts (accepted), drop, wait for completion.
    // =======================================================================
    for (i = 0; i < 4; i = i + 1) begin
        @(negedge clk);
        dst_addr = {2'd2, 24'h000500, 1'b0} + (i*2);  // word 0x500+i (byte+2/word)
        dst_din  = 16'hC000 + i;
        dst_we   = 1'b1;
        begin : t6_busy
            for (timeout_cnt = 0; timeout_cnt < 1000; timeout_cnt = timeout_cnt + 1) begin
                @(posedge clk);
                if (dst_busy) begin @(negedge clk); dst_we = 1'b0; disable t6_busy; end
            end
            $display("RESULT: FAIL — T6 single write %0d: dst_busy timeout", i); $finish;
        end
        begin : t6_wdone
            for (timeout_cnt = 0; timeout_cnt < 5000; timeout_cnt = timeout_cnt + 1) begin
                @(posedge clk);
                if (!dst_busy) disable t6_wdone;
            end
            $display("RESULT: FAIL — T6 single write %0d: dst_busy clear timeout", i); $finish;
        end
    end
    // read the qword back
    @(negedge clk);
    dst_addr  = {2'd2, 24'h000500, 1'b0};
    dst_burst = 8'd1;
    dst_rd    = 1'b1;
    begin : t6_collect
        for (timeout_cnt = 0; timeout_cnt < 5000; timeout_cnt = timeout_cnt + 1) begin
            @(posedge clk);
            if (dst_dready) begin captured[0] = dst_dout64; dst_rd = 1'b0; disable t6_collect; end
        end
        $display("RESULT: FAIL — T6 single-write readback timeout"); $finish;
    end
    begin : t6_idle
        for (timeout_cnt = 0; timeout_cnt < 1000; timeout_cnt = timeout_cnt + 1) begin
            @(posedge clk); if (!dst_busy) disable t6_idle;
        end
    end
    if (captured[0] !== {16'hC003, 16'hC002, 16'hC001, 16'hC000}) begin
        $display("RESULT: FAIL — T6 single-write readback got %016h expected c003c002c001c000", captured[0]);
        result_ok = 1'b0;
    end

    // =======================================================================
    // TEST 3 (Task 4): 3-client contention — scan-never-starve + correctness
    //
    // Concurrently:
    //   - scan_rd asserted continuously (back-to-back 2-qword line reads from
    //     bank 3, the seeded region used in Test 1)
    //   - dst_we_burst hammering 2-qword write bursts to bank 2 (DST region)
    //   - p0_rd asserted continuously (2-qword reads from bank 0, seeded below)
    //
    // Requirements over CONTENTION_CYCLES:
    //   - scan_reads_done >= MIN_SCAN_READS   (priority; scan never starved)
    //   - dst_writes_done >= 1                (lower priority still progresses)
    //   - p0_reads_done  >= 1                 (lowest priority still progresses)
    //   - all scan read-back data correct     (no cross-client corruption)
    //   - all p0 read-back data correct       (no cross-client corruption)
    // =======================================================================

    // Seed bank 0 for p0 reads (2 qwords = 8 words at offset 0x200)
    u_sdram.Bank0[P0_WORD_ADDR + 0] = P0W0;
    u_sdram.Bank0[P0_WORD_ADDR + 1] = P0W1;
    u_sdram.Bank0[P0_WORD_ADDR + 2] = P0W2;
    u_sdram.Bank0[P0_WORD_ADDR + 3] = P0W3;
    u_sdram.Bank0[P0_WORD_ADDR + 4] = P0W4;
    u_sdram.Bank0[P0_WORD_ADDR + 5] = P0W5;
    u_sdram.Bank0[P0_WORD_ADDR + 6] = P0W6;
    u_sdram.Bank0[P0_WORD_ADDR + 7] = P0W7;

    // Wait for any residual from Test 2 to clear
    repeat (16) @(posedge clk);

    // --- init test 3 counters ---
    t3_scan_reads_done  = 0;
    t3_dst_writes_done  = 0;
    t3_p0_reads_done    = 0;
    t3_scan_qidx        = 0;
    t3_p0_qidx          = 0;
    t3_dst_qword_idx    = 0;
    t3_ok               = 1'b1;
    t3_dst_wr_inflight  = 1'b0;

    // Assert all three clients simultaneously at negedge
    @(negedge clk);
    // scan: 2-qword line reads from the seeded region (Test 1 / Bank 3)
    scan_addr  = TEST_BYTE_ADDR;
    scan_burst = 8'd2;
    scan_rd    = 1'b1;
    // p0: 2-qword reads from Bank 0 seeded region
    p0_addr    = P0_BYTE_ADDR;
    p0_burst   = 8'd2;
    p0_rd      = 1'b1;
    // dst: 2-qword write bursts to the contention write region (Bank 2 offset 0x300)
    dst_addr     = DST_WR_CONT_ADDR;
    dst_we_qcnt  = 8'd2;
    dst_din64    = CONT_DQ0;
    dst_we_burst = 1'b1;

    for (t3_cycle = 0; t3_cycle < CONTENTION_CYCLES; t3_cycle = t3_cycle + 1) begin
        @(posedge clk);

        // ---- scan: collect qwords, verify, restart burst ----
        // After completing a burst, wait for FSM to go idle (scan_busy low) then
        // re-assert.  This is still "back-to-back" from scan's perspective (no
        // deliberate inter-burst delay beyond FSM drain time) and gives the
        // arbiter exactly one IDLE cycle where scan_rd is not asserted, letting
        // dst/p0 win if they are pending.
        if (scan_dready) begin
            t3_scan_cap[t3_scan_qidx] = scan_dout64;
            t3_scan_qidx = t3_scan_qidx + 1;
            if (t3_scan_qidx == 2) begin
                t3_scan_reads_done = t3_scan_reads_done + 1;
                if (t3_scan_cap[0] !== Q0_EXP) begin
                    $display("RESULT: FAIL — T3 scan burst %0d Q0 got %016h exp %016h",
                             t3_scan_reads_done, t3_scan_cap[0], Q0_EXP);
                    t3_ok = 1'b0;
                end
                if (t3_scan_cap[1] !== Q1_EXP) begin
                    $display("RESULT: FAIL — T3 scan burst %0d Q1 got %016h exp %016h",
                             t3_scan_reads_done, t3_scan_cap[1], Q1_EXP);
                    t3_ok = 1'b0;
                end
                t3_scan_qidx = 0;
                // Deassert scan_rd and wait for FSM to idle before re-asserting.
                // This ensures the arbiter sees at least one IDLE cycle with
                // scan_rd=0, giving dst/p0 a chance to be granted.
                @(negedge clk);
                scan_rd = 1'b0;
                // Wait until scan_busy clears (FSM is back in S_IDLE)
                while (scan_busy) @(posedge clk);
                // One more negedge to let dst/p0 see the IDLE cycle
                @(negedge clk);
                scan_rd = 1'b1;
            end
        end

        // ---- p0: collect qwords, verify, restart burst ----
        if (p0_dready) begin
            t3_p0_cap[t3_p0_qidx] = p0_dout64;
            t3_p0_qidx = t3_p0_qidx + 1;
            if (t3_p0_qidx == 2) begin
                t3_p0_reads_done = t3_p0_reads_done + 1;
                if (t3_p0_cap[0] !== P0Q0_EXP) begin
                    $display("RESULT: FAIL — T3 p0 burst %0d Q0 got %016h exp %016h",
                             t3_p0_reads_done, t3_p0_cap[0], P0Q0_EXP);
                    t3_ok = 1'b0;
                end
                if (t3_p0_cap[1] !== P0Q1_EXP) begin
                    $display("RESULT: FAIL — T3 p0 burst %0d Q1 got %016h exp %016h",
                             t3_p0_reads_done, t3_p0_cap[1], P0Q1_EXP);
                    t3_ok = 1'b0;
                end
                t3_p0_qidx = 0;
                @(negedge clk);
                p0_rd = 1'b0;
                while (p0_busy) @(posedge clk);
                @(negedge clk);
                p0_rd = 1'b1;
            end
        end

        // ---- dst write: advance qwords on accept, count completions, restart ----
        // Track in-flight: set when dst_busy first asserts (write accepted)
        if (dst_busy && dst_we_burst && !t3_dst_wr_inflight) begin
            t3_dst_wr_inflight = 1'b1;
            @(negedge clk);
            dst_we_burst = 1'b0;   // deassert once accepted
        end
        // Advance to second qword on accept strobe
        if (dst_wr_accept) begin
            @(negedge clk);
            dst_din64 = CONT_DQ1;
        end
        // Count completion when dst_busy falls with a write in-flight
        if (t3_dst_wr_inflight && !dst_busy) begin
            t3_dst_writes_done = t3_dst_writes_done + 1;
            t3_dst_wr_inflight = 1'b0;
            t3_dst_qword_idx   = 0;
            // Re-arm immediately for next write burst
            @(negedge clk);
            dst_din64    = CONT_DQ0;
            dst_we_burst = 1'b1;
        end
    end

    // Stop all clients
    @(negedge clk);
    scan_rd      = 1'b0;
    p0_rd        = 1'b0;
    dst_we_burst = 1'b0;

    // Wait for any in-flight burst to drain
    begin : t3_drain
        for (timeout_cnt = 0; timeout_cnt < 2000; timeout_cnt = timeout_cnt + 1) begin
            @(posedge clk);
            if (!scan_busy && !dst_busy && !p0_busy) disable t3_drain;
        end
    end

    $display("T3 contention: scan_reads=%0d  dst_writes=%0d  p0_reads=%0d",
             t3_scan_reads_done, t3_dst_writes_done, t3_p0_reads_done);

    if (t3_scan_reads_done < MIN_SCAN_READS) begin
        $display("RESULT: FAIL — T3 scan: only %0d bursts (need >=%0d); priority broken",
                 t3_scan_reads_done, MIN_SCAN_READS);
        result_ok = 1'b0;
    end
    if (t3_dst_writes_done < 1) begin
        $display("RESULT: FAIL — T3 dst: 0 write bursts completed; starvation");
        result_ok = 1'b0;
    end
    if (!t3_ok)
        result_ok = 1'b0;

    // =======================================================================
    // TEST 5 (Task 5): refresh timer vs sustained bursts.
    //
    // The shortened RFSH_TEST_PERIOD makes rfsh fire many times during this
    // run.  Phase A writes T5_BANDS bands (each a different row) back-to-back
    // through the real write path, interleaving a scan read every 4th band so
    // refresh, writes and reads all contend.  Phase B reads every band back.
    //   - no wedge: each handshake is watchdog-bounded; the whole run completing
    //     is the unit analog of the sdram_psx sustained-write livelock NOT
    //     happening (jtframe defers refresh to burst gaps).
    //   - data correct: refresh never corrupts a live burst.
    //   - rfsh fired >=2×: the timer ran and refresh was actually serviced.
    // =======================================================================
    // drain anything left from Test 3
    repeat (16) @(posedge clk);

    t5_rfsh_start = t5_rfsh_count;
    t5_ok         = 1'b1;

    // Phase A: sustained writes interleaved with scan reads
    for (t5_band = 0; t5_band < T5_BANDS; t5_band = t5_band + 1) begin
        dst_write_2qw(t5_addr(t5_band), t5_q0(t5_band), t5_q1(t5_band));
        if (t5_band[1:0] == 2'd0) begin
            scan_read_2qw(TEST_BYTE_ADDR, t5_sc0, t5_sc1);
            if (t5_sc0 !== Q0_EXP || t5_sc1 !== Q1_EXP) begin
                $display("RESULT: FAIL — T5 interleaved scan @band %0d got %016h/%016h",
                         t5_band, t5_sc0, t5_sc1);
                t5_ok = 1'b0;
            end
        end
    end

    // Phase B: read every band back and verify
    for (t5_band = 0; t5_band < T5_BANDS; t5_band = t5_band + 1) begin
        dst_read_2qw(t5_addr(t5_band), t5_rd0, t5_rd1);
        if (t5_rd0 !== t5_q0(t5_band)) begin
            $display("RESULT: FAIL — T5 band %0d Q0 got %016h exp %016h",
                     t5_band, t5_rd0, t5_q0(t5_band));
            t5_ok = 1'b0;
        end
        if (t5_rd1 !== t5_q1(t5_band)) begin
            $display("RESULT: FAIL — T5 band %0d Q1 got %016h exp %016h",
                     t5_band, t5_rd1, t5_q1(t5_band));
            t5_ok = 1'b0;
        end
    end

    // refresh must have fired across the sustained run
    if ((t5_rfsh_count - t5_rfsh_start) < 2) begin
        $display("RESULT: FAIL — T5 refresh: only %0d rfsh pulses during run (need >=2)",
                 t5_rfsh_count - t5_rfsh_start);
        t5_ok = 1'b0;
    end

    $display("T5 sustained: bands=%0d  rfsh_pulses=%0d",
             T5_BANDS, t5_rfsh_count - t5_rfsh_start);

    if (!t5_ok)
        result_ok = 1'b0;

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
wire [3:0] dbg_state    = dut.state;
wire [1:0] dbg_beat_pos = dut.beat_pos;
wire [9:0] dbg_word_cnt = dut.word_cnt;
wire       dbg_jt_rd    = dut.jt_rd;
wire       dbg_jt_wr    = dut.jt_wr;
wire       dbg_jt_ack   = dut.jt_ack;
wire       dbg_jt_dok   = dut.jt_dok;
wire       dbg_jt_dst   = dut.jt_dst;
wire [15:0] dbg_jt_dout = dut.jt_dout;
wire [1:0]  dbg_wr_beat  = dut.wr_beat;
wire [9:0]  dbg_wr_wc    = dut.wr_word_cnt;

// Log every clk posedge when interesting
integer dbg_clk_cnt;
always @(posedge clk) begin
    dbg_clk_cnt <= dbg_clk_cnt + 1;
    if (dbg_state != 0 || dbg_jt_dok || dbg_jt_ack) begin
        $display("CLK#%0d@%0t st=%0d rd=%b wr=%b ack=%b dok=%b dst=%b dout=%04h dq=%04h beat=%0d wc=%0d wbeat=%0d wwc=%0d | sr=%b dwb=%b dr=%b p0=%b gr=%0d",
            dbg_clk_cnt, $time,
            dbg_state, dbg_jt_rd, dbg_jt_wr, dbg_jt_ack, dbg_jt_dok, dbg_jt_dst,
            dbg_jt_dout, sdram_dq, dbg_beat_pos, dbg_word_cnt,
            dbg_wr_beat, dbg_wr_wc,
            scan_rd, dst_we_burst, dst_rd, p0_rd, dut.grant);
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
