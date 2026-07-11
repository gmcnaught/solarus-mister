// tb_bgplane_write_pipe.sv — whole-system TB for BLT_OP_BGPLANE_WRITE (#Phase3b).
//
// Paints a known, position-dependent (per-quadrant) pattern into comp_fbram's WORK
// buffer via ordinary OP_FILL commands (modern FB-in-BRAM harness, mirrors
// tb_tilelist.sv), then submits one OP_BGPLANE_WRITE command with a target SDRAM
// qword offset and a dst_stride_qw WIDER than one cell row (CELL_ROW_QW=80), and
// asserts (via a REAL sdram_fb_cache + mt48lc16m16a2 model, mirroring
// tb_sdram_fb_cache.sv's harness) that:
//   (a) every cell-row qword landed at the STRIDED destination address, matching
//       the quadrant painted at that (row,col), and
//   (b) the stride GAP qwords (between the end of one cell row and the start of
//       the next) were left holding the pre-bake sentinel — proving the streamer
//       skips the gap rather than overwriting it.
//
// Readback reads the mt48 chip store DIRECTLY (Bank0[], same word_base() mapping
// tb_sdram_fb_cache.sv's preload_qword() uses) rather than through the dst_* cache
// port, since blitter_top now drives dst_* itself (a second driver on dst_addr/
// dst_wr from the TB would conflict). A `vs` pulse after the bake flushes ch0's
// dirty cache lines to the physical model before readback (same coherency path
// production relies on).
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"

module tb_bgplane_write_pipe;
  localparam [31:0] RINGB = 32'h200008;   // ring slot0 (window idx, 0x3B000040)
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h8000;

  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  // free-running vblank so S_SNAP_* drains after every submit (mirrors tb_tilelist.sv)
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

  // ---- ch0 (P_DST) write port: real sdram_fb_cache + mt48 model ----
  wire        dst_wr;
  wire [26:0] dst_addr;
  wire [63:0] dst_din;
  wire [7:0]  dst_wdsn;
  wire        dst_ok;
  wire        coh_busy;

  wire [15:0] sdram_dq;
  wire [12:0] sdram_a;
  wire        sdram_dqml, sdram_dqmh;
  wire [1:0]  sdram_ba;
  wire        sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke, sdram_clk;

  // [bgplane bake -> STAGE reroute] the bake now streams through ch1 (STAGE), so wire
  // blitter_top's STAGE outputs into the cache's ch1 and the stage_barrier into the
  // barrier sequencer (previously tied off when the bake used ch0).
  wire        stage_we_burst_w;
  wire [63:0] stage_din64_w;
  wire [26:0] stage_waddr_w;
  wire        stage_ok_w;
  wire        stage_barrier_w;
  wire        stage_busy_w;

  sdram_fb_cache u_cache (
    .clk(clk), .clk_sdram(clk), .rst(rst),
    .init(),
    .dst_addr(dst_addr), .dst_rd(1'b0), .dst_wr(dst_wr),
    .dst_din(dst_din), .dst_wdsn(dst_wdsn), .dst_dout(), .dst_ok(dst_ok),
    .scan_addr(27'd0), .scan_rd(1'b0), .scan_dout(), .scan_ok(),
    .p0_addr(27'd0), .p0_rd(1'b0), .p0_dout(), .p0_ok(),
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

  mt48lc16m16a2 #(.addr_bits(13), .col_bits(10)) u_sdram (
    .Clk(clk), .Cke(sdram_cke), .Dq(sdram_dq), .Addr(sdram_a), .Ba(sdram_ba),
    .Cs_n(sdram_ncs), .Ras_n(sdram_nras), .Cas_n(sdram_ncas), .We_n(sdram_nwe),
    .Dqm({sdram_dqmh, sdram_dqml}), .downloading(1'b0), .VS(1'b0), .frame_cnt(0)
  );

  // word_base: client byte addr (qword-aligned) -> SDRAM 16-bit word base, OFFSET=0
  // (verbatim from tb_sdram_fb_cache.sv's address model).
  function automatic integer word_base(input integer byte_addr);
    begin word_base = (byte_addr >> 3) * 4; end
  endfunction

  task preload_qword(input integer byte_addr, input [63:0] data);
    integer wb;
    begin
      wb = word_base(byte_addr);
      u_sdram.Bank0[wb+0] = data[15: 0];
      u_sdram.Bank0[wb+1] = data[31:16];
      u_sdram.Bank0[wb+2] = data[47:32];
      u_sdram.Bank0[wb+3] = data[63:48];
    end
  endtask

  function automatic [63:0] read_qword(input integer byte_addr);
    integer wb;
    begin
      wb = word_base(byte_addr);
      read_qword = {u_sdram.Bank0[wb+3], u_sdram.Bank0[wb+2],
                    u_sdram.Bank0[wb+1], u_sdram.Bank0[wb+0]};
    end
  endfunction

  // ---- DUT ----
  blitter_top blt (.clk(clk), .rst(rst), .vs(vs),
    .mem_addr(bt_addr), .mem_rd(b_rd), .mem_wr(b_we), .mem_burstcnt(bt_burst),
    .mem_din(b_din), .mem_be(b_be),
    .mem_dout(d_dout), .mem_dout_ready(d_dready), .mem_busy(d_busy),
    .p0_addr(), .p0_rd(), .p0_dout(64'd0), .p0_ok(1'b0),
    // [bgplane bake -> STAGE reroute] the bake drives these STAGE outputs; pace it off
    // the real cache's stage_ok and hold on stage_busy (the barrier).
    .src_sdram_we_burst(stage_we_burst_w), .src_sdram_din64(stage_din64_w),
    .src_sdram_waddr(stage_waddr_w), .src_sdram_ok(stage_ok_w),
    .stage_barrier(stage_barrier_w), .stage_barrier_busy(stage_busy_w),
    .fb_wr_en(fb_wr_en), .fb_wr_qw(fb_wr_qw), .fb_wr_lane(fb_wr_lane), .fb_wr_pix(fb_wr_pix),
    .fb_rd_en(fb_rd_en), .fb_rd_qw(fb_rd_qw), .fb_rd_qword(fb_rd_qword),
    .dst_wr(dst_wr), .dst_addr(dst_addr), .dst_din(dst_din), .dst_wdsn(dst_wdsn), .dst_ok(dst_ok),
    .idle(bt_idle));

  // ---- command-ring helpers (mirrors tb_tilelist.sv's set_ctrl/run_submit) ----
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

  // OP_BGPLANE_WRITE: dst_x|dst_y<<16 (u32[5]) = absolute plane qword offset;
  // src_x (u32[2][31:16]) = dst_stride_qw. Same header field-reuse idiom as
  // OP_TILELIST (blitter_top.sv S_SETUP decode, dst_x/dst_y/src_x latching).
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

  // wait for one more vs rising edge + coh_busy to clear (flushes ch0 to the
  // physical mt48 model before we peek Bank0[] directly).
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

  // ---- quadrant pattern: color(row,col) depends on qword coords, aligned exactly
  // on the 160x120 quadrant boundaries (160/4=40 qwords, 120 rows). ----
  localparam integer CELL_ROW_QW = 80;
`ifdef BGPLANE_WRITE_FULL
  localparam integer CELL_ROWS  = 240;   // full HW plane height (nightly)
  localparam integer QSPLIT_ROW = 120;   // vertical quadrant split at mid-plane
`else
  localparam integer CELL_ROWS  = 12;    // reduced: 12 baked rows still cross the split
  localparam integer QSPLIT_ROW = 6;     // split scaled to CELL_ROWS/2 -> TL/TR + BL/BR both baked
`endif
  localparam [15:0] COLOR_TL = 16'h001F;   // top-left    (blue)
  localparam [15:0] COLOR_TR = 16'hF800;   // top-right   (red)
  localparam [15:0] COLOR_BL = 16'h07E0;   // bottom-left (green)
  localparam [15:0] COLOR_BR = 16'hFFE0;   // bottom-right(yellow)

  function automatic [15:0] expect_color(input integer row, input integer col);
    begin
      if (row < QSPLIT_ROW)
        expect_color = (col < 40) ? COLOR_TL : COLOR_TR;
      else
        expect_color = (col < 40) ? COLOR_BL : COLOR_BR;
    end
  endfunction

  // ---- target SDRAM region: base_qw, stride_qw > CELL_ROW_QW (non-trivial gap) ----
  localparam integer BASE_QW   = 32'h0000_2000;   // qword index (well inside the mt48 model)
  localparam integer STRIDE_QW = 100;             // > CELL_ROW_QW=80 -> 20-qword gap/row
  localparam [63:0] SENTINEL   = 64'hDEAD_BEEF_CAFE_F00D;
  // ---- ARGB4444-mode scenario: second target region, well clear of BASE_QW's
  // footprint (CELL_ROWS*STRIDE_QW = 24000 qwords past BASE_QW). ----
  localparam integer BASE_QW2  = 32'h0000_5000;

  integer r, c, errs, mism;
  reg [63:0] got, exp64;

`ifndef BGPLANE_WRITE_FULL
  // Fabric bake volume = blitter_top's fbram_to_sdram instance (u_bgw:
  // FB_QWORDS=19200, CELL_ROWS=240). Override to the reduced window so the streamer
  // bakes only CELL_ROWS rows -- strided per-row advance + gap-skip identical, fewer
  // repetitions. (TB-only; no production RTL change.)
  defparam blt.u_bgw.FB_QWORDS = CELL_ROWS*CELL_ROW_QW;
  defparam blt.u_bgw.CELL_ROWS = CELL_ROWS;
`endif

  initial begin
    for (i = 0; i < MEMQW; i = i + 1) mem[i] = 64'd0;
    mem[32'h200000] = 64'd0; mem[32'h200005] = 64'd0;
    errs = 0;

    // Pre-fill the ENTIRE strided footprint (cell columns AND gap columns) with a
    // sentinel, so a post-bake gap check proves the write truly skipped the gap.
    for (r = 0; r < CELL_ROWS; r = r + 1)
      for (c = 0; c < STRIDE_QW; c = c + 1)
        preload_qword((BASE_QW + r*STRIDE_QW + c) * 8, SENTINEL);

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

    // Submit 1: 4 quadrant FILLs + END -> paint comp_fbram's WORK buffer.
    // [Task 22 perf] No CLEAR: FILL entries overwrite unconditionally (blend=COPY, the
    // opcode-only header wr_fill emits leaves the blend byte 0) and the 4 quadrants
    // exactly tile the full CELL_ROWS x CELL_ROW_QW*4 region this TB's CELL DATA check
    // covers below -- a preceding full-fbram CLEAR would be entirely overwritten before
    // ever being read, so it was pure dead work.
    // [reduced-geometry] FILL extents track QSPLIT_ROW/CELL_ROWS so the 12-row reduced
    // and 240-row +BGPLANE_WRITE_FULL cases both tile their region exactly.
    set_ctrl(5, 0);   // 4 FILLs + END = 5 cmds, no CLEAR (fully overwritten -- see above)
    wr_fill(0, 16'd0,   16'd0,            16'd160, 16'(QSPLIT_ROW),           COLOR_TL);
    wr_fill(1, 16'd160, 16'd0,            16'd160, 16'(QSPLIT_ROW),           COLOR_TR);
    wr_fill(2, 16'd0,   16'(QSPLIT_ROW),  16'd160, 16'(CELL_ROWS-QSPLIT_ROW), COLOR_BL);
    wr_fill(3, 16'd160, 16'(QSPLIT_ROW),  16'd160, 16'(CELL_ROWS-QSPLIT_ROW), COLOR_BR);
    mem[RINGB + 4*4] = 64'd1;   // END
    run_submit;

    // Submit 2: OP_BGPLANE_WRITE (no CLEAR -- must not disturb the painted WORK buffer).
    set_ctrl(2, 0);
    wr_bgw(0, BASE_QW, STRIDE_QW[15:0]);
    mem[RINGB + 1*4] = 64'd1;   // END
    run_submit;

    // Flush ch0's dirty cache lines to the physical mt48 model before peeking Bank0[].
    flush_to_sdram;

    // ---- verify: every cell-row qword landed at the strided address, matching
    // the quadrant painted at that (row,col). ----
    mism = 0;
    for (r = 0; r < CELL_ROWS; r = r + 1) begin
      for (c = 0; c < CELL_ROW_QW; c = c + 1) begin
        got   = read_qword((BASE_QW + r*STRIDE_QW + c) * 8);
        exp64 = {expect_color(r,c), expect_color(r,c), expect_color(r,c), expect_color(r,c)};
        if (got !== exp64) begin
          if (mism < 8) $display("  FAIL cell (row=%0d col=%0d): got=%h want=%h", r, c, got, exp64);
          mism = mism + 1;
        end
      end
    end
    if (mism == 0) $display("CELL DATA: PASS (%0d qwords)", CELL_ROWS*CELL_ROW_QW);
    else           $display("CELL DATA: FAIL (%0d mismatches)", mism);
    errs = errs + mism;

    // ---- verify: gap qwords (col in [CELL_ROW_QW, STRIDE_QW)) untouched. ----
    mism = 0;
    for (r = 0; r < CELL_ROWS; r = r + 1) begin
      for (c = CELL_ROW_QW; c < STRIDE_QW; c = c + 1) begin
        got = read_qword((BASE_QW + r*STRIDE_QW + c) * 8);
        if (got !== SENTINEL) begin
          if (mism < 8) $display("  FAIL gap (row=%0d col=%0d): got=%h want sentinel=%h", r, c, got, SENTINEL);
          mism = mism + 1;
        end
      end
    end
    if (mism == 0) $display("GAP UNTOUCHED: PASS (%0d qwords)", CELL_ROWS*(STRIDE_QW-CELL_ROW_QW));
    else           $display("GAP UNTOUCHED: FAIL (%0d mismatches)", mism);
    errs = errs + mism;

    // ---- ARGB4444 mode: paint only TL+BR quadrants, bake with BLT_F_BGCOV,
    // verify covered quadrants pack as alpha=0xF+truncated-color and uncovered
    // ones as alpha=0x0 (color bits don't matter when alpha=0, not checked).
    //
    // Task 3 (not landed yet) is what wires BLT_F_BGCOV command-flag decode to
    // c_bgcov_clear/bgw_argb4444 -- this task's own gate is the packing math
    // itself (Step 4's "real correctness gate for the packing math"), so this
    // scenario drives those two signals directly via hierarchical force/release
    // instead of relying on flag decode that doesn't exist yet. See
    // .superpowers/sdd/task-2-report.md for the full reasoning (escalated,
    // resolved with the team lead).
    //
    // The two signals are forced across SEPARATE submits (not one, unlike the
    // plan's original single-submit sketch), because they mean different
    // things to different ops and both a whole-cell clear-FILL and the two
    // quadrant paint-FILLs would otherwise share one force window: forcing
    // c_bgcov_clear=1 across the paints too would make THEM clear coverage
    // bits instead of setting them, corrupting the covered/uncovered split
    // this test depends on. run_submit already blocks until its command list
    // fully completes, so bracketing force/release at submit boundaries needs
    // no cycle-level timing knowledge of the FILL's internal pixel-write loop.
    // ---- ---------------------------------------------------------------- ----
    for (r = 0; r < CELL_ROWS; r = r + 1)
      for (c = 0; c < STRIDE_QW; c = c + 1)
        preload_qword((BASE_QW2 + r*STRIDE_QW + c) * 8, SENTINEL);

    // Submit 3: whole-cell FILL, forced into bake-coverage-CLEAR mode (flags
    // left 0 -- BLT_F_BGCOV isn't decoded yet, the force is what does the work).
    force blt.c_bgcov_clear = 1'b1;
    set_ctrl(2, 0);
    mem[RINGB + 0*4] = 64'h0000_0000_0000_0002;                     // FILL, flags=0
    mem[RINGB + 0*4 + 1] = {16'd240, 16'd320, 32'd0};                // full 320x240
    mem[RINGB + 0*4 + 2] = 64'd0;                                    // dst 0,0
    mem[RINGB + 0*4 + 3] = {16'd0, COLOR_TL, 32'd0};                 // clear color irrelevant (never read back)
    mem[RINGB + 1*4] = 64'd1;                                        // END
    run_submit;
    force blt.c_bgcov_clear = 1'b0;
    release blt.c_bgcov_clear;

    // Submit 4: paint only TL + BR quadrants (leaving TR/BL "uncovered").
    // Normal paint mode -- c_bgcov_clear released back to its default 0.
    set_ctrl(3, 0);
    wr_fill(0, 16'd0,   16'd0,   16'd160, 16'd120, COLOR_TL);        // TL covered
    wr_fill(1, 16'd160, 16'd120, 16'd160, 16'd120, COLOR_BR);        // BR covered
    mem[RINGB + 2*4] = 64'd1;                                        // END
    run_submit;

    // Submit 5: OP_BGPLANE_WRITE, forced into ARGB4444 pack mode (flags left 0
    // for the same reason as Submit 3 -- the force does the work, not the flag).
    force blt.bgw_argb4444 = 1'b1;
    set_ctrl(2, 0);
    mem[RINGB + 0*4] = {32'd0, 8'd0, 8'd0, 8'd0, OP_BGPLANE_WRITE};
    mem[RINGB + 0*4 + 1] = {32'd0, STRIDE_QW[15:0], 16'd0};
    mem[RINGB + 0*4 + 2] = {BASE_QW2[31:16], BASE_QW2[15:0], 32'd0};
    mem[RINGB + 0*4 + 3] = 64'd0;
    mem[RINGB + 1*4] = 64'd1;                                        // END
    run_submit;
    force blt.bgw_argb4444 = 1'b0;
    release blt.bgw_argb4444;
    flush_to_sdram;

    // verify: TL/BR quadrants packed as alpha=0xF + truncated color; TR/BL as alpha=0x0.
    mism = 0;
    for (r = 0; r < CELL_ROWS; r = r + 1) begin
      for (c = 0; c < CELL_ROW_QW; c = c + 1) begin
        got = read_qword((BASE_QW2 + r*STRIDE_QW + c) * 8);
        begin : per_pixel
          integer lane; reg [15:0] px; reg covered;
          for (lane = 0; lane < 4; lane = lane + 1) begin
            px = got[lane*16 +: 16];
            covered = (r < 120) ? (c < 40) : (c >= 40);   // TL(r<120,c<40) or BR(r>=120,c>=40)
            if (covered && px[15:12] !== 4'hF) begin
              if (mism < 8) $display("  FAIL argb (row=%0d col=%0d lane=%0d): want alpha=F got=%h", r, c, lane, px);
              mism = mism + 1;
            end
            if (!covered && px[15:12] !== 4'h0) begin
              if (mism < 8) $display("  FAIL argb (row=%0d col=%0d lane=%0d): want alpha=0 got=%h", r, c, lane, px);
              mism = mism + 1;
            end
          end
        end
      end
    end
    if (mism == 0) $display("ARGB4444 PACK: PASS");
    else           $display("ARGB4444 PACK: FAIL (%0d mismatches)", mism);
    errs = errs + mism;

    if (errs == 0) $display("RESULT: PASS");
    else           $display("RESULT: FAIL (%0d total mismatches)", errs);
    $finish;
  end

  initial begin #40000000 $display("RESULT: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire
