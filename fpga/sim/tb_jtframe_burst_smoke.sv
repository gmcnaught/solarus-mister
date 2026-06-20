// Smoke testbench for jtframe_burst_sdram — write 4 words then read them back.
// Uses AW=23 (64 MB), MISTER=0 (sim DQM routing), HF=1.
// Passes when RESULT: PASS is printed; fails with RESULT: FAIL.
`timescale 1ns/1ps

module tb_jtframe_burst_smoke;

localparam integer PERIOD   = 10;   // 100 MHz system clock period (ns)
localparam integer AW       = 23;
localparam integer HF       = 1;

// ---------------------------------------------------------------------------
// Clocks and reset
// ---------------------------------------------------------------------------
reg clk;
reg clk_sdram;
reg rst;

// clk_sdram leads clk by 5 ns (same convention as upstream test.v)
initial begin
    clk       = 0;
    clk_sdram = 0;
    forever begin
        #(PERIOD/2) clk_sdram = ~clk_sdram;
        #5          clk       =  clk_sdram;  // clk trails by 5 ns inside a half-period
    end
end

// ---------------------------------------------------------------------------
// Refresh pulse — every ~6400 ns (once per "horizontal line" equiv.)
// ---------------------------------------------------------------------------
integer hcnt;
wire rfsh = (hcnt == 0);

always @(posedge clk or posedge rst) begin
    if (rst)
        hcnt <= 0;
    else
        hcnt <= (hcnt == 639) ? 0 : hcnt + 1;
end

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
wire             init;
reg  [AW-1:0]   addr;
reg  [ 1:0]      ba;
reg              rd;
reg              wr;
reg  [15:0]      din;
wire [15:0]      dout;
wire             ack;
wire             dst;
wire             dok;
wire             rdy;

wire [15:0]      sdram_dq;
wire [12:0]      sdram_a;
wire             sdram_dqml;
wire             sdram_dqmh;
wire [ 1:0]      sdram_ba;
wire             sdram_nwe;
wire             sdram_ncas;
wire             sdram_nras;
wire             sdram_ncs;
wire             sdram_cke;

// ---------------------------------------------------------------------------
// DUT
// ---------------------------------------------------------------------------
jtframe_burst_sdram #(
    .AW      ( AW ),
    .HF      ( HF ),
    .MISTER  ( 0  ),
    .PROG_LEN( 64 )
) uut (
    .rst        ( rst          ),
    .clk        ( clk          ),
    .init       ( init         ),
    .addr       ( addr         ),
    .ba         ( ba           ),
    .rd         ( rd           ),
    .wr         ( wr           ),
    .din        ( din          ),
    .dout       ( dout         ),
    .ack        ( ack          ),
    .dst        ( dst          ),
    .dok        ( dok          ),
    .rdy        ( rdy          ),
    .prog_en    ( 1'b0         ),
    .prog_addr  ( {AW{1'b0}}   ),
    .prog_rd    ( 1'b0         ),
    .prog_wr    ( 1'b0         ),
    .prog_din   ( 16'h0000     ),
    .prog_dsn   ( 2'b00        ),
    .prog_ba    ( 2'b00        ),
    .prog_dst   (              ),
    .prog_dok   (              ),
    .prog_rdy   (              ),
    .prog_ack   (              ),
    .rfsh       ( rfsh         ),
    .sdram_dq   ( sdram_dq     ),
    .sdram_a    ( sdram_a      ),
    .sdram_dqml ( sdram_dqml   ),
    .sdram_dqmh ( sdram_dqmh   ),
    .sdram_ba   ( sdram_ba     ),
    .sdram_nwe  ( sdram_nwe    ),
    .sdram_ncas ( sdram_ncas   ),
    .sdram_nras ( sdram_nras   ),
    .sdram_ncs  ( sdram_ncs    ),
    .sdram_cke  ( sdram_cke    )
);

// ---------------------------------------------------------------------------
// SDRAM chip model
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
// Test data
// ---------------------------------------------------------------------------
localparam [15:0] WORD0 = 16'h1111,
                  WORD1 = 16'h2222,
                  WORD2 = 16'h3333,
                  WORD3 = 16'h4444;

localparam [AW-1:0] TEST_ADDR = 23'h000100;   // row=0, col=0x100 (well within page)
localparam [ 1:0]   TEST_BA   = 2'd3;

// ---------------------------------------------------------------------------
// Test sequence
// ---------------------------------------------------------------------------
integer i;
integer timeout;
integer write_words;
integer read_words;
reg [15:0] captured [0:3];
reg result_ok;

initial begin
    // -----------------------------------------------------------------------
    // Initialise
    // -----------------------------------------------------------------------
    rst         = 1'b1;
    addr        = {AW{1'b0}};
    ba          = 2'd0;
    rd          = 1'b0;
    wr          = 1'b0;
    din         = 16'h0000;
    write_words = 0;
    read_words  = 0;
    result_ok   = 1'b1;

    repeat (20) @(posedge clk);
    rst = 1'b0;

    // -----------------------------------------------------------------------
    // Wait for SDRAM init to complete (init deasserts)
    // -----------------------------------------------------------------------
    begin : wait_init_done
        for (i = 0; i < 25_000; i = i + 1) begin
            @(posedge clk);
            if (!init) disable wait_init_done;
        end
        $display("RESULT: FAIL — timed out waiting for SDRAM init");
        $finish;
    end

    // Small gap after init
    repeat (8) @(posedge clk);

    // -----------------------------------------------------------------------
    // WRITE BURST: 4 words starting at TEST_ADDR / bank TEST_BA
    //
    // Protocol (from jtframe_burst_ctrl FSM):
    //   1. Assert wr + addr + ba + din[0] on a negedge (setup before posedge).
    //   2. Wait for ack.
    //   3. Update din each cycle while wr is high; drop wr after 4th word.
    //   4. Wait for rdy.
    // -----------------------------------------------------------------------
    @(negedge clk);
    addr = TEST_ADDR;
    ba   = TEST_BA;
    wr   = 1'b1;
    din  = WORD0;

    // Wait for ack
    begin : wait_wr_ack
        for (i = 0; i < 1000; i = i + 1) begin
            @(posedge clk);
            if (ack) disable wait_wr_ack;
        end
        $display("RESULT: FAIL — timed out waiting for write ack");
        $finish;
    end

    // ack fires at B_WACK (posedge).
    // FSM sequence after ack:
    //   +0 cycles (ack posedge): B_WACK  — din should be WORD0 (already set)
    //   +1 cycle:                B_WDATA — din=WORD0 (no cmd yet)
    //   +2 cycles:               B_WRITE_CMD — issues CMD_WRITE, captures din=WORD0
    //   +3 cycles:               B_WRITE    — captures din=WORD1
    //   +4 cycles:               B_WRITE    — captures din=WORD2
    //   +5 cycles:               B_WRITE    — captures din=WORD3; drop wr here
    //
    // Stage 1 + Stage 2 pipeline delays shift cmd and data together to the pad,
    // so relative alignment is maintained regardless of pipeline depth.
    //
    // Strategy: stay on WORD0 for 2 cycles after ack, then present WORD1/2/3
    // on successive negedges; drop wr on the negedge after WORD3.
    @(negedge clk);  // ack negedge: still din=WORD0
    @(negedge clk);  // +1 negedge: B_WRITE_CMD will fire on next posedge with din=WORD0
    din = WORD1;
    @(negedge clk);  // din=WORD1 for B_WRITE
    din = WORD2;
    @(negedge clk);  // din=WORD2 for B_WRITE
    din = WORD3;
    @(negedge clk);  // din=WORD3 for B_WRITE, then stop
    wr  = 1'b0;

    // Wait for rdy (write done / precharge complete)
    begin : wait_wr_rdy
        for (i = 0; i < 1000; i = i + 1) begin
            @(posedge clk);
            if (rdy) disable wait_wr_rdy;
        end
        $display("RESULT: FAIL — timed out waiting for write rdy");
        $finish;
    end

    // Gap between write and read
    repeat (8) @(posedge clk);

    // -----------------------------------------------------------------------
    // READ BURST: 4 words from same address
    //
    // Protocol:
    //   1. Assert rd + addr + ba on negedge.
    //   2. Wait for ack.
    //   3. Capture dout on each dok pulse; drop rd after 4th word.
    //   4. Wait for rdy.
    // -----------------------------------------------------------------------
    @(negedge clk);
    addr = TEST_ADDR;
    ba   = TEST_BA;
    rd   = 1'b1;

    // Wait for ack
    begin : wait_rd_ack
        for (i = 0; i < 1000; i = i + 1) begin
            @(posedge clk);
            if (ack) disable wait_rd_ack;
        end
        $display("RESULT: FAIL — timed out waiting for read ack");
        $finish;
    end

    // Capture data words on dok
    read_words = 0;
    begin : collect_words
        for (timeout = 0; timeout < 2000; timeout = timeout + 1) begin
            @(posedge clk);
            if (dok) begin
                captured[read_words] = dout;
                read_words = read_words + 1;
                if (read_words == 4) begin
                    @(negedge clk);
                    rd = 1'b0;
                    disable collect_words;
                end
            end
        end
        if (read_words < 4) begin
            $display("RESULT: FAIL — only %0d of 4 words received", read_words);
            $finish;
        end
    end

    // Wait for rdy
    begin : wait_rd_rdy
        for (i = 0; i < 1000; i = i + 1) begin
            @(posedge clk);
            if (rdy) disable wait_rd_rdy;
        end
        $display("RESULT: FAIL — timed out waiting for read rdy");
        $finish;
    end

    // -----------------------------------------------------------------------
    // Verify
    // -----------------------------------------------------------------------
    if (captured[0] !== WORD0) begin
        $display("RESULT: FAIL — word[0] got %04h expected %04h", captured[0], WORD0);
        result_ok = 1'b0;
    end
    if (captured[1] !== WORD1) begin
        $display("RESULT: FAIL — word[1] got %04h expected %04h", captured[1], WORD1);
        result_ok = 1'b0;
    end
    if (captured[2] !== WORD2) begin
        $display("RESULT: FAIL — word[2] got %04h expected %04h", captured[2], WORD2);
        result_ok = 1'b0;
    end
    if (captured[3] !== WORD3) begin
        $display("RESULT: FAIL — word[3] got %04h expected %04h", captured[3], WORD3);
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
    #10_000_000;
    $display("RESULT: FAIL — global simulation timeout");
    $finish;
end

endmodule
