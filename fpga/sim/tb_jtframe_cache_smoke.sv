// Smoke testbench for jtframe_cache (DW=64) wired to jtframe_burst_sdram + mt48lc16m16a2.
// De-risk gate: confirms the jtframe cache stack simulates at DW=64 under iverilog.
//
// wdsn polarity (empirically confirmed by the partial-write assertion below):
//   wdsn is ACTIVE-LOW byte-select: wdsn[i]=0 ENABLES write of byte lane i;
//                                   wdsn[i]=1 MASKS   (inhibits) write of byte lane i.
//   req_write_mask in jtframe_cache_ctrl: req_we[MW-1:0] = ~wdsn
//   req_we[3:0]  → ram0 (din[31:0],  bytes 0-3)
//   req_we[7:4]  → ram1 (din[63:32], bytes 4-7)
//   wdsn=8'h00 → write all 8 bytes
//   wdsn=8'hFF → write no bytes (mask all)
//   wdsn=8'hF0 → write bytes 0-3  (din[31:0]);  mask bytes 4-7  (din[63:32])
//   wdsn=8'h0F → write bytes 4-7  (din[63:32]); mask bytes 0-3  (din[31:0])
// Task 3 note: client drivers should use wdsn=8'h00 for full-qword writes and
//   set the corresponding byte-lane bits to 1'b1 to mask individual bytes.
//
// Parameters match the intended compositor cache:
//   BLOCKS=2, BLKSIZE=64, AW=23, DW=64, EW=23
// For DW=64: AW0=3, MW=8, DEPTH=8 qwords/block, OFFW=3
// addr port = [AW-1:AW0] = [22:3] (20-bit qword address)
// Line 0 (A0): byte address 0x000000 → qword-addr 20'h00000 → cache line [2:0]=000
// Line 1 (A1): byte address 0x000040 → qword-addr 20'h00008 → next 64-byte line

`timescale 1ns/1ps

module tb_jtframe_cache_smoke;

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
localparam integer PERIOD   = 10;    // 100 MHz system clock (ns)
localparam integer AW       = 23;
localparam integer EW       = 23;
localparam integer DW       = 64;
localparam integer AW0      = 3;     // DW==64 → AW0=3
localparam integer MW       = 8;     // DW/8

// Cache line addresses (qword-aligned address, bits [22:3])
// A0 = byte 0x000000, A1 = byte 0x000040 (different 64-byte cache line)
localparam [AW-1:AW0] ADDR_A0 = 20'h00000;   // line 0, offset 0
localparam [AW-1:AW0] ADDR_A1 = 20'h00008;   // line 1, offset 0

// Test data
localparam [DW-1:0] DATA_A0    = 64'hCAFEBABE_0BADF00D;
localparam [DW-1:0] DATA_A1    = 64'h0123456789ABCDEF;
// Partial-write at A0: wdsn=8'hF0 masks bytes 4-7 (din[63:32]), writes bytes 0-3
localparam [MW-1:0] PARTIAL_DSN= 8'hF0;          // mask upper 4 bytes, write lower 4
localparam [DW-1:0] PARTIAL_DIN= 64'hAAAAAAAA_DEADBEEF;
// Expected: upper half unchanged (0xCAFEBABE), lower half overwritten (0xDEADBEEF)
localparam [DW-1:0] PARTIAL_EXP= 64'hCAFEBABE_DEADBEEF;

// ---------------------------------------------------------------------------
// Clocks & reset  (clk_sdram leads clk by 5 ns — same convention as upstream)
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
// Refresh pulse — every 256 clk cycles
// ---------------------------------------------------------------------------
integer hcnt;
wire rfsh = (hcnt == 0);

always @(posedge clk or posedge rst) begin
    if (rst)
        hcnt <= 0;
    else
        hcnt <= (hcnt == 255) ? 0 : hcnt + 1;
end

// ---------------------------------------------------------------------------
// Cache user-port signals
// ---------------------------------------------------------------------------
reg  [AW-1:AW0] addr;
reg  [DW-1:0]   din;
wire [DW-1:0]   dout;
reg              rd;
reg              wr;
reg  [MW-1:0]   wdsn;
wire             ok;

// ---------------------------------------------------------------------------
// Cache → burst_sdram ext_* signals
// ---------------------------------------------------------------------------
wire [EW-1:1]   ext_addr;
wire [15:0]     ext_din;
wire [15:0]     ext_dout;
wire             ext_rd;
wire             ext_wr;
wire             ext_ack;
wire             ext_dst;
wire             ext_dok;
wire             ext_rdy;
wire             init;

// ---------------------------------------------------------------------------
// SDRAM I/O
// ---------------------------------------------------------------------------
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
// DUT: jtframe_cache (DW=64)
// ---------------------------------------------------------------------------
jtframe_cache #(
    .BLOCKS  ( 2    ),
    .BLKSIZE ( 64   ),
    .AW      ( AW   ),
    .DW      ( DW   ),
    .EW      ( EW   )
) u_cache (
    .rst             ( rst       ),
    .clk             ( clk       ),
    .addr            ( addr      ),
    .dout            ( dout      ),
    .din             ( din       ),
    .rd              ( rd        ),
    .wr              ( wr        ),
    .wdsn            ( wdsn      ),
    .ok              ( ok        ),
    .flush           ( 1'b0      ),
    .flushing        (           ),
    .flush_done      (           ),
    .invalidate      ( 1'b0      ),
    .invalidating    (           ),
    .invalidate_done (           ),
    .ext_addr        ( ext_addr  ),
    .ext_din         ( ext_din   ),
    .ext_dout        ( ext_dout  ),
    .ext_rd          ( ext_rd    ),
    .ext_wr          ( ext_wr    ),
    .ext_ack         ( ext_ack   ),
    .ext_dst         ( ext_dst   ),
    .ext_dok         ( ext_dok   ),
    .ext_rdy         ( ext_rdy   )
);

// ---------------------------------------------------------------------------
// jtframe_burst_sdram (AW=22, HF=1, MISTER=0, PROG_LEN=64)
// ext_addr is [EW-1:1] = [22:1]; burst_sdram AW=22 takes [AW-1:0]=[21:0] = ext_addr[22:1]
// ---------------------------------------------------------------------------
jtframe_burst_sdram #(
    .AW      ( 22 ),
    .HF      ( 1  ),
    .MISTER  ( 0  ),
    .PROG_LEN( 64 )
) u_sdram_ctrl (
    .rst        ( rst              ),
    .clk        ( clk              ),
    .init       ( init             ),
    .addr       ( ext_addr[22:1]   ),
    .ba         ( 2'd0             ),
    .rd         ( ext_rd           ),
    .wr         ( ext_wr           ),
    .din        ( ext_dout         ),
    .dout       ( ext_din          ),
    .ack        ( ext_ack          ),
    .dst        ( ext_dst          ),
    .dok        ( ext_dok          ),
    .rdy        ( ext_rdy          ),
    .prog_en    ( 1'b0             ),
    .prog_addr  ( 22'd0            ),
    .prog_rd    ( 1'b0             ),
    .prog_wr    ( 1'b0             ),
    .prog_din   ( 16'h0000         ),
    .prog_dsn   ( 2'b11            ),
    .prog_ba    ( 2'b00            ),
    .prog_dst   (                  ),
    .prog_dok   (                  ),
    .prog_rdy   (                  ),
    .prog_ack   (                  ),
    .rfsh       ( rfsh             ),
    .sdram_dq   ( sdram_dq         ),
    .sdram_a    ( sdram_a          ),
    .sdram_dqml ( sdram_dqml       ),
    .sdram_dqmh ( sdram_dqmh       ),
    .sdram_ba   ( sdram_ba         ),
    .sdram_nwe  ( sdram_nwe        ),
    .sdram_ncas ( sdram_ncas       ),
    .sdram_nras ( sdram_nras       ),
    .sdram_ncs  ( sdram_ncs        ),
    .sdram_cke  ( sdram_cke        )
);

// ---------------------------------------------------------------------------
// SDRAM chip model (clocked on clk_sdram — leads clk by 5 ns)
// ---------------------------------------------------------------------------
mt48lc16m16a2 #(
    .addr_bits ( 13 ),
    .col_bits  ( 10 )
) u_sdram (
    .Clk        ( clk_sdram              ),
    .Cke        ( sdram_cke              ),
    .Dq         ( sdram_dq               ),
    .Addr       ( sdram_a                ),
    .Ba         ( sdram_ba               ),
    .Cs_n       ( sdram_ncs              ),
    .Ras_n      ( sdram_nras             ),
    .Cas_n      ( sdram_ncas             ),
    .We_n       ( sdram_nwe              ),
    .Dqm        ( {sdram_dqmh,sdram_dqml}),
    .downloading( 1'b0                   ),
    .VS         ( 1'b0                   ),
    .frame_cnt  ( 0                      )
);

// ---------------------------------------------------------------------------
// Helper task: do a single cache request (rd or wr) and wait for ok
//   pulse rd/wr high for ONE clock (edge-triggered detection in jtframe_cache_req)
//   then wait for ok to pulse.
// ---------------------------------------------------------------------------
task do_cache_rd;
    input  [AW-1:AW0] req_addr;
    output [DW-1:0]   q;
    integer cyc;
    begin
        @(posedge clk); #1;
        addr  = req_addr;
        din   = {DW{1'b0}};
        wdsn  = {MW{1'b0}};   // irrelevant for reads
        rd    = 1'b1;
        wr    = 1'b0;
        @(posedge clk); #1;
        rd    = 1'b0;          // one-cycle pulse
        cyc   = 0;
        while (!ok) begin
            @(posedge clk); #1;
            cyc = cyc + 1;
            if (cyc > 2000) begin
                $display("RESULT: FAIL — rd timeout at addr=%0h", req_addr);
                $finish;
            end
        end
        q = dout;
    end
endtask

task do_cache_wr;
    input  [AW-1:AW0] req_addr;
    input  [DW-1:0]   data;
    input  [MW-1:0]   dsn;
    integer cyc;
    begin
        @(posedge clk); #1;
        addr  = req_addr;
        din   = data;
        wdsn  = dsn;
        rd    = 1'b0;
        wr    = 1'b1;
        @(posedge clk); #1;
        wr    = 1'b0;          // one-cycle pulse
        cyc   = 0;
        while (!ok) begin
            @(posedge clk); #1;
            cyc = cyc + 1;
            if (cyc > 2000) begin
                $display("RESULT: FAIL — wr timeout at addr=%0h", req_addr);
                $finish;
            end
        end
    end
endtask

// ---------------------------------------------------------------------------
// Test sequence
// ---------------------------------------------------------------------------
integer i;
reg [DW-1:0] got;
reg          pass;

initial begin
    rst  = 1'b1;
    addr = {(AW-AW0){1'b0}};
    din  = {DW{1'b0}};
    wdsn = {MW{1'b0}};
    rd   = 1'b0;
    wr   = 1'b0;
    pass = 1'b1;

    repeat (20) @(posedge clk);
    rst = 1'b0;

    // Wait for SDRAM init complete (init deasserts)
    begin : wait_init
        for (i = 0; i < 25000; i = i + 1) begin
            @(posedge clk);
            if (!init) disable wait_init;
        end
        $display("RESULT: FAIL — timeout waiting for SDRAM init");
        $finish;
    end

    repeat (4) @(posedge clk);

    // -----------------------------------------------------------------------
    // Test 1: WRITE A0, READ BACK (cache HIT on second read)
    // -----------------------------------------------------------------------
    // Write DATA_A0 to A0 (cache miss → fill from SDRAM then dirty-write)
    do_cache_wr(ADDR_A0, DATA_A0, 8'h00);   // wdsn=00 = write all bytes

    // Read A0 back — must be a hit (no SDRAM burst)
    do_cache_rd(ADDR_A0, got);
    if (got !== DATA_A0) begin
        $display("RESULT: FAIL — test1 hit-rd: got %016h, exp %016h", got, DATA_A0);
        pass = 1'b0;
    end

    // -----------------------------------------------------------------------
    // Test 2: WRITE A1 (different line, cache MISS → fill), READ BACK
    // -----------------------------------------------------------------------
    do_cache_wr(ADDR_A1, DATA_A1, 8'h00);
    do_cache_rd(ADDR_A1, got);
    if (got !== DATA_A1) begin
        $display("RESULT: FAIL — test2 A1 rd: got %016h, exp %016h", got, DATA_A1);
        pass = 1'b0;
    end

    // -----------------------------------------------------------------------
    // Test 3: PARTIAL WRITE at A0
    //   wdsn=8'hF0: masks bytes 4-7 (din[63:32]), writes bytes 0-3 (din[31:0])
    //   din upper = 0xAAAAAAAA (masked → stays 0xCAFEBABE)
    //   din lower = 0xDEADBEEF (written)
    //   expected  = 64'hCAFEBABE_DEADBEEF
    // -----------------------------------------------------------------------
    do_cache_wr(ADDR_A0, PARTIAL_DIN, PARTIAL_DSN);
    do_cache_rd(ADDR_A0, got);
    if (got !== PARTIAL_EXP) begin
        $display("RESULT: FAIL — test3 partial: got %016h, exp %016h", got, PARTIAL_EXP);
        $display("  wdsn=8'hF0: masks bytes[7:4] (din[63:32]), writes bytes[3:0] (din[31:0])");
        $display("  upper half: exp 0xCAFEBABE (unchanged), lower: exp 0xDEADBEEF (written)");
        pass = 1'b0;
    end

    if (pass)
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
