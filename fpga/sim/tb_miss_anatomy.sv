// tb_miss_anatomy.sv — where do the ~145 cycles of a P_SRC cold miss actually go?
//
// Probes jtframe_cache_ctrl (ch5) during a single cold read and reports:
//   t_ack   : cycle the SDRAM burst was acked (ACT+tRCD+READ issued)
//   t_word  : cycle the REQUESTED qword had fully streamed into block RAM
//   t_ok    : cycle the cache actually returned it to the client
// The gap (t_ok - t_word) is what an early-restart / hit-under-fill cache would
// remove. Repeated for several request offsets within the block.
`timescale 1ns/1ps

module tb_miss_anatomy #(parameter integer INIT_WAIT_SIM = 40);

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

// ── probes into ch5's cache controller ─────────────────────────────────────
wire [4:0]  st          = u_dut.u_mux.u_cache5.u_ctrl.st;
wire [6:0]  stream_word = u_dut.u_mux.u_cache5.u_ctrl.stream_word;
wire [4:0]  req_off_l   = u_dut.u_mux.u_cache5.u_ctrl.req_off_l;
wire        ext_ack     = u_dut.u_mux.u_cache5.u_ctrl.ext_ack;

integer t_start, t_ack, t_word, t_ok;
reg     armed;

// requested qword `off` is complete once halfword 4*off+3 has been written
always @(posedge clk) begin
    if (armed) begin
        if (ext_ack && t_ack < 0) t_ack <= cyc;
        if (t_word < 0 && (st == 5'd10 /*S_FILL_STREAM*/ || st == 5'd13 /*S_FILL_WB_PRIME*/)
            && stream_word >= (7'(req_off_l) * 4 + 3)) t_word <= cyc;
        if (p0_ok && t_ok < 0) t_ok <= cyc;
    end
end

integer off;
task cold_read(input integer blk, input integer qoff);
    begin
        @(posedge clk); #1;
        t_ack = -1; t_word = -1; t_ok = -1; armed = 1'b1;
        t_start = cyc;
        p0_addr = 27'(blk*256 + qoff*8); p0_rd = 1'b1;
        @(posedge clk); #1; p0_rd = 1'b0;
        while (t_ok < 0) begin @(posedge clk); #1; end
        armed = 1'b0;
        $display("  qword offset %2d in block : total %3d | ack@%3d | data-in-RAM@%3d | returned@%3d  =>  %3d cyc AFTER its own data landed",
                 qoff, t_ok-t_start, t_ack-t_start, t_word-t_start, t_ok-t_start, t_ok-t_word);
    end
endtask

integer i;
initial begin
    rst = 1; p0_rd = 0; p0_addr = 0; cyc = 0; armed = 0;
    t_ack = -1; t_word = -1; t_ok = -1;
    for (i = 0; i < 262144; i = i + 1) u_sdram.Bank0[i] = i[15:0];
    repeat (8) @(posedge clk);
    rst = 0;
    while (u_dut.init) @(posedge clk);
    repeat (200) @(posedge clk);

    $display("");
    $display("=== P_SRC cold-miss anatomy (256 B block = 32 qwords = 128 SDRAM beats) ===");
    $display("");
    cold_read(64,  0);    // block-aligned  — the linear-walk case
    cold_read(96,  8);
    cold_read(128, 16);
    cold_read(160, 31);   // last qword of the block — worst case for early restart
    $display("");
    $display("RESULT: PASS (measurement bench)");
    $finish;
end

endmodule
