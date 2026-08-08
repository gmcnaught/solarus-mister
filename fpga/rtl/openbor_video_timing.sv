//============================================================================
//
//  OpenBOR Native Video Timing Generator
//
//  416x240 active area @ 59.92 Hz (570x262 total)
//  NTSC-derived MCLK from the colorburst crystal, Genesis H/V RATES preserved exactly.
//  CLK_VIDEO: 53.693 MHz (exact Genesis MCLK), uniform CE_PIXEL = /6 for H_TOTAL=570.
//
//  H: 416 active + 154 blanking = 570 total (3420 MCLK / 6, exact)
//  V: 240 active +   2 FP + 3 sync + 17 BP = 262 total (exact Genesis NTSC)
//
//  Refresh: 15,700 / 262 = 59.92 Hz (exact Genesis)
//  H freq:  53,693,182 / 3420 = 15,700 Hz (exact Genesis)
//  H active time: 416 × 6 / 53.693MHz = 46.48 µs
//
//  Was 320x240 in 420x262 with the Genesis H40 mixed /8,/9,/10 pixel schedule. The
//  MCLK-per-line budget (3420) and therefore both rates are UNCHANGED; widening to
//  416 only re-divided the line, and 3420/6 divides evenly where 3420/8 did not.
//
//  Adapted from MiSTer_PICO-8 by MiSTer Organize
//  Copyright (C) 2026 MiSTer Organize -- GPL-3.0
//
//============================================================================

`include "fb_geom.vh"

module openbor_video_timing (
    input  wire        clk,        // CLK_VIDEO (53.693 MHz)
    input  wire        ce_pix,     // pixel enable (variable rate — exact Genesis H40)
    input  wire        reset,

    // CRT position offset (signed: -3 to +3, from OSD)
    input  wire signed [4:0] h_adj,  // horizontal: positive = shift right
    input  wire signed [3:0] v_adj,  // vertical: positive = shift down

    output reg         hsync,      // active low
    output reg         vsync,      // active low
    output reg         hblank,
    output reg         vblank,
    output reg         de,         // data enable = ~(hblank | vblank)
    output reg  [9:0]  hcount,
    output reg  [8:0]  vcount,
    output reg         new_frame,  // pulse at vblank start
    output reg         new_line    // pulse at hblank start
);

// -- Timing constants --------------------------------------------------
// 320x240 active, centered for 15kHz CRT, NTSC-compatible H rate.
// CRT-compatible blanking with balanced porches.
// Active area comes from fb_geom.vh — the raster and the compositor framebuffer are
// the same picture and must not be able to disagree. The porches stay literal: they
// are analog-signal tuning, derived from the MCLK-per-line budget, not from FB_W.
// Porches for the 416-wide raster, at ce_pix = CLK_VIDEO/6 (see Solarus.sv). The line
// budget is still exactly 3420 MCLK, so H stays 15,700 Hz and V stays 59.92 Hz; only
// the split of that line into pixels changed. 3420/6 = 570 pixels, exactly.
//   H sync  51 px = 5.70 us  (was 38 px @/8 = 5.66 us — deliberately held, this is the
//                             width already proven on the operator's displays)
//   H FP    26 px = 2.91 us  (was 17 px @/8 = 2.53 us)
//   H BP    77 px = 8.60 us  (was 45 px @/8 = 6.71 us — absorbs the slack, since 416
//                             narrower pixels use less line time than 320 wider ones)
//   active 416 px = 46.48 us (was 47.68 us)
localparam H_ACTIVE = `FB_W;
localparam H_FP     = 26;
localparam H_SYNC   = 51;
localparam H_BP     = 77;
localparam H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;   // 570 @416 (3420 MCLK / 6)

localparam V_ACTIVE = `FB_H;
localparam V_FP     = 2;
localparam V_SYNC   = 3;
localparam V_BP     = 17;
localparam V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;   // 262 (exact Genesis NTSC)

// Derived boundaries — adjusted by OSD H/V position offset.
wire [9:0] h_sync_start = H_ACTIVE + H_FP + {{5{h_adj[4]}}, h_adj};
wire [9:0] h_sync_end   = h_sync_start + H_SYNC;
// [#107] Clamp v_sync_start to >= V_ACTIVE so vsync can never assert INSIDE active video
// (lines 0..V_ACTIVE-1). The raw value V_ACTIVE+V_FP+v_adj = 242+v_adj drops to 239 at the
// maximum OSD shift-up (v_adj=-3), one line inside active -> bottom-row roll/clip on strict
// 15 kHz displays (vblank is not asserted until line V_ACTIVE). Floor at V_ACTIVE.
wire [8:0] v_sync_start_raw = V_ACTIVE + V_FP + {{5{v_adj[3]}}, v_adj};
wire [8:0] v_sync_start = (v_sync_start_raw < V_ACTIVE[8:0]) ? V_ACTIVE[8:0] : v_sync_start_raw;
wire [8:0] v_sync_end   = v_sync_start + V_SYNC;

// Next-cycle blanking state, computed combinationally so `de` leads the registered
// hblank/vblank by one pixel. Kept in a dedicated `always @(*)` (NOT the clocked
// block below) so the intra-block temporaries stay blocking `=` without tripping the
// blocking-in-sequential HDL lint gate.
reg next_hblank, next_vblank;
always @(*) begin
    if (hcount == H_ACTIVE - 1)
        next_hblank = 1'b1;
    else if (hcount == H_TOTAL - 1)
        next_hblank = 1'b0;
    else
        next_hblank = hblank;

    if (hcount == H_TOTAL - 1) begin
        if (vcount == V_ACTIVE - 1)
            next_vblank = 1'b1;
        else if (vcount == V_TOTAL - 1)
            next_vblank = 1'b0;
        else
            next_vblank = vblank;
    end
    else
        next_vblank = vblank;
end

always @(posedge clk) begin
    if (reset) begin
        hcount    <= 10'd0;
        vcount    <= 9'd0;
        hsync     <= 1'b1;
        vsync     <= 1'b1;
        hblank    <= 1'b0;
        vblank    <= 1'b0;
        de        <= 1'b1;
        new_frame <= 1'b0;
        new_line  <= 1'b0;
    end
    else if (ce_pix) begin
        new_frame <= 1'b0;
        new_line  <= 1'b0;

        // Horizontal counter
        if (hcount == H_TOTAL - 1) begin
            hcount <= 10'd0;
            if (vcount == V_TOTAL - 1)
                vcount <= 9'd0;
            else
                vcount <= vcount + 9'd1;
        end
        else begin
            hcount <= hcount + 10'd1;
        end

        // Horizontal blanking
        if (hcount == H_ACTIVE - 1)
            hblank <= 1'b1;
        else if (hcount == H_TOTAL - 1)
            hblank <= 1'b0;

        // Horizontal sync (active low)
        if (hcount == h_sync_start - 1)
            hsync <= 1'b0;
        else if (hcount == h_sync_end - 1)
            hsync <= 1'b1;

        // Vertical blanking (transitions on line boundaries)
        if (hcount == H_TOTAL - 1) begin
            if (vcount == V_ACTIVE - 1)
                vblank <= 1'b1;
            else if (vcount == V_TOTAL - 1)
                vblank <= 1'b0;
        end

        // Vertical sync (active low)
        if (hcount == H_TOTAL - 1) begin
            if (vcount == v_sync_start - 1)
                vsync <= 1'b0;
            else if (vcount == v_sync_end - 1)
                vsync <= 1'b1;
        end

        // New line pulse
        if (hcount == H_ACTIVE - 1)
            new_line <= 1'b1;

        // New frame pulse
        if (hcount == H_TOTAL - 1 && vcount == V_ACTIVE - 1)
            new_frame <= 1'b1;

        // Data enable leads registered blanking by one pixel (next-cycle state
        // computed in the always @(*) above).
        de <= ~next_hblank & ~next_vblank;
    end
end

endmodule
