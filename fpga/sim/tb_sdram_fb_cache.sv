// tb_sdram_fb_cache.sv — unit test for the sdram_fb_cache wrapper
// (jtframe_cache_mux 3-channel + jtframe_burst_sdram + coherency sequencer).
//
// Clock convention (verbatim from Task 1's tb_jtframe_cache_smoke):
//   clk_sdram leads clk by 5 ns; mt48lc16m16a2 is clocked off clk_sdram.
//
// wdsn polarity (ACTIVE-LOW, verified Task 1): wdsn[i]=0 ENABLES byte lane i,
//   wdsn[i]=1 MASKS it. Full-qword write = 8'h00.
//
// Address model — how a client byte address maps to an SDRAM 16-bit word:
//   The cache channel addr port is [AW-1:3] (DW=64 -> AW0=3), i.e. a qword index.
//   jtframe_cache turns qword index Q into ext word-address Q*4; cache_mux then
//   adds the channel OFFSET (in 16-bit words) before indexing SDRAM.  So a client
//   byte address A (qword-aligned, A[2:0]==0) lands at SDRAM words
//     base = (A>>3)*4 + OFFSET  ..  base+3 (little-endian: low word = din[15:0]).
//   This tb pre-loads / reads SDRAM via u_sdram.Bank0[word] exactly that way.
//
// Channels (must match sdram_fb_cache's cache_mux config):
//   ch0 = P_DST  (R/W), OFFSET = DST_OFFSET_W
//   ch4 = P_SCAN (RO),  OFFSET = SCAN_OFFSET_W
//   ch5 = P_SRC  (RO),  OFFSET = SRC_OFFSET_W

`timescale 1ns/1ps

module tb_sdram_fb_cache;

localparam integer PERIOD = 10;   // 100 MHz system clock

// OFFSETs (16-bit words) — MUST match sdram_fb_cache params (all 0 after the #2
// shared-FB fix: ch0/ch4 share the framebuffer region; ch5 uses real byte addrs).
localparam integer DST_OFFSET_W  = 0;
localparam integer SCAN_OFFSET_W = 0;
localparam integer SRC_OFFSET_W  = 0;
// T6: warm-hit vs cold-miss latency guard (cycles after p0_rd deassert until p0_ok).
// A warm cache hit returns in 0 cycles; a cold block-fill takes 30+ cycles. 20 gives
// clear separation so a warm post-vs read passes and a cold refill fails.
localparam integer MISS_SLACK    = 20;

// ---------------------------------------------------------------------------
// Clocks & reset
// ---------------------------------------------------------------------------
reg clk, clk_sdram, rst;
initial begin
    clk = 0; clk_sdram = 0;
    forever begin
        #(PERIOD/2) clk_sdram = ~clk_sdram;
        #5          clk       =  clk_sdram;
    end
end

// ---------------------------------------------------------------------------
// DUT client ports
// ---------------------------------------------------------------------------
reg  [26:0] dst_addr;
reg         dst_rd, dst_wr;
reg  [63:0] dst_din;
reg  [ 7:0] dst_wdsn;
wire [63:0] dst_dout;
wire        dst_ok;

reg  [26:0] scan_addr;
reg         scan_rd;
wire [63:0] scan_dout;
wire        scan_ok;

reg  [26:0] p0_addr;
reg         p0_rd;
wire [63:0] p0_dout;
wire        p0_ok;

reg         vs;
wire        coh_busy;

// SDRAM pins
wire [15:0] sdram_dq;
wire [12:0] sdram_a;
wire        sdram_dqml, sdram_dqmh;
wire [ 1:0] sdram_ba;
wire        sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke, sdram_clk;

// ---------------------------------------------------------------------------
// DUT
// ---------------------------------------------------------------------------
sdram_fb_cache u_dut (
    .clk       ( clk       ),
    .clk_sdram ( clk       ),
    .rst       ( rst       ),
    .dst_addr  ( dst_addr  ),
    .dst_rd    ( dst_rd    ),
    .dst_wr    ( dst_wr    ),
    .dst_din   ( dst_din   ),
    .dst_wdsn  ( dst_wdsn  ),
    .dst_dout  ( dst_dout  ),
    .dst_ok    ( dst_ok    ),
    .scan_addr ( scan_addr ),
    .scan_rd   ( scan_rd   ),
    .scan_dout ( scan_dout ),
    .scan_ok   ( scan_ok   ),
    .p0_addr   ( p0_addr   ),
    .p0_rd     ( p0_rd     ),
    .p0_dout   ( p0_dout   ),
    .p0_ok     ( p0_ok     ),
    .stage_addr(27'd0), .stage_wr(1'b0), .stage_din(64'd0), .stage_wdsn(8'hff), .stage_ok(),
    .stage_barrier(1'b0), .stage_busy(),   // STAGE-barrier unit-tested elsewhere
    .dst_barrier(1'b0), .dst_busy(),       // no carry-forward in this bench
    .vs        ( vs        ),
    .coh_busy  ( coh_busy  ),
    .sdram_dq  ( sdram_dq  ),
    .sdram_a   ( sdram_a   ),
    .sdram_dqml( sdram_dqml),
    .sdram_dqmh( sdram_dqmh),
    .sdram_ba  ( sdram_ba  ),
    .sdram_nwe ( sdram_nwe ),
    .sdram_ncas( sdram_ncas),
    .sdram_nras( sdram_nras),
    .sdram_ncs ( sdram_ncs ),
    .sdram_cke ( sdram_cke ),
    .sdram_clk ( sdram_clk )
);

// ---------------------------------------------------------------------------
// SDRAM chip model (clocked on clk_sdram — leads clk by 5 ns)
// ---------------------------------------------------------------------------
mt48lc16m16a2 #(.addr_bits(13), .col_bits(10)) u_sdram (
    .Clk        ( clk_sdram               ),
    .Cke        ( sdram_cke               ),
    .Dq         ( sdram_dq                ),
    .Addr       ( sdram_a                 ),
    .Ba         ( sdram_ba                ),
    .Cs_n       ( sdram_ncs               ),
    .Ras_n      ( sdram_nras              ),
    .Cas_n      ( sdram_ncas              ),
    .We_n       ( sdram_nwe               ),
    .Dqm        ( {sdram_dqmh,sdram_dqml} ),
    .downloading( 1'b0                    ),
    .VS         ( 1'b0                    ),
    .frame_cnt  ( 0                       )
);

// ---------------------------------------------------------------------------
// Address helper: client byte addr (qword-aligned) -> SDRAM word base
// ---------------------------------------------------------------------------
function automatic integer word_base(input integer byte_addr, input integer offset_w);
    begin
        word_base = ((byte_addr >> 3) * 4) + offset_w;
    end
endfunction

// Preload one qword into SDRAM at the given client byte addr + channel offset.
task preload_qword(input integer byte_addr, input integer offset_w, input [63:0] data);
    integer wb;
    begin
        wb = word_base(byte_addr, offset_w);
        u_sdram.Bank0[wb+0] = data[15: 0];
        u_sdram.Bank0[wb+1] = data[31:16];
        u_sdram.Bank0[wb+2] = data[47:32];
        u_sdram.Bank0[wb+3] = data[63:48];
    end
endtask

// ---------------------------------------------------------------------------
// Client request helpers (pulse rd/wr one cycle, wait ok). Hold off while
// coh_busy is high (models the client coherency gate).
// ---------------------------------------------------------------------------
task dst_write(input [26:0] a, input [63:0] d, input [7:0] dsn);
    integer cyc;
    begin
        while (coh_busy) @(posedge clk);
        @(posedge clk); #1;
        dst_addr = a; dst_din = d; dst_wdsn = dsn; dst_wr = 1'b1; dst_rd = 1'b0;
        @(posedge clk); #1; dst_wr = 1'b0;
        cyc = 0;
        while (!dst_ok) begin @(posedge clk); #1; cyc=cyc+1;
            if (cyc>4000) begin $display("RESULT: FAIL - dst_write timeout @%h", a); $finish; end end
    end
endtask

task dst_read(input [26:0] a, output [63:0] q);
    integer cyc;
    begin
        while (coh_busy) @(posedge clk);
        @(posedge clk); #1;
        dst_addr = a; dst_rd = 1'b1; dst_wr = 1'b0;
        @(posedge clk); #1; dst_rd = 1'b0;
        cyc = 0;
        while (!dst_ok) begin @(posedge clk); #1; cyc=cyc+1;
            if (cyc>4000) begin $display("RESULT: FAIL - dst_read timeout @%h", a); $finish; end end
        q = dst_dout;
    end
endtask

task scan_read(input [26:0] a, output [63:0] q);
    integer cyc;
    begin
        while (coh_busy) @(posedge clk);
        @(posedge clk); #1;
        scan_addr = a; scan_rd = 1'b1;
        @(posedge clk); #1; scan_rd = 1'b0;
        cyc = 0;
        while (!scan_ok) begin @(posedge clk); #1; cyc=cyc+1;
            if (cyc>4000) begin $display("RESULT: FAIL - scan_read timeout @%h", a); $finish; end end
        q = scan_dout;
    end
endtask

task p0_read(input [26:0] a, output [63:0] q);
    integer cyc;
    begin
        while (coh_busy) @(posedge clk);
        @(posedge clk); #1;
        p0_addr = a; p0_rd = 1'b1;
        @(posedge clk); #1; p0_rd = 1'b0;
        cyc = 0;
        while (!p0_ok) begin @(posedge clk); #1; cyc=cyc+1;
            if (cyc>4000) begin $display("RESULT: FAIL - p0_read timeout @%h", a); $finish; end end
        q = p0_dout;
    end
endtask

// time_p0_read: like p0_read but returns the number of cycles from p0_rd
// deassert until p0_ok (0 = ok asserted on the same posedge as deassert).
// A warm cache hit returns 0; a cold block-fill takes tens of cycles.
task time_p0_read(input [26:0] a, output integer lat);
    integer cyc;
    begin
        while (coh_busy) @(posedge clk);
        @(posedge clk); #1;
        p0_addr = a; p0_rd = 1'b1;
        @(posedge clk); #1; p0_rd = 1'b0;
        cyc = 0;
        while (!p0_ok) begin @(posedge clk); #1; cyc = cyc + 1;
            if (cyc > 4000) begin $display("RESULT: FAIL - time_p0_read timeout @%h", a); $finish; end
        end
        lat = cyc;
    end
endtask

// pulse_vs_and_wait_coh: assert vs for one cycle (triggers the vsync coherency
// FSM), then wait until coh_busy falls (flush+invalidate complete).
task pulse_vs_and_wait_coh;
    integer coh_wait;
    begin
        @(posedge clk); #1; vs = 1'b1;
        @(posedge clk); #1; vs = 1'b0;
        coh_wait = 0;
        // Allow a few cycles for coh_busy to assert, then wait for it to fall.
        while (coh_wait < 4 || coh_busy) begin
            @(posedge clk); #1;
            coh_wait = coh_wait + 1;
            if (coh_wait > 30000) begin
                $display("RESULT: FAIL - T6 coh_busy never cleared");
                $finish;
            end
        end
    end
endtask

// ---------------------------------------------------------------------------
// Test sequence
// ---------------------------------------------------------------------------
integer i;
integer warm_lat, post_vs_lat;   // T6: latency counters for warm-cache assertion
reg [63:0] got, exp;
reg        pass;
reg [26:0] a;

// T1 band data
reg [63:0] band [0:7];

initial begin
    rst      = 1'b1;
    dst_addr = 27'd0; dst_rd = 1'b0; dst_wr = 1'b0; dst_din = 64'd0; dst_wdsn = 8'h00;
    scan_addr= 27'd0; scan_rd= 1'b0;
    p0_addr  = 27'd0; p0_rd  = 1'b0;
    vs       = 1'b0;
    pass     = 1'b1;

    repeat (20) @(posedge clk);
    rst = 1'b0;

    // Wait for SDRAM init to complete (init deasserts inside the DUT).
    begin : wait_init
        for (i = 0; i < 30000; i = i + 1) begin
            @(posedge clk);
            if (!u_dut.init) disable wait_init;
        end
        $display("RESULT: FAIL - timeout waiting for SDRAM init");
        $finish;
    end
    repeat (4) @(posedge clk);

    // =======================================================================
    // T1: P_DST band RMW — write 8 distinct qwords, read them back.
    // =======================================================================
    for (i = 0; i < 8; i = i + 1)
        band[i] = (64'hA0000000_00000000 + (i*64'h0001_1111_2222_3333)) ^ {i[3:0],60'd0};
    for (i = 0; i < 8; i = i + 1)
        dst_write(27'h001000 + i*8, band[i], 8'h00);
    for (i = 0; i < 8; i = i + 1) begin
        dst_read(27'h001000 + i*8, got);
        if (got !== band[i]) begin
            $display("RESULT: FAIL - T1 dst band rd[%0d]: got %016h exp %016h", i, got, band[i]);
            pass = 1'b0;
        end
    end

    // =======================================================================
    // T2: P_DST partial write via wdsn (mask 2 lanes -> 4 bytes).
    //   Start from a known qword, write with wdsn=8'h30 (mask bytes 4,5 ->
    //   din[47:32]); all other bytes written. Verify masked bytes unchanged.
    // =======================================================================
    a = 27'h002000;
    dst_write(a, 64'h1111_2222_3333_4444, 8'h00);
    // wdsn[5:4]=1 masks bytes 4 and 5 -> din[47:32] held; rest written.
    dst_write(a, 64'hAAAA_BBBB_CCCC_DDDD, 8'h30);
    exp = 64'hAAAA_2222_CCCC_DDDD;   // bytes[47:32]=0x2222 preserved
    dst_read(a, got);
    if (got !== exp) begin
        $display("RESULT: FAIL - T2 partial: got %016h exp %016h", got, exp);
        pass = 1'b0;
    end

    // =======================================================================
    // T3: P_SCAN read — preload SDRAM directly, read via scan_*.
    // =======================================================================
    a = 27'h000080;
    exp = 64'hCAFEBABE_0BADF00D;
    preload_qword(a, SCAN_OFFSET_W, exp);
    scan_read(a, got);
    if (got !== exp) begin
        $display("RESULT: FAIL - T3 scan rd: got %016h exp %016h", got, exp);
        pass = 1'b0;
    end

    // =======================================================================
    // T4: P_SRC read — preload SDRAM directly, read via p0_*.
    // =======================================================================
    a = 27'h0000C0;
    exp = 64'h0123456789ABCDEF;
    preload_qword(a, SRC_OFFSET_W, exp);
    p0_read(a, got);
    if (got !== exp) begin
        $display("RESULT: FAIL - T4 p0 rd: got %016h exp %016h", got, exp);
        pass = 1'b0;
    end

    // =======================================================================
    // T5: coherency — write dirty qwords (cache-resident, not yet committed),
    //   pulse vs, wait !coh_busy. The sequencer flushes ch0 (commit to SDRAM)
    //   THEN invalidates ch0/ch4/ch5 (force cold). Read the same addresses
    //   back: a cold cache must miss and refill from SDRAM, returning the
    //   just-written values -> proves flush-happened-before-invalidate.
    // =======================================================================
    for (i = 0; i < 4; i = i + 1)
        band[i] = 64'hDEAD0000_00000000 + (i*64'h0000_1234_5678_9ABC) + i;
    for (i = 0; i < 4; i = i + 1)
        dst_write(27'h003000 + i*8, band[i], 8'h00);

    // Pulse vs (rising edge triggers the coherency FSM).
    @(posedge clk); #1; vs = 1'b1;
    @(posedge clk); #1; vs = 1'b0;
    // coh_busy must rise; wait for it to fall.
    begin : wait_coh
        for (i = 0; i < 30000; i = i + 1) begin
            @(posedge clk);
            if (!coh_busy && i > 2) disable wait_coh;  // allow a couple cycles to assert
        end
        $display("RESULT: FAIL - T5 coh_busy never cleared");
        $finish;
    end

    // Read back through the now-cold ch0. A miss must refill committed data.
    for (i = 0; i < 4; i = i + 1) begin
        dst_read(27'h003000 + i*8, got);
        if (got !== band[i]) begin
            $display("RESULT: FAIL - T5 coherency rd[%0d]: got %016h exp %016h", i, got, band[i]);
            pass = 1'b0;
        end
    end
    // Also confirm the data is physically in SDRAM (the flush committed it).
    for (i = 0; i < 4; i = i + 1) begin
        got = { u_sdram.Bank0[word_base(27'h003000 + i*8, DST_OFFSET_W)+3],
                u_sdram.Bank0[word_base(27'h003000 + i*8, DST_OFFSET_W)+2],
                u_sdram.Bank0[word_base(27'h003000 + i*8, DST_OFFSET_W)+1],
                u_sdram.Bank0[word_base(27'h003000 + i*8, DST_OFFSET_W)+0] };
        if (got !== band[i]) begin
            $display("RESULT: FAIL - T5 SDRAM commit[%0d]: got %016h exp %016h", i, got, band[i]);
            pass = 1'b0;
        end
    end

    // =======================================================================
    // T6: P_SRC warm-cache survives a vsync (Lever B: ch5 NOT in INVAL_MASK0).
    //   Preload a fresh atlas qword at address B (distinct from T3/T4 addrs).
    //   First p0_read warms the cache line (cold-miss, discard timing).
    //   Second call (time_p0_read) measures the warm-hit latency.
    //   Pulse vs and wait for !coh_busy.  Third call must have warm-hit latency
    //   (line retained by vsync flush), not a cold block-fill (line invalidated).
    //   RED  (INVAL_MASK0 = 8'b0010_0001): vsync invalidates ch5 -> cold refill
    //        -> post_vs_lat >> warm_lat + MISS_SLACK -> FAIL.
    //   GREEN (INVAL_MASK0 = 8'b0000_0001): ch5 NOT invalidated -> warm hit
    //        -> post_vs_lat <= warm_lat + MISS_SLACK -> PASS.
    // =======================================================================
    a = 27'h000800;
    preload_qword(a, SRC_OFFSET_W, 64'hFEEDC0DE_CAFEF00D);
    p0_read(a, got);                   // cold miss -> warm (discard)
    time_p0_read(a, warm_lat);         // warm hit — record latency
    pulse_vs_and_wait_coh();           // vsync flush; ch5 must NOT be in INVAL_MASK0
    time_p0_read(a, post_vs_lat);      // EXPECT: warm (line retained), not a refill
    if (post_vs_lat > warm_lat + MISS_SLACK) begin
        $display("RESULT: FAIL - T6: P_SRC invalidated by vsync (post_vs_lat=%0d warm_lat=%0d MISS_SLACK=%0d)",
                 post_vs_lat, warm_lat, MISS_SLACK);
        pass = 1'b0;
    end else begin
        $display("T6: P_SRC survives vsync OK (post_vs_lat=%0d warm_lat=%0d MISS_SLACK=%0d)",
                 post_vs_lat, warm_lat, MISS_SLACK);
    end

    if (pass) $display("RESULT: PASS");
    else      $display("RESULT: FAIL");
    $finish;
end

// Safety timeout
initial begin
    #40_000_000;
    $display("RESULT: FAIL - global simulation timeout");
    $finish;
end

endmodule
