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

    // LEND GUARD (replaces the fragile outstanding-beat counter). Count cycles the
    // reader has been genuinely quiescent (no rd/we issued, no read beat arriving)
    // while we own the bus for it. `quiet` resets on EVERY dout_ready, so it only
    // climbs AFTER the reader's last burst beat has returned. Once it reaches GUARD,
    // the bus is provably drained -> safe to lend ONE transaction to the blitter.
    //
    // This needs NO outstanding-read counter and therefore CANNOT drift: earlier
    // designs inferred "reader has no read in flight" from a +burst/-beat counter,
    // which the real f2h's BUSY/DOUT_READY timing desynced, intermittently making
    // the blitter borrow while a reader beat was still in flight (or clobbering the
    // blitter's own beat) -> the blitter's read beat got mis-routed -> S_RD_WAIT
    // hung (HW-observed: status stuck at the prologue 0xCAFE0000, intermittently).
    // GUARD=8 is ample: f2h first-beat latency is well under 8 cycles and `quiet`
    // counts from the LAST beat, so 8 idle cycles guarantee a quiescent bus.
    localparam [4:0] GUARD = 5'd8;
    reg  [4:0] quiet;
    always @(posedge clk) begin
        if (reset) quiet <= 5'd0;
        else if ((state != G_READER) | rdr_rd | rdr_we | ddram_dout_ready) quiet <= 5'd0;
        else if (quiet != GUARD) quiet <= quiet + 5'd1;
    end
    wire guard_ok = (quiet >= GUARD);

    // grant FSM: reader is the DEFAULT owner; the blitter borrows ONE transaction in
    // a proven-quiescent gap, then yields. A single blitter read beat is captured by
    // yielding on its dout_ready (blt_grant is high that cycle) — no beat counter.
    always @(posedge clk) begin
        if (reset) state <= G_READER;
        else case (state)
            G_READER:
                if (guard_ok & ~rdr_rd & ~rdr_we & ~ddram_busy & (b_rd | b_we))
                    state <= G_BLT;
            G_BLT:
                if (b_we & ~ddram_busy)      state <= G_READER;   // write accepted -> yield
                else if (b_rd & ~ddram_busy) state <= G_BLT_RD;   // read accepted -> await beat
                else if (~b_rd & ~b_we)      state <= G_READER;   // nothing to do
                // else: blitter command stalled by ddram_busy -> hold G_BLT
            G_BLT_RD:
                if (ddram_dout_ready)        state <= G_READER;   // single beat captured -> yield
            default: state <= G_READER;
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
