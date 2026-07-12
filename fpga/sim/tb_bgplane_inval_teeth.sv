// tb_bgplane_inval_teeth.sv — [#112][#95] INVAL_MASK1 barrier-teeth strengthening.
//
// PURPOSE. The merged #95 fix makes blitter_top pulse `stage_barrier` after every
// OP_BGPLANE_WRITE STAGE bake; the stage-barrier sequencer in sdram_fb_cache flushes
// ch1's STAGE writes to SDRAM and then invalidates the ch5 (P_SRC) cache lines via
//   INVAL_MASK1 = 8'b0010_0000
// (sdram_fb_cache.sv ~L163-222, L415-418, passed to jtframe_cache_mux_flush). The
// compositor reads each plane through ch5. If that invalidation regressed — wrong
// mask bit, mask zeroed, or the barrier not firing — a per-frame COPY read of a
// RE-BAKED plane base would return a STALE cached line from the PREVIOUS bake.
//
// tb_bgplane_maptrans proves the happy path (A->B->C to a reused base reads fresh).
// This TB is the intended STRENGTHENING named in that TB's header: it makes the
// assertion coverage tight enough that an INVAL_MASK1 regression FAILS the suite.
// It does that by attacking the exact failure mechanism head-on:
//
//   1. Bake map A (a distinct sentinel fill) to plane base X.
//   2. WARM ch5 by reading base X's lines back through the P_SRC port (returns A) —
//      and crucially re-warm a COMPACT probe cluster LAST so those lines are the
//      freshest resident ch5 lines going into the next bake.
//   3. RE-BAKE a DIFFERENT map B (distinct sentinel) to the SAME base X. This fires
//      stage_barrier -> INVAL_MASK1 -> ch5 invalidate.
//   4. Re-read base X through ch5, PROBE CLUSTER FIRST, and HARD-ASSERT it returns B,
//      never stale A. A read returning A is the exact INVAL_MASK1 regression signature.
//
// TEETH. Several bake->warm->rebake->reread cycles run across a few DISTINCT bases
// with a DISTINCT sentinel per (base,cycle). Every reread is asserted. Because the
// compact probe cluster is re-warmed last each cycle (so it occupies ch5's small RO
// cache) and reread FIRST after the rebake, a partially-broken mask — invalidating
// the wrong channel, a 1-deep pending-latch miss, or a no-op mask — surfaces as a
// stale-sentinel mismatch on the very first probe read. An extra two-base interleave
// occupies BOTH ch5 RO blocks with different bases before rebaking one, so an
// over/under-scoped invalidate is caught too.
//
// Harness (2-die XL sdram_fb_cache #(.SDRAM_AW(25)) + ch5 P_SRC readback driving
// blitter_top OP_BGPLANE_WRITE) is reused verbatim from tb_bgplane_maptrans.sv /
// tb_bgplane_write_pipe_xl.sv. Geometry is reduced by default (CELL_ROWS=12) so this
// runs in the PR tier; +define+BGPLANE_INVAL_FULL restores the full 240-row plane
// (nightly), mirroring maptrans's BGPLANE_MAPTRANS_FULL.
//
// Pass protocol (run_sims.sh FAIL regex = FAIL|DEADLOCK|STARV|WEDGE|Assertion failed|
// PROTO:|TIMEOUT): the happy path prints none of those substrings and uses no bare
// SystemVerilog assert. Mismatches increment `errs` and print a MISMATCH line; the
// run prints "RESULT: PASS" only when errs==0, else a line containing FAIL.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"

module tb_bgplane_inval_teeth;
  localparam [31:0] RINGB = 32'h200008;   // ring slot0 (window idx, 0x3B000040)
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h8000;

  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  // free-running vblank so S_SNAP_* drains after every submit + the ch0 coherency
  // flush commits dirty lines to the physical dies before a ch5 readback.
  reg vs = 0; integer vsc = 0;
  always @(posedge clk) begin
    vsc <= vsc + 1;
    if (vsc >= 256) begin vs <= ~vs; vsc <= 0; end
  end

  // ---- behavioral command-ring DDR (single-beat reads, latency + backpressure) ----
  reg [63:0] mem [0:MEMQW-1];
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat; reg [1:0] bp = 0;
  always @(posedge clk) bp <= bp + 2'd1;
  wire [31:0] bt_addr; wire b_rd, b_we; wire [63:0] b_din; wire [7:0] b_be; wire bt_idle;
  wire [7:0] bt_burst;
  reg  d_dready; reg [63:0] d_dout;
  wire d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  integer i;
  always @(posedge clk) begin
    d_dready <= 1'b0;
    if (rst) begin rbeats <= 0; rlat <= 0; end
    else begin
      if (rlat != 3'd0) rlat <= rlat - 3'd1;
      else if (rbeats != 8'd0) begin
        if (bp == 2'd2) begin
          d_dout <= mem[raddr - WBASE]; d_dready <= 1'b1;
          raddr <= raddr + 29'd1; rbeats <= rbeats - 8'd1;
        end
      end else if (!d_busy) begin
        if (b_rd) begin rbeats <= bt_burst; raddr <= bt_addr[28:0]; rlat <= 3'd3; end
        else if (b_we) for (i = 0; i < 8; i = i + 1)
          if (b_be[i]) mem[(bt_addr[28:0] - WBASE)][i*8 +: 8] <= b_din[i*8 +: 8];
      end
    end
  end

  // ---- on-chip dest framebuffer [FB-in-BRAM] ----
  wire fb_wr_en; wire [14:0] fb_wr_qw; wire [1:0] fb_wr_lane; wire [15:0] fb_wr_pix;
  wire fb_rd_en; wire [14:0] fb_rd_qw; wire [63:0] fb_rd_qword;
  comp_fbram fbram (.clk(clk),
    .wr_en(fb_wr_en), .wr_qw(fb_wr_qw), .wr_lane(fb_wr_lane), .wr_pix(fb_wr_pix),
    .rd_en(fb_rd_en), .rd_qw(fb_rd_qw), .rd_qword(fb_rd_qword));

  // ---- ch0 (P_DST) write port (driven by blitter_top) + ch5 (P_SRC) read port
  //      (driven by THIS TB for readback): real sdram_fb_cache XL + 2 mt48 dies ----
  wire        dst_wr;
  wire [26:0] dst_addr;
  wire [63:0] dst_din;
  wire [7:0]  dst_wdsn;
  wire        dst_ok;
  wire        coh_busy;

  reg  [26:0] p0_addr;   // ch5 P_SRC read address (TB-driven)
  reg         p0_rd;
  wire [63:0] p0_dout;
  wire        p0_ok;

  wire [15:0] sdram_dq;
  wire [12:0] sdram_a;
  wire        sdram_dqml, sdram_dqmh;
  wire [1:0]  sdram_ba;
  wire        sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke, sdram_clk;

  // [bgplane bake -> STAGE reroute] wire blitter_top's STAGE outputs into cache ch1.
  wire        stage_we_burst_w;
  wire [63:0] stage_din64_w;
  wire [26:0] stage_waddr_w;
  wire        stage_ok_w;
  wire        stage_barrier_w;
  wire        stage_busy_w;

  sdram_fb_cache #(.SDRAM_AW(25)) u_cache (
    .clk(clk), .clk_sdram(clk), .rst(rst),
    .init(),
    .dst_addr(dst_addr), .dst_rd(1'b0), .dst_wr(dst_wr),
    .dst_din(dst_din), .dst_wdsn(dst_wdsn), .dst_dout(), .dst_ok(dst_ok),
    .scan_addr(27'd0), .scan_rd(1'b0), .scan_dout(), .scan_ok(),
    .p0_addr(p0_addr), .p0_rd(p0_rd), .p0_dout(p0_dout), .p0_ok(p0_ok),
    .stage_addr(stage_waddr_w), .stage_wr(stage_we_burst_w), .stage_din(stage_din64_w),
    .stage_wdsn(8'h00), .stage_ok(stage_ok_w),
    .vs(vs), .coh_busy(coh_busy),
    .stage_barrier(stage_barrier_w), .stage_busy(stage_busy_w),
    .dst_barrier(1'b0), .dst_busy(),
    .sdram_dq(sdram_dq), .sdram_a(sdram_a),
    .sdram_dqml(sdram_dqml), .sdram_dqmh(sdram_dqmh), .sdram_ba(sdram_ba),
    .sdram_nwe(sdram_nwe), .sdram_ncas(sdram_ncas), .sdram_nras(sdram_nras),
    .sdram_ncs(sdram_ncs), .sdram_cke(sdram_cke), .sdram_clk(sdram_clk)
  );

  // [XL 2-chip] MiSTer 128MB = 2 dies selected via sdram_ncs = cmd_cs ^ sel_chip
  // (jtframe_burst_io). Tap the controller's registered sel_chip and reconstruct
  // each die's command-CS. Verbatim wiring from tb_sdram_fb_cache_xl.sv.
  wire sc   = u_cache.u_sdram_ctrl.u_io.sel_chip_r;
  wire ncs0 = sc ? 1'b1 : sdram_ncs;      // die0 sees the command only when sel_chip=0
  wire ncs1 = sc ? ~sdram_ncs : 1'b1;     // die1 sees it only when sel_chip=1
  mt48lc16m16a2 #(.addr_bits(13), .col_bits(10)) u_chip0 (
    .Clk(clk), .Cke(sdram_cke), .Dq(sdram_dq), .Addr(sdram_a), .Ba(sdram_ba),
    .Cs_n(ncs0), .Ras_n(sdram_nras), .Cas_n(sdram_ncas), .We_n(sdram_nwe),
    .Dqm({sdram_dqmh, sdram_dqml}), .downloading(1'b0), .VS(1'b0), .frame_cnt(0));
  mt48lc16m16a2 #(.addr_bits(13), .col_bits(10)) u_chip1 (
    .Clk(clk), .Cke(sdram_cke), .Dq(sdram_dq), .Addr(sdram_a), .Ba(sdram_ba),
    .Cs_n(ncs1), .Ras_n(sdram_nras), .Cas_n(sdram_ncas), .We_n(sdram_nwe),
    .Dqm({sdram_dqmh, sdram_dqml}), .downloading(1'b0), .VS(1'b0), .frame_cnt(0));

  // ---- DUT ----
  blitter_top blt (.clk(clk), .rst(rst), .vs(vs),
    .mem_addr(bt_addr), .mem_rd(b_rd), .mem_wr(b_we), .mem_burstcnt(bt_burst),
    .mem_din(b_din), .mem_be(b_be),
    .mem_dout(d_dout), .mem_dout_ready(d_dready), .mem_busy(d_busy),
    .p0_addr(), .p0_rd(), .p0_dout(64'd0), .p0_ok(1'b0),
    .src_sdram_we_burst(stage_we_burst_w), .src_sdram_din64(stage_din64_w),
    .src_sdram_waddr(stage_waddr_w), .src_sdram_ok(stage_ok_w),
    .stage_barrier(stage_barrier_w), .stage_barrier_busy(stage_busy_w),
    .fb_wr_en(fb_wr_en), .fb_wr_qw(fb_wr_qw), .fb_wr_lane(fb_wr_lane), .fb_wr_pix(fb_wr_pix),
    .fb_rd_en(fb_rd_en), .fb_rd_qw(fb_rd_qw), .fb_rd_qword(fb_rd_qword),
    .dst_wr(dst_wr), .dst_addr(dst_addr), .dst_din(dst_din), .dst_wdsn(dst_wdsn), .dst_ok(dst_ok),
    .idle(bt_idle));

  // ---- command-ring helpers (mirrors tb_bgplane_maptrans.sv) ----
  integer submit_n = 0;
  task set_ctrl(input integer ncmds, input integer flags);
    begin
      mem[32'h200001] = ncmds;
      mem[32'h200002] = 64'd0;      // target_buf=0
      mem[32'h200003] = 64'd0;      // clear_color
      mem[32'h200004] = flags;
      mem[32'h200007] = 64'd2;      // C_PIPE=1
    end
  endtask

  task wr_fill(input integer slot, input [15:0] dx, input [15:0] dy,
               input [15:0] w, input [15:0] h, input [15:0] color);
    integer base;
    begin
      base = RINGB + slot*4;
      mem[base+0] = 64'h0000_0000_0000_0002;             // opcode=FILL
      mem[base+1] = {h, w, 32'd0};
      mem[base+2] = {dy, dx, 32'd0};
      mem[base+3] = {16'd0, color, 32'd0};
    end
  endtask

  // OP_BGPLANE_WRITE: dst_x|dst_y<<16 = absolute plane qword offset; src_x = dst_stride_qw.
  task wr_bgw(input integer slot, input [31:0] base_qw, input [15:0] stride_qw);
    integer base;
    begin
      base = RINGB + slot*4;
      mem[base+0] = {32'd0, 8'd0, 8'd0, 8'd0, OP_BGPLANE_WRITE};
      mem[base+1] = {32'd0, stride_qw, 16'd0};
      mem[base+2] = {base_qw[31:16], base_qw[15:0], 32'd0};
      mem[base+3] = 64'd0;
    end
  endtask

  task run_submit;
    integer to;
    begin
      submit_n = submit_n + 1;
      mem[32'h200000] = submit_n;
      to = 0;
      while (mem[32'h200005][31:0] !== submit_n[31:0] && to < 4000000) begin @(posedge clk); to = to + 1; end
      if (mem[32'h200005][31:0] !== submit_n[31:0]) $display("  submit %0d never acked (to=%0d) - WEDGE", submit_n, to);
      repeat (10) @(posedge clk);
    end
  endtask

  // wait for one more vs rising edge + coh_busy to clear (flushes ch0's dirty
  // lines to the physical dies before a ch5 readback).
  task flush_to_sdram;
    integer to;
    begin
      to = 0;
      while (!vs && to < 400) begin @(posedge clk); to = to + 1; end
      while (vs  && to < 400) begin @(posedge clk); to = to + 1; end
      to = 0;
      while (coh_busy && to < 40000) begin @(posedge clk); to = to + 1; end
      repeat (10) @(posedge clk);
    end
  endtask

  // ch5 P_SRC read: pulse p0_rd one cycle with p0_addr, wait p0_ok. A cold miss
  // fetches the block fresh from SDRAM; a warm hit returns the CACHED line (the whole
  // point — a rebake must have invalidated it, else this returns the prior sentinel).
  task p0_read(input [26:0] a, output [63:0] q);
    integer cyc;
    begin
      while (coh_busy) @(posedge clk);
      @(posedge clk); #1;
      p0_addr = a; p0_rd = 1'b1;
      @(posedge clk); #1; p0_rd = 1'b0;
      cyc = 0;
      while (!p0_ok) begin @(posedge clk); #1; cyc = cyc + 1;
        if (cyc > 4000) begin $display("RESULT: FAIL - p0_read timeout @%h", a); $finish; end end
      q = p0_dout;
    end
  endtask

  // ---- geometry (reduced by default; +BGPLANE_INVAL_FULL restores full plane) ----
  localparam integer CELL_ROW_QW = 80;    // 320 px / 4 px-per-qword
`ifdef BGPLANE_INVAL_FULL
  localparam integer CELL_ROWS = 240;     // full HW plane height (nightly)
`else
  localparam integer CELL_ROWS = 6;       // reduced: enough strided rows for coverage
`endif
  localparam integer STRIDE_QW = 100;     // > CELL_ROW_QW=80 (wide plane stride)

  // ---- distinct plane bases (chip1 high banks, as write_pipe_xl / maptrans) ----
  // Each base is REUSED across its bake cycles (the whole point). Two of them are also
  // co-resident in ch5 for the interleave scenario.
  localparam integer BASE_A = 32'h00A8_0000;   // 84 MiB, chip1 bank1
  localparam integer BASE_B = 32'h00C0_0000;   // 96 MiB, chip1 bank2
  localparam integer BASE_C = 32'h00D0_0000;   // 104 MiB, chip1 bank3

  localparam integer NCYCLES = 3;   // bake->warm->rebake reread cycles per base

  // Distinct non-zero RGB565 sentinel per (base-index, cycle). Any two entries differ,
  // so a stale prior-bake ch5 line is unambiguous. base 0..2, cycle 0..2 -> 9 values.
  function automatic [15:0] sentinel(input integer bidx, input integer cyc);
    begin
      case (bidx*4 + cyc)
        0:  sentinel = 16'h001F;  1:  sentinel = 16'hF800;  2:  sentinel = 16'h07E0;   // base0
        4:  sentinel = 16'hFFE0;  5:  sentinel = 16'hF81F;  6:  sentinel = 16'h07FF;   // base1
        8:  sentinel = 16'hAAAA;  9:  sentinel = 16'h5555;  10: sentinel = 16'h1234;   // base2
        default: sentinel = 16'h89AB;
      endcase
    end
  endfunction

  // Compact probe cluster: 4 consecutive qwords at the plane base — all inside one ch5
  // RO cache line, so re-warming them LAST makes them the freshest resident lines. These
  // are reread FIRST after a rebake: a missed INVAL_MASK1 returns the prior sentinel here.
  localparam integer NPROBE = 4;
  // Broad strided sample across the plane for banding/coverage: row extremes + both
  // column halves of the cell (col<40 left, >=40 right).
  localparam integer NCOLS = 4;
  integer csamp [0:NCOLS-1];

`ifndef BGPLANE_INVAL_FULL
  // Fabric bake volume = blitter_top's fbram_to_sdram (u_bgw: FB_QWORDS=19200,
  // CELL_ROWS=240). Override to the reduced window so the streamer bakes only
  // CELL_ROWS rows -- strided per-row advance identical, fewer repetitions.
  // (TB-only; no production RTL change.)
  defparam blt.u_bgw.FB_QWORDS = CELL_ROWS*CELL_ROW_QW;
  defparam blt.u_bgw.CELL_ROWS = CELL_ROWS;
`endif

  integer bidx, cyc, r, ci, k, errs, mism;
  integer base_of [0:2];
  reg [63:0] got, exp64, stale64;
  reg [15:0] want16, prev16;

  // Paint a uniform sentinel fill covering the whole baked cell into comp_fbram WORK,
  // then bake OP_BGPLANE_WRITE to `pbase` (fires stage_barrier -> INVAL_MASK1), flush.
  task bake_map(input integer pbase, input [15:0] color);
    begin
      set_ctrl(2, 0);   // 1 FILL + END
      wr_fill(0, 16'd0, 16'd0, 16'd320, 16'(CELL_ROWS), color);
      mem[RINGB + 1*4] = 64'd1;   // END
      run_submit;

      set_ctrl(2, 0);   // 1 OP_BGPLANE_WRITE + END
      wr_bgw(0, pbase, STRIDE_QW[15:0]);
      mem[RINGB + 1*4] = 64'd1;   // END
      run_submit;
      flush_to_sdram;
    end
  endtask

  // Read + assert the compact probe cluster at `pbase` == `color`. On a stale line the
  // prior sentinel `prev` (if any) is flagged explicitly as the INVAL_MASK1 signature.
  task check_probe(input integer pbase, input [15:0] color, input [15:0] prev,
                   input integer has_prev, input integer bidx_i, input integer cyc_i);
    begin
      exp64   = {color, color, color, color};
      stale64 = {prev,  prev,  prev,  prev};
      for (k = 0; k < NPROBE; k = k + 1) begin
        p0_read((pbase + k) * 8, got);
        if (got !== exp64) begin
          if (mism < 8) begin
            if (has_prev && got === stale64)
              $display("  MISMATCH inval-teeth STALE (base%0d cyc%0d qw%0d): read prior-bake %h -> ch5 NOT invalidated after rebake to reused base (INVAL_MASK1 regressed)",
                       bidx_i, cyc_i, k, got);
            else
              $display("  MISMATCH inval-teeth (base%0d cyc%0d qw%0d): got=%h want=%h", bidx_i, cyc_i, k, got, exp64);
          end
          mism = mism + 1;
        end
      end
    end
  endtask

  // Re-warm the compact probe cluster (read it) so its ch5 line is the freshest resident
  // line going into the NEXT rebake — this is what gives the teeth their bite.
  task warm_probe(input integer pbase);
    begin
      for (k = 0; k < NPROBE; k = k + 1) p0_read((pbase + k) * 8, got);
    end
  endtask

  initial begin
    for (i = 0; i < MEMQW; i = i + 1) mem[i] = 64'd0;
    mem[32'h200000] = 64'd0; mem[32'h200005] = 64'd0;
    p0_addr = 27'd0; p0_rd = 1'b0;
    csamp[0] = 0; csamp[1] = 39; csamp[2] = 40; csamp[3] = CELL_ROW_QW-1;   // 0,39,40,79
    base_of[0] = BASE_A; base_of[1] = BASE_B; base_of[2] = BASE_C;
    errs = 0; mism = 0;

    repeat (8) @(posedge clk); rst <= 0;
    // wait for the cache's SDRAM init to complete
    begin : wait_init
      integer wi;
      for (wi = 0; wi < 30000; wi = wi + 1) begin
        @(posedge clk);
        if (!u_cache.init) disable wait_init;
      end
    end
    repeat (4) @(posedge clk);

    // ======================================================================
    // Scenario 1 — BAKE -> WARM -> REBAKE -> REREAD teeth, per distinct base.
    // For each base, run NCYCLES bakes to the SAME base with a DISTINCT sentinel each
    // cycle. Every cycle: (a) bake sentinel S_cyc; (b) reread the COMPACT PROBE CLUSTER
    // FIRST and hard-assert == S_cyc -- entering cyc>=1 that cluster is WARM from the
    // prior cycle's warm_probe, so a fresh result here can ONLY mean the rebake's
    // stage_barrier invalidated ch5 (INVAL_MASK1). A stale line reads the prior sentinel
    // and is flagged. (c) sweep strided samples for banding coverage. (d) re-warm the
    // probe cluster so it is the freshest resident ch5 line for the next rebake.
    // ======================================================================
    for (bidx = 0; bidx < 3; bidx = bidx + 1) begin
      mism = 0;
      for (cyc = 0; cyc < NCYCLES; cyc = cyc + 1) begin
        want16 = sentinel(bidx, cyc);
        prev16 = (cyc > 0) ? sentinel(bidx, cyc-1) : 16'h0000;

        bake_map(base_of[bidx], want16);

        // (b) probe cluster FIRST -- the teeth. Warm from the prior cycle when cyc>=1.
        check_probe(base_of[bidx], want16, prev16, (cyc > 0) ? 1 : 0, bidx, cyc);

        // (c) strided coverage sweep across the plane.
        exp64 = {want16, want16, want16, want16};
        for (r = 0; r < CELL_ROWS; r = r + 1) begin
          for (ci = 0; ci < NCOLS; ci = ci + 1) begin
            p0_read((base_of[bidx] + r*STRIDE_QW + csamp[ci]) * 8, got);
            if (got !== exp64) begin
              if (mism < 8)
                $display("  MISMATCH inval-teeth sweep (base%0d cyc%0d row%0d col%0d): got=%h want=%h",
                         bidx, cyc, r, csamp[ci], got, exp64);
              mism = mism + 1;
            end
          end
        end

        // (d) re-warm the probe cluster so it is the freshest resident ch5 line.
        warm_probe(base_of[bidx]);
      end
      if (mism == 0)
        $display("INVAL-TEETH base%0d (%0d bake->warm->rebake->reread cycles to reused base %h, every reread fresh not stale): PASS",
                 bidx, NCYCLES, base_of[bidx]);
      else
        $display("INVAL-TEETH base%0d: FAIL (%0d mismatches)", bidx, mism);
      errs = errs + mism;
    end

    // ======================================================================
    // Scenario 2 — TWO-BASE INTERLEAVE (over/under-scoped invalidate).
    // Bake distinct sentinels to BASE_A and BASE_B, then WARM BOTH probe clusters so both
    // occupy ch5's small RO cache (RO_BLOCKS=2). Rebake ONLY BASE_A with a new sentinel
    // (fires one stage_barrier -> whole-ch5 INVAL_MASK1). Then reread:
    //   - BASE_A probe MUST be the NEW sentinel (not the pre-interleave stale one) -- the
    //     invalidate reached the rebaked base's warm line.
    //   - BASE_B probe MUST still be BASE_B's baked sentinel -- a cold refetch returns the
    //     correct SDRAM contents (proves the barrier didn't corrupt the other base).
    // A mask that invalidates the WRONG channel/bit leaves BASE_A's warm line stale here.
    // ======================================================================
    mism = 0;
    bake_map(BASE_A, sentinel(0, 0));   // BASE_A := S(0,0)
    bake_map(BASE_B, sentinel(1, 0));   // BASE_B := S(1,0)
    warm_probe(BASE_A);                 // both clusters resident in ch5 (2 RO blocks)
    warm_probe(BASE_B);

    bake_map(BASE_A, sentinel(0, 1));   // rebake ONLY BASE_A := S(0,1); barrier invalidates ch5
    check_probe(BASE_A, sentinel(0, 1), sentinel(0, 0), 1, 0, 99);  // teeth: must be S(0,1)
    // BASE_B must still read its own baked sentinel (cold refetch from SDRAM).
    begin
      reg [63:0] eB, gB; integer j;
      eB = {sentinel(1,0), sentinel(1,0), sentinel(1,0), sentinel(1,0)};
      for (j = 0; j < NPROBE; j = j + 1) begin
        p0_read((BASE_B + j) * 8, gB);
        if (gB !== eB) begin
          if (mism < 8) $display("  MISMATCH inval-teeth interleave BASE_B (qw%0d): got=%h want=%h (barrier over-scoped/corrupted the un-rebaked base)", j, gB, eB);
          mism = mism + 1;
        end
      end
    end
    if (mism == 0)
      $display("INVAL-TEETH interleave (rebake BASE_A with BASE_B co-resident: A fresh, B intact): PASS");
    else
      $display("INVAL-TEETH interleave: FAIL (%0d mismatches)", mism);
    errs = errs + mism;

    if (errs == 0) $display("RESULT: PASS");
    else           $display("RESULT: FAIL (%0d total mismatches)", errs);
    $finish;
  end

  initial begin #60000000 $display("RESULT: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire
