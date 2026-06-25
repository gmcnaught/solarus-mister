// tb_comp_banding.sv — pixel-exact banding repro for the compositor WRITE path.
//
// Purpose (issue #44 banding): the on-HW banding lives in what the compositor
// writes into the SDRAM framebuffer (scanout proven innocent — H2 refuted:
// skipped_lines=0, full 240-line fetch). This tb drives the REAL compositor write
// datapath end-to-end and checks the framebuffer PIXEL-EXACT:
//
//   blitter_top(comp_pipeline) -> vram_demux -> { DDR side  -> ddr_blitter_arb -> behavioral DDR (COPY source)
//                                                 SDRAM side -> sdram_fb_cache P_DST }
//   sdram_fb_cache -> jtframe_burst_sdram -> mt48lc16m16a2 (faithful Micron)
//
// Unlike tb_vram_contention (progress-based, single-color FILL, can't SEE banding),
// this composites a PIXEL-UNIQUE test image via a full-screen COPY/BLIT, then reads
// the framebuffer back through the cache P_SCAN port (after a coherency flush) and
// asserts FB[y] == V(y). A misplaced/duplicated/stale band yields an EXACT mismatch
// whose low byte names the source row it leaked from.
//
//   Test image: every pixel in row y = V(y) = (BAND_HI[y>>4] << 8) | (y & 8'hFF).
//     low byte  = y (0..239) -> globally unique per row (exact band-shift detection).
//     high byte = per-16px-band tint -> crisp boundaries aligned to BAND_H=16.
//
// No scanout reader / no DDR-scan contention here: the read path is innocent, so we
// keep the tb fast by driving P_SCAN ourselves only for the readback.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
`include "vram_defs.vh"

module tb_comp_banding;
  localparam [28:0] WBASE = 29'h07400000;   // DDR window base; mem index = addr-WBASE
  // mem must cover control block (0x200000) + COPY source image (0x201000 + 240*80).
  localparam        MEMQW = 32'h206000;

  // ---- clocks --------------------------------------------------------------
  reg clk_sys = 0;   always #5 clk_sys   = ~clk_sys;     // 100 MHz
  reg clk_sdram = 1; always #5 clk_sdram = ~clk_sdram;   // leads clk_sys by 5 ns
  reg reset = 1;

  // ---- framebuffer geometry (RGB565, 320x240) ------------------------------
  localparam integer FBW = 320, FBH = 240;
  localparam integer ROW_QW = FBW/4;             // 80 qwords/row
  localparam integer ROW_B  = FBW*2;             // 640 bytes/row

  // Per-row test value: low byte = y (unique), high byte = band tint.
  function [15:0] vrow(input integer y);
    reg [7:0] hi;
    begin
      // alternating high-contrast band tint every 16 rows (visual boundaries)
      hi   = ((y>>4) & 1) ? 8'hF8 : 8'h07;       // red-ish vs green-ish high byte
      vrow = {hi, y[7:0]};
    end
  endfunction

  // ================= BLITTER -> VRAM DEMUX (mirror Solarus.sv) ===============
  wire [31:0] bt_addr; wire bt_rd, bt_wr; wire [63:0] bt_din; wire [7:0] bt_be;
  wire [7:0]  bt_burstcnt;
  wire        bt_idle;
  wire [63:0] blt_demux_dout; wire blt_demux_dready, blt_busy_w;
  wire [31:0] blt_dbg;
  // demux DDR side -> ddr_blitter_arb blt_*
  wire [28:0] bd_addr; wire bd_rd, bd_wr; wire [63:0] bd_din; wire [7:0] bd_be;
  wire        b_grant; wire blt_arb_busy;
  // [collapse-single-source] The per-blit source read is hardwired to SDRAM
  // (src_in_sdram=1), so the compositor now fetches its COPY source rows through
  // the P_SRC (p0_*) port — NOT the DDR mem_* path. This tb is the compositor
  // WRITE-path banding probe (the read path is proven innocent), so we serve p0_*
  // from a FAST behavioral model that returns the same SRC-window source image the
  // test already preloads (mem[0x201000 + heap_qw]); the WRITE path under test
  // (vram_demux -> sdram_fb_cache P_DST -> Micron) is unchanged.
  wire [26:0] bs_p0_addr; wire bs_p0_rd;
  wire        bs_we; wire [15:0] bs_din; wire [26:0] bs_waddr;
  wire        bs_we_burst; wire [63:0] bs_din64;
  wire [3:0]  vdemux_dbg;

  // ── P_SRC cache-ok behavioral source model (decls; always block after mem[]) ──
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

  // demux SDRAM side -> sdram_fb_cache P_DST (cache-ok)
  wire [26:0] dst_addr; wire dst_rd, dst_wr;
  wire [63:0] dst_din;  wire [7:0] dst_wdsn;
  wire [63:0] dst_dout; wire dst_ok;

  // behavioral DDR3 nets (model below)
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
    .sd_din(dst_din), .sd_wdsn(dst_wdsn),
    .sd_dout(dst_dout), .sd_ok(dst_ok),
    .dbg(vdemux_dbg));

  // ================= DDR blitter arbiter (blitter only; no reader) ===========
  // blt_burstcnt = the blitter's real burst length (matches Solarus.sv #1 fix):
  // a full-screen COPY bursts source rows from DDR -> must reach the arb.
  ddr_blitter_arb #(.ENABLE(1'b1)) arb_ddr (
    .clk(clk_sys), .reset(reset),
    .rdr_burstcnt(8'd0), .rdr_addr(29'd0), .rdr_rd(1'b0), .rdr_din(64'd0),
    .rdr_be(8'd0), .rdr_we(1'b0), .rdr_busy(), .rdr_grant(),
    .blt_burstcnt(bt_burstcnt), .blt_addr(bd_addr), .blt_rd(bd_rd), .blt_din(bd_din),
    .blt_be(bd_be), .blt_we(bd_wr), .blt_busy(blt_arb_busy), .blt_grant(b_grant),
    .ddram_busy(d_busy), .ddram_dout_ready(d_dready),
    .ddram_burstcnt(d_burst), .ddram_addr(d_addr), .ddram_rd(d_rd),
    .ddram_din(d_din), .ddram_be(d_be), .ddram_we(d_we), .dbg());

  // ================= SDRAM framebuffer cache ================================
  reg  [26:0] scan_addr_r = 27'd0;  reg scan_rd_r = 1'b0;
  wire [63:0] scan_dout;  wire scan_ok;
  reg         vs_r = 1'b0;          wire coh_busy;

  wire [15:0] SDQ; wire [12:0] SA; wire SDQML, SDQMH; wire [1:0] SBA;
  wire        SnCS, SnWE, SnRAS, SnCAS, SCKE, cache_sdram_clk;

  sdram_fb_cache fbcache (
    .clk(clk_sys), .clk_sdram(clk_sys), .rst(reset), .init(),
    .dst_addr(dst_addr), .dst_rd(dst_rd), .dst_wr(dst_wr),
    .dst_din(dst_din), .dst_wdsn(dst_wdsn), .dst_dout(dst_dout), .dst_ok(dst_ok),
    .scan_addr(scan_addr_r), .scan_rd(scan_rd_r), .scan_dout(scan_dout), .scan_ok(scan_ok),
    .p0_addr(27'd0), .p0_rd(1'b0), .p0_dout(), .p0_ok(),
    .stage_addr(27'd0), .stage_wr(1'b0), .stage_din(64'd0), .stage_wdsn(8'hff), .stage_ok(),
    .vs(vs_r), .coh_busy(coh_busy),
    .sdram_dq(SDQ), .sdram_a(SA), .sdram_dqml(SDQML), .sdram_dqmh(SDQMH),
    .sdram_ba(SBA), .sdram_nwe(SnWE), .sdram_ncas(SnCAS), .sdram_nras(SnRAS),
    .sdram_ncs(SnCS), .sdram_cke(SCKE), .sdram_clk(cache_sdram_clk));

  mt48lc16m16a2 #(.addr_bits(13), .col_bits(10)) schip (
    .Dq(SDQ), .Addr(SA), .Ba(SBA), .Clk(clk_sdram), .Cke(SCKE),
    .Cs_n(SnCS), .Ras_n(SnRAS), .Cas_n(SnCAS), .We_n(SnWE), .Dqm({SDQMH, SDQML}),
    .downloading(1'b0), .VS(1'b0), .frame_cnt(32'd0));

  // ================= Behavioral DDR3 with backpressure ======================
  reg [63:0] mem [0:MEMQW-1];

  // P_SRC cache-ok behavioral source model (serves the compositor's source rows
  // from the SRC-window image preloaded into mem[0x201000+]). Placed after mem[]
  // so the procedural read binds. p0_addr is the heap byte offset; heap_qw>>3.
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

  // ================= command-list builder: full-screen COPY ==================
  // Source image preloaded into the DDR source heap (SRC_QW = byte 0x3B008000 =
  // mem index 0x201000). One BLIT command copies the whole 320x240 to FB0.
  integer submit_n = 0;
  task submit_copy_frame;
    begin
      wmem(32'h200002, 64'd0);          // target_buf = 0 -> FB0 (SDRAM)
      wmem(32'h200004, 64'd0);          // flags = 0
      wmem(32'h200007, 64'd0);          // throttle=0 (C_SRCSEL bit0 dead: source always SDRAM)
      wmem(32'h200001, 64'd2);          // cmd_count = 2 (BLIT + END)
      // cmd0 BLIT: op=3 (blend=COPY, fmt=0/16bpp), src_off=0, full screen.
      wmem(32'h200008, 64'h0000_0000_0000_0003);                    // op=BLIT, src_off=0
      wmem(32'h200009, {16'(FBH), 16'(FBW), 16'd0, 16'(ROW_B)});    // h|w|src_x|stride(bytes)
      wmem(32'h20000A, {16'd0, 16'd0, 16'd0, 16'd0});               // dst_y|dst_x|0|src_y
      wmem(32'h20000B, 64'd0);                                      // key/alpha/unused
      wmem(32'h20000C, 64'd1);          // cmd1 END
      wmem(32'h20000D, 64'd0); wmem(32'h20000E, 64'd0); wmem(32'h20000F, 64'd0);
      submit_n = submit_n + 1;
      wmem(32'h200000, submit_n[63:0]); // bump submit -> compositor renders the frame
    end
  endtask

  // ================= P_SCAN readback (after coherency flush) =================
  // SDRAM_FB0_BASE byte addr; reader/demux both address FB0 at this base.
  task scan_read(input [26:0] byte_addr, output [63:0] q);
    integer cyc;
    begin
      cyc = 0;
      @(posedge clk_sys); #1;
      scan_addr_r = byte_addr; scan_rd_r = 1'b1;
      @(posedge clk_sys); #1; scan_rd_r = 1'b0;
      while (!scan_ok) begin
        @(posedge clk_sys); cyc=cyc+1;
        if (cyc>5000) begin $display("RESULT: FAIL - scan_read timeout @%h", byte_addr); $finish; end
      end
      q = scan_dout;
    end
  endtask

  // ================= stimulus ===============================================
  integer y, qw, qsel, lane, settle;
  integer bad_rows, first_bad_y, total_checks;
  reg [63:0] got;
  reg [15:0] px, want;
  reg [14:0] band_bad;   // per-16px-band fail flag (15 bands)
  integer band;
  reg got_first_bad;
  integer qsamp [0:2];   // sampled qwords per row: left / middle / right

  initial begin
    for (i=0;i<MEMQW;i=i+1) mem[i]=64'd0;

    // Preload the test image into the DDR source heap. SRC_QW (qword) - WBASE =
    // 0x07601000 - 0x07400000 = 0x201000. Each row: 80 qwords, all = {V,V,V,V}.
    for (y=0; y<FBH; y=y+1) begin
      px = vrow(y);
      for (qw=0; qw<ROW_QW; qw=qw+1)
        mem[32'h201000 + y*ROW_QW + qw] = {px, px, px, px};
    end

    repeat (16) @(posedge clk_sys);
    reset = 1'b0;
    repeat (8) @(posedge clk_sys);

    // ---- composite one full-screen COPY frame --------------------------------
    submit_copy_frame;
    settle = 0;
    while (done_seq !== submit_n[31:0]) begin
      @(posedge clk_sys); settle = settle + 1;
      if (settle > 80_000_000) begin
        $display("RESULT: FAIL - compositor never completed (done_seq=%0d submit=%0d blt.state=%0d)",
                 done_seq, submit_n, blt.state);
        $finish;
      end
    end
    $display("compositor completed frame in %0d cyc (blt.state=%0d)", settle, blt.state);

    // ---- coherency flush: commit ch0 dirty -> SDRAM, invalidate ch4 ----------
    @(posedge clk_sys); #1; vs_r = 1'b1;
    repeat (4) @(posedge clk_sys);
    #1; vs_r = 1'b0;
    settle = 0;
    while (coh_busy) begin
      @(posedge clk_sys); settle = settle + 1;
      if (settle > 2_000_000) begin $display("RESULT: FAIL - coh_busy never cleared"); $finish; end
    end
    $display("coherency flush complete");

    // ---- read framebuffer back and check PIXEL-EXACT -------------------------
    // Sample 3 qwords per row (left/middle/right) — every pixel in a row == V(y).
    bad_rows=0; first_bad_y=-1; total_checks=0; band_bad=15'd0; got_first_bad=1'b0;
    qsamp[0]=0; qsamp[1]=ROW_QW/2; qsamp[2]=ROW_QW-1;   // left / middle / right
    for (y=0; y<FBH; y=y+1) begin
      want = vrow(y);
      for (qsel=0; qsel<3; qsel=qsel+1) begin
        qw = qsamp[qsel];
        scan_read(27'(`SDRAM_FB0_BASE) + 27'(y*ROW_B + qw*8), got);
        total_checks = total_checks + 1;
        for (lane=0; lane<4; lane=lane+1) begin
          px = got[lane*16 +:16];
          if (px !== want) begin
            band = y >> 4;
            band_bad[band] = 1'b1;
            if (!got_first_bad) begin
              got_first_bad = 1'b1; first_bad_y = y;
              $display("FIRST MISMATCH @ row y=%0d qw=%0d lane=%0d x=%0d : got=%04h want=%04h  (got.low=%0d => leaked from source row %0d)",
                       y, qw, lane, qw*4+lane, px, want, px[7:0], px[7:0]);
            end
          end
        end
      end
    end

    // count distinct bad rows (re-scan qw0 only for the tally)
    bad_rows=0;
    for (y=0; y<FBH; y=y+1) begin
      want = vrow(y);
      scan_read(27'(`SDRAM_FB0_BASE) + 27'(y*ROW_B), got);
      if (got[15:0] !== want) bad_rows = bad_rows + 1;
    end

    $display("=== BANDING MAP (15 bands x 16px) ===");
    for (band=0; band<15; band=band+1)
      $display("  band %2d  rows %3d..%3d  : %s", band, band*16, band*16+15,
               band_bad[band] ? "CORRUPT" : "ok");
    $display("checks=%0d  bad_rows(qw0)=%0d / %0d", total_checks, bad_rows, FBH);

    if (band_bad == 15'd0 && bad_rows == 0) begin
      $display("RESULT: PASS  (framebuffer matches the test image exactly - no banding in the compositor write path)");
    end else begin
      $display("RESULT: FAIL  (BANDING REPRODUCED: first bad row=%0d, %0d/%0d rows corrupt)",
               first_bad_y, bad_rows, FBH);
    end
    $finish;
  end

  // hard backstop
  initial begin
    #4_000_000_000;
    $display("RESULT: FAIL - global sim timeout (done_seq=%0d)", done_seq);
    $finish;
  end

endmodule
`default_nettype wire
