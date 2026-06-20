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
  output reg  [15:0] rd_dst,

  // flush side
  input  wire        flush_req,
  output reg         fl_valid,
  output reg  [63:0] fl_qw,
  output reg   [7:0] fl_be,
  output reg  [12:0] fl_idx,
  output reg         flush_done
);

  // ── BRAM arrays ────────────────────────────────────────────────────────────
  localparam BAND_H   = `COMP_BAND_H;       // rows in band (16)
  localparam N_QW     = 80 * BAND_H;        // total qwords (1280)

  reg [63:0] data [0:N_QW-1];
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
  // flush emits + clears this qword's dirty flag. Mutually exclusive in time with
  // ld/cw, which only run in the LOAD/COMPOSITE phases (never during FLUSH).
  wire fl_clr = (fl_state == FLUSH_WALK) && dirty[fl_ptr];

  // ── single band-memory write port (data / be / dirty) ───────────────────────
  // Quartus requires ONE write process per inferred BRAM (Error 10028: "multiple
  // constant drivers"). The three logical writers — preload (ld), composite-merge
  // (cw), and flush-clear — are mutually exclusive in time (LOAD -> COMPOSITE ->
  // FLUSH phases never overlap), so they share one port via priority muxing.
  // iverilog tolerated separate always blocks; a real FPGA does not.
  always @(posedge clk) begin : band_write
    if (ld_we) begin
      // preload from DDR: clears be/dirty so the next blend RMW reads real data
      data[ld_idx]  <= ld_qw;
      be[ld_idx]    <= 8'd0;
      dirty[ld_idx] <= 1'b0;
    end else if (cw_we) begin
      // merge pixel into its correct 16-bit lane (painter's order: overwrite)
      data[cw_qw][16*cw_lane +: 16] <= cw_pix;
      // OR the byte-enable for this lane (2 BE bits per 16-bit pixel)
      be[cw_qw]                      <= be[cw_qw] | (8'b00000011 << (cw_lane * 2));
      dirty[cw_qw]                   <= 1'b1;
    end
    if (fl_clr) dirty[fl_ptr] <= 1'b0;   // flush clears the qword it just emitted
  end

  // ── RMW destination read (1-cycle latency) ─────────────────────────────────
  always @(posedge clk) begin : rd_read
    rd_dst <= data[rd_qw][16*rd_x[1:0] +: 16];
  end

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
      data[i]  = 64'd0;
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
            fl_qw         <= data[fl_ptr];
            fl_be         <= be[fl_ptr];
            fl_idx        <= fl_ptr;
          end
          fl_state <= FLUSH_DONE;
        end else begin
          if (dirty[fl_ptr]) begin
            fl_valid      <= 1'b1;
            fl_qw         <= data[fl_ptr];
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
