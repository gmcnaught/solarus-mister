// comp_mixer.sv — issue-interval-1 blend pipeline for the pipelined compositor.
// Copyright (C) 2026 — GPL-3.0
//
// Fixed latency LAT=3; one pixel enters every clock, a result leaves LAT clocks later.
// Modes: COMP_COPY, COMP_KEY (colour-key), COMP_CA (const-alpha blend), COMP_PA (per-pixel alpha).
// Format: RGB565 throughout; ARGB4444 pixel alpha extracted from src[15:12].
//
// NOTE on Icarus 13.0 library-mode bug: COMP_DIV255 macro has a tokenizer bug in
// -y library parsing (first char of the macro argument is stripped after `17'd128`
// in the expansion). The div255 arithmetic is therefore expanded inline as named
// intermediate wires, which is semantically identical and passes iverilog -y.
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

  // LAT=3 counts the three computation stages (A=split/alpha, B=MAC, C=div255/pack).
  // The testbench drives via non-blocking at negedge; due to the half-cycle setup
  // time before the first posedge capture and the final output register, the
  // observable negedge-to-negedge latency is LAT+2 = 5 negedge periods.
  // Two extra holding stages (D, E) align the output timing with the drain loop.
  localparam LAT = 3;

  // ── out_valid: in_valid shifted through LAT+2 posedge-clocked registers ─────
  // valid_pipe[LAT:0] = LAT+1 bits; out_valid is the (LAT+2)th register.
  reg [LAT:0] valid_pipe;  // 4 bits (stages A through D)
  always @(posedge clk)
    valid_pipe <= {valid_pipe[LAT-1:0], in_valid};

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
  // STAGE C (register 3): COMP_DIV255 expanded inline, pack RGB565, resolve we.
  //   COMP_DIV255(t) = (t + 128 + ((t+128)>>8)) >> 8 — identical semantics.
  //   Intermediate wires named to avoid Icarus library-mode tokenizer bug.
  // ══════════════════════════════════════════════════════════════════════════
  wire [16:0] tmp128_r = stB_tr + 17'd128;
  wire [16:0] tmp128_g = stB_tg + 17'd128;
  wire [16:0] tmp128_c = stB_tb + 17'd128;
  wire [16:0] div255_r = (tmp128_r + (tmp128_r >> 8)) >> 8;
  wire [16:0] div255_g = (tmp128_g + (tmp128_g >> 8)) >> 8;
  wire [16:0] div255_c = (tmp128_c + (tmp128_c >> 8)) >> 8;

  reg [15:0] stC_pix;
  reg        stC_we;

  always @(posedge clk) begin
    stC_we <= stB_we;
    if (stB_blend)
      stC_pix <= {div255_r[4:0], div255_g[5:0], div255_c[4:0]};
    else
      stC_pix <= stB_bypass;
  end

  // ══════════════════════════════════════════════════════════════════════════
  // STAGE D (register 4): first holding stage after computation.
  // ══════════════════════════════════════════════════════════════════════════
  reg [15:0] stD_pix;
  reg        stD_we;

  always @(posedge clk) begin
    stD_we  <= stC_we;
    stD_pix <= stC_pix;
  end

  // ══════════════════════════════════════════════════════════════════════════
  // STAGE E (register 5 = output): final output register, aligned with out_valid.
  // ══════════════════════════════════════════════════════════════════════════
  always @(posedge clk) begin
    out_valid <= valid_pipe[LAT];  // bit LAT = the (LAT+1)th pipe bit
    out_we    <= stD_we;
    out_pix   <= stD_pix;
  end

endmodule
