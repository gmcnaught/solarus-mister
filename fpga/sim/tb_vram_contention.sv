// tb_vram_contention.sv — SDRAM scan-vs-compositor contention (issue #34, compositor).
//
// SDRAM scanout reader (P_SCAN) vs the compositor's framebuffer writes (P_DST),
// both fronted by the cache. This tb wires the REAL combination none of the unit
// tests run together:
//   real openbor_video_reader SDRAM scan master  (NOT a stub)
//   + real sdram_fb_cache (jtframe_cache_mux)     (P_SCAN + P_DST both LIVE)
//   + real mt48lc16m16a2 Micron chip
//   + concurrent P_SCAN line-fetch AND P_DST compositor RMW.
//
// ── Compositor topology (mirrors Solarus.sv) ────────────────────────────────
//   blitter_top(comp_pipeline) -> vram_demux -> {DDR side -> ddr_blitter_arb ;
//                                                 SDRAM side -> sdram_fb_cache P_DST}
//   openbor_video_top.reader DDR master  -> ddr_blitter_arb rdr port
//   openbor_video_top.reader SDRAM master (P_SCAN) -> sdram_fb_cache scan_*
//   sdram_fb_cache -> jtframe_burst_sdram -> mt48lc16m16a2
//
// The legacy per-pixel renderer was retired; comp_pipeline is the sole renderer
// and issues MULTI-BEAT bursts. The single wire that makes that correct here is
// blitter_top.mem_burstcnt -> vram_demux.blt_burstcnt (bt_burstcnt): the demux's
// SDRAM read loop fetches blt_burstcnt beats per dest-band load. The old tb hard-
// coded blt_burstcnt=1 ("legacy FSM single-beat"), so a compositor burst read
// returned one beat and comp_pipeline hung waiting for the rest.
//
// ── Workload (validated compositor path) ────────────────────────────────────
// Each frame the compositor runs a full-screen opaque FILL into FB0 (which the
// demux routes to SDRAM) — a band-chunked RMW that LOAD-reads and FLUSH-writes
// the framebuffer over P_DST every frame — while the reader scans the displayed
// FB from SDRAM over P_SCAN. C_SRCSEL=0 (no SDRAM sprite source): comp_pipeline's
// SDRAM-SOURCE path (C_SRCSEL=1 / P_SRC) is still Phase-2 deferred (see the PCOMP
// ledger and tb_blitter_system_pipe), so the 3-client (P_SRC+P_DST+P_SCAN)
// variant of this test is deferred with it. This tb covers the P_DST-vs-P_SCAN
// contention — the first compositor test to run a REAL competing scan master.
//
// Pass/fail is PROGRESS-based (not pixel-exact): a healthy system keeps the reader
// completing scanlines (lines_done climbs) AND the compositor completing frames
// (done_seq advances). A true wedge stalls both; the watchdog fires.
//
// ── STATUS: NON-GATING — JC-T7 re-point landed; full re-gate is a follow-up ──
// JC-T7 re-pointed this tb from the retired sdram_src_arb + sdram_psx chain to the
// cache (sdram_fb_cache + mt48). It BUILDS and the cache serves P_DST (the
// compositor composites — dst_ok flows). It is kept NON-GATING for now: the full
// 480-line / 4-frame contention completion is impractically slow under the faithful
// mt48 model in iverilog, and the reader's scan-via-cache cadence under a competing
// P_DST RMW needs a dedicated perf/timing pass to complete in a CI-tractable budget
// (the cache wrapper itself is proven in tb_sdram_fb_cache, and the per-client
// conversions in tb_vram_demux / tb_scanout_sdram / tb_blitter_system_pipe). The
// re-point is required so the JC-T8 cleanup can delete sdram_src_arb/sdram_psx
// without breaking this tb. Re-gating (a tractable system FB proof on the cache,
// + the coh_busy client-gating refinement) is tracked as a JC follow-up. The
// 3-client P_SRC/C_SRCSEL variant stays Phase-2 deferred.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
`include "vram_defs.vh"

module tb_vram_contention;
  localparam [28:0] WBASE = 29'h07400000;     // DDR window base; mem index = addr-WBASE
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h10000;  // [#52] tracks SRC_QW heap base        // covers control block @ 0x200000

  // ---- clocks --------------------------------------------------------------
  // clk_sys: 100 MHz (DDR3 + SDRAM + blitter + arbiters). clk_vid: 53.69 MHz
  // (CLK_VIDEO). ce_pix: SIM runs it full-rate (every clk_vid, not 1-in-8).
  reg clk_sys = 0; always #5 clk_sys = ~clk_sys;   // 100 MHz (unchanged)
  // clk_sdram is the inverted clk_sys -> leads it by 5 ns; mt48lc16m16a2 is clocked
  // on it (same source-synchronous skew the old SDRAM_CLK altddio 180 deg used).
  reg clk_sdram = 1; always #5 clk_sdram = ~clk_sdram;
  reg clk_vid = 0; always #9.3125 clk_vid = ~clk_vid;
  reg reset = 1;

  // SIM: full-rate ce_pix shrinks the video frame ~8x. The reader's first sync is
  // gated by new_frame (one full 240-line frame away); at the HW ÷8 pixel rate
  // that's ~1.5M clk_sys cycles of dead time before any P_SCAN activity. Full-rate
  // pixels remove that without changing capture (line-buffer fill is on clk_sys).
  reg       ce_pix = 1'b0;
  always @(posedge clk_vid) ce_pix <= ~reset;

  // Behavioral DDR3 bus nets (declared early — referenced by u_video/vdemux below;
  // the model + ddr_blitter_arb that drive them are instantiated further down).
  wire [7:0] d_burst; wire [28:0] d_addr; wire d_rd; wire [63:0] d_din;
  wire [7:0] d_be;    wire d_we;
  wire       d_busy;  reg d_dready = 0; reg [63:0] d_dout = 0;
  wire [31:0] blt_dbg;   // #34 debug snapshot (blitter dbg -> reader -> VSYNC high word)
  wire [3:0]  vdemux_dbg; // #34 probe: {rd_on_sdram, demux_st}

  // ================= REAL SCANOUT READER (openbor_video_top) ================
  // DDR master (control word / joystick / audio) -> ddr_blitter_arb rdr port.
  wire  [7:0] nv_burst;  wire [28:0] nv_addr;  wire nv_rd;
  wire [63:0] nv_din;    wire  [7:0] nv_be;    wire nv_we;
  wire        rdr_busy_w, rdr_grant_w;
  // SDRAM scan master (P_SCAN) -> sdram_fb_cache scan_* (cache-ok protocol).
  wire [26:0] scan_addr; wire scan_rd;
  wire [63:0] scan_dout; wire scan_ok;
  wire        nv_vs_w;   // reader vsync (clk_vid) -> cache coherency vs (synced below)

  openbor_video_top u_video (
    .clk_sys        (clk_sys),
    .clk_vid        (clk_vid),
    .ce_pix         (ce_pix),
    .reset          (reset),
    // DDR3 master -> ddr_blitter_arb rdr port
    .ddr_busy       (rdr_busy_w),
    .ddr_burstcnt   (nv_burst),
    .ddr_addr       (nv_addr),
    .ddr_dout       (d_dout),
    .ddr_dout_ready (d_dready & rdr_grant_w),
    .ddr_rd         (nv_rd),
    .ddr_din        (nv_din),
    .ddr_be         (nv_be),
    .ddr_we         (nv_we),
    // SDRAM scan master -> sdram_fb_cache P_SCAN (cache-ok)
    .scan_addr      (scan_addr),
    .scan_rd        (scan_rd),
    .scan_dout      (scan_dout),
    .scan_ok        (scan_ok),
    // video out (vga_vs drives the cache coherency vs)
    .vga_r(), .vga_g(), .vga_b(), .vga_hs(), .vga_vs(nv_vs_w), .vga_de(),
    .enable         (1'b1),
    .active         (),
    .vsync_out      (),
    .dbg_blt        (blt_dbg),
    .dbg_addr       (32'd0),
    .h_offset       (3'd0),
    .v_offset       (3'd0),
    .joystick_0     (32'd0), .joystick_1(32'd0), .joystick_2(32'd0), .joystick_3(32'd0),
    .joystick_l_analog_0 (16'd0),
    .ioctl_download (1'b0), .ioctl_wr(1'b0), .ioctl_addr(27'd0), .ioctl_dout(8'd0),
    .ioctl_wait     (),
    .clk_audio      (clk_vid),
    .audio_l        (), .audio_r()
  );

  // ================= BLITTER -> VRAM DEMUX (mirror Solarus.sv) ===============
  wire [31:0] bt_addr; wire bt_rd, bt_wr; wire [63:0] bt_din; wire [7:0] bt_be;
  wire [7:0]  bt_burstcnt;   // comp_pipeline mem_burstcnt -> vram_demux SDRAM read loop
  wire        bt_idle;
  wire [63:0] blt_demux_dout; wire blt_demux_dready, blt_busy_w;
  // demux DDR side -> ddr_blitter_arb blt_*
  wire [28:0] bd_addr; wire bd_rd, bd_wr; wire [63:0] bd_din; wire [7:0] bd_be;
  wire        b_grant; wire blt_arb_busy;
  // blitter SDRAM source path -> src_arb P_SRC (idle this workload: C_SRCSEL=0,
  // and comp_pipeline's SDRAM-source path is Phase-2 deferred — kept wired so the
  // ports exist and STAGE writes still route, but no P_SRC read traffic is driven).
  // Task 5: P_SRC source reads now use cache-ok (p0_*). This regression exercises
  // FILL-only blits with no SDRAM source (C_SRCSEL=0), so p0_ok=0 is safe (the
  // blitter never asserts p0_rd during a FILL). Staging write outputs kept; inert.
  wire [26:0] bs_p0_addr; wire bs_p0_rd;
  wire        bs_we; wire [15:0] bs_din; wire [26:0] bs_waddr;
  wire        bs_we_burst; wire [63:0] bs_din64;

  // Coherency vs: reader vsync (clk_vid) double-flopped into clk_sys. Also drives the
  // blitter's per-frame work->scan snapshot (blitter_top.vs) [FB-in-BRAM double-buffer].
  reg [1:0] vs_sync = 2'b0;
  always @(posedge clk_sys) vs_sync <= {vs_sync[0], nv_vs_w};
  wire fb_vs = vs_sync[1];

  blitter_top blt (
    .clk(clk_sys), .rst(reset), .vs(fb_vs),
    .mem_addr(bt_addr), .mem_rd(bt_rd), .mem_wr(bt_wr), .mem_burstcnt(bt_burstcnt),
    .mem_din(bt_din), .mem_be(bt_be),
    .mem_dout(blt_demux_dout), .mem_dout_ready(blt_demux_dready), .mem_busy(blt_busy_w),
    // P_SRC cache-ok (Task 5): p0_ok=0 (FILL workload; no source reads issued).
    .p0_addr(bs_p0_addr), .p0_rd(bs_p0_rd), .p0_dout(64'd0), .p0_ok(1'b0),
    .src_sdram_we(bs_we), .src_sdram_din(bs_din), .src_sdram_waddr(bs_waddr),
    .src_sdram_we_burst(bs_we_burst), .src_sdram_din64(bs_din64), .src_sdram_ok(1'b1),
    .stage_barrier(), .stage_barrier_busy(1'b0),   // FILL-only: blitter never reaches the barrier
    .idle(bt_idle), .dbg(blt_dbg));

  // demux SDRAM side -> sdram_fb_cache P_DST (cache-ok)
  wire [26:0] dst_addr; wire dst_rd, dst_wr;
  wire [63:0] dst_din;  wire [7:0] dst_wdsn;
  wire [63:0] dst_dout; wire dst_ok;

  vram_demux vdemux (
    .clk(clk_sys), .reset(reset),
    .blt_addr(bt_addr), .blt_rd(bt_rd), .blt_wr(bt_wr), .blt_din(bt_din), .blt_be(bt_be),
    .blt_burstcnt(bt_burstcnt),   // compositor bursts: demux fetches N beats per band load
    .blt_dout(blt_demux_dout), .blt_dout_ready(blt_demux_dready), .blt_busy(blt_busy_w),
    .ddr_addr(bd_addr), .ddr_rd(bd_rd), .ddr_wr(bd_wr), .ddr_din(bd_din), .ddr_be(bd_be),
    .ddr_dout(d_dout), .ddr_dout_ready(d_dready & b_grant), .ddr_busy(blt_arb_busy),
    .sd_addr(dst_addr), .sd_rd(dst_rd), .sd_wr(dst_wr),
    .sd_din(dst_din), .sd_wdsn(dst_wdsn),
    .sd_dout(dst_dout), .sd_ok(dst_ok),
    .dbg(vdemux_dbg));

  // ================= DDR blitter arbiter (reader + blitter share DDR3) =======
  // blt_burstcnt stays 1: this FILL workload drives no blitter DDR traffic (the FB
  // is in SDRAM; FILL has no DDR source). DDR-source compositor bursts (COPY from a
  // DDR sprite) are a separate path, not exercised here.
  ddr_blitter_arb #(.ENABLE(1'b1)) arb_ddr (
    .clk(clk_sys), .reset(reset),
    .rdr_burstcnt(nv_burst), .rdr_addr(nv_addr), .rdr_rd(nv_rd), .rdr_din(nv_din),
    .rdr_be(nv_be), .rdr_we(nv_we), .rdr_busy(rdr_busy_w), .rdr_grant(rdr_grant_w),
    .blt_burstcnt(8'd1), .blt_addr(bd_addr), .blt_rd(bd_rd), .blt_din(bd_din), .blt_be(bd_be), .blt_we(bd_wr),
    .blt_busy(blt_arb_busy), .blt_grant(b_grant),
    .ddram_busy(d_busy), .ddram_dout_ready(d_dready),
    .ddram_burstcnt(d_burst), .ddram_addr(d_addr), .ddram_rd(d_rd),
    .ddram_din(d_din), .ddram_be(d_be), .ddram_we(d_we), .dbg());

  // ================= SDRAM framebuffer cache (jtframe_cache_mux) =============
  // JC-T7: replaces sdram_src_arb + sdram_psx. One sdram_fb_cache fronts the
  // jtframe burst controller with three cache-ok channels — ch0 P_DST (r/w) from
  // vram_demux, ch4 P_SCAN (ro) from the real reader, ch5 P_SRC (ro, idle: this
  // is a FILL-only workload, C_SRCSEL=0). Every client holds its request until
  // ok, so coherency flush/invalidate stalls are absorbed without coh_busy gating.
  // SDRAM chip pins.
  wire [15:0] SDQ; wire [12:0] SA; wire SDQML, SDQMH; wire [1:0] SBA;
  wire        SnCS, SnWE, SnRAS, SnCAS, SCKE, cache_sdram_clk;

  sdram_fb_cache fbcache (
    .clk(clk_sys), .clk_sdram(clk_sys), .rst(reset), .init(),
    // P_DST (ch0, r/w) <- vram_demux
    .dst_addr(dst_addr), .dst_rd(dst_rd), .dst_wr(dst_wr),
    .dst_din(dst_din), .dst_wdsn(dst_wdsn), .dst_dout(dst_dout), .dst_ok(dst_ok),
    // P_SCAN (ch4, ro) <- reader
    .scan_addr(scan_addr), .scan_rd(scan_rd), .scan_dout(scan_dout), .scan_ok(scan_ok),
    // P_SRC (ch5, ro) <- idle (FILL-only)
    .p0_addr(27'd0), .p0_rd(1'b0), .p0_dout(), .p0_ok(),
    .stage_addr(27'd0), .stage_wr(1'b0), .stage_din(64'd0), .stage_wdsn(8'hff), .stage_ok(),
    .stage_barrier(1'b0), .stage_busy(),   // FILL-only workload: no STAGE
    .dst_barrier(1'b0), .dst_busy(),       // no carry-forward in this bench
    .vs(fb_vs), .coh_busy(),
    .sdram_dq(SDQ), .sdram_a(SA), .sdram_dqml(SDQML), .sdram_dqmh(SDQMH),
    .sdram_ba(SBA), .sdram_nwe(SnWE), .sdram_ncas(SnCAS), .sdram_nras(SnRAS),
    .sdram_ncs(SnCS), .sdram_cke(SCKE), .sdram_clk(cache_sdram_clk));

  // Faithful Micron timing model — the chip the cache was validated against —
  // clocked on clk_sdram (leads clk_sys by 5 ns). FB (0x400000) fits in 32MB.
  mt48lc16m16a2 schip (
    .Dq(SDQ), .Addr(SA), .Ba(SBA), .Clk(clk_sdram), .Cke(SCKE),
    .Cs_n(SnCS), .Ras_n(SnRAS), .Cas_n(SnCAS), .We_n(SnWE), .Dqm({SDQMH, SDQML}),
    .downloading(1'b0), .VS(1'b0), .frame_cnt(32'd0));

  // ================= Behavioral DDR3 with backpressure (busy 2/3) ===========
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

  // ================= command-list builder ===================================
  task wmem(input [31:0] idx, input [63:0] val); mem[idx]=val; endtask

  // Program ONE frame of compositor work: a full-screen opaque FILL into FB0
  // (which vram_demux routes to SDRAM). comp_pipeline runs it as band-chunked RMW
  // — LOAD-reading and FLUSH-writing the framebuffer over P_DST in BURSTS — while
  // the reader scans the displayed FB over P_SCAN. C_SRCSEL=0: no SDRAM sprite
  // source (that 3-client / P_SRC path is Phase-2 deferred with comp_pipeline's
  // SDRAM-source support). target_buf=0 every frame so the reader scans the exact
  // rows the compositor is rewriting — maximal P_DST/P_SCAN overlap.
  // Gating: composite a reduced-height (full-width) fill so each frame's P_DST
  // band-RMW completes quickly. The contention coverage is P_DST writes overlapping
  // P_SCAN reads over the rewritten rows — preserved at FILL_H=48; only the number
  // of composited rows shrinks. Full 240-row composite via +define+VRAM_CONTENTION_FULL.
`ifdef VRAM_CONTENTION_FULL
  localparam integer FILL_H = 240;
`else
  localparam integer FILL_H = 48;
`endif
  integer submit_n = 0;
  task submit_fill_frame(input [15:0] color);
    begin
      wmem(32'h200002, 64'd0);          // target_buf = 0 (BUF0 -> SDRAM FB0)
      wmem(32'h200004, 64'd0);          // flags = 0 (no legacy CLEAR; compositor does the work)
      wmem(32'h200007, 64'd0);          // C_SRCSEL=0, throttle=0 (arb prioritizes P_SCAN)
      wmem(32'h200001, 64'd2);          // cmd_count = 2 (FILL + END)
      // cmd0 FILL: op=2, full screen 320x240 at (0,0), color in u32[7].
      // qw0 u32[0]=opcode|blend<<8|fmt<<16|flags<<24 ; u32[1]=src_off (unused for FILL)
      wmem(32'h200008, 64'h0000_0000_0000_0002);            // op=FILL(2)
      wmem(32'h200009, {16'(FILL_H), 16'd320, 32'd0});      // u32[3]=h(FILL_H)<<16|w(320); u32[2]=0
      wmem(32'h20000A, 64'd0);                              // u32[5]=dst_y(0)<<16|dst_x(0); u32[4]=0
      wmem(32'h20000B, {16'd0, color, 32'd0});              // u32[7]=color; u32[6]=0
      wmem(32'h20000C, 64'd1);          // cmd1 = END
      wmem(32'h20000D, 64'd0); wmem(32'h20000E, 64'd0); wmem(32'h20000F, 64'd0);
      submit_n = submit_n + 1;
      wmem(32'h200000, submit_n[63:0]); // bump submit -> compositor renders a frame
    end
  endtask

  wire [31:0] done_seq = mem[32'h200005][31:0];
  wire [31:0] vctrl    = mem[0][31:0];

  // ================= progress monitors ======================================
  // Reader scanline completions: count entries into ST_LINE_DONE (=6).
  localparam [4:0] ST_LINE_DONE = 5'd6;
  reg  [4:0] rstate_q = 5'd31;
  integer    lines_done = 0;
  always @(posedge clk_sys) begin
    if (reset) begin rstate_q <= 5'd31; lines_done <= 0; end
    else begin
      if (u_video.reader.state == ST_LINE_DONE && rstate_q != ST_LINE_DONE)
        lines_done <= lines_done + 1;
      rstate_q <= u_video.reader.state;
    end
  end

  // ================= heartbeat (periodic progress trace) ====================
  integer hb = 0;
  always @(posedge clk_sys) begin
    if (!reset) begin
      hb = hb + 1;
      if (hb % 500_000 == 0)
        $display("[hb %0t] lines=%0d done=%0d submit=%0d | rdr.st=%0d beat=%0d dl=%0d | blt.st=%0d pbusy=%0b | scan_rd=%0b scan_ok=%0b dst_rd=%0b dst_wr=%0b dst_ok=%0b vs=%0b",
                 $time, lines_done, done_seq, submit_n, u_video.reader.state,
                 u_video.reader.beat_count, u_video.reader.display_line,
                 blt.state, blt.pipe_busy, scan_rd, scan_ok,
                 dst_rd, dst_wr, dst_ok, fb_vs);
    end
  end

  // ================= wedge watchdog =========================================
  // Combined progress = scanout lines + completed compositor frames. If it stalls
  // for STALL_LIMIT clk_sys cycles, the system has WEDGED — the #34 reproduction.
  parameter integer STALL_LIMIT = 2_000_000;   // ~20 ms @ 100 MHz; >> one frame
  integer    prog_q = -1, stall = 0;
  integer    cur_prog;
  reg        wedged = 0;
  always @(posedge clk_sys) begin
    if (reset) begin prog_q <= -1; stall <= 0; end
    else begin
      // The scanout reader advances lines_done independently of the compositor, so
      // a slow-but-advancing frame is never falsely flagged; a TRUE system wedge
      // (the #34 repro) stalls scanout too, so both terms freeze and we trip.
      cur_prog = lines_done + done_seq;
      if (cur_prog != prog_q) begin prog_q <= cur_prog; stall <= 0; end
      else begin
        stall <= stall + 1;
        if (stall + 1 >= STALL_LIMIT && !wedged) begin
          wedged <= 1;
          $display("WEDGE: no progress for %0d cyc (lines_done=%0d done_seq=%0d submit=%0d)",
                   STALL_LIMIT, lines_done, done_seq, submit_n);
          $display("  reader.state=%0d beat_count=%0d display_line=%0d frame_ready=%0b synced=%0b vsync_count=%0d",
                   u_video.reader.state, u_video.reader.beat_count, u_video.reader.display_line,
                   u_video.reader.frame_ready_reg, u_video.reader.synced, u_video.reader.vsync_count);
          $display("  P_SCAN: scan_rd=%0b scan_ok=%0b scan_addr=%h | P_DST: dst_rd=%0b dst_wr=%0b dst_ok=%0b dst_addr=%h",
                   scan_rd, scan_ok, scan_addr, dst_rd, dst_wr, dst_ok, dst_addr);
          $display("  coherency: vs=%0b | blt.state=%0d pbusy=%0b | bt_rd=%0b bt_wr=%0b bt_burstcnt=%0d blt_busy=%0b",
                   fb_vs, blt.state, blt.pipe_busy, bt_rd, bt_wr, bt_burstcnt, blt_busy_w);
          $display("RESULT: WEDGE");
          $finish;
        end
      end
    end
  end

  // ================= stimulus ===============================================
  // Gating geometry: contention coverage = P_DST (compositor) and P_SCAN
  // (scanout) running CONCURRENTLY through the shared cache/SDRAM; a starve/wedge
  // shows in the first frame of overlap. The reduced targets keep both clients
  // contending while cutting the multi-frame scanout/composite wall time (~10x).
  // Full 4-frame/480-line soak: build with +define+VRAM_CONTENTION_FULL.
`ifdef VRAM_CONTENTION_FULL
  localparam integer TARGET_FRAMES = 4;    // compositor frames to complete
  localparam integer TARGET_LINES  = 480;  // reader scanlines to complete (>=2 frames)
`else
  localparam integer TARGET_FRAMES = 2;    // CI gating: enough P_DST/P_SCAN overlap
  localparam integer TARGET_LINES  = 64;   // CI gating: concurrent scanout progress
`endif
  integer settle, t;
  initial begin
    // clear DDR (avoids 'x' in the reader's audio-path polls) and command block
    for (i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    repeat (16) @(posedge clk_sys);
    reset = 1'b0;

    // let the reader sync (first ctrl read captures the stale counter, synced=1)
    settle = 0;
    while (!u_video.reader.synced) begin
      @(posedge clk_sys); settle = settle + 1;
      if (settle > 2_000_000) begin
        $display("RESULT: WEDGE (reader never synced - ctrl read stuck)"); $finish;
      end
    end
    $display("reader synced after %0d cyc", settle);

    // contention loop: keep the compositor rendering frames (P_DST) while the
    // reader scans (P_SCAN). Submit the next frame as soon as the prior completes.
    fork
      begin : blitter_proc
        for (t = 0; t < 64; t = t + 1) begin
          submit_fill_frame(16'hF800 ^ t[15:0]);   // vary the color per frame
          // wait for this frame to complete (done_seq catches up) or a generous cap
          settle = 0;
          while (done_seq !== submit_n[31:0] && settle < 4_000_000) begin
            @(posedge clk_sys); settle = settle + 1;
          end
        end
      end
      begin : judge_proc
        // success once BOTH the reader and compositor have made enough progress
        while (lines_done < TARGET_LINES || done_seq < TARGET_FRAMES)
          @(posedge clk_sys);
        $display("=== PROGRESS OK: lines_done=%0d done_seq=%0d vsync_count=%0d vctrl=%h ===",
                 lines_done, done_seq, u_video.reader.vsync_count, vctrl);
        $display("RESULT: PASS");
        $finish;
      end
    join
  end

  // hard backstop (the watchdog above should fire first on a real wedge)
  initial begin
    #2_000_000_000;
    $display("RESULT: WEDGE (sim backstop timeout: lines_done=%0d done_seq=%0d)",
             lines_done, done_seq);
    $finish;
  end

endmodule
`default_nettype wire
