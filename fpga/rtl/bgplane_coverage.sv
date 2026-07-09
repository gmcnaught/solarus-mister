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
    // Four separate 1-bit-wide, 19200-deep arrays (one per lane) instead of a
    // single 4-bit-wide array. A dynamically-indexed bit-select write
    // (mem[wr_qw][wr_lane] <= ...) doesn't match Quartus's RAM-inference
    // template — confirmed on real hardware: the original single-array version
    // built (0 errors) but Solarus.map.rpt's RAM Summary showed ZERO M10K/MLAB
    // blocks for this module, meaning it silently fell through to raw logic
    // instead of the intended ~8-block on-chip RAM. Splitting by lane makes
    // every write a plain enable-qualified FULL-WORD (1-bit) write — the
    // simplest RAM-inference pattern — at the cost of needing a lane mux on
    // both the write-enable and the read reconstruction below.
    //
    // That split alone still wasn't enough — confirmed on HW again: 0 M10K
    // blocks even for the 4-array version. Quartus's automatic RAM inference
    // has area heuristics that can decide a narrow (1-bit-wide) shape is
    // "better" left as plain logic; comp_fbram.sv (this module's sibling,
    // same file/author, DOES land in M10K every time) never relies on pure
    // inference — every one of its banks carries an explicit `ramstyle`
    // attribute. Matching that exact syntax here forces Quartus's hand
    // regardless of the heuristic. `no_rw_check` is safe for the same reason
    // comp_fbram.sv's own comment gives: this tracker's writes (during
    // cell-paint) and reads (during the later OP_BGPLANE_WRITE streaming
    // pass) are temporally separated phases, never same-cycle/same-address,
    // so no read-during-write forwarding behavior is needed.
    //
    // Still 0 M10K blocks after the ramstyle attribute — 3rd HW round. Likely
    // cause (unconfirmed, deferred): Task 1 wires wr_en/wr_qw/wr_lane to
    // comp_pipeline's real per-pixel write signals (real writes happen every
    // frame), but this module's OWN read output (rd_nibble) has zero
    // consumers anywhere yet — Task 2 is what wires it into fbram_to_sdram's
    // rd_cov port. A memory whose contents are never observed by anything
    // downstream is a standard dead-code-elimination target regardless of
    // write activity or ramstyle. A `noprune` diagnostic was tried (4th HW
    // round) and showed no effect either way — synthesized totals were
    // bit-for-bit identical with and without it, so it was reverted rather
    // than kept as an unproven attribute. The real fit-verification gate for
    // this module is deferred to Task 2, once rd_nibble has a genuine
    // consumer (see .superpowers/sdd/task-1-report.md).
    (* ramstyle = "no_rw_check, M10K" *) reg mem0 [0:19199];
    (* ramstyle = "no_rw_check, M10K" *) reg mem1 [0:19199];
    (* ramstyle = "no_rw_check, M10K" *) reg mem2 [0:19199];
    (* ramstyle = "no_rw_check, M10K" *) reg mem3 [0:19199];
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
    initial for (init_i = 0; init_i < 19200; init_i = init_i + 1) begin
        mem0[init_i] = 1'b0; mem1[init_i] = 1'b0;
        mem2[init_i] = 1'b0; mem3[init_i] = 1'b0;
    end
    // synthesis translate_on

    always @(posedge clk) begin
        if (wr_en && wr_lane == 2'd0) mem0[wr_qw] <= !wr_clear;
        if (wr_en && wr_lane == 2'd1) mem1[wr_qw] <= !wr_clear;
        if (wr_en && wr_lane == 2'd2) mem2[wr_qw] <= !wr_clear;
        if (wr_en && wr_lane == 2'd3) mem3[wr_qw] <= !wr_clear;
        if (rd_en) rd_nibble <= {mem3[rd_qw], mem2[rd_qw], mem1[rd_qw], mem0[rd_qw]};
    end
endmodule
`default_nettype wire
