//============================================================================
//  ddr_blitter_arb.sv — 2-master f2h DDR arbiter (reader + blitter)
//
//  fpga-hw-blitter #003 iteration 6. Shares the single f2h DDR port between the
//  UNMODIFIED video reader (m0) and the hardware blitter (m1, blitter_top).
//
//  Design (validated across iterations 2-5 on HW): the READER is the DEFAULT bus
//  owner (it gates its own requests on !ddr_busy, so it can only ask when it sees
//  the bus free — it must never have to ask first). The blitter BORROWS the bus
//  for a burst of up to MAXBURST beats only in a genuine reader-idle gap, then
//  yields. Read latency is honored for both masters: the grant is held until a
//  read burst's beats have all returned, and dout_ready is routed to the master
//  that issued.
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

    // blitter master (m1) — blitter_top
    input  wire [7:0]  blt_burstcnt,     // beats in the current blitter burst (>=1)
    input  wire [28:0] blt_addr,
    input  wire        blt_rd,
    input  wire [63:0] blt_din,
    input  wire [7:0]  blt_be,
    input  wire        blt_we,
    output wire        blt_busy,
    output wire        blt_grant,        // AND with ddram_dout_ready for blitter

    // scanout master (m2) — ddr3_scan_adapter [Stage 5 Phase 2 Task 8].
    // Read-only DDR3 master serving the scanline line-burst. Given PRIORITY ABOVE
    // the blitter in a reader-idle gap so a scanout fetch never underruns (the
    // reader still owns the bus by default; scan only borrows quiescent gaps, but
    // ahead of the blitter). Symmetric to the blitter read-borrow path, minus the
    // write states — the adapter holds scn_rd until accepted and needs all beats
    // of its burst to return uninterrupted (grant held for the whole burst).
    input  wire [7:0]  scn_burstcnt,     // beats in the current scanout burst (LINE_QW)
    input  wire [28:0] scn_addr,
    input  wire        scn_rd,
    output wire        scn_busy,
    output wire        scn_grant,        // AND with ddram_dout_ready for scanout

    // shared DDRAM (f2h) port
    input  wire        ddram_busy,
    input  wire        ddram_dout_ready,
    output reg  [7:0]  ddram_burstcnt,
    output reg  [28:0] ddram_addr,
    output reg         ddram_rd,
    output reg  [63:0] ddram_din,
    output reg  [7:0]  ddram_be,
    output reg         ddram_we,
    // DEBUG (#34): {rd_out_nz, state[1:0]} — is a reader f2h burst in flight (so the
    // blitter can't borrow = starvation) and the grant-FSM state. HW wedge probe.
    output wire  [2:0] dbg
);
    // gate the blitter off entirely when disabled
    wire b_rd = ENABLE & blt_rd;
    wire b_we = ENABLE & blt_we;
    // scanout is essential (never gated by ENABLE); read-only master.
    wire s_rd = scn_rd;

    localparam [2:0] G_READER=3'd0, G_BLT=3'd1, G_BLT_RD=3'd2, G_BLT_WR=3'd3,
                     G_SCN=3'd4, G_SCN_RD=3'd5;
    reg [2:0] state;

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

    // blitter burst beat counters: how many beats the current blitter burst still
    // owes (reads: dout_ready beats; writes: !ddram_busy accepts). The grant is held
    // until this reaches zero. blt_burstcnt is bounded by MAXBURST at the master, so
    // the reader waits at most MAXBURST beats -> never starves.
    reg [7:0] blt_out;

    // blitter beat bookkeeping (reads counted by dout_ready; writes by !busy accept)
    always @(posedge clk) begin
        if (reset) blt_out <= 8'd0;
        else case (state)
            G_BLT:    if (b_rd & ~ddram_busy)      blt_out <= blt_burstcnt; // arm read beats
                      else if (b_we & ~ddram_busy) blt_out <= blt_burstcnt - 8'd1; // 1st write beat taken
            G_BLT_RD: if (ddram_dout_ready & (blt_out!=8'd0)) blt_out <= blt_out - 8'd1;
            G_BLT_WR: if (b_we & ~ddram_busy & (blt_out!=8'd0)) blt_out <= blt_out - 8'd1;
            default: ;
        endcase
    end

    // scanout burst beat counter — read-only, mirrors blt_out for G_SCN_RD. The
    // grant is held until every beat of the LINE_QW burst has returned.
    reg [7:0] scn_out;
    always @(posedge clk) begin
        if (reset) scn_out <= 8'd0;
        else case (state)
            G_SCN:    if (s_rd & ~ddram_busy)                 scn_out <= scn_burstcnt; // arm read beats
            G_SCN_RD: if (ddram_dout_ready & (scn_out!=8'd0)) scn_out <= scn_out - 8'd1;
            default: ;
        endcase
    end

    // grant FSM: reader is the DEFAULT owner; scanout and the blitter each borrow a
    // burst in a proven-quiescent gap, then yield. Scanout is checked FIRST so it
    // takes priority above the blitter (it must never underrun). Hold the grant for
    // the full burst.
    always @(posedge clk) begin
        if (reset) state <= G_READER;
        else case (state)
            G_READER:
                // lend ONLY when the reader has no burst in flight (rdr_idle) and
                // isn't requesting — so its scanline fetches are never interrupted.
                // Scanout has priority over the blitter.
                if (rdr_idle & ~rdr_rd & ~rdr_we & ~ddram_busy) begin
                    if      (s_rd)          state <= G_SCN;   // scanout first
                    else if (b_rd | b_we)   state <= G_BLT;   // then blitter
                end
            G_SCN:
                if      (s_rd & ~ddram_busy)               state <= G_SCN_RD;  // await read beats
                else if (~s_rd)                            state <= G_READER;  // request withdrawn
                // else: scan command stalled by ddram_busy -> hold G_SCN
            G_SCN_RD:
                if (ddram_dout_ready & (scn_out==8'd1))     state <= G_READER;  // last beat captured
            G_BLT:
                if      (b_rd & ~ddram_busy)               state <= G_BLT_RD;  // await read beats
                else if (b_we & ~ddram_busy)
                    state <= (blt_burstcnt==8'd1) ? G_READER : G_BLT_WR;       // 1-beat write done now
                else if (~b_rd & ~b_we)                    state <= G_READER;
                // else: blitter command stalled by ddram_busy -> hold G_BLT
            G_BLT_RD:
                if (ddram_dout_ready & (blt_out==8'd1))     state <= G_READER;  // last beat captured
            G_BLT_WR:
                if (b_we & ~ddram_busy & (blt_out==8'd1))   state <= G_READER;  // last write accepted
            default: state <= G_READER;
        endcase
    end

    assign dbg       = {~rdr_idle, state[1:0]};        // #34 probe: rd_out!=0 + grant state
    assign rdr_grant = (state == G_READER);
    assign blt_grant = (state == G_BLT_RD);               // route read beats to blitter
    assign scn_grant = (state == G_SCN_RD);               // route read beats to scanout
    assign rdr_busy  = ddram_busy | (state != G_READER);
    assign blt_busy  = ddram_busy | ((state != G_BLT) & (state != G_BLT_WR));
    assign scn_busy  = ddram_busy | (state != G_SCN);     // command accepted only in G_SCN

    // mux to DDRAM. CRITICAL: assert ddram_rd ONLY in the command state (G_BLT /
    // G_SCN). The borrowing master holds its rd asserted into the *_RD state while
    // it waits for beats; forwarding that would let the f2h latch a SECOND read
    // during the latency window -> beat desync. ddram_we is asserted in G_BLT and
    // G_BLT_WR for multi-beat write streaming (scanout is read-only).
    always @(*) begin
        case (state)
            G_SCN, G_SCN_RD: begin
                ddram_burstcnt = scn_burstcnt; ddram_addr = scn_addr;
                ddram_rd = (state == G_SCN) ? s_rd : 1'b0; // read command only in G_SCN
                ddram_we = 1'b0;                           // scanout never writes
                ddram_din = 64'd0; ddram_be = 8'hFF;
            end
            G_BLT, G_BLT_RD, G_BLT_WR: begin
                ddram_burstcnt = blt_burstcnt; ddram_addr = blt_addr;
                ddram_rd = (state == G_BLT) ? b_rd : 1'b0; // read command only in G_BLT
                ddram_we = ((state == G_BLT) | (state == G_BLT_WR)) ? b_we : 1'b0;
                ddram_din = blt_din; ddram_be = blt_be;
            end
            default: begin // G_READER
                ddram_burstcnt = rdr_burstcnt; ddram_addr = rdr_addr; ddram_rd = rdr_rd;
                ddram_din = rdr_din; ddram_be = rdr_be; ddram_we = rdr_we;
            end
        endcase
    end
endmodule
`default_nettype wire
