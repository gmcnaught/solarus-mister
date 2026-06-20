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

  // `data` is the large band buffer (64b x N_QW). It has TWO readers — the RMW read
  // (rd_dst) and the flush (fl_qw) — at different addresses. Quartus will NOT auto-
  // replicate a *byte-enable* RAM for a 2nd read port, so a single `data` array fell
  // into flip-flops (~41 K regs, ~35 K ALUTs = the whole fit overflow). Replicate it
  // MANUALLY into two 1-write/1-read byte-enable M10Ks (the pattern `be` infers from):
  // data_a serves the RMW read, data_b serves the flush; the write port updates both.
  // no_rw_check drops read-during-write bypass (safe — the RMW read targets a lane the
  // in-flight write isn't touching, matching iverilog's old-data NBA semantics).
  (* ramstyle = "no_rw_check, M10K" *) reg [63:0] data_a [0:N_QW-1];   // RMW-read copy
  (* ramstyle = "no_rw_check, M10K" *) reg [63:0] data_b [0:N_QW-1];   // flush-read copy
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

  // ── band-buffer (data) single write port — byte-enable loop = canonical M10K ──
  // ld (full qword) has priority over cw (one 16-bit lane); d_wbe selects which
  // bytes are written. ld_we/cw_we are mutually exclusive in time (LOAD vs
  // COMPOSITE phases), so this priority is behaviour-identical to the old per-lane
  // partial write. One write process = no multi-driver (Error 10028); the per-byte
  // `if (d_wbe[j]) data[a][8j+:8] <= d[8j+:8]` form is what Quartus maps to M10K BE.
  wire [12:0] d_waddr = ld_we ? ld_idx : cw_qw;
  wire [63:0] d_wdata = ld_we ? ld_qw  : {4{cw_pix}};
  wire [7:0]  d_wbe   = ld_we ? 8'hFF  : (cw_we ? (8'b00000011 << (cw_lane * 2)) : 8'h00);
  integer jb;
  always @(posedge clk) begin : data_write
    for (jb = 0; jb < 8; jb = jb + 1)
      if (d_wbe[jb]) begin
        data_a[d_waddr][8*jb +: 8] <= d_wdata[8*jb +: 8];
        data_b[d_waddr][8*jb +: 8] <= d_wdata[8*jb +: 8];
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
  // Register the FULL qword then select the 16-bit lane combinationally. The old
  // sub-word RAM read (data[rd_qw][16*rd_x[1:0]+:16]) blocked M10K inference, so the
  // 40 Kbit band buffer fell into flip-flops (~41 K regs). With both read ports now
  // doing clean full-qword reads (this + the flush), Quartus maps `data` to
  // replicated M10K. Latency is unchanged (registered read + combinational select).
  reg [63:0] rd_qword_q;
  reg  [1:0] rd_lane_q;
  always @(posedge clk) begin : rd_read
    rd_qword_q <= data_a[rd_qw];
    rd_lane_q  <= rd_x[1:0];
  end
  assign rd_dst = rd_qword_q[16*rd_lane_q +: 16];

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
      data_a[i] = 64'd0;
      data_b[i] = 64'd0;
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
            fl_qw         <= data_b[fl_ptr];
            fl_be         <= be[fl_ptr];
            fl_idx        <= fl_ptr;
          end
          fl_state <= FLUSH_DONE;
        end else begin
          if (dirty[fl_ptr]) begin
            fl_valid      <= 1'b1;
            fl_qw         <= data_b[fl_ptr];
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
