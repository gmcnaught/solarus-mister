// tb_bgplane_write_pipe_xl.sv — [#24] whole-system TB for BLT_OP_BGPLANE_WRITE
// baking into the HIGH SDRAM ARENA (chip1, high banks) on the 2-die XL harness.
//
// This is the one path neither the HW arena probe (STAGE-write + opaque RGB565
// COPY-read) nor tb_sdram_fb_cache_xl's arena_uniqueness (drove ch0 dst_addr
// DIRECTLY, bypassing the fbram_to_sdram stride accumulator + the ARGB4444
// coverage packer) exercised: the REAL OP_BGPLANE_WRITE bake (comp_fbram WORK ->
// SDRAM strided write via bgw/fbram_to_sdram, incl. ARGB4444 coverage/alpha) at a
// chip1 high-bank arena base (84-96 MiB), read back through ch5 (P_SRC) — the
// exact port the compositor reads a baked plane through.
//
// Structure mirrors tb_bgplane_write_pipe.sv (paint WORK via OP_FILLs, then one
// OP_BGPLANE_WRITE), CHANGED for arena coverage:
//   - sdram_fb_cache #(.SDRAM_AW(25))  -> XL, 128 MiB, 2 physical dies
//   - 2 mt48 models split by the controller's sel_chip (MiSTer 128MB wiring:
//     sdram_ncs = cmd_cs ^ sel_chip), verbatim from tb_sdram_fb_cache_xl.sv
//   - readback via the ch5 P_SRC cache port (p0_*), not a direct Bank[] peek: the
//     arena lands in die1 at a within-die {bank,row,col} the direct-peek address
//     model doesn't map, and ch5 is the real compositor read path anyway
//   - bases in the 84-124 MiB arena (chip1 bank1 + bank2)
//
// The gap-untouched / streamer-skips-gap check stays in the low-address
// tb_bgplane_write_pipe.sv (already GATING); this TB's job is arena-address +
// wide-stride + ARGB4444-alpha correctness, so it omits the sentinel pre-fill
// (which would need the 2-die direct-Bank address model). The bake writes the
// FULL 320x240 cell (covered pixels alpha=F, uncovered alpha=0), so the alpha
// check needs no pre-fill.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"

module tb_bgplane_write_pipe_xl;
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

  // ---- quadrant pattern (verbatim from tb_bgplane_write_pipe.sv) ----
  localparam integer CELL_ROW_QW = 80;
  localparam integer CELL_ROWS   = 240;
  localparam [15:0] COLOR_TL = 16'h001F;   // top-left    (blue)
  localparam [15:0] COLOR_TR = 16'hF800;   // top-right   (red)
  localparam [15:0] COLOR_BL = 16'h07E0;   // bottom-left (green)
  localparam [15:0] COLOR_BR = 16'hFFE0;   // bottom-right(yellow)

  function automatic [15:0] expect_color(input integer row, input integer col);
    begin
      if (row < 120)
        expect_color = (col < 40) ? COLOR_TL : COLOR_TR;
      else
        expect_color = (col < 40) ? COLOR_BL : COLOR_BR;
    end
  endfunction

  // ---- ARENA target regions (chip1, high banks) ----
  //   BASE_QW  = 0xA80000 -> byte 0x5400000 = 84 MiB = chip1 bank1 (the arena base,
  //              the reopener's exact "INTER@80-84 works but arena@84 bands" combo)
  //   BASE_QW2 = 0xC00000 -> byte 0x6000000 = 96 MiB = chip1 bank2
  // STRIDE_QW=100 > CELL_ROW_QW=80 (20-qword gap/row, wide stride like a real plane).
  // Cell footprint = 240*100 = 24000 qw (0x5DC0) ~= 192 KiB, safely within one bank.
  localparam integer BASE_QW   = 32'h00A8_0000;   // 84 MiB, chip1 bank1
  localparam integer BASE_QW2  = 32'h00C0_0000;   // 96 MiB, chip1 bank2
  localparam integer STRIDE_QW = 100;
  // [#94] Chip-boundary STRADDLE base: 64 MiB = 0x0080_0000 qwords (the
  // sel_chip / bit23 chip-select boundary). A base just below it whose 240-row
  // strided extent (240*100 = 24000 qw) crosses into chip1 exercises the
  // fbram_to_sdram stride accumulator + the `bgw_base_qw + bgw_sdram_wr_addr`
  // add CARRYING across the physical-die boundary through the REAL bgw datapath
  // (not the direct ch0 dst path tb_sdram_fb_cache_xl uses). Rows 0..81 land in
  // chip0, rows ~82..239 in chip1. Byte-address round-trip verified on ch5.
  localparam integer BASE_QW3  = 32'h007F_E000;   // 8380416 qw; +239*100 (0x5D5C) = 0x803D5C > 0x800000 [#94 nit]

  integer r, c, ci, errs, mism;
  reg [63:0] got, exp64;
  // Column sample spanning the quadrant split (col<40 = left, >=40 = right) plus
  // the row extremes. Checking every one of the 240 rows at these cols catches a
  // row landing at the wrong strided address (banding); full 19200-qword sweep is
  // needlessly slow in iverilog. cols: first, last-left, first-right, last.
  localparam integer NCOLS = 4;
  integer csamp [0:NCOLS-1];

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
    // Scenario A — RGB565 cell-data bake at the ARENA base (chip1 bank1, 84 MiB).
    // Paint the 4-quadrant pattern into WORK, bake via real OP_BGPLANE_WRITE at
    // BASE_QW with a wide stride, read back through ch5, assert every strided cell
    // qword is bit-exact. Exercises fbram_to_sdram's per-row stride accumulation +
    // the 24-bit bgw_base_qw add AT A HIGH ARENA BASE (never covered before).
    // ======================================================================
    set_ctrl(5, 0);   // 4 FILLs + END, no CLEAR (quadrants fully tile the cell)
    wr_fill(0, 16'd0,   16'd0,   16'd160, 16'd120, COLOR_TL);
    wr_fill(1, 16'd160, 16'd0,   16'd160, 16'd120, COLOR_TR);
    wr_fill(2, 16'd0,   16'd120, 16'd160, 16'd120, COLOR_BL);
    wr_fill(3, 16'd160, 16'd120, 16'd160, 16'd120, COLOR_BR);
    mem[RINGB + 4*4] = 64'd1;   // END
    run_submit;

    set_ctrl(2, 0);
    wr_bgw(0, BASE_QW, STRIDE_QW[15:0]);
    mem[RINGB + 1*4] = 64'd1;   // END
    run_submit;
    flush_to_sdram;

    mism = 0;
    for (r = 0; r < CELL_ROWS; r = r + 1) begin
      for (ci = 0; ci < NCOLS; ci = ci + 1) begin
        c = csamp[ci];
        p0_read((BASE_QW + r*STRIDE_QW + c) * 8, got);
        exp64 = {expect_color(r,c), expect_color(r,c), expect_color(r,c), expect_color(r,c)};
        if (got !== exp64) begin
          if (mism < 8) $display("  FAIL arena-cell (row=%0d col=%0d @byte %h): got=%h want=%h",
                                 r, c, (BASE_QW + r*STRIDE_QW + c)*8, got, exp64);
          mism = mism + 1;
        end
      end
    end
    if (mism == 0) $display("ARENA CELL DATA (chip1 bank1, 84MiB): PASS (%0d rows x %0d cols via ch5)", CELL_ROWS, NCOLS);
    else           $display("ARENA CELL DATA (chip1 bank1, 84MiB): FAIL (%0d mismatches)", mism);
    errs = errs + mism;

    // ======================================================================
    // Scenario B — ARGB4444 coverage/alpha bake at the ARENA (chip1 bank2, 96 MiB).
    // Paint only TL+BR quadrants (leaving TR/BL uncovered), bake with the coverage
    // clear + ARGB4444 pack forced (BLT_F_BGCOV decode is exercised elsewhere; this
    // drives the two internal signals directly, same as tb_bgplane_write_pipe.sv).
    // Read back via ch5 and assert covered pixels pack alpha=0xF, uncovered alpha=0.
    // This is the coverage/alpha path (bgplane_coverage rd_cov + fbram_to_sdram
    // pack_qword_argb4444) at a high arena base — the prime banding suspect.
    // ======================================================================
    // Submit: whole-cell FILL forced into bake-coverage-CLEAR mode.
    force blt.c_bgcov_clear = 1'b1;
    set_ctrl(2, 0);
    mem[RINGB + 0*4] = 64'h0000_0000_0000_0002;         // FILL, flags=0
    mem[RINGB + 0*4 + 1] = {16'd240, 16'd320, 32'd0};    // full 320x240
    mem[RINGB + 0*4 + 2] = 64'd0;                        // dst 0,0
    mem[RINGB + 0*4 + 3] = {16'd0, COLOR_TL, 32'd0};     // clear color irrelevant
    mem[RINGB + 1*4] = 64'd1;                            // END
    run_submit;
    force blt.c_bgcov_clear = 1'b0;
    release blt.c_bgcov_clear;

    // Paint only TL + BR (TR/BL left uncovered).
    set_ctrl(3, 0);
    wr_fill(0, 16'd0,   16'd0,   16'd160, 16'd120, COLOR_TL);   // TL covered
    wr_fill(1, 16'd160, 16'd120, 16'd160, 16'd120, COLOR_BR);   // BR covered
    mem[RINGB + 2*4] = 64'd1;                                   // END
    run_submit;

    // OP_BGPLANE_WRITE forced into ARGB4444 pack mode, at BASE_QW2 (arena bank2).
    force blt.bgw_argb4444 = 1'b1;
    set_ctrl(2, 0);
    mem[RINGB + 0*4] = {32'd0, 8'd0, 8'd0, 8'd0, OP_BGPLANE_WRITE};
    mem[RINGB + 0*4 + 1] = {32'd0, STRIDE_QW[15:0], 16'd0};
    mem[RINGB + 0*4 + 2] = {BASE_QW2[31:16], BASE_QW2[15:0], 32'd0};
    mem[RINGB + 0*4 + 3] = 64'd0;
    mem[RINGB + 1*4] = 64'd1;                                   // END
    run_submit;
    force blt.bgw_argb4444 = 1'b0;
    release blt.bgw_argb4444;
    flush_to_sdram;

    mism = 0;
    for (r = 0; r < CELL_ROWS; r = r + 1) begin
      for (ci = 0; ci < NCOLS; ci = ci + 1) begin
        c = csamp[ci];
        p0_read((BASE_QW2 + r*STRIDE_QW + c) * 8, got);
        begin : per_pixel
          integer lane; reg [15:0] px; reg covered;
          for (lane = 0; lane < 4; lane = lane + 1) begin
            px = got[lane*16 +: 16];
            covered = (r < 120) ? (c < 40) : (c >= 40);   // TL(r<120,c<40) or BR(r>=120,c>=40)
            if (covered && px[15:12] !== 4'hF) begin
              if (mism < 8) $display("  FAIL arena-argb (row=%0d col=%0d lane=%0d): want alpha=F got=%h", r, c, lane, px);
              mism = mism + 1;
            end
            if (!covered && px[15:12] !== 4'h0) begin
              if (mism < 8) $display("  FAIL arena-argb (row=%0d col=%0d lane=%0d): want alpha=0 got=%h", r, c, lane, px);
              mism = mism + 1;
            end
          end
        end
      end
    end
    if (mism == 0) $display("ARENA ARGB4444 PACK (chip1 bank2, 96MiB): PASS (via ch5)");
    else           $display("ARENA ARGB4444 PACK (chip1 bank2, 96MiB): FAIL (%0d mismatches)", mism);
    errs = errs + mism;

    // ======================================================================
    // Scenario C — [#94] RGB565 cell-data bake STRADDLING the 64 MiB chip
    // boundary. Same 4-quadrant WORK pattern, baked via the REAL OP_BGPLANE_WRITE
    // at BASE_QW3 (8380416 qw), whose 240-row strided extent crosses 0x800000 qw
    // (rows ~0..81 -> chip0, ~82..239 -> chip1). This is the FULL-channel
    // byte-address round-trip ACROSS THE CHIP BOUNDARY through the bgw datapath
    // that #94 asks for: it forces the fbram_to_sdram stride accumulator + the
    // `bgw_base_qw + bgw_sdram_wr_addr` add to carry across the sel_chip / bit23
    // die-select bit, then reads every strided cell qword back on ch5. A dropped
    // or mis-routed carry lands a row on the wrong die -> ch5 mismatch.
    set_ctrl(5, 0);   // repaint quadrants into WORK (Scenario B overwrote it)
    wr_fill(0, 16'd0,   16'd0,   16'd160, 16'd120, COLOR_TL);
    wr_fill(1, 16'd160, 16'd0,   16'd160, 16'd120, COLOR_TR);
    wr_fill(2, 16'd0,   16'd120, 16'd160, 16'd120, COLOR_BL);
    wr_fill(3, 16'd160, 16'd120, 16'd160, 16'd120, COLOR_BR);
    mem[RINGB + 4*4] = 64'd1;   // END
    run_submit;

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
        exp64 = {expect_color(r,c), expect_color(r,c), expect_color(r,c), expect_color(r,c)};
        if (got !== exp64) begin
          if (mism < 8) $display("  FAIL straddle-cell (row=%0d col=%0d @byte %h): got=%h want=%h",
                                 r, c, (BASE_QW3 + r*STRIDE_QW + c)*8, got, exp64);
          mism = mism + 1;
        end
      end
    end
    if (mism == 0) $display("CHIP-BOUNDARY STRADDLE (64MiB, rows cross chip0->chip1): PASS (%0d rows x %0d cols via ch5)", CELL_ROWS, NCOLS);
    else           $display("CHIP-BOUNDARY STRADDLE (64MiB): FAIL (%0d mismatches)", mism);
    errs = errs + mism;

    if (errs == 0) $display("RESULT: PASS");
    else           $display("RESULT: FAIL (%0d total mismatches)", errs);
    $finish;
  end

  initial begin #60000000 $display("RESULT: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire
