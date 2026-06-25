// tb_fbcopy_dst2src_sameframe.sv — SAME-FRAME ch0(P_DST) -> ch5(P_SRC) carry-forward
// coherency reproduction + gate (the single-pipeline overworld "two locations" bug).
//
// THE BUG. Every non-clear frame the engine carry-forwards the previously-composited
// framebuffer into this frame's target FB before drawing the incremental diff
// (mister_blitter_renderer.cpp: blt_blit_fb_copy → a full-screen FB->FB BLIT). The
// source FB was written by the compositor through P_DST/ch0; the carry-forward reads it
// back through P_SRC/ch5 — a SEPARATE jtframe_cache over the SAME SDRAM. ch0 is write-
// back and ch5 caches stale lines, and the only commit+invalidate is on display-vsync
// (async to frame processing). So the carry-forward reads STALE pixels: FB0 and FB1 stop
// sharing state and diverge into two independent incremental canvases — on screen the
// hero/NPCs flip between two frames (the burst the user captured). Exposed on every frame
// once C_SRCSEL=1 routed ALL source reads (incl. the carry-forward) through ch5.
//
// THE FIX (under test). blt_blit_fb_copy tags the carry-forward BLIT with BLT_F_SRC_FB.
// blitter_top sees F_SRC_FB and, BEFORE the source fetch, pulses dst_barrier and holds
// until dst_barrier_busy clears; sdram_fb_cache commits ch0 (P_DST) + invalidates ch5
// (P_SRC) — the same flush0/INVAL_MASK0 the vsync uses, but handshaked intra-frame and
// raising dst_busy (not the global coh_busy, so the scanout fetch is not stalled).
//
// METHOD (uses the REAL datapath for seeding so SDRAM addressing is automatic):
//   seed   : FILL FB0=SENTINEL (ch0) + flush  -> SDRAM FB0 = SENTINEL
//   prime  : carry-forward FB0->FB1 (reads ch5) -> ch5 caches SENTINEL
//   dirty  : FILL FB0=NEW (ch0, NO flush)      -> ch0 dirty=NEW, SDRAM=SENTINEL, ch5=SENTINEL
//   copy   : carry-forward FB0->FB1            -> reads FB0 via ch5
//   verify : flush + scan(ch4) FB1
//     - WITHOUT F_SRC_FB (Phase A): no barrier -> ch5 returns STALE SENTINEL -> FB1=SENTINEL  (REPRO)
//     - WITH    F_SRC_FB (Phase B): barrier commits ch0 + invalidates ch5 -> FB1=NEW          (FIX)
//
// Verdict: GATING. RESULT: PASS iff Phase B (the fixed carry-forward) reads NEW. Phase A
// is the diagnostic REPRO line (reports the staleness the fix removes); it does not gate.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
`include "vram_defs.vh"

module tb_fbcopy_dst2src_sameframe;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = 32'h206000;

  reg clk_sys = 0;   always #5 clk_sys   = ~clk_sys;
  reg clk_sdram = 1; always #5 clk_sdram = ~clk_sdram;
  reg reset = 1;

  // small rect inside the FB (full-FB row stride so the FILL/copy match the engine).
  localparam integer W = 16, H = 8;
  localparam integer ROW_QW  = W/4;              // 4 qwords across the rect
  localparam integer FB_ROW_B = 320*2;           // 640 B — full FB row stride
  localparam [7:0]   F_SRC_SDRAM = 8'h10, F_SRC_FB = 8'h20;
  localparam [15:0]  SENTINEL = 16'hDEAD;

  // ================= BLITTER -> VRAM DEMUX ==================================
  wire [31:0] bt_addr; wire bt_rd, bt_wr; wire [63:0] bt_din; wire [7:0] bt_be;
  wire [7:0]  bt_burstcnt; wire bt_idle; wire [31:0] blt_dbg;
  wire [63:0] blt_demux_dout; wire blt_demux_dready, blt_busy_w;
  wire [28:0] bd_addr; wire bd_rd, bd_wr; wire [63:0] bd_din; wire [7:0] bd_be;
  wire        b_grant; wire blt_arb_busy;
  wire [26:0] bs_p0_addr; wire bs_p0_rd; wire [63:0] cp0_dout; wire cp0_ok;
  wire        bs_we;        wire [15:0] bs_din;  wire [26:0] bs_waddr;
  wire        bs_we_burst;  wire [63:0] bs_din64; wire stage_ok;
  wire        blt_stage_barrier;                 // unused (no STAGE in this bench)
  wire        blt_dst_barrier; wire blt_dst_busy;// carry-forward ch0->ch5 barrier

  blitter_top blt (
    .clk(clk_sys), .rst(reset),
    .mem_addr(bt_addr), .mem_rd(bt_rd), .mem_wr(bt_wr), .mem_burstcnt(bt_burstcnt),
    .mem_din(bt_din), .mem_be(bt_be),
    .mem_dout(blt_demux_dout), .mem_dout_ready(blt_demux_dready), .mem_busy(blt_busy_w),
    .p0_addr(bs_p0_addr), .p0_rd(bs_p0_rd), .p0_dout(cp0_dout), .p0_ok(cp0_ok),
    .src_sdram_we(bs_we), .src_sdram_din(bs_din), .src_sdram_waddr(bs_waddr),
    .src_sdram_we_burst(bs_we_burst), .src_sdram_din64(bs_din64),
    .src_sdram_ok(stage_ok),
    .stage_barrier(blt_stage_barrier), .stage_barrier_busy(1'b0),
    .dst_barrier(blt_dst_barrier), .dst_barrier_busy(blt_dst_busy),
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
    .dbg());

  ddr_blitter_arb #(.ENABLE(1'b1)) arb_ddr (
    .clk(clk_sys), .reset(reset),
    .rdr_burstcnt(8'd0), .rdr_addr(29'd0), .rdr_rd(1'b0), .rdr_din(64'd0),
    .rdr_be(8'd0), .rdr_we(1'b0), .rdr_busy(), .rdr_grant(),
    .blt_burstcnt(bt_burstcnt), .blt_addr(bd_addr), .blt_rd(bd_rd), .blt_din(bd_din),
    .blt_be(bd_be), .blt_we(bd_wr), .blt_busy(blt_arb_busy), .blt_grant(b_grant),
    .ddram_busy(d_busy), .ddram_dout_ready(d_dready),
    .ddram_burstcnt(d_burst), .ddram_addr(d_addr), .ddram_rd(d_rd),
    .ddram_din(d_din), .ddram_be(d_be), .ddram_we(d_we), .dbg());

  // ================= SDRAM framebuffer cache ===============================
  reg  [26:0] scan_addr_r = 27'd0;  reg scan_rd_r = 1'b0;
  wire [63:0] scan_dout;  wire scan_ok;
  reg         vs_r = 1'b0;  wire coh_busy;
  wire        sdram_init;
  wire [15:0] SDQ; wire [12:0] SA; wire SDQML, SDQMH; wire [1:0] SBA;
  wire        SnCS, SnWE, SnRAS, SnCAS, SCKE, cache_sdram_clk;

  sdram_fb_cache fbcache (
    .clk(clk_sys), .clk_sdram(clk_sys), .rst(reset), .init(sdram_init),
    .dst_addr(dst_addr), .dst_rd(dst_rd), .dst_wr(dst_wr),
    .dst_din(dst_din), .dst_wdsn(dst_wdsn), .dst_dout(dst_dout), .dst_ok(dst_ok),
    .scan_addr(scan_addr_r), .scan_rd(scan_rd_r), .scan_dout(scan_dout), .scan_ok(scan_ok),
    .p0_addr(bs_p0_addr), .p0_rd(bs_p0_rd), .p0_dout(cp0_dout), .p0_ok(cp0_ok),
    .stage_addr(bs_waddr), .stage_wr(bs_we_burst), .stage_din(bs_din64),
    .stage_wdsn(8'h00), .stage_ok(stage_ok),
    .vs(vs_r), .coh_busy(coh_busy),
    .stage_barrier(1'b0), .stage_busy(),
    .dst_barrier(blt_dst_barrier), .dst_busy(blt_dst_busy),
    .sdram_dq(SDQ), .sdram_a(SA), .sdram_dqml(SDQML), .sdram_dqmh(SDQMH),
    .sdram_ba(SBA), .sdram_nwe(SnWE), .sdram_ncas(SnCAS), .sdram_nras(SnRAS),
    .sdram_ncs(SnCS), .sdram_cke(SCKE), .sdram_clk(cache_sdram_clk));

  mt48lc16m16a2 #(.addr_bits(13), .col_bits(10)) schip (
    .Dq(SDQ), .Addr(SA), .Ba(SBA), .Clk(clk_sdram), .Cke(SCKE),
    .Cs_n(SnCS), .Ras_n(SnRAS), .Cas_n(SnCAS), .We_n(SnWE), .Dqm({SDQMH, SDQML}),
    .downloading(1'b0), .VS(1'b0), .frame_cnt(32'd0));

  // ================= behavioral DDR3 (command ring only) ====================
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

  // ---- command builders ----------------------------------------------------
  // FILL the WxH rect of FB[target] with `color` (compositor write via ch0/P_DST).
  task submit_fill(input [1:0] target, input [15:0] color);
    begin
      wmem(32'h200002, {62'd0, target});
      wmem(32'h200004, 64'd0);            // flags = 0 (no CLEAR)
      wmem(32'h200007, 64'd1);            // C_SRCSEL=1 (single pipeline), throttle=0
      wmem(32'h200001, 64'd2);            // cmd_count = 2 (FILL + END)
      wmem(32'h200008, {32'd0, 8'd0, 8'd0, 8'd0, 8'd2});          // op=FILL
      wmem(32'h200009, {16'(H), 16'(W), 16'd0, 16'd0});           // h|w|src_x|stride
      wmem(32'h20000A, 64'd0);                                    // dst_y|dst_x|0|src_y
      wmem(32'h20000B, {16'd0, color, 32'd0});                    // color at [47:32]
      wmem(32'h20000C, 64'd1);            // END
      wmem(32'h20000D, 64'd0); wmem(32'h20000E,64'd0); wmem(32'h20000F,64'd0);
      submit_n = submit_n + 1; wmem(32'h200000, submit_n[63:0]);
    end
  endtask

  // Carry-forward: COPY the WxH rect from FB0 (read via ch5/P_SRC) into FB[target].
  // use_fb_flag=1 tags it BLT_F_SRC_FB so the fabric fires the dst-barrier first.
  task submit_carryfwd(input [1:0] target, input use_fb_flag);
    reg [7:0] flags;
    begin
      flags = F_SRC_SDRAM | (use_fb_flag ? F_SRC_FB : 8'd0);
      wmem(32'h200002, {62'd0, target});
      wmem(32'h200004, 64'd0);
      wmem(32'h200007, 64'd1);            // C_SRCSEL=1
      wmem(32'h200001, 64'd2);            // BLIT + END
      // op=BLIT(3), blend=COPY(0), fmt=0, flags; src_off=SDRAM_FB0_BASE (byte base)
      wmem(32'h200008, {32'(`SDRAM_FB0_BASE), flags, 8'd0, 8'd0, 8'd3});
      wmem(32'h200009, {16'(H), 16'(W), 16'd0, 16'(FB_ROW_B)});   // h|w|src_x|stride
      wmem(32'h20000A, 64'd0);                                    // dst at 0,0; src_y=0
      wmem(32'h20000B, 64'd0);                                    // COPY: no key/alpha
      wmem(32'h20000C, 64'd1);            // END
      wmem(32'h20000D, 64'd0); wmem(32'h20000E,64'd0); wmem(32'h20000F,64'd0);
      submit_n = submit_n + 1; wmem(32'h200000, submit_n[63:0]);
    end
  endtask

  integer settle;
  task wait_done;
    begin
      settle = 0;
      while (done_seq !== submit_n[31:0]) begin
        @(posedge clk_sys); settle = settle + 1;
        if (settle > 40_000_000) begin
          $display("RESULT: FAIL - frame never completed (done=%0d submit=%0d blt.state=%0d)",
                   done_seq, submit_n, blt.state); $finish;
        end
      end
    end
  endtask

  task flush;   // vsync ch0 commit -> SDRAM + invalidate ch0/4/5
    begin
      @(posedge clk_sys); #1; vs_r=1'b1; repeat(4) @(posedge clk_sys); #1; vs_r=1'b0;
      settle=0; while (coh_busy) begin @(posedge clk_sys); settle=settle+1;
        if (settle>2_000_000) begin $display("RESULT: FAIL - coh_busy stuck (commit wedge)"); $finish; end end
    end
  endtask

  task scan_read(input [26:0] byte_addr, output [63:0] q);
    integer cyc;
    begin
      cyc=0; @(posedge clk_sys); #1; scan_addr_r=byte_addr; scan_rd_r=1'b1;
      @(posedge clk_sys); #1; scan_rd_r=1'b0;
      while (!scan_ok) begin @(posedge clk_sys); cyc=cyc+1;
        if (cyc>5000) begin $display("RESULT: FAIL - scan_read timeout @%h", byte_addr); $finish; end end
      q = scan_dout;
    end
  endtask

  // Read back FB1's rect; return count of qwords != expected16 (all 4 lanes).
  integer y, qw, lane;
  reg [63:0] got; reg [15:0] px;
  task count_fb1_mismatch(input [15:0] expect16, output integer bad, output [15:0] sample);
    begin
      bad = 0; sample = 16'h0;
      for (y=0; y<H; y=y+1) for (qw=0; qw<ROW_QW; qw=qw+1) begin
        scan_read(27'(`SDRAM_FB1_BASE) + 27'(y*FB_ROW_B + qw*8), got);
        for (lane=0; lane<4; lane=lane+1) begin
          px = got[lane*16 +:16];
          if (px !== expect16) begin bad = bad + 1; sample = px; end
        end
      end
    end
  endtask

  // run the seed/prime/dirty/copy sequence; return FB1 mismatch-vs-NEW count + a sample.
  integer bad; reg [15:0] sample;
  task run_phase(input use_fb_flag, input [15:0] newcol, output integer bad_o, output [15:0] samp_o);
    begin
      submit_fill(2'd0, SENTINEL); wait_done; flush;       // SDRAM FB0 = SENTINEL
      submit_carryfwd(2'd1, 1'b0); wait_done;              // prime ch5 with SENTINEL (FB1=SENTINEL)
      submit_fill(2'd0, newcol);   wait_done;              // ch0 dirty FB0=NEW (NO flush)
      submit_carryfwd(2'd1, use_fb_flag); wait_done;       // carry-forward FB0->FB1 via ch5
      flush;                                               // commit FB1 -> SDRAM for readback
      count_fb1_mismatch(newcol, bad_o, samp_o);
    end
  endtask

  integer hbc = 0;
  always @(posedge clk_sys) if (!reset) begin
    hbc = hbc + 1;
    if (hbc % 400000 == 0) begin
      $display("[hb %0t] blt.st=%0d done=%0d submit=%0d coh=%0b dstbusy=%0b",
               $time, blt.state, done_seq, submit_n, coh_busy, blt_dst_busy); $fflush;
    end
  end

  integer a_bad, b_bad; reg [15:0] a_s, b_s;
  initial begin
    for (i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    repeat (16) @(posedge clk_sys); reset=1'b0; repeat (8) @(posedge clk_sys);
    settle=0; while (sdram_init) begin @(posedge clk_sys); settle=settle+1;
      if (settle>2_000_000) begin $display("RESULT: FAIL - SDRAM init never completed"); $finish; end end
    $display("SDRAM init done after %0d cyc", settle);

    // ---- Phase A: carry-forward WITHOUT the F_SRC_FB barrier (the bug) --------
    $display("PHASE A: carry-forward WITHOUT BLT_F_SRC_FB (no dst-barrier)");
    run_phase(1'b0, 16'hBEEF, a_bad, a_s);
    if (a_bad != 0)
      $display("REPRO: bug reproduced — FB1 != NEW in %0d/%0d lanes (sample got=%04h want=BEEF)%s",
               a_bad, H*ROW_QW*4, a_s, (a_s===SENTINEL) ? "  [STALE ch5 / uncommitted ch0]" : "");
    else
      $display("REPRO: (no staleness observed without the flag — environment did not expose the hole)");

    // ---- Phase B: carry-forward WITH the F_SRC_FB barrier (the fix) -----------
    $display("PHASE B: carry-forward WITH BLT_F_SRC_FB (dst-barrier: commit ch0 + invalidate ch5)");
    run_phase(1'b1, 16'hCAFE, b_bad, b_s);
    if (b_bad == 0)
      $display("FIX: carry-forward read COHERENT — FB1 == NEW (CAFE) across all %0d lanes", H*ROW_QW*4);
    else
      $display("FIX FAILED: FB1 != NEW in %0d/%0d lanes (sample got=%04h want=CAFE)%s",
               b_bad, H*ROW_QW*4, b_s, (b_s===SENTINEL) ? "  [STALE — barrier ineffective]" : "");

    // ---- gate on the fix (Phase B). Phase A is diagnostic only. --------------
    if (b_bad != 0)
      $display("RESULT: FAIL - carry-forward STALE even with BLT_F_SRC_FB (%0d/%0d) — dst-barrier missing/broken",
               b_bad, H*ROW_QW*4);
    else
      $display("RESULT: PASS");
    $finish;
  end

  initial begin
    #2_000_000_000;
    $display("RESULT: FAIL - global sim timeout (done=%0d submit=%0d)", done_seq, submit_n);
    $finish;
  end
endmodule
`default_nettype wire
