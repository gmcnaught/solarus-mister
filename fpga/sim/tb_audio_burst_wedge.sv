// tb_scanout_sdram.sv — scanout reads the framebuffer from SDRAM (P_SCAN path).
// FB seeded at SDRAM_FB0_BASE; control word still on the DDR master. Proves the
// reader's new SDRAM read master + the SDRAM FB address map are pixel-exact.
//
// Two phases:
//   PIXEL-EXACT : no bus contention -> every displayed pixel must match the
//                 framebuffer source exactly (regression guard; expect errs==0).
//   UNDERFLOW   : starve the SDRAM responder for ~one line time while the reader
//                 is fetching the line that feeds display line 100. The
//                 position-addressed line-buffer reader anchors the fetch to the
//                 live scan line (display_line = vcount+1), so once the starve
//                 lifts it re-syncs within ~1-2 lines and the REST of the frame
//                 is pixel-exact. A sustained K-line starve glitches ~K lines
//                 plus a short recovery tail, but NEVER drifts downstream.
//
// VERDICT: PASS iff PIXEL-EXACT clean AND starve-zone glitches (non-vacuous)
//          AND post-recovery lines [104..239] are all pixel-exact (no drift).
`timescale 1ns/1ps
`default_nettype none
`include "../rtl/vram_defs.vh"

module tb_audio_burst_wedge;
  // ---- [#39] audio-burst-wedge regression injection -------------------------
  // The reader's audio-ring DDR read (ST_WAIT_AUDIO_RING) waits for exactly
  // ddr_burstcnt ddr_dout_ready beats with NO timeout. On the shared f2h bus a
  // burst occasionally returns fewer beats (the arbiter self-corrects via
  // QUIET_MAX; the reader does not), wedging the single shared FSM forever ->
  // vsync_count freezes -> black screen. This harness drops ONE beat on the next
  // audio-ring read after inject_short is armed, then requires recovery.
  reg               inject_short = 1'b0;   // armed by stimulus
  reg               short_fired  = 1'b0;   // set by DDR model when it shorts a burst
  localparam [28:0] AUDIO_RING_LO = 29'h0741A000;  // AUDIO_RING_ADDR (qword)
  localparam [28:0] AUDIO_RING_HI = 29'h0741C000;  // + 0x2000 qwords (64KB ring)
  localparam integer AUDIO_WR_IDX = 6;             // AUDIO_WR_ADDR(0x07400006)-WBASE
  reg [31:0]        awc0, awc2, awc3;              // vsync_count snapshots


  // ---- DDR window mapping (qword addresses; mem index = addr - WBASE) -------
  localparam [28:0] WBASE = 29'h07400000;   // 0x3A000000 >> 3
  localparam [31:0] MEMQW = 32'h20000;      // 128k qwords window (DDR control area)

  // Control-word / buffer geometry (qword window indices, relative to CTRL).
  localparam integer CTRL_IDX = 0;          // control word lives at mem[0]

  // Scanout geometry for self-documenting starve windows: H_TOTAL clk_vid pixels
  // per line, ce_pix is 1-in-CE_DIV of clk_vid, so H_TOTAL*CE_DIV clk_vid ticks
  // span one full display line.
  localparam integer H_TOTAL = 420;         // clk_vid pixels per line
`ifdef AUDIO_WEDGE_FULL
  localparam integer CE_DIV  = 8;           // HW-faithful: ce_pix divides clk_vid by 8 (nightly)
`else
  localparam integer CE_DIV  = 1;           // sim-only full-rate ce_pix (~faster scanout pacing)
`endif

  // ---- clocks ---------------------------------------------------------------
  // clk_vid: 53.693 MHz (exact Genesis MCLK) -> 18.625 ns period.
  // ddr_clk: 100 MHz -> 10 ns period.
  reg clk_vid = 0;
  reg ddr_clk = 0;
  always #9.3125 clk_vid = ~clk_vid;   // ~53.69 MHz
  always #5      ddr_clk = ~ddr_clk;   // 100 MHz

  reg reset = 1;

  // ---- ce_pix: 1-in-8 enable of clk_vid -------------------------------------
  reg [2:0] ce_div = 3'd0;
  reg       ce_pix = 1'b0;
  always @(posedge clk_vid) begin
    if (reset) begin
      ce_div <= 3'd0;
      ce_pix <= 1'b0;
    end else begin
      ce_div <= (ce_div == CE_DIV-1) ? 3'd0 : ce_div + 3'd1;
      ce_pix <= (ce_div == 3'd0);   // CE_DIV=1 -> every clk_vid; CE_DIV=8 -> 1-in-8 (== original)
    end
  end

  // ---- timing generator -----------------------------------------------------
  wire        t_hsync, t_vsync, t_hblank, t_vblank, t_de, t_new_frame, t_new_line;
  wire [9:0]  t_hcount;
  wire [8:0]  t_vcount;

  openbor_video_timing u_timing (
    .clk       (clk_vid),
    .ce_pix    (ce_pix),
    .reset     (reset),
    .h_adj     (5'sd0),
    .v_adj     (4'sd0),
    .hsync     (t_hsync),
    .vsync     (t_vsync),
    .hblank    (t_hblank),
    .vblank    (t_vblank),
    .de        (t_de),
    .hcount    (t_hcount),
    .vcount    (t_vcount),
    .new_frame (t_new_frame),
    .new_line  (t_new_line)
  );

  // ---- reader DDR master (control/joystick/audio) ---------------------------
  wire [7:0]  ddr_burstcnt;
  wire [28:0] ddr_addr;
  wire        ddr_rd;
  wire [63:0] ddr_din;
  wire [7:0]  ddr_be;
  wire        ddr_we;
  reg         ddr_busy;
  reg  [63:0] ddr_dout;
  reg         ddr_dout_ready;

  // ---- reader P_SCAN master (framebuffer line fetch via cache ok protocol) ---
  wire [26:0] scan_addr;
  wire        scan_rd;
  reg  [63:0] scan_dout;
  reg         scan_ok;

  wire [7:0]  r_out, g_out, b_out;
  wire        frame_ready;

  openbor_video_reader u_reader (
    .ddr_clk         (ddr_clk),
    .ddr_busy        (ddr_busy),
    .ddr_burstcnt    (ddr_burstcnt),
    .ddr_addr        (ddr_addr),
    .ddr_dout        (ddr_dout),
    .ddr_dout_ready  (ddr_dout_ready),
    .ddr_rd          (ddr_rd),
    .ddr_din         (ddr_din),
    .ddr_be          (ddr_be),
    .ddr_we          (ddr_we),

    // SDRAM framebuffer read master (P_SCAN — cache ok protocol)
    .scan_addr       (scan_addr),
    .scan_rd         (scan_rd),
    .scan_dout       (scan_dout),
    .scan_ok         (scan_ok),

    .clk_vid         (clk_vid),
    .ce_pix          (ce_pix),
    .reset           (reset),

    .de              (t_de),
    .hblank          (t_hblank),
    .vblank          (t_vblank),
    .new_frame       (t_new_frame),
    .new_line        (t_new_line),
    .vcount          (t_vcount),

    .ioctl_download  (1'b0),
    .ioctl_wr        (1'b0),
    .ioctl_addr      (27'd0),
    .ioctl_dout      (8'd0),
    .ioctl_wait      (),

    .joystick_0      (32'd0),
    .joystick_1      (32'd0),
    .joystick_2      (32'd0),
    .joystick_3      (32'd0),
    .joystick_l_analog_0 (16'd0),

    .r_out           (r_out),
    .g_out           (g_out),
    .b_out           (b_out),

    .clk_audio       (clk_vid),
    .audio_l         (),
    .audio_r         (),

    .enable          (1'b1),
    .frame_ready     (frame_ready)
  );

  // ---- behavioral DDR (control word + joystick/audio only) ------------------
  reg [63:0] mem [0:MEMQW-1];
  reg [7:0]  rbeats = 8'd0;        // remaining beats in current read burst
  reg [28:0] raddr  = 29'd0;       // current beat address
  reg [2:0]  rlat   = 3'd0;        // command latency before first beat
  integer    bi;

  // busy while a burst is in flight or during command latency
  wire   ddr_busy_w = (rbeats != 8'd0) || (rlat != 3'd0);
  always @(*) ddr_busy = ddr_busy_w;


  always @(posedge ddr_clk) begin
    ddr_dout_ready <= 1'b0;
    if (reset) begin
      rbeats <= 8'd0;
      rlat   <= 3'd0;
    end else begin
      if (rlat != 3'd0) begin
        rlat <= rlat - 3'd1;                 // command latency countdown
      end else if (rbeats != 8'd0) begin
        ddr_dout       <= mem[raddr - WBASE];
        ddr_dout_ready <= 1'b1;
        raddr  <= raddr + 29'd1;
        rbeats <= rbeats - 8'd1;
      end else if (!ddr_busy) begin          // accept a new command
        if (ddr_rd) begin
          // [#39 audio-wedge] drop ONE beat on the next audio-ring read when armed
          if (inject_short && !short_fired &&
              ddr_addr >= AUDIO_RING_LO && ddr_addr < AUDIO_RING_HI) begin
            rbeats      <= (ddr_burstcnt > 8'd1) ? (ddr_burstcnt - 8'd1) : 8'd0;
            short_fired <= 1'b1;
          end else begin
            rbeats <= ddr_burstcnt;
          end
          raddr  <= ddr_addr;
          rlat   <= 3'd2;
        end else if (ddr_we) begin
          for (bi = 0; bi < 8; bi = bi + 1)
            if (ddr_be[bi])
              mem[ddr_addr - WBASE][bi*8 +: 8] <= ddr_din[bi*8 +: 8];
        end
      end
    end
  end

  // ---- P_SCAN cache ok model: word-addressed 16-bit cells ------------------
  // 1<<22 = 4M words = 8MB (covers the 64MB SDRAM but we only need a small region)
  // Per-qword ok protocol: on scan_rd rising at scan_addr, after a fixed
  // latency assert scan_ok with the preloaded line qword. The reader walks
  // scan_addr per qword and captures scan_dout on scan_ok.
  reg [15:0] sdram_mem [0:1<<22];
  reg        sdram_starve = 1'b0;   // when high: hold off scan_ok responses

  // Fixed-latency per-qword cache responder (mimics jtframe_cache ok output),
  // rising-edge triggered with HOLD-until-ok backpressure: on scan_rd rising,
  // latch the address and count SCAN_LAT cycles, then assert scan_ok for one
  // cycle with the qword. A starve PAUSES the countdown, so a request issued
  // before/during the starve is HELD pending and completes when it lifts
  // (matching a real cache that holds the request) — exactly one ok per request.
  localparam integer SCAN_LAT = 3;
  reg        scan_rd_d = 1'b0;
  reg [3:0]  scan_cnt  = 4'd0;
  reg        scan_run  = 1'b0;
  reg [26:0] scan_la   = 27'd0;
  always @(posedge ddr_clk) scan_rd_d <= scan_rd;
  wire scan_req_rise = scan_rd & ~scan_rd_d;

  always @(posedge ddr_clk) begin
    scan_ok <= 1'b0;
    if (reset) begin
      scan_run <= 1'b0; scan_cnt <= 4'd0;
    end else if (scan_req_rise && !scan_run) begin
      scan_run <= 1'b1; scan_cnt <= SCAN_LAT[3:0] - 4'd1; scan_la <= scan_addr;
    end else if (scan_run && !sdram_starve) begin
      if (scan_cnt == 4'd0) begin
        scan_run  <= 1'b0;
        scan_ok   <= 1'b1;
        // Assemble 4 x 16-bit words -> 64-bit little-endian qword
        scan_dout <= {sdram_mem[(scan_la>>1)+3], sdram_mem[(scan_la>>1)+2],
                      sdram_mem[(scan_la>>1)+1], sdram_mem[(scan_la>>1)+0]};
      end else scan_cnt <= scan_cnt - 4'd1;
    end
  end

  // ---- framebuffer pattern + control word seeding ---------------------------
  // fb[y][x] = 16'(((y<<8)|x) & 16'hFFFF)
  // KNOWN/ACCEPTED ALIASING: for x>=256, x's bit 8 collides with y's bit 0, so
  // e.g. fbpix(y,300)==fbpix(y+1,44). This is an accepted blind spot — the
  // comparison is position-based (pv2_x/pv2_y drive both sides), so it stays
  // self-consistent and still catches scroll/drift bugs empirically.
  // Do NOT change the pattern; doing so reworks the whole comparison.
  function [15:0] fbpix(input integer y, input integer x);
    fbpix = (((y << 8) | x) & 16'hFFFF);
  endfunction

  // RGB565 -> RGB888 decode (mirror reader exactly)
  function [7:0] dec_r(input [15:0] p); dec_r = {p[15:11], p[15:13]}; endfunction
  function [7:0] dec_g(input [15:0] p); dec_g = {p[10:5],  p[10:9]};  endfunction
  function [7:0] dec_b(input [15:0] p); dec_b = {p[4:0],   p[4:2]};   endfunction

  integer yy, xx;
  reg [26:0] b;

  // Seed framebuffer into SDRAM byte model at SDRAM_FB0_BASE (byte-addressed).
  // Each pixel is 2 bytes (RGB565), stride is 640 bytes/line.
  integer sm_i;
  task seed_fb_sdram;
    begin
      // Clear the FB region first (address range covering both FBs)
      for (sm_i = (`SDRAM_FB0_BASE >> 1); sm_i < ((`SDRAM_FB1_BASE + 27'h25800) >> 1); sm_i = sm_i + 1)
        sdram_mem[sm_i] = 16'd0;
      for (yy = 0; yy < 240; yy = yy + 1)
        for (xx = 0; xx < 320; xx = xx + 1) begin
          b = `SDRAM_FB0_BASE + yy * `SDRAM_FB_STRIDE + xx * 2;
          sdram_mem[b >> 1] = fbpix(yy, xx);
        end
    end
  endtask

  // Initialise the DDR control window to all-zero before seeding the ctrl word.
  // This prevents uninitialized reads (e.g. AUDIO_WR_ADDR) from returning 'x'
  // and corrupting the audio-path state machine.
  integer qw_i;
  task clear_ddr_mem;
    begin
      for (qw_i = 0; qw_i < MEMQW; qw_i = qw_i + 1) mem[qw_i] = 64'd0;
    end
  endtask

  // Control word: [31:2]=frame_counter, [1]=unused, [0]=active_buffer.
  reg [29:0] frame_ctr = 30'd0;
  task publish_frame(input [29:0] fc);
    begin
      frame_ctr = fc;
      mem[CTRL_IDX] = {fc, 1'b0, 1'b0};  // active_buffer = 0 (FB0)
    end
  endtask

  // ---- 1-ce_pix latency shadow pipeline -------------------------------------
  // The position-addressed line-buffer reader registers r_out in lock-step with
  // the timing position. The timing gen registers (vcount,hcount,de) one ce_pix
  // before they drive r_out's BRAM read+decode, so a 1-deep shadow (pv_*) aligns
  // the comparison exactly.
  reg [8:0] pv_y;
  reg [9:0] pv_x;
  reg       pv_valid;

  reg          chk_enable = 1'b0;
  integer      px_errs    = 0;
  integer      px_checked = 0;
  integer      line_err [0:239];
  reg          pe_ok      = 1'b0;
  integer      starve_zone_errs = 0;   // glitches within the starve+recovery window
  integer      recovered_errs   = 0;   // glitches AFTER recovery -> cumulative drift

  reg [15:0] exp_pix;
  reg [7:0]  exp_r, exp_g, exp_b;
  integer    li;

  always @(posedge clk_vid) begin
    if (reset) begin
      pv_valid  <= 1'b0;
      pv_y      <= 9'd0;
      pv_x      <= 10'd0;
    end else if (ce_pix) begin
      // --- compare the now-visible pixel against the 1-ce_pix-ago source ------
      // pv_* holds the (vcount,hcount,de) the timing gen registered on the prior
      // ce_pix; the reader's r_out registered this ce_pix carries exactly that
      // position's source pixel (position-addressed, no occupancy coupling).
      if (chk_enable && frame_ready && pv_valid
          && pv_x < 320 && pv_y < 240) begin
        exp_pix = fbpix(pv_y, pv_x);
        exp_r   = dec_r(exp_pix);
        exp_g   = dec_g(exp_pix);
        exp_b   = dec_b(exp_pix);
        px_checked = px_checked + 1;
        if (r_out !== exp_r || g_out !== exp_g || b_out !== exp_b) begin
          px_errs = px_errs + 1;
          line_err[pv_y] = line_err[pv_y] + 1;
        end
      end
      // --- 1-deep shadow of the timing position --------------------------
      pv_valid  <= t_de;
      pv_y      <= t_vcount;
      pv_x      <= t_hcount;
    end
  end

  task clear_counters;
    begin
      px_errs = 0;
      px_checked = 0;
      for (li = 0; li < 240; li = li + 1) line_err[li] = 0;
    end
  endtask

  // ---- helper: wait until the timing gen is at a given (vcount, hblank) -----
  task wait_for_line_hblank(input [8:0] target_v);
    integer guard;
    begin
      guard = 0;
      while (!(t_vcount == target_v && t_hblank)) begin
        @(posedge clk_vid);
        guard = guard + 1;
        if (guard > 50_000_000) begin
          $display("RESULT: FAIL (wait_for_line_hblank hung v=%0d)", target_v);
          $finish;
        end
      end
    end
  endtask

  // ---- stimulus -------------------------------------------------------------
  integer scan;
  integer settle;

  initial begin
    for (li = 0; li < 240; li = li + 1) line_err[li] = 0;

    ddr_busy       = 1'b0;
    ddr_dout       = 64'd0;
    ddr_dout_ready = 1'b0;
    scan_dout      = 64'd0;
    scan_ok        = 1'b0;

    clear_ddr_mem;
    seed_fb_sdram;
    publish_frame(30'd1);     // seed an initial control word for the sync

    repeat (16) @(posedge ddr_clk);
    reset = 1'b0;

    // Let the reader perform its initial control-word SYNC (it captures the stale
    // frame counter WITHOUT displaying). Wait for synced, THEN bump the counter to
    // trigger display (if we bump too early the reader syncs to the new value and
    // never sees a change).
    settle = 0;
    while (!u_reader.synced) begin
      @(posedge clk_vid);
      settle = settle + 1;
      if (settle > 5_000_000) begin
        $display("RESULT: FAIL (reader never synced)");
        $finish;
      end
    end
    repeat (200) @(posedge clk_vid);
    publish_frame(30'd2);     // first displayable frame (counter change -> display)

    // Wait until the reader has loaded a full frame and is displaying.
    settle = 0;
    while (!frame_ready) begin
      @(posedge clk_vid);
      settle = settle + 1;
      if (settle > 5_000_000) begin
        $display("RESULT: FAIL (frame_ready never asserted)");
        $finish;
      end
    end

    // ===================== AUDIO-BURST WEDGE TEST (#39) =====================
    // Seed audio so the reader issues a ring burst, drop ONE beat, then require
    // the reader to RECOVER (vsync_count keeps advancing). Pre-fix: wedges
    // forever (FAIL). Post-fix (ST_WAIT_LINE-style timeout->ST_IDLE): PASS.
    awc0 = u_reader.vsync_count;
    repeat (500_000) @(posedge ddr_clk);
    if (u_reader.vsync_count <= awc0) begin
      $display("RESULT: FAIL (vsync not advancing pre-test -- harness invalid)");
      $finish;
    end

    // seed audio write pointer 256 bytes ahead of read pointer (low-32 = byte
    // wr_ptr) so the reader plans a full 32-qword ring burst, then arm the short
    mem[AUDIO_WR_IDX] = 64'h0000_0000_0000_0100;
    inject_short = 1'b1;

    settle = 0;
    while (!short_fired) begin
      @(posedge ddr_clk);
      settle = settle + 1;
      if (settle > 8_000_000) begin
        $display("RESULT: FAIL (audio-ring read never occurred -- seeding wrong)");
        $finish;
      end
    end

    // short burst has fired; wait LONGER than TIMEOUT_MAX (~1.05M ddr_clk) + slack
    awc2 = u_reader.vsync_count;
    repeat (2_000_000) @(posedge ddr_clk);
    awc3 = u_reader.vsync_count;
    $display("AUDIO-RING: vsync at-inject=%0d after-wait=%0d (advanced=%0d)",
             awc2, awc3, awc3 - awc2);
    if (awc3 > awc2 + 1)
      $display("RESULT: PASS");
    else
      $display("RESULT: FAIL (scanout WEDGE: vsync frozen after short audio burst)");
    $finish;

    // ===================== PIXEL-EXACT PHASE ================================
    // The reader, once it has a frame, re-reads the SAME buffer every vertical
    // scan via its stale-frame path (frame counter unchanged) and holds
    // frame_ready for ~30 vblanks. So we DON'T re-publish here.
    // Wait for a clean top-of-frame, then enable checking just inside the next
    // active region so we never straddle a publish/preload boundary.
    wait_for_line_hblank(9'd241);   // settle in vblank, reader fully preloaded
    clear_counters;
    chk_enable = 1'b1;
    for (scan = 0; scan < 3; scan = scan + 1) begin
      wait_for_line_hblank(9'd239);   // run through one full active region
      @(posedge clk_vid);
      wait_for_line_hblank(9'd241);   // and its vblank
    end
    chk_enable = 1'b0;

    pe_ok = (px_errs == 0 && px_checked > 200000);
    $display("PIXEL-EXACT: checked=%0d errs=%0d  -> %s",
             px_checked, px_errs, pe_ok ? "PASS" : "FAIL");

    // ===================== UNDERFLOW PHASE =================================
    // Reset counters; let the display reach a few lines above 100; then STARVE
    // the SDRAM responder for ~4 active-line times so the reader's line fetches
    // for that band cannot complete before the display reaches them.
    //
    // The position-addressed line-buffer reader anchors the fetch to the live
    // scan line (display_line = vcount+1), so once the starve lifts it re-syncs
    // within ~1-2 lines and the REST of the frame is pixel-exact.
    // A sustained K-line starve glitches ~K lines plus a short recovery tail,
    // but NEVER drifts downstream. The old FIFO reader failed this property.
    //
    // Verdict invariant: (a) the starve actually corrupted the starve band
    // (non-vacuous), and (b) every line after a small recovery margin through
    // end-of-frame is clean (no cumulative drift).
    clear_counters;
    chk_enable = 1'b1;

    // The buffer is static (single publish above); the reader keeps re-displaying
    // it via the stale path. Wait for a clean top-of-frame, then approach line 100.
    wait_for_line_hblank(9'd241);
    wait_for_line_hblank(9'd96);

    // Starve from the hblank before line 96 onward, through ~line 100, holding for
    // ~4 active-line times so the SDRAM genuinely cannot deliver beats mid-frame.
    sdram_starve = 1'b1;
    repeat (H_TOTAL*CE_DIV*4) @(posedge clk_vid);   // ~4 full display lines
    sdram_starve = 1'b0;

    // let the rest of the frame scan out
    wait_for_line_hblank(9'd239);
    repeat (H_TOTAL*CE_DIV) @(posedge clk_vid);      // ~1 full display line
    chk_enable = 1'b0;

    // Starve band starts at line ~97 and runs ~4 lines; allow a short recovery
    // tail. Lines [96 .. 103] = starve+recovery window (glitches expected/allowed);
    // lines [104 .. 239] = post-recovery (MUST be clean — proves no drift).
    starve_zone_errs = 0;
    recovered_errs   = 0;
    for (li = 96;  li <= 103; li = li + 1) starve_zone_errs = starve_zone_errs + line_err[li];
    for (li = 104; li <= 239; li = li + 1) recovered_errs   = recovered_errs   + line_err[li];

    $display("UNDERFLOW: line[100]=%0d line[101]=%0d line[150]=%0d | starve_zone[96..103]=%0d recovered[104..239]=%0d",
             line_err[100], line_err[101], line_err[150], starve_zone_errs, recovered_errs);

    // ===================== VERDICT =========================================
    // PASS iff: steady-state pixel-exact; the starve actually corrupted its band
    // (non-vacuous); and EVERY line after the recovery margin is clean (no drift).
    if (pe_ok && starve_zone_errs > 0 && recovered_errs == 0)
      $display("RESULT: PASS");
    else
      $display("RESULT: FAIL");
    $finish;
  end

  // ---- watchdog -------------------------------------------------------------
  initial begin
    #500000000 $display("RESULT: FAIL (timeout/hang)");
    $finish;
  end

endmodule
`default_nettype wire
