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
// Serve side: 2-cycle read latency.  serve_req/serve_x (serve_w, serve_hflip,
//   serve_bank) are presented at cycle T+1 of the pipeline; serve_pix is a REGISTER
//   valid two clocks later, and serve_valid tracks serve_req with the same delay.
//   When serve_hflip is set the effective address is serve_w-1-serve_x.
//
// Storage (2026-09-26, serve-path fmax): ONE simple-dual-port M10K array holding
// both banks, written 64 bits wide and read 16 bits wide (mixed-width altsyncram):
//   write port A: 512 x 64, address {fill_bank, fill_idx[7:0]}
//   read  port B: 2048 x 16, address {serve_bank, xa[9:0]}, OUTPUT REGISTERED
// Port B's output register removes the unregistered M10K clock-to-out from the
// served-pixel cone, and the 16-bit read port removes the post-RAM bank (2:1) and
// lane (4:1) muxes. That cone (M10K -> bank/lane mux -> feed mux -> DSP multiply ->
// s3_cm_p*/s3_pa_prod/clut addr) was the seed-sensitive clk_sys violator: see
// docs/superpowers/findings/2026-09-26-compositor-serve-path-timing.md.
// Mixed-width lane order: on Intel M10Ks the LOW bits of the wide word are the
// LOWEST narrow address, so fill_qw[15:0] is pixel idx*4+0 -- the layout the
// previous per-bank 64-bit arrays used.
//
// The array is an explicit altsyncram (not inferred): the previous two-bank form had
// already fallen out of M10K inference once (~32K flip-flops, clk_sys failure),
// and Quartus 17 Lite's mixed-width inference is not something to depend on.
// Icarus/Verilator get a behavioural model with the same 2-cycle timing.
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

  output reg         serve_valid,   // serve_req delayed 2 cycles
  output wire [15:0] serve_pix
);

  wire [15:0] xa    = serve_hflip ? (serve_w - 16'd1 - serve_x) : serve_x;
  wire  [8:0] wr_a  = {fill_bank, fill_idx[7:0]};
  wire [10:0] rd_a  = {serve_bank, xa[9:0]};
  reg         serve_valid_d;

  always @(posedge clk) begin
    serve_valid_d <= serve_req;
    serve_valid   <= serve_valid_d;
  end

`ifdef __ICARUS__
  `define LINEBUF_BEHAVIOURAL
`endif
`ifdef VERILATOR
  `define LINEBUF_BEHAVIOURAL
`endif
`ifdef LINEBUF_BEHAVIOURAL
  // Behavioural model of the altsyncram below: registered read address, then the
  // output register (2 cycles). Mixed-port read-during-write is DONT_CARE in the
  // primitive; the pipeline never reads the bank being filled.
  reg [15:0] mem [0:2047];
  reg [15:0] rd_q, out_q;
  always @(posedge clk) begin
    if (fill_we) begin
      mem[{wr_a, 2'd0}] <= fill_qw[15:0];
      mem[{wr_a, 2'd1}] <= fill_qw[31:16];
      mem[{wr_a, 2'd2}] <= fill_qw[47:32];
      mem[{wr_a, 2'd3}] <= fill_qw[63:48];
    end
    rd_q  <= mem[rd_a];
    out_q <= rd_q;
  end
  assign serve_pix = out_q;
  `undef LINEBUF_BEHAVIOURAL
`else
  altsyncram #(
    .operation_mode                     ("DUAL_PORT"),
    .intended_device_family             ("Cyclone V"),
    .lpm_type                           ("altsyncram"),
    .ram_block_type                     ("M10K"),
    .width_a                            (64),
    .widthad_a                          (9),
    .numwords_a                         (512),
    .width_byteena_a                    (1),
    .width_b                            (16),
    .widthad_b                          (11),
    .numwords_b                         (2048),
    .address_reg_b                      ("CLOCK0"),
    .outdata_reg_b                      ("CLOCK0"),
    .outdata_aclr_b                     ("NONE"),
    .address_aclr_b                     ("NONE"),
    .clock_enable_input_a               ("BYPASS"),
    .clock_enable_input_b               ("BYPASS"),
    .clock_enable_output_b              ("BYPASS"),
    .read_during_write_mode_mixed_ports ("DONT_CARE"),
    .power_up_uninitialized             ("FALSE")
  ) u_ram (
    .clock0    (clk),
    .address_a (wr_a),
    .data_a    (fill_qw),
    .wren_a    (fill_we),
    .address_b (rd_a),
    .q_b       (serve_pix),
    // unused ports
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_a(1'b1), .byteena_b(1'b1), .clock1(1'b1), .clocken0(1'b1),
    .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1), .data_b({16{1'b1}}),
    .eccstatus(), .q_a(), .rden_a(1'b1), .rden_b(1'b1), .wren_b(1'b0)
  );
`endif

endmodule
