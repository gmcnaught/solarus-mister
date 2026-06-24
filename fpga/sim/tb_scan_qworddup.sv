// tb_scan_qworddup.sv — FAST faithful repro for the #44 qword-duplication
// (the "A,B,C,D drawn as A,A,C,C" banding, where each letter = one 64-bit qword
// = 4 RGB565 pixels).
//
// Wires the REAL scanout reader (openbor_video_top) to the REAL sdram_fb_cache
// + REAL Micron SDRAM model, but PRELOADS the framebuffer directly into SDRAM
// and drives only the ctrl word — NO compositor/blitter. That removes the slow
// composite path so the sim reaches scanout in seconds instead of minutes.
//
// Each FB qword carries its own column index (qw) and row (y):
//   qword(y,qw) = {16'(qw), 16'(y), 16'(qw), 16'(y)}
// The reader captures qword `beat_count` on each scan_ok. PASS iff, for every
// captured beat, the data's column-marker == beat_count and row == display_line
// (i.e. beat N really holds qword N). FAIL = qword duplication / misplacement.
`timescale 1ns/1ps
`default_nettype none
`include "vram_defs.vh"

module tb_scan_qworddup;
  localparam [28:0] WBASE  = 29'h07400000;   // ctrl/DDR window base (qword)
  localparam        MEMQW  = 32'h20000;       // 128k-qword DDR window
  localparam integer FBW = 320, FBH = 240, ROW_QW = FBW/4;

  // ---- clocks --------------------------------------------------------------
  reg clk_sys = 0;   always #5 clk_sys   = ~clk_sys;     // 100 MHz
  reg clk_sdram = 1; always #5 clk_sdram = ~clk_sdram;   // leads clk_sys by 5 ns
  reg clk_vid = 0;   always #9.3125 clk_vid = ~clk_vid;  // 53.69 MHz
  reg reset = 1;

  reg [2:0] ce_div = 3'd0; reg ce_pix = 1'b0;
  always @(posedge clk_vid) begin
    if (reset) begin ce_div<=0; ce_pix<=0; end
    else begin ce_div<=ce_div+3'd1; ce_pix<=(ce_div==3'd0); end
  end

  // ---- reader <-> DDR (direct, always granted) -----------------------------
  wire [7:0] nv_burst; wire [28:0] nv_addr; wire nv_rd;
  wire [63:0] nv_din;  wire [7:0] nv_be;    wire nv_we;
  wire [26:0] scan_addr; wire scan_rd; wire [63:0] scan_dout; wire scan_ok;
  wire        nv_vs_w;
  reg  [63:0] d_dout = 0; reg d_dready = 0; wire d_busy;

  openbor_video_top u_video (
    .clk_sys(clk_sys), .clk_vid(clk_vid), .ce_pix(ce_pix), .reset(reset),
    .ddr_busy(d_busy), .ddr_burstcnt(nv_burst), .ddr_addr(nv_addr),
    .ddr_dout(d_dout), .ddr_dout_ready(d_dready),
    .ddr_rd(nv_rd), .ddr_din(nv_din), .ddr_be(nv_be), .ddr_we(nv_we),
    .scan_addr(scan_addr), .scan_rd(scan_rd), .scan_dout(scan_dout), .scan_ok(scan_ok),
    .vga_r(), .vga_g(), .vga_b(), .vga_hs(), .vga_vs(nv_vs_w), .vga_de(),
    .enable(1'b1), .active(), .vsync_out(),
    .dbg_blt(32'd0), .dbg_addr(32'd0), .h_offset(3'd0), .v_offset(3'd0),
    .joystick_0(32'd0), .joystick_1(32'd0), .joystick_2(32'd0), .joystick_3(32'd0),
    .joystick_l_analog_0(16'd0),
    .ioctl_download(1'b0), .ioctl_wr(1'b0), .ioctl_addr(27'd0), .ioctl_dout(8'd0),
    .ioctl_wait(), .clk_audio(clk_vid), .audio_l(), .audio_r());

  // ---- SDRAM cache + Micron chip -------------------------------------------
  wire [15:0] SDQ; wire [12:0] SA; wire SDQML, SDQMH; wire [1:0] SBA;
  wire SnCS, SnWE, SnRAS, SnCAS, SCKE, scache_clk; wire coh_busy;

  reg [1:0] vs_sync = 2'b0;
  always @(posedge clk_sys) vs_sync <= {vs_sync[0], nv_vs_w};
  wire fb_vs = vs_sync[1];

  sdram_fb_cache fbcache (
    .clk(clk_sys), .clk_sdram(clk_sys), .rst(reset), .init(),
    .dst_addr(27'd0), .dst_rd(1'b0), .dst_wr(1'b0), .dst_din(64'd0),
    .dst_wdsn(8'hff), .dst_dout(), .dst_ok(),
    .scan_addr(scan_addr), .scan_rd(scan_rd), .scan_dout(scan_dout), .scan_ok(scan_ok),
    .p0_addr(27'd0), .p0_rd(1'b0), .p0_dout(), .p0_ok(),
    .stage_addr(27'd0), .stage_wr(1'b0), .stage_din(64'd0), .stage_wdsn(8'hff), .stage_ok(),
    .vs(fb_vs), .coh_busy(coh_busy),
    .sdram_dq(SDQ), .sdram_a(SA), .sdram_dqml(SDQML), .sdram_dqmh(SDQMH),
    .sdram_ba(SBA), .sdram_nwe(SnWE), .sdram_ncas(SnCAS), .sdram_nras(SnRAS),
    .sdram_ncs(SnCS), .sdram_cke(SCKE), .sdram_clk(scache_clk));

  mt48lc16m16a2 #(.addr_bits(13), .col_bits(10)) schip (
    .Dq(SDQ), .Addr(SA), .Ba(SBA), .Clk(clk_sdram), .Cke(SCKE),
    .Cs_n(SnCS), .Ras_n(SnRAS), .Cas_n(SnCAS), .We_n(SnWE), .Dqm({SDQMH, SDQML}),
    .downloading(1'b0), .VS(1'b0), .frame_cnt(32'd0));

  // ---- behavioral DDR3 (serves ctrl word + reader misc reads/writes) -------
  reg [63:0] mem [0:MEMQW-1];
  reg [1:0] bp=0; always @(posedge clk_sys) bp <= (bp==2'd2)?2'd0:bp+2'd1;
  integer ii;
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
        if (nv_rd) begin rbeats <= nv_burst; raddr <= nv_addr; rlat <= 3'd3; end
        else if (nv_we) for (ii=0; ii<8; ii=ii+1)
          if (nv_be[ii]) mem[(nv_addr-WBASE)][ii*8 +:8] <= nv_din[ii*8 +:8];
      end
    end
  end

  // ---- preload FB0 directly into the Micron array --------------------------
  // qword(y,qw) byte address = SDRAM_FB0_BASE + y*640 + qw*8 ; SCAN_OFFSET=0.
  // schip word address = (byteaddr>>3)*4 (+0), little-endian 4x16b.
  integer y, qw, wb, bytea;
  reg [63:0] v;
  task preload_fb0;
    begin
      for (y=0; y<FBH; y=y+1)
        for (qw=0; qw<ROW_QW; qw=qw+1) begin
          bytea = `SDRAM_FB0_BASE + y*`SDRAM_FB_STRIDE + qw*8;
          wb    = (bytea >> 3) * 4;
          v     = {16'(qw[15:0]), 16'(y[15:0]), 16'(qw[15:0]), 16'(y[15:0])};
          schip.Bank0[wb+0] = v[15: 0];
          schip.Bank0[wb+1] = v[31:16];
          schip.Bank0[wb+2] = v[47:32];
          schip.Bank0[wb+3] = v[63:48];
        end
    end
  endtask

  // ---- per-qword duplication detector + first-line trace -------------------
  wire [6:0] rdr_beat = u_video.reader.beat_count;
  wire [8:0] rdr_dl   = u_video.reader.display_line;
  wire       rdr_sync = u_video.reader.synced;
  integer qw_errs = 0, scan_oks = 0;

  // SOUND checker: snoop the reader's actual line-buffer WRITES (lb_we/lb_waddr/
  // lb_wdata). This validates exactly what gets displayed, independent of the
  // capture cadence, so it catches BOTH the buggy level-capture (a 2nd, stale
  // write to slot N+1) AND confirms the fix (one correct write per slot).
  //   lb_waddr = {display_line[0], beat_count[6:0]} ; lb_wdata = the qword.
  //   correct => wdata col-marker [63:48] == slot [6:0]  &&  row [15:0] == display_line.
  wire        lbwe = u_video.reader.lb_we;
  wire [7:0]  lbwa = u_video.reader.lb_waddr;
  wire [63:0] lbwd = u_video.reader.lb_wdata;
  always @(posedge clk_sys) if (!reset && lbwe && rdr_sync && rdr_dl < FBH) begin
    scan_oks = scan_oks + 1;
    if (lbwd[63:48] !== {9'd0, lbwa[6:0]} || lbwd[15:0] !== {7'd0, rdr_dl}) begin
      qw_errs = qw_errs + 1;
      if (qw_errs <= 24)
        $display("LBDUP line=%0d slot=%0d: wdata=%h  col-marker=%0d (exp %0d), row=%0d (exp %0d)",
                 rdr_dl, lbwa[6:0], lbwd, lbwd[63:48], lbwa[6:0], lbwd[15:0], rdr_dl);
    end
  end

  // ---- stimulus ------------------------------------------------------------
  integer settle;
  initial begin
    for (ii=0; ii<MEMQW; ii=ii+1) mem[ii]=64'd0;
    preload_fb0;
    repeat (16) @(posedge clk_sys);
    reset = 1'b0;

    // sync the reader: first ctrl read latches frame_counter=1, buf=0
    mem[0] = {32'd0, 32'h0000_0004};   // fc=1<<2 | buf0
    settle = 0;
    while (!rdr_sync && settle < 4_000_000) begin @(posedge clk_sys); settle=settle+1; end
    if (!rdr_sync) begin $display("RESULT: FAIL - reader never synced"); $finish; end
    $display("reader synced after %0d cyc", settle);

    // advance frame_counter -> reader loads buf_base=FB0 + first_frame_loaded -> scans
    mem[0] = {32'd0, 32'h0000_0008};   // fc=2<<2 | buf0

    // let it scan a few frames worth of lines
    settle = u_video.reader.vsync_count;
    while (u_video.reader.vsync_count < settle + 3 && scan_oks < 80*240*2)
      @(posedge clk_sys);

    $display("=== SUMMARY: scan_oks=%0d  qword-dup/misplace errors=%0d ===", scan_oks, qw_errs);
    if (scan_oks < 80) $display("RESULT: FAIL - scanout never progressed (scan_oks=%0d)", scan_oks);
    else if (qw_errs == 0) $display("RESULT: PASS  (every beat holds its own qword: no A,A,C,C)");
    else $display("RESULT: FAIL  (#44 reproduced: %0d qword duplications/misplacements)", qw_errs);
    $finish;
  end

  initial begin
    #2_000_000_000;
    $display("RESULT: FAIL - global timeout (scan_oks=%0d vs=%0d)", scan_oks, u_video.reader.vsync_count);
    $finish;
  end
endmodule
`default_nettype wire
