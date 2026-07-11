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

// [XL 128MB 2-chip harness] Reproduces + verifies the jtframe XL dual-die addressing at
// SDRAM_AW=25. Two 64MB mt48 models split by the controller's sel_chip (MiSTer 128MB
// wiring: sdram_ncs = cmd_cs ^ sel_chip). Cross-boundary contamination test: a chip-1
// write must NOT clobber a chip-0 location (the "menu surface bleeds into overworld" bug).
module tb_sdram_fb_cache_xl;

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
sdram_fb_cache #(.SDRAM_AW(25)) u_dut (
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
// [XL 2-chip] MiSTer 128MB = 2 dies selected via sdram_ncs = cmd_cs ^ sel_chip
// (jtframe_burst_io:172). Tap the controller's registered sel_chip and reconstruct each
// die's command-CS: cmd_cs = sdram_ncs ^ sel_chip; die0 active iff sel_chip==0, die1 iff
// sel_chip==1. Both dies share Addr/Ba/DQ/command/Clk/Dqm; only Cs_n differs. Each stores
// the SAME within-die {bank,row,col}, so logical byte addr < 64MB -> die0, >= 64MB -> die1
// IFF the controller drives sel_chip + within-die addr correctly (that's what we test).
wire sc   = u_dut.u_sdram_ctrl.u_io.sel_chip_r;
wire ncs0 = sc ? 1'b1 : sdram_ncs;      // die0 sees the command only when sel_chip=0
wire ncs1 = sc ? ~sdram_ncs : 1'b1;     // die1 sees it only when sel_chip=1 (cmd_cs=~ncs)
mt48lc16m16a2 #(.addr_bits(13), .col_bits(10)) u_chip0 (
    .Clk(clk_sdram), .Cke(sdram_cke), .Dq(sdram_dq), .Addr(sdram_a), .Ba(sdram_ba),
    .Cs_n(ncs0), .Ras_n(sdram_nras), .Cas_n(sdram_ncas), .We_n(sdram_nwe),
    .Dqm({sdram_dqmh,sdram_dqml}), .downloading(1'b0), .VS(1'b0), .frame_cnt(0) );
mt48lc16m16a2 #(.addr_bits(13), .col_bits(10)) u_chip1 (
    .Clk(clk_sdram), .Cke(sdram_cke), .Dq(sdram_dq), .Addr(sdram_a), .Ba(sdram_ba),
    .Cs_n(ncs1), .Ras_n(sdram_nras), .Cas_n(sdram_ncas), .We_n(sdram_nwe),
    .Dqm({sdram_dqmh,sdram_dqml}), .downloading(1'b0), .VS(1'b0), .frame_cnt(0) );

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
        u_chip0.Bank0[wb+0] = data[15: 0];
        u_chip0.Bank0[wb+1] = data[31:16];
        u_chip0.Bank0[wb+2] = data[47:32];
        u_chip0.Bank0[wb+3] = data[63:48];
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
    // XL cross-boundary contamination test (the "menu bleeds into overworld" bug).
    // Write distinct data to a CHIP-0 addr and a CHIP-1 addr THROUGH the DUT (exercising
    // cache->burst->sel_chip address computation), flush each to real SDRAM (vsync flush
    // invalidates ch0 so reads are COLD from SDRAM), then read back and assert no cross-
    // contamination. 32MB(chip0) and 96MB(chip1) share the same within-die {bank,row,col},
    // so if the chip bit is wrong the 96MB write clobbers the 32MB die-0 location -> the
    // 32MB read returns the chip-1 marker. A mismatch here reproduces the HW garbage in sim.
    // =======================================================================
    begin : xl_boundary
        reg [63:0] A0, B1, C0b, D1b;
        reg [26:0] addr_lo, addr_hi, addr_lo2, addr_hi2;
        A0  = 64'hA0A0A0A0_0000A0A0;   // marker for 32 MiB  (chip 0)
        B1  = 64'hB1B1B1B1_0000B1B1;   // marker for 96 MiB  (chip 1)
        C0b = 64'hC0C0C0C0_1111C0C0;   // marker for 48 MiB  (chip 0)
        D1b = 64'hD1D1D1D1_2222D1D1;   // marker for 112 MiB (chip 1)
        addr_lo  = 27'h2000000;   // 32 MiB  -> chip 0
        addr_hi  = 27'h6000000;   // 96 MiB  -> chip 1  (96-64 = 32 MiB within die = same as 32MB)
        addr_lo2 = 27'h3000000;   // 48 MiB  -> chip 0
        addr_hi2 = 27'h7000000;   // 112 MiB -> chip 1

        // Pair 1: write chip0 then chip1, flushing each to real SDRAM.
        dst_write(addr_lo, A0, 8'h00); pulse_vs_and_wait_coh();
        dst_write(addr_hi, B1, 8'h00); pulse_vs_and_wait_coh();
        dst_read(addr_lo, got);
        if (got !== A0) begin pass=1'b0;
            $display("RESULT: FAIL - XL chip0 32MB: got %016h exp %016h (chip1 write aliased onto chip0?)", got, A0); end
        dst_read(addr_hi, got);
        if (got !== B1) begin pass=1'b0;
            $display("RESULT: FAIL - XL chip1 96MB: got %016h exp %016h (read wrong die?)", got, B1); end

        // Pair 2 (48/112 MiB share a within-die location too).
        dst_write(addr_lo2, C0b, 8'h00); pulse_vs_and_wait_coh();
        dst_write(addr_hi2, D1b, 8'h00); pulse_vs_and_wait_coh();
        dst_read(addr_lo2, got);
        if (got !== C0b) begin pass=1'b0;
            $display("RESULT: FAIL - XL chip0 48MB: got %016h exp %016h", got, C0b); end
        dst_read(addr_hi2, got);
        if (got !== D1b) begin pass=1'b0;
            $display("RESULT: FAIL - XL chip1 112MB: got %016h exp %016h", got, D1b); end

        // Re-read pair 1 to confirm pair-2 writes did not corrupt them (cross-alias).
        dst_read(addr_lo, got);
        if (got !== A0) begin pass=1'b0;
            $display("RESULT: FAIL - XL chip0 32MB (after pair2): got %016h exp %016h", got, A0); end
        dst_read(addr_hi, got);
        if (got !== B1) begin pass=1'b0;
            $display("RESULT: FAIL - XL chip1 96MB (after pair2): got %016h exp %016h", got, B1); end

        if (pass) $display("XL boundary: 32/96/48/112 MiB round-trip CLEAN across the chip boundary (no cross-die alias)");
    end

    // =======================================================================
    // [#24 arena] Address-uniqueness sweep across the chip(bit26) + bank(bit25,
    // bit24) bits, read back through EVERY consumer channel (ch0 P_DST, ch5
    // P_SRC, ch4 P_SCAN). The xl_boundary block above only exercises chip1
    // banks 2/3 (96/112 MiB) and reads back solely via ch0; it never touches
    // chip1 bank1 (80-96 MiB -- where the 84 MiB per-layer bgplane arena BEGINS)
    // nor verifies that a plane WRITTEN via ch0 (the exact port the
    // OP_BGPLANE_WRITE bake drives through bgw_ch0_mux) reads back identically
    // through ch5 (the port the compositor actually reads a baked plane through).
    // This sweep writes a unique, address-derived marker to all 8 {chip,bank}
    // combinations of a within-die location, flushes to real SDRAM, and asserts
    // every combo reads back bit-exact on all three channels. If ANY of bits
    // 24/25/26 is dropped or mis-routed for high addresses, two combos collide
    // in one physical cell and the readback mismatches. Run at two within-die
    // locations (row/col = 0 and nonzero) so a bank bit cannot masquerade as a
    // row/col bit. This is the coverage whose absence let the arena regression
    // pass CI: the pre-existing benches only address the low 0-64 MiB span plus
    // the two chip1 banks that happen NOT to be the arena base.
    // =======================================================================
    begin : arena_uniqueness
        reg [26:0] base_l [0:1];
        reg [26:0] aw;
        integer li, ci;
        reg [63:0] m, q;
        base_l[0] = 27'h0000000;   // within-die {row,col} = 0
        base_l[1] = 27'h0A00000;   // 10 MiB into a bank (nonzero row/col), qword-aligned

        for (li = 0; li < 2; li = li + 1) begin
            // write all 8 chip/bank combos of this within-die location
            for (ci = 0; ci < 8; ci = ci + 1) begin
                aw = base_l[li] | (((ci & 4) != 0) ? 27'h4000000 : 27'd0)   // bit26 chip
                                | (((ci & 2) != 0) ? 27'h2000000 : 27'd0)   // bit25 bank hi
                                | (((ci & 1) != 0) ? 27'h1000000 : 27'd0);  // bit24 bank lo
                m  = {aw, aw, 10'h2C5};   // unique address-derived marker
                dst_write(aw, m, 8'h00);
            end
            pulse_vs_and_wait_coh();   // commit ch0 dirty lines to SDRAM, invalidate ch0+ch4

            // read every combo back on all three consumer channels
            for (ci = 0; ci < 8; ci = ci + 1) begin
                aw = base_l[li] | (((ci & 4) != 0) ? 27'h4000000 : 27'd0)
                                | (((ci & 2) != 0) ? 27'h2000000 : 27'd0)
                                | (((ci & 1) != 0) ? 27'h1000000 : 27'd0);
                m  = {aw, aw, 10'h2C5};
                dst_read (aw, q);
                if (q !== m) begin pass=1'b0;
                    $display("RESULT: FAIL - arena ch0 @%07h: got %016h exp %016h (chip/bank bit dropped?)", aw, q, m); end
                p0_read  (aw, q);
                if (q !== m) begin pass=1'b0;
                    $display("RESULT: FAIL - arena ch5/P_SRC @%07h: got %016h exp %016h (ch0-write/ch5-read addr divergence?)", aw, q, m); end
                scan_read(aw, q);
                if (q !== m) begin pass=1'b0;
                    $display("RESULT: FAIL - arena ch4/P_SCAN @%07h: got %016h exp %016h", aw, q, m); end
            end
        end
        if (pass) $display("arena sweep: all 8 chip/bank combos x2 within-die locations round-trip CLEAN on ch0+ch5+ch4 (incl chip1 bank1 @80MiB, the 84MiB arena base)");
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
