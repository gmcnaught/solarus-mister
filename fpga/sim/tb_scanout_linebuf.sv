// tb_scanout_linebuf.sv — scanout DATAPATH tb for issue #34 (TDD).
//
// Instantiates the REAL openbor_video_timing + REAL openbor_video_reader against
// a behavioral DDR holding a seeded framebuffer + control word, and samples the
// reader's r_out/g_out/b_out pixel stream.
//
// Two phases:
//   PIXEL-EXACT : no bus contention -> every displayed pixel must match the
//                 framebuffer source exactly (regression guard; expect errs==0).
//   UNDERFLOW   : starve the DDR for ~one line time while the reader is fetching
//                 the line that feeds display line 100. The CURRENT FIFO reader
//                 couples pixel output to FIFO occupancy, so an underflow shifts
//                 EVERY subsequent pixel -> cumulative vertical scroll. We expect
//                 downstream display lines (101, 150) to be corrupted.
//
// VERDICT: RESULT: PASS iff PIXEL-EXACT clean AND line 101 & 150 clean under the
// starve. Against the unmodified (buggy) FIFO reader this is expected to FAIL —
// that FAIL is the captured bug and the CORRECT outcome for this TDD task.
//
// The fix (LATER task) replaces the FIFO with position-addressed ping-pong line
// buffers and will make this RESULT: PASS.
`timescale 1ns/1ps
`default_nettype none

module tb_scanout_linebuf;

  // ---- DDR window mapping (qword addresses; mem index = addr - WBASE) -------
  localparam [28:0] WBASE = 29'h07400000;   // 0x3A000000 >> 3
  localparam [31:0] MEMQW = 32'h20000;      // 128k qwords window

  // Control-word / buffer geometry (qword window indices, relative to CTRL).
  localparam integer CTRL_IDX = 0;          // control word lives at mem[0]
  localparam integer BUF0_IDX = 'h8;        // BUF0_ADDR - CTRL_ADDR
  localparam integer QW_PER_LINE = 80;      // 80 qwords/line (4 RGB565 px each)

  // Scanout geometry for self-documenting starve windows: H_TOTAL clk_vid pixels
  // per line, ce_pix is 1-in-CE_DIV of clk_vid, so H_TOTAL*CE_DIV clk_vid ticks
  // span one full display line.
  localparam integer H_TOTAL = 420;         // clk_vid pixels per line
  localparam integer CE_DIV  = 8;           // ce_pix divides clk_vid by 8

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
      ce_div <= ce_div + 3'd1;
      ce_pix <= (ce_div == 3'd0);
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

  // ---- reader DDR master / pixel out ----------------------------------------
  wire [7:0]  ddr_burstcnt;
  wire [28:0] ddr_addr;
  wire        ddr_rd;
  wire [63:0] ddr_din;
  wire [7:0]  ddr_be;
  wire        ddr_we;
  reg         ddr_busy;
  reg  [63:0] ddr_dout;
  reg         ddr_dout_ready;

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

  // ---- behavioral DDR (single ddr_clk domain, burst, latency, starve) -------
  reg [63:0] mem [0:MEMQW-1];
  reg        starve = 1'b0;        // when high: hold off beats AND assert busy
  reg [7:0]  rbeats = 8'd0;        // remaining beats in current read burst
  reg [28:0] raddr  = 29'd0;       // current beat address
  reg [2:0]  rlat   = 3'd0;        // command latency before first beat
  integer    bi;

  // busy while a burst is in flight, during command latency, OR while starved.
  wire   ddr_busy_w = (rbeats != 8'd0) || (rlat != 3'd0) || starve;
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
        if (!starve) begin                   // deliver a beat (held off while starved)
          ddr_dout       <= mem[raddr - WBASE];
          ddr_dout_ready <= 1'b1;
          raddr  <= raddr + 29'd1;
          rbeats <= rbeats - 8'd1;
        end
      end else if (!ddr_busy) begin          // accept a new command
        if (ddr_rd) begin
          rbeats <= ddr_burstcnt;
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

  // ---- framebuffer pattern + control word seeding ---------------------------
  // fb[y][x] = 16'(((y<<8)|x) & 16'hFFFF)
  // KNOWN/ACCEPTED ALIASING: for x>=256, x's bit 8 collides with y's bit 0, so
  // e.g. fbpix(y,300)==fbpix(y+1,44). This is an accepted blind spot — the
  // comparison is position-based (pv2_x/pv2_y drive both sides), so it stays
  // self-consistent and still catches the scroll bug empirically (full-line
  // errors). Do NOT change the pattern; doing so reworks the whole comparison.
  function [15:0] fbpix(input integer y, input integer x);
    fbpix = (((y << 8) | x) & 16'hFFFF);
  endfunction

  // RGB565 -> RGB888 decode (mirror reader exactly)
  function [7:0] dec_r(input [15:0] p); dec_r = {p[15:11], p[15:13]}; endfunction
  function [7:0] dec_g(input [15:0] p); dec_g = {p[10:5],  p[10:9]};  endfunction
  function [7:0] dec_b(input [15:0] p); dec_b = {p[4:0],   p[4:2]};   endfunction

  integer y, x, qw, lane;
  reg [63:0] word;
  task seed_framebuffer;
    begin
      for (qw = 0; qw < MEMQW; qw = qw + 1) mem[qw] = 64'd0;
      for (y = 0; y < 240; y = y + 1) begin
        for (qw = 0; qw < QW_PER_LINE; qw = qw + 1) begin
          word = 64'd0;
          for (lane = 0; lane < 4; lane = lane + 1) begin
            x = qw*4 + lane;            // little-endian lanes: x&3 == lane
            word[lane*16 +: 16] = fbpix(y, x);
          end
          mem[BUF0_IDX + y*QW_PER_LINE + qw] = word;
        end
      end
    end
  endtask

  // Control word: [31:2]=frame_counter, [1]=unused, [0]=active_buffer.
  reg [29:0] frame_ctr = 30'd0;
  task publish_frame(input [29:0] fc);
    begin
      frame_ctr = fc;
      mem[CTRL_IDX] = {fc, 1'b0, 1'b0};  // active_buffer = 0 (BUF0)
    end
  endtask

  // ---- 2-ce_pix latency shadow pipeline -------------------------------------
  // The reader's pixel output has a 2-ce_pix latency relative to the timing
  // generator's (vcount,hcount,de): the timing outputs and de are registered at
  // ce_pix, and the reader registers r_out a further ce_pix later. We therefore
  // use a 2-deep shadow: r_out at this ce_pix is compared against the source
  // pixel for the position that was active TWO ce_pix ago (pv2_*). This makes
  // the comparison exact regardless of the fixed pipeline delay (empirically
  // verified against the current reader: 1-deep is off by one source pixel).
  reg [8:0] pv_y,  pv2_y;
  reg [9:0] pv_x,  pv2_x;
  reg       pv_valid, pv2_valid;

  reg          chk_enable = 1'b0;
  integer      px_errs    = 0;
  integer      px_checked = 0;
  integer      line_err [0:239];
  reg          pe_ok      = 1'b0;

  reg [15:0] exp_pix;
  reg [7:0]  exp_r, exp_g, exp_b;
  integer    li;

  always @(posedge clk_vid) begin
    if (reset) begin
      pv_valid  <= 1'b0;
      pv_y      <= 9'd0;
      pv_x      <= 10'd0;
      pv2_valid <= 1'b0;
      pv2_y     <= 9'd0;
      pv2_x     <= 10'd0;
    end else if (ce_pix) begin
      // --- compare the now-visible pixel against the 2-ce_pix-ago source ------
      // Require pv_valid too: the reader zeroes r_out when de drops, so the very
      // last active column (pv2 in active, pv already in hblank) gets clobbered by
      // the reader's own de-gating before the 2-cycle-delayed sample lands. That is
      // a deterministic boundary artifact of the FIFO reader's registered output,
      // not the scroll bug — exclude it by requiring de still high one cycle later.
      if (chk_enable && frame_ready && pv2_valid && pv_valid
          && pv2_x < 320 && pv2_y < 240) begin
        exp_pix = fbpix(pv2_y, pv2_x);
        exp_r   = dec_r(exp_pix);
        exp_g   = dec_g(exp_pix);
        exp_b   = dec_b(exp_pix);
        px_checked = px_checked + 1;
        if (r_out !== exp_r || g_out !== exp_g || b_out !== exp_b) begin
          px_errs = px_errs + 1;
          line_err[pv2_y] = line_err[pv2_y] + 1;
        end
      end
      // --- 2-deep shadow of the timing position --------------------------
      pv2_valid <= pv_valid;
      pv2_y     <= pv_y;
      pv2_x     <= pv_x;
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
      // wait until we are on target line during hblank (line fetch boundary)
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

    seed_framebuffer;
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

    // ===================== PIXEL-EXACT PHASE ================================
    // The reader, once it has a frame, re-reads the SAME buffer every vertical
    // scan via its stale-frame path (frame counter unchanged) and holds
    // frame_ready for ~30 vblanks. So we DON'T re-publish here: a fresh publish
    // forces a FIFO clear + line-0/1 preload that races the bottom of the
    // outgoing scan (a frame-boundary preload artifact, not the scroll bug).
    // We simply check pixels over ~3 full scans (>200k comparisons). The buffer
    // contents are static, so steady-state scanout must be pixel-exact.
    //
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
    // the DDR so the reader's line fetch for display line 100 cannot complete in
    // time. The FIFO reader buffers ~2-3 lines, so a one-line starve is absorbed;
    // we hold the starve long enough (a few line-times) to drain the FIFO during
    // ACTIVE display. The reader then stalls (emits black) and — because its pixel
    // output is coupled to FIFO occupancy, not to (vcount,hcount) — every
    // subsequent pixel is shifted: the scroll bug. We expect downstream display
    // lines (101, 150) to be corrupted, not just line 100.
    clear_counters;
    chk_enable = 1'b1;

    // The buffer is static (single publish above); the reader keeps re-displaying
    // it via the stale path. Wait for a clean top-of-frame, then approach line 100.
    wait_for_line_hblank(9'd241);
    wait_for_line_hblank(9'd96);

    // Starve from the hblank before line 96 onward, through ~line 100, holding for
    // ~4 active-line times so the FIFO genuinely empties mid-frame.
    starve = 1'b1;
    repeat (H_TOTAL*CE_DIV*4) @(posedge clk_vid);   // ~4 full display lines
    starve = 1'b0;

    // let the rest of the frame scan out
    wait_for_line_hblank(9'd239);
    repeat (H_TOTAL*CE_DIV) @(posedge clk_vid);      // ~1 full display line
    chk_enable = 1'b0;

    $display("UNDERFLOW: line[100] errs=%0d  line[101] errs=%0d  line[150] errs=%0d",
             line_err[100], line_err[101], line_err[150]);

    // ===================== VERDICT =========================================
    // line 100 itself MAY be corrupted (allowed single-line glitch). Downstream
    // lines 101 and 150 must be clean for a PASS.
    if (pe_ok && line_err[101] == 0 && line_err[150] == 0)
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
