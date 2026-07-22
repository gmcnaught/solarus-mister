// tb_scanout_ddr3.sv — scanout reads the framebuffer from the DDR3 double-buffer
// [Stage 5 Phase 2 Task 6, un-bridge]. comp_fbram / fbram_scan_adapter are gone;
// ddr3_scan_adapter now bridges the reader's unchanged P_SCAN cache-ok protocol to
// a real DDR3 read master, hiding the round-trip with a line-granular (80 qword)
// burst per scanline. Modeled on tb_scanout_fbram.sv (the retired FB-in-BRAM
// pixel-exact harness) and tb_scanout_sdram.sv (the earlier DDR/SDRAM-backed
// scanout TB, git history 07426f8) for the two-responder (ctrl/joystick/audio +
// framebuffer) DDR3 behavioral-model shape.
//
// Preloads a known 320x240 frame into a DDR3 model at `FB_DDR0_QW` (buf0), sets
// the control word's active_buffer bit to 0, runs the real reader +
// ddr3_scan_adapter, and asserts:
//   (a) PIXEL-EXACT: every displayed pixel for a full frame matches the seeded
//       pattern exactly (regression guard for the un-bridge).
//   (b) BUF0-ONLY: the adapter's DDR3 read master never issues a burst whose
//       address falls in the FB1 region (`FB_DDR1_QW`..+FB_QWORDS) -- i.e. with
//       active_buffer=0 it genuinely reads buf0, not buf1.
`timescale 1ns/1ps
`default_nettype none
`include "../rtl/vram_defs.vh"

module tb_scanout_ddr3;

  localparam [28:0] WBASE = 29'h07400000;   // 0x3A000000 >> 3 (ctrl/joystick/audio window)
  localparam [31:0] MEMQW = 32'h20000;      // 128k qwords window (DDR control area)
  localparam integer CTRL_IDX = 0;          // control word at mem[0]
  localparam integer H_TOTAL = 420;
`ifdef SCANOUT_DDR3_FULL
  localparam integer CE_DIV  = 8;   // HW-faithful /8 pixel clock (nightly)
`else
  // sim-only reduced ce_pix divider: min value that stays pixel-exact.
  localparam integer CE_DIV  = 2;
`endif
`ifdef SCANOUT_DDR3_FULL
  localparam integer N_SCAN_FRAMES = 3;
  localparam integer MIN_CHECKED   = 200000;
`else
  localparam integer N_SCAN_FRAMES = 1;
  localparam integer MIN_CHECKED   = 60000;   // one 320x240 frame = 76800 active px; require >60k
`endif

  reg clk_vid = 0;
  reg ddr_clk = 0;
  always #9.3125 clk_vid = ~clk_vid;   // ~53.69 MHz
  always #5      ddr_clk = ~ddr_clk;   // 100 MHz
  reg reset = 1;

  reg [2:0] ce_div = 3'd0;
  reg       ce_pix = 1'b0;
  always @(posedge clk_vid) begin
    if (reset) begin ce_div <= 3'd0; ce_pix <= 1'b0; end
    else begin
      ce_div <= (ce_div == CE_DIV-1) ? 3'd0 : ce_div + 3'd1;
      ce_pix <= (ce_div == 3'd0);
    end
  end

  wire t_hsync, t_vsync, t_hblank, t_vblank, t_de, t_new_frame, t_new_line;
  wire [9:0] t_hcount;
  wire [8:0] t_vcount;
  openbor_video_timing u_timing (
    .clk(clk_vid), .ce_pix(ce_pix), .reset(reset), .h_adj(5'sd0), .v_adj(4'sd0),
    .hsync(t_hsync), .vsync(t_vsync), .hblank(t_hblank), .vblank(t_vblank),
    .de(t_de), .hcount(t_hcount), .vcount(t_vcount),
    .new_frame(t_new_frame), .new_line(t_new_line));

  // reader DDR master (control/joystick/audio)
  wire [7:0]  ddr_burstcnt; wire [28:0] ddr_addr; wire ddr_rd;
  wire [63:0] ddr_din; wire [7:0] ddr_be; wire ddr_we;
  reg         ddr_busy; reg [63:0] ddr_dout; reg ddr_dout_ready;

  // reader P_SCAN master -> ddr3_scan_adapter -> DDR3 FB model
  wire [26:0] scan_addr; wire scan_rd; wire [63:0] scan_dout; wire scan_ok;
  wire [28:0] fb_ddr_addr; wire [7:0] fb_ddr_burstcnt; wire fb_ddr_rd;
  reg  [63:0] fb_ddr_dout; reg fb_ddr_dout_ready; reg fb_ddr_busy;

  ddr3_scan_adapter u_adapter (
    .clk(ddr_clk), .reset(reset),
    .scn_addr(scan_addr), .scn_rd(scan_rd), .scn_dout(scan_dout), .scn_ok(scan_ok),
    .ddr_addr(fb_ddr_addr), .ddr_burstcnt(fb_ddr_burstcnt), .ddr_rd(fb_ddr_rd),
    .ddr_dout(fb_ddr_dout), .ddr_dout_ready(fb_ddr_dout_ready), .ddr_busy(fb_ddr_busy));

  wire [7:0] r_out, g_out, b_out;
  wire       frame_ready;

  openbor_video_reader u_reader (
    .ddr_clk(ddr_clk), .ddr_busy(ddr_busy), .ddr_burstcnt(ddr_burstcnt),
    .ddr_addr(ddr_addr), .ddr_dout(ddr_dout), .ddr_dout_ready(ddr_dout_ready),
    .ddr_rd(ddr_rd), .ddr_din(ddr_din), .ddr_be(ddr_be), .ddr_we(ddr_we),
    .scan_addr(scan_addr), .scan_rd(scan_rd), .scan_dout(scan_dout), .scan_ok(scan_ok),
    .clk_vid(clk_vid), .ce_pix(ce_pix), .reset(reset),
    .de(t_de), .hblank(t_hblank), .vblank(t_vblank),
    .new_frame(t_new_frame), .new_line(t_new_line), .vcount(t_vcount),
    .ioctl_download(1'b0), .ioctl_wr(1'b0), .ioctl_addr(27'd0), .ioctl_dout(8'd0), .ioctl_wait(),
    .joystick_0(32'd0), .joystick_1(32'd0), .joystick_2(32'd0), .joystick_3(32'd0),
    .joystick_l_analog_0(16'd0),
    .r_out(r_out), .g_out(g_out), .b_out(b_out),
    .clk_audio(clk_vid), .audio_l(), .audio_r(),
    .enable(1'b1), .frame_ready(frame_ready),
    .dbg_blt(32'd0), .dbg_addr(32'd0), .dbg_diag(32'd0));

  // behavioral DDR (control word + joystick/audio only) -- same shape as
  // tb_scanout_fbram.sv / tb_scanout_sdram.sv's ctrl responder.
  reg [63:0] mem [0:MEMQW-1];
  reg [7:0]  rbeats = 8'd0; reg [28:0] raddr = 29'd0; reg [2:0] rlat = 3'd0;
  integer bi;
  wire ddr_busy_w = (rbeats != 8'd0) || (rlat != 3'd0);
  always @(*) ddr_busy = ddr_busy_w;
  always @(posedge ddr_clk) begin
    ddr_dout_ready <= 1'b0;
    if (reset) begin rbeats <= 8'd0; rlat <= 3'd0; end
    else begin
      if (rlat != 3'd0) rlat <= rlat - 3'd1;
      else if (rbeats != 8'd0) begin
        ddr_dout <= mem[raddr - WBASE]; ddr_dout_ready <= 1'b1;
        raddr <= raddr + 29'd1; rbeats <= rbeats - 8'd1;
      end else if (!ddr_busy) begin
        if (ddr_rd) begin rbeats <= ddr_burstcnt; raddr <= ddr_addr; rlat <= 3'd2; end
        else if (ddr_we)
          for (bi = 0; bi < 8; bi = bi + 1)
            if (ddr_be[bi]) mem[ddr_addr - WBASE][bi*8 +: 8] <= ddr_din[bi*8 +: 8];
      end
    end
  end

  // -- DDR3 framebuffer model: burst-read only, 16-bit-addressable underneath so
  // the seed task can write individual pixels (same idiom as tb_scanout_sdram's
  // sdram_mem). Window covers FB0 AND FB1 (0x8000 qwords apart, see
  // DDR3_SCAN_BUF1_OFF in openbor_video_reader.sv / FB_DDR1_QW in vram_defs.vh):
  // relative qword 0 = FB_DDR0_QW, relative qword 0x8000 = FB_DDR1_QW.
  localparam [28:0] FBBASE     = `FB_DDR0_QW;
  localparam integer FB_WIN_QW = 32'h10000;         // 64k qwords: covers buf0 + buf1 + margin
  reg [15:0] fb16mem [0:(FB_WIN_QW*4)-1];            // 4 x 16-bit lanes per qword

  reg [7:0]  fbeats = 8'd0; reg [28:0] fraddr = 29'd0; reg [2:0] frlat = 3'd0;
  wire fb_busy_w = (fbeats != 8'd0) || (frlat != 3'd0);
  always @(*) fb_ddr_busy = fb_busy_w;

  // BUF0-ONLY monitor: latch true if any accepted burst targets the FB1 region.
  reg touched_buf1 = 1'b0;
  wire fb_accept = fb_ddr_rd & ~fb_ddr_busy;
  always @(posedge ddr_clk)
    if (fb_accept && (fb_ddr_addr >= (FBBASE + 29'h8000)))
      touched_buf1 <= 1'b1;

  always @(posedge ddr_clk) begin
    fb_ddr_dout_ready <= 1'b0;
    if (reset) begin fbeats <= 8'd0; frlat <= 3'd0; end
    else begin
      if (frlat != 3'd0) frlat <= frlat - 3'd1;
      else if (fbeats != 8'd0) begin
        fb_ddr_dout <= {fb16mem[(fraddr-FBBASE)*4+3], fb16mem[(fraddr-FBBASE)*4+2],
                        fb16mem[(fraddr-FBBASE)*4+1], fb16mem[(fraddr-FBBASE)*4+0]};
        fb_ddr_dout_ready <= 1'b1;
        fraddr <= fraddr + 29'd1; fbeats <= fbeats - 8'd1;
      end else if (!fb_ddr_busy) begin
        if (fb_ddr_rd) begin fbeats <= fb_ddr_burstcnt; fraddr <= fb_ddr_addr; frlat <= 3'd2; end
      end
    end
  end

  // framebuffer pattern: fb[y][x] = ((y<<8)|x) & 0xFFFF (same as tb_scanout_fbram /
  // tb_scanout_sdram -- do NOT change; the aliasing for x>=256 is an accepted
  // blind spot documented there).
  function [15:0] fbpix(input integer y, input integer x);
    fbpix = (((y << 8) | x) & 16'hFFFF);
  endfunction
  function [7:0] dec_r(input [15:0] p); dec_r = {p[15:11], p[15:13]}; endfunction
  function [7:0] dec_g(input [15:0] p); dec_g = {p[10:5],  p[10:9]};  endfunction
  function [7:0] dec_b(input [15:0] p); dec_b = {p[4:0],   p[4:2]};   endfunction

  integer yy, xx, half_idx;
  // Seed FB0 (buf0, relative qword 0) with the pattern; FB1 gets a distinct
  // poison pattern so a wrong-buffer read would visibly diverge (belt+braces on
  // top of the address-range monitor above).
  task seed_fb_ddr3;
    begin
      for (half_idx = 0; half_idx < FB_WIN_QW*4; half_idx = half_idx + 1)
        fb16mem[half_idx] = 16'hDEAD;
      for (yy = 0; yy < 240; yy = yy + 1)
        for (xx = 0; xx < 320; xx = xx + 1) begin
          half_idx = (yy*80 + (xx>>2))*4 + (xx & 3);
          fb16mem[half_idx] = fbpix(yy, xx);
        end
    end
  endtask

  integer qw_i;
  task clear_ddr_mem; begin for (qw_i = 0; qw_i < MEMQW; qw_i = qw_i + 1) mem[qw_i] = 64'd0; end endtask

  reg [29:0] frame_ctr = 30'd0;
  // Control word: [31:2]=frame_counter, [0]=active_buffer. active_buffer=0 (FB0).
  task publish_frame(input [29:0] fc); begin frame_ctr = fc; mem[CTRL_IDX] = {fc, 1'b0, 1'b0}; end endtask

  reg [8:0] pv_y; reg [9:0] pv_x; reg pv_valid;
  reg          chk_enable = 1'b0;
  integer      px_errs = 0, px_checked = 0;
  integer      line_err [0:239];
  reg          pe_ok = 1'b0;
  reg [15:0]   exp_pix; reg [7:0] exp_r, exp_g, exp_b;
  integer      li;

  always @(posedge clk_vid) begin
    if (reset) begin pv_valid <= 1'b0; pv_y <= 9'd0; pv_x <= 10'd0; end
    else if (ce_pix) begin
      if (chk_enable && frame_ready && pv_valid && pv_x < 320 && pv_y < 240) begin
        exp_pix = fbpix(pv_y, pv_x);
        exp_r = dec_r(exp_pix); exp_g = dec_g(exp_pix); exp_b = dec_b(exp_pix);
        px_checked = px_checked + 1;
        if (r_out !== exp_r || g_out !== exp_g || b_out !== exp_b) begin
          px_errs = px_errs + 1; line_err[pv_y] = line_err[pv_y] + 1;
        end
      end
      pv_valid <= t_de; pv_y <= t_vcount; pv_x <= t_hcount;
    end
  end

  task clear_counters;
    begin px_errs = 0; px_checked = 0; for (li = 0; li < 240; li = li + 1) line_err[li] = 0; end
  endtask

  task wait_for_line_hblank(input [8:0] target_v);
    integer guard;
    begin
      guard = 0;
      while (!(t_vcount == target_v && t_hblank)) begin
        @(posedge clk_vid); guard = guard + 1;
        if (guard > 50_000_000) begin $display("RESULT: FAIL (wait hung v=%0d)", target_v); $finish; end
      end
    end
  endtask

  integer scan, settle;
  initial begin
    for (li = 0; li < 240; li = li + 1) line_err[li] = 0;
    ddr_busy = 1'b0; ddr_dout = 64'd0; ddr_dout_ready = 1'b0;
    fb_ddr_dout = 64'd0; fb_ddr_dout_ready = 1'b0;
    clear_ddr_mem;
    seed_fb_ddr3;
    publish_frame(30'd1);
    repeat (16) @(posedge ddr_clk);
    reset = 1'b0;

    settle = 0;
    while (!u_reader.synced) begin
      @(posedge clk_vid); settle = settle + 1;
      if (settle > 5_000_000) begin $display("RESULT: FAIL (reader never synced)"); $finish; end
    end
    repeat (200) @(posedge clk_vid);
    publish_frame(30'd2);

    settle = 0;
    while (!frame_ready) begin
      @(posedge clk_vid); settle = settle + 1;
      if (settle > 5_000_000) begin $display("RESULT: FAIL (frame_ready never asserted)"); $finish; end
    end

    // PIXEL-EXACT phase
    wait_for_line_hblank(9'd241);
    clear_counters;
    chk_enable = 1'b1;
    for (scan = 0; scan < N_SCAN_FRAMES; scan = scan + 1) begin
      wait_for_line_hblank(9'd239);
      @(posedge clk_vid);
      wait_for_line_hblank(9'd241);
    end
    chk_enable = 1'b0;

    pe_ok = (px_errs == 0 && px_checked > MIN_CHECKED);
    $display("PIXEL-EXACT: checked=%0d errs=%0d  -> %s", px_checked, px_errs, pe_ok ? "PASS" : "FAIL");
    $display("BUF0-ONLY: touched_buf1=%0d -> %s", touched_buf1, touched_buf1 ? "FAIL" : "PASS");
    if (pe_ok && !touched_buf1) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end

  initial begin #500000000 $display("RESULT: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire
