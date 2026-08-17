// tb_rowopen_probe.sv — how much is row-open reuse actually worth here?
//
// jtframe_burst_ctrl unconditionally PRECHARGEs after every burst and ACTivates
// before the next, even when both target the same SDRAM row. Skipping that pair
// on a row hit saves B_PRE + B_TRP1 + B_ACT + B_TRCD1 + B_TRCD2 = 5 clk.
//
// This counts, over a realistic P_SRC walk: how many bursts are issued, how many
// of them target the same (chip, bank, row) as the burst before them, and what
// the resulting cycle saving would be against the measured walk length. It is a
// MEASUREMENT bench — it answers "is the lever worth its risk" before any RTL is
// written, because holding a row open across idle time interacts with refresh
// (jtframe only grants AUTO REFRESH at burst_idle, and AUTO REFRESH requires all
// banks precharged).
//
// The single long linear span walked here is the BEST case for row reuse: 256
// source qwords = 2048 B = exactly one 2 KB row, so 7 of its 8 block fills are
// same-row by construction. Real spans are short (a tile/sprite scanline) and
// step by the surface pitch between spans, so treat this as an upper bound.
`timescale 1ns/1ps

module tb_rowopen_probe #(parameter integer INIT_WAIT_SIM = 40);

localparam integer PERIOD = 10;
localparam integer NLBQ   = 2048;   // 4 rows' worth, so cross-row steps appear

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

reg  [26:0] p0_addr; reg p0_rd; wire [63:0] p0_dout; wire p0_ok;
wire [15:0] sdram_dq; wire [12:0] sdram_a;
wire sdram_dqml, sdram_dqmh; wire [1:0] sdram_ba;
wire sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke, sdram_clk;

sdram_fb_cache #(.INIT_WAIT_SIM(INIT_WAIT_SIM), .SRC_BLOCKS(128), .SRC_EARLY(1)) u_dut (
    .clk(clk), .clk_sdram(clk), .rst(rst), .init(),
    .dst_addr(27'd0), .dst_rd(1'b0), .dst_wr(1'b0), .dst_din(64'd0),
    .dst_wdsn(8'hff), .dst_dout(), .dst_ok(),
    .scan_addr(27'd0), .scan_rd(1'b0), .scan_dout(), .scan_ok(),
    .p0_addr(p0_addr), .p0_rd(p0_rd), .p0_dout(p0_dout), .p0_ok(p0_ok),
    .stage_addr(27'd0), .stage_wr(1'b0), .stage_din(64'd0), .stage_wdsn(8'hff), .stage_ok(),
    .stage_barrier(1'b0), .stage_busy(), .dst_barrier(1'b0), .dst_busy(),
    .vs(1'b0), .coh_busy(),
    .sdram_dq(sdram_dq), .sdram_a(sdram_a), .sdram_dqml(sdram_dqml), .sdram_dqmh(sdram_dqmh),
    .sdram_ba(sdram_ba), .sdram_nwe(sdram_nwe), .sdram_ncas(sdram_ncas),
    .sdram_nras(sdram_nras), .sdram_ncs(sdram_ncs), .sdram_cke(sdram_cke), .sdram_clk(sdram_clk)
);

mt48lc16m16a2 #(.addr_bits(13), .col_bits(10)) u_sdram (
    .Clk(clk_sdram), .Cke(sdram_cke), .Dq(sdram_dq), .Addr(sdram_a), .Ba(sdram_ba),
    .Cs_n(sdram_ncs), .Ras_n(sdram_nras), .Cas_n(sdram_ncas), .We_n(sdram_nwe),
    .Dqm({sdram_dqmh,sdram_dqml}), .downloading(1'b0), .VS(1'b0), .frame_cnt(0)
);

// ── burst probe ────────────────────────────────────────────────────────────
// B_ACT = 5'd1 in jtframe_burst_ctrl. Sample row/bank/chip as the ACTIVATE goes
// out and compare against the previous burst's.
wire [4:0]  burst_st   = u_dut.u_sdram_ctrl.u_burst.burst_st;
wire [12:0] burst_row  = u_dut.u_sdram_ctrl.u_burst.burst_row;
wire [1:0]  burst_bank = u_dut.u_sdram_ctrl.u_burst.burst_bank_r;
wire        burst_chip = u_dut.u_sdram_ctrl.u_burst.burst_chip;

reg  [4:0]  burst_st_l;
reg [12:0]  prev_row;
reg  [1:0]  prev_bank;
reg         prev_chip, have_prev;
integer     n_bursts, n_samerow;
reg         counting;

always @(posedge clk) begin
    burst_st_l <= burst_st;
    if (rst) begin
        have_prev <= 1'b0; burst_st_l <= 5'd0;
    end else if (counting && burst_st == 5'd1 && burst_st_l != 5'd1) begin
        n_bursts <= n_bursts + 1;
        if (have_prev && burst_row == prev_row && burst_bank == prev_bank
                      && burst_chip == prev_chip)
            n_samerow <= n_samerow + 1;
        prev_row  <= burst_row;
        prev_bank <= burst_bank;
        prev_chip <= burst_chip;
        have_prev <= 1'b1;
    end
end

// ── F_WALK-shaped driver (PAL8, one outstanding, dedup on odd beats) ───────
reg [31:0] base_lbq; reg run;
reg [15:0] sf_idx; reg busy, dup_pending;

function [26:0] src_byte_addr; input [31:0] lbq;
    src_byte_addr = 27'((lbq >> 1) << 3);
endfunction

always @(posedge clk) begin
    if (rst) begin busy <= 0; p0_rd <= 0; dup_pending <= 0; end
    else begin
        p0_rd <= 1'b0; dup_pending <= 1'b0;
        if (!busy && run) begin
            busy <= 1'b1; sf_idx <= 16'd0;
            p0_addr <= src_byte_addr(base_lbq); p0_rd <= 1'b1;
        end else if (busy && (p0_ok | dup_pending)) begin
            if ((sf_idx + 16'd1) >= NLBQ) busy <= 1'b0;
            else begin
                sf_idx <= sf_idx + 16'd1;
                if ((base_lbq + {16'd0, sf_idx} + 32'd1) & 32'd1) dup_pending <= 1'b1;
                else begin
                    p0_addr <= src_byte_addr(base_lbq + {16'd0, sf_idx} + 32'd1);
                    p0_rd   <= 1'b1;
                end
            end
        end
    end
end

integer i, t0, walk_cyc;

initial begin
    rst = 1; p0_rd = 0; p0_addr = 0; run = 0; counting = 0;
    cycle_ctr = 0; base_lbq = 0; sf_idx = 0;
    n_bursts = 0; n_samerow = 0; have_prev = 0;
    for (i = 0; i < 262144; i = i + 1) u_sdram.Bank0[i] = i[15:0];
    repeat (8) @(posedge clk);
    rst = 0;
    while (u_dut.init) @(posedge clk);
    repeat (200) @(posedge clk);

    @(posedge clk); #1;
    base_lbq = 32'h04000; counting = 1'b1;
    t0 = cycle_ctr; run = 1'b1;
    @(posedge clk); #1; run = 1'b0;
    while (busy) begin @(posedge clk); #1; end
    walk_cyc = cycle_ctr - t0;
    counting = 1'b0;

    $display("");
    $display("=== Row-open reuse headroom on a COLD P_SRC walk (EARLY=1) ===");
    $display("  %0d linebuf qwords = %0d source qwords = %0d B = %0d SDRAM rows (2 KB each)",
             NLBQ, NLBQ/2, (NLBQ/2)*8, ((NLBQ/2)*8)/2048);
    $display("");
    $display("  walk length              : %0d cyc", walk_cyc);
    $display("  bursts (ACTIVATEs) issued: %0d", n_bursts);
    $display("  ... targeting the SAME (chip,bank,row) as the previous burst: %0d", n_samerow);
    $display("");
    $display("  row-open reuse would skip PRE+tRP+ACT+tRCD = 5 clk on each of those:");
    $display("    saving = %0d cyc of %0d = %0.2f%% of this walk",
             n_samerow*5, walk_cyc, (n_samerow*5*100.0)/walk_cyc);
    $display("");
    $display("  NOTE: one long linear span is the BEST case for row reuse. Real spans");
    $display("        are a tile/sprite scanline and step by the surface pitch, so the");
    $display("        same-row fraction in gameplay is at or below this.");
    $display("");
    $display("RESULT: PASS (measurement bench)");
    $finish;
end

endmodule
