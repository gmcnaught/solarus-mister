//============================================================================
//
//  OpenBOR Native Video Timing Generator
//
//  320x240 active area @ 59.92 Hz (420x262 total)
//  Exact Genesis H40 timing — NTSC-derived MCLK from colorburst crystal.
//  CLK_VIDEO: 53.693 MHz (exact Genesis MCLK), variable CE_PIXEL for H_TOTAL=420.
//
//  H: 320 active + 100 blanking = 420 total (exact Genesis H40)
//  V: 240 active +   2 FP + 3 sync + 17 BP = 262 total (exact Genesis NTSC)
//
//  Refresh: 15,700 / 262 = 59.92 Hz (exact Genesis)
//  H freq:  53,693,182 / 3420 = 15,700 Hz (exact Genesis)
//  H active time: 320 × 8 / 53.693MHz = 47.68 µs (exact NES/SNES/Genesis)
//
//  Adapted from MiSTer_PICO-8 by MiSTer Organize
//  Copyright (C) 2026 MiSTer Organize -- GPL-3.0
//
//============================================================================

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
localparam H_ACTIVE = 320;
localparam H_FP     = 17;
localparam H_SYNC   = 38;
localparam H_BP     = 45;
localparam H_TOTAL  = 420;   // 320+17+38+45 (exact Genesis H40)

localparam V_ACTIVE = 240;
localparam V_FP     = 2;
localparam V_SYNC   = 3;
localparam V_BP     = 17;
localparam V_TOTAL  = 262;   // 240+2+3+17 (exact Genesis NTSC)

// Derived boundaries — adjusted by OSD H/V position offset.
wire [9:0] h_sync_start = H_ACTIVE + H_FP + {{5{h_adj[4]}}, h_adj};
wire [9:0] h_sync_end   = h_sync_start + H_SYNC;
wire [8:0] v_sync_start = V_ACTIVE + V_FP + {{5{v_adj[3]}}, v_adj};
wire [8:0] v_sync_end   = v_sync_start + V_SYNC;

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

        // Data enable (combinational from next-cycle blanking state)
        begin
            reg next_hblank, next_vblank;

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

            de <= ~next_hblank & ~next_vblank;
        end
    end
end

endmodule
