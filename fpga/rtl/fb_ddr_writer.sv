// fb_ddr_writer.sv — Stage 5 Phase 2, Task 4 (rev 2: pipelined read + skid buffer).
//
// Vblank WORK->DDR3 snapshot burst writer. On a `start` pulse it streams the entire
// on-chip WORK framebuffer (a comp_fbram-style rd_en/rd_qw/rd_qword port, registered,
// 1-cyc latency) out to the DDR3 inactive buffer at `base_qw` (`FB_DDR0_QW`/
// `FB_DDR1_QW`) via a DDR write master (mem_wr/mem_addr/mem_din/mem_be/mem_burstcnt,
// mem_accept backpressure), one qword per beat: DDR[base_qw+k] = WORK[k], k=0..FB_QWORDS-1.
//
// ---- Why rev 1 (S_ISSUE->S_WAIT->S_ARM) was 3 cyc/beat ----
// The original FSM only issued WORK read k+1 AFTER beat k had been safely captured into
// mem_din (not merely into rd_qword), because the WORK read port is a single register
// (comp_fbram-style: it updates on EVERY rd_en pulse, unconditionally, on its own fixed
// 1-cycle schedule, no matter what our FSM/backpressure state is doing). An earlier
// prototype that issued read k+1 the same cycle beat k was armed looked fine under
// continuous mem_accept but broke under backpressure: the already-in-flight "ahead"
// read for k+1 lands regardless of whether beat k has been accepted yet, silently
// overwriting rd_qword out from under a still-unconsumed beat before it could be
// latched. Rev 1's fix (never issue read k+1 until beat k is already in mem_din) is
// race-safe but costs 2 idle cycles (S_WAIT, and any S_ARM stall) per beat.
//
// ---- Rev 2: pipelined reads drained through a small skid FIFO ----
// The race isn't inherent to reading ahead — it's inherent to reading ahead WITHOUT
// somewhere safe to put the result the instant it lands. So: keep exactly the same
// "rd_qword is a single register, 1-cyc latency, updates unconditionally on rd_en"
// contract, but the cycle immediately after a read is issued, unconditionally capture
// rd_qword into a small tagged skid FIFO (tag = the WORK index that read was for, so
// mem_addr can be reconstructed after buffering, independent of read/write timing).
// A read for index k+1 is only ISSUED (rd_en pulsed) once we can prove the FIFO will
// have a free slot ready for it the cycle it lands — i.e. gate new reads on FIFO
// occupancy, not on the write side being accepted. At most one WORK read is ever
// in flight (issue -> land is exactly 1 cycle, and we never issue a second one before
// the first's landing cycle), so there is never more than one pending capture to
// account for, and the capture is unconditional the cycle it's due: rd_qword can never
// be silently overwritten out from under an uncaptured value. This is the same
// race-safety property rev 1 relied on, just enforced against the FIFO's free space
// instead of against the bus.
//
// The DDR write side independently drains the FIFO head onto mem_wr/mem_addr/mem_din
// whenever the bus can take a new beat (mem_wr deasserted, or the current one is being
// accepted this very cycle) — this is decoupled from the read side entirely, so reads
// keep flowing even while a write is stalled (up to the FIFO's depth), and under
// continuous mem_accept, a read is issued AND a write is accepted every single cycle:
// steady-state throughput is 1 qword/cycle (vs. rev 1's 1 qword/3 cycles).
//
// FIFO depth = 4. The minimum needed to never bubble the read pipeline is 2 (one slot
// draining while the next lands), since only one read is ever in flight; 4 gives a
// couple of cycles of slack so a short mem_accept stall doesn't immediately stall new
// WORK reads too (it only does so once all 4 slots are backed up) — cheap (4x(15+64)
// bits of registers) and comfortably covers real DDR arbiter stall bursts without
// growing into a second, harder-to-reason-about resource.
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
    localparam [AW:0] LAST = NQW - ONE;          // wcnt value (pre-increment) on the final beat

    // ---- Skid FIFO: holds WORK reads that have landed but not yet been written ----
    localparam integer DEPTH = 4;
    reg [AW-1:0] fifo_idx  [0:DEPTH-1];
    reg [63:0]   fifo_data [0:DEPTH-1];
    reg [1:0]    fifo_head, fifo_tail;   // DEPTH==4 -> 2-bit wraparound pointers
    reg [2:0]    fifo_cnt;               // 0..DEPTH occupancy

    wire fifo_empty = (fifo_cnt == 3'd0);

    // Bus can accept a newly-armed beat this cycle iff nothing is outstanding, or the
    // one currently asserted is being accepted right now (same test as rev 1's arm_ok).
    wire bus_ready = (!mem_wr) || mem_accept;

    // Read-side pipeline register: rd_qword is valid THIS cycle for pend_idx iff a read
    // was issued (rd_en pulsed) last cycle. Exactly mirrors the WORK port's own 1-cycle
    // registered latency, so "pend_valid" tells us precisely when to capture.
    reg          pend_valid;
    reg [AW-1:0] pend_idx;
    reg [AW:0]   rptr;   // next WORK index to request a read for (0..NQW)
    reg [AW:0]   wcnt;   // qwords accepted so far (0..NQW)

    // This cycle's FIFO traffic:
    wire push = pend_valid;                 // land rd_qword (for pend_idx) into the tail
    wire pop  = !fifo_empty && bus_ready;    // drain the head onto the bus
    wire [2:0] next_fifo_cnt = fifo_cnt + (push ? 3'd1 : 3'd0) - (pop ? 3'd1 : 3'd0);

    // Only issue a new WORK read if the FIFO is guaranteed to have room for it when it
    // lands next cycle. next_fifo_cnt is the occupancy the FIFO will have ENTERING next
    // cycle (after this cycle's own push/pop) -- but a read already in flight right now
    // (rd_en currently 1, issued last cycle, not yet landed) is a SEPARATE, already-
    // committed demand for a slot one cycle after that: it lands and pushes next cycle
    // regardless of what we decide here, and next_fifo_cnt does not yet include it (its
    // push hasn't happened -- pend_valid/push above reflect a read that landed on a
    // PRIOR cycle, not this one). Back-to-back issuing means this in-flight slot is
    // real: e.g. issue idx=6 (rd_en=1), then issue idx=7 the very next cycle while idx=6
    // is still only pend_valid (about to push THIS cycle) -- by the time idx=7 lands, an
    // extra push (from whatever is rd_en right now) may already have consumed the slot
    // this check thought was free. Reserving +1 for a currently-outstanding rd_en fixes
    // that exact one-slot undercount (found via a period-3-busy repro: without it, a
    // FIFO entry still awaiting drain gets silently clobbered under sustained
    // backpressure). rd_en is a single bit here because the WORK port's read latency is
    // contractually fixed at exactly 1 cycle -- never generalize this into a wider
    // "in-flight count" without re-deriving it if that latency ever changes.
    wire [2:0] reserved      = next_fifo_cnt + (rd_en ? 3'd1 : 3'd0);
    wire       issue_new     = busy && (rptr < NQW) && (reserved < DEPTH[2:0]);

    // done: combinational so it pulses the SAME cycle mem_accept drains the final beat.
    always @(*) begin
        done = busy & mem_wr & mem_accept & (wcnt == LAST);
    end

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            rd_en <= 1'b0; rd_qw <= {AW{1'b0}};
            // mem_burstcnt never varies across a transfer -- set once here and never
            // touched elsewhere, so it just holds LINE_BEATS forever (avoids a
            // sensitivity-free `always @(*)` on a parameter-only expression).
            mem_burstcnt <= LINE_BEATS[7:0];
            mem_wr <= 1'b0; mem_addr <= 29'd0; mem_din <= 64'd0;
            rptr <= {(AW+1){1'b0}}; wcnt <= {(AW+1){1'b0}};
            pend_valid <= 1'b0; pend_idx <= {AW{1'b0}};
            fifo_head <= 2'd0; fifo_tail <= 2'd0; fifo_cnt <= 3'd0;
        end else begin
            rd_en <= 1'b0;   // default: rd_en is a one-shot pulse, never held

            // Completion bookkeeping: independent of everything else below, fires
            // whenever whatever is CURRENTLY asserted on mem_wr gets accepted this
            // cycle. mem_wr is deasserted by DEFAULT the instant it's consumed -- it
            // must not sit high with stale (already-written) addr/data for cycles that
            // follow, or the bus would see the same beat "accepted" again on every
            // subsequent cycle mem_accept happens to still be high. The FIFO-pop logic
            // below (textually later => wins) re-asserts it when it arms a genuinely
            // new beat, giving back-to-back beats with no bubble when the bus stays
            // ready -- this is the same hazard/fix rev 1 documented, unchanged.
            if (mem_wr && mem_accept) begin
                wcnt   <= wcnt + ONE;
                mem_wr <= 1'b0;
            end

            if (start && !busy) begin
                busy       <= 1'b1;
                rptr       <= {(AW+1){1'b0}};
                wcnt       <= {(AW+1){1'b0}};
                pend_valid <= 1'b0;
                fifo_head  <= 2'd0;
                fifo_tail  <= 2'd0;
                fifo_cnt   <= 3'd0;
                mem_wr     <= 1'b0;
            end else if (busy) begin
                // --- drain: pop the FIFO head onto the bus if it's ready for a new beat ---
                if (pop) begin
                    mem_wr    <= 1'b1;
                    mem_addr  <= base_qw + {{(29-AW){1'b0}}, fifo_idx[fifo_head]};
                    mem_din   <= fifo_data[fifo_head];
                    fifo_head <= fifo_head + 2'd1;
                end

                // --- capture: land last cycle's read (if any) into the FIFO tail ---
                if (push) begin
                    fifo_idx[fifo_tail]  <= pend_idx;
                    fifo_data[fifo_tail] <= rd_qword;
                    fifo_tail            <= fifo_tail + 2'd1;
                end

                fifo_cnt <= next_fifo_cnt;

                // --- issue: start the next WORK read now that we know it'll fit ---
                if (issue_new) begin
                    rd_en <= 1'b1;
                    rd_qw <= rptr[AW-1:0];
                    rptr  <= rptr + ONE;
                end
                // pend_valid/pend_idx must land in lockstep with rd_qword itself -- both
                // are driven, at this very edge, from the OLD (pre-edge) rd_en/rd_qw, so
                // both become visible one cycle from now, together. Tagging from
                // `issue_new`/`rptr` (this cycle's NEW decision) instead would fire a
                // cycle too early, one full cycle ahead of rd_qword actually landing.
                pend_valid <= rd_en;
                pend_idx   <= rd_qw;

                if (done) begin
                    busy <= 1'b0;
                end
            end
        end
    end
endmodule
`default_nettype wire
