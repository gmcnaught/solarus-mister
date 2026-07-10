// comp_src_linebuf.sv — on-chip source line buffer for the pipelined compositor.
// Copyright (C) 2026 — GPL-3.0
//
// Holds two independent banks of up to 1024 pixels (16-bit each, 2 KiB BRAM each).
// Bank 0 is the default; Task 3 will drive fill_bank/serve_bank to overlap
// SRCFILL(N+1) with composite(N).
//
// Fill side: burst engine writes four packed 16-bit pixels per clock via
//   fill_we / fill_qw[63:0] / fill_idx[9:0] / fill_bank.  fill_idx is the qword index;
//   pixels land at addresses fill_idx*4 .. fill_idx*4+3.
//   fill_qw[15:0] → pixel 0, fill_qw[31:16] → pixel 1, etc.
//   fill_bank selects which bank (0/1) the fill writes.
//
// Serve side: 1-cycle read latency.  On serve_req the mixer asserts serve_req
//   with serve_x (source-local pixel x), serve_w (row width), serve_hflip, and
//   serve_bank (selects which bank the serve reads).
//   When serve_hflip is set the effective address is serve_w-1-serve_x.
//   serve_pix is valid the following clock; serve_valid tracks serve_req with
//   the same 1-cycle delay.
//
// M10K inference: each bank has ONE write port + ONE registered read port, and the
// register captures a DIRECT array read (q0<=line0[a]; q1<=line1[a]) — the bank mux is
// applied AFTER the register. Do NOT mux the two array reads before the register and do
// NOT add a second write port; either makes Quartus treat the read as asynchronous and
// drops the bank to ~32K flip-flops (clk_sys timing failure).
//
`default_nettype none

module comp_src_linebuf (
  input  wire        clk,

  // fill side
  input  wire        fill_we,
  input  wire [63:0] fill_qw,
  input  wire  [9:0] fill_idx,
  input  wire        fill_bank,   // [overlap] bank the fill writes (0/1)

  // serve side
  input  wire        serve_req,
  input  wire [15:0] serve_x,
  input  wire [15:0] serve_w,
  input  wire        serve_hflip,
  input  wire        serve_bank,  // [overlap] bank the serve reads (0/1)

  output reg         serve_valid,
  output wire [15:0] serve_pix
);

  // Two 256-entry, 64-bit-wide BRAMs (= 1024 px each). Each bank has exactly one
  // write port + one registered read port → M10K inference. Splitting fill_we by
  // bank keeps each write port strictly single-ported (a shared write port with a
  // mux-on-address would still be one write port, but the conditional form is
  // clearest and matches Quartus M10K inference guidelines).
  // Explicit ramstyle -- do not rely on Quartus's AUTO inference heuristic here.
  // Root cause of the Task 3 LAB-overflow fit failure (Fitter requires 8391+
  // LABs, device has only 4191): this module lost its M10K inference entirely
  // in the failing build (0 Block Memory Bits, 32,899 registers -- matching the
  // ~32K-flip-flop failure mode this file's own header already documents above)
  // once bgw_argb4444 going real also forced bgplane_coverage's 4 M10K arrays to
  // actually be implemented (previously optimized away as dead code), shifting
  // overall M10K/logic cost pressure enough to tip AUTO's decision for this
  // already-borderline case. Same fix already proven for bgplane_coverage.sv.
  (* ramstyle = "no_rw_check, M10K" *) reg [63:0] line0 [0:255];
  (* ramstyle = "no_rw_check, M10K" *) reg [63:0] line1 [0:255];

  // ── fill: write the whole 64-bit qword to the selected bank ──────────────────
  always @(posedge clk) if (fill_we && !fill_bank) line0[fill_idx[7:0]] <= fill_qw;
  always @(posedge clk) if (fill_we &&  fill_bank) line1[fill_idx[7:0]] <= fill_qw;

  // ── serve: 1-cycle read latency; horizontal flip applied on address ──────────
  // Register EACH bank's read into its OWN output (q0/q1), then mux the two
  // REGISTERED outputs by a registered serve_bank. This keeps each array a pure
  // registered-read RAM so both infer as M10K. The previous form muxed the two
  // array reads BEFORE the register (serve_qw_q <= serve_bank ? line1 : line0),
  // which Quartus flagged as "asynchronous read logic" and dropped both banks to
  // ~32K flip-flops — blowing clk_sys timing (the bank mux landed on the RAM-read
  // path). Bit-identical: serve_qw at T+1 = (serve_bank@T) ? line1[xa@T] : line0[xa@T],
  // and the bank mux is now post-register (off the read path). Latency stays 1 cycle.
  wire [15:0] xa = serve_hflip ? (serve_w - 16'd1 - serve_x) : serve_x;
  reg [63:0] q0, q1;          // per-bank registered qword reads (each → M10K)
  reg        serve_bank_q;    // serve_bank aligned with q0/q1 (post-register mux select)
  reg  [1:0] serve_lane_q;    // registered lane, aligned with the reads

  always @(posedge clk) begin
    serve_valid  <= serve_req;
    serve_lane_q <= xa[1:0];
    serve_bank_q <= serve_bank;
    if (serve_req) q0 <= line0[xa[9:2]];
    if (serve_req) q1 <= line1[xa[9:2]];
  end

  wire [63:0] serve_qw_q = serve_bank_q ? q1 : q0;
  assign serve_pix = serve_qw_q[16*serve_lane_q +: 16];

endmodule
