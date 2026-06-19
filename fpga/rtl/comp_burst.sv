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
  output reg           wr_take,
  output reg  [15:0]   wr_beat,
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

  initial begin
    state = S_IDLE; busy = 0; done = 0;
    rd_valid = 0; rd_qw = 0; rd_beat = 0;
    wr_take = 0; wr_beat = 0;
    mem_rd = 0; mem_wr = 0; mem_burstcnt = 8'd1;
    mem_addr = 0; mem_din = 0; mem_be = 0;
    beats_left = 0; beat_ix = 0;
  end

  always @(posedge clk) begin
    done     <= 1'b0;
    rd_valid <= 1'b0;
    wr_take  <= 1'b0;

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
          state      <= req_we ? S_WRLOAD : S_RDSETUP;
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

      // ══ WRITE PATH ═════════════════════════════════════════════════════════
      //
      // S_WRLOAD: Set wr_beat = beat_ix so the producer drives wr_qw = data[N].
      //           Keep mem_wr = 0 (DDR ignores this cycle; data not ready yet).
      //           Also initialise sub-burst counter when beats_left == 0.
      S_WRLOAD: begin
        wr_beat  <= beat_ix[15:0];   // NBA: visible NEXT cycle in S_WRARM
        mem_wr   <= 1'b0;
        mem_addr <= cur_addr;
        if (beats_left == 8'd0) begin
          // First beat of a new sub-burst: latch sub-burst size.
          beats_left   <= next_burst;
          mem_burstcnt <= next_burst;
        end
        state <= S_WRARM;
      end

      // S_WRARM: wr_beat is now stable (registered from S_WRLOAD).
      //          wr_qw = data[wr_beat] combinationally from producer.
      //          Latch wr_qw → mem_din, assert mem_wr = 1.
      S_WRARM: begin
        mem_din  <= wr_qw;   // capture correct data for this beat
        mem_be   <= wr_be;
        mem_wr   <= 1'b1;
        mem_addr <= cur_addr;
        state    <= S_WRWAIT;
      end

      // S_WRWAIT: mem_wr = 1 and mem_din = data[beat_ix] stable on bus.
      //           DDR writes this cycle if !mem_busy.
      //           Accept: fire wr_take, advance counters.
      S_WRWAIT: begin
        mem_addr <= cur_addr;  // hold
        if (!mem_busy) begin
          wr_take    <= 1'b1;
          beat_ix    <= beat_ix    + 17'd1;
          cur_addr   <= cur_addr   + {{(AW-1){1'b0}}, 1'b1};
          beats_left <= beats_left - 8'd1;
          rem        <= rem        - 16'd1;
          mem_wr     <= 1'b0;
          if (beats_left == 8'd1)
            state <= (rem == 16'd1) ? S_DONE : S_WRLOAD;
          else
            state <= S_WRLOAD;
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
