// comp_src_linebuf.sv — on-chip source line buffer for the pipelined compositor.
// Copyright (C) 2026 — GPL-3.0
//
// Holds one row of up to 1024 pixels (16-bit each, 2 KiB BRAM).
//
// Fill side: burst engine writes four packed 16-bit pixels per clock via
//   fill_we / fill_qw[63:0] / fill_idx[9:0].  fill_idx is the qword index;
//   pixels land at addresses fill_idx*4 .. fill_idx*4+3.
//   fill_qw[15:0] → pixel 0, fill_qw[31:16] → pixel 1, etc.
//
// Serve side: 1-cycle read latency.  On fill_we the mixer asserts serve_req
//   with serve_x (source-local pixel x), serve_w (row width), and serve_hflip.
//   When serve_hflip is set the effective address is serve_w-1-serve_x.
//   serve_pix is valid the following clock; serve_valid tracks serve_req with
//   the same 1-cycle delay.
//
`default_nettype none

module comp_src_linebuf (
  input  wire        clk,

  // fill side
  input  wire        fill_we,
  input  wire [63:0] fill_qw,
  input  wire  [9:0] fill_idx,

  // serve side
  input  wire        serve_req,
  input  wire [15:0] serve_x,
  input  wire [15:0] serve_w,
  input  wire        serve_hflip,

  output reg         serve_valid,
  output wire [15:0] serve_pix
);

  // 256-entry, 64-bit-wide BRAM (= 1024 px). Stored qword-wide so the fill writes
  // ONE qword per cycle (a single write port) — the previous 16-bit-wide array did
  // FOUR writes/cycle (line[{idx,0}]..line[{idx,3}]), i.e. 4 write ports, which M10K
  // can't provide, so Quartus dropped the whole 16 Kbit array into flip-flops
  // (~16,400 regs). One write port + one registered read port → inferred M10K.
  reg [63:0] line [0:255];

  // ── fill: write the whole 64-bit qword (fill_idx is the qword index) ──────────
  always @(posedge clk) begin
    if (fill_we)
      line[fill_idx[7:0]] <= fill_qw;
  end

  // ── serve: 1-cycle read latency; horizontal flip applied on address ─────────
  // Read the qword (registered), then combinationally select the 16-bit lane so the
  // serve latency stays exactly one cycle (no extra pipeline stage vs the old array).
  wire [15:0] xa = serve_hflip ? (serve_w - 16'd1 - serve_x) : serve_x;
  reg [63:0] serve_qw_q;     // registered qword read
  reg  [1:0] serve_lane_q;   // registered lane, aligned with serve_qw_q

  always @(posedge clk) begin
    serve_valid  <= serve_req;
    serve_lane_q <= xa[1:0];
    if (serve_req)
      serve_qw_q <= line[xa[9:2]];
  end

  assign serve_pix = serve_qw_q[16*serve_lane_q +: 16];

endmodule
