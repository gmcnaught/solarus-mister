// tb_vram_contention.sv — FAITHFUL SDRAM contention reproduction (issue #34).
//
// The HW deadlock: on the timing-clean core (+0.046 ns), the SDRAM scanout reader
// (P_SCAN) HARD-WEDGES the instant the blitter composites FB writes to SDRAM
// (P_DST). Screen goes black; only a fabric reset clears it. ALL existing sims
// pass because none runs the REAL combination:
//   real openbor_video_reader SDRAM scan master  (NOT a stub)
//   + real sdram_src_arb                          (tb_blitter_system tied scan off)
//   + real sdram_psx
//   + concurrent P_SCAN line-fetch AND P_DST blitter writes.
//
// This tb wires that exact combination, mirroring Solarus.sv:
//   blitter_top -> vram_demux -> {DDR side -> ddr_blitter_arb ; SDRAM side -> P_DST}
//   openbor_video_top.reader DDR master -> ddr_blitter_arb rdr port
//   openbor_video_top.reader SDRAM master (P_SCAN) -> sdram_src_arb scan port
//   sdram_src_arb -> sdram_psx -> {sdram_chip_model | mt48lc16m16a2}
//
// Contention loop: the blitter composites a full-buffer CLEAR to FB0 in SDRAM
// (sustained P_DST traffic) AND writes the VCTRL frame counter; the reader sees
// the changing counter and scans the framebuffer line-by-line from SDRAM (P_SCAN)
// — both clients hammer the single sdram_psx every frame.
//
// Pass/fail is PROGRESS-based (not pixel-exact): a healthy system keeps the reader
// completing scanlines (beat_count reaches 80; ST_LINE_DONE recurs; frame_ready /
// vsync_count advance) AND the blitter completing frames (done_seq advances). The
// UNFIXED RTL must WEDGE here (watchdog fires on no-progress) — that is the
// reproduction. Re-run as a gating test once it passes post-fix.
//
// Build step 1 (validate wiring, zero-delay chip): default (sdram_chip_model).
// Build step 2 (reproduction, real timing):  -DUSE_MICRON  (mt48lc16m16a2).
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
`include "vram_defs.vh"

module tb_vram_contention;
  localparam [28:0] WBASE = 29'h07400000;     // DDR window base; mem index = addr-WBASE
  localparam        MEMQW = 32'h202000;        // covers control block @ 0x200000

  // ---- clocks --------------------------------------------------------------
  // clk_sys: 100 MHz (DDR3 + SDRAM + blitter + arbiters). clk_vid: 53.69 MHz
  // (CLK_VIDEO). ce_pix: 1-in-8 enable of clk_vid (one display pixel per 8).
  reg clk_sys = 0; always #5      clk_sys = ~clk_sys;
  reg clk_vid = 0; always #9.3125 clk_vid = ~clk_vid;
  reg reset = 1;

  reg [2:0] ce_div = 3'd0;
  reg       ce_pix = 1'b0;
  always @(posedge clk_vid) begin
    if (reset) begin ce_div <= 3'd0; ce_pix <= 1'b0; end
    else begin ce_div <= ce_div + 3'd1; ce_pix <= (ce_div == 3'd0); end
  end

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
  // SDRAM scan master (P_SCAN) -> sdram_src_arb scan port.
  wire [26:0] scan_addr; wire scan_rd; wire [7:0] scan_burst;
  wire        scan_busy; wire [63:0] scan_dout64; wire scan_dready;

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
    // SDRAM scan master -> sdram_src_arb scan port (the part tb_blitter_system tied off)
    .sdram_busy     (scan_busy),
    .sdram_addr     (scan_addr),
    .sdram_burst    (scan_burst),
    .sdram_rd       (scan_rd),
    .sdram_dout64   (scan_dout64),
    .sdram_dready   (scan_dready),
    // video out (unused)
    .vga_r(), .vga_g(), .vga_b(), .vga_hs(), .vga_vs(), .vga_de(),
    .enable         (1'b1),
    .active         (),
    .vsync_out      (),
    .dbg_blt        (blt_dbg),
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
  wire        bt_idle;
  wire [63:0] blt_demux_dout; wire blt_demux_dready, blt_busy_w;
  // demux DDR side -> ddr_blitter_arb blt_*
  wire [28:0] bd_addr; wire bd_rd, bd_wr; wire [63:0] bd_din; wire [7:0] bd_be;
  wire        b_grant; wire blt_arb_busy;
  // blitter SDRAM source path -> src_arb P_SRC
  wire [26:0] bs_addr; wire bs_rd; wire [63:0] bs_dout64; wire bs_dready; wire bs_busy;
  wire        bs_we; wire [15:0] bs_din; wire [26:0] bs_waddr;
  wire        bs_we_burst; wire [63:0] bs_din64;

  blitter_top blt (
    .clk(clk_sys), .rst(reset),
    .mem_addr(bt_addr), .mem_rd(bt_rd), .mem_wr(bt_wr), .mem_din(bt_din), .mem_be(bt_be),
    .mem_dout(blt_demux_dout), .mem_dout_ready(blt_demux_dready), .mem_busy(blt_busy_w),
    .src_sdram_addr(bs_addr), .src_sdram_rd(bs_rd), .src_sdram_dout64(bs_dout64),
    .src_sdram_dout_ready(bs_dready), .src_sdram_busy(bs_busy),
    .src_sdram_we(bs_we), .src_sdram_din(bs_din), .src_sdram_waddr(bs_waddr),
    .src_sdram_we_burst(bs_we_burst), .src_sdram_din64(bs_din64),
    .idle(bt_idle), .dbg(blt_dbg));

  // demux SDRAM side -> src_arb P_DST
  wire [26:0] dst_addr; wire dst_rd, dst_we, dst_we_burst;
  wire [15:0] dst_din; wire [63:0] dst_din64;
  wire        dst_busy; wire [63:0] dst_dout64; wire dst_dready;

  vram_demux vdemux (
    .clk(clk_sys), .reset(reset),
    .blt_addr(bt_addr), .blt_rd(bt_rd), .blt_wr(bt_wr), .blt_din(bt_din), .blt_be(bt_be),
    .blt_dout(blt_demux_dout), .blt_dout_ready(blt_demux_dready), .blt_busy(blt_busy_w),
    .ddr_addr(bd_addr), .ddr_rd(bd_rd), .ddr_wr(bd_wr), .ddr_din(bd_din), .ddr_be(bd_be),
    .ddr_dout(d_dout), .ddr_dout_ready(d_dready & b_grant), .ddr_busy(blt_arb_busy),
    .sd_addr(dst_addr), .sd_rd(dst_rd), .sd_din(dst_din), .sd_we(dst_we),
    .sd_din64(dst_din64), .sd_we_burst(dst_we_burst),
    .sd_dout64(dst_dout64), .sd_dready(dst_dready), .sd_busy(dst_busy),
    .dbg(vdemux_dbg));

  // ================= DDR blitter arbiter (reader + blitter share DDR3) =======
  ddr_blitter_arb #(.ENABLE(1'b1)) arb_ddr (
    .clk(clk_sys), .reset(reset),
    .rdr_burstcnt(nv_burst), .rdr_addr(nv_addr), .rdr_rd(nv_rd), .rdr_din(nv_din),
    .rdr_be(nv_be), .rdr_we(nv_we), .rdr_busy(rdr_busy_w), .rdr_grant(rdr_grant_w),
    .blt_addr(bd_addr), .blt_rd(bd_rd), .blt_din(bd_din), .blt_be(bd_be), .blt_we(bd_wr),
    .blt_busy(blt_arb_busy), .blt_grant(b_grant),
    .ddram_busy(d_busy), .ddram_dout_ready(d_dready),
    .ddram_burstcnt(d_burst), .ddram_addr(d_addr), .ddram_rd(d_rd),
    .ddram_din(d_din), .ddram_be(d_be), .ddram_we(d_we), .dbg());

  // ================= SDRAM source arbiter (3 clients) + controller ==========
  wire        sps_ready, sps_dready; wire [63:0] sps_dout64;
  wire [26:0] sc_addr; wire sc_rd; wire sc_we; wire [15:0] sc_din;
  wire        sc_we_burst; wire [63:0] sc_din64;
  wire        sc_busy = ~sps_ready;
  wire [63:0] p0_dout64; wire p0_dready;
  // SDRAM chip pins
  wire [15:0] SDQ; wire [12:0] SA; wire SDQML, SDQMH; wire [1:0] SBA;
  wire        SnCS, SnWE, SnRAS, SnCAS, SCLK, SCKE;

  sdram_src_arb src_arb (
    .clk(clk_sys), .reset(reset),
    // P_SCAN: the REAL reader scan master (live, not tied off)
    .scan_addr(scan_addr), .scan_rd(scan_rd), .scan_burst(scan_burst),
    .scan_busy(scan_busy), .scan_dout64(scan_dout64), .scan_dready(scan_dready),
    // P_SRC: blitter source reads + staging writes
    .p0_addr(bs_addr), .p0_rd(bs_rd), .p0_grant(), .p0_busy(bs_busy),
    .p0_we(bs_we), .p0_din(bs_din), .p0_waddr(bs_waddr),
    .p0_we_burst(bs_we_burst), .p0_din64(bs_din64),
    .p0_dready(p0_dready), .p0_dout64(p0_dout64),
    // P_DST: blitter destination read/write (from vram_demux SDRAM side)
    .dst_addr(dst_addr), .dst_rd(dst_rd), .dst_we(dst_we), .dst_din(dst_din),
    .dst_we_burst(dst_we_burst), .dst_din64(dst_din64),
    .dst_busy(dst_busy), .dst_dout64(dst_dout64), .dst_dready(dst_dready),
    // controller-facing
    .c_addr(sc_addr), .c_rd(sc_rd), .c_we(sc_we), .c_din(sc_din),
    .c_we_burst(sc_we_burst), .c_din64(sc_din64),
    .c_ready(sps_ready), .c_busy(sc_busy),
    .c_dready(sps_dready), .c_dout64(sps_dout64));
  assign bs_dout64 = p0_dout64;
  assign bs_dready = p0_dready;

  sdram_psx #(.BURST_BEATS(1)) sps (
    .init(reset), .clk(clk_sys),
    .SDRAM_DQ(SDQ), .SDRAM_A(SA), .SDRAM_DQML(SDQML), .SDRAM_DQMH(SDQMH),
    .SDRAM_BA(SBA), .SDRAM_nCS(SnCS), .SDRAM_nWE(SnWE), .SDRAM_nRAS(SnRAS),
    .SDRAM_nCAS(SnCAS), .SDRAM_CLK(SCLK), .SDRAM_CKE(SCKE),
    .wtbt(2'b11), .addr(sc_addr), .dout(),
    .dout64(sps_dout64), .dout_ready(sps_dready),
    .din(sc_din), .din64(sc_din64), .we(sc_we), .we_burst(sc_we_burst),
    .rd(sc_rd), .ready(sps_ready));

`ifdef USE_MICRON
  // Faithful Micron timing model (32MB/9-col; geometry is silicon-proven, we need
  // only true tRCD/tRP/tRC/CAS/refresh TIMING). FB(0x400000) fits in 32MB.
  mt48lc16m16a2 schip (
    .Dq(SDQ), .Addr(SA), .Ba(SBA), .Clk(SCLK), .Cke(SCKE),
    .Cs_n(SnCS), .Ras_n(SnRAS), .Cas_n(SnCAS), .We_n(SnWE), .Dqm({SDQMH, SDQML}),
    .downloading(1'b0), .VS(1'b0), .frame_cnt(32'd0));
`else
  // Zero-delay behavioral chip model (matches today's green sims).
  sdram_chip_model schip (
    .clk(clk_sys), .DQ(SDQ), .A(SA), .BA(SBA),
    .nCS(SnCS), .nRAS(SnRAS), .nCAS(SnCAS), .nWE(SnWE), .CKE(SCKE),
    .DQML(SDQML), .DQMH(SDQMH), .proto_errors());
`endif

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

  // Program ONE frame of the REAL engine's per-frame work: a full-screen
  // carry-forward COPY FB1 -> FB0, both in SDRAM. This drives ALL THREE arbiter
  // clients every frame:
  //   P_SRC  = blitter SOURCE-reads FB1 from SDRAM (src_off=0x440000, F_SRC_SDRAM,
  //            C_SRCSEL=1) — the bit the original CLEAR-only loop never exercised,
  //   P_DST  = blitter writes FB0 to SDRAM,
  //   P_SCAN = scanout reads the displayed FB (concurrent, from the reader).
  // The HW wedge (blitter done freezes after frame 1) only appears under this
  // 3-client contention; SCAN+P_DST alone (the CLEAR loop) passed but missed it.
  // No seed needed — progress-based test (reads return whatever's in SDRAM).
  integer submit_n = 0;
  task submit_carryforward_frame;
    begin
      wmem(32'h200002, 64'd0);          // target_buf = 0 (BUF0 -> SDRAM FB0)
      wmem(32'h200004, 64'd0);          // flags = 0 (no CLEAR; pure carry-forward COPY)
      wmem(32'h200007, 64'd1);          // C_SRCSEL=1, throttle=0
      wmem(32'h200001, 64'd3);          // cmd_count = 3 (STAGE + COPY + END)
      // cmd0 STAGE: op=4, copy 8 KiB DDR3->SDRAM at off 0x100000 -> P_SRC BURST-WRITES
      // (p0_we_burst). This is what SOLARUS_SDRAM_SRC=1 does every frame (texture
      // staging) and the one 3-client arbiter path the COPY-only loop never drove
      // against SCAN. (#34 HW: blitter wedged after frame 1 with staging ON.)
      wmem(32'h200008, {32'h0010_0000, 32'h0000_0004});     // op=STAGE(4), src/dst off=0x100000
      wmem(32'h200009, {16'd0, 16'd8192, 32'd0});           // h=0, w=8192 bytes
      wmem(32'h20000A, 64'd0);
      wmem(32'h20000B, 64'd0);
      // cmd1 BLEND_ALPHA BLIT: op=3, blend=2 (ALPHA), flags=F_SRC_SDRAM(0x10),
      // src_off=0x440000 (SDRAM FB1). A const-alpha blend does a dst READ-MODIFY-
      // WRITE: it SOURCE-reads FB1 (P_SRC) AND DST-reads FB0 (P_DST READ via
      // S_BLIT_RDDST/S_DST_RDISS -> S_RD_WAIT) then writes FB0 (P_DST write). The
      // SDRAM dst-RMW READ under SCAN is the path the opaque COPY never exercised
      // and is the #34 HW wedge suspect (probe showed S_RD_WAIT, full-screen).
      wmem(32'h20000C, {32'h0044_0000, {8'h10, 8'h02, 8'h00, 8'h03}});
      wmem(32'h20000D, {16'd240, 16'd320, 16'd0, 16'd640});  // h=240 w=320 stride=640
      wmem(32'h20000E, {16'd0, 16'd0, 16'd0, 16'd0});        // dst_y=0 dst_x=0
      wmem(32'h20000F, 64'h0000_0000_0080_0000);             // c_alpha = 0x80 (qw3[23:16])
      wmem(32'h200010, 64'd1);          // cmd2 = END
      wmem(32'h200011, 64'd0); wmem(32'h200012, 64'd0); wmem(32'h200013, 64'd0);
      submit_n = submit_n + 1;
      wmem(32'h200000, submit_n[63:0]); // bump submit -> blitter composites a frame
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
        $display("[hb %0t] lines=%0d done=%0d submit=%0d | rdr.st=%0d beat=%0d dl=%0d | blt.st=%0d dx=%0d dy=%0d | sps.st=%0d rdy=%0b | owner=%0d held=%0b scanb=%0b dstb=%0b srcb=%0b",
                 $time, lines_done, done_seq, submit_n, u_video.reader.state,
                 u_video.reader.beat_count, u_video.reader.display_line,
                 blt.state, blt.dx, blt.dy, sps.fsm.state, sps_ready,
                 src_arb.owner, src_arb.held_txn, scan_busy, dst_busy, bs_busy);
    end
  end

  // ================= wedge watchdog =========================================
  // Combined progress = lines_done + blitter done_seq. If it stalls for
  // STALL_LIMIT clk_sys cycles, the system has WEDGED — the reproduction.
  parameter integer STALL_LIMIT = 2_000_000;   // ~20 ms @ 100 MHz; >> one frame
  integer    prog_q = -1, stall = 0;
  integer    cur_prog;
  reg        wedged = 0;
  always @(posedge clk_sys) begin
    if (reset) begin prog_q <= -1; stall <= 0; end
    else begin
      // include blitter PIXEL progress (dy*320+dx) so a slow-but-advancing COPY is
      // NOT flagged as a wedge — only a truly frozen pipeline trips the watchdog.
      cur_prog = lines_done + done_seq + (blt.dy*320 + blt.dx);
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
          $display("  src_arb.owner=%0d held_txn=%0b | scan_busy=%0b dst_busy=%0b sc_busy=%0b sps_ready=%0b",
                   src_arb.owner, src_arb.held_txn, scan_busy, dst_busy, sc_busy, sps_ready);
          $display("  scan_rd=%0b scan_addr=%h | dst_rd=%0b dst_we=%0b dst_we_burst=%0b",
                   scan_rd, scan_addr, dst_rd, dst_we, dst_we_burst);
          $display("  sps.state=%0d command=%0b refresh_count=%0d reads_issued=%0d beat_idx=%0d save_we=%0b save_burst=%0b new_rd=%0b new_we=%0b new_burst=%0b",
                   sps.fsm.state, sps.command, sps.refresh_count, sps.reads_issued, sps.beat_idx,
                   sps.fsm.save_we, sps.save_burst, sps.fsm.new_rd, sps.fsm.new_we, sps.fsm.new_burst);
          $display("  blt.state=%0d | bs_rd=%0b bs_we_burst=%0b bs_busy=%0b p0_grant?=%0b | c_rd=%0b c_we=%0b c_we_burst=%0b c_addr=%h",
                   blt.state, bs_rd, bs_we_burst, bs_busy, src_arb.p0_grant,
                   src_arb.c_rd, src_arb.c_we, src_arb.c_we_burst, src_arb.c_addr);
          $display("RESULT: WEDGE");
          $finish;
        end
      end
    end
  end

  // ================= stimulus ===============================================
  localparam integer TARGET_FRAMES = 4;    // blitter frames to complete
  localparam integer TARGET_LINES  = 480;  // reader scanlines to complete (>=2 frames)
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

    // contention loop: keep the blitter compositing frames (P_DST) while the
    // reader scans (P_SCAN). Submit the next frame as soon as the prior completes.
    fork
      begin : blitter_proc
        for (t = 0; t < 64; t = t + 1) begin
          submit_carryforward_frame;
          // wait for this frame to complete (done_seq catches up) or a generous cap
          settle = 0;
          while (done_seq !== submit_n[31:0] && settle < 4_000_000) begin
            @(posedge clk_sys); settle = settle + 1;
          end
        end
      end
      begin : judge_proc
        // success once BOTH the reader and blitter have made enough progress
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
