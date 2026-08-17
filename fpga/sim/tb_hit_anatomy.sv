// tb_hit_anatomy.sv — where do the 5 cycles of a WARM P_SRC hit go?
//
// tb_miss_anatomy did this for the miss path and the answer (130 of 145 cycles
// spent waiting for the rest of the block) drove the early-restart change. This
// is the same question for the hit path, which is what 97.4% of reads take.
//
// Traces one warm read end to end: the client's p0_rd, the cache controller's
// state walk (S_IDLE -> S_LOOKUP -> S_RD_RESP), the cache's own ok, and the
// p0_ok the client finally sees through jtframe_cache_mux's ok_hold register.
// Then measures the back-to-back period of a one-outstanding walker, which is
// the number that actually bounds the source walk.
`timescale 1ns/1ps

module tb_hit_anatomy #(parameter integer INIT_WAIT_SIM = 40);

localparam integer PERIOD = 10;

reg clk, clk_sdram, rst;
initial begin
    clk = 0; clk_sdram = 0;
    forever begin
        #(PERIOD/2) clk_sdram = ~clk_sdram;
        #5          clk       =  clk_sdram;
    end
end

integer cyc;
always @(posedge clk) cyc <= cyc + 1;

reg  [26:0] p0_addr; reg p0_rd; wire [63:0] p0_dout; wire p0_ok;
wire [15:0] sdram_dq; wire [12:0] sdram_a;
wire sdram_dqml, sdram_dqmh; wire [1:0] sdram_ba;
wire sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke, sdram_clk;

// SRC_FASTHIT(0) is DELIBERATE: this bench exists to document the STOCK hit
// decomposition -- the 3 controller cycles that motivated FASTHIT in the first
// place. Left at the default (1) it measures the post-change path instead (4 cyc,
// ctrl_st never leaves S_IDLE) while the text below still describes the stock
// one, which is exactly the sort of drift that misleads a later reader.
// tb_fasthit_ab is where the improvement is measured.
sdram_fb_cache #(.INIT_WAIT_SIM(INIT_WAIT_SIM), .SRC_BLOCKS(128),
                 .SRC_FASTHIT(0)) u_dut (
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

wire [4:0] st       = u_dut.u_mux.u_cache5.u_ctrl.st;
wire       cache_ok = u_dut.u_mux.u_cache5.u_ctrl.ok;

localparam [4:0] S_IDLE = 5'd1, S_LOOKUP = 5'd2, S_RD_RESP = 5'd3;

// st values: 1=S_IDLE 2=S_LOOKUP 3=S_RD_RESP (jtframe_cache_ctrl localparams)

integer i, t_rd, t_ok, prev_ok, period;
reg trace;

// one-outstanding walker for the period measurement
reg        walk, busy;
reg [15:0] n;
integer    t_first, t_last, nreads;

always @(posedge clk) begin
    if (rst) begin busy <= 1'b0; end
    else if (walk) begin
        if (!busy) begin busy <= 1'b1; p0_addr <= 27'h04000; p0_rd <= 1'b1; n <= 0; end
        else begin
            p0_rd <= 1'b0;
            if (p0_ok) begin
                nreads <= nreads + 1;
                if (nreads == 0) t_first <= cyc;
                t_last <= cyc;
                if (n == 16'd30) busy <= 1'b0;
                else begin n <= n + 1; p0_addr <= 27'h04000 + 27'(n+1)*27'd8; p0_rd <= 1'b1; end
            end
        end
    end
end

always @(posedge clk) if (trace && !rst) begin
    if (p0_rd || st != S_IDLE || cache_ok || p0_ok)
        $display("    cyc %0d : p0_rd=%b  ctrl_st=%0d  cache_ok=%b  p0_ok=%b",
                 cyc - t_rd, p0_rd, st, cache_ok, p0_ok);
end

initial begin
    rst = 1; p0_rd = 0; p0_addr = 0; cyc = 0; trace = 0; walk = 0; busy = 0;
    nreads = 0; n = 0;
    for (i = 0; i < 262144; i = i + 1) u_sdram.Bank0[i] = i[15:0];
    repeat (8) @(posedge clk);
    rst = 0;
    while (u_dut.init) @(posedge clk);
    repeat (200) @(posedge clk);

    // warm the block
    @(posedge clk); #1; p0_addr = 27'h04000; p0_rd = 1'b1;
    @(posedge clk); #1; p0_rd = 1'b0;
    while (!p0_ok) begin @(posedge clk); #1; end
    // NOT ENOUGH to wait for p0_ok: with SRC_EARLY=1 the read is acked while the
    // block is still streaming, so tracing here would trace the EARLY path (which
    // is what the first version of this bench accidentally did -- ctrl_st=10,
    // S_FILL_STREAM). Wait for the controller to actually reach S_IDLE.
    while (st != S_IDLE) begin @(posedge clk); #1; end
    repeat (20) @(posedge clk);

    $display("");
    $display("=== WARM P_SRC hit, STOCK path (SRC_FASTHIT=0), cycle by cycle ===");
    $display("");
    @(posedge clk); #1;
    t_rd = cyc + 1; trace = 1'b1;
    p0_addr = 27'h04008; p0_rd = 1'b1;
    @(posedge clk); #1; p0_rd = 1'b0;
    while (!p0_ok) begin @(posedge clk); #1; end
    @(posedge clk); #1; trace = 1'b0;

    // back-to-back period of a one-outstanding walker
    repeat (20) @(posedge clk);
    nreads = 0;
    @(posedge clk); #1; walk = 1'b1;
    while (!busy) begin @(posedge clk); #1; end
    while (busy)  begin @(posedge clk); #1; end
    walk = 1'b0;

    $display("");
    $display("  one-outstanding walker: %0d reads over %0d cyc = %0d cyc per read",
             nreads-1, t_last - t_first, (t_last - t_first) / (nreads-1));
    $display("");
    $display("  Of that period: 1 cyc S_IDLE/take, 1 cyc S_LOOKUP (tag RAM -> hit_blk),");
    $display("                  1 cyc S_RD_RESP (data RAM -> dout/ok),");
    $display("                  1 cyc jtframe_cache_mux ok_hold, 1 cyc client turnaround.");
    $display("  A pipelined hit path can only remove the S_LOOKUP cycle: the data RAM");
    $display("  address depends on hit_blk_now, which is the tag RAM's registered output.");
    $display("");
    $display("RESULT: PASS (measurement bench)");
    $finish;
end

endmodule
