// comp_dest_band.sv — full-width on-chip destination band buffer for pipelined compositor.
// Copyright (C) 2026 — GPL-3.0
//
// Holds 320 px × COMP_BAND_H rows = 80*COMP_BAND_H qwords of 64-bit BRAM.
// Each qword carries four 16-bit pixels; per-qword dirty flag and byte-enable
// accumulator support blend RMW and efficient burst-write flush to DDR.
//
// ld_*   : preload real DDR contents (clears dirty so blend reads are valid)
// cw_*   : composite-write from mixer; merges pixel into lane, ORs BE, sets dirty
// rd_*   : 1-cycle read latency for RMW destination pixel
// flush  : on flush_req, stream every dirty qword out via fl_*, then flush_done
//
`default_nettype none

// Pull in shared params (COMP_BAND_H) so a standalone Quartus synthesis pass sees
// the real value.  In the iverilog -y sim flow the testbench includes comp_defs.vh
// first, so this re-include is a no-op (guarded by COMP_DEFS_VH).
`include "comp_defs.vh"

// Belt-and-suspenders fallback in case the include path is unavailable.  Only
// active when the macro is still absent (never the case once comp_defs.vh is seen).
`ifndef COMP_BAND_H
  `define COMP_BAND_H 16
`endif

module comp_dest_band (
  input  wire        clk,

  // preload side — write real DDR qword, clear dirty
  input  wire        ld_we,
  input  wire [63:0] ld_qw,
  input  wire [12:0] ld_idx,

  // composite-write side — merge pixel into band
  input  wire        cw_we,
  input  wire [15:0] cw_x,
  input  wire  [3:0] cw_row,
  input  wire [15:0] cw_pix,

  // RMW destination read (1-cycle latency)
  input  wire [15:0] rd_x,
  input  wire  [3:0] rd_row,
  output wire [15:0] rd_dst,

  // flush side
  input  wire        flush_req,
  output reg         fl_valid,
  output reg  [63:0] fl_qw,
  output reg   [7:0] fl_be,
  output reg  [12:0] fl_idx,
  output reg         flush_done
);

  // ── BRAM arrays ────────────────────────────────────────────────────────────
  localparam BAND_H   = `COMP_BAND_H;       // rows in band (8)
  localparam N_QW     = 80 * BAND_H;        // total qwords (640)

  // The band buffer is stored as FOUR 16-bit lane RAMs with FULL-WIDTH writes (no
  // byte enables). Quartus 17.0 would not infer a byte-enable RAM — even a 1W1R one —
  // so the 64-bit `data` kept landing in flip-flops (~41 K regs, ~35 K ALUTs = the
  // entire fit overflow). Splitting into per-lane 16-bit RAMs makes every write
  // full-width (ld writes all 4 lanes; cw writes only lane cw_lane). Each lane is
  // replicated for its two readers (RMW read + flush) so every array is a clean
  // 1-write/1-read full-width RAM — the exact shape `be` infers from → M10K (8 small
  // blocks). no_rw_check drops read-during-write bypass (safe: the RMW read targets a
  // lane the in-flight write isn't touching, matching iverilog's old-data semantics).
  // NOTE: these MUST be eight separate 1D arrays — Quartus infers RAM only from 1D
  // unpacked memories (a 2D `[0:3][0:N_QW-1]` is not inferred at all, it stays regs).
  (* ramstyle = "no_rw_check, M10K" *) reg [15:0] band_rd0 [0:N_QW-1];  // lane 0, RMW-read
  (* ramstyle = "no_rw_check, M10K" *) reg [15:0] band_rd1 [0:N_QW-1];  // lane 1, RMW-read
  (* ramstyle = "no_rw_check, M10K" *) reg [15:0] band_rd2 [0:N_QW-1];  // lane 2, RMW-read
  (* ramstyle = "no_rw_check, M10K" *) reg [15:0] band_rd3 [0:N_QW-1];  // lane 3, RMW-read
  (* ramstyle = "no_rw_check, M10K" *) reg [15:0] band_fl0 [0:N_QW-1];  // lane 0, flush-read
  (* ramstyle = "no_rw_check, M10K" *) reg [15:0] band_fl1 [0:N_QW-1];  // lane 1, flush-read
  (* ramstyle = "no_rw_check, M10K" *) reg [15:0] band_fl2 [0:N_QW-1];  // lane 2, flush-read
  (* ramstyle = "no_rw_check, M10K" *) reg [15:0] band_fl3 [0:N_QW-1];  // lane 3, flush-read
  // be/dirty stay in logic: be OR-accumulates (same-cycle read-modify-write, not
  // RAM-inferrable) and both are small (N_QW x 8b / x 1b), halved by BAND_H=8.
  reg  [7:0] be   [0:N_QW-1];
  reg        dirty[0:N_QW-1];

  // ── address helpers ────────────────────────────────────────────────────────
  // cw addressing — row is 4-bit, x is up to 319 (9-bit useful)
  wire [12:0] cw_qw  = 13'(cw_row) * 13'd80 + 13'(cw_x[8:2]);
  wire  [1:0] cw_lane = cw_x[1:0];

  // rd addressing (combinational qword index; result registered 1 cycle later)
  wire [12:0] rd_qw  = 13'(rd_row) * 13'd80 + 13'(rd_x[8:2]);

  // ── flush FSM state ─────────────────────────────────────────────────────────
  // Declared here so the single band-memory write port below can reference it for
  // the flush-clear of `dirty` (the FSM body lives further down).
  localparam FLUSH_IDLE = 2'd0;
  localparam FLUSH_WALK = 2'd1;
  localparam FLUSH_DONE = 2'd2;
  reg [1:0]  fl_state;
  reg [12:0] fl_ptr;
  // Clear dirty[fl_ptr] on every FLUSH_WALK cycle. Clearing an already-clear bit
  // is a no-op, so dropping the `&& dirty[fl_ptr]` term is behaviour-identical AND
  // removes an asynchronous array read (which blocked RAM inference and added a
  // 1280:1 combinational mux). Mutually exclusive in time with ld/cw.
  wire fl_clr = (fl_state == FLUSH_WALK);

  // ── band-buffer write port — one full-width 16-bit write per lane ─────────────
  // ld (full qword) writes all four lanes at ld_idx; cw writes one lane (cw_lane) at
  // cw_qw. ld_we/cw_we are mutually exclusive in time (LOAD vs COMPOSITE phases). The
  // rd- and fl- copies of each lane get the identical write (manual replication for
  // the two readers). One write process per array → no multi-driver (Error 10028).
  always @(posedge clk) begin : data_write
    if (ld_we) begin
      band_rd0[ld_idx] <= ld_qw[15:0];   band_fl0[ld_idx] <= ld_qw[15:0];
      band_rd1[ld_idx] <= ld_qw[31:16];  band_fl1[ld_idx] <= ld_qw[31:16];
      band_rd2[ld_idx] <= ld_qw[47:32];  band_fl2[ld_idx] <= ld_qw[47:32];
      band_rd3[ld_idx] <= ld_qw[63:48];  band_fl3[ld_idx] <= ld_qw[63:48];
    end else if (cw_we) begin
      case (cw_lane)
        2'd0: begin band_rd0[cw_qw] <= cw_pix; band_fl0[cw_qw] <= cw_pix; end
        2'd1: begin band_rd1[cw_qw] <= cw_pix; band_fl1[cw_qw] <= cw_pix; end
        2'd2: begin band_rd2[cw_qw] <= cw_pix; band_fl2[cw_qw] <= cw_pix; end
        2'd3: begin band_rd3[cw_qw] <= cw_pix; band_fl3[cw_qw] <= cw_pix; end
      endcase
    end
  end

  // ── be/dirty single write port (kept in logic; be is an OR-accumulate RMW) ────
  always @(posedge clk) begin : bd_write
    if (ld_we) begin
      // preload from DDR: clears be/dirty so the next blend RMW reads real data
      be[ld_idx]    <= 8'd0;
      dirty[ld_idx] <= 1'b0;
    end else if (cw_we) begin
      be[cw_qw]     <= be[cw_qw] | (8'b00000011 << (cw_lane * 2));
      dirty[cw_qw]  <= 1'b1;
    end
    if (fl_clr) dirty[fl_ptr] <= 1'b0;   // flush clears the qword it just emitted
  end

  // ── RMW destination read (1-cycle latency) ─────────────────────────────────
  // Read all four lanes of the qword (each a clean full-width RAM read), register
  // them, then select the lane combinationally — preserves the original 1-cycle
  // serve latency without any sub-word RAM access.
  reg [15:0] rd0_q, rd1_q, rd2_q, rd3_q;
  reg  [1:0] rd_lane_q;
  always @(posedge clk) begin : rd_read
    rd0_q <= band_rd0[rd_qw];
    rd1_q <= band_rd1[rd_qw];
    rd2_q <= band_rd2[rd_qw];
    rd3_q <= band_rd3[rd_qw];
    rd_lane_q <= rd_x[1:0];
  end
  assign rd_dst = (rd_lane_q == 2'd0) ? rd0_q :
                  (rd_lane_q == 2'd1) ? rd1_q :
                  (rd_lane_q == 2'd2) ? rd2_q : rd3_q;

  // ── flush state machine ────────────────────────────────────────────────────
  // On flush_req: walk all N_QW qwords; emit dirty ones (band_write's fl_clr
  // clears each as it is emitted). flush_done pulses in the cycle after the last
  // qword (or immediately if none dirty). State decls live above (band_write deps).

  integer i;
  initial begin
    fl_state   = FLUSH_IDLE;
    fl_ptr     = 13'd0;
    fl_valid   = 1'b0;
    fl_qw      = 64'd0;
    fl_be      = 8'd0;
    fl_idx     = 13'd0;
    flush_done = 1'b0;
    // initialise BRAM to zero
    for (i = 0; i < N_QW; i = i + 1) begin
      band_rd0[i] = 16'd0; band_rd1[i] = 16'd0; band_rd2[i] = 16'd0; band_rd3[i] = 16'd0;
      band_fl0[i] = 16'd0; band_fl1[i] = 16'd0; band_fl2[i] = 16'd0; band_fl3[i] = 16'd0;
      be[i]    = 8'd0;
      dirty[i] = 1'b0;
    end
  end

  always @(posedge clk) begin : flush_fsm
    // default de-asserts
    fl_valid   <= 1'b0;
    flush_done <= 1'b0;

    case (fl_state)

      FLUSH_IDLE: begin
        if (flush_req) begin
          fl_ptr   <= 13'd0;
          fl_state <= FLUSH_WALK;
        end
      end

      FLUSH_WALK: begin
        if (fl_ptr == 13'(N_QW - 1)) begin
          // last qword — emit if dirty (cleared by band_write), then done next cyc
          if (dirty[fl_ptr]) begin
            fl_valid      <= 1'b1;
            fl_qw         <= {band_fl3[fl_ptr], band_fl2[fl_ptr],
                              band_fl1[fl_ptr], band_fl0[fl_ptr]};
            fl_be         <= be[fl_ptr];
            fl_idx        <= fl_ptr;
          end
          fl_state <= FLUSH_DONE;
        end else begin
          if (dirty[fl_ptr]) begin
            fl_valid      <= 1'b1;
            fl_qw         <= {band_fl3[fl_ptr], band_fl2[fl_ptr],
                              band_fl1[fl_ptr], band_fl0[fl_ptr]};
            fl_be         <= be[fl_ptr];
            fl_idx        <= fl_ptr;
          end
          fl_ptr <= fl_ptr + 13'd1;
        end
      end

      FLUSH_DONE: begin
        flush_done <= 1'b1;
        fl_state   <= FLUSH_IDLE;
      end

      default: fl_state <= FLUSH_IDLE;

    endcase
  end

endmodule
