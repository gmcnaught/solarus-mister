// bgplane_coverage.sv -- per-cell pixel-coverage tracker for the Phase 3b+ ARGB4444
// plane bake. Mirrors comp_pipeline's fb_wr_en/fb_wr_qw/fb_wr_lane pulses (one per
// pixel actually written to comp_fbram) into a 19200x4-bit array, addressed
// identically to comp_fbram's own AW=15 qword space (4 lanes/qword, matching
// comp_fbram's 16-bit-pixel x 4-lane/64-bit-qword layout).
//
// wr_clear selects what a pulse WRITES: 0 (normal paint) sets the touched lane's
// bit to 1 ("covered"); 1 (bake-mode OP_FILL, see blitter_top.sv's BLT_F_BGCOV
// decode) clears it to 0. A full-screen FILL touches every lane at every address
// exactly once as part of its own existing pixel-write loop, so this doubles as
// the clear-sweep with no separate FSM: no address is ever "not yet cleared" by
// the time OP_BGPLANE_WRITE reads it, because the FILL that must precede any
// bake-cell paint (see mister_blitter_renderer.cpp's bake_background_plane_step)
// always visits the whole cell before the paint's own tile-list ops run.
//
// Read port mirrors comp_fbram's registered-read contract exactly (rd_nibble valid
// 1 cycle after rd_qw/rd_en) so fbram_to_sdram.sv can read it in lockstep with
// rd_qword with zero new pipeline-timing bookkeeping.
// Copyright (C) 2026 -- GPL-3.0
`default_nettype none
module bgplane_coverage #(
    parameter integer AW = 15
)(
    input  wire          clk,
    input  wire          rst,
    // write side: tap comp_pipeline's fb_wr_* directly (fan-out, not exclusive use)
    input  wire          wr_en,
    input  wire [AW-1:0] wr_qw,
    input  wire [1:0]    wr_lane,
    input  wire          wr_clear,   // 0=paint (set bit) 1=bake-FILL (clear bit)
    // read side: tap the fb_rd_* bus (already muxed for whichever consumer owns it)
    input  wire          rd_en,
    input  wire [AW-1:0] rd_qw,
    output reg  [3:0]    rd_nibble   // registered, valid 1 cyc after rd_qw/rd_en
);
    reg [3:0] mem [0:19199];
    // Zero-init: matches Cyclone V M10K's power-up-to-0 default (no .mif given),
    // and makes a not-yet-painted cell read a deterministic 0 in simulation too
    // (real usage never reads one — an OP_FILL always visits every address before
    // any bake-cell paint — but the unit TB below exercises this corner directly).
    // Sim-only: Quartus's Analysis & Synthesis refuses to unroll an initial-block
    // loop past 5000 iterations (Error 10106) — a hard elaboration limit, not a
    // style choice. Icarus (our sim) has no such limit, so this still runs under
    // sim (fixing the X's bug this loop exists for); on real hardware we instead
    // rely on the M10K's own zero-at-configuration power-up, which produces the
    // identical value this loop would have written, so synthesis skipping it is
    // not a functional gap.
    // synthesis translate_off
    integer init_i;
    initial for (init_i = 0; init_i < 19200; init_i = init_i + 1) mem[init_i] = 4'd0;
    // synthesis translate_on

    always @(posedge clk) begin
        if (wr_en) mem[wr_qw][wr_lane] <= !wr_clear;
        if (rd_en) rd_nibble <= mem[rd_qw];
    end
endmodule
`default_nettype wire
