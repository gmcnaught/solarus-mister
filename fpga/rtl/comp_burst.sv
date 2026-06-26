// comp_burst.sv — bounded-length sequential burst master for the compositor.
// Copyright (C) 2026 — GPL-3.0
//
// Turns a {req_addr, req_len, req_we} transfer request from comp_pipeline into
// aligned sequential bursts on the mem_* master, split into sub-bursts of at
// most MAXBURST beats so the arbiter never has to hold the f2h bus away from the
// video reader for longer than MAXBURST beats (reader-never-starve). Reads stream
// returned qwords out on rd_valid/rd_qw with a running rd_beat index; writes pull
// qwords in via wr_take/wr_beat. Shallow by design to protect fmax.
//
// Write beat sequencing
// ─────────────────────
// mem_din and mem_wr are registered outputs; the DDR model samples them one
// posedge AFTER comp_burst computes them.  To guarantee each beat is written
// with correct data and address, each write beat goes through three phases:
//
//   S_WRLOAD: set wr_beat = beat_ix (registered → visible next cycle),
//             mem_wr = 0 (DDR ignores this cycle).
//   S_WRARM : wr_beat is now stable → wr_qw = data[beat_ix].
//             latch mem_din = wr_qw and assert mem_wr = 1.
//   S_WRWAIT: mem_wr = 1 and mem_din = data[beat_ix] are both stable on the
//             bus.  Sample !mem_busy; DDR writes this cycle if not busy.
//             Fire wr_take, advance beat_ix / cur_addr / rem / beats_left.
`default_nettype none
module comp_burst #(parameter AW = 32, parameter MAXBURST = 16) (
  input  wire          clk, rst,
  input  wire          req, req_we,
  input  wire [AW-1:0] req_addr,
  input  wire [15:0]   req_len,
  output reg           busy, done,
  output reg           rd_valid,
  output reg  [63:0]   rd_qw,
  output reg  [15:0]   rd_beat,
  output wire          wr_take,
  output wire [15:0]   wr_beat,
  input  wire [63:0]   wr_qw,
  input  wire [7:0]    wr_be,
  output reg  [AW-1:0] mem_addr,
  output reg           mem_rd, mem_wr,
  output reg  [7:0]    mem_burstcnt,
  output reg  [63:0]   mem_din,
  output reg  [7:0]    mem_be,
  input  wire [63:0]   mem_dout,
  input  wire          mem_dout_ready,
  input  wire          mem_busy
);
  localparam [3:0]
    S_IDLE    = 4'd0,
    S_RDSETUP = 4'd1,
    S_RDISSUE = 4'd2,
    S_RDBEATS = 4'd3,
    S_WRLOAD  = 4'd4,
    S_WRARM   = 4'd5,
    S_WRWAIT  = 4'd6,
    S_DONE    = 4'd7;

  reg [3:0]    state;
  reg          dir_we;
  reg [AW-1:0] cur_addr;
  reg [15:0]   rem;          // beats remaining in the whole transfer
  reg [7:0]    beats_left;   // beats remaining in current sub-burst (0 = start new)
  reg [16:0]   beat_ix;      // global beat index (0..req_len-1), one extra bit

  wire [7:0] next_burst = (rem > 16'(MAXBURST)) ? 8'(MAXBURST) : rem[7:0];

  // wr_beat is COMBINATIONAL (the live global beat index). The old write path
  // registered it in S_WRLOAD and spent a cycle letting it settle before the
  // producer drove wr_qw; making it combinational removes that cycle (see the
  // 2-phase write path below). Indexed producers (tb_comp_burst) read it directly;
  // comp_pipeline ignores it (ordering-based FIFO head).
  assign wr_beat = beat_ix[15:0];

  // wr_take is COMBINATIONAL "this beat is accepted THIS cycle" (S_WRWAIT & !busy).
  // It used to be a registered pulse, which cost the FIFO-head producer an extra
  // cycle to advance (wr_take_reg → f_rptr → wr_qw → mem_din = 2 hops). Asserting it
  // combinationally lets comp_pipeline advance f_rptr the same cycle the beat is
  // accepted, so the next beat's data is ready in the following S_WRARM — the head-
  // advance latency the old 3rd phase (S_WRLOAD) used to hide. f_rptr is registered,
  // so there is no combinational loop.
  assign wr_take = (state == S_WRWAIT) && !mem_busy;

  initial begin
    state = S_IDLE; busy = 0; done = 0;
    rd_valid = 0; rd_qw = 0; rd_beat = 0;
    mem_rd = 0; mem_wr = 0; mem_burstcnt = 8'd1;
    mem_addr = 0; mem_din = 0; mem_be = 0;
    beats_left = 0; beat_ix = 0;
  end

  always @(posedge clk) begin
    done     <= 1'b0;
    rd_valid <= 1'b0;

    if (rst) begin
      state <= S_IDLE; busy <= 1'b0;
      mem_rd <= 1'b0; mem_wr <= 1'b0; mem_burstcnt <= 8'd1;
      beats_left <= 8'd0;
    end else case (state)

      // ── IDLE ──────────────────────────────────────────────────────────────
      S_IDLE: begin
        mem_rd <= 1'b0; mem_wr <= 1'b0;
        if (req) begin
          busy       <= 1'b1;
          dir_we     <= req_we;
          cur_addr   <= req_addr;
          rem        <= req_len;
          beat_ix    <= 17'd0;
          beats_left <= 8'd0;    // signal: start of first sub-burst
          state      <= req_we ? S_WRARM : S_RDSETUP;
        end else begin
          busy <= 1'b0;
        end
      end

      // ══ READ PATH ══════════════════════════════════════════════════════════

      S_RDSETUP: begin
        mem_addr     <= cur_addr;
        mem_burstcnt <= next_burst;
        beats_left   <= next_burst;
        mem_rd       <= 1'b1;
        state        <= S_RDISSUE;
      end

      S_RDISSUE: begin
        if (!mem_busy) begin
          mem_rd <= 1'b0;
          state  <= S_RDBEATS;
        end
      end

      S_RDBEATS: begin
        if (mem_dout_ready) begin
          rd_valid   <= 1'b1;
          rd_qw      <= mem_dout;
          rd_beat    <= beat_ix[15:0];
          beat_ix    <= beat_ix + 17'd1;
          cur_addr   <= cur_addr + {{(AW-1){1'b0}}, 1'b1};
          beats_left <= beats_left - 8'd1;
          rem        <= rem - 16'd1;
          if (beats_left == 8'd1)
            state <= (rem == 16'd1) ? S_DONE : S_RDSETUP;
        end
      end

      // ══ WRITE PATH (2-phase: ARM presents the beat, WAIT observes accept) ════
      //
      // Collapsed from the old 3-phase LOAD→ARM→WAIT. The LOAD cycle existed only to
      // let a REGISTERED wr_beat settle before the producer drove wr_qw; wr_beat is
      // now combinational (= beat_ix, assigned above), so ARM can capture wr_qw the
      // same cycle. 2 cyc/beat instead of 3 — write-back is ~37–49% of blit cycles
      // (tb_profile). 1 cyc/beat is not reachable here without a skid buffer: the
      // FIFO-head producer only advances the cycle AFTER wr_take, so the next beat's
      // data is not available in the accept cycle.
      //
      // S_WRARM: size the sub-burst on its first beat (beats_left==0), capture the
      //          producer's data (wr_qw = data[wr_beat]) into mem_din, assert mem_wr.
      S_WRARM: begin
        if (beats_left == 8'd0) begin
          // First beat of a new sub-burst: latch sub-burst size.
          beats_left   <= next_burst;
          mem_burstcnt <= next_burst;
        end
        mem_din  <= wr_qw;   // capture correct data for this beat (combinational wr_beat)
        mem_be   <= wr_be;
        mem_wr   <= 1'b1;
        mem_addr <= cur_addr;
        state    <= S_WRWAIT;
      end

      // S_WRWAIT: mem_wr = 1 and mem_din = data[beat_ix] stable on bus.
      //           DDR writes this cycle if !mem_busy.
      //           Accept: fire wr_take, advance counters, go straight to ARM for the
      //           next beat (or DONE).  mem_busy=1: hold (registered mem_wr/din/addr).
      S_WRWAIT: begin
        mem_addr <= cur_addr;  // hold
        if (!mem_busy) begin
          beat_ix    <= beat_ix    + 17'd1;
          cur_addr   <= cur_addr   + {{(AW-1){1'b0}}, 1'b1};
          beats_left <= beats_left - 8'd1;
          rem        <= rem        - 16'd1;
          mem_wr     <= 1'b0;
          if (beats_left == 8'd1)
            state <= (rem == 16'd1) ? S_DONE : S_WRARM;
          else
            state <= S_WRARM;
        end
        // mem_busy=1: stay, registered values hold mem_wr=1, mem_din, mem_addr
      end

      // ── DONE ──────────────────────────────────────────────────────────────
      S_DONE: begin
        mem_rd <= 1'b0; mem_wr <= 1'b0;
        done   <= 1'b1;
        busy   <= 1'b0;
        state  <= S_IDLE;
      end

      default: state <= S_IDLE;
    endcase
  end
endmodule
`default_nettype wire
