// tb_bgplane_3plane_xl.sv — [#24 dungeon] THREE back-to-back per-layer plane bakes
// into disjoint arena bases, reproducing "the last-baked plane reads transparent".
//
// The dungeon bakes 3 per-layer ARGB4444 planes to disjoint contiguous arena bases
// (layer2 @0x05400000 first, layer1 @0x05658000, layer0 @0x058b0000 last/densest),
// each via the real per-cell sequence:
//     FILL(320x240, BLT_F_BGCOV)   -> clears the bgplane_coverage tracker
//     paint tiles (normal FILL)     -> SETS coverage on covered pixels
//     OP_BGPLANE_WRITE(BLT_F_BGCOV) -> ARGB4444 pack, alpha = coverage nibble
// USER-observed: bgplane ON flattens the dungeon; host-traced that layer0 (last,
// densest) composites ~0% (reads transparent) while layer2 (first) shows ~7%. The
// host writes each plane's content exactly where the COPY reads it (addresses
// provably correct), so the suspect is a 3-simultaneous-plane FABRIC interaction in
// the SHARED bake machinery (comp_fbram WORK, fbram_to_sdram, bgplane_coverage) —
// the LAST plane's coverage/alpha baking as 0 -> PALPHA COPY reads it transparent.
//
// This TB bakes 3 planes at the dungeon's real bases, back-to-back, NO fabric reset
// between them (mimicking the real sequential bake), then reads EACH plane back via
// ch5 P_SRC and asserts covered pixels pack alpha=0xF (+correct color) and uncovered
// alpha=0. It uses the REAL BLT_F_BGCOV ring-flag path (decode landed:
// blitter_top.sv:291 c_bgcov_clear, :668 bgw_argb4444), not force. The verdict is
// whether the LAST plane's covered pixels read alpha=0xF (fabric clean, bug is
// host-side) or 0x0 (reproduced -> localize to the shared coverage/bake state).
//
// Harness = tb_bgplane_write_pipe_xl.sv (2-die XL, ch5 readback).
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"

module tb_bgplane_3plane_xl;
  localparam [31:0] RINGB = 32'h200008;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h8000;

  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  reg vs = 0; integer vsc = 0;
  always @(posedge clk) begin
    vsc <= vsc + 1;
    if (vsc >= 256) begin vs <= ~vs; vsc <= 0; end
  end

  // ---- behavioral command-ring DDR ----
  reg [63:0] mem [0:MEMQW-1];
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat; reg [1:0] bp = 0;
  always @(posedge clk) bp <= bp + 2'd1;
  wire [31:0] bt_addr; wire b_rd, b_we; wire [63:0] b_din; wire [7:0] b_be; wire bt_idle;
  wire [7:0] bt_burst;
  reg  d_dready; reg [63:0] d_dout;
  wire d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  integer i;
  always @(posedge clk) begin
    d_dready <= 1'b0;
    if (rst) begin rbeats <= 0; rlat <= 0; end
    else begin
      if (rlat != 3'd0) rlat <= rlat - 3'd1;
      else if (rbeats != 8'd0) begin
        if (bp == 2'd2) begin
          d_dout <= mem[raddr - WBASE]; d_dready <= 1'b1;
          raddr <= raddr + 29'd1; rbeats <= rbeats - 8'd1;
        end
      end else if (!d_busy) begin
        if (b_rd) begin rbeats <= bt_burst; raddr <= bt_addr[28:0]; rlat <= 3'd3; end
        else if (b_we) for (i = 0; i < 8; i = i + 1)
          if (b_be[i]) mem[(bt_addr[28:0] - WBASE)][i*8 +: 8] <= b_din[i*8 +: 8];
      end
    end
  end

  // ---- on-chip dest framebuffer ----
  wire fb_wr_en; wire [14:0] fb_wr_qw; wire [1:0] fb_wr_lane; wire [15:0] fb_wr_pix;
  wire fb_rd_en; wire [14:0] fb_rd_qw; wire [63:0] fb_rd_qword;
  comp_fbram fbram (.clk(clk),
    .wr_en(fb_wr_en), .wr_qw(fb_wr_qw), .wr_lane(fb_wr_lane), .wr_pix(fb_wr_pix),
    .rd_en(fb_rd_en), .rd_qw(fb_rd_qw), .rd_qword(fb_rd_qword));

  // ---- ch0 (P_DST) write (blitter_top) + ch5 (P_SRC) read (TB): XL cache + 2 dies ----
  wire        dst_wr; wire [26:0] dst_addr; wire [63:0] dst_din; wire [7:0] dst_wdsn; wire dst_ok;
  wire        coh_busy;
  reg  [26:0] p0_addr; reg p0_rd; wire [63:0] p0_dout; wire p0_ok;

  wire [15:0] sdram_dq; wire [12:0] sdram_a;
  wire        sdram_dqml, sdram_dqmh; wire [1:0] sdram_ba;
  wire        sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke, sdram_clk;

  // [bgplane bake -> STAGE reroute] wire blitter_top's STAGE outputs into cache ch1.
  wire        stage_we_burst_w;
  wire [63:0] stage_din64_w;
  wire [26:0] stage_waddr_w;
  wire        stage_ok_w;
  wire        stage_barrier_w;
  wire        stage_busy_w;

  sdram_fb_cache #(.SDRAM_AW(25)) u_cache (
    .clk(clk), .clk_sdram(clk), .rst(rst), .init(),
    .dst_addr(dst_addr), .dst_rd(1'b0), .dst_wr(dst_wr),
    .dst_din(dst_din), .dst_wdsn(dst_wdsn), .dst_dout(), .dst_ok(dst_ok),
    .scan_addr(27'd0), .scan_rd(1'b0), .scan_dout(), .scan_ok(),
    .p0_addr(p0_addr), .p0_rd(p0_rd), .p0_dout(p0_dout), .p0_ok(p0_ok),
    .stage_addr(stage_waddr_w), .stage_wr(stage_we_burst_w), .stage_din(stage_din64_w),
    .stage_wdsn(8'h00), .stage_ok(stage_ok_w),
    .vs(vs), .coh_busy(coh_busy),
    .stage_barrier(stage_barrier_w), .stage_busy(stage_busy_w), .dst_barrier(1'b0), .dst_busy(),
    .sdram_dq(sdram_dq), .sdram_a(sdram_a),
    .sdram_dqml(sdram_dqml), .sdram_dqmh(sdram_dqmh), .sdram_ba(sdram_ba),
    .sdram_nwe(sdram_nwe), .sdram_ncas(sdram_ncas), .sdram_nras(sdram_nras),
    .sdram_ncs(sdram_ncs), .sdram_cke(sdram_cke), .sdram_clk(sdram_clk)
  );

  wire sc   = u_cache.u_sdram_ctrl.u_io.sel_chip_r;
  wire ncs0 = sc ? 1'b1 : sdram_ncs;
  wire ncs1 = sc ? ~sdram_ncs : 1'b1;
  mt48lc16m16a2 #(.addr_bits(13), .col_bits(10)) u_chip0 (
    .Clk(clk), .Cke(sdram_cke), .Dq(sdram_dq), .Addr(sdram_a), .Ba(sdram_ba),
    .Cs_n(ncs0), .Ras_n(sdram_nras), .Cas_n(sdram_ncas), .We_n(sdram_nwe),
    .Dqm({sdram_dqmh, sdram_dqml}), .downloading(1'b0), .VS(1'b0), .frame_cnt(0));
  mt48lc16m16a2 #(.addr_bits(13), .col_bits(10)) u_chip1 (
    .Clk(clk), .Cke(sdram_cke), .Dq(sdram_dq), .Addr(sdram_a), .Ba(sdram_ba),
    .Cs_n(ncs1), .Ras_n(sdram_nras), .Cas_n(sdram_ncas), .We_n(sdram_nwe),
    .Dqm({sdram_dqmh, sdram_dqml}), .downloading(1'b0), .VS(1'b0), .frame_cnt(0));

  // ---- DUT ----
  blitter_top blt (.clk(clk), .rst(rst), .vs(vs),
    .mem_addr(bt_addr), .mem_rd(b_rd), .mem_wr(b_we), .mem_burstcnt(bt_burst),
    .mem_din(b_din), .mem_be(b_be),
    .mem_dout(d_dout), .mem_dout_ready(d_dready), .mem_busy(d_busy),
    .p0_addr(), .p0_rd(), .p0_dout(64'd0), .p0_ok(1'b0),
    .src_sdram_we_burst(stage_we_burst_w), .src_sdram_din64(stage_din64_w),
    .src_sdram_waddr(stage_waddr_w), .src_sdram_ok(stage_ok_w),
    .stage_barrier(stage_barrier_w), .stage_barrier_busy(stage_busy_w),
    .fb_wr_en(fb_wr_en), .fb_wr_qw(fb_wr_qw), .fb_wr_lane(fb_wr_lane), .fb_wr_pix(fb_wr_pix),
    .fb_rd_en(fb_rd_en), .fb_rd_qw(fb_rd_qw), .fb_rd_qword(fb_rd_qword),
    .dst_wr(dst_wr), .dst_addr(dst_addr), .dst_din(dst_din), .dst_wdsn(dst_wdsn), .dst_ok(dst_ok),
    .idle(bt_idle));

  // ---- command-ring helpers ----
  integer submit_n = 0;
  task set_ctrl(input integer ncmds, input integer flags);
    begin
      mem[32'h200001] = ncmds; mem[32'h200002] = 64'd0; mem[32'h200003] = 64'd0;
      mem[32'h200004] = flags; mem[32'h200007] = 64'd2;
    end
  endtask

  // FILL with an explicit flags byte (c_flags = cmd_qw[0][31:24]).
  task wr_fill_f(input integer slot, input [15:0] dx, input [15:0] dy,
                 input [15:0] w, input [15:0] h, input [15:0] color, input [7:0] flags);
    integer base;
    begin
      base = RINGB + slot*4;
      mem[base+0] = {32'd0, flags, 8'd0, 8'd0, 8'd2};   // opcode=FILL(2), blend=0, fmt=0, flags
      mem[base+1] = {h, w, 32'd0};
      mem[base+2] = {dy, dx, 32'd0};
      mem[base+3] = {16'd0, color, 32'd0};
    end
  endtask

  // OP_BGPLANE_WRITE with an explicit flags byte (BLT_F_BGCOV=0x80 -> bgw_argb4444).
  task wr_bgw_f(input integer slot, input [31:0] base_qw, input [15:0] stride_qw, input [7:0] flags);
    integer base;
    begin
      base = RINGB + slot*4;
      mem[base+0] = {32'd0, flags, 8'd0, 8'd0, OP_BGPLANE_WRITE};
      mem[base+1] = {32'd0, stride_qw, 16'd0};
      mem[base+2] = {base_qw[31:16], base_qw[15:0], 32'd0};
      mem[base+3] = 64'd0;
    end
  endtask

  task run_submit;
    integer to;
    begin
      submit_n = submit_n + 1; mem[32'h200000] = submit_n; to = 0;
      while (mem[32'h200005][31:0] !== submit_n[31:0] && to < 4000000) begin @(posedge clk); to = to + 1; end
      if (mem[32'h200005][31:0] !== submit_n[31:0]) $display("  WEDGE: submit %0d never acked", submit_n);
      repeat (10) @(posedge clk);
    end
  endtask

  task flush_to_sdram;
    integer to;
    begin
      to = 0; while (!vs && to < 400) begin @(posedge clk); to = to + 1; end
      while (vs && to < 400) begin @(posedge clk); to = to + 1; end
      to = 0; while (coh_busy && to < 40000) begin @(posedge clk); to = to + 1; end
      repeat (10) @(posedge clk);
    end
  endtask

  task p0_read(input [26:0] a, output [63:0] q);
    integer cyc;
    begin
      while (coh_busy) @(posedge clk);
      @(posedge clk); #1; p0_addr = a; p0_rd = 1'b1;
      @(posedge clk); #1; p0_rd = 1'b0; cyc = 0;
      while (!p0_ok) begin @(posedge clk); #1; cyc = cyc + 1;
        if (cyc > 4000) begin $display("RESULT: FAIL - p0_read timeout @%h", a); $finish; end end
      q = p0_dout;
    end
  endtask

  // ---- ARGB4444 pack reference (mirrors fbram_to_sdram.sv pack_argb4444) ----
  function automatic [15:0] exp_argb(input [15:0] rgb565, input covered);
    begin
      exp_argb = {covered ? 4'hF : 4'h0, rgb565[15:12], rgb565[10:7], rgb565[4:1]};
    end
  endfunction

  localparam integer CELL_ROW_QW = 80;
  localparam integer STRIDE_QW   = 320;   // dungeon's stride (padded_w=1280)

  // dungeon plane bases (byte -> qword). Bake order: [0]=first .. [2]=last (invisible).
  localparam integer BASE0 = 32'h00A8_0000;   // 0x05400000  layer2 (first)
  localparam integer BASE1 = 32'h00AC_B000;   // 0x05658000  layer1 (mid)
  localparam integer BASE2 = 32'h00B1_6000;   // 0x058B0000  layer0 (last / reported invisible)

  // per-plane distinct colors so a readback proves plane identity (not aliasing).
  reg [15:0] TLC [0:2];
  reg [15:0] BRC [0:2];
  integer BASEQ [0:2];

  integer p, r, ci, errs, plane_cov_fail, plane_unc_fail;
  reg [63:0] got;
  reg [15:0] px, want;
  reg covered;
  integer rsamp [0:7];
  integer csamp [0:1];

  // bake one plane (cell 0) via the real per-cell sequence, at base BASEQ[p].
  task bake_plane(input integer p);
    begin
      // (1) clear coverage: full-cell FILL with BLT_F_BGCOV
      set_ctrl(2, 0);
      wr_fill_f(0, 16'd0, 16'd0, 16'd320, 16'd240, 16'h0000, 8'h80);
      mem[RINGB + 1*4] = 64'd1;   // END
      run_submit;
      // (2) paint TL + BR quadrants (normal FILL -> sets coverage)
      set_ctrl(3, 0);
      wr_fill_f(0, 16'd0,   16'd0,   16'd160, 16'd120, TLC[p], 8'h00);
      wr_fill_f(1, 16'd160, 16'd120, 16'd160, 16'd120, BRC[p], 8'h00);
      mem[RINGB + 2*4] = 64'd1;   // END
      run_submit;
      // (3) bake ARGB4444 at this plane's base (BLT_F_BGCOV -> bgw_argb4444)
      set_ctrl(2, 0);
      wr_bgw_f(0, BASEQ[p], STRIDE_QW[15:0], 8'h80);
      mem[RINGB + 1*4] = 64'd1;   // END
      run_submit;
    end
  endtask

  initial begin
    for (i = 0; i < MEMQW; i = i + 1) mem[i] = 64'd0;
    mem[32'h200000] = 64'd0; mem[32'h200005] = 64'd0;
    p0_addr = 27'd0; p0_rd = 1'b0; errs = 0;
    TLC[0]=16'h001F; BRC[0]=16'hFFE0;   // plane0 (first): blue / yellow
    TLC[1]=16'hF800; BRC[1]=16'h07E0;   // plane1 (mid):   red  / green
    TLC[2]=16'h0F0F; BRC[2]=16'hF0F0;   // plane2 (last):  distinct
    BASEQ[0]=BASE0; BASEQ[1]=BASE1; BASEQ[2]=BASE2;
    rsamp[0]=0; rsamp[1]=40; rsamp[2]=80; rsamp[3]=119;      // top half rows
    rsamp[4]=120; rsamp[5]=160; rsamp[6]=200; rsamp[7]=239;  // bottom half rows
    csamp[0]=0; csamp[1]=40;                                 // left (col<40) / right (col>=40)

    repeat (8) @(posedge clk); rst <= 0;
    begin : wait_init
      integer wi;
      for (wi = 0; wi < 30000; wi = wi + 1) begin @(posedge clk); if (!u_cache.init) disable wait_init; end
    end
    repeat (4) @(posedge clk);

    // ---- bake all THREE planes back-to-back, NO fabric reset between ----
    bake_plane(0);
    bake_plane(1);
    bake_plane(2);
    flush_to_sdram;

    // ---- read each plane back via ch5; assert covered=alpha0xF+color, uncovered=alpha0 ----
    for (p = 0; p < 3; p = p + 1) begin
      plane_cov_fail = 0; plane_unc_fail = 0;
      for (r = 0; r < 8; r = r + 1) begin
        for (ci = 0; ci < 2; ci = ci + 1) begin
          // read the qword at (row=rsamp[r], col=csamp[ci]) of this plane's cell 0
          p0_read((BASEQ[p] + rsamp[r]*STRIDE_QW + csamp[ci]) * 8, got);
          px = got[15:0];   // lane 0 of the qword (all 4 px in a qword share row/quadrant here)
          covered = (rsamp[r] < 120) ? (csamp[ci] < 40) : (csamp[ci] >= 40);
          want = covered ? exp_argb((rsamp[r] < 120) ? TLC[p] : BRC[p], 1'b1) : 16'h0000;
          if (covered) begin
            if (px[15:12] !== 4'hF || px !== want) begin
              if (plane_cov_fail < 4)
                $display("  plane%0d COVERED (r=%0d c=%0d): got=%h want=%h  (alpha nibble=%h)",
                         p, rsamp[r], csamp[ci], px, want, px[15:12]);
              plane_cov_fail = plane_cov_fail + 1;
            end
          end else begin
            if (px[15:12] !== 4'h0) begin
              if (plane_unc_fail < 4)
                $display("  plane%0d UNCOVERED (r=%0d c=%0d): got=%h want alpha=0", p, rsamp[r], csamp[ci], px);
              plane_unc_fail = plane_unc_fail + 1;
            end
          end
        end
      end
      $display("PLANE %0d @byte %h (%s): covered-fail=%0d uncovered-fail=%0d",
               p, BASEQ[p]*8,
               (p==0)?"first-baked":(p==2)?"LAST-baked (dungeon layer0, reported invisible)":"mid",
               plane_cov_fail, plane_unc_fail);
      errs = errs + plane_cov_fail + plane_unc_fail;
    end

    if (errs == 0) $display("RESULT: PASS");
    else           $display("RESULT: FAIL (%0d mismatches across 3 planes)", errs);
    $finish;
  end

  initial begin #80000000 $display("RESULT: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire
