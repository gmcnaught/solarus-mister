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
    // [#44] dedicated phase-shifted SDRAM output clock (PLL general[3]). Clocks the
    // SDRAM_CLK forwarder DDIO below so the chip clock is the swept-phase output and
    // the SDRAM_CLK generated-clock + I/O delays actually bind in STA. In sim, tie to
    // clk (the SDRAM_CLK pin is unused-in-sim).
    input  wire        clk_sdram,
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

    // ---- STAGE (ch1, write-only) -------------------------------------------
    // [#44] SDRAM source-staging WRITE path (BLT_OP_STAGE DDR3->SDRAM atlas copy).
    // Dedicated write channel so P_SRC (ch5) stays read-only/tunable. stage_wr is
    // held until stage_ok (cache-ok), single-qword writes (src_sdram_din64 = 1 qword).
    input  wire [26:0] stage_addr,   // byte address (qword-aligned) of the atlas write
    input  wire        stage_wr,
    input  wire [63:0] stage_din,    // 64-bit write data (the staged beat)
    input  wire [ 7:0] stage_wdsn,   // active-low byte-select; full write = 8'h00
    output wire        stage_ok,

    // ---- Coherency ----------------------------------------------------------
    input  wire        vs,          // frame swap — rising edge triggers ch0 flush
    output wire        coh_busy,    // high during the vsync flush/invalidate
    // [stage-barrier] Intra-frame ch1->ch5 coherency. The blitter pulses
    // stage_barrier after a STAGE batch completes and BEFORE the first source
    // (P_SRC/ch5) read that consumes it: commit ch1's dirty atlas lines to SDRAM
    // then invalidate ch5 so the source re-fetch sees the fresh atlas. Decoupled
    // from vs because the engine STAGEs and BLITs a surface in the SAME frame's
    // command ring (no vsync separates the write from the read).
    input  wire        stage_barrier, // one-cycle request: flush ch1 + invalidate ch5
    output wire        stage_busy,    // high while the stage-barrier flush/invalidate runs
    // [dst-barrier] Intra-frame ch0->ch5 coherency for the per-frame carry-forward
    // FB->FB copy. The blitter pulses dst_barrier at frame start (BEFORE the first
    // command, i.e. before the carry-forward BLIT reads the previous FB via P_SRC/ch5):
    // commit ch0's (P_DST) dirty framebuffer lines to SDRAM then invalidate ch5 so the
    // carry-forward source re-fetch sees the previous frame's freshly-composited pixels.
    // Decoupled from vs (the vsync ch0 flush is async to the blitter's frame processing,
    // so without this handshake the carry-forward races/wedges and the two FBs diverge).
    // Served by the same ch0-flush sequencer as vs (shares flush0 + INVAL_MASK0); raises
    // dst_busy (not the global coh_busy) so it does not stall the scanout fetch.
    input  wire        dst_barrier,   // one-cycle request: flush ch0 + invalidate ch0/4/5
    output wire        dst_busy,      // high while the dst-barrier flush/invalidate runs

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
// [residency/XL] jtframe 128MB: cache_mux XL activates at SDRAM_AW==25 (xl_addr) and a
// FULL channel widens its external SDRAM address to EW=SDRAM_AW+2 (=27 -> reaches byte
// bit 26 = 128MB). The client addr port of a FULL channel is [CH_AW-1:AW0_64] = [26:3].
// burst_sdram's XL is a DIFFERENT convention (AW==24), so we feed it SDRAM_AW-1 (=24):
// cache_mux emits {chip, ext[23:1]} (24b) which maps to burst addr[23:0], chip=addr[23].
// XL_MODE gates ALL of this so the non-XL (64MB) path stays byte-identical to baseline
// (FULL=0, CH_AW=SDRAM_AW, BURST_AW=SDRAM_AW) — the sim runs at SDRAM_AW=23.
localparam integer XL_MODE  = (SDRAM_AW == 25) ? 1 : 0;
localparam integer CH_FULL  = XL_MODE;                          // FULL on the 4 active channels in XL
localparam integer CH_AW    = XL_MODE ? (SDRAM_AW + 2) : SDRAM_AW;   // FULL client addr width (128MB)
localparam integer BURST_AW = XL_MODE ? (SDRAM_AW - 1) : SDRAM_AW;   // burst XL convention (AW==24)

// INVAL_MASK0: after ch0's flush commits, invalidate ch0(bit0) ONLY.
//   ch5 (P_SRC / atlas) is NOT invalidated here: the atlas uploads once and persists
//   across frames; forcing a cold re-fetch every vsync wasted SRCFILL bandwidth.
//   The sole correct ch5 invalidation is stage_barrier (INVAL_MASK1), fired intra-frame
//   after a STAGE batch writes a fresh atlas. (Was 8'b0010_0001; the ch5 bit forced a
//   cold atlas refetch every frame.)
//   ch4 (P_SCAN) is deliberately absent too: this flush is fired both on vsync AND
//   intra-frame by the dst-barrier; invalidating the scanout line cache mid-frame starves
//   the reader. ch4 is invalidated separately, vsync-ONLY, via flush2/INVAL_MASK2 below.
localparam [7:0] INVAL_MASK0 = 8'b0000_0001;
// [#44] INVAL_MASK1: after ch1's STAGE flush commits the atlas to SDRAM, invalidate
//   ch5(bit5) P_SRC so source reads re-fetch the freshly-staged atlas.
localparam [7:0] INVAL_MASK1 = 8'b0010_0000;
// INVAL_MASK2: ch2 is an unused cache; we (ab)use its flush channel purely to carry the
//   ch4(bit4) P_SCAN invalidate, fired ONLY on vsync (at vblank, where dropping the
//   scanout line cache is safe). Keeps the scanout invalidate off the intra-frame path.
localparam [7:0] INVAL_MASK2 = 8'b0001_0000;

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
// Coherency sequencers (own always-blocks per reg). TWO independent sequencers
// drive the two flush channels, which target DISJOINT caches (ch0 vs ch1) and so
// never conflict at the cache level; the mux flush block serializes their two
// invalidate sub-sequences internally.
//
//   (A) ch0-flush sequencer — serves vsync AND the carry-forward dst-barrier:
//       flush0 commits ch0 (P_DST) then invalidates ch0 ONLY (INVAL_MASK0).
//       ch5 (P_SRC / atlas) is NOT invalidated here — the atlas persists across
//       frames and is solely invalidated by stage_barrier (INVAL_MASK1). On vsync
//       ONLY it ALSO fires flush2, which invalidates ch4 (P_SCAN) via INVAL_MASK2 —
//       the scanout invalidate is kept off the intra-frame dst-barrier so it cannot
//       starve the reader mid-frame. coh_busy (vsync) held until flush_done0 &
//       flush_done2; dst_busy (carry-forward) held until flush_done0.
//   (B) STAGE-BARRIER sequencer — on stage_barrier: flush1 commits ch1 (STAGE
//       atlas) then invalidates ch5 (INVAL_MASK1). stage_busy held until flush_done1.
//       This is the sole correct ch5 invalidation path.
//
// ch1 is no longer flushed on vs (it is committed intra-frame by the barrier before
// any P_SRC consumer); this also removes the old dual-flush_done latching hazard.
// ---------------------------------------------------------------------------
wire flush_done0;
wire flush_done1;   // ch1 STAGE-channel flush completion (consumed by sequencer B)
wire flush_done2;   // ch2-channel flush completion — carries the vsync-only ch4 invalidate

// ---- (A) ch0-flush sequencer: serves VSYNC (global) and DST-BARRIER (intra-frame)
// Both triggers commit ch0 (P_DST) + invalidate ch0 only (INVAL_MASK0) — physically the
// same flush0 sequence — and differ ONLY in which busy flag they raise: vsync raises the
// global coh_busy (stalls every client), dst-barrier raises dst_busy (stalls only the
// blitter, which waits for it before the carry-forward read). ch5 (P_SRC) is NOT
// invalidated here; see stage_barrier (INVAL_MASK1). A 1-deep pending latch per
// source guarantees a trigger arriving DURING an in-flight flush is not lost: the host
// paces the dst-barrier to just after vblank, so it routinely coincides with the vsync
// flush. VSYNC has priority; the other request is served immediately after.
// [#104] Synchronize vs (may cross from the video clock) through a 3-FF chain BEFORE the
// rising-edge detect, and detect between the two RESOLVED stages ([2]&[1]). The old
// single vs_d edge-detected a still-async vs -> a metastable sample could mis-time the
// vsync ch0 flush/invalidate. The added 1-2 clk of latency is negligible for a per-frame
// vsync event.
reg [2:0] vs_sync;
always @(posedge clk or posedge rst) begin
    if (rst) vs_sync <= 3'b0;
    else     vs_sync <= {vs_sync[1:0], vs};
end
wire vs_rise = ~vs_sync[2] & vs_sync[1];

localparam [1:0] C_IDLE = 2'd0,
                 C_FLUSH= 2'd1,
                 C_WAIT = 2'd2;
reg [1:0] coh_state;
reg       flush0;
reg       flush2;        // vsync-only ch4 invalidate (via ch2's flush channel)
reg       coh_busy_r;
reg       dst_busy_r;
reg       fd0_seen;
reg       fd2_seen;      // flush_done2 latched (vsync ch4-invalidate complete)
reg       pend_vs;       // latched vsync request awaiting service
reg       pend_dst;      // latched dst-barrier request awaiting service
reg       serving_vs;    // the in-flight flush is vsync-origin (else dst-origin)

// Consume (clear pending + start flush) when idle; vsync takes priority.
wire consume_vs  = (coh_state == C_IDLE) && pend_vs;
wire consume_dst = (coh_state == C_IDLE) && !pend_vs && pend_dst;
wire start_flush = consume_vs | consume_dst;
// A vsync flush also fires flush2 (ch4 invalidate), so it is done only when BOTH
// flush_done0 and flush_done2 are seen; a dst flush uses flush0 alone.
wire flush_complete = serving_vs ? (fd0_seen & fd2_seen) : fd0_seen;

// Pending latches: SET on the trigger pulse, hold until consumed. Set has priority over
// clear (the OR), so a trigger coinciding with consumption of the OTHER source stays
// pending rather than being dropped.
always @(posedge clk or posedge rst) begin
    if (rst) pend_vs  <= 1'b0;
    else     pend_vs  <= vs_rise     | (pend_vs  & ~consume_vs);
end
always @(posedge clk or posedge rst) begin
    if (rst) pend_dst <= 1'b0;
    else     pend_dst <= dst_barrier | (pend_dst & ~consume_dst);
end

always @(posedge clk or posedge rst) begin
    if (rst)
        coh_state <= C_IDLE;
    else case (coh_state)
        C_IDLE:  if (start_flush)    coh_state <= C_FLUSH;
        // Hold one cycle in C_FLUSH so flush0/flush2 are registered before sampling.
        C_FLUSH:                     coh_state <= C_WAIT;
        C_WAIT:  if (flush_complete) coh_state <= C_IDLE;
        default:                     coh_state <= C_IDLE;
    endcase
end

// Remember which source this in-flight flush serves (vsync priority).
always @(posedge clk or posedge rst) begin
    if (rst)                serving_vs <= 1'b0;
    else if (start_flush)   serving_vs <= consume_vs;
end

always @(posedge clk or posedge rst) begin
    if (rst) flush0 <= 1'b0;
    // Pulse flush0 for one cycle on entering the flush sequence; the cache latches it.
    else     flush0 <= start_flush;
end

// flush2 (ch4 invalidate) fires ONLY for a vsync-origin flush — never intra-frame.
always @(posedge clk or posedge rst) begin
    if (rst) flush2 <= 1'b0;
    else     flush2 <= consume_vs;
end

// coh_busy: global stall, asserted from vs_rise until the vsync-origin flush completes
// (unchanged semantics — other clients gate on this only for the vsync flush).
always @(posedge clk or posedge rst) begin
    if (rst)                                                       coh_busy_r <= 1'b0;
    else if (vs_rise)                                              coh_busy_r <= 1'b1;
    else if (coh_state == C_WAIT && flush_complete && serving_vs)  coh_busy_r <= 1'b0;
end

// dst_busy: asserted while a dst-origin flush is in flight (the blitter waits on it).
always @(posedge clk or posedge rst) begin
    if (rst)                                                       dst_busy_r <= 1'b0;
    else if (consume_dst)                                          dst_busy_r <= 1'b1;
    else if (coh_state == C_WAIT && flush_complete && !serving_vs) dst_busy_r <= 1'b0;
end

always @(posedge clk or posedge rst) begin
    if (rst)              fd0_seen <= 1'b0;
    else if (start_flush) fd0_seen <= 1'b0;     // a new flush sequence begins
    else if (flush_done0) fd0_seen <= 1'b1;
end

always @(posedge clk or posedge rst) begin
    if (rst)              fd2_seen <= 1'b0;
    else if (start_flush) fd2_seen <= 1'b0;     // a new flush sequence begins
    else if (flush_done2) fd2_seen <= 1'b1;
end

assign coh_busy = coh_busy_r;
assign dst_busy = dst_busy_r;

// ---- (B) STAGE-BARRIER sequencer: flush ch1 (STAGE atlas) + invalidate ch5 -
localparam [1:0] SB_IDLE = 2'd0,
                 SB_FLUSH= 2'd1,
                 SB_WAIT = 2'd2;
reg [1:0] sb_state;
reg       flush1;
reg       stage_busy_r;
reg       fd1_seen;

always @(posedge clk or posedge rst) begin
    if (rst)
        sb_state <= SB_IDLE;
    else case (sb_state)
        SB_IDLE:  if (stage_barrier) sb_state <= SB_FLUSH;
        // Hold one cycle in SB_FLUSH so flush1 is registered before sampling.
        SB_FLUSH:                    sb_state <= SB_WAIT;
        SB_WAIT:  if (fd1_seen)      sb_state <= SB_IDLE;
        default:                     sb_state <= SB_IDLE;
    endcase
end

always @(posedge clk or posedge rst) begin
    if (rst) flush1 <= 1'b0;
    else     flush1 <= (sb_state == SB_IDLE) && stage_barrier;
end

always @(posedge clk or posedge rst) begin
    if (rst)                                          stage_busy_r <= 1'b0;
    else if ((sb_state == SB_IDLE) && stage_barrier)  stage_busy_r <= 1'b1;
    else if (sb_state == SB_WAIT && fd1_seen)         stage_busy_r <= 1'b0;
end

always @(posedge clk or posedge rst) begin
    if (rst)                                          fd1_seen <= 1'b0;
    else if ((sb_state == SB_IDLE) && stage_barrier)  fd1_seen <= 1'b0; // new sequence
    else if (flush_done1)                             fd1_seen <= 1'b1;
end

assign stage_busy = stage_busy_r;

`ifdef FABRIC_ASSERT
// [#97 SVA] stage_barrier must only pulse while the SB sequencer is IDLE. There is no
// pend_stage latch (see the (B) sequencer note): a barrier requested mid-sequence
// (SB_FLUSH/SB_WAIT) is silently DROPPED -> ch1 not committed + ch5 not invalidated ->
// the #84 stale-plane class. This encodes the caller-serialization invariant that makes
// the absent latch safe: blitter_top HOLDS its FSM in S_STAGE_BARRIER_WAIT until
// stage_busy clears, so it never re-pulses mid-sequence. iverilog immediate assertion
// (concurrent `assert property` is unsupported); "FAIL" in the message trips run_sims.sh.
always @(posedge clk) if (!rst)
  assert (!(stage_barrier && sb_state != SB_IDLE))
  else $display("FABRIC-ASSERT FAIL [sdram_fb_cache]: stage_barrier pulsed in sb_state=%0d (not SB_IDLE) @%0t -> barrier silently DROPPED (no pend latch)", sb_state, $time);
`endif

// ---------------------------------------------------------------------------
// cache_mux <-> burst_sdram glue
// ---------------------------------------------------------------------------
wire [SDRAM_AW-1:1] mux_addr;
// [XL] Explicit BURST_AW-wide burst address (no implicit port truncation, so Quartus and
// iverilog cannot diverge). XL: mux_addr is [24:1] (24b) with MSB=chip -> burst addr[23:0]
// (chip=addr[23]). non-XL: {1'b0,mux_addr} = SDRAM_AW bits = BURST_AW.
wire [BURST_AW-1:0] burst_addr = XL_MODE ? mux_addr : {1'b0, mux_addr};
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
    // ch0 = P_DST (R/W, big cache) — FULL: addresses the whole 128MB span
    .AW0      ( CH_AW       ), .FULL0 ( CH_FULL ),
    .BLOCKS0  ( DST_BLOCKS  ),
    .BLKSIZE0 ( DST_BLKSIZE ),
    .DW0      ( 64          ),
    .OFFSET0  ( DST_OFFSET_W),
    .INVAL_MASK0 ( INVAL_MASK0 ),
    // ch1 = STAGE (write-only, #44): atlas DDR3->SDRAM staging write channel. Shares
    //   the source SDRAM region with ch5 P_SRC, so OFFSET1 == SRC_OFFSET_W (same SDRAM
    //   addresses). INVAL_MASK1 invalidates ch5 after the atlas flush.
    .AW1      ( CH_AW       ), .FULL1 ( CH_FULL ), .BLOCKS1 ( RO_BLOCKS ), .BLKSIZE1 ( RO_BLKSIZE ), .DW1 ( 64 ),
    .OFFSET1  ( SRC_OFFSET_W ),
    .INVAL_MASK1 ( INVAL_MASK1 ),
    // ch2 cache unused, but its flush channel carries the vsync-only ch4 invalidate.
    .INVAL_MASK2 ( INVAL_MASK2 ),
    // ch2..3 unused — read-only-sized defaults, tied off below
    .AW2      ( SDRAM_AW    ), .BLOCKS2 ( RO_BLOCKS ), .BLKSIZE2 ( RO_BLKSIZE ), .DW2 ( 64 ),
    .AW3      ( SDRAM_AW    ), .BLOCKS3 ( RO_BLOCKS ), .BLKSIZE3 ( RO_BLKSIZE ), .DW3 ( 64 ),
    // ch4 = P_SCAN (read-only) — FULL in XL
    .AW4      ( CH_AW       ), .FULL4 ( CH_FULL ), .BLOCKS4 ( RO_BLOCKS ), .BLKSIZE4 ( RO_BLKSIZE ), .DW4 ( 64 ),
    .OFFSET4  ( SCAN_OFFSET_W ),
    // ch5 = P_SRC (read-only) — FULL in XL
    .AW5      ( CH_AW       ), .FULL5 ( CH_FULL ), .BLOCKS5 ( RO_BLOCKS ), .BLKSIZE5 ( RO_BLKSIZE ), .DW5 ( 64 ),
    .OFFSET5  ( SRC_OFFSET_W ),
    // ch6,7 unused
    .AW6      ( SDRAM_AW    ), .BLOCKS6 ( RO_BLOCKS ), .BLKSIZE6 ( RO_BLKSIZE ), .DW6 ( 64 ),
    .AW7      ( SDRAM_AW    ), .BLOCKS7 ( RO_BLOCKS ), .BLKSIZE7 ( RO_BLKSIZE ), .DW7 ( 64 )
) u_mux (
    .rst    ( rst  ),
    .clk    ( clk  ),

    // ch0 = P_DST (read/write)
    .addr0  ( dst_addr[CH_AW-1:AW0_64] ),
    .dout0  ( dst_dout ),
    .rd0    ( dst_rd   ),
    .wr0    ( dst_wr   ),
    .din0   ( dst_din  ),
    .wdsn0  ( dst_wdsn ),
    .ok0    ( dst_ok   ),
    .flush0 ( flush0   ),
    .flushing0   (             ),
    .flush_done0 ( flush_done0 ),

    // ch1 = STAGE (write-only, #44): blitter atlas DDR3->SDRAM staging writes.
    .addr1  ( stage_addr[CH_AW-1:AW0_64] ), .dout1 ( ), .rd1 ( 1'b0 ), .wr1 ( stage_wr ),
    .din1   ( stage_din ), .wdsn1 ( stage_wdsn ), .ok1 ( stage_ok ),
    .flush1 ( flush1 ), .flushing1 ( ), .flush_done1 ( flush_done1 ),
    // ch2..3 unused (read/write capable, tied off)
    .addr2  ( {(SDRAM_AW-AW0_64){1'b0}} ), .dout2 ( ), .rd2 ( 1'b0 ), .wr2 ( 1'b0 ),
    .din2   ( 64'd0 ), .wdsn2 ( 8'hff ), .ok2 ( ),
    .flush2 ( flush2 ), .flushing2 ( ), .flush_done2 ( flush_done2 ),
    .addr3  ( {(SDRAM_AW-AW0_64){1'b0}} ), .dout3 ( ), .rd3 ( 1'b0 ), .wr3 ( 1'b0 ),
    .din3   ( 64'd0 ), .wdsn3 ( 8'hff ), .ok3 ( ),
    .flush3 ( 1'b0 ), .flushing3 ( ), .flush_done3 ( ),

    // ch4 = P_SCAN (read-only)
    .addr4  ( scan_addr[CH_AW-1:AW0_64] ),
    .dout4  ( scan_dout ),
    .rd4    ( scan_rd   ),
    .ok4    ( scan_ok   ),
    .flush4 ( 1'b0 ), .flushing4 ( ), .flush_done4 ( ),

    // ch5 = P_SRC (read-only)
    .addr5  ( p0_addr[CH_AW-1:AW0_64] ),
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
// [residency/XL] burst_sdram's XL convention is AW==24 (chip = addr[AW-1]); the cache_mux
// convention is SDRAM_AW==25. Feed burst AW = SDRAM_AW-1 so both engage XL for 128MB.
// cache_mux.addr (= mux_addr, [SDRAM_AW-1:1] = 24b at SDRAM_AW=25) already carries the
// chip bit as its MSB, mapping directly to burst addr[23:0] (chip=addr[23]).
jtframe_burst_sdram #(
    .AW      ( BURST_AW ),
    .HF      ( HF       ),
    .MISTER  ( MISTER   ),
    .PROG_LEN( PROG_LEN )
) u_sdram_ctrl (
    .rst        ( rst                  ),
    .clk        ( clk                  ),
    .init       ( init                 ),
    .addr       ( burst_addr           ),   // [XL] explicit BURST_AW-wide (see decl)
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
    .prog_addr  ( {BURST_AW{1'b0}}     ),
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
    .datain_h ( 1'b0       ),
    .datain_l ( 1'b1       ),
    .outclock ( clk_sdram  ),   // [#44] phase-shifted general[3], not clk_sys
    .dataout  ( sdram_clk  ),
    .aclr     ( 1'b0      ),
    .aset     ( 1'b0      ),
    .oe       ( 1'b1      ),
    .outclocken( 1'b1     ),
    .sclr     ( 1'b0      ),
    .sset     ( 1'b0      )
);

endmodule
`default_nettype wire
