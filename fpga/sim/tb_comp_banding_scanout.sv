// tb_comp_banding_scanout.sv — DOUBLE-BUFFERED async-flush banding repro (#44, path A).
//
// Hypothesis: the on-HW "band duplication" is the cache coherency flush/invalidate
// (fired every display-vsync, async to the compositor) vs the scanout buffer switch
// serving a SINGLE displayed frame a MIX of new (flushed) and stale (un-flushed /
// previous-frame) bands. H2 (scanout underflow) does NOT exclude this: the reader
// never SKIPS lines, it faithfully fetches all 240 — some just stale.
//
// This tb wires the REAL scanout reader + REAL sdram_fb_cache + REAL compositor and
// models the engine's DOUBLE-BUFFER anti-tear protocol exactly as the reader expects:
//   - composite frame f into the BACK buffer (target_buf alternates 0/1),
//   - at vblank publish ctrl_word = {frame_counter++ , active_buffer=back} @ 0x3A000000,
//   - the reader latches active_buffer/buf_base when frame_counter advances (rtl line ~677).
// The cache coherency fb_vs flush fires every reader vsync (nv_vs double-flopped), as
// in Solarus.sv.
//
// Each compositor frame paints a FRAME-UNIQUE pixel pattern via a full-screen COPY:
//   V(x,y,f) = (f[7:0] << 8) | y[7:0]   (every pixel in row y of frame f).
// We SNOOP the P_SCAN returns (scan_dout per fetched line) — no RGB565 truncation —
// recording, per fetched display line, the frame-id (hi byte) and row-id (lo byte).
//
// PASS  = every displayed frame is internally consistent: all fetched lines share ONE
//         frame-id, and fetched row-id == display_line (no stale/misplaced bands).
// FAIL  = a displayed frame mixes frame-ids across bands  -> BAND DUPLICATION REPRODUCED.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
`include "vram_defs.vh"

module tb_comp_banding_scanout;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = 32'h206000;
  localparam integer FBW = 320, FBH = 240, ROW_QW = FBW/4, ROW_B = FBW*2;
  localparam integer NFRAMES = 3;        // distinct compositor frames to drive

  // ---- clocks --------------------------------------------------------------
  reg clk_sys = 0;   always #5 clk_sys   = ~clk_sys;     // 100 MHz
  reg clk_sdram = 1; always #5 clk_sdram = ~clk_sdram;   // leads clk_sys by 5 ns
  reg clk_vid = 0;   always #9.3125 clk_vid = ~clk_vid;  // 53.69 MHz CLK_VIDEO
  reg reset = 1;

  reg [2:0] ce_div = 3'd0; reg ce_pix = 1'b0;
  always @(posedge clk_vid) begin
    if (reset) begin ce_div<=0; ce_pix<=0; end
    else begin ce_div<=ce_div+3'd1; ce_pix<=(ce_div==3'd0); end
  end

  // ---- behavioral DDR3 nets ------------------------------------------------
  wire [7:0] d_burst; wire [28:0] d_addr; wire d_rd; wire [63:0] d_din;
  wire [7:0] d_be;    wire d_we;
  wire       d_busy;  reg d_dready = 0; reg [63:0] d_dout = 0;
  wire [31:0] blt_dbg;
  wire [3:0]  vdemux_dbg;

  // ================= REAL SCANOUT READER =====================================
  wire  [7:0] nv_burst;  wire [28:0] nv_addr;  wire nv_rd;
  wire [63:0] nv_din;    wire  [7:0] nv_be;    wire nv_we;
  wire        rdr_busy_w, rdr_grant_w;
  wire [26:0] scan_addr; wire scan_rd;
  wire [63:0] scan_dout; wire scan_ok;
  wire        nv_vs_w;

  openbor_video_top u_video (
    .clk_sys(clk_sys), .clk_vid(clk_vid), .ce_pix(ce_pix), .reset(reset),
    .ddr_busy(rdr_busy_w), .ddr_burstcnt(nv_burst), .ddr_addr(nv_addr),
    .ddr_dout(d_dout), .ddr_dout_ready(d_dready & rdr_grant_w),
    .ddr_rd(nv_rd), .ddr_din(nv_din), .ddr_be(nv_be), .ddr_we(nv_we),
    .scan_addr(scan_addr), .scan_rd(scan_rd), .scan_dout(scan_dout), .scan_ok(scan_ok),
    .vga_r(), .vga_g(), .vga_b(), .vga_hs(), .vga_vs(nv_vs_w), .vga_de(),
    .enable(1'b1), .active(), .vsync_out(),
    .dbg_blt(blt_dbg), .dbg_addr(32'd0), .h_offset(3'd0), .v_offset(3'd0),
    .joystick_0(32'd0), .joystick_1(32'd0), .joystick_2(32'd0), .joystick_3(32'd0),
    .joystick_l_analog_0(16'd0),
    .ioctl_download(1'b0), .ioctl_wr(1'b0), .ioctl_addr(27'd0), .ioctl_dout(8'd0),
    .ioctl_wait(), .clk_audio(clk_vid), .audio_l(), .audio_r());

  // ================= BLITTER -> VRAM DEMUX ===================================
  wire [31:0] bt_addr; wire bt_rd, bt_wr; wire [63:0] bt_din; wire [7:0] bt_be;
  wire [7:0]  bt_burstcnt; wire bt_idle;
  wire [63:0] blt_demux_dout; wire blt_demux_dready, blt_busy_w;
  wire [28:0] bd_addr; wire bd_rd, bd_wr; wire [63:0] bd_din; wire [7:0] bd_be;
  wire        b_grant; wire blt_arb_busy;
  wire [26:0] bs_p0_addr; wire bs_p0_rd;
  wire        bs_we; wire [15:0] bs_din; wire [26:0] bs_waddr;
  wire        bs_we_burst; wire [63:0] bs_din64;

  // [collapse-single-source] source read is hardwired to SDRAM (src_in_sdram=1):
  // serve p0_* from the SRC-window image preloaded into mem[0x201000+] (decls here;
  // always block placed after mem[] so the procedural read binds).
  localparam P_SRC_LAT = 3;
  localparam [28:0] SRC_WIN = `SRC_QW - WBASE;   // 0x201000
  reg  [63:0] bs_p0_dout; reg bs_p0_ok = 1'b0;
  reg         bs_rd_d;
  reg [26:0]  bs_lat_addr [0:P_SRC_LAT-1];
  reg         bs_lat_v    [0:P_SRC_LAT-1];
  integer     bsli;

  blitter_top blt (
    .clk(clk_sys), .rst(reset),
    .mem_addr(bt_addr), .mem_rd(bt_rd), .mem_wr(bt_wr), .mem_burstcnt(bt_burstcnt),
    .mem_din(bt_din), .mem_be(bt_be),
    .mem_dout(blt_demux_dout), .mem_dout_ready(blt_demux_dready), .mem_busy(blt_busy_w),
    .p0_addr(bs_p0_addr), .p0_rd(bs_p0_rd), .p0_dout(bs_p0_dout), .p0_ok(bs_p0_ok),
    .src_sdram_we(bs_we), .src_sdram_din(bs_din), .src_sdram_waddr(bs_waddr),
    .src_sdram_we_burst(bs_we_burst), .src_sdram_din64(bs_din64), .src_sdram_ok(1'b1),
    .idle(bt_idle), .dbg(blt_dbg));

  wire [26:0] dst_addr; wire dst_rd, dst_wr;
  wire [63:0] dst_din;  wire [7:0] dst_wdsn;
  wire [63:0] dst_dout; wire dst_ok;

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

  // ================= DDR blitter arbiter (reader + blitter share DDR3) =======
  ddr_blitter_arb #(.ENABLE(1'b1)) arb_ddr (
    .clk(clk_sys), .reset(reset),
    .rdr_burstcnt(nv_burst), .rdr_addr(nv_addr), .rdr_rd(nv_rd), .rdr_din(nv_din),
    .rdr_be(nv_be), .rdr_we(nv_we), .rdr_busy(rdr_busy_w), .rdr_grant(rdr_grant_w),
    .blt_burstcnt(bt_burstcnt), .blt_addr(bd_addr), .blt_rd(bd_rd), .blt_din(bd_din),
    .blt_be(bd_be), .blt_we(bd_wr), .blt_busy(blt_arb_busy), .blt_grant(b_grant),
    .ddram_busy(d_busy), .ddram_dout_ready(d_dready),
    .ddram_burstcnt(d_burst), .ddram_addr(d_addr), .ddram_rd(d_rd),
    .ddram_din(d_din), .ddram_be(d_be), .ddram_we(d_we), .dbg());

  // ================= SDRAM framebuffer cache + Micron chip ===================
  wire [15:0] SDQ; wire [12:0] SA; wire SDQML, SDQMH; wire [1:0] SBA;
  wire        SnCS, SnWE, SnRAS, SnCAS, SCKE, cache_sdram_clk;
  wire        coh_busy;

  reg [1:0] vs_sync = 2'b0;
  always @(posedge clk_sys) vs_sync <= {vs_sync[0], nv_vs_w};
  wire fb_vs = vs_sync[1];

  sdram_fb_cache fbcache (
    .clk(clk_sys), .clk_sdram(clk_sys), .rst(reset), .init(),
    .dst_addr(dst_addr), .dst_rd(dst_rd), .dst_wr(dst_wr),
    .dst_din(dst_din), .dst_wdsn(dst_wdsn), .dst_dout(dst_dout), .dst_ok(dst_ok),
    .scan_addr(scan_addr), .scan_rd(scan_rd), .scan_dout(scan_dout), .scan_ok(scan_ok),
    .p0_addr(27'd0), .p0_rd(1'b0), .p0_dout(), .p0_ok(),
    .stage_addr(27'd0), .stage_wr(1'b0), .stage_din(64'd0), .stage_wdsn(8'hff), .stage_ok(),
    .stage_barrier(1'b0), .stage_busy(),   // no STAGE in this bench
    .dst_barrier(1'b0), .dst_busy(),       // no carry-forward in this bench
    .vs(fb_vs), .coh_busy(coh_busy),
    .sdram_dq(SDQ), .sdram_a(SA), .sdram_dqml(SDQML), .sdram_dqmh(SDQMH),
    .sdram_ba(SBA), .sdram_nwe(SnWE), .sdram_ncas(SnCAS), .sdram_nras(SnRAS),
    .sdram_ncs(SnCS), .sdram_cke(SCKE), .sdram_clk(cache_sdram_clk));

  mt48lc16m16a2 #(.addr_bits(13), .col_bits(10)) schip (
    .Dq(SDQ), .Addr(SA), .Ba(SBA), .Clk(clk_sdram), .Cke(SCKE),
    .Cs_n(SnCS), .Ras_n(SnRAS), .Cas_n(SnCAS), .We_n(SnWE), .Dqm({SDQMH, SDQML}),
    .downloading(1'b0), .VS(1'b0), .frame_cnt(32'd0));

  // ================= behavioral DDR3 with backpressure =======================
  reg [63:0] mem [0:MEMQW-1];

  // P_SRC cache-ok behavioral source model (after mem[] so the read binds).
  always @(posedge clk_sys) bs_rd_d <= bs_p0_rd;
  always @(posedge clk_sys) begin
    bs_p0_ok <= 1'b0;
    bs_lat_v   [0] <= bs_p0_rd & ~bs_rd_d;
    bs_lat_addr[0] <= bs_p0_addr;
    for (bsli = 1; bsli < P_SRC_LAT; bsli = bsli + 1) begin
      bs_lat_v   [bsli] <= bs_lat_v   [bsli-1];
      bs_lat_addr[bsli] <= bs_lat_addr[bsli-1];
    end
    if (bs_lat_v[P_SRC_LAT-1]) begin
      bs_p0_dout <= mem[SRC_WIN + (bs_lat_addr[P_SRC_LAT-1] >> 3)];
      bs_p0_ok   <= 1'b1;
    end
  end
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

  // Paint the DDR COPY source with frame f's pattern: row y -> V = (f<<8)|y.
  task load_source(input [7:0] fid);
    integer y, qw; reg [15:0] px;
    begin
      for (y=0; y<FBH; y=y+1) begin
        px = {fid, y[7:0]};
        for (qw=0; qw<ROW_QW; qw=qw+1)
          mem[32'h201000 + y*ROW_QW + qw] = {px, px, px, px};
      end
    end
  endtask

  integer submit_n = 0;
  task submit_copy(input integer tbuf);
    begin
      wmem(32'h200002, tbuf[63:0]);     // target_buf
      wmem(32'h200004, 64'd0);          // flags=0
      wmem(32'h200007, 64'd0);          // throttle=0 (C_SRCSEL bit0 dead: source always SDRAM)
      wmem(32'h200001, 64'd2);          // cmd_count=2
      wmem(32'h200008, 64'h0000_0000_0000_0003);                  // op=BLIT, COPY
      wmem(32'h200009, {16'(FBH), 16'(FBW), 16'd0, 16'(ROW_B)});  // h|w|src_x|stride
      wmem(32'h20000A, 64'd0);                                    // dst=(0,0) src=(0,0)
      wmem(32'h20000B, 64'd0);
      wmem(32'h20000C, 64'd1);          // END
      wmem(32'h20000D, 64'd0); wmem(32'h20000E,64'd0); wmem(32'h20000F,64'd0);
      submit_n = submit_n + 1;
      wmem(32'h200000, submit_n[63:0]);
    end
  endtask

  // ================= SCAN SNOOP + band-duplication detector ==================
  // For the CURRENT displayed frame, record the frame-id observed for each line.
  reg  [7:0]  seen_fid  [0:FBH-1];
  reg         seen_have [0:FBH-1];
  reg  [8:0]  seen_ly   [0:FBH-1];
  integer     cur_vs = -1;            // displayed-frame index we are accumulating
  integer     fail_dup = 0, fail_line = 0;
  integer     report_done = 0;

  // snapshot of the reader's display line at each scan return
  wire [8:0]  rdr_dl = u_video.reader.display_line;
  wire [31:0] rdr_vs = u_video.reader.vsync_count;

  integer k, distinct, base_fid, b;
  reg [7:0] band_fid [0:14];
  reg [14:0] band_seen;

  task evaluate_frame(input integer vsidx);
    begin
      // collect distinct frame-ids seen this displayed frame
      distinct = 0; base_fid = -1; band_seen = 15'd0;
      for (b=0;b<15;b=b+1) band_fid[b]=8'hxx;
      for (k=0;k<FBH;k=k+1) begin
        if (seen_have[k]) begin
          if (base_fid == -1) base_fid = seen_fid[k];
          band_fid[k>>4] = seen_fid[k];
          band_seen[k>>4] = 1'b1;
          if (seen_ly[k] !== k[8:0]) fail_line = fail_line + 1;
        end
      end
      // count distinct band frame-ids
      distinct = 0;
      for (b=0;b<15;b=b+1) if (band_seen[b]) begin
        if (b==0) distinct=1;
        else if (band_fid[b] !== band_fid[0]) distinct = distinct + 1; // rough: >1 => mix
      end
      // robust mix check: scan all seen lines for any fid != base_fid
      distinct = 0;
      for (k=0;k<FBH;k=k+1)
        if (seen_have[k] && seen_fid[k] !== base_fid[7:0]) distinct = distinct + 1;

      if (base_fid != -1) begin
        if (distinct != 0) begin
          fail_dup = fail_dup + 1;
          $display("BAND DUPLICATION @ displayed frame %0d: %0d/%0d fetched lines differ from base frame-id %0d",
                   vsidx, distinct, FBH, base_fid);
          $display("  per-band frame-id map (band=16px):");
          for (b=0;b<15;b=b+1)
            if (band_seen[b]) $display("    band %2d rows %3d..%3d : frame-id %0d", b, b*16, b*16+15, band_fid[b]);
        end else begin
          $display("frame %0d OK: all fetched bands frame-id %0d (line-placement errors so far=%0d)",
                   vsidx, base_fid, fail_line);
        end
      end
    end
  endtask

  // accumulate per-line frame-id on each scan return; evaluate at frame rollover
  always @(posedge clk_sys) begin
    if (!reset) begin
      if (rdr_vs != cur_vs[31:0]) begin
        if (cur_vs >= 0) evaluate_frame(cur_vs);
        // reset accumulators for the new displayed frame
        for (i=0;i<FBH;i=i+1) begin seen_have[i] <= 1'b0; end
        cur_vs <= rdr_vs;
      end
      if (scan_ok && rdr_dl < FBH) begin
        seen_fid[rdr_dl]  <= scan_dout[15:8];
        seen_ly[rdr_dl]   <= {1'b0, scan_dout[7:0]};
        seen_have[rdr_dl] <= 1'b1;
      end
    end
  end

  // ================= heartbeat (progress trace) ==============================
  integer settle, fdrv = 0, back;
  integer hb = 0, scan_oks = 0;
  always @(posedge clk_sys) if (!reset) begin
    if (scan_ok) scan_oks = scan_oks + 1;
    hb = hb + 1;
    if (hb % 200_000 == 0)
      $display("[hb %0t] driven_frame=%0d done_seq=%0d submit=%0d | rdr.state=%0d dl=%0d vs=%0d synced=%0b | scan_oks=%0d back_ctrl=%h",
               $time, fdrv, done_seq, submit_n, u_video.reader.state, rdr_dl, rdr_vs,
               u_video.reader.synced, scan_oks, mem[0][31:0]);
  end

  // ================= stimulus: double-buffered publish loop ==================
  reg vs_q;
  initial begin
    for (i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    for (i=0;i<FBH;i=i+1) begin seen_have[i]=1'b0; seen_ly[i]=0; seen_fid[i]=0; end
    repeat (16) @(posedge clk_sys);
    reset = 1'b0;

    settle = 0;
    while (!u_video.reader.synced) begin
      @(posedge clk_sys); settle=settle+1;
      if (settle>4_000_000) begin $display("RESULT: FAIL - reader never synced"); $finish; end
    end
    $display("reader synced after %0d cyc", settle);

    back = 0;
    for (fdrv=1; fdrv<=NFRAMES; fdrv=fdrv+1) begin
      load_source(fdrv[7:0]);          // frame fdrv pattern into DDR source
      submit_copy(back);               // composite into back buffer
      settle = 0;
      while (done_seq !== submit_n[31:0] && settle < 40_000_000) begin
        @(posedge clk_sys); settle=settle+1;
      end
      // anti-tear barrier: wait for a reader vblank, then publish the swap.
      vs_q = nv_vs_w; settle=0;
      while (!(nv_vs_w & ~vs_q) && settle<8_000_000) begin
        vs_q=nv_vs_w; @(posedge clk_sys); settle=settle+1;
      end
      // publish ctrl_word = {frame_counter++, active_buffer=back}
      wmem(32'h000000, {32'd0, (fdrv[29:0]<<2) | back[1:0]});
      back = back ^ 1;
    end

    // let the reader display a couple more frames past the last publish
    settle = u_video.reader.vsync_count;
    while (u_video.reader.vsync_count < settle + 3) @(posedge clk_sys);

    $display("=== SUMMARY: band-dup frames=%0d  line-placement errors=%0d ===", fail_dup, fail_line);
    if (fail_dup==0 && fail_line==0)
      $display("RESULT: PASS  (no band duplication: every displayed frame is one consistent compositor frame)");
    else
      $display("RESULT: FAIL  (BAND DUPLICATION REPRODUCED: %0d mixed frames, %0d misplaced lines)", fail_dup, fail_line);
    $finish;
  end

  // hard backstop
  initial begin
    #6_000_000_000;
    $display("RESULT: FAIL - global sim timeout (drove %0d frames, reader vs=%0d)", submit_n, u_video.reader.vsync_count);
    $finish;
  end

endmodule
`default_nettype wire
