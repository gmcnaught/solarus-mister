// tb_scanout_fbram.sv — scanout reads the framebuffer from on-chip comp_fbram
// [FB-in-BRAM], via fbram_scan_adapter (the reader's P_SCAN cache-ok protocol
// unchanged; the adapter maps it to comp_fbram's 1-cycle scan read). Proves the
// single-buffer reader address map (buf_base=0) + the adapter + comp_fbram scan
// port are pixel-exact end-to-end through the real openbor_video_reader.
//
// Only a PIXEL-EXACT phase: comp_fbram is on-chip and never backpressures, so the
// SDRAM-underflow/recovery phase of tb_scanout_sdram does not apply here.
`timescale 1ns/1ps
`default_nettype none
`include "../rtl/vram_defs.vh"

module tb_scanout_fbram;

  localparam [28:0] WBASE = 29'h07400000;   // 0x3A000000 >> 3
  localparam [31:0] MEMQW = 32'h20000;      // 128k qwords window (DDR control area)
  localparam integer CTRL_IDX = 0;          // control word at mem[0]
  localparam integer H_TOTAL = 420;
`ifdef SCANOUT_FBRAM_FULL
  localparam integer CE_DIV  = 8;   // HW-faithful /8 pixel clock (nightly)
`else
  // sim-only reduced ce_pix divider: min value that stays pixel-exact.
  // CE_DIV=1 outruns the reader's fetch pipeline -> mismatches.
  localparam integer CE_DIV  = 2;
`endif
`ifdef SCANOUT_FBRAM_FULL
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
      ce_pix <= (ce_div == 3'd0);   // CE_DIV=1 -> every clk_vid; CE_DIV=8 -> 1-in-8 (== original)
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

  // reader P_SCAN master -> fbram_scan_adapter -> comp_fbram scan port
  wire [26:0] scan_addr; wire scan_rd; wire [63:0] scan_dout; wire scan_ok;
  wire        fb_scan_rd_en; wire [14:0] fb_scan_rd_qw; wire [63:0] fb_scan_rd_qword;

  fbram_scan_adapter u_adapter (
    .clk(ddr_clk),
    .scn_addr(scan_addr), .scn_rd(scan_rd), .scn_dout(scan_dout), .scn_ok(scan_ok),
    .scan_rd_en(fb_scan_rd_en), .scan_rd_qw(fb_scan_rd_qw), .scan_rd_qword(fb_scan_rd_qword));

  comp_fbram u_fbram (
    .clk(ddr_clk),
    .wr_en(1'b0), .wr_qw(15'd0), .wr_lane(2'd0), .wr_pix(16'd0),   // composite port unused
    .rd_en(1'b0), .rd_qw(15'd0), .rd_qword(),
    .scan_rd_en(fb_scan_rd_en), .scan_rd_qw(fb_scan_rd_qw), .scan_rd_qword(fb_scan_rd_qword));

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

  // behavioral DDR (control word + joystick/audio only)
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

  // framebuffer pattern: fb[y][x] = ((y<<8)|x) & 0xFFFF (same as tb_scanout_sdram)
  function [15:0] fbpix(input integer y, input integer x);
    fbpix = (((y << 8) | x) & 16'hFFFF);
  endfunction
  function [7:0] dec_r(input [15:0] p); dec_r = {p[15:11], p[15:13]}; endfunction
  function [7:0] dec_g(input [15:0] p); dec_g = {p[10:5],  p[10:9]};  endfunction
  function [7:0] dec_b(input [15:0] p); dec_b = {p[4:0],   p[4:2]};   endfunction

  integer yy, xx, qw_seed, lane_seed;
  // Seed comp_fbram's scan-read banks (and the composite copy) with the pattern.
  task seed_fb_bram;
    begin
      for (yy = 0; yy < 240; yy = yy + 1)
        for (xx = 0; xx < 320; xx = xx + 1) begin
          qw_seed   = yy*80 + (xx>>2);
          lane_seed = xx & 3;
          case (lane_seed)
            0: begin u_fbram.sbank0[qw_seed]=fbpix(yy,xx); u_fbram.bank0[qw_seed]=fbpix(yy,xx); end
            1: begin u_fbram.sbank1[qw_seed]=fbpix(yy,xx); u_fbram.bank1[qw_seed]=fbpix(yy,xx); end
            2: begin u_fbram.sbank2[qw_seed]=fbpix(yy,xx); u_fbram.bank2[qw_seed]=fbpix(yy,xx); end
            3: begin u_fbram.sbank3[qw_seed]=fbpix(yy,xx); u_fbram.bank3[qw_seed]=fbpix(yy,xx); end
          endcase
        end
    end
  endtask

  integer qw_i;
  task clear_ddr_mem; begin for (qw_i = 0; qw_i < MEMQW; qw_i = qw_i + 1) mem[qw_i] = 64'd0; end endtask

  reg [29:0] frame_ctr = 30'd0;
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
    clear_ddr_mem;
    seed_fb_bram;
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
    if (pe_ok) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end

  initial begin #500000000 $display("RESULT: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire
