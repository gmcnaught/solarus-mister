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

    // SELF-CORRECT: a quiet counter for when the reader is genuinely idle (no
    // read/write issued, no beats arriving) while we're the reader's owner. The
    // per-scanline idle window is thousands of cycles; any mid-burst f2h stall is
    // a few. So a threshold safely in between means "reader has NO read in flight"
    // -> rd_out MUST be 0. Forcing it recovers from any beat-count drift (the real
    // f2h's DOUT_READY/BUSY timing can desync a pure beat counter, sticking rd_out
    // nonzero forever -> blitter starved). This makes the arbiter drift-proof.
    localparam [8:0] QUIET_MAX = 9'd200;
    reg  [8:0] quiet;
    always @(posedge clk) begin
        if (reset) quiet <= 9'd0;
        else if ((state != G_READER) | rdr_rd | rdr_we | ddram_dout_ready) quiet <= 9'd0;
        else if (quiet != QUIET_MAX) quiet <= quiet + 9'd1;
    end
    wire reader_idle = (quiet >= QUIET_MAX);

    // outstanding read beats for the currently-granted master
    reg  [9:0] rd_out;
    wire acc_rd = ~ddram_busy & ((state==G_READER & rdr_rd) | (state==G_BLT & b_rd));
    wire [7:0] acc_burst = (state==G_READER) ? rdr_burstcnt : 8'd1;
    always @(posedge clk) begin
        if (reset) rd_out <= 10'd0;
        // self-correct ONLY for reader drift (in G_READER). Gating on state is
        // essential: there is a 1-cycle lag between the grant FSM entering G_BLT
        // and `quiet` resetting, so reader_idle can still be high on the cycle the
        // blitter's borrowed READ is accepted. Without this gate that clobbers the
        // blitter's own outstanding-read count to 0 -> G_BLT_RD yields before the
        // beat returns -> blt_grant drops -> the read beat is routed to the reader
        // -> blitter's S_RD_WAIT hangs forever (HW-observed freeze).
        else if (reader_idle & (state == G_READER)) rd_out <= 10'd0;
        else case ({acc_rd, ddram_dout_ready})
            2'b10: rd_out <= rd_out + acc_burst;
            2'b01: rd_out <= (rd_out != 0) ? rd_out - 10'd1 : 10'd0;
            2'b11: rd_out <= rd_out + acc_burst - 10'd1;
            default: ;
        endcase
    end
    wire txn_busy = (rd_out != 10'd0);

    // grant FSM
    always @(posedge clk) begin
        if (reset) state <= G_READER;
        else case (state)
            G_READER:
                // lend a single gap to the blitter only when the reader is fully
                // idle (no cmd, no outstanding reads) and the bus is free
                if (~txn_busy & ~rdr_rd & ~rdr_we & ~ddram_busy & (b_rd | b_we))
                    state <= G_BLT;
            G_BLT:
                if (b_we & ~ddram_busy)      state <= G_READER;   // write accepted -> yield
                else if (b_rd & ~ddram_busy) state <= G_BLT_RD;   // read accepted -> await beat
                else if (~b_rd & ~b_we)      state <= G_READER;   // nothing to do
                // else: blitter command stalled by ddram_busy -> hold G_BLT
            G_BLT_RD:
                if (~txn_busy)               state <= G_READER;   // beat returned -> yield
            default: state <= G_READER;
        endcase
    end

    assign rdr_grant = (state == G_READER);
    assign blt_grant = (state == G_BLT_RD);            // route read beats to blitter
    assign rdr_busy  = ddram_busy | (state != G_READER);
    assign blt_busy  = ddram_busy | (state != G_BLT);  // blitter issues only in G_BLT

    // mux to DDRAM: reader in G_READER, blitter otherwise
    always @(*) begin
        if (state == G_READER) begin
            ddram_burstcnt = rdr_burstcnt; ddram_addr = rdr_addr; ddram_rd = rdr_rd;
            ddram_din = rdr_din; ddram_be = rdr_be; ddram_we = rdr_we;
        end else begin
            ddram_burstcnt = 8'd1; ddram_addr = blt_addr; ddram_rd = b_rd;
            ddram_din = blt_din; ddram_be = blt_be; ddram_we = b_we;
        end
    end
endmodule
`default_nettype wire
