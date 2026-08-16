// tb_psrc_walk_ab.sv — A/B of the PAL8 source walk against the REAL SDRAM stack.
//
// Measures TRUE wall-clock cycles (free-running counter) for a walker that
// mirrors comp_pipeline's F_WALK issue logic exactly:
//   OLD: one P_SRC read per LINEBUF qword  -> PAL8 reads each source qword twice.
//   NEW: dup beat served from src_hold     -> one read per SOURCE qword + 1 cycle.
// Both walkers fill the same number of linebuf qwords, so the totals are directly
// comparable. DUT is sdram_fb_cache + jtframe_burst_sdram + mt48lc16m16a2.
`timescale 1ns/1ps

module tb_psrc_walk_ab #(parameter integer INIT_WAIT_SIM = 40);

localparam integer PERIOD = 10;
localparam integer NLBQ   = 512;   // linebuf qwords to fill per walk

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

sdram_fb_cache #(.INIT_WAIT_SIM(INIT_WAIT_SIM), .SRC_BLOCKS(128)) u_dut (
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

// ── walker (mirrors comp_pipeline F_WALK) ──────────────────────────────────
reg        run, dedup_en;
reg [31:0] base_lbq;
reg [15:0] sf_idx;
reg        busy, dup_pending;
reg [63:0] src_hold;
integer    n_reads, n_dups;

wire [31:0] cur_lbq  = base_lbq + {16'd0, sf_idx};
wire [31:0] next_lbq = cur_lbq + 32'd1;
wire        next_dup = dedup_en & next_lbq[0];
wire        f_beat   = p0_ok | dup_pending;

function [26:0] src_byte_addr; input [31:0] lbq;
    src_byte_addr = 27'((lbq >> 1) << 3);      // PAL8 mapping
endfunction

always @(posedge clk) begin
    if (rst) begin busy <= 0; p0_rd <= 0; dup_pending <= 0; end
    else begin
        p0_rd <= 1'b0; dup_pending <= 1'b0;
        if (p0_ok) src_hold <= p0_dout;
        if (!busy && run) begin                       // kick: always a real read
            busy <= 1'b1; sf_idx <= 16'd0;
            p0_addr <= src_byte_addr(base_lbq); p0_rd <= 1'b1;
            n_reads <= n_reads + 1;
        end else if (busy && f_beat) begin
            if (dup_pending) n_dups <= n_dups + 1;
            if ((sf_idx + 16'd1) >= NLBQ) busy <= 1'b0;
            else begin
                sf_idx <= sf_idx + 16'd1;
                if (next_dup) dup_pending <= 1'b1;
                else begin
                    p0_addr <= src_byte_addr(next_lbq); p0_rd <= 1'b1;
                    n_reads <= n_reads + 1;
                end
            end
        end
    end
end

integer i, t0, t_old_cold, t_old_warm, t_new_cold, t_new_warm;

task do_walk(input integer lbq_base, input dedup, output integer cycles);
    begin
        @(posedge clk); #1;
        base_lbq = lbq_base; dedup_en = dedup; n_reads = 0; n_dups = 0;
        t0 = cycle_ctr; run = 1'b1;
        @(posedge clk); #1; run = 1'b0;
        while (busy) begin @(posedge clk); #1; end
        cycles = cycle_ctr - t0;
    end
endtask

initial begin
    rst = 1; p0_rd = 0; p0_addr = 0; run = 0; dedup_en = 0;
    cycle_ctr = 0; n_reads = 0; n_dups = 0; base_lbq = 0; sf_idx = 0;
    for (i = 0; i < 262144; i = i + 1) u_sdram.Bank0[i] = i[15:0];
    repeat (8) @(posedge clk);
    rst = 0;
    while (u_dut.init) @(posedge clk);
    repeat (200) @(posedge clk);

    $display("");
    $display("=== PAL8 source-walk A/B — %0d linebuf qwords (= %0d px) per walk ===", NLBQ, NLBQ*4);
    $display("Real sdram_fb_cache (SRC_BLOCKS=128) + jtframe_burst_sdram + mt48 model.");
    $display("");

    do_walk(32'h04000, 1'b0, t_old_cold);
    $display("  OLD (2 reads/src qword)  COLD : %5d cyc  (%0d reads) = %0.3f cyc/px",
             t_old_cold, n_reads, t_old_cold*1.0/(NLBQ*4));
    do_walk(32'h04000, 1'b0, t_old_warm);
    $display("  OLD (2 reads/src qword)  WARM : %5d cyc  (%0d reads) = %0.3f cyc/px",
             t_old_warm, n_reads, t_old_warm*1.0/(NLBQ*4));

    do_walk(32'h08000, 1'b1, t_new_cold);
    $display("  NEW (dedup, 1 read+1 dup) COLD: %5d cyc  (%0d reads, %0d dups) = %0.3f cyc/px",
             t_new_cold, n_reads, n_dups, t_new_cold*1.0/(NLBQ*4));
    do_walk(32'h08000, 1'b1, t_new_warm);
    $display("  NEW (dedup, 1 read+1 dup) WARM: %5d cyc  (%0d reads, %0d dups) = %0.3f cyc/px",
             t_new_warm, n_reads, n_dups, t_new_warm*1.0/(NLBQ*4));

    $display("");
    $display("  COLD speed-up: %0.2fx   WARM speed-up: %0.2fx",
             t_old_cold*1.0/t_new_cold, t_old_warm*1.0/t_new_warm);
    $display("");
    $display("RESULT: PASS (measurement bench)");
    $finish;
end

endmodule
