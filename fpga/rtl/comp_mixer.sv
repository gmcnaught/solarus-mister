// comp_mixer.sv — issue-interval-1 blend pipeline for the pipelined compositor.
// Copyright (C) 2026 — GPL-3.0
//
// Fixed latency LAT=3; one pixel enters every clock, a result leaves 3 clocks later.
// out_valid/out_pix/out_we are the registered outputs of stage C (the 3rd stage).
// Modes: COMP_COPY, COMP_KEY (colour-key), COMP_CA (const-alpha blend), COMP_PA (per-pixel alpha).
// Format: RGB565 throughout; ARGB4444 pixel alpha extracted from src[15:12].
//
`default_nettype none
`include "comp_defs.vh"

module comp_mixer (
  input  wire        clk,
  input  wire        in_valid,
  input  wire [15:0] in_src,
  input  wire [15:0] in_dst,
  input  wire  [7:0] in_mode,
  input  wire  [7:0] in_fmt,
  input  wire [15:0] in_key,
  input  wire  [7:0] in_alpha,

  output reg         out_valid,
  output reg  [15:0] out_pix,
  output reg         out_we
);

  // LAT == pipeline depth == 3 (stage A: split/alpha, stage B: MAC, stage C: div255/pack).
  // Downstream coordinates timing via this value, so LAT must equal the true latency.
  localparam LAT = 3;

  // ── out_valid: in_valid delayed through LAT registers ─────────────────────
  // Three registers total: valid_pipe[0] @ stage A, valid_pipe[1] @ stage B,
  // out_valid @ stage C — aligned exactly with out_pix/out_we (also stage C).
  reg [LAT-2:0] valid_pipe;          // 2 registers (stages A, B)
  always @(posedge clk) begin
    valid_pipe <= {valid_pipe[LAT-3:0], in_valid};
    out_valid  <= valid_pipe[LAT-2]; // 3rd register (stage C)
  end

  // ══════════════════════════════════════════════════════════════════════════
  // STAGE A (register 1): latch inputs, compute alpha, channel splits,
  //                        key/transparent flags, bypass pixel for COPY/KEY.
  // ══════════════════════════════════════════════════════════════════════════
  reg  [7:0] stA_alpha;
  reg  [4:0] stA_sr, stA_dr;
  reg  [5:0] stA_sg, stA_dg;
  reg  [4:0] stA_sb, stA_db;
  reg        stA_blend;
  reg        stA_we;
  reg [15:0] stA_bypass;

  always @(posedge clk) begin
    stA_sr <= in_src[15:11];
    stA_sg <= in_src[10:5];
    stA_sb <= in_src[4:0];
    stA_dr <= in_dst[15:11];
    stA_dg <= in_dst[10:5];
    stA_db <= in_dst[4:0];
    stA_bypass <= in_src;

    case (in_mode)
      `COMP_COPY: begin
        stA_blend <= 1'b0;
        stA_we    <= 1'b1;
        stA_alpha <= 8'd0;
      end
      `COMP_KEY: begin
        stA_blend <= 1'b0;
        stA_we    <= (in_src != in_key);
        stA_alpha <= 8'd0;
      end
      `COMP_CA: begin
        stA_blend <= 1'b1;
        stA_we    <= 1'b1;
        stA_alpha <= in_alpha;
      end
      `COMP_PA: begin
        stA_blend <= (in_src[15:12] != 4'd0);
        stA_we    <= (in_src[15:12] != 4'd0);
        stA_alpha <= {in_src[15:12], in_src[15:12]};
      end
      default: begin
        stA_blend <= 1'b0;
        stA_we    <= 1'b0;
        stA_alpha <= 8'd0;
      end
    endcase
  end

  // ══════════════════════════════════════════════════════════════════════════
  // STAGE B (register 2): three parallel channel multiply-accumulates.
  //   t = chan_src*a + chan_dst*(255-a)
  // ══════════════════════════════════════════════════════════════════════════
  reg [16:0] stB_tr, stB_tg, stB_tb;
  reg        stB_blend;
  reg        stB_we;
  reg [15:0] stB_bypass;

  always @(posedge clk) begin
    stB_blend  <= stA_blend;
    stB_we     <= stA_we;
    stB_bypass <= stA_bypass;

    if (stA_blend) begin
      stB_tr <= {12'd0, stA_sr} * {9'd0, stA_alpha}
              + {12'd0, stA_dr} * (17'd255 - {9'd0, stA_alpha});
      stB_tg <= {11'd0, stA_sg} * {9'd0, stA_alpha}
              + {11'd0, stA_dg} * (17'd255 - {9'd0, stA_alpha});
      stB_tb <= {12'd0, stA_sb} * {9'd0, stA_alpha}
              + {12'd0, stA_db} * (17'd255 - {9'd0, stA_alpha});
    end else begin
      stB_tr <= 17'd0;
      stB_tg <= 17'd0;
      stB_tb <= 17'd0;
    end
  end

  // ══════════════════════════════════════════════════════════════════════════
  // STAGE C (register 3 = outputs): /255 reduce, pack RGB565, resolve out_we.
  //
  // The div255 reduction below MUST stay bit-identical to COMP_DIV255 in
  // comp_defs.vh (contract). We cannot call the macro here: iverilog's -y
  // library-mode preprocessor does not inherit macros from the main file, and
  // because tb_comp_mixer.sv includes comp_defs.vh first, this file's own
  // `include is skipped (include guard already set) -> COMP_DIV255 is undefined
  // when comp_mixer.sv is parsed as a library file, and iverilog then mangles
  // the macro-call argument (strips its first character). Reproduced on
  // Icarus 13.0 with `COMP_DIV255(stB_tr) in stage C:
  //   $ cd fpga/sim && iverilog -g2012 -I ../rtl -y ../rtl -Y .sv \
  //         -o /tmp/x.vvp tb_comp_mixer.sv
  //   ../rtl/comp_mixer.sv: error: Unable to bind wire/reg/memory `tB_tr' ...
  //   ../rtl/comp_mixer.sv: error: Unable to elaborate r-value:
  //     (((tB_tr)+(17'd128))+(((tB_tr)+(17'd128))>>('sd8)))>>('sd8)
  // (Defining the same macro directly inside this file, or listing the sources
  //  explicitly instead of via -y, both compile cleanly -- confirming the
  //  per-compilation-unit macro-scoping limitation, not a formula error.)
  // ══════════════════════════════════════════════════════════════════════════
  wire [16:0] tmp128_r = stB_tr + 17'd128;
  wire [16:0] tmp128_g = stB_tg + 17'd128;
  wire [16:0] tmp128_b = stB_tb + 17'd128;
  wire [16:0] div255_r = (tmp128_r + (tmp128_r >> 8)) >> 8;
  wire [16:0] div255_g = (tmp128_g + (tmp128_g >> 8)) >> 8;
  wire [16:0] div255_b = (tmp128_b + (tmp128_b >> 8)) >> 8;

  always @(posedge clk) begin
    out_we <= stB_we;
    if (stB_blend)
      out_pix <= {div255_r[4:0], div255_g[5:0], div255_b[4:0]};
    else
      out_pix <= stB_bypass;
  end

endmodule
