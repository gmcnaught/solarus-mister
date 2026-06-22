// sdram_fb_cache.sv — framebuffer SDRAM cache wrapper.
//
// Controller pivot (spec docs/superpowers/specs/2026-06-21-jtframe-cache-sdram-fb-design.md):
//   the hand-rolled sdram_burst_arb is replaced by jtframe's cache subsystem.
//   A jtframe_cache_mux fronts a single jtframe_burst_sdram with three client
//   channels, plus a small coherency sequencer that flushes+invalidates the
//   caches on every frame swap (vs).
//
//   ch0 = P_DST  (read/write) — the big compositor destination cache.
//   ch4 = P_SCAN (read-only)  — scanout reader.
//   ch5 = P_SRC  (read-only)  — blitter source reader.
//   ch1..3, ch6, ch7 are tied off (unused).
//
// DW=64 on every channel; the channel addr port is [AW-1:3] (a qword index).
//
// Address model (see tb_sdram_fb_cache.sv for the matching pre-load math):
//   client byte addr A (qword-aligned) -> cache qword index A[AW-1:3]
//   -> jtframe_cache ext word-addr = index*4
//   -> cache_mux SDRAM word-addr = ext_word + OFFSET (16-bit-word units).
//   The three channels are separated by OFFSET so they occupy disjoint SDRAM
//   regions within bank 0.
//
// wdsn is ACTIVE-LOW byte-select (verified Task 1): wdsn[i]=0 enables lane i,
//   wdsn[i]=1 masks it. Full qword write = 8'h00.
//
// Coherency contract:
//   The cache_mux flush block (jtframe_cache_mux_flush) sequences flush THEN
//   invalidate automatically when a channel's INVAL_MASK is non-zero: asserting
//   flush0 commits ch0's dirty lines to SDRAM, and only AFTER the writeback
//   completes does it pulse `invalidate` on the INVAL_MASK0 channels and finally
//   raise flush_done0. We set INVAL_MASK0 to invalidate ch0 (so re-reads come
//   cold), ch4 and ch5 (so the readers re-fetch the new frame). The sequencer in
//   this file just pulses flush0 on vs-rising and holds coh_busy until
//   flush_done0 — the mux guarantees flush-before-invalidate.
//
// Quartus constraint: exactly one always-block per reg/array (Error 10028);
//   iverilog won't catch a violation. The refresh timer and the coherency FSM
//   each get their own always-block.
`default_nettype none

module sdram_fb_cache #(
    // jtframe_burst_sdram / cache_mux address width (16-bit-word address bits).
    parameter integer SDRAM_AW    = 23,
    parameter integer HF          = 1,
    parameter integer MISTER      = 0,
    parameter integer PROG_LEN    = 64,
    // Refresh interval in clk cycles (default 640 ~6.4 us @ 100 MHz; under the
    // 7.8 us row-refresh deadline). Overridable so sims can shorten it.
    parameter integer RFSH_PERIOD = 640,
    // ---- Cache geometry — CI-fit-tunable (conservative starting defaults) ----
    // P_DST is the big read/write cache; P_SCAN/P_SRC are small read-only caches.
    parameter integer DST_BLOCKS  = 8,
    parameter integer DST_BLKSIZE = 1024,
    parameter integer RO_BLOCKS   = 2,
    parameter integer RO_BLKSIZE  = 256,
    // ---- Channel SDRAM offsets (16-bit-word units) ----
    // #2 fix: these are ADDED to the client's SDRAM word address. ch0 (P_DST,
    // compositor) and ch4 (P_SCAN, scanout) address the SAME framebuffer via the
    // same SDRAM_FB0/1_BASE byte addresses, so they MUST share an offset — a
    // non-zero SCAN offset made the scanout read a region 0x2000 words away from
    // where the compositor wrote (black/garbage, frame counter stuck). The clients
    // already use disjoint byte addresses (FB vs source atlas), so no artificial
    // per-channel separation is needed: all offsets are 0.
    parameter integer DST_OFFSET_W  = 0,
    parameter integer SCAN_OFFSET_W = 0,
    parameter integer SRC_OFFSET_W  = 0
)(
    input  wire        clk,
    input  wire        rst,

    // jtframe_burst_sdram power-on init flag (high during init).
    output wire        init,

    // ---- P_DST (ch0, read/write) -------------------------------------------
    input  wire [26:0] dst_addr,    // byte address (qword-aligned)
    input  wire        dst_rd,
    input  wire        dst_wr,
    input  wire [63:0] dst_din,
    input  wire [ 7:0] dst_wdsn,    // active-low byte-select
    output wire [63:0] dst_dout,
    output wire        dst_ok,

    // ---- P_SCAN (ch4, read-only) -------------------------------------------
    input  wire [26:0] scan_addr,
    input  wire        scan_rd,
    output wire [63:0] scan_dout,
    output wire        scan_ok,

    // ---- P_SRC (ch5, read-only) --------------------------------------------
    input  wire [26:0] p0_addr,
    input  wire        p0_rd,
    output wire [63:0] p0_dout,
    output wire        p0_ok,

    // ---- Coherency ----------------------------------------------------------
    input  wire        vs,          // frame swap — rising edge triggers flush
    output wire        coh_busy,    // high during flush/invalidate

    // ---- SDRAM physical pins -----------------------------------------------
    inout  wire [15:0] sdram_dq,
    output wire [12:0] sdram_a,
    output wire        sdram_dqml,
    output wire        sdram_dqmh,
    output wire [ 1:0] sdram_ba,
    output wire        sdram_nwe,
    output wire        sdram_ncas,
    output wire        sdram_nras,
    output wire        sdram_ncs,
    output wire        sdram_cke,
    output wire        sdram_clk
);

localparam integer AW0_64 = 3;   // DW==64 -> channel addr port is [AW-1:3]

// INVAL_MASK0: after ch0's flush commits, invalidate ch0(bit0), ch4(bit4),
//   ch5(bit5) so all three caches re-fetch the committed frame.
localparam [7:0] INVAL_MASK0 = 8'b0011_0001;

// ---------------------------------------------------------------------------
// Refresh timer (own always-block per reg). jtframe_burst_sdram defers the
// refresh to the next burst gap, so rfsh never corrupts a live burst.
// ---------------------------------------------------------------------------
reg [$clog2(RFSH_PERIOD)-1:0] hcnt;
wire rfsh = (hcnt == 0);

always @(posedge clk or posedge rst) begin
    if (rst)
        hcnt <= 0;
    else
        hcnt <= (hcnt == (RFSH_PERIOD - 1)) ? 0 : hcnt + 1;
end

// ---------------------------------------------------------------------------
// Coherency sequencer (own always-blocks per reg).
//   On vs-rising: assert flush0 and raise coh_busy. The mux's flush block does
//   flush-then-invalidate; flush_done0 (which the mux only asserts AFTER the
//   invalidate completes) clears the sequence.
// ---------------------------------------------------------------------------
wire flush_done0;

reg vs_d;
always @(posedge clk or posedge rst) begin
    if (rst) vs_d <= 1'b0;
    else     vs_d <= vs;
end
wire vs_rise = vs & ~vs_d;

localparam [1:0] C_IDLE = 2'd0,
                 C_FLUSH= 2'd1,
                 C_WAIT = 2'd2;
reg [1:0] coh_state;
reg       flush0;
reg       coh_busy_r;

always @(posedge clk or posedge rst) begin
    if (rst)
        coh_state <= C_IDLE;
    else case (coh_state)
        C_IDLE:  if (vs_rise)     coh_state <= C_FLUSH;
        // Hold one cycle in C_FLUSH so flush0 is registered before sampling done.
        C_FLUSH:                  coh_state <= C_WAIT;
        C_WAIT:  if (flush_done0) coh_state <= C_IDLE;
        default:                  coh_state <= C_IDLE;
    endcase
end

always @(posedge clk or posedge rst) begin
    if (rst)
        flush0 <= 1'b0;
    else
        // Pulse flush0 for one cycle on entering the flush sequence; the cache
        // latches the request internally.
        flush0 <= (coh_state == C_IDLE) && vs_rise;
end

always @(posedge clk or posedge rst) begin
    if (rst)
        coh_busy_r <= 1'b0;
    else if (vs_rise)
        coh_busy_r <= 1'b1;
    else if (coh_state == C_WAIT && flush_done0)
        coh_busy_r <= 1'b0;
end

assign coh_busy = coh_busy_r;

// ---------------------------------------------------------------------------
// cache_mux <-> burst_sdram glue
// ---------------------------------------------------------------------------
wire [SDRAM_AW-1:1] mux_addr;
wire [1:0]          mux_ba;
wire                mux_rd, mux_wr;
wire [15:0]         mux_din;     // burst_sdram -> mux (read data)
wire [15:0]         mux_dout;    // mux -> burst_sdram (write data)
wire                mux_ack, mux_dst, mux_dok, mux_rdy;

// ---------------------------------------------------------------------------
// jtframe_cache_mux — 3 active channels (ch0 R/W, ch4/ch5 read-only).
//   Unused channels (1,2,3,6,7) keep default params and tie their inputs off.
// ---------------------------------------------------------------------------
jtframe_cache_mux #(
    .SDRAM_AW ( SDRAM_AW    ),
    .ENDIAN   ( 0           ),
    // ch0 = P_DST (R/W, big cache)
    .AW0      ( SDRAM_AW    ),
    .BLOCKS0  ( DST_BLOCKS  ),
    .BLKSIZE0 ( DST_BLKSIZE ),
    .DW0      ( 64          ),
    .OFFSET0  ( DST_OFFSET_W),
    .INVAL_MASK0 ( INVAL_MASK0 ),
    // ch1..3 unused — read-only-sized defaults, tied off below
    .AW1      ( SDRAM_AW    ), .BLOCKS1 ( RO_BLOCKS ), .BLKSIZE1 ( RO_BLKSIZE ), .DW1 ( 64 ),
    .AW2      ( SDRAM_AW    ), .BLOCKS2 ( RO_BLOCKS ), .BLKSIZE2 ( RO_BLKSIZE ), .DW2 ( 64 ),
    .AW3      ( SDRAM_AW    ), .BLOCKS3 ( RO_BLOCKS ), .BLKSIZE3 ( RO_BLKSIZE ), .DW3 ( 64 ),
    // ch4 = P_SCAN (read-only)
    .AW4      ( SDRAM_AW    ), .BLOCKS4 ( RO_BLOCKS ), .BLKSIZE4 ( RO_BLKSIZE ), .DW4 ( 64 ),
    .OFFSET4  ( SCAN_OFFSET_W ),
    // ch5 = P_SRC (read-only)
    .AW5      ( SDRAM_AW    ), .BLOCKS5 ( RO_BLOCKS ), .BLKSIZE5 ( RO_BLKSIZE ), .DW5 ( 64 ),
    .OFFSET5  ( SRC_OFFSET_W ),
    // ch6,7 unused
    .AW6      ( SDRAM_AW    ), .BLOCKS6 ( RO_BLOCKS ), .BLKSIZE6 ( RO_BLKSIZE ), .DW6 ( 64 ),
    .AW7      ( SDRAM_AW    ), .BLOCKS7 ( RO_BLOCKS ), .BLKSIZE7 ( RO_BLKSIZE ), .DW7 ( 64 )
) u_mux (
    .rst    ( rst  ),
    .clk    ( clk  ),

    // ch0 = P_DST (read/write)
    .addr0  ( dst_addr[SDRAM_AW-1:AW0_64] ),
    .dout0  ( dst_dout ),
    .rd0    ( dst_rd   ),
    .wr0    ( dst_wr   ),
    .din0   ( dst_din  ),
    .wdsn0  ( dst_wdsn ),
    .ok0    ( dst_ok   ),
    .flush0 ( flush0   ),
    .flushing0   (             ),
    .flush_done0 ( flush_done0 ),

    // ch1..3 unused (read/write capable, tied off)
    .addr1  ( {(SDRAM_AW-AW0_64){1'b0}} ), .dout1 ( ), .rd1 ( 1'b0 ), .wr1 ( 1'b0 ),
    .din1   ( 64'd0 ), .wdsn1 ( 8'hff ), .ok1 ( ),
    .flush1 ( 1'b0 ), .flushing1 ( ), .flush_done1 ( ),
    .addr2  ( {(SDRAM_AW-AW0_64){1'b0}} ), .dout2 ( ), .rd2 ( 1'b0 ), .wr2 ( 1'b0 ),
    .din2   ( 64'd0 ), .wdsn2 ( 8'hff ), .ok2 ( ),
    .flush2 ( 1'b0 ), .flushing2 ( ), .flush_done2 ( ),
    .addr3  ( {(SDRAM_AW-AW0_64){1'b0}} ), .dout3 ( ), .rd3 ( 1'b0 ), .wr3 ( 1'b0 ),
    .din3   ( 64'd0 ), .wdsn3 ( 8'hff ), .ok3 ( ),
    .flush3 ( 1'b0 ), .flushing3 ( ), .flush_done3 ( ),

    // ch4 = P_SCAN (read-only)
    .addr4  ( scan_addr[SDRAM_AW-1:AW0_64] ),
    .dout4  ( scan_dout ),
    .rd4    ( scan_rd   ),
    .ok4    ( scan_ok   ),
    .flush4 ( 1'b0 ), .flushing4 ( ), .flush_done4 ( ),

    // ch5 = P_SRC (read-only)
    .addr5  ( p0_addr[SDRAM_AW-1:AW0_64] ),
    .dout5  ( p0_dout ),
    .rd5    ( p0_rd   ),
    .ok5    ( p0_ok   ),
    .flush5 ( 1'b0 ), .flushing5 ( ), .flush_done5 ( ),

    // ch6,7 unused
    .addr6  ( {(SDRAM_AW-AW0_64){1'b0}} ), .dout6 ( ), .rd6 ( 1'b0 ), .ok6 ( ),
    .flush6 ( 1'b0 ), .flushing6 ( ), .flush_done6 ( ),
    .addr7  ( {(SDRAM_AW-AW0_64){1'b0}} ), .dout7 ( ), .rd7 ( 1'b0 ), .ok7 ( ),
    .flush7 ( 1'b0 ), .flushing7 ( ), .flush_done7 ( ),

    // shared SDRAM request port
    .addr   ( mux_addr ),
    .ba     ( mux_ba   ),
    .rd     ( mux_rd   ),
    .wr     ( mux_wr   ),
    .din    ( mux_din  ),
    .dout   ( mux_dout ),
    .ack    ( mux_ack  ),
    .dst    ( mux_dst  ),
    .dok    ( mux_dok  ),
    .rdy    ( mux_rdy  )
);

// ---------------------------------------------------------------------------
// jtframe_burst_sdram — single SDRAM controller for the mux.
//   prog_* path tied off (burst path is the active one here, same as the
//   cache_mux rw reference test).
// ---------------------------------------------------------------------------
jtframe_burst_sdram #(
    .AW      ( SDRAM_AW ),
    .HF      ( HF       ),
    .MISTER  ( MISTER   ),
    .PROG_LEN( PROG_LEN )
) u_sdram_ctrl (
    .rst        ( rst                  ),
    .clk        ( clk                  ),
    .init       ( init                 ),
    .addr       ( {1'b0, mux_addr}     ),
    .ba         ( mux_ba               ),
    .rd         ( mux_rd               ),
    .wr         ( mux_wr               ),
    .din        ( mux_dout             ),
    .dout       ( mux_din              ),
    .ack        ( mux_ack              ),
    .dst        ( mux_dst              ),
    .dok        ( mux_dok              ),
    .rdy        ( mux_rdy              ),
    .prog_en    ( 1'b0                 ),
    .prog_addr  ( {SDRAM_AW{1'b0}}     ),
    .prog_rd    ( 1'b0                 ),
    .prog_wr    ( 1'b0                 ),
    .prog_din   ( 16'h0000             ),
    .prog_dsn   ( 2'b11                ),
    .prog_ba    ( 2'b00                ),
    .prog_dst   (                      ),
    .prog_dok   (                      ),
    .prog_rdy   (                      ),
    .prog_ack   (                      ),
    .rfsh       ( rfsh                 ),
    .sdram_dq   ( sdram_dq             ),
    .sdram_a    ( sdram_a              ),
    .sdram_dqml ( sdram_dqml           ),
    .sdram_dqmh ( sdram_dqmh           ),
    .sdram_ba   ( sdram_ba             ),
    .sdram_nwe  ( sdram_nwe            ),
    .sdram_ncas ( sdram_ncas           ),
    .sdram_nras ( sdram_nras           ),
    .sdram_ncs  ( sdram_ncs            ),
    .sdram_cke  ( sdram_cke            )
);

// ---------------------------------------------------------------------------
// SDRAM_CLK forwarder — phase-shifted clock out via DDIO (copied from
// Solarus.sv). In sim the chip model is clocked off the tb clock directly, so
// this only drives the (unused-in-sim) sdram_clk pin; in synthesis it is the
// real SDRAM clock forwarder. The sim stub altddio_out_stub.sv elaborates it.
// ---------------------------------------------------------------------------
altddio_out #(
    .extend_oe_disable("OFF"),
    .intended_device_family("Cyclone V"),
    .invert_output("OFF"),
    .lpm_hint("UNUSED"),
    .lpm_type("altddio_out"),
    .oe_reg("UNREGISTERED"),
    .power_up_high("OFF"),
    .width(1)
) sdramclk_ddr (
    .datain_h ( 1'b0      ),
    .datain_l ( 1'b1      ),
    .outclock ( clk       ),
    .dataout  ( sdram_clk ),
    .aclr     ( 1'b0      ),
    .aset     ( 1'b0      ),
    .oe       ( 1'b1      ),
    .outclocken( 1'b1     ),
    .sclr     ( 1'b0      ),
    .sset     ( 1'b0      )
);

endmodule
`default_nettype wire
