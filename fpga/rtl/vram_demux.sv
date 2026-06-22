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
// Write flow (S_IDLE -> S_WOKWAIT -> S_IDLE), one request per sd_ok:
//   S_IDLE:    for a FRESH qword (qw != acc_qw) assert sd_wr + latch
//              addr/din/wdsn; blt_busy high this cycle; -> S_WOKWAIT.
//   S_WOKWAIT: hold sd_wr (=~sd_ok) until sd_ok; blt_busy=~sd_ok so it drops on
//              the accept cycle (producer advances). sd_ok -> S_IDLE; a pending
//              different-qword write (blt_wr held, new addr) issues next cycle.
//              A held blt_wr at the just-written qword does NOT re-fire (guard).
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

  assign dbg = {rd_on_sdram, st};

  // A new FB write is one whose qword differs from the write we just issued
  // (acc_qw). The producer (comp_burst) drops blt_wr between distinct writes
  // and its write-back addresses strictly increase, so a fresh write always
  // has qw != acc_qw; holding blt_wr at the SAME qword (tb cadence after a
  // completed write) must NOT re-fire. This is the qw!=acc_qw invariant the
  // legacy SDRAM path also relied on.
  wire new_fb_wr = is_fb & blt_wr & (qw != acc_qw);

  // ---------------------------------------------------------------------------
  // blt_dout / blt_dout_ready
  // ---------------------------------------------------------------------------
  assign blt_dout       = rd_on_sdram ? sd_dout        : ddr_dout;
  assign blt_dout_ready = rd_on_sdram ? sd_ok          : ddr_dout_ready;

  // ---------------------------------------------------------------------------
  // blt_busy
  // ---------------------------------------------------------------------------
  // S_RDLAT:       busy for the entire read sequence (per-beat; waiting sd_ok).
  // S_IDLE issue:  busy combinationally the cycle a new FB write is presented,
  //                so comp_burst's S_WRWAIT does not mistake the issue cycle for
  //                an immediate accept.
  // S_WOKWAIT:     busy while the write is in flight; drops on sd_ok so the
  //                producer advances to the next qword (one-cycle accept window).
  // S_IDLE/DDR:    DDR back-pressure.
  assign blt_busy =
      (st == S_RDLAT)
    | ((st == S_IDLE) & new_fb_wr)
    | ((st == S_WOKWAIT) & ~sd_ok)
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
          end else if (new_fb_wr) begin
            // Fire only for a fresh qword (qw != acc_qw); a held blt_wr at the
            // just-completed qword must not re-fire.
            sd_wr   = 1'b1;
            sd_addr = qw_byte;
            sd_din  = blt_din;
            sd_wdsn = ~blt_be;
          end
        end
      end

      S_WOKWAIT: begin
        // Hold sd_wr with latched values until sd_ok; drop sd_wr ON the sd_ok
        // cycle so the next write gets a clean rising edge (one request per ok).
        sd_wr   = ~sd_ok;
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
            if (blt_rd)        st <= S_RDLAT;
            else if (new_fb_wr) st <= S_WOKWAIT;
          end
        end

        S_RDLAT: begin
          if (sd_ok && rd_beats_left == 8'd0)
            st <= S_IDLE;
          // else stay in S_RDLAT for the next beat
        end

        S_WOKWAIT: begin
          // Write accepted on sd_ok -> return to S_IDLE so a pending different
          // -qword write (blt_wr held, new addr) issues next cycle.
          if (sd_ok) st <= S_IDLE;
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
    else if (st == S_IDLE && new_fb_wr)
      acc_qw <= qw;
  end

  // ---------------------------------------------------------------------------
  // wr_addr_r — own always-block
  // ---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (reset)
      wr_addr_r <= 27'd0;
    else if (st == S_IDLE && new_fb_wr)
      wr_addr_r <= qw_byte;
  end

  // ---------------------------------------------------------------------------
  // wr_din_r — own always-block
  // ---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (reset)
      wr_din_r <= 64'd0;
    else if (st == S_IDLE && new_fb_wr)
      wr_din_r <= blt_din;
  end

  // ---------------------------------------------------------------------------
  // wr_wdsn_r — own always-block
  // ---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (reset)
      wr_wdsn_r <= 8'hFF;
    else if (st == S_IDLE && new_fb_wr)
      wr_wdsn_r <= ~blt_be;
  end

endmodule
`default_nettype wire
