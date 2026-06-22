`default_nettype none
`include "vram_defs.vh"
// Address-decode demux: routes the vendored blitter's mem_* between the DDR
// arbiter (blt_* port) and the SDRAM cache P_DST channel (sd_*).
// FB0/FB1 region -> SDRAM (byte-address remapped); everything else -> DDR.
//
// P_DST cache interface (Task 3):
//   sd_rd/sd_wr: pulse asserted until sd_ok; sd_ok acknowledges in one cycle.
//   sd_din[63:0]: write data (full qword).
//   sd_wdsn[7:0]: active-low byte-select (0=enable, 1=mask). Full write=8'h00.
//   sd_dout[63:0]: read data, valid on sd_ok cycle.
//   Partial and full writes both become ONE masked sd_wr request (no per-lane
//   serialization). sd_wdsn = ~blt_be.
//
// Write flow (S_IDLE -> S_WOKWAIT -> S_IDLE):
//   S_IDLE:    assert sd_wr with qword addr/din/wdsn; latch request; -> S_WOKWAIT.
//   S_WOKWAIT: hold sd_wr until sd_ok; set wr_ok_r; hold blt_busy until blt_wr=0.
//              After ok, sd_wr=0 (wr_ok_r=1). Stay until blt_wr=0 -> S_IDLE.
//
// Read flow (S_IDLE -> S_RDLAT -> ... -> S_IDLE):
//   S_IDLE:   latch rd_on_sdram + beat count + first address; -> S_RDLAT.
//   S_RDLAT:  hold sd_rd until sd_ok for the current beat; on sd_ok:
//             - advance rd_cur_byte +8, decrement rd_beats_left.
//             - last beat: clear rd_on_sdram; -> S_IDLE.
//             - more beats: stay in S_RDLAT (issue next beat immediately).
//
// One always-block per reg/array (Quartus 10028).
module vram_demux (
  input  wire        clk, reset,
  // blitter mem_* (qword-addressed, [31:0] carrying a 29-bit range)
  input  wire [31:0] blt_addr,
  input  wire        blt_rd, blt_wr,
  input  wire [63:0] blt_din,
  input  wire [7:0]  blt_be,
  // SDRAM read-burst beat count. 1 = single-beat (legacy).
  input  wire [7:0]  blt_burstcnt,
  output wire [63:0] blt_dout,
  output wire        blt_dout_ready,
  output wire        blt_busy,
  // DDR side (ddr_blitter_arb blt_* port)
  output wire [28:0] ddr_addr,
  output wire        ddr_rd, ddr_wr,
  output wire [63:0] ddr_din,
  output wire [7:0]  ddr_be,
  input  wire [63:0] ddr_dout,
  input  wire        ddr_dout_ready,
  input  wire        ddr_busy,
  // SDRAM side — P_DST cache channel
  output reg  [26:0] sd_addr,
  output reg         sd_rd,
  output reg         sd_wr,
  output reg  [63:0] sd_din,    // 64-bit write data
  output reg  [ 7:0] sd_wdsn,  // active-low byte-select; full write = 8'h00
  input  wire [63:0] sd_dout,   // read data, valid on sd_ok
  input  wire        sd_ok,     // single-cycle accept/return pulse
  // DEBUG: {rd_on_sdram, st[2:0]}
  output wire  [3:0] dbg
);
  // ---------------------------------------------------------------------------
  // Address decode (combinatorial)
  // ---------------------------------------------------------------------------
  wire [28:0] qw      = blt_addr[28:0];
  wire in_fb0 = (qw >= `FB_DDR0_QW) && (qw < (`FB_DDR0_QW + `FB_QWORDS));
  wire in_fb1 = (qw >= `FB_DDR1_QW) && (qw < (`FB_DDR1_QW + `FB_QWORDS));
  wire is_fb  = in_fb0 | in_fb1;

  wire [28:0] off_qw  = in_fb1 ? (qw - `FB_DDR1_QW) : (qw - `FB_DDR0_QW);
  wire [26:0] fb_base = in_fb1 ? `SDRAM_FB1_BASE : `SDRAM_FB0_BASE;
  wire [26:0] qw_byte = fb_base + {off_qw[23:0], 3'b000};

  // ---------------------------------------------------------------------------
  // DDR passthrough (non-FB, combinatorial)
  // ---------------------------------------------------------------------------
  assign ddr_addr = qw;
  assign ddr_rd   = blt_rd & ~is_fb;
  assign ddr_wr   = blt_wr & ~is_fb;
  assign ddr_din  = blt_din;
  assign ddr_be   = blt_be;

  // ---------------------------------------------------------------------------
  // FSM state encoding
  // ---------------------------------------------------------------------------
  localparam S_IDLE    = 3'd0;
  localparam S_RDLAT   = 3'd1;   // issue + hold sd_rd per beat; wait sd_ok
  localparam S_WOKWAIT = 3'd2;   // hold sd_wr until sd_ok; then wait blt_wr=0

  // ---------------------------------------------------------------------------
  // Registers (one always-block each)
  // ---------------------------------------------------------------------------
  reg [2:0]  st;
  reg        rd_on_sdram;
  reg [7:0]  rd_beats_left;
  reg [26:0] rd_cur_byte;
  reg [28:0] acc_qw;
  reg [63:0] wr_din_r;
  reg [ 7:0] wr_wdsn_r;
  reg [26:0] wr_addr_r;
  reg        wr_ok_r;   // set when sd_ok received in S_WOKWAIT; cleared on S_IDLE entry

  assign dbg = {rd_on_sdram, st};

  // A NEW FB write (different qword) is pending during S_WOKWAIT.
  // Hold blt_busy so comp_burst's pipelined next write is not dropped.
  wire new_wr_pending = is_fb & blt_wr & (qw != acc_qw);

  // ---------------------------------------------------------------------------
  // blt_dout / blt_dout_ready
  // ---------------------------------------------------------------------------
  assign blt_dout       = rd_on_sdram ? sd_dout        : ddr_dout;
  assign blt_dout_ready = rd_on_sdram ? sd_ok          : ddr_dout_ready;

  // ---------------------------------------------------------------------------
  // blt_busy
  // ---------------------------------------------------------------------------
  // S_RDLAT:    busy for entire read sequence (per-beat; waiting sd_ok each)
  // S_WOKWAIT:  busy while blt_wr is still asserted or a new write is pending
  //             (once blt_wr drops and no new write pending, FSM exits -> S_IDLE)
  // S_IDLE/DDR: DDR back-pressure
  assign blt_busy =
      (st == S_RDLAT)
    | ((st == S_WOKWAIT) & (blt_wr | new_wr_pending))
    | ((st == S_IDLE) & ~is_fb & (blt_rd | blt_wr) & ddr_busy);

  // ---------------------------------------------------------------------------
  // SDRAM combinatorial outputs
  // ---------------------------------------------------------------------------
  always @(*) begin
    sd_rd   = 1'b0;
    sd_wr   = 1'b0;
    sd_addr = qw_byte;
    sd_din  = blt_din;
    sd_wdsn = ~blt_be;

    case (st)
      S_IDLE: begin
        if (is_fb) begin
          if (blt_rd) begin
            sd_rd   = 1'b1;
            sd_addr = qw_byte;
          end else if (blt_wr) begin
            sd_wr   = 1'b1;
            sd_addr = qw_byte;
            sd_din  = blt_din;
            sd_wdsn = ~blt_be;
          end
        end
      end

      S_WOKWAIT: begin
        // Hold sd_wr with latched values until sd_ok; after ok, wr_ok_r=1 -> sd_wr=0.
        sd_wr   = ~wr_ok_r;
        sd_addr = wr_addr_r;
        sd_din  = wr_din_r;
        sd_wdsn = wr_wdsn_r;
      end

      S_RDLAT: begin
        // Hold sd_rd with current beat address until sd_ok.
        sd_rd   = ~sd_ok;   // safe: sd_ok is a one-cycle pulse; next cycle FSM advances
        sd_addr = rd_cur_byte;
      end

      default: ;
    endcase
  end

  // ---------------------------------------------------------------------------
  // st — FSM state register
  // ---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (reset) begin
      st <= S_IDLE;
    end else begin
      case (st)
        S_IDLE: begin
          if (is_fb) begin
            if (blt_rd)       st <= S_RDLAT;
            else if (blt_wr)  st <= S_WOKWAIT;
          end
        end

        S_RDLAT: begin
          if (sd_ok && rd_beats_left == 8'd0)
            st <= S_IDLE;
          // else stay in S_RDLAT for the next beat
        end

        S_WOKWAIT: begin
          if (!blt_wr) st <= S_IDLE;
        end

        default: st <= S_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // rd_on_sdram — own always-block
  // ---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (reset)
      rd_on_sdram <= 1'b0;
    else if (st == S_IDLE && is_fb && blt_rd)
      rd_on_sdram <= 1'b1;
    else if (st == S_RDLAT && sd_ok && rd_beats_left == 8'd0)
      rd_on_sdram <= 1'b0;
  end

  // ---------------------------------------------------------------------------
  // rd_beats_left — own always-block
  // ---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (reset)
      rd_beats_left <= 8'd0;
    else if (st == S_IDLE && is_fb && blt_rd)
      rd_beats_left <= blt_burstcnt - 8'd1;
    else if (st == S_RDLAT && sd_ok && rd_beats_left != 8'd0)
      rd_beats_left <= rd_beats_left - 8'd1;
  end

  // ---------------------------------------------------------------------------
  // rd_cur_byte — own always-block
  // ---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (reset)
      rd_cur_byte <= 27'd0;
    else if (st == S_IDLE && is_fb && blt_rd)
      rd_cur_byte <= qw_byte;
    else if (st == S_RDLAT && sd_ok && rd_beats_left != 8'd0)
      rd_cur_byte <= rd_cur_byte + 27'd8;
  end

  // ---------------------------------------------------------------------------
  // acc_qw — own always-block
  // ---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (reset)
      acc_qw <= 29'h1FFFFFFF;
    else if (st == S_IDLE && is_fb && blt_wr)
      acc_qw <= qw;
  end

  // ---------------------------------------------------------------------------
  // wr_addr_r — own always-block
  // ---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (reset)
      wr_addr_r <= 27'd0;
    else if (st == S_IDLE && is_fb && blt_wr)
      wr_addr_r <= qw_byte;
  end

  // ---------------------------------------------------------------------------
  // wr_din_r — own always-block
  // ---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (reset)
      wr_din_r <= 64'd0;
    else if (st == S_IDLE && is_fb && blt_wr)
      wr_din_r <= blt_din;
  end

  // ---------------------------------------------------------------------------
  // wr_wdsn_r — own always-block
  // ---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (reset)
      wr_wdsn_r <= 8'hFF;
    else if (st == S_IDLE && is_fb && blt_wr)
      wr_wdsn_r <= ~blt_be;
  end

  // ---------------------------------------------------------------------------
  // wr_ok_r — set when sd_ok received in S_WOKWAIT; cleared on S_IDLE entry
  // ---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (reset)
      wr_ok_r <= 1'b0;
    else if (st == S_WOKWAIT && sd_ok)
      wr_ok_r <= 1'b1;
    else if (st == S_IDLE)
      wr_ok_r <= 1'b0;
  end

endmodule
`default_nettype wire
