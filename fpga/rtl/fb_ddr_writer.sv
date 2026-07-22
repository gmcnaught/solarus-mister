// fb_ddr_writer.sv — Stage 5 Phase 2, Task 4.
//
// Vblank WORK->DDR3 snapshot burst writer. On a `start` pulse it streams the entire
// on-chip WORK framebuffer (a comp_fbram-style rd_en/rd_qw/rd_qword port, registered,
// 1-cyc latency) out to the DDR3 inactive buffer at `base_qw` (`FB_DDR0_QW`/
// `FB_DDR1_QW`) via a DDR write master (mem_wr/mem_addr/mem_din/mem_be/mem_burstcnt,
// mem_accept backpressure), one qword per beat: DDR[base_qw+k] = WORK[k], k=0..FB_QWORDS-1.
//
// FSM (S_IDLE -> S_ISSUE -> S_WAIT -> S_ARM [-> S_ISSUE | S_LASTWAIT] -> S_IDLE):
//   S_ISSUE: pulse rd_en/rd_qw = the next WORK index (rptr), advance rptr.
//   S_WAIT : one cycle for the address to be visible to the WORK port.
//   S_ARM  : rd_qword is now valid for that index. If the bus can take a beat
//            (mem_accept, or nothing outstanding yet) latch it into mem_din/mem_addr
//            and assert mem_wr; otherwise HOLD here (no new read is issued) until it
//            can. Only on a successful arm do we move on to issue the *next* read.
//   S_LASTWAIT: the final beat has been armed (no more WORK indices remain) — wait
//            here for its mem_accept, then drop mem_wr/busy.
//
// This deliberately does NOT prefetch a second WORK read ahead of the one currently
// armed. An earlier draft did ("issue read k+1 the same cycle beat k is armed") and it
// looked fine under continuous mem_accept, but broke under backpressure: the WORK read
// port is a single register (comp_fbram-style, updates whenever rd_en pulses,
// regardless of what our FSM thinks it's doing) — an already-in-flight "ahead" read
// lands on its own fixed 1-cycle schedule no matter how long the write side then
// stalls, silently overwriting rd_qword out from under a still-unconsumed beat before
// it could be latched into mem_din. Never issuing read k+1 until beat k is already
// safely captured in mem_din (not just "in rd_qword") removes that race entirely: at
// every moment at most one WORK read is in flight or freshly landed, and while parked
// in S_ARM waiting on backpressure, rd_en never re-pulses, so rd_qword cannot drift.
//
// mem_burstcnt is held at a constant 80 (one 320x240 RGB565 scanline of qwords) for
// the whole transfer to amortize DDR latency (line-granular burst) -- never 8'd1 for
// this multi-beat stream (the known "#1 burstcnt" bus-wedge class). `done` pulses
// combinationally the SAME cycle mem_accept accepts the FB_QWORDS-th (last) beat;
// no write is emitted after that cycle.
//
// Copyright (C) 2026 — GPL-3.0
`default_nettype none
module fb_ddr_writer #(
    parameter integer FB_QWORDS  = 19200,
    parameter integer AW         = 15,
    parameter integer LINE_BEATS = 80     // one scanline's worth of qwords (line-granular burst)
)(
    input  wire         clk, rst,
    input  wire         start,          // 1-cyc pulse (vblank): begin WORK->DDR3 burst
    input  wire [28:0]  base_qw,        // inactive-buffer base (DDR qword addr) = `FB_DDR0_QW or `FB_DDR1_QW
    output reg          busy,
    output reg          done,           // 1-cyc pulse when the LAST write is accepted (drained)
    output reg          rd_en,          // WORK read port (-> comp_fbram rd_*)
    output reg  [AW-1:0] rd_qw,
    input  wire [63:0]  rd_qword,       // registered, valid 1 cyc after rd_qw/rd_en
    output reg          mem_wr,         // DDR write master (Task 5 funnels onto blitter mem_* during snap)
    output reg  [28:0]  mem_addr,       // = base_qw + k
    output reg  [63:0]  mem_din,        // = WORK qword k
    output wire [7:0]   mem_be,         // 8'hFF
    output reg  [7:0]   mem_burstcnt,   // real burst length (NEVER 8'd1 for a multi-beat write)
    input  wire         mem_accept      // write accepted this cycle (bus ready; e.g. ~mem_busy)
);
    assign mem_be = 8'hFF;

    // Compile-time guard: FB_QWORDS must be an exact multiple of LINE_BEATS.
    // The FSM always arms a full LINE_BEATS-length burst (mem_burstcnt <=
    // LINE_BEATS, see S_ARM); if FB_QWORDS didn't divide evenly, the final
    // burst would be issued short of its declared beat count and the DDR
    // arbiter's burst-count handshake would never see it complete -- wedging
    // the arbiter (-> black screen) instead of failing anywhere visible.
    // Fail loudly here, at elaboration, instead of silently on hardware.
    initial begin
        if ((FB_QWORDS % LINE_BEATS) != 0) begin
            $fatal(1, "fb_ddr_writer: FB_QWORDS (%0d) must be an exact multiple of LINE_BEATS (%0d) -- a remainder leaves a short final burst that never completes its burst-count handshake and wedges the DDR arbiter", FB_QWORDS, LINE_BEATS);
        end
    end

    localparam [AW:0] NQW  = FB_QWORDS[AW:0];
    localparam [AW:0] ONE  = {{AW{1'b0}}, 1'b1};
    localparam [AW:0] LAST = NQW - ONE;          // pre-increment wcnt value on the final beat

    localparam [2:0] S_IDLE=3'd0, S_ISSUE=3'd1, S_WAIT=3'd2, S_ARM=3'd3, S_LASTWAIT=3'd4;
    reg [2:0]    state;
    reg [AW:0]   rptr;       // next WORK index to request a read for (0..NQW)
    reg [AW:0]   wcnt;       // qwords accepted so far (0..NQW)
    reg [AW-1:0] cur_idx;    // WORK index whose data is (about to be) in rd_qword

    // May latch a new beat onto the bus this cycle iff nothing is outstanding, or the
    // one currently asserted is being accepted right now.
    wire arm_ok = (!mem_wr) || mem_accept;

    // done: combinational so it pulses the SAME cycle mem_accept drains the final beat.
    always @(*) begin
        done = busy & mem_wr & mem_accept & (wcnt == LAST);
    end

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; busy <= 1'b0;
            rd_en <= 1'b0; rd_qw <= {AW{1'b0}}; cur_idx <= {AW{1'b0}};
            mem_wr <= 1'b0; mem_addr <= 29'd0; mem_din <= 64'd0; mem_burstcnt <= 8'd0;
            rptr <= {(AW+1){1'b0}}; wcnt <= {(AW+1){1'b0}};
        end else begin
            rd_en <= 1'b0;   // default: rd_en is a one-shot pulse, never held

            // Completion bookkeeping: independent of state, fires whenever whatever is
            // CURRENTLY asserted on mem_wr gets accepted this cycle. mem_wr is deasserted
            // by DEFAULT the instant it's consumed -- it must not sit high with stale
            // (already-written) addr/data for the S_ISSUE/S_WAIT cycles that follow, or
            // the bus (and any accept-counting logic) would see the same beat "accepted"
            // again on every subsequent cycle mem_accept happens to still be high. S_ARM
            // re-asserts it (below, textually later => wins) when it arms a genuinely new
            // beat, giving back-to-back beats with no bubble when the bus stays ready.
            if (mem_wr && mem_accept) begin
                wcnt   <= wcnt + ONE;
                mem_wr <= 1'b0;
            end

            case (state)
                S_IDLE: begin
                    mem_wr <= 1'b0;
                    if (start) begin
                        busy <= 1'b1; rptr <= {(AW+1){1'b0}}; wcnt <= {(AW+1){1'b0}};
                        state <= S_ISSUE;
                    end else begin
                        busy <= 1'b0;
                    end
                end

                S_ISSUE: begin
                    rd_en   <= 1'b1;
                    rd_qw   <= rptr[AW-1:0];
                    cur_idx <= rptr[AW-1:0];
                    rptr    <= rptr + ONE;
                    state   <= S_WAIT;
                end

                S_WAIT: begin
                    // address now visible to the WORK port; its data lands next cycle.
                    state <= S_ARM;
                end

                S_ARM: begin
                    // rd_qword is now valid == WORK[cur_idx].
                    if (arm_ok) begin
                        mem_wr       <= 1'b1;
                        mem_addr     <= base_qw + {{(29-AW){1'b0}}, cur_idx};
                        mem_din      <= rd_qword;
                        mem_burstcnt <= LINE_BEATS[7:0];
                        state        <= (rptr < NQW) ? S_ISSUE : S_LASTWAIT;
                    end
                    // else: hold — a prior beat is still outstanding (unaccepted); no
                    // new read is issued, so rd_qword cannot be disturbed while we wait.
                end

                S_LASTWAIT: begin
                    // Final beat armed (no more WORK indices remain); wait for its accept.
                    if (mem_accept) begin
                        mem_wr <= 1'b0;
                        busy   <= 1'b0;
                        state  <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
