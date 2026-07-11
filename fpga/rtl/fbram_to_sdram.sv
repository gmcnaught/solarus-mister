// fbram_to_sdram.sv -- one-time WORK-buffer -> SDRAM strided streamer for the
// Phase 3b background-plane cache. On a `start` pulse it streams the entire
// on-chip comp_fbram WORK buffer (one 320x240 cell, CELL_ROW_QW=80 qwords
// per row x CELL_ROWS=240 rows) out to a caller-supplied SDRAM write port.
// Read side is a straight linear walk of the WORK buffer (comp_fbram itself
// is always flat/contiguous); the WRITE side jumps by `dst_stride_qw`
// (latched at `start`) at every row boundary, so the destination can be a
// wider map-scan-order plane the cell is embedded in (Task 1's layout) --
// `sdram_wr_addr` output is RELATIVE, the caller adds the cell's absolute
// plane base on top (Task 3).
//
// BACKPRESSURE (added after a Quartus M10K fit failure: "needs more than 553
// [blocks]" -- the FIRST version of this feature paired a NO-backpressure
// streamer with a 32768-entry x 64-bit elastic FIFO in blitter_top.sv to
// avoid ever overflowing against a slow consumer; that FIFO alone cost
// ~205 M10K blocks against ~118 blocks of headroom). The destination SDRAM
// write port (sdram_fb_cache ch0) is a cache-ok request/response port, not a
// free-running sink: every address this bake touches is cold, so a write can
// take 30+ cycles to be accepted. `consumer_ready` tells this module the
// write currently held on sdram_wr_en/addr/data was accepted THIS cycle; the
// module holds that output completely stable until it sees consumer_ready=1,
// and paces its own production to match, so the caller needs no elastic
// buffer at all: this is the same hold-until-accept contract vram_demux's
// sd_wr/sd_ok and blitter_top's own STAGE writer (src_sdram_we_burst/
// src_sdram_ok) already use, so the caller can wire sdram_wr_en/addr/data
// straight into a ch0-style dst_wr/dst_addr/dst_din port with
// consumer_ready <= that port's *_ok.
//
// MANDATORY 1-CYCLE GAP after every accepted write (see jtframe_cache_mux.v's
// ok_hold[N] register): ch0's *_ok is NOT a clean one-shot pulse per request
// -- once the underlying cache signals completion, ok_hold LATCHES high and
// STAYS high for as long as the request line (dst_wr) stays asserted,
// clearing only on a cycle where dst_wr is actually low. The STAGE writer
// and vram_demux never hit this because they naturally leave gaps between
// requests (DDR3 reads, etc. in between); this module's whole point is
// back-to-back requests with no such natural gap, so it deliberately drops
// sdram_wr_en for exactly one cycle after every accepted write before
// presenting the next one -- otherwise the SAME stale ok_hold=1 would look
// like an instant accept for every subsequent (still-in-flight) address,
// and the cache would silently lose most of the writes. Cost: 1 extra cycle
// per qword, utterly dwarfed by ch0's real 30+ cycle cold-miss latency.
//
// PRECONDITION: This module's own dst_wr drops during the gap, but ok_hold
// only truly clears when the consumer's ENTIRE request line (dst_rd|dst_wr
// at the sdram_fb_cache ch0 port) goes idle. dst_rd is wired separately from
// vram_demux in Solarus.sv (not part of this module's backpressure logic).
// Safe TODAY only because vram_demux's ch0 read path is dead (is_fb always
// false); any future revival of that path MUST ALSO gate dst_rd on bgw_active
// (see bgw_ch0_mux.sv's revival note) or the identical write-drop bug this
// commit just fixed will silently reappear.
//
// Internal pipeline (2-slot skid, ordinary flip-flops -- negligible M10K
// cost, nothing like the deleted FIFO):
//   SLOT A (sdram_wr_en/addr/data): the item currently offered to the
//     consumer, held stable until accepted.
//   SLOT B (v1/a1/row_base1/col1 + v1_rdy): the NEXT item, staged one step
//     ahead. `v1` marks the slot occupied (an issued-but-not-yet-handed-off
//     read); `v1_rdy` marks that comp_fbram's registered read for it has
//     actually completed (comp_fbram's read is registered: a read issued at
//     cycle N has data at cycle N+1 relative to the issue pulse -- fixed and
//     NOT gated by this module's own backpressure, since comp_fbram doesn't
//     know or care whether SLOT A is stalled). `v1_rdy` ticks unconditionally
//     off that fixed latency; SLOT B itself (v1/a1/...) is only touched when
//     it's about to be vacated (moved into SLOT A) or refilled, so it can
//     never be silently overwritten/skipped while backpressure holds SLOT A.
//
// (An earlier version of this fix mirrored v1/a1 into a second register pair
// UNCONDITIONALLY every cycle, thinking that alone would track readiness
// safely under backpressure -- it does track readiness correctly, but since
// nothing gated it from ALSO racing ahead to a third value while the second
// was still unconsumed, it silently dropped qwords under a multi-cycle
// stall. The two-slot model above is stalled-safe: a slot cannot be
// refilled until it is actually drained.)
//
// Cost: ~FB_QWORDS+1 cycles per cell (19200+1 ~= 0.2ms @96MHz) was the
// original no-backpressure cost; it is now a FLOOR, not a fixed cost --
// actual wall time is however long the consumer takes to accept each of the
// FB_QWORDS writes (this runs OUTSIDE vblank, during the rare one-time bake,
// same contract as before).
// Copyright (C) 2026 -- GPL-3.0
`default_nettype none
module fbram_to_sdram #(
    parameter integer FB_QWORDS   = 19200,
    parameter integer AW          = 15,
    parameter integer CELL_ROW_QW = 80,    // one WORK-buffer row = 320px*2B/8
    parameter integer CELL_ROWS   = 240
)(
    input  wire          clk,
    input  wire          rst,
    input  wire          start,           // 1-cyc pulse: begin a work->SDRAM copy
    input  wire [23:0]   dst_stride_qw,   // destination row stride (qwords), latched at start
    // NOTE: no SystemVerilog default value on these two ports (tried,
    // reverted) -- Quartus 17.0 rejects `input wire x = 1'b0` on a module
    // port ("value cannot be assigned to input"), even though Icarus accepts
    // it fine. tb_fbram_to_sdram.sv and tb_fbram_to_sdram_backpressure.sv
    // (which instantiate this module directly and predate these ports) now
    // explicitly wire .argb4444_mode(1'b0), .rd_cov(4'd0) at their own
    // instantiation sites instead, to opt out of ARGB4444 mode.
    input  wire          argb4444_mode,   // latched at start, alongside dst_stride_qw
    input  wire [3:0]    rd_cov,          // registered, same 1-cyc-after-rd_qw/rd_en
                                           // contract as rd_qword; caller wires this to
                                           // bgplane_coverage's rd_nibble (same rd_qw/rd_en)
    output reg            busy,           // stays high until the LAST write is ACCEPTED
    // work-buffer read port (mux onto comp_fbram rd_* while busy, same as fbram_snapshot)
    output reg           rd_en,
    output reg [AW-1:0]  rd_qw,
    input  wire [63:0]   rd_qword,        // registered, valid 1 cyc after rd_qw/rd_en
    // SDRAM write port (wired to sdram_fb_cache ch0's write side by the caller);
    // sdram_wr_addr is RELATIVE -- caller adds the cell's plane base offset.
    // HELD (not pulsed) from the cycle it is presented until consumer_ready.
    output reg           sdram_wr_en,
    output reg [23:0]    sdram_wr_addr,
    output reg [63:0]    sdram_wr_data,
    // backpressure: pulse high the cycle the caller accepts the currently
    // presented write (sdram_wr_en=1). Don't-care while sdram_wr_en=0.
    input  wire          consumer_ready
);
    // RGB565 {r[4:0],g[5:0],b[4:0]} -> ARGB4444 {a[3:0],r[3:0],g[3:0],b[3:0]}, alpha
    // from the coverage nibble's corresponding lane bit (0xF covered / 0x0 not).
    // Truncates (not rounds) the low bits of each channel -- acceptable for a
    // static-tile plane bake, same precision loss any 565->444 conversion incurs.
    function automatic [15:0] pack_argb4444(input [15:0] rgb565, input cov_bit);
        reg [3:0] a4, r4, g4, b4;
        begin
            a4 = cov_bit ? 4'hF : 4'h0;
            r4 = rgb565[15:12];   // top 4 of the 5-bit R
            g4 = rgb565[10:7];    // top 4 of the 6-bit G
            b4 = rgb565[4:1];     // top 4 of the 5-bit B
            pack_argb4444 = {a4, r4, g4, b4};
        end
    endfunction

    function automatic [63:0] pack_qword_argb4444(input [63:0] qw, input [3:0] cov);
        begin
            pack_qword_argb4444 = {
                pack_argb4444(qw[63:48], cov[3]),
                pack_argb4444(qw[47:32], cov[2]),
                pack_argb4444(qw[31:16], cov[1]),
                pack_argb4444(qw[15: 0], cov[0])
            };
        end
    endfunction

    localparam [AW:0] NQW = FB_QWORDS[AW:0];
    localparam integer COLW = $clog2(CELL_ROW_QW);

    reg [AW:0] rptr;
    reg [AW:0] wcnt;
    reg        v1;        // SLOT B occupied: a read issued, not yet handed to SLOT A
    reg        v1_rdy;    // SLOT B's underlying comp_fbram read has completed
    reg [AW-1:0] a1;
    reg [23:0] stride_q;
    reg        argb_mode_q;   // latched at start alongside stride_q
    reg [COLW-1:0] col1;
    reg [23:0] row_base1;
    reg [23:0] cur_row_base;
    reg [COLW-1:0] cur_col;
    localparam [AW:0] ONE = {{(AW){1'b0}},1'b1};

    // SLOT A is empty this cycle (nothing presented -- either never was, or
    // was cleared by the mandatory post-accept gap below).
    wire slotA_empty = !sdram_wr_en;
    // SLOT A's currently-presented item retires this cycle (the one case that
    // actually completes a write -- `busy` gates on this, not merely on
    // production, so it doesn't drop until the LAST qword is truly accepted).
    wire retiring = sdram_wr_en && consumer_ready;
    // SLOT B has a ready item and SLOT A is ALREADY empty (not merely "being
    // vacated this cycle" -- see the gap note above: a retire never directly
    // hands off to SLOT B on the same cycle, so ok_hold gets a real
    // dst_wr=0 cycle to reset before the next request is asserted).
    wire move_b2a = slotA_empty && v1 && v1_rdy;
    // SLOT B will be empty (or emptied this very cycle) and so can accept a
    // freshly-issued read this same cycle.
    wire v1_will_be_free = !v1 || move_b2a;
    wire [AW:0] wcnt_next = wcnt + (retiring ? ONE : {(AW+1){1'b0}});

    always @(posedge clk) begin
        if (rst) begin
            busy<=1'b0; rd_en<=1'b0; sdram_wr_en<=1'b0;
            rptr<={(AW+1){1'b0}}; wcnt<={(AW+1){1'b0}}; v1<=1'b0; v1_rdy<=1'b0;
            cur_row_base<=24'd0; cur_col<={COLW{1'b0}};
        end else begin
            rd_en<=1'b0;
            if (!busy) begin
                v1<=1'b0; v1_rdy<=1'b0; sdram_wr_en<=1'b0;
                if (start) begin
                    busy<=1'b1; rptr<={(AW+1){1'b0}}; wcnt<={(AW+1){1'b0}};
                    stride_q<=dst_stride_qw;
                    argb_mode_q<=argb4444_mode;
                    cur_row_base<=24'd0; cur_col<={COLW{1'b0}};
                end
            end else begin
                // (1) retire bookkeeping: purely a function of SLOT A's own state.
                if (retiring) begin
                    wcnt <= wcnt_next;
                    if (wcnt_next == NQW) busy <= 1'b0;
                end

                // (2) SLOT A update. A retire ALWAYS clears sdram_wr_en (the
                // mandatory 1-cycle gap -- never hands off to SLOT B on the
                // same cycle as an accept, so ch0's ok_hold sees a real
                // dst_wr=0 cycle and resets before the next request asserts).
                // Only from an ALREADY-empty SLOT A do we hand off SLOT B (if
                // ready); if SLOT B isn't ready yet, SLOT A just stays idle
                // (a brief bubble -- only possible right after `start` or a
                // long dry spell, utterly dwarfed by ch0's real 30+ cycle
                // cold-miss accept latency).
                if (retiring) begin
                    sdram_wr_en <= 1'b0;
                end else if (move_b2a) begin
                    sdram_wr_en   <= 1'b1;
                    sdram_wr_addr <= row_base1 + {{(24-COLW){1'b0}}, col1};
                    sdram_wr_data <= argb_mode_q ? pack_qword_argb4444(rd_qword, rd_cov)
                                                  : rd_qword;   // v1_rdy guarantees both are valid for a1
                end
                // else: SLOT A either already empty with SLOT B not ready
                // (stays empty, no change needed), or presented-and-not-yet-
                // accepted (hold sdram_wr_en/addr/data exactly as they are).

                // (3) SLOT B readiness: an UNCONDITIONAL 1-cycle delay that
                // mirrors comp_fbram's own fixed read latency -- runs
                // regardless of SLOT A's state, since an already-issued read
                // completes on schedule whether or not SLOT A is stalled.
                if (v1 && !v1_rdy) v1_rdy <= 1'b1;

                // (4) issue a new read into SLOT B whenever it will be free
                // this cycle (already empty, or being drained to SLOT A right
                // now) and words remain; otherwise SLOT B holds untouched --
                // it can never be overwritten while occupied and un-drained,
                // so no qword can be skipped by a staged-but-uncaptured read.
                if (v1_will_be_free) begin
                    if (rptr < NQW) begin
                        rd_en<=1'b1; rd_qw<=rptr[AW-1:0];
                        v1<=1'b1; a1<=rptr[AW-1:0];
                        row_base1<=cur_row_base; col1<=cur_col;
                        if (cur_col == CELL_ROW_QW-1) begin
                            cur_col<={COLW{1'b0}};
                            cur_row_base<=cur_row_base+stride_q;
                        end else begin
                            cur_col<=cur_col+1'b1;
                        end
                        rptr<=rptr+ONE;
                    end else begin
                        v1<=1'b0;
                    end
                    v1_rdy <= 1'b0;   // new (or now-empty) SLOT B starts not-ready
                end
            end
        end
    end
endmodule
`default_nettype wire
