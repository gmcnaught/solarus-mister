// tb_scanout_contention.sv — SUSTAINED f2h-contention probe for issue #34.
//
// The committed tb_scanout_linebuf.sv only models a TRANSIENT full starve (beats
// either flow at full rate or stop entirely, then release). The HW failure is
// different: under SDRAM-source, the blitter's un-throttled f2h writes steal
// bandwidth ALL FRAME, so the reader's per-scanline line fetch gets its 80 beats
// delivered SLOWER than the one-scanline deadline, sustained across many frames.
//
// This tb models exactly that: a DDR whose read beats arrive with a tunable
// inter-beat gap (BEAT_GAP ddr cycles), held for the whole run. It does NOT check
// pixels — it answers ONE diagnostic question the HW raised:
//
//   Does the reader FSM keep returning to ST_IDLE and advancing vsync_count
//   (graceful degradation), or does it WEDGE (vsync writeback frozen) ?
//
// Budget: one line = 80 beats must land within ~1 scanline. clk_vid period
// 18.625 ns, ddr 10 ns. One scanline = 420*8 clk_vid = 3360 ticks = 62.6 us =
// ~6260 ddr cycles -> ~78 ddr cycles/beat budget. BEAT_GAP > ~78 starves the
// per-scanline fetch deadline.
`timescale 1ns/1ps
`default_nettype none

module tb_scanout_contention;

  localparam [28:0] WBASE = 29'h07400000;
  localparam [31:0] MEMQW = 32'h20000;
  localparam integer BUF0_IDX    = 'h8;
  localparam integer QW_PER_LINE = 80;

  // Inter-beat gap in ddr cycles. Override on the command line with
  //   iverilog ... -Ptb_scanout_contention.BEAT_GAP=<n>
  parameter integer BEAT_GAP = 120;   // > ~78 budget -> sustained underflow

  reg clk_vid = 0;
  reg ddr_clk = 0;
  always #9.3125 clk_vid = ~clk_vid;
  always #5      ddr_clk = ~ddr_clk;

  reg reset = 1;

  reg [2:0] ce_div = 3'd0;
  reg       ce_pix = 1'b0;
  always @(posedge clk_vid) begin
    if (reset) begin ce_div <= 3'd0; ce_pix <= 1'b0; end
    else begin ce_div <= ce_div + 3'd1; ce_pix <= (ce_div == 3'd0); end
  end

  wire t_hsync,t_vsync,t_hblank,t_vblank,t_de,t_new_frame,t_new_line;
  wire [9:0] t_hcount;
  wire [8:0] t_vcount;
  openbor_video_timing u_timing (
    .clk(clk_vid), .ce_pix(ce_pix), .reset(reset),
    .h_adj(5'sd0), .v_adj(4'sd0),
    .hsync(t_hsync), .vsync(t_vsync), .hblank(t_hblank), .vblank(t_vblank),
    .de(t_de), .hcount(t_hcount), .vcount(t_vcount),
    .new_frame(t_new_frame), .new_line(t_new_line));

  wire [7:0]  ddr_burstcnt;
  wire [28:0] ddr_addr;
  wire        ddr_rd;
  wire [63:0] ddr_din;
  wire [7:0]  ddr_be;
  wire        ddr_we;
  reg         ddr_busy;
  reg  [63:0] ddr_dout;
  reg         ddr_dout_ready;
  wire [7:0]  r_out,g_out,b_out;
  wire        frame_ready;

  openbor_video_reader u_reader (
    .ddr_clk(ddr_clk), .ddr_busy(ddr_busy), .ddr_burstcnt(ddr_burstcnt),
    .ddr_addr(ddr_addr), .ddr_dout(ddr_dout), .ddr_dout_ready(ddr_dout_ready),
    .ddr_rd(ddr_rd), .ddr_din(ddr_din), .ddr_be(ddr_be), .ddr_we(ddr_we),
    .clk_vid(clk_vid), .ce_pix(ce_pix), .reset(reset),
    .de(t_de), .hblank(t_hblank), .vblank(t_vblank), .new_frame(t_new_frame),
    .new_line(t_new_line), .vcount(t_vcount),
    .ioctl_download(1'b0), .ioctl_wr(1'b0), .ioctl_addr(27'd0), .ioctl_dout(8'd0),
    .ioctl_wait(),
    .joystick_0(32'd0), .joystick_1(32'd0), .joystick_2(32'd0), .joystick_3(32'd0),
    .joystick_l_analog_0(16'd0),
    .r_out(r_out), .g_out(g_out), .b_out(b_out),
    .clk_audio(clk_vid), .audio_l(), .audio_r(),
    .enable(1'b1), .frame_ready(frame_ready));

  // ---- behavioral DDR with tunable inter-beat gap ----
  reg [63:0] mem [0:MEMQW-1];
  reg [7:0]  rbeats = 8'd0;
  reg [28:0] raddr  = 29'd0;
  reg [2:0]  rlat   = 3'd0;
  integer    gap    = 0;          // ddr cycles to wait before next beat
  integer    bi;

  // busy while a burst is in flight (incl. inter-beat gaps) or command latency.
  wire ddr_busy_w = (rbeats != 8'd0) || (rlat != 3'd0);
  always @(*) ddr_busy = ddr_busy_w;

  always @(posedge ddr_clk) begin
    ddr_dout_ready <= 1'b0;
    if (reset) begin rbeats <= 8'd0; rlat <= 3'd0; gap <= 0; end
    else begin
      if (rlat != 3'd0) begin
        rlat <= rlat - 3'd1;
      end else if (rbeats != 8'd0) begin
        if (gap != 0) begin
          gap <= gap - 1;                 // sustained-contention inter-beat delay
        end else begin
          ddr_dout       <= mem[raddr - WBASE];
          ddr_dout_ready <= 1'b1;
          raddr  <= raddr + 29'd1;
          rbeats <= rbeats - 8'd1;
          gap    <= BEAT_GAP;
        end
      end else if (!ddr_busy) begin
        if (ddr_rd) begin
          rbeats <= ddr_burstcnt;
          raddr  <= ddr_addr;
          rlat   <= 3'd2;
          gap    <= BEAT_GAP;
        end else if (ddr_we) begin
          for (bi = 0; bi < 8; bi = bi + 1)
            if (ddr_be[bi]) mem[ddr_addr - WBASE][bi*8 +: 8] <= ddr_din[bi*8 +: 8];
        end
      end
    end
  end

  function [15:0] fbpix(input integer y, input integer x);
    fbpix = (((y << 8) | x) & 16'hFFFF);
  endfunction
  integer y, qw, lane, xx;
  reg [63:0] word;
  task seed_framebuffer;
    begin
      for (qw = 0; qw < MEMQW; qw = qw + 1) mem[qw] = 64'd0;
      for (y = 0; y < 240; y = y + 1)
        for (qw = 0; qw < QW_PER_LINE; qw = qw + 1) begin
          word = 64'd0;
          for (lane = 0; lane < 4; lane = lane + 1) begin
            xx = qw*4 + lane;
            word[lane*16 +: 16] = fbpix(y, xx);
          end
          mem[BUF0_IDX + y*QW_PER_LINE + qw] = word;
        end
    end
  endtask
  task publish_frame(input [29:0] fc);
    begin mem[0] = {fc, 1'b0, 1'b0}; end
  endtask

  // ---- wedge watchdog: flag if FSM state is unchanged for too long ----
  reg  [4:0] last_state = 5'd31;
  integer    state_stuck = 0;
  integer    max_stuck   = 0;
  reg  [4:0] worst_state = 5'd31;
  always @(posedge ddr_clk) begin
    if (reset) begin state_stuck <= 0; last_state <= 5'd31; end
    else begin
      if (u_reader.state == last_state) begin
        state_stuck <= state_stuck + 1;
        if (state_stuck + 1 > max_stuck) begin
          max_stuck   <= state_stuck + 1;
          worst_state <= u_reader.state;
        end
      end else begin
        state_stuck <= 0;
        last_state  <= u_reader.state;
      end
    end
  end

  // ---- vsync_count progress sampler ----
  integer settle, k;
  reg [31:0] vs0, vs1;
  integer    dl_min, dl_max;

  initial begin
    ddr_busy = 1'b0; ddr_dout = 64'd0; ddr_dout_ready = 1'b0;
    seed_framebuffer;
    publish_frame(30'd1);
    repeat (16) @(posedge ddr_clk);
    reset = 1'b0;

    settle = 0;
    while (!u_reader.synced) begin
      @(posedge clk_vid); settle = settle + 1;
      if (settle > 5_000_000) begin $display("RESULT: FAIL (never synced)"); $finish; end
    end
    repeat (200) @(posedge clk_vid);
    publish_frame(30'd2);

    settle = 0;
    while (!frame_ready) begin
      @(posedge clk_vid); settle = settle + 1;
      if (settle > 20_000_000) begin
        $display("WEDGE: frame_ready never asserted under BEAT_GAP=%0d (state=%0d display_line=%0d)",
                 BEAT_GAP, u_reader.state, u_reader.display_line);
        $display("RESULT: WEDGE");
        $finish;
      end
    end
    $display("frame_ready reached after %0d clk_vid (BEAT_GAP=%0d)", settle, BEAT_GAP);

    // ---- sustained contention: keep committing fresh frames, watch vsync_count ----
    // Engine "keeps committing": bump the frame counter periodically (like the
    // real engine). Sample vsync_count across ~12 display frames.
    vs0 = u_reader.vsync_count;
    dl_min = 9999; dl_max = -1;
    for (k = 0; k < 12; k = k + 1) begin
      // one display frame is ~262 lines * 420 px * 8 = 880k clk_vid ticks
      repeat (262*420*8/10) @(posedge clk_vid);  // ~1/10 frame
      publish_frame(u_reader.prev_frame_counter + 30'd2);  // engine commits new frame
      if (u_reader.display_line < dl_min) dl_min = u_reader.display_line;
      if (u_reader.display_line > dl_max) dl_max = u_reader.display_line;
    end
    vs1 = u_reader.vsync_count;

    $display("vsync_count: start=%0d end=%0d delta=%0d", vs0, vs1, vs1 - vs0);
    $display("display_line span observed: [%0d .. %0d]", dl_min, dl_max);
    $display("max consecutive cycles stuck in one state: %0d (state=%0d)", max_stuck, worst_state);

    // Verdict: under sustained contention, a HEALTHY FSM keeps minting vsync
    // (returns to ST_IDLE every frame). vsync delta of 0 == the HW 'frozen
    // writeback' wedge reproduced in sim.
    if ((vs1 - vs0) == 0)
      $display("RESULT: WEDGE (vsync_count frozen -> FSM not reaching ST_WRITE_VSYNC)");
    else
      $display("RESULT: ALIVE (vsync advancing -> graceful degradation, not a hard wedge)");
    $finish;
  end

  initial begin
    #2000000000 $display("RESULT: WEDGE (sim watchdog timeout)"); $finish;
  end

endmodule
`default_nettype wire
