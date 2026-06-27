// tb_stage_psrc_sameframe.sv — SAME-FRAME STAGE->P_SRC coherency reproduction.
//
// PER-TILE ATLAS GARBAGE root-cause repro (per-sprite scramble, SDRAM-source path).
//
// tb_stage_psrc proves STAGE (ch1 write) -> [vs flush+invalidate] -> P_SRC (ch5 read)
// round-trips a staged atlas correctly. THIS tb removes the vs pulse between the STAGE
// and the P_SRC read — exactly what the ENGINE does: the per-surface STAGE
// (blt_stage_surface in upload()) is emitted in the SAME frame's command ring,
// immediately before the BLIT that reads it (mister_blitter_renderer.cpp upload() ->
// blt_blit). No frame swap (vs) separates the write from the read.
//
// COHERENCY CONTRACT (sdram_fb_cache.sv:26-34, :149-152): ch1 (STAGE write) and ch5
// (P_SRC read) are SEPARATE jtframe_cache instances. ch1's dirty lines commit to SDRAM
// and ch5 is invalidated ONLY on vs-rising (flush1 + INVAL_MASK1). With NO vs between
// the STAGE write and the P_SRC read, ch5 returns its STALE/cold contents (or pre-stage
// SDRAM) -> GARBAGE source pixels for a freshly-staged atlas.
//
// Content-dependent on HW: a STATIC atlas (roof/grass) staged on an early frame has
// had a vs flush+invalidate since, so P_SRC reads it clean; a sprite/tile FIRST staged
// on the frame it is drawn (door/window/fence/bush — colorkey/alpha variants force a
// fresh second (ptr,fmt) upload+stage) is read same-frame -> garbage.
//
//   EXPECTED today (RED): some staged qwords read back != pattern (the bug reproduced).
//   With an intra-frame STAGE->P_SRC coherency fix: all qwords match (GREEN).
//
// Verdict: DIAGNOSTIC. The discriminating signal is the "REPRO:" line. The final
// RESULT: PASS asserts only the CONTROL (post-vs) read — so the tb never wedges CI;
// its value is the same-frame mismatch report.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
`include "vram_defs.vh"

module tb_stage_psrc_sameframe;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h10000;  // [#52] tracks SRC_QW
  localparam [28:0] SRC_WIN = `SRC_QW - WBASE;  // [#52] heap base (was hardcoded 0x201000)

  reg clk_sys = 0;   always #5 clk_sys   = ~clk_sys;
  reg clk_sdram = 1; always #5 clk_sdram = ~clk_sdram;
  reg reset = 1;

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
  wire        bs_we;        wire [15:0] bs_din;  wire [26:0] bs_waddr;
  wire        bs_we_burst;  wire [63:0] bs_din64;
  wire        stage_ok;
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

  reg  [26:0] p0_addr_r = 27'd0;  reg p0_rd_r = 1'b0;
  wire [63:0] p0_dout;  wire p0_ok;
  reg         vs_r = 1'b0;  wire coh_busy;
  wire [15:0] SDQ; wire [12:0] SA; wire SDQML, SDQMH; wire [1:0] SBA;
  wire        SnCS, SnWE, SnRAS, SnCAS, SCKE, cache_sdram_clk;

  wire sdram_init;
  sdram_fb_cache fbcache (
    .clk(clk_sys), .clk_sdram(clk_sys), .rst(reset), .init(sdram_init),
    .dst_addr(dst_addr), .dst_rd(dst_rd), .dst_wr(dst_wr),
    .dst_din(dst_din), .dst_wdsn(dst_wdsn), .dst_dout(dst_dout), .dst_ok(dst_ok),
    .scan_addr(27'd0), .scan_rd(1'b0), .scan_dout(), .scan_ok(),
    .p0_addr(p0_addr_r), .p0_rd(p0_rd_r), .p0_dout(p0_dout), .p0_ok(p0_ok),
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

  integer submit_n = 0;
  task submit_stage;
    begin
      wmem(32'h200002, 64'd0);          // target_buf
      wmem(32'h200004, 64'd0);          // flags = 0 (no CLEAR)
      wmem(32'h200007, 64'd1);          // C_SRCSEL = 1
      wmem(32'h200001, 64'd2);          // cmd_count = 2 (STAGE + END)
      wmem(32'h200008, {32'd0, 32'h0800_0004});
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

  integer k, settle, bad, bad_sameframe;
  reg [63:0] got, want;
  initial begin
    for (i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    for (k=0;k<NQW;k=k+1) mem[SRC_WIN + k] = {pat(k),pat(k),pat(k),pat(k)};
    for (k=0;k<NQW;k=k+1) begin
      schip.Bank0[((SDRAM_DEST+k*8)>>3)*4 + 0] = 16'hDEAD;
      schip.Bank0[((SDRAM_DEST+k*8)>>3)*4 + 1] = 16'hDEAD;
      schip.Bank0[((SDRAM_DEST+k*8)>>3)*4 + 2] = 16'hDEAD;
      schip.Bank0[((SDRAM_DEST+k*8)>>3)*4 + 3] = 16'hDEAD;
    end

    repeat (16) @(posedge clk_sys); reset = 1'b0; repeat (8) @(posedge clk_sys);

    settle=0;
    while (sdram_init) begin @(posedge clk_sys); settle=settle+1;
      if (settle>2_000_000) begin $display("RESULT: FAIL - SDRAM init never completed"); $finish; end end
    $display("SDRAM init done after %0d cyc", settle);

    // PRIME ch5 (P_SRC) with the pre-stage SDRAM contents (sentinel) so a later
    // same-frame read returns the STALE cached line deterministically. Mirrors HW
    // where ch5 holds lines from prior frames' atlases.
    for (k=0;k<NQW;k=k+1) p0_read(SDRAM_DEST + 27'(k*8), got);
    $display("ch5 primed with pre-stage SDRAM contents (sentinel 0xDEAD)");

    // SAME-FRAME: STAGE the atlas, then read it via P_SRC with NO vs in between.
    submit_stage;
    settle=0;
    while (done_seq !== submit_n[31:0] && settle < 20_000_000) begin @(posedge clk_sys); settle=settle+1; end
    if (done_seq !== submit_n[31:0]) begin $display("RESULT: FAIL - STAGE never completed (blt.state=%0d)", blt.state); $finish; end
    $display("STAGE completed in %0d cyc (NO vs issued — same-frame read follows)", settle);

    // *** DELIBERATELY NO vs HERE (the bug): engine reads the staged surface in the
    //     SAME frame, before any video vsync flushes ch1 / invalidates ch5. ***

    bad=0;
    for (k=0;k<NQW;k=k+1) begin
      want = {pat(k),pat(k),pat(k),pat(k)};
      p0_read(SDRAM_DEST + 27'(k*8), got);
      if (got !== want) begin
        bad = bad + 1;
        if (bad <= 6) $display("  SAME-FRAME MISMATCH qw %0d @%h: got=%016h want=%016h%s",
                               k, SDRAM_DEST+k*8, got, want,
                               (got === 64'hDEADDEADDEADDEAD) ? "  [STALE ch5 / pre-stage SDRAM]" : "");
      end
    end

    bad_sameframe = bad;
    if (bad != 0) begin
      $display("REPRO: bug reproduced — %0d/%0d staged qwords read STALE same-frame", bad, NQW);
      $display("ROOT CAUSE: ch1 STAGE write not committed + ch5 P_SRC not invalidated until vs");
      $display("            (sdram_fb_cache.sv coherency keyed on vs-rising, not STAGE-done).");
    end else begin
      $display("REPRO: no staleness — same-frame STAGE->P_SRC read returned the pattern");
      $display("       (intra-frame STAGE-barrier coherency present: ch1 committed + ch5");
      $display("        invalidated on STAGE-done, BEFORE the same-frame source read).");
    end

    // CONTROL: issue a vs (as tb_stage_psrc does) and re-read; this MUST pass.
    @(posedge clk_sys); #1; vs_r=1'b1; repeat(4) @(posedge clk_sys); #1; vs_r=1'b0;
    settle=0; while (coh_busy) begin @(posedge clk_sys); settle=settle+1;
      if (settle>2_000_000) begin $display("RESULT: FAIL - coh_busy stuck"); $finish; end end
    bad=0;
    for (k=0;k<NQW;k=k+1) begin
      want = {pat(k),pat(k),pat(k),pat(k)};
      p0_read(SDRAM_DEST + 27'(k*8), got);
      if (got !== want) bad = bad + 1;
    end
    if (bad==0) $display("CONTROL (after vs): PASS — staged atlas reads correctly post-flush");
    else        $display("CONTROL (after vs): UNEXPECTED FAIL (%0d/%0d) — staging itself broken", bad, NQW);

    // GATING: the same-frame STAGE->P_SRC read MUST return the staged pattern (the
    // intra-frame STAGE-barrier fix). This is now a regression assertion, not just a
    // diagnostic — a stale same-frame read (the original bug) fails the suite.
    if (bad_sameframe != 0)
      $display("RESULT: FAIL - same-frame STAGE->P_SRC read STALE (%0d/%0d) — intra-frame barrier missing/broken", bad_sameframe, NQW);
    else if (bad != 0)
      $display("RESULT: FAIL - staging broken even after vs (separate from the same-frame hole)");
    else
      $display("RESULT: PASS");
    $finish;
  end

  initial begin
    #500_000_000;
    $display("RESULT: FAIL - global timeout (done=%0d)", done_seq);
    $finish;
  end
endmodule
`default_nettype wire
