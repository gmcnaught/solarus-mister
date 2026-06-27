// tb_stage_psrc.sv — SDRAM source STAGING write-path coverage (#44 strategic fix).
//
// ROOT CAUSE under test: when sdram_fb_cache replaced sdram_src_arb (JC-T5/T7), the
// blitter's BLT_OP_STAGE write outputs (src_sdram_we_burst/waddr/din64) were left
// UNCONNECTED at the top level (Solarus.sv) and the cache grew no atlas-write channel.
// So with C_SRCSEL=1 the engine stages atlases but NOTHING is written to SDRAM, and
// the P_SRC (ch5) source reads return uninitialized SDRAM -> full-screen noise on HW.
// No existing tb covered this (all tie src_sdram_* off / pre-seed the chip store).
//
// This test drives a REAL BLT_OP_STAGE through blitter_top: it copies a known pattern
// from the DDR3 source heap into an SDRAM atlas offset, then reads that offset back
// through the cache P_SRC port and asserts equality.
//
//   RED  (today): src_sdram_* dangling -> staging writes nowhere -> P_SRC reads
//                 uninitialized SDRAM != pattern -> FAIL.
//   GREEN(fix):   route src_sdram_* into a dedicated cache atlas-write channel (ch1),
//                 flush+invalidate so P_SRC re-reads -> pattern matches -> PASS.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
`include "vram_defs.vh"

module tb_stage_psrc;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h10000;  // [#52] tracks SRC_QW
  localparam [28:0] SRC_WIN = `SRC_QW - WBASE;  // [#52] heap base (was hardcoded 0x201000)

  reg clk_sys = 0;   always #5 clk_sys   = ~clk_sys;
  reg clk_sdram = 1; always #5 clk_sdram = ~clk_sdram;
  reg reset = 1;

  // staging parameters: copy NQW qwords from DDR3 src_off=0 to SDRAM dest.
  localparam integer NQW = 16;                 // 16 qwords = 128 bytes staged
  localparam [26:0]  SDRAM_DEST = 27'h0100000; // atlas-like SDRAM dest offset (1 MiB)
  function [15:0] pat(input integer k); pat = 16'hA000 | k[15:0]; endfunction

  // ---- blitter -> vram_demux ----
  wire [31:0] bt_addr; wire bt_rd, bt_wr; wire [63:0] bt_din; wire [7:0] bt_be;
  wire [7:0]  bt_burstcnt; wire bt_idle; wire [31:0] blt_dbg;
  wire [63:0] blt_demux_dout; wire blt_demux_dready, blt_busy_w;
  wire [28:0] bd_addr; wire bd_rd, bd_wr; wire [63:0] bd_din; wire [7:0] bd_be;
  wire        b_grant; wire blt_arb_busy;
  wire [26:0] bs_p0_addr; wire bs_p0_rd;
  // blitter STAGING-write outputs — the path that is unconnected in Solarus.sv today.
  wire        bs_we;        wire [15:0] bs_din;  wire [26:0] bs_waddr;
  wire        bs_we_burst;  wire [63:0] bs_din64;
  wire        stage_ok;     // cache STAGE-channel (ch1) accept, fed back to the blitter
  wire        blt_stage_barrier; wire blt_stage_busy;  // intra-frame STAGE->P_SRC barrier
  wire [3:0]  vdemux_dbg;

  blitter_top blt (
    .clk(clk_sys), .rst(reset),
    .mem_addr(bt_addr), .mem_rd(bt_rd), .mem_wr(bt_wr), .mem_burstcnt(bt_burstcnt),
    .mem_din(bt_din), .mem_be(bt_be),
    .mem_dout(blt_demux_dout), .mem_dout_ready(blt_demux_dready), .mem_busy(blt_busy_w),
    .p0_addr(bs_p0_addr), .p0_rd(bs_p0_rd), .p0_dout(64'd0), .p0_ok(1'b0),
    .src_sdram_we(bs_we), .src_sdram_din(bs_din), .src_sdram_waddr(bs_waddr),
    .src_sdram_we_burst(bs_we_burst), .src_sdram_din64(bs_din64),
    .src_sdram_ok(stage_ok),
    .stage_barrier(blt_stage_barrier), .stage_barrier_busy(blt_stage_busy),
    .idle(bt_idle), .dbg(blt_dbg));

  wire [26:0] dst_addr; wire dst_rd, dst_wr;
  wire [63:0] dst_din;  wire [7:0] dst_wdsn;
  wire [63:0] dst_dout; wire dst_ok;
  wire [7:0] d_burst; wire [28:0] d_addr; wire d_rd; wire [63:0] d_din;
  wire [7:0] d_be;    wire d_we;
  wire       d_busy;  reg d_dready = 0; reg [63:0] d_dout = 0;

  vram_demux vdemux (
    .clk(clk_sys), .reset(reset),
    .blt_addr(bt_addr), .blt_rd(bt_rd), .blt_wr(bt_wr), .blt_din(bt_din), .blt_be(bt_be),
    .blt_burstcnt(bt_burstcnt),
    .blt_dout(blt_demux_dout), .blt_dout_ready(blt_demux_dready), .blt_busy(blt_busy_w),
    .ddr_addr(bd_addr), .ddr_rd(bd_rd), .ddr_wr(bd_wr), .ddr_din(bd_din), .ddr_be(bd_be),
    .ddr_dout(d_dout), .ddr_dout_ready(d_dready & b_grant), .ddr_busy(blt_arb_busy),
    .sd_addr(dst_addr), .sd_rd(dst_rd), .sd_wr(dst_wr),
    .sd_din(dst_din), .sd_wdsn(dst_wdsn), .sd_dout(dst_dout), .sd_ok(dst_ok),
    .dbg(vdemux_dbg));

  ddr_blitter_arb #(.ENABLE(1'b1)) arb_ddr (
    .clk(clk_sys), .reset(reset),
    .rdr_burstcnt(8'd0), .rdr_addr(29'd0), .rdr_rd(1'b0), .rdr_din(64'd0),
    .rdr_be(8'd0), .rdr_we(1'b0), .rdr_busy(), .rdr_grant(),
    .blt_burstcnt(bt_burstcnt), .blt_addr(bd_addr), .blt_rd(bd_rd), .blt_din(bd_din),
    .blt_be(bd_be), .blt_we(bd_wr), .blt_busy(blt_arb_busy), .blt_grant(b_grant),
    .ddram_busy(d_busy), .ddram_dout_ready(d_dready),
    .ddram_burstcnt(d_burst), .ddram_addr(d_addr), .ddram_rd(d_rd),
    .ddram_din(d_din), .ddram_be(d_be), .ddram_we(d_we), .dbg());

  // ---- SDRAM cache: tb drives P_SRC (p0_*) for readback; vs for coherency ----
  reg  [26:0] p0_addr_r = 27'd0;  reg p0_rd_r = 1'b0;
  wire [63:0] p0_dout;  wire p0_ok;
  reg         vs_r = 1'b0;  wire coh_busy;
  wire [15:0] SDQ; wire [12:0] SA; wire SDQML, SDQMH; wire [1:0] SBA;
  wire        SnCS, SnWE, SnRAS, SnCAS, SCKE, cache_sdram_clk;

  // GREEN-path staging connection: once sdram_fb_cache exposes a stage-write port,
  // these drive it. RED today: the cache has no such port, so blitter src_sdram_*
  // (bs_we_burst/bs_waddr/bs_din64) terminate here and write nothing to SDRAM.
  wire sdram_init;   // high while the SDRAM controller runs power-up init
  sdram_fb_cache fbcache (
    .clk(clk_sys), .clk_sdram(clk_sys), .rst(reset), .init(sdram_init),
    .dst_addr(dst_addr), .dst_rd(dst_rd), .dst_wr(dst_wr),
    .dst_din(dst_din), .dst_wdsn(dst_wdsn), .dst_dout(dst_dout), .dst_ok(dst_ok),
    .scan_addr(27'd0), .scan_rd(1'b0), .scan_dout(), .scan_ok(),
    .p0_addr(p0_addr_r), .p0_rd(p0_rd_r), .p0_dout(p0_dout), .p0_ok(p0_ok),
    // STAGE (ch1) write channel <- blitter src_sdram burst-write outputs.
    .stage_addr(bs_waddr), .stage_wr(bs_we_burst), .stage_din(bs_din64),
    .stage_wdsn(8'h00), .stage_ok(stage_ok),
    .vs(vs_r), .coh_busy(coh_busy),
    .stage_barrier(blt_stage_barrier), .stage_busy(blt_stage_busy),
    .dst_barrier(1'b0), .dst_busy(),       // no carry-forward in this bench
    .sdram_dq(SDQ), .sdram_a(SA), .sdram_dqml(SDQML), .sdram_dqmh(SDQMH),
    .sdram_ba(SBA), .sdram_nwe(SnWE), .sdram_ncas(SnCAS), .sdram_nras(SnRAS),
    .sdram_ncs(SnCS), .sdram_cke(SCKE), .sdram_clk(cache_sdram_clk));

  mt48lc16m16a2 #(.addr_bits(13), .col_bits(10)) schip (
    .Dq(SDQ), .Addr(SA), .Ba(SBA), .Clk(clk_sdram), .Cke(SCKE),
    .Cs_n(SnCS), .Ras_n(SnRAS), .Cas_n(SnCAS), .We_n(SnWE), .Dqm({SDQMH, SDQML}),
    .downloading(1'b0), .VS(1'b0), .frame_cnt(32'd0));

  // ---- behavioral DDR3 (serves the blitter control/ring + the STAGE source reads) ----
  reg [63:0] mem [0:MEMQW-1];
  reg [1:0] bp=0; always @(posedge clk_sys) bp <= (bp==2'd2)?2'd0:bp+2'd1;
  integer i;
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat;
  assign d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  always @(posedge clk_sys) begin
    d_dready <= 1'b0;
    if (reset) begin rbeats<=0; rlat<=0; end
    else begin
      if (rlat != 3'd0) rlat <= rlat - 3'd1;
      else if (rbeats != 8'd0) begin
        if (bp == 2'd2) begin
          d_dout <= mem[raddr-WBASE]; d_dready <= 1'b1;
          raddr <= raddr + 29'd1; rbeats <= rbeats - 8'd1;
        end
      end else if (!d_busy) begin
        if (d_rd) begin rbeats <= d_burst; raddr <= d_addr; rlat <= 3'd3; end
        else if (d_we) for(i=0;i<8;i=i+1) if(d_be[i]) mem[(d_addr-WBASE)][i*8 +:8]<=d_din[i*8 +:8];
      end
    end
  end

  task wmem(input [31:0] idx, input [63:0] val); mem[idx]=val; endtask
  wire [31:0] done_seq = mem[32'h200005][31:0];

  // submit ONE BLT_OP_STAGE: DDR3 src_off=0 -> SDRAM_DEST, size = NQW*8 bytes.
  integer submit_n = 0;
  task submit_stage;
    begin
      wmem(32'h200002, 64'd0);          // target_buf
      wmem(32'h200004, 64'd0);          // flags = 0 (no CLEAR)
      wmem(32'h200007, 64'd1);          // C_SRCSEL = 1
      wmem(32'h200001, 64'd2);          // cmd_count = 2 (STAGE + END)
      // cmd0 STAGE: u32[0]=op4|F_STAGE_DST(0x08)<<24 ; u32[1]=src_off=0
      wmem(32'h200008, {32'd0, 32'h0800_0004});
      // qw1: u32[2]=SDRAM dest off (low) ; u32[3]=size bytes (high)
      wmem(32'h200009, {32'(NQW*8), 32'(SDRAM_DEST)});
      wmem(32'h20000A, 64'd0);
      wmem(32'h20000B, 64'd0);
      wmem(32'h20000C, 64'd1);          // cmd1 END
      wmem(32'h20000D, 64'd0); wmem(32'h20000E,64'd0); wmem(32'h20000F,64'd0);
      submit_n = submit_n + 1;
      wmem(32'h200000, submit_n[63:0]);
    end
  endtask

  task p0_read(input [26:0] byte_addr, output [63:0] q);
    integer cyc;
    begin
      cyc=0; @(posedge clk_sys); #1;
      p0_addr_r = byte_addr; p0_rd_r = 1'b1;
      @(posedge clk_sys); #1; p0_rd_r = 1'b0;
      while (!p0_ok) begin @(posedge clk_sys); cyc=cyc+1;
        if (cyc>5000) begin $display("RESULT: FAIL - p0_read timeout @%h", byte_addr); $finish; end end
      q = p0_dout;
    end
  endtask

  integer k, settle, bad;
  reg [63:0] got, want;
  initial begin
    for (i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    // preload the DDR3 source heap (SRC_QW byte 0x3B008000 -> mem idx 0x201000) with
    // a known pattern: qword k = {pat,pat,pat,pat}.
    for (k=0;k<NQW;k=k+1) mem[SRC_WIN + k] = {pat(k),pat(k),pat(k),pat(k)};
    // Pre-seed the SDRAM dest region with a SENTINEL (0xDEAD) so a dropped staging
    // write reads a DEFINED non-pattern value (clean mismatch) rather than an
    // uninitialized-row read that stalls the model. word_base = (byte>>3)*4 (bank 0;
    // the FB cache addresses bank 0 — same map tb_sdram_fb_cache verifies).
    for (k=0;k<NQW;k=k+1) begin
      schip.Bank0[((SDRAM_DEST+k*8)>>3)*4 + 0] = 16'hDEAD;
      schip.Bank0[((SDRAM_DEST+k*8)>>3)*4 + 1] = 16'hDEAD;
      schip.Bank0[((SDRAM_DEST+k*8)>>3)*4 + 2] = 16'hDEAD;
      schip.Bank0[((SDRAM_DEST+k*8)>>3)*4 + 3] = 16'hDEAD;
    end

    repeat (16) @(posedge clk_sys); reset = 1'b0; repeat (8) @(posedge clk_sys);

    // wait for SDRAM controller power-up init before any SDRAM access
    settle=0;
    while (sdram_init) begin @(posedge clk_sys); settle=settle+1;
      if (settle>2_000_000) begin $display("RESULT: FAIL - SDRAM init never completed"); $finish; end end
    $display("SDRAM init done after %0d cyc", settle);

    submit_stage;
    settle=0;
    while (done_seq !== submit_n[31:0] && settle < 20_000_000) begin @(posedge clk_sys); settle=settle+1; end
    if (done_seq !== submit_n[31:0]) begin $display("RESULT: FAIL - STAGE never completed (blt.state=%0d)", blt.state); $finish; end
    $display("STAGE completed in %0d cyc", settle);

    // coherency: flush the staged data to SDRAM + invalidate P_SRC so it re-reads.
    @(posedge clk_sys); #1; vs_r=1'b1; repeat(4) @(posedge clk_sys); #1; vs_r=1'b0;
    settle=0; while (coh_busy) begin @(posedge clk_sys); settle=settle+1;
      if (settle>2_000_000) begin $display("RESULT: FAIL - coh_busy stuck"); $finish; end end

    // read the staged atlas back through P_SRC and check.
    bad=0;
    for (k=0;k<NQW;k=k+1) begin
      want = {pat(k),pat(k),pat(k),pat(k)};
      p0_read(SDRAM_DEST + 27'(k*8), got);
      if (got !== want) begin
        bad = bad + 1;
        if (bad <= 4) $display("  MISMATCH qw %0d @%h: got=%016h want=%016h", k, SDRAM_DEST+k*8, got, want);
      end
    end

    if (bad==0) $display("RESULT: PASS  (staged %0d qwords readable via P_SRC)", NQW);
    else        $display("RESULT: FAIL  (%0d/%0d staged qwords wrong - staging write path dropped)", bad, NQW);
    $finish;
  end

  initial begin
    #500_000_000;
    $display("RESULT: FAIL - global timeout (done=%0d)", done_seq);
    $finish;
  end
endmodule
`default_nettype wire
