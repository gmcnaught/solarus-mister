// comp_span_setup.sv — per-blit clip/flip → row-span decomposition
// Copyright (C) 2026 — GPL-3.0
//
// Ported clip arithmetic from blitter_top.sv lines 201-207, 234-235, 429-430.
// On `start`, computes clip bounds; if fully offscreen asserts `done` with
// zero spans.  Otherwise iterates rows clip_y0..clip_y1-1, emitting one
// span_valid per row, then asserts `done`.
//
// Interface (all signals are registered outputs, combinational inputs):
//   start          — one-cycle pulse; inputs sampled on the same posedge
//   c_dst_x/y      — signed destination origin (may be negative)
//   c_w/h          — sprite dimensions (unsigned, pixels)
//   c_flags        — F_HFLIP=8'h01, F_VFLIP=8'h02
//   span_valid     — one span per visible row
//   span_dst_x     — clipped destination X (0..319)
//   span_dst_y     — destination Y (0..239)
//   span_len       — pixel count for this row
//   span_src_x0    — flip-resolved source X at start of span
//   span_src_y     — flip-resolved source Y for this row
//   span_last      — asserted on the final row's span
//   done           — asserted the cycle after the last span (or immediately
//                    if fully offscreen); clears all output flags

`default_nettype none

module comp_span_setup (
    input  wire        clk,
    input  wire        rst,          // [#110] synchronous reset -> S_IDLE
    input  wire        start,
    input  wire signed [15:0] c_dst_x,
    input  wire signed [15:0] c_dst_y,
    input  wire        [15:0] c_w,
    input  wire        [15:0] c_h,
    input  wire        [7:0]  c_flags,

    output reg         span_valid,
    output reg  [15:0] span_dst_x,
    output reg  [15:0] span_dst_y,
    output reg  [15:0] span_len,
    output reg  [15:0] span_src_x0,
    output reg  [15:0] span_src_y,
    output reg         span_last,
    output reg         done
);

    // ---- constants (matching blitter_defs.vh) --------------------------------
    localparam signed [31:0] FB_W = 32'sd320;
    localparam signed [31:0] FB_H = 32'sd240;
    localparam [7:0] F_HFLIP = 8'h01;
    localparam [7:0] F_VFLIP = 8'h02;

    // ---- FSM states ----------------------------------------------------------
    localparam [1:0] S_IDLE  = 2'd0,
                     S_SETUP = 2'd1,
                     S_SPAN  = 2'd2,
                     S_DONE  = 2'd3;
    reg [1:0] state;

    // ---- registered copies of decoded command (latched on start) -------------
    reg signed [31:0] r_sdx, r_sdy;
    reg        [15:0] r_w,   r_h;
    reg        [7:0]  r_flags;

    // ---- clip bounds (combinational off registered inputs) -------------------
    wire signed [31:0] r_xe  = r_sdx + {16'd0, r_w};
    wire signed [31:0] r_ye  = r_sdy + {16'd0, r_h};
    wire signed [31:0] clip_x0 = (r_sdx < 32'sd0) ? 32'sd0 : r_sdx;
    wire signed [31:0] clip_y0 = (r_sdy < 32'sd0) ? 32'sd0 : r_sdy;
    wire signed [31:0] clip_x1 = (r_xe > FB_W)    ? FB_W   : r_xe;
    wire signed [31:0] clip_y1 = (r_ye > FB_H)    ? FB_H   : r_ye;
    wire               empty   = (clip_x0 >= clip_x1) || (clip_y0 >= clip_y1);

    // source-local start offsets (clip_x0 - dst_x), matching blitter_top:234-235
    wire signed [31:0] sx0 = clip_x0 - r_sdx;
    wire signed [31:0] sy0 = clip_y0 - r_sdy;

    // flip-aware source x start (no c_src_x — tile origin always 0)
    // mirrors blitter_top.sv:429
    wire [15:0] src_x0s = (r_flags & F_HFLIP) ? (r_w - 16'd1 - sx0[15:0])
                                               :  sx0[15:0];
    // flip-aware source y start for first row, mirrors blitter_top.sv:430
    wire [15:0] src_y0s = (r_flags & F_VFLIP) ? (r_h - 16'd1 - sy0[15:0])
                                               :  sy0[15:0];

    // ---- span row iteration state -------------------------------------------
    reg signed [31:0] dy;         // current dest Y being output
    reg signed [31:0] y1r;        // latched clip_y1
    reg        [15:0] src_y_r;    // current source Y (incremented per row)
    reg        [15:0] span_len_v; // clipped span length = clip_x1 - clip_x0

    // ---- power-on state (simulation) ----------------------------------------
    initial begin
        state      = S_IDLE;
        done       = 1'b0;
        span_valid = 1'b0;
        span_last  = 1'b0;
        r_flags    = 8'd0;
    end

    // ---- FSM -----------------------------------------------------------------
    // [#110] Without a reset this FSM could be mid-blit when a global rst re-inits the
    // rest of comp_pipeline, desyncing the span stream until the next start (self-heals,
    // but a real transient). Sync-reset to S_IDLE keeps it in lockstep with the pipeline.
    always @(posedge clk) begin
        if (rst) begin
            state      <= S_IDLE;
            done       <= 1'b0;
            span_valid <= 1'b0;
            span_last  <= 1'b0;
            r_flags    <= 8'd0;
        end else
        case (state)

            S_IDLE: begin
                done       <= 1'b0;
                span_valid <= 1'b0;
                span_last  <= 1'b0;
                if (start) begin
                    // latch inputs for clip computation
                    r_sdx   <= {{16{c_dst_x[15]}}, c_dst_x};
                    r_sdy   <= {{16{c_dst_y[15]}}, c_dst_y};
                    r_w     <= c_w;
                    r_h     <= c_h;
                    r_flags <= c_flags;
                    state   <= S_SETUP;
                end
            end

            S_SETUP: begin
                span_valid <= 1'b0;
                span_last  <= 1'b0;
                done       <= 1'b0;
                if (empty) begin
                    state <= S_DONE;
                end else begin
                    // latch clip bounds and span constants
                    dy          <= clip_y0;
                    y1r         <= clip_y1;
                    span_len_v  <= clip_x1[15:0] - clip_x0[15:0];
                    // latch flip-resolved span_src_x0 (constant across all rows)
                    span_src_x0 <= src_x0s;
                    span_dst_x  <= clip_x0[15:0];
                    // initialise per-row source Y
                    src_y_r     <= src_y0s;
                    state       <= S_SPAN;
                end
            end

            S_SPAN: begin
                // emit one span for row `dy`; span_dst_x and span_src_x0 are
                // constant across all rows (latched in S_SETUP) and held implicitly
                span_valid <= 1'b1;
                span_dst_y <= dy[15:0];
                span_len   <= span_len_v;
                span_src_y <= src_y_r;
                span_last  <= (dy == y1r - 32'sd1);

                if (dy == y1r - 32'sd1) begin
                    // last row — next cycle → done
                    state <= S_DONE;
                end else begin
                    // advance to next row
                    dy      <= dy + 32'sd1;
                    src_y_r <= (r_flags & F_VFLIP) ? (src_y_r - 16'd1)
                                                   : (src_y_r + 16'd1);
                end
            end

            S_DONE: begin
                span_valid <= 1'b0;
                span_last  <= 1'b0;
                done       <= 1'b1;
                state      <= S_IDLE;
            end

        endcase
    end

endmodule
