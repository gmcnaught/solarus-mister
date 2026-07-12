// tb_bgplane_maptrans.sv — [#95][#84] REPEATED-MAP-TRANSITION bgplane regression.
//
// The #84 failure needs a *sequence*, not a single bake: load map A to plane base
// X, load map B to the SAME base X, and the per-frame compositor COPY read (ch5 /
// P_SRC) must return B, not a STALE A cached line. On HW the only thing that drops
// ch5's cached plane lines after a bake is `stage_barrier` (sdram_fb_cache
// INVAL_MASK1: flush ch1's STAGE writes to SDRAM, then invalidate ch5). blitter_top
// pulses stage_barrier automatically after every OP_BGPLANE_WRITE STAGE batch. If
// that invalidation ever regressed, this TB would read map A's pixels back after
// baking map B — exactly the #84 "static tiles missing after several transitions"
// symptom (#85 landed the ch0->ch1/STAGE reroute; this is the guard against
// re-breaking the barrier that consumes it).
//
// KEY vs the existing bgplane XL TBs (write_pipe_xl / 3plane_xl): those bake each
// plane to a DISTINCT base and read it COLD (ch5 never warm at that address), so
// they prove a cold read returns baked data but NOT that a base-REUSE invalidates a
// warm line. This TB reads base X via ch5 (warming it with map m-1) and THEN rebakes
// X with map m and re-reads — so a missing barrier invalidation surfaces as stale.
//
// Also EXERCISES the second #84 lead — the un-cleared comp_fbram WORK buffer
// (comp_fbram.sv WORK persists across scene rebuilds): Scenario 2 does a PARTIAL
// repaint (only the TL quadrant) after a full map, bakes it, and reports whether the
// un-repainted plane regions carry stale prior-scene pixels or were cleared. That
// probe is INFORMATIONAL only (no pass/fail on the un-cleared bytes) — the hard
// assertion + the fix live in #102; here it just documents the current behavior.
//
// Harness (2-die XL sdram_fb_cache #(.SDRAM_AW(25)) + ch5 P_SRC readback, the exact
// port the compositor reads a plane through) is reused verbatim from
// tb_bgplane_write_pipe_xl.sv. Geometry is reduced by default (CELL_ROWS=12) so this
// runs in the PR tier; +define+BGPLANE_MAPTRANS_FULL restores the 240-row plane
// (nightly, via run_sims.sh TIER_DEFINES_FULL).
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"

module tb_bgplane_maptrans;
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

  // ---- command-ring helpers (mirrors tb_bgplane_write_pipe.sv) ----
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
      if (mem[32'h200005][31:0] !== submit_n[31:0]) $display("  WEDGE: submit %0d never acked (to=%0d)", submit_n, to);
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

  // ch5 P_SRC read: pulse p0_rd one cycle with p0_addr, wait p0_ok. Cold miss
  // fetches the block fresh from SDRAM (ch5 is never invalidated by vsync, but is
  // cold on first touch, and the bake data doesn't change after flush).
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

  // ---- quadrant pattern + per-map palettes ----
  // Reduced geometry by default (12 baked rows still cross the TL/TR<->BL/BR split
  // and both column halves) so this runs in the PR tier; +BGPLANE_MAPTRANS_FULL
  // restores the full 240-row HW plane (nightly).
  localparam integer CELL_ROW_QW = 80;
`ifdef BGPLANE_MAPTRANS_FULL
  localparam integer CELL_ROWS  = 240;   // full HW plane height (nightly)
  localparam integer QSPLIT_ROW = 120;   // vertical quadrant split at mid-plane
`else
  localparam integer CELL_ROWS  = 12;    // reduced: 12 baked rows still cross the split
  localparam integer QSPLIT_ROW = 6;     // split scaled to CELL_ROWS/2 -> TL/TR + BL/BR both baked
`endif

  localparam integer NMAPS = 3;   // A -> B -> C, all baked to the SAME base

  // quadrant index from (row,col): 0=TL 1=TR 2=BL 3=BR
  function automatic [1:0] quad(input integer row, input integer col);
    begin
      quad = (row < QSPLIT_ROW) ? (col < 40 ? 2'd0 : 2'd1)
                                : (col < 40 ? 2'd2 : 2'd3);
    end
  endfunction

  // Per-(map,quadrant) fill color. 12 distinct non-zero RGB565 values so map m's
  // color at ANY sampled (row,col) differs from every other map's at the same spot
  // -> a stale prior-map ch5 line is unambiguously detected.
  function automatic [15:0] map_q_color(input integer m, input [1:0] q);
    begin
      case (m*4 + q)
        0:  map_q_color = 16'h001F;  1:  map_q_color = 16'hF800;   // map0 TL,TR
        2:  map_q_color = 16'h07E0;  3:  map_q_color = 16'hFFE0;   // map0 BL,BR
        4:  map_q_color = 16'hF81F;  5:  map_q_color = 16'h07FF;   // map1 TL,TR
        6:  map_q_color = 16'hFD20;  7:  map_q_color = 16'h8410;   // map1 BL,BR
        8:  map_q_color = 16'hAAAA;  9:  map_q_color = 16'h5555;   // map2 TL,TR
        10: map_q_color = 16'h1234;  11: map_q_color = 16'hABCD;   // map2 BL,BR
        default: map_q_color = 16'h0000;
      endcase
    end
  endfunction

  // ---- plane bases (chip1 high banks, exactly as write_pipe_xl) ----
  // BASE_QW = 84 MiB (the base REUSED by every map transition — the whole point).
  // BASE_QW2 = 96 MiB, a fresh base used only by the un-cleared-WORK probe.
  localparam integer BASE_QW   = 32'h00A8_0000;   // 84 MiB, chip1 bank1 (reused)
  localparam integer BASE_QW2  = 32'h00C0_0000;   // 96 MiB, chip1 bank2 (probe)
  localparam integer BASE_QW3  = 32'h00D0_0000;   // 104 MiB, chip1 bank3 (#102 clear proof)
  localparam integer STRIDE_QW = 100;             // > CELL_ROW_QW=80 (wide plane stride)
  localparam [15:0]  PROBE_TL  = 16'h7C1F;        // partial-repaint TL color (distinct)

  integer m, r, c, ci, errs, mism, stale_cnt, clear_cnt, other_cnt;
  reg [63:0] got, exp64, stale64;
  reg [15:0] want16, want_prev;
  // Column sample spanning the quadrant split (col<40 = left, >=40 = right) plus the
  // row extremes; catches a row landing at the wrong strided address (banding).
  localparam integer NCOLS = 4;
  integer csamp [0:NCOLS-1];

`ifndef BGPLANE_MAPTRANS_FULL
  // Fabric bake volume = blitter_top's fbram_to_sdram (u_bgw: FB_QWORDS=19200,
  // CELL_ROWS=240). Override to the reduced window so the streamer bakes only
  // CELL_ROWS rows -- strided per-row advance identical, fewer repetitions.
  // (TB-only; no production RTL change.)
  defparam blt.u_bgw.FB_QWORDS = CELL_ROWS*CELL_ROW_QW;
  defparam blt.u_bgw.CELL_ROWS = CELL_ROWS;
`endif

  initial begin
    for (i = 0; i < MEMQW; i = i + 1) mem[i] = 64'd0;
    mem[32'h200000] = 64'd0; mem[32'h200005] = 64'd0;
    p0_addr = 27'd0; p0_rd = 1'b0;
    csamp[0] = 0; csamp[1] = 39; csamp[2] = 40; csamp[3] = CELL_ROW_QW-1;   // 0,39,40,79
    errs = 0;

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
    // Scenario 1 — REPEATED MAP TRANSITION to a REUSED base (the #84 regression).
    // For each map A(0)->B(1)->C(2): paint its 4-quadrant pattern into comp_fbram
    // WORK, bake OP_BGPLANE_WRITE to the SAME BASE_QW, then read the plane back
    // through ch5. Entering iteration m>=1 the ch5 lines for BASE_QW are WARM from
    // map (m-1)'s readback below, so a FRESH result here can only mean the bake's
    // stage_barrier invalidated them (INVAL_MASK1) — the exact mechanism #84 needs.
    // A stale line surfaces as the prior map's color (flagged explicitly).
    // ======================================================================
    for (m = 0; m < NMAPS; m = m + 1) begin
      // (a) paint map m into WORK (4 quadrant FILLs, no CLEAR — they tile the cell)
      set_ctrl(5, 0);
      wr_fill(0, 16'd0,   16'd0,           16'd160, 16'(QSPLIT_ROW),           map_q_color(m, 2'd0));  // TL
      wr_fill(1, 16'd160, 16'd0,           16'd160, 16'(QSPLIT_ROW),           map_q_color(m, 2'd1));  // TR
      wr_fill(2, 16'd0,   16'(QSPLIT_ROW), 16'd160, 16'(CELL_ROWS-QSPLIT_ROW), map_q_color(m, 2'd2));  // BL
      wr_fill(3, 16'd160, 16'(QSPLIT_ROW), 16'd160, 16'(CELL_ROWS-QSPLIT_ROW), map_q_color(m, 2'd3));  // BR
      mem[RINGB + 4*4] = 64'd1;   // END
      run_submit;

      // (b) bake WORK -> plane at the REUSED base. blitter_top pulses stage_barrier
      //     after this STAGE batch: flush ch1 to SDRAM, then invalidate ch5.
      set_ctrl(2, 0);
      wr_bgw(0, BASE_QW, STRIDE_QW[15:0]);
      mem[RINGB + 1*4] = 64'd1;   // END
      run_submit;
      flush_to_sdram;

      // (c) read the plane back via ch5 (the compositor's real plane-COPY port).
      mism = 0;
      for (r = 0; r < CELL_ROWS; r = r + 1) begin
        for (ci = 0; ci < NCOLS; ci = ci + 1) begin
          c = csamp[ci];
          p0_read((BASE_QW + r*STRIDE_QW + c) * 8, got);
          want16 = map_q_color(m, quad(r,c));
          exp64  = {want16, want16, want16, want16};
          if (got !== exp64) begin
            if (mism < 8) begin
              want_prev = (m > 0) ? map_q_color(m-1, quad(r,c)) : 16'h0000;
              stale64   = {want_prev, want_prev, want_prev, want_prev};
              if (m > 0 && got === stale64)
                $display("  FAIL maptrans STALE (map=%0d row=%0d col=%0d): read prior-map %h -> ch5 NOT invalidated after rebake to reused base",
                         m, r, c, got);
              else
                $display("  FAIL maptrans (map=%0d row=%0d col=%0d @byte %h): got=%h want=%h",
                         m, r, c, (BASE_QW + r*STRIDE_QW + c)*8, got, exp64);
            end
            mism = mism + 1;
          end
        end
      end
      if (mism == 0)
        $display("MAP-TRANSITION m=%0d (bake #%0d to reused base %h, ch5 reads fresh not stale prior map): PASS (%0d rows x %0d cols)",
                 m, m, BASE_QW, CELL_ROWS, NCOLS);
      else
        $display("MAP-TRANSITION m=%0d: FAIL (%0d mismatches)", m, mism);
      errs = errs + mism;
    end

    // ======================================================================
    // Scenario 2 — UN-CLEARED comp_fbram WORK probe (the second #84 lead, #102).
    // Full-paint map0 into WORK, then PARTIAL-repaint ONLY the TL quadrant with a
    // distinct color and bake to a FRESH base. The TL region MUST read the new
    // color (hard assert). The un-repainted TR/BL/BR regions expose whether WORK
    // persisted the prior scene (stale) or was cleared — REPORTED, not asserted;
    // the fix + the hard assertion land in #102.
    // ======================================================================
    set_ctrl(5, 0);   // full map0 paint into WORK
    wr_fill(0, 16'd0,   16'd0,           16'd160, 16'(QSPLIT_ROW),           map_q_color(0, 2'd0));
    wr_fill(1, 16'd160, 16'd0,           16'd160, 16'(QSPLIT_ROW),           map_q_color(0, 2'd1));
    wr_fill(2, 16'd0,   16'(QSPLIT_ROW), 16'd160, 16'(CELL_ROWS-QSPLIT_ROW), map_q_color(0, 2'd2));
    wr_fill(3, 16'd160, 16'(QSPLIT_ROW), 16'd160, 16'(CELL_ROWS-QSPLIT_ROW), map_q_color(0, 2'd3));
    mem[RINGB + 4*4] = 64'd1;   // END
    run_submit;

    // partial repaint: ONLY the TL quadrant (TR/BL/BR left holding map0 in WORK)
    set_ctrl(2, 0);
    wr_fill(0, 16'd0, 16'd0, 16'd160, 16'(QSPLIT_ROW), PROBE_TL);
    mem[RINGB + 1*4] = 64'd1;   // END
    run_submit;

    // bake the (partially-repainted) WORK to a FRESH base
    set_ctrl(2, 0);
    wr_bgw(0, BASE_QW2, STRIDE_QW[15:0]);
    mem[RINGB + 1*4] = 64'd1;   // END
    run_submit;
    flush_to_sdram;

    mism = 0; stale_cnt = 0; clear_cnt = 0; other_cnt = 0;
    for (r = 0; r < CELL_ROWS; r = r + 1) begin
      for (ci = 0; ci < NCOLS; ci = ci + 1) begin
        c = csamp[ci];
        p0_read((BASE_QW2 + r*STRIDE_QW + c) * 8, got);
        if (quad(r,c) == 2'd0) begin
          // TL: repainted THIS scene -> must be fresh PROBE_TL
          exp64 = {PROBE_TL, PROBE_TL, PROBE_TL, PROBE_TL};
          if (got !== exp64) begin
            if (mism < 8) $display("  FAIL probe-TL (row=%0d col=%0d): got=%h want=%h", r, c, got, exp64);
            mism = mism + 1;
          end
        end else begin
          // TR/BL/BR: NOT repainted this scene -> classify what got baked.
          want16 = map_q_color(0, quad(r,c));   // prior scene color for this quad
          if      (got === {want16, want16, want16, want16}) stale_cnt = stale_cnt + 1;
          else if (got === 64'd0)                            clear_cnt = clear_cnt + 1;
          else                                               other_cnt = other_cnt + 1;
        end
      end
    end
    if (mism == 0)
      $display("UNCLEARED-WORK PROBE: TL-repaint fresh PASS; un-repainted regions prior-scene=%0d cleared=%0d other=%0d (informational; #102 fix = clear before bake, proven in Scenario 3)",
               stale_cnt, clear_cnt, other_cnt);
    else
      $display("UNCLEARED-WORK PROBE: TL-repaint mismatch (%0d)", mism);
    errs = errs + mism;

    // ======================================================================
    // Scenario 3 — [#102] EXPLICIT WORK CLEAR before a partial repaint bakes CLEAN gaps.
    // The #102 defect (Scenario 2: prior-scene=36) is that an un-cleared WORK bakes stale
    // prior-scene pixels into un-repainted regions. The RTL ALREADY provides the cure: a
    // CLEAR-flagged submit routes a full-screen FILL (clear_color=0) through comp_pipeline,
    // zeroing WORK, BEFORE the scene's tiles composite (blitter_top S_GOT_CLEAR). This is
    // the POSITIVE proof: leave a full prior map in WORK, then issue CLEAR + a partial TL
    // repaint -> bake -> the un-repainted TR/BL/BR bake CLEAN (0), NOT the prior map. It
    // pins the required host sequencing (emit a full-screen opaque clear before plane tiles
    // in raw-RGB565 bake mode); the production fix is host-side (renderer), tracked to
    // impl-host. A MISSING clear regresses to Scenario 2's stale bake.
    // ======================================================================
    set_ctrl(5, 0);   // stuff a full prior map (map2) into WORK first
    wr_fill(0, 16'd0,   16'd0,           16'd160, 16'(QSPLIT_ROW),           map_q_color(2, 2'd0));
    wr_fill(1, 16'd160, 16'd0,           16'd160, 16'(QSPLIT_ROW),           map_q_color(2, 2'd1));
    wr_fill(2, 16'd0,   16'(QSPLIT_ROW), 16'd160, 16'(CELL_ROWS-QSPLIT_ROW), map_q_color(2, 2'd2));
    wr_fill(3, 16'd160, 16'(QSPLIT_ROW), 16'd160, 16'(CELL_ROWS-QSPLIT_ROW), map_q_color(2, 2'd3));
    mem[RINGB + 4*4] = 64'd1;   // END
    run_submit;

    // CLEAR-flagged submit: full-screen clear-to-0 THEN partial TL repaint only
    set_ctrl(2, 1);   // flags bit0 = CLEAR (clear_color=0), then 1 FILL + END
    wr_fill(0, 16'd0, 16'd0, 16'd160, 16'(QSPLIT_ROW), PROBE_TL);
    mem[RINGB + 1*4] = 64'd1;   // END
    run_submit;

    // bake the cleared+partially-repainted WORK to a fresh base
    set_ctrl(2, 0);
    wr_bgw(0, BASE_QW3, STRIDE_QW[15:0]);
    mem[RINGB + 1*4] = 64'd1;   // END
    run_submit;
    flush_to_sdram;

    mism = 0;
    for (r = 0; r < CELL_ROWS; r = r + 1) begin
      for (ci = 0; ci < NCOLS; ci = ci + 1) begin
        c = csamp[ci];
        p0_read((BASE_QW3 + r*STRIDE_QW + c) * 8, got);
        if (quad(r,c) == 2'd0)
          exp64 = {PROBE_TL, PROBE_TL, PROBE_TL, PROBE_TL};   // repainted TL -> fresh
        else
          exp64 = 64'd0;                                       // cleared -> CLEAN, not stale map2
        if (got !== exp64) begin
          if (mism < 8) $display("  FAIL clear-bake (row=%0d col=%0d quad=%0d): got=%h want=%h",
                                 r, c, quad(r,c), got, exp64);
          mism = mism + 1;
        end
      end
    end
    if (mism == 0)
      $display("WORK-CLEAR-BEFORE-BAKE (#102): PASS (CLEAR-flagged submit -> un-repainted gaps bake clean 0, not stale prior map)");
    else
      $display("WORK-CLEAR-BEFORE-BAKE (#102): FAIL (%0d mismatches)", mism);
    errs = errs + mism;

    if (errs == 0) $display("RESULT: PASS");
    else           $display("RESULT: FAIL (%0d total mismatches)", errs);
    $finish;
  end

  initial begin #60000000 $display("RESULT: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire
