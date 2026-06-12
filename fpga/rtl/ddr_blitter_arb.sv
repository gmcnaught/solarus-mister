//============================================================================
//  ddr_blitter_arb.sv — shared-f2h arbiter + standalone frame producer
//
//  fpga-hw-blitter #003, iteration 2: prove a SEPARATE fabric master can share
//  the single f2h DDR port with the (unmodified) video reader via a priority
//  arbiter, and act as a drop-in producer.
//
//  - Reader (m0) keeps priority and is unaware of sharing: it is fed
//    rdr_busy = ddram_busy | ~grant, and its dout_ready is gated by rdr_grant
//    in the top level. A locking arbiter never switches masters while the
//    reader has outstanding read beats (tracked) or a stalled command.
//  - Producer (m1) writes a full test frame (blue field + green rectangle) into
//    BUF0 and then the video control word, looping — so with NO ARM engine the
//    reader scans a fully fabric-produced frame.
//
//  This is the structural model the real blitter uses (master + arbiter +
//  control-word producer); only the pixel source is a hardcoded test pattern.
//  Set ENABLE=0 to make m1 idle (reader owns the bus, normal core).
//
//  Copyright (C) 2026 — GPL-3.0
//============================================================================
`default_nettype none

module ddr_blitter_arb #(
    parameter ENABLE = 1'b1
) (
    input  wire        clk,
    input  wire        reset,

    // reader master (m0) — driven by openbor_video_reader
    input  wire [7:0]  rdr_burstcnt,
    input  wire [28:0] rdr_addr,
    input  wire        rdr_rd,
    input  wire [63:0] rdr_din,
    input  wire [7:0]  rdr_be,
    input  wire        rdr_we,
    output wire        rdr_busy,     // gated busy back to the reader
    output wire        rdr_grant,    // AND with ddram_dout_ready for reader

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
    // -- DDR addresses (qword; match openbor_video_reader) ----------------
    localparam [28:0] CTRL_ADDR   = 29'h07400000;  // 0x3A000000>>3
    localparam [28:0] BUF0_ADDR   = 29'h07400008;  // 0x3A000040>>3
    localparam [8:0]  V_ACTIVE    = 9'd240;
    localparam [6:0]  H_QW        = 7'd80;          // 80 qwords / line
    // green rectangle: cols [32..47] qw (px 128..191), lines [100..131]
    localparam [6:0]  RECT_X0     = 7'd32, RECT_X1 = 7'd47;
    localparam [8:0]  RECT_Y0     = 9'd100, RECT_Y1 = 9'd131;
    localparam [15:0] GREEN = 16'h07E0, BLUE = 16'h001F;

    // -- Producer (m1) FSM -------------------------------------------------
    localparam P_FRAME = 1'b0, P_CTRL = 1'b1;
    reg         pstate;
    reg [28:0]  p_addr;     // running qword address into BUF0
    reg [8:0]   p_line;
    reg [6:0]   p_col;
    reg [29:0]  p_fctr;     // frame counter

    wire in_rect = (p_line >= RECT_Y0) && (p_line <= RECT_Y1)
                && (p_col  >= RECT_X0) && (p_col  <= RECT_X1);

    wire        m1_we  = ENABLE;          // continuously producing when enabled
    wire        m1_rd  = 1'b0;
    wire [7:0]  m1_burstcnt = 8'd1;
    wire [7:0]  m1_be   = 8'hFF;
    wire [28:0] m1_addr = (pstate == P_CTRL) ? CTRL_ADDR : p_addr;
    wire [63:0] m1_din  = (pstate == P_CTRL)
                          ? {32'd0, (p_fctr + 30'd1), 2'b00}     // (fctr+1)<<2 | buf0
                          : (in_rect ? {4{GREEN}} : {4{BLUE}});

    // -- Arbiter -----------------------------------------------------------
    reg        gnt;        // 0 = reader, 1 = producer
    reg [9:0]  rd_out;     // outstanding reader read beats

    wire accepted_rd = (gnt == 1'b0) && rdr_rd && !ddram_busy;  // reader reads only
    always @(posedge clk) begin
        if (reset) rd_out <= 10'd0;
        else case ({accepted_rd, ddram_dout_ready})
            2'b10: rd_out <= rd_out + rdr_burstcnt;
            2'b01: rd_out <= (rd_out != 0) ? rd_out - 10'd1 : 10'd0;
            2'b11: rd_out <= rd_out + rdr_burstcnt - 10'd1;
            default: ;
        endcase
    end
    wire txn_busy = (rd_out != 10'd0);

    // The READER is the DEFAULT bus owner (gnt=0). It gates its own requests on
    // its busy input (`if(!ddr_busy) assert rd`), so it can only ask for the bus
    // when it already sees it free — meaning we must NOT make it ask first. The
    // producer is a background filler: it BORROWS the bus for a single
    // transaction only in a genuine idle gap, then immediately yields to the
    // reader. This breaks the chicken-and-egg deadlock that black-screened the
    // earlier builds (reader stalled by grant -> can't assert rd -> never granted).
    wire rdr_active = rdr_rd | rdr_we | txn_busy;
    wire prod_wants = m1_we | m1_rd;
    wire m1_busy    = ddram_busy | (gnt != 1'b1);
    wire m1_accept  = m1_we & ~m1_busy;

    always @(posedge clk) begin
        if (reset) gnt <= 1'b0;                    // reader owns the bus by default
        else if (gnt) begin
            if (m1_accept | ~prod_wants) gnt <= 1'b0;            // yield after 1 txn
        end else begin
            if (~rdr_active & prod_wants & ~ddram_busy) gnt <= 1'b1;  // lend a gap
        end
    end

    assign rdr_grant = (gnt == 1'b0);
    assign rdr_busy  = ddram_busy | (gnt != 1'b0);

    // -- Mux to DDRAM ------------------------------------------------------
    always @(*) begin
        if (gnt == 1'b0) begin
            ddram_burstcnt = rdr_burstcnt; ddram_addr = rdr_addr; ddram_rd = rdr_rd;
            ddram_din = rdr_din; ddram_be = rdr_be; ddram_we = rdr_we;
        end else begin
            ddram_burstcnt = m1_burstcnt; ddram_addr = m1_addr; ddram_rd = m1_rd;
            ddram_din = m1_din; ddram_be = m1_be; ddram_we = m1_we;
        end
    end

    // -- Producer sequencing ----------------------------------------------
    always @(posedge clk) begin
        if (reset) begin
            pstate <= P_FRAME; p_addr <= BUF0_ADDR; p_line <= 9'd0;
            p_col <= 7'd0; p_fctr <= 30'd0;
        end else if (ENABLE) begin
            case (pstate)
                P_FRAME: if (m1_accept) begin
                    p_addr <= p_addr + 29'd1;
                    if (p_col == H_QW - 7'd1) begin
                        p_col <= 7'd0;
                        if (p_line == V_ACTIVE - 9'd1) pstate <= P_CTRL;
                        else p_line <= p_line + 9'd1;
                    end else p_col <= p_col + 7'd1;
                end
                P_CTRL: if (m1_accept) begin
                    p_fctr <= p_fctr + 30'd1;
                    p_addr <= BUF0_ADDR; p_line <= 9'd0; p_col <= 7'd0;
                    pstate <= P_FRAME;
                end
            endcase
        end
    end
endmodule
`default_nettype wire
