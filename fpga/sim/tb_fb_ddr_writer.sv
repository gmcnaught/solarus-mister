// tb_fb_ddr_writer.sv — Stage 5 Phase 2, Task 4.
//
// Unit test for fb_ddr_writer: the vblank WORK->DDR3 snapshot burst writer. Drives a
// behavioral WORK-read model (qword k = {4{k[15:0]}}, registered/enable-gated like
// comp_fbram's real rd_en/rd_qw/rd_qword port) and a behavioral DDR write-sink model
// that captures (mem_addr, mem_din) on every ACCEPTED beat and can inject backpressure
// by deasserting mem_accept for a run of cycles mid-stream. Asserts:
//   - exactly FB_QWORDS writes captured
//   - first/last address bracket base_qw .. base_qw+FB_QWORDS-1
//   - every captured qword's data matches the WORK ramp for its address
//   - done rises only once, only after all FB_QWORDS writes are in
//   - no write is captured after done
//   - mem_burstcnt is never 8'd1 for this multi-beat stream (the "#1 burstcnt" wedge class)
// Copyright (C) 2026 — GPL-3.0
`timescale 1ns/1ps
`default_nettype none
`include "../rtl/vram_defs.vh"

module tb_fb_ddr_writer;
    localparam integer AW = 15;
    localparam integer NQW = `FB_QWORDS;   // 19200

    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;

    reg         start = 0;
    reg [28:0]  base_qw = 29'd0;
    wire        busy, done;

    // WORK read port (fb_ddr_writer -> this behavioral model)
    wire        rd_en;
    wire [AW-1:0] rd_qw;
    reg  [63:0] rd_qword = 64'd0;

    // DDR write master (fb_ddr_writer -> this behavioral sink)
    wire        mem_wr;
    wire [28:0] mem_addr;
    wire [63:0] mem_din;
    wire [7:0]  mem_be;
    wire [7:0]  mem_burstcnt;
    reg         mem_accept = 1'b1;

    // Free-running cycle counter used only to time the phase-2 throughput run below
    // (start-to-done cycle count under continuous mem_accept).
    reg [31:0] cyc_count = 32'd0;
    always @(posedge clk) begin
        if (rst) cyc_count <= 32'd0;
        else     cyc_count <= cyc_count + 32'd1;
    end

    fb_ddr_writer #(.FB_QWORDS(NQW), .AW(AW)) dut (
        .clk(clk), .rst(rst),
        .start(start), .base_qw(base_qw),
        .busy(busy), .done(done),
        .rd_en(rd_en), .rd_qw(rd_qw), .rd_qword(rd_qword),
        .mem_wr(mem_wr), .mem_addr(mem_addr), .mem_din(mem_din),
        .mem_be(mem_be), .mem_burstcnt(mem_burstcnt),
        .mem_accept(mem_accept)
    );

    // ---- WORK-read model: registered, enable-gated, 1-cyc latency, ramp pattern ----
    // qword k -> {4{k[15:0]}} (zero-extend the 15-bit index to 16 bits, replicate x4).
    always @(posedge clk) if (rd_en) rd_qword <= {4{ {1'b0, rd_qw} }};

    // ---- DDR write-sink model: captures accepted beats, can inject backpressure ----
    integer write_count = 0;
    reg [28:0] first_addr = 29'd0;
    reg [28:0] last_addr  = 29'd0;
    integer errs = 0;
    reg data_matches_work_ramp = 1'b1;
    reg no_write_after_done = 1'b1;
    reg burstcnt_ok = 1'b1;
    reg done_after_full_drain = 1'b1;
    integer done_pulses = 0;
    reg seen_done = 1'b0;

    // Backpressure injection: stall mem_accept for a run of cycles at several points
    // mid-stream (identified by write_count reaching a threshold), guarded so each
    // stall fires exactly once. stall1/stall2 are arbitrary mid-stream points (not
    // burst-boundary-aligned); stall3 lands exactly on a LINE_BEATS (80) burst
    // boundary; stall4 lands on the very LAST beat (write_count == NQW-1, i.e. the
    // 19200th/final accept is what gets stalled) -- the rev-2 skid design must not
    // lose or duplicate that beat, and `done` must still pulse exactly once, only
    // after the stall clears and the final beat is actually accepted.
    reg stall1_done = 1'b0, stall2_done = 1'b0, stall3_done = 1'b0, stall4_done = 1'b0;
    integer stall_left = 0;
    localparam integer LINE_BEATS_TB = 80;  // matches dut's default LINE_BEATS param (not overridden below)
    localparam integer BOUNDARY_WC = (NQW / LINE_BEATS_TB) * LINE_BEATS_TB / 2; // mid-stream, 80-aligned

    always @(posedge clk) begin
        if (rst) begin
            mem_accept <= 1'b1;
            stall_left <= 0;
            stall1_done <= 1'b0; stall2_done <= 1'b0;
            stall3_done <= 1'b0; stall4_done <= 1'b0;
        end else begin
            if (stall_left > 0) begin
                mem_accept <= 1'b0;
                stall_left <= stall_left - 1;
            end else begin
                mem_accept <= 1'b1;
                if (!stall1_done && write_count == 100) begin
                    stall_left <= 6; stall1_done <= 1'b1;
                end else if (!stall2_done && write_count == 15000) begin
                    stall_left <= 11; stall2_done <= 1'b1;
                end else if (!stall3_done && write_count == BOUNDARY_WC) begin
                    stall_left <= 5; stall3_done <= 1'b1;
                end else if (!stall4_done && write_count == (NQW - 1)) begin
                    stall_left <= 8; stall4_done <= 1'b1;
                end
            end
        end
    end

    // Pure combinational -- mem_addr/base_qw are stable signals sampled at the
    // clock edge, so pulling these out as continuous assigns reproduces exactly
    // the value the old blocking-= temp held at that same instant.
    wire [15:0] exp_k    = mem_addr - base_qw;
    wire [63:0] exp_data = {4{ {1'b0, exp_k[14:0]} }};

    // Combinational per-cycle event flags. Kept out of the clocked block so the
    // done-cycle drain check can see "what write_count becomes THIS cycle"
    // without a same-cycle read-after-(nonblocking)write hazard: fb_ddr_writer's
    // `done` pulses combinationally on the SAME cycle the last beat is accepted
    // (see its header comment), so write_count's bump and the done-time drain
    // check land in the same clock edge -- next_write_count (not write_count)
    // is what the original blocking code effectively compared here.
    wire        beat_accepted    = mem_wr && mem_accept;
    wire        cond_data_bad    = beat_accepted && (mem_din !== exp_data);
    wire        cond_burst_bad   = beat_accepted && (mem_burstcnt == 8'd1);
    wire        cond_late_write  = seen_done && beat_accepted;
    wire [31:0] next_write_count = write_count + (beat_accepted ? 32'd1 : 32'd0);
    wire        cond_drain_bad   = done && (next_write_count != NQW);

    // Scopes the phase-1 correctness checker (write_count/first_addr/last_addr/
    // no_write_after_done/done_pulses/seen_done and the errs it feeds) to phase 1
    // only. Phase 2 below issues a second, entirely legitimate `start`...`done`
    // transfer purely to time it; without this gate the phase-1 checker (which
    // latches `seen_done` forever) would misread phase 2's own accepted beats and
    // `done` pulse as "writes after done" / "done pulsed twice" -- a test-harness
    // bug, not a DUT bug. Phase 2 has its own independent, self-contained checks.
    reg phase1_window = 1'b1;

    always @(posedge clk) begin
        if (!rst && phase1_window) begin
            // capture on every accepted beat
            if (beat_accepted) begin
                if (write_count == 0) first_addr <= mem_addr;
                last_addr <= mem_addr;
                if (cond_data_bad) begin
                    data_matches_work_ramp <= 1'b0;
                    $display("FAIL: data mismatch at addr=%0d (k=%0d) got=%h want=%h",
                              mem_addr, exp_k, mem_din, exp_data);
                end
                if (cond_burst_bad) begin
                    burstcnt_ok <= 1'b0;
                    $display("FAIL: mem_burstcnt==1 on a multi-beat write (beat %0d)", write_count);
                end
                write_count <= next_write_count;
            end
            // "no write after done": once we've seen done rise, no FURTHER accepted
            // beat may ever occur.
            if (cond_late_write) begin
                no_write_after_done <= 1'b0;
                $display("FAIL: write accepted after done (addr=%0d)", mem_addr);
            end
            if (done) begin
                done_pulses <= done_pulses + 1;
                seen_done <= 1'b1;
                if (cond_drain_bad) begin
                    done_after_full_drain <= 1'b0;
                    $display("FAIL: done rose with write_count=%0d (want %0d)", next_write_count, NQW);
                end
            end
            // Sum every condition that fired THIS cycle (rather than four separate
            // `errs <= errs + 1` statements, which -- same-time-step nonblocking
            // semantics -- would only ever apply the LAST one and silently drop
            // simultaneous failures).
            errs <= errs + cond_data_bad + cond_burst_bad + cond_late_write + cond_drain_bad;
        end
    end

    // Phase-2 (continuous-mem_accept throughput) measurement state.
    reg [31:0] t2_start, t2_done;
    integer    cycles2;
    reg        phase2_window = 1'b0;
    reg        phase2_bp_seen = 1'b0;
    always @(posedge clk) begin
        if (rst) phase2_bp_seen <= 1'b0;
        else if (phase2_window && !mem_accept) phase2_bp_seen <= 1'b1;
    end

    integer guard;
    initial begin
        @(negedge clk); rst <= 0; @(negedge clk);

        base_qw = `FB_DDR1_QW;
        @(negedge clk); start <= 1; @(negedge clk); start <= 0;

        if (!busy) begin $display("FAIL: busy did not assert after start"); errs = errs + 1; end

        guard = 0;
        while (!seen_done) begin
            @(negedge clk); guard = guard + 1;
            if (guard > 200000) begin
                $display("RESULT: FAIL (TIMEOUT waiting for done, write_count=%0d)", write_count);
                $finish;
            end
        end
        // drain a few more cycles to make sure nothing sneaks out after done
        repeat (20) @(negedge clk);

        if (write_count !== NQW) begin
            $display("FAIL: write_count=%0d want %0d", write_count, NQW); errs = errs + 1;
        end
        if (first_addr !== `FB_DDR1_QW) begin
            $display("FAIL: first_addr=%0d want %0d", first_addr, `FB_DDR1_QW); errs = errs + 1;
        end
        if (last_addr !== (`FB_DDR1_QW + 29'd19199)) begin
            $display("FAIL: last_addr=%0d want %0d", last_addr, `FB_DDR1_QW + 29'd19199); errs = errs + 1;
        end
        if (!data_matches_work_ramp) begin
            $display("FAIL: data_matches_work_ramp false"); errs = errs + 1;
        end
        if (!done_after_full_drain) begin
            $display("FAIL: done rose before full drain"); errs = errs + 1;
        end
        if (done_pulses !== 1) begin
            $display("FAIL: done pulsed %0d times, want 1", done_pulses); errs = errs + 1;
        end
        if (!no_write_after_done) begin
            $display("FAIL: a write was accepted after done"); errs = errs + 1;
        end
        if (!burstcnt_ok) begin
            $display("FAIL: mem_burstcnt==1 seen on a multi-beat write"); errs = errs + 1;
        end
        if (!stall1_done || !stall2_done || !stall3_done || !stall4_done) begin
            $display("FAIL: backpressure injection did not fire (stall1=%0d stall2=%0d stall3=%0d stall4=%0d)",
                      stall1_done, stall2_done, stall3_done, stall4_done);
            errs = errs + 1;
        end

        // ---- Phase 2: continuous-mem_accept throughput measurement ----
        // Proves the rev-2 (pipelined-read + skid-buffer) redesign's central claim:
        // under a bus that never stalls, the whole FB_QWORDS-beat transfer drains in
        // roughly FB_QWORDS cycles (~1 beat/cycle), not the rev-1 FSM's ~3*FB_QWORDS
        // (S_ISSUE->S_WAIT->S_ARM per qword). By this point in the test both
        // backpressure-injection guards (stall1_done..stall4_done) have already
        // latched, so the driver block above no longer stalls mem_accept for the rest
        // of the run -- this second transfer is genuinely backpressure-free, not just
        // assumed to be; phase2_bp_seen (below) double-checks that at runtime so the
        // assertion can never pass vacuously.
        phase1_window = 1'b0;
        base_qw = `FB_DDR0_QW;
        @(negedge clk);
        t2_start = cyc_count;
        phase2_window <= 1'b1;
        start <= 1; @(negedge clk); start <= 0;

        guard = 0;
        while (!done) begin
            @(negedge clk); guard = guard + 1;
            if (guard > 200000) begin
                $display("RESULT: FAIL (TIMEOUT phase2 waiting for done)");
                $finish;
            end
        end
        t2_done = cyc_count;
        phase2_window <= 1'b0;
        @(negedge clk); // let phase2_window's deassertion register before we read it

        cycles2 = t2_done - t2_start;
        $display("INFO: phase2 (continuous mem_accept) start->done = %0d cycles (budget <= %0d)",
                  cycles2, NQW + 64);

        if (phase2_bp_seen) begin
            $display("FAIL: phase2 throughput window saw mem_accept deasserted -- measurement invalid");
            errs = errs + 1;
        end
        if (cycles2 > NQW + 64) begin
            $display("FAIL: phase2 throughput budget exceeded: %0d cycles > %0d (FB_QWORDS+64)",
                      cycles2, NQW + 64);
            errs = errs + 1;
        end
        if (cycles2 < NQW) begin
            $display("FAIL: phase2 completed in fewer cycles than beats written (%0d < %0d) -- impossible, TB bug",
                      cycles2, NQW);
            errs = errs + 1;
        end

        if (errs == 0) $display("RESULT: PASS");
        else           $display("RESULT: FAIL (%0d errors)", errs);
        $finish;
    end

    initial begin #50000000; $display("RESULT: FAIL TIMEOUT"); $finish; end
endmodule
`default_nettype wire
