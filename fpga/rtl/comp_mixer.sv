// comp_mixer.sv — issue-interval-1 blend pipeline for the pipelined compositor.
// Copyright (C) 2026 — GPL-3.0
//
// Fixed latency LAT=3; one pixel enters every clock, a result leaves 3 clocks later.
// out_valid/out_pix/out_we are the registered outputs of stage C (the 3rd stage).
// Modes: COMP_COPY, COMP_KEY (colour-key), COMP_CA (const-alpha blend),
//        COMP_PA (per-pixel alpha), COMP_ADD (saturating add), COMP_MUL (multiply).
// Format: RGB565 throughout; ARGB4444 pixel alpha extracted from src[15:12].
//
// [v2 escape-elim] ADD/MULTIPLY reuse the existing 3-stage skeleton (II=1): the
// mode decode emits a 2-bit ARITH kind (stage A); stage B computes the per-channel
// intermediate (CA MAC / s+d / s*d); stage C finalises (/255 / saturate / round).
// Color-mod (tint) is NOT done here — comp_pipeline modulates the source pixel
// before it reaches in_src, so ADD/MUL/etc. all compose with tint for free.
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

  // [v2 escape-elim] per-channel arithmetic kind carried A->B->C (decouples the
  // mode decode from the stage-B/C datapath so ADD/MUL fit the same skeleton).
  localparam [1:0] ARITH_BYP = 2'd0,  // COPY/KEY: out = bypass src (we per key)
                   ARITH_CA  = 2'd1,  // const-alpha / palpha: MAC + /255
                   ARITH_ADD = 2'd2,  // saturating add: min(s+d, chan_max)
                   ARITH_MUL = 2'd3;  // multiply: round(s*d / chan_max)

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
  reg  [1:0] stA_arith;
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
        stA_arith <= ARITH_BYP;
        stA_we    <= 1'b1;
        stA_alpha <= 8'd0;
      end
      `COMP_KEY: begin
        stA_arith <= ARITH_BYP;
        stA_we    <= (in_src != in_key);
        stA_alpha <= 8'd0;
      end
      `COMP_CA: begin
        stA_arith <= ARITH_CA;
        stA_we    <= 1'b1;
        stA_alpha <= in_alpha;
      end
      `COMP_PA: begin
        // a4==0 -> fully transparent: BYP with we=0 (skip-write), matching the
        // legacy blend4444 contract. a4!=0 -> CA with a8={a4,a4}.
        stA_arith <= (in_src[15:12] != 4'd0) ? ARITH_CA : ARITH_BYP;
        stA_we    <= (in_src[15:12] != 4'd0);
        stA_alpha <= {in_src[15:12], in_src[15:12]};
      end
      `COMP_ADD: begin
        stA_arith <= ARITH_ADD;
        stA_we    <= 1'b1;
        stA_alpha <= 8'd0;
      end
      `COMP_MUL: begin
        stA_arith <= ARITH_MUL;
        stA_we    <= 1'b1;
        stA_alpha <= 8'd0;
      end
      default: begin
        stA_arith <= ARITH_BYP;
        stA_we    <= 1'b0;
        stA_alpha <= 8'd0;
      end
    endcase
  end

  // ══════════════════════════════════════════════════════════════════════════
  // STAGE B (register 2): per-channel intermediate, selected by stA_arith.
  //   ARITH_CA : t = src*a + dst*(255-a)   (reduced /255 in stage C)
  //   ARITH_ADD: t = src + dst             (saturated in stage C)
  //   ARITH_MUL: t = src * dst             (round-divided by chan_max in stage C)
  // 17-bit holds every case: CA max 31*255+31*255=15810, ADD max 63+63=126,
  // MUL max 63*63=3969.
  // ══════════════════════════════════════════════════════════════════════════
  reg [16:0] stB_tr, stB_tg, stB_tb;
  reg  [1:0] stB_arith;
  reg        stB_we;
  reg [15:0] stB_bypass;

  always @(posedge clk) begin
    stB_arith  <= stA_arith;
    stB_we     <= stA_we;
    stB_bypass <= stA_bypass;

    case (stA_arith)
      ARITH_CA: begin
        stB_tr <= {12'd0, stA_sr} * {9'd0, stA_alpha}
                + {12'd0, stA_dr} * (17'd255 - {9'd0, stA_alpha});
        stB_tg <= {11'd0, stA_sg} * {9'd0, stA_alpha}
                + {11'd0, stA_dg} * (17'd255 - {9'd0, stA_alpha});
        stB_tb <= {12'd0, stA_sb} * {9'd0, stA_alpha}
                + {12'd0, stA_db} * (17'd255 - {9'd0, stA_alpha});
      end
      ARITH_ADD: begin
        stB_tr <= {12'd0, stA_sr} + {12'd0, stA_dr};   // R5 + R5  (<=62)
        stB_tg <= {11'd0, stA_sg} + {11'd0, stA_dg};   // G6 + G6  (<=126)
        stB_tb <= {12'd0, stA_sb} + {12'd0, stA_db};   // B5 + B5  (<=62)
      end
      ARITH_MUL: begin
        stB_tr <= {12'd0, stA_sr} * {12'd0, stA_dr};   // R5 * R5  (<=961)
        stB_tg <= {11'd0, stA_sg} * {11'd0, stA_dg};   // G6 * G6  (<=3969)
        stB_tb <= {12'd0, stA_sb} * {12'd0, stA_db};   // B5 * B5  (<=961)
      end
      default: begin // ARITH_BYP
        stB_tr <= 17'd0;
        stB_tg <= 17'd0;
        stB_tb <= 17'd0;
      end
    endcase
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

  // ADD: per-channel saturate to the RGB565 channel maxima (R/B=31, G=63).
  wire [4:0] add_r = (stB_tr > 17'd31) ? 5'd31 : stB_tr[4:0];
  wire [5:0] add_g = (stB_tg > 17'd63) ? 6'd63 : stB_tg[5:0];
  wire [4:0] add_b = (stB_tb > 17'd31) ? 5'd31 : stB_tb[4:0];

  // MULTIPLY: round(p/chan_max). p = src*dst (already in stB_t*). DIVIDE-FREE
  // reduction (bit-exact to round(p/(2^k-1)), same shape as COMP_DIV255 / the C
  // golden blt_mul565): round(p/31)=((p+16)+((p+16)>>5))>>5, round(p/63)=
  // ((p+32)+((p+32)>>6))>>6. A literal /31,/63 synthesises a deep reciprocal
  // network (cost ~18ns on the core clock — the v2 timing blowup); these are shifts+adds.
  wire [16:0] mul_r = ((stB_tr + 17'd16) + ((stB_tr + 17'd16) >> 5)) >> 5;  // round(p/31)
  wire [16:0] mul_g = ((stB_tg + 17'd32) + ((stB_tg + 17'd32) >> 6)) >> 6;  // round(p/63)
  wire [16:0] mul_b = ((stB_tb + 17'd16) + ((stB_tb + 17'd16) >> 5)) >> 5;  // round(p/31)

  always @(posedge clk) begin
    out_we <= stB_we;
    case (stB_arith)
      ARITH_CA:  out_pix <= {div255_r[4:0], div255_g[5:0], div255_b[4:0]};
      ARITH_ADD: out_pix <= {add_r,         add_g,         add_b};
      ARITH_MUL: out_pix <= {mul_r[4:0],    mul_g[5:0],    mul_b[4:0]};
      default:   out_pix <= stB_bypass;   // ARITH_BYP (COPY/KEY/transparent)
    endcase
  end

endmodule
