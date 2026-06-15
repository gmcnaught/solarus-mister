//============================================================================
//  ddr_blitter_arb.sv — 2-master f2h DDR arbiter (reader + blitter)
//
//  fpga-hw-blitter #003 iteration 5. Shares the single f2h DDR port between the
//  UNMODIFIED video reader (m0) and the hardware blitter (m1, blitter_top).
//
//  Design (validated across iterations 2-4 on HW): the READER is the DEFAULT bus
//  owner (it gates its own requests on !ddr_busy, so it can only ask when it sees
//  the bus free — it must never have to ask first). The blitter BORROWS the bus
//  for a single transaction only in a genuine reader-idle gap, then yields. Read
//  latency is honored for both masters: the grant is held until a read burst's
//  beats have all returned, and dout_ready is routed to the master that issued.
//
//  Set ENABLE=0 to make the blitter port inert (reader owns the bus = normal core).
//
//  Copyright (C) 2026 — GPL-3.0
//============================================================================
`default_nettype none

module ddr_blitter_arb #(
    parameter ENABLE = 1'b1
) (
    input  wire        clk,
    input  wire        reset,

    // reader master (m0) — openbor_video_reader
    input  wire [7:0]  rdr_burstcnt,
    input  wire [28:0] rdr_addr,
    input  wire        rdr_rd,
    input  wire [63:0] rdr_din,
    input  wire [7:0]  rdr_be,
    input  wire        rdr_we,
    output wire        rdr_busy,
    output wire        rdr_grant,        // AND with ddram_dout_ready for reader

    // blitter master (m1) — blitter_top (single-beat accesses)
    input  wire [28:0] blt_addr,
    input  wire        blt_rd,
    input  wire [63:0] blt_din,
    input  wire [7:0]  blt_be,
    input  wire        blt_we,
    output wire        blt_busy,
    output wire        blt_grant,        // AND with ddram_dout_ready for blitter

    // shared DDRAM (f2h) port
    input  wire        ddram_busy,
    input  wire        ddram_dout_ready,
    output reg  [7:0]  ddram_burstcnt,
    output reg  [28:0] ddram_addr,
    output reg         ddram_rd,
    output reg  [63:0] ddram_din,
    output reg  [7:0]  ddram_be,
    output reg         ddram_we
);
    // gate the blitter off entirely when disabled
    wire b_rd = ENABLE & blt_rd;
    wire b_we = ENABLE & blt_we;

    localparam [1:0] G_READER = 2'd0, G_BLT = 2'd1, G_BLT_RD = 2'd2;
    reg [1:0] state;

    // OUTSTANDING READER BEATS. The reader issues f2h BURST reads; ALL their beats
    // must return to it uninterrupted. The f2h's command->first-beat latency is
    // MANY cycles, so a "cycles since the last beat" guard alone wrongly thinks the
    // bus is idle DURING that latency and lends it away mid-fetch -> the reader
    // loses its scanline beats -> BLACK SCREEN (HW-confirmed: bypassing this arbiter
    // restores the picture). So: track the reader's outstanding beats and NEVER lend
    // while rd_out != 0 (a burst is in flight, even before its first beat arrives).
    //
    // The earlier blitter freeze that motivated removing this counter was actually a
    // TIMING-CLOSURE failure (the per-pixel blend path), since fixed — not counter
    // drift. A self-correct still guards against any f2h handshake desync: if the
    // reader stays quiescent FAR longer than any burst could take, force rd_out=0.
    reg  [9:0] rd_out;
    wire rdr_acc  = (state == G_READER) & rdr_rd & ~ddram_busy;   // reader read taken
    wire rdr_beat = (state == G_READER) & ddram_dout_ready;       // a reader beat back
    localparam [9:0] QUIET_MAX = 10'd400;   // >> worst-case burst drain (80 beats)
    reg  [9:0] quiet;
    always @(posedge clk) begin
        if (reset) quiet <= 10'd0;
        else if ((state != G_READER) | rdr_rd | rdr_we | ddram_dout_ready) quiet <= 10'd0;
        else if (quiet != QUIET_MAX) quiet <= quiet + 10'd1;
    end
    wire drift_clr = (quiet >= QUIET_MAX) & (state == G_READER);
    always @(posedge clk) begin
        if (reset)          rd_out <= 10'd0;
        else if (drift_clr) rd_out <= 10'd0;       // self-correct (true idle only)
        else case ({rdr_acc, rdr_beat})
            2'b10: rd_out <= rd_out + {2'd0, rdr_burstcnt};
            2'b01: rd_out <= (rd_out != 10'd0) ? rd_out - 10'd1 : 10'd0;
            2'b11: rd_out <= rd_out + {2'd0, rdr_burstcnt} - 10'd1;
            default: ;
        endcase
    end
    wire rdr_idle = (rd_out == 10'd0);   // reader has NO burst in flight -> safe to lend

    // SCANOUT-STRICT priority (issue #19). The scanout reader (rdr_*) is a HARD
    // real-time master: it must get the bus within a small bounded gap or its FIFO
    // underflows -> BLACK screen. The blitter (blt_*, incl. DDR3->SDRAM staging
    // reads) is best-effort and, under SOLARUS_SDRAM_SRC=1, asks for the bus almost
    // CONTINUOUSLY. The original FSM lent the bus the instant the reader had a gap,
    // then committed to the blitter's single-beat read; the moment that beat returned
    // it went back to G_READER and IMMEDIATELY re-lent to the still-asking blitter —
    // before the busy-gated scanout (it asserts rdr_rd only when it sees !rdr_busy)
    // could claim the freed cycle. The scanout lost the race every time, so its grant
    // latency tracked the (repeated) blitter read window -> deadline blown.
    //
    // Fix: after EVERY blitter loan the arbiter inserts a one-cycle SCANOUT WINDOW in
    // G_READER during which it will NOT re-lend. With state==G_READER the bus shows
    // free (rdr_busy low), so the scanout asserts rdr_rd in that window; the lend
    // guard then sees rdr_rd and holds the bus for the scanout. Only if the scanout
    // does NOT take the window does the blitter get re-lent. This bounds the scanout's
    // worst case to ONE in-flight blitter single-beat read (which cannot be aborted
    // without desyncing the f2h beat — the original hazard) plus that one window.
    //
    // No-deadlock / no-livelock: the scanout always gets the window (and it can never
    // be lent-around indefinitely); the blitter still makes forward progress because
    // whenever the scanout is not requesting, the window expires and the blitter is
    // lent the gap. Blitter WRITES (blt_we) take the same single-cycle loan and yield.
    reg yielded;   // high for the one G_READER cycle right after a blitter loan
    always @(posedge clk) begin
        if (reset) begin state <= G_READER; yielded <= 1'b0; end
        else case (state)
            G_READER: begin
                yielded <= 1'b0;                       // window (if any) consumed this cycle
                // lend ONLY when the reader has no burst in flight (rdr_idle), isn't
                // requesting, AND we're not in the post-loan scanout window — so the
                // busy-gated scanout always gets first claim on a freed bus.
                if (rdr_idle & ~rdr_rd & ~rdr_we & ~ddram_busy & ~yielded & (b_rd | b_we))
                    state <= G_BLT;
            end
            G_BLT:
                if (b_we & ~ddram_busy)      begin state <= G_READER; yielded <= 1'b1; end // write accepted -> yield + window
                else if (b_rd & ~ddram_busy) state <= G_BLT_RD;   // read accepted -> await beat
                else if (~b_rd & ~b_we)      begin state <= G_READER; yielded <= 1'b1; end // nothing to do -> yield + window
                // else: blitter command stalled by ddram_busy -> hold G_BLT
            G_BLT_RD:
                if (ddram_dout_ready)        begin state <= G_READER; yielded <= 1'b1; end // single beat captured -> yield + window
            default: begin state <= G_READER; yielded <= 1'b0; end
        endcase
    end

    assign rdr_grant = (state == G_READER);
    assign blt_grant = (state == G_BLT_RD);            // route the read beat to blitter
    assign rdr_busy  = ddram_busy | (state != G_READER);
    assign blt_busy  = ddram_busy | (state != G_BLT);  // blitter issues only in G_BLT

    // mux to DDRAM. CRITICAL: assert ddram_rd/we ONLY in G_BLT. The blitter holds
    // mem_rd asserted into G_BLT_RD while it waits for its beat; if we forwarded that
    // the f2h could latch a SECOND read during the latency window -> beat desync.
    always @(*) begin
        if (state == G_READER) begin
            ddram_burstcnt = rdr_burstcnt; ddram_addr = rdr_addr; ddram_rd = rdr_rd;
            ddram_din = rdr_din; ddram_be = rdr_be; ddram_we = rdr_we;
        end else begin
            ddram_burstcnt = 8'd1; ddram_addr = blt_addr;
            ddram_rd = (state == G_BLT) ? b_rd : 1'b0;   // issue only in G_BLT
            ddram_we = (state == G_BLT) ? b_we : 1'b0;
            ddram_din = blt_din; ddram_be = blt_be;
        end
    end
endmodule
`default_nettype wire
