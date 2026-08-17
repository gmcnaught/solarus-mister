// tb_early_restart_ab.sv — A/B of the cache fill-front comparator (EARLY).
//
// Two INDEPENDENT stacks (sdram_fb_cache + jtframe_burst_sdram + mt48 model),
// identical except SRC_EARLY, each driven by an identical copy of
// comp_pipeline's F_WALK issue logic (one outstanding, pulse p0_rd, re-issue on
// p0_ok, PAL8 dedup on the odd beat). Same span, same addresses, same order.
//
//   OFF: stock jtframe — a read miss is answered only after all 128 beats of the
//        256 B block have streamed in (S_POSTFILL_WAIT is reachable only from
//        ext_rdy).
//   ON : early restart + hit-under-fill — the read is answered as soon as the
//        fill front passes its word, and later reads into the same block are
//        served from the block RAM while the rest of it streams.
//
// Checks BOTH legs return identical data for every beat, then reports cycles.
// COLD is the interesting leg; WARM should be unchanged (no fill in flight).
`timescale 1ns/1ps

module tb_early_restart_ab #(parameter integer INIT_WAIT_SIM = 40);

localparam integer PERIOD = 10;
localparam integer NLBQ   = 512;   // linebuf qwords per walk (= 2048 px PAL8)

reg clk, clk_sdram, rst;
initial begin
    clk = 0; clk_sdram = 0;
    forever begin
        #(PERIOD/2) clk_sdram = ~clk_sdram;
        #5          clk       =  clk_sdram;
    end
end

integer cycle_ctr;
always @(posedge clk) cycle_ctr <= cycle_ctr + 1;

// ── two stacks ─────────────────────────────────────────────────────────────
`define STACK(NAME, EARLY)                                                      \
    reg  [26:0] NAME``_addr; reg NAME``_rd;                                     \
    wire [63:0] NAME``_dout; wire NAME``_ok;                                    \
    wire [15:0] NAME``_dq;   wire [12:0] NAME``_a;                              \
    wire NAME``_dqml, NAME``_dqmh; wire [1:0] NAME``_ba;                        \
    wire NAME``_nwe, NAME``_ncas, NAME``_nras, NAME``_ncs, NAME``_cke, NAME``_sclk; \
    sdram_fb_cache #(.INIT_WAIT_SIM(INIT_WAIT_SIM), .SRC_BLOCKS(128),           \
                     .SRC_EARLY(EARLY)) u_``NAME (                              \
        .clk(clk), .clk_sdram(clk), .rst(rst), .init(),                         \
        .dst_addr(27'd0), .dst_rd(1'b0), .dst_wr(1'b0), .dst_din(64'd0),        \
        .dst_wdsn(8'hff), .dst_dout(), .dst_ok(),                               \
        .scan_addr(27'd0), .scan_rd(1'b0), .scan_dout(), .scan_ok(),            \
        .p0_addr(NAME``_addr), .p0_rd(NAME``_rd),                               \
        .p0_dout(NAME``_dout), .p0_ok(NAME``_ok),                               \
        .stage_addr(27'd0), .stage_wr(1'b0), .stage_din(64'd0),                 \
        .stage_wdsn(8'hff), .stage_ok(),                                        \
        .stage_barrier(1'b0), .stage_busy(), .dst_barrier(1'b0), .dst_busy(),   \
        .vs(1'b0), .coh_busy(),                                                 \
        .sdram_dq(NAME``_dq), .sdram_a(NAME``_a), .sdram_dqml(NAME``_dqml),     \
        .sdram_dqmh(NAME``_dqmh), .sdram_ba(NAME``_ba), .sdram_nwe(NAME``_nwe), \
        .sdram_ncas(NAME``_ncas), .sdram_nras(NAME``_nras),                     \
        .sdram_ncs(NAME``_ncs), .sdram_cke(NAME``_cke), .sdram_clk(NAME``_sclk) \
    );                                                                          \
    mt48lc16m16a2 #(.addr_bits(13), .col_bits(10)) u_``NAME``_mem (             \
        .Clk(clk_sdram), .Cke(NAME``_cke), .Dq(NAME``_dq), .Addr(NAME``_a),     \
        .Ba(NAME``_ba), .Cs_n(NAME``_ncs), .Ras_n(NAME``_nras),                 \
        .Cas_n(NAME``_ncas), .We_n(NAME``_nwe),                                 \
        .Dqm({NAME``_dqmh,NAME``_dqml}), .downloading(1'b0), .VS(1'b0),         \
        .frame_cnt(0) );

`STACK(a, 0)
`STACK(b, 1)

// ── two identical F_WALK walkers ───────────────────────────────────────────
reg [31:0] base_lbq;
reg        run;

function [26:0] src_byte_addr; input [31:0] lbq;
    src_byte_addr = 27'((lbq >> 1) << 3);      // PAL8 mapping
endfunction

// walker state, one set per leg
reg [15:0] a_idx, b_idx;
reg        a_busy, b_busy, a_dup, b_dup;
reg [63:0] a_hold, b_hold;
integer    a_beats, b_beats, mismatches;

`define WALKER(NAME, IDX, BUSY, DUP, HOLD, BEATS)                               \
    always @(posedge clk) begin                                                 \
        if (rst) begin BUSY <= 0; NAME``_rd <= 0; DUP <= 0; end                 \
        else begin                                                              \
            NAME``_rd <= 1'b0; DUP <= 1'b0;                                     \
            if (NAME``_ok) HOLD <= NAME``_dout;                                 \
            if (!BUSY && run) begin                                             \
                BUSY <= 1'b1; IDX <= 16'd0;                                     \
                NAME``_addr <= src_byte_addr(base_lbq); NAME``_rd <= 1'b1;      \
            end else if (BUSY && (NAME``_ok | DUP)) begin                       \
                BEATS <= BEATS + 1;                                             \
                if ((IDX + 16'd1) >= NLBQ) BUSY <= 1'b0;                        \
                else begin                                                      \
                    IDX <= IDX + 16'd1;                                         \
                    if ((base_lbq + {16'd0, IDX} + 32'd1) & 32'd1) DUP <= 1'b1; \
                    else begin                                                  \
                        NAME``_addr <= src_byte_addr(base_lbq + {16'd0,IDX} + 32'd1); \
                        NAME``_rd   <= 1'b1;                                    \
                    end                                                         \
                end                                                             \
            end                                                                 \
        end                                                                     \
    end

`WALKER(a, a_idx, a_busy, a_dup, a_hold, a_beats)
`WALKER(b, b_idx, b_busy, b_dup, b_hold, b_beats)

// data equivalence: every real read must return the same qword on both legs.
// The legs run at different speeds, so compare per-index through small queues.
reg [63:0] a_q [0:1023]; reg [63:0] b_q [0:1023];
integer    a_n, b_n;
always @(posedge clk) if (!rst) begin
    if (a_ok) begin a_q[a_n] <= a_dout; a_n <= a_n + 1; end
    if (b_ok) begin b_q[b_n] <= b_dout; b_n <= b_n + 1; end
end

integer i, t0a, t0b, t_a_cold, t_b_cold, t_a_warm, t_b_warm;

task do_walk(input integer lbq_base, output integer ca, output integer cb);
    begin
        @(posedge clk); #1;
        base_lbq = lbq_base;
        a_beats = 0; b_beats = 0; a_n = 0; b_n = 0;
        t0a = cycle_ctr; run = 1'b1;
        @(posedge clk); #1; run = 1'b0;
        ca = -1; cb = -1;
        while (a_busy || b_busy) begin
            @(posedge clk); #1;
            if (!a_busy && ca < 0) ca = cycle_ctr - t0a;
            if (!b_busy && cb < 0) cb = cycle_ctr - t0a;
        end
        if (ca < 0) ca = cycle_ctr - t0a;
        if (cb < 0) cb = cycle_ctr - t0a;
        // compare the real-read streams
        if (a_n != b_n) begin
            $display("  MISMATCH: leg A took %0d reads, leg B took %0d", a_n, b_n);
            mismatches = mismatches + 1;
        end
        for (i = 0; i < a_n; i = i + 1)
            if (a_q[i] !== b_q[i]) begin
                if (mismatches < 8)
                    $display("  MISMATCH read %0d: OFF=%h ON=%h", i, a_q[i], b_q[i]);
                mismatches = mismatches + 1;
            end
    end
endtask

initial begin
    rst = 1; a_rd = 0; b_rd = 0; a_addr = 0; b_addr = 0; run = 0;
    cycle_ctr = 0; base_lbq = 0; a_idx = 0; b_idx = 0;
    a_beats = 0; b_beats = 0; a_n = 0; b_n = 0; mismatches = 0;
    for (i = 0; i < 262144; i = i + 1) begin
        u_a_mem.Bank0[i] = i[15:0] ^ 16'hA5A5;
        u_b_mem.Bank0[i] = i[15:0] ^ 16'hA5A5;
    end
    repeat (8) @(posedge clk);
    rst = 0;
    while (u_a.init || u_b.init) @(posedge clk);
    repeat (200) @(posedge clk);

    $display("");
    $display("=== Early-restart A/B — %0d linebuf qwords (= %0d px) per walk ===", NLBQ, NLBQ*4);
    $display("Two independent sdram_fb_cache + jtframe_burst_sdram + mt48 stacks,");
    $display("SRC_EARLY=0 vs SRC_EARLY=1, identical PAL8 F_WALK driver on each.");
    $display("");

    do_walk(32'h04000, t_a_cold, t_b_cold);
    $display("  COLD  EARLY=0 : %5d cyc = %0.3f cyc/px", t_a_cold, t_a_cold*1.0/(NLBQ*4));
    $display("  COLD  EARLY=1 : %5d cyc = %0.3f cyc/px   -> %0.2fx",
             t_b_cold, t_b_cold*1.0/(NLBQ*4), t_a_cold*1.0/t_b_cold);
    do_walk(32'h04000, t_a_warm, t_b_warm);
    $display("  WARM  EARLY=0 : %5d cyc = %0.3f cyc/px", t_a_warm, t_a_warm*1.0/(NLBQ*4));
    $display("  WARM  EARLY=1 : %5d cyc = %0.3f cyc/px   -> %0.2fx",
             t_b_warm, t_b_warm*1.0/(NLBQ*4), t_a_warm*1.0/t_b_warm);
    $display("");
    $display("  read-data mismatches between legs: %0d", mismatches);
    $display("");
    if (mismatches != 0) begin
        $display("RESULT: FAIL (early restart returned different data)");
        $finish;
    end
    $display("RESULT: PASS");
    $finish;
end

endmodule
