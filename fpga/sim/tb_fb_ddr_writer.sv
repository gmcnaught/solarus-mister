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

    // Backpressure injection: stall mem_accept for a run of cycles at two points
    // mid-stream (identified by write_count reaching a threshold), guarded so each
    // stall fires exactly once.
    reg stall1_done = 1'b0, stall2_done = 1'b0;
    integer stall_left = 0;

    always @(posedge clk) begin
        if (rst) begin
            mem_accept <= 1'b1;
            stall_left <= 0;
            stall1_done <= 1'b0; stall2_done <= 1'b0;
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
                end
            end
        end
    end

    reg [15:0] exp_k;
    reg [63:0] exp_data;
    always @(posedge clk) begin
        if (!rst) begin
            // capture on every accepted beat
            if (mem_wr && mem_accept) begin
                if (write_count == 0) first_addr <= mem_addr;
                last_addr <= mem_addr;
                exp_k    = mem_addr - base_qw;
                exp_data = {4{ {1'b0, exp_k[14:0]} }};
                if (mem_din !== exp_data) begin
                    data_matches_work_ramp <= 1'b0;
                    $display("FAIL: data mismatch at addr=%0d (k=%0d) got=%h want=%h",
                              mem_addr, exp_k, mem_din, exp_data);
                    errs = errs + 1;
                end
                if (mem_burstcnt == 8'd1) begin
                    burstcnt_ok <= 1'b0;
                    $display("FAIL: mem_burstcnt==1 on a multi-beat write (beat %0d)", write_count);
                    errs = errs + 1;
                end
                write_count = write_count + 1;
            end
            // "no write after done": once we've seen done rise, no FURTHER accepted
            // beat may ever occur.
            if (seen_done && mem_wr && mem_accept) begin
                no_write_after_done <= 1'b0;
                $display("FAIL: write accepted after done (addr=%0d)", mem_addr);
                errs = errs + 1;
            end
            if (done) begin
                done_pulses = done_pulses + 1;
                seen_done <= 1'b1;
                if (write_count != NQW) begin
                    done_after_full_drain <= 1'b0;
                    $display("FAIL: done rose with write_count=%0d (want %0d)", write_count, NQW);
                    errs = errs + 1;
                end
            end
        end
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
        if (!stall1_done || !stall2_done) begin
            $display("FAIL: backpressure injection did not fire (stall1=%0d stall2=%0d)",
                      stall1_done, stall2_done);
            errs = errs + 1;
        end

        if (errs == 0) $display("RESULT: PASS");
        else           $display("RESULT: FAIL (%0d errors)", errs);
        $finish;
    end

    initial begin #50000000; $display("RESULT: FAIL TIMEOUT"); $finish; end
endmodule
`default_nettype wire
