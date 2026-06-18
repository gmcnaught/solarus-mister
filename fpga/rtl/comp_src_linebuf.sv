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
  output reg  [15:0] serve_pix
);

  // 1024-entry, 16-bit-wide BRAM (inferred)
  reg [15:0] line [0:1023];

  // ── fill: unpack four pixels from qword and write to consecutive addresses ──
  always @(posedge clk) begin
    if (fill_we) begin
      line[{fill_idx, 2'd0}] <= fill_qw[15:0];
      line[{fill_idx, 2'd1}] <= fill_qw[31:16];
      line[{fill_idx, 2'd2}] <= fill_qw[47:32];
      line[{fill_idx, 2'd3}] <= fill_qw[63:48];
    end
  end

  // ── serve: 1-cycle read latency; horizontal flip applied on address ─────────
  wire [15:0] xa = serve_hflip ? (serve_w - 16'd1 - serve_x) : serve_x;

  always @(posedge clk) begin
    serve_valid <= serve_req;
    if (serve_req)
      serve_pix <= line[xa[9:0]];
  end

endmodule
