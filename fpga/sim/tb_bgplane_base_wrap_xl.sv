// tb_bgplane_base_wrap_xl.sv — [#113, follow-up of #101] bgw_base wrap-overlap
// STRENGTHENING TB on the XL / 128 MiB layout (SDRAM_AW=25).
//
// WHAT #101 FIXED (fpga/rtl/blitter_top.sv ~1080-1111): the OP_BGPLANE_WRITE bake
// writes each cell qword at   plane_base(qword) + cell_relative_offset(qword).
//   base = bgw_base_qw          (24-bit absolute plane qword base, latched from the
//                                command header {c_dst_y,c_dst_x} at decode)
//   off  = bgw_sdram_wr_addr    (24-bit cell-relative offset from fbram_to_sdram:
//                                row*stride_qw + col, produced in strict qword order)
// The OLD code did a NATIVE 24-bit add (base + off) that SILENTLY DROPS the carry:
// an overflowing base WRAPS to a LOW SDRAM address (base+off mod 2^24) and stomps an
// unrelated region — the atlas / an adjacent plane down at the bottom of SDRAM. The
// fix widens the add to 25 bits and, on a bit-24 carry, CLAMPS to the top valid
// qword:  bgw_qw_sum  = {1'b0,base} + {1'b0,off};
//         bgw_qw_safe = bgw_qw_sum[24] ? 24'hFF_FFFF : bgw_qw_sum[23:0];
// The final byte write address on ch1 is {bgw_qw_safe, 3'b000}.
//
// HOW THIS TB CATCHES A DROPPED-CARRY REGRESSION. It configures the bake at a base
// near the TOP of the 24-bit qword space so a plain cell offset pushes the running
// sum past 0x00FF_FFFF, then OBSERVES the ACTUAL byte write address the bake presents
// on the ch1 STAGE port (stage_waddr_w == blitter_top.src_sdram_waddr) at the exact
// cycle each write is accepted, and — reading the live RTL base/offset — recomputes
// the widened sum itself. For every overflowing cell it HARD-ASSERTS the observed
// address is the CLAMPED top qword {24'hFF_FFFF,3'b000} and, CRITICALLY, that it is
// NOT the wrapped-LOW address ((base+off)[23:0]<<3) the old truncation would have
// produced — proving the write stays disjoint from the low-SDRAM atlas/adjacent
// plane. It also asserts the non-overflowing cells (base+off <= 0x00FF_FFFF) land at
// the EXACT untruncated sum, proving the 25-bit widening did not break the normal
// path. If the clamp were reverted to the native 24-bit add, the overflowing cells'
// observed address would collapse to the low wrapped value and BOTH the "==clamp" and
// "!=wrapped-low" assertions would fire.
//
// This is a DATAPATH test observed at the write port — NOT the #97 FABRIC_ASSERT SVA
// (that SVA fires on exactly the carry we intentionally drive, so this TB is built
// WITHOUT +define+FABRIC_ASSERT). No ch5 readback and no full 19200-qword bake are
// needed: the boundary is fully exercised within the first two cell rows, so PR mode
// early-finishes after observing those (fast). +define+BGPLANE_BASEWRAP_FULL runs a
// dedicated low-base normal bake plus the whole-cell wrap bake to completion.
//
// Harness (cache + 2 mt48 dies + blitter_top driving OP_BGPLANE_WRITE through the
// STAGE ch1 reroute) is lifted verbatim from tb_bgplane_write_pipe_xl.sv; the
// readback/quadrant machinery is dropped (addresses only).
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"

// [#113] This TB INTENTIONALLY drives an OP_BGPLANE_WRITE base whose cell offset
// carries out of the 24-bit qword space — exactly the input the #97 FABRIC_ASSERT
// SVA (`ifdef FABRIC_ASSERT in blitter_top.sv) flags with "FABRIC-ASSERT FAIL",
// which would trip run_sims.sh's FAIL regex. We are testing the DATAPATH clamp
// (bgw_qw_safe) observed at the ch1 write port, NOT the assert.
//
// run_sims.sh's NIGHTLY tier defines FABRIC_ASSERT GLOBALLY (TIER_DEFINES_FULL) for
// EVERY TB, and we cannot edit run_sims.sh. A plain `undef here does NOT reach
// blitter_top when it is pulled from the -y library (iverilog preprocesses -y files
// with only the command-line -D macros, not this file's `undef). So, ONLY when
// FABRIC_ASSERT is defined, we `undef it and then `include blitter_top.sv EXPLICITLY:
// it is then compiled in THIS translation unit with the SVA excluded, and because the
// module is now already defined, the -y search never re-loads (a would-be duplicate)
// it. This strips ONLY the sim-time assertion — never functional RTL — and lets the
// real wrap/clamp datapath test run in BOTH the pr and nightly tiers. In the pr tier
// (no FABRIC_ASSERT) blitter_top loads from -y as usual (the SVA is compiled out
// anyway), so this block is a no-op there.
`ifdef FABRIC_ASSERT
  `undef FABRIC_ASSERT
  `include "blitter_top.sv"
`endif

module tb_bgplane_base_wrap_xl;
  localparam [31:0] RINGB = 32'h200008;   // ring slot0 (window idx, 0x3B000040)
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h8000;

  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  // free-running vblank (matches write_pipe_xl; keeps the STAGE barrier machinery
  // happy even though this TB never reads back).
  reg vs = 0; integer vsc = 0;
  always @(posedge clk) begin
    vsc <= vsc + 1;
    if (vsc >= 256) begin vs <= ~vs; vsc <= 0; end
  end

  // ---- behavioral command-ring DDR (single-beat reads, latency + backpressure) ----
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

  // ---- on-chip dest framebuffer [FB-in-BRAM] ----
  wire fb_wr_en; wire [14:0] fb_wr_qw; wire [1:0] fb_wr_lane; wire [15:0] fb_wr_pix;
  wire fb_rd_en; wire [14:0] fb_rd_qw; wire [63:0] fb_rd_qword;
  comp_fbram fbram (.clk(clk),
    .wr_en(fb_wr_en), .wr_qw(fb_wr_qw), .wr_lane(fb_wr_lane), .wr_pix(fb_wr_pix),
    .rd_en(fb_rd_en), .rd_qw(fb_rd_qw), .rd_qword(fb_rd_qword));

  // ---- ch0 (P_DST, unused) + ch5 (P_SRC, tied off) + ch1 (STAGE, observed) ----
  wire        dst_wr;
  wire [26:0] dst_addr;
  wire [63:0] dst_din;
  wire [7:0]  dst_wdsn;
  wire        dst_ok;
  wire        coh_busy;

  reg  [26:0] p0_addr;   // ch5 P_SRC read address (tied off — no readback here)
  reg         p0_rd;
  wire [63:0] p0_dout;
  wire        p0_ok;

  wire [15:0] sdram_dq;
  wire [12:0] sdram_a;
  wire        sdram_dqml, sdram_dqmh;
  wire [1:0]  sdram_ba;
  wire        sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke, sdram_clk;

  // [bgplane bake -> STAGE reroute] blitter_top's STAGE (ch1) write outputs.
  // stage_waddr_w IS the observed write byte-address = {bgw_qw_safe, 3'b000}.
  wire        stage_we_burst_w;
  wire [63:0] stage_din64_w;
  wire [26:0] stage_waddr_w;
  wire        stage_ok_w;
  wire        stage_barrier_w;
  wire        stage_busy_w;

  sdram_fb_cache #(.SDRAM_AW(25)) u_cache (
    .clk(clk), .clk_sdram(clk), .rst(rst),
    .init(),
    .dst_addr(dst_addr), .dst_rd(1'b0), .dst_wr(dst_wr),
    .dst_din(dst_din), .dst_wdsn(dst_wdsn), .dst_dout(), .dst_ok(dst_ok),
    .scan_addr(27'd0), .scan_rd(1'b0), .scan_dout(), .scan_ok(),
    .p0_addr(p0_addr), .p0_rd(p0_rd), .p0_dout(p0_dout), .p0_ok(p0_ok),
    .stage_addr(stage_waddr_w), .stage_wr(stage_we_burst_w), .stage_din(stage_din64_w),
    .stage_wdsn(8'h00), .stage_ok(stage_ok_w),
    .vs(vs), .coh_busy(coh_busy),
    .stage_barrier(stage_barrier_w), .stage_busy(stage_busy_w),
    .dst_barrier(1'b0), .dst_busy(),
    .sdram_dq(sdram_dq), .sdram_a(sdram_a),
    .sdram_dqml(sdram_dqml), .sdram_dqmh(sdram_dqmh), .sdram_ba(sdram_ba),
    .sdram_nwe(sdram_nwe), .sdram_ncas(sdram_ncas), .sdram_nras(sdram_nras),
    .sdram_ncs(sdram_ncs), .sdram_cke(sdram_cke), .sdram_clk(sdram_clk)
  );

  // [XL 2-chip] MiSTer 128MB = 2 dies via sdram_ncs = cmd_cs ^ sel_chip. Verbatim
  // from tb_sdram_fb_cache_xl.sv / tb_bgplane_write_pipe_xl.sv.
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

  // ---- observation counters (updated by the write-address monitor + tasks) ----
  integer errors    = 0;
  integer obs_count = 0;   // accepted bake qwords seen
  integer cov_exact = 0;   // non-overflow cells landed at the exact untruncated sum
  integer cov_ovf   = 0;   // overflow cells clamped in-bounds (and NOT wrapped low)
  integer nreport   = 0;   // cap on printed mismatch lines

  // ---- command-ring helpers (mirror tb_bgplane_write_pipe_xl.sv) ----
  integer submit_n = 0;
  task set_ctrl(input integer ncmds, input integer flags);
    begin
      mem[32'h200001] = ncmds;
      mem[32'h200002] = 64'd0;      // target_buf=0
      mem[32'h200003] = 64'd0;      // clear_color
      mem[32'h200004] = flags;
      mem[32'h200007] = 64'd2;      // C_PIPE=1
    end
  endtask

  // OP_BGPLANE_WRITE: {dst_y,dst_x} = absolute plane qword base; src_x = stride_qw.
  task wr_bgw(input integer slot, input [31:0] base_qw, input [15:0] stride_qw);
    integer base;
    begin
      base = RINGB + slot*4;
      mem[base+0] = {32'd0, 8'd0, 8'd0, 8'd0, OP_BGPLANE_WRITE};
      mem[base+1] = {32'd0, stride_qw, 16'd0};
      mem[base+2] = {base_qw[31:16], base_qw[15:0], 32'd0};
      mem[base+3] = 64'd0;
    end
  endtask

  // Push a single OP_BGPLANE_WRITE + END into the ring and RAISE the submit — but do
  // NOT wait for the ack. The address monitor drives the (early) finish in PR mode.
  task launch_bgw(input [31:0] base_qw, input [15:0] stride_qw);
    begin
      set_ctrl(2, 0);
      wr_bgw(0, base_qw, stride_qw);
      mem[RINGB + 1*4] = 64'd1;   // END
      submit_n = submit_n + 1;
      mem[32'h200000] = submit_n;
    end
  endtask

  // Blocking submit (FULL mode only): wait for the bake's whole command list to ack.
  task run_bgw_full(input [31:0] base_qw, input [15:0] stride_qw);
    integer to;
    begin
      launch_bgw(base_qw, stride_qw);
      to = 0;
      while (mem[32'h200005][31:0] !== submit_n[31:0] && to < 8000000) begin @(posedge clk); to = to + 1; end
      if (mem[32'h200005][31:0] !== submit_n[31:0]) begin
        $display("  MISMATCH: full bake submit %0d never acked (to=%0d)", submit_n, to);
        errors = errors + 1;
      end
      repeat (10) @(posedge clk);
    end
  endtask

  // ======================================================================
  // Address configuration.
  //   STRIDE = 80 (= CELL_ROW_QW, contiguous) so cell row r, col c has relative
  //   offset off = r*80 + c; row 0 covers off 0..79.
  //
  //   BASE_WRAP = 0x00FF_FFC0 (16,777,152), 64 qwords below the 2^24 top. Row 0:
  //     cols 0..63  -> sum 0x00FFFFC0..0x00FFFFFF  = NO overflow -> exact untruncated
  //                    address (proves the widening did not break the normal path).
  //     cols 64..79 -> sum 0x01000000..0x0100000F  = bit-24 CARRY -> clamp to
  //                    0x00FFFFFF; the OLD 24-bit truncation would have wrapped these
  //                    to LOW qwords 0x000000..0x00000F (byte 0..0x78) — right on top
  //                    of the atlas at the bottom of SDRAM.
  //   Row 1 (off 80..159) is entirely past the top -> all clamp, giving many more
  //   overflow samples. Both regimes therefore appear inside the first two rows.
  //
  //   BASE_NORMAL = 0x0010_0000 (1 MiB qword, well inside range): FULL-mode normal
  //   bake where NO cell overflows across the whole 320x240 cell — a dedicated
  //   proof the ordinary path is bit-exact end to end.
  // ======================================================================
  localparam [31:0] BASE_WRAP   = 32'h00FF_FFC0;
  localparam [31:0] BASE_NORMAL = 32'h0010_0000;
  localparam [15:0] STRIDE      = 16'd80;
  localparam [23:0] TOP_QW      = 24'hFF_FFFF;    // top valid qword (clamp target)

`ifdef BGPLANE_BASEWRAP_FULL
  localparam integer OBS_TARGET = `FB_QWORDS;     // observe the whole cell
`else
  localparam integer OBS_TARGET = 200;            // 2.5 rows: covers both regimes, fast
`endif

  // ---- the WRITE-ADDRESS monitor ----------------------------------------
  // Fires once per accepted bake qword: bgw_active AND a STAGE write being accepted
  // (stage_we_burst_w && stage_ok_w) — the same {sdram_wr_en && consumer_ready}
  // retire condition fbram_to_sdram uses to advance its own wcnt, so exactly one
  // sample per qword, in strict order. Recomputes the widened add from the LIVE RTL
  // base/offset and checks the OBSERVED byte address against it.
  reg [23:0] m_base, m_off, m_obsqw, m_exp, m_low;
  reg [24:0] m_sum;
  reg [26:0] m_obsby;
  reg        m_ovf;
  // The check body is a task so its intentional blocking assignments (scratch
  // temporaries computed-then-read, and read-modify-write counters) stay out of
  // the clocked always — matching this TB's task-based idiom and the hdl-lint
  // "no blocking assignment in an edge-triggered always" rule.
  task check_waddr; begin
    begin
      m_base  = blt.bgw_base_qw;          // 24-bit absolute plane qword base
      m_off   = blt.bgw_sdram_wr_addr;    // 24-bit cell-relative offset
      m_obsby = stage_waddr_w;            // observed byte write address = {safe,3'b0}
      m_obsqw = m_obsby[26:3];            // observed qword
      m_sum   = {1'b0, m_base} + {1'b0, m_off};   // 25-bit widened add (the fix)
      m_ovf   = m_sum[24];                        // carry out of the 24-bit space
      m_exp   = m_ovf ? TOP_QW : m_sum[23:0];     // expected clamped/normal qword
      m_low   = m_sum[23:0];                      // OLD 24-bit truncation (wrapped)

      // (1) observed address must equal the widened/clamped datapath result.
      if (m_obsqw !== m_exp) begin
        if (nreport < 12) $display("  MISMATCH clamp: base=%h off=%h obs_qw=%h exp=%h (byte %h)",
                                   m_base, m_off, m_obsqw, m_exp, m_obsby);
        nreport = nreport + 1; errors = errors + 1;
      end
      // (2) in-bounds: never past the top valid qword (2^24-qword / 128 MiB space).
      if (m_obsqw > TOP_QW) begin
        if (nreport < 12) $display("  MISMATCH oob: base=%h off=%h obs_qw=%h past top", m_base, m_off, m_obsqw);
        nreport = nreport + 1; errors = errors + 1;
      end

      if (m_ovf) begin
        cov_ovf = cov_ovf + 1;
        // (3a) TEETH: must NOT be the LOW wrapped address the old truncation gives —
        // that value collides with the atlas/adjacent plane at the bottom of SDRAM.
        if (m_obsby === {m_low, 3'b000}) begin
          if (nreport < 12) $display("  MISMATCH wrap-low: base=%h off=%h obs byte=%h == old-truncation low addr (atlas stomp)",
                                     m_base, m_off, m_obsby);
          nreport = nreport + 1; errors = errors + 1;
        end
        // (3b) overflow cells clamp to the top qword.
        if (m_obsqw !== TOP_QW) begin
          if (nreport < 12) $display("  MISMATCH clamp-top: base=%h off=%h obs_qw=%h != top %h",
                                     m_base, m_off, m_obsqw, TOP_QW);
          nreport = nreport + 1; errors = errors + 1;
        end
      end else begin
        cov_exact = cov_exact + 1;
        // (4) non-overflow cells land at the EXACT untruncated sum (normal path intact).
        if (m_obsqw !== m_sum[23:0]) begin
          if (nreport < 12) $display("  MISMATCH exact: base=%h off=%h obs_qw=%h != sum %h",
                                     m_base, m_off, m_obsqw, m_sum[23:0]);
          nreport = nreport + 1; errors = errors + 1;
        end
      end
      obs_count = obs_count + 1;
    end
  end endtask

  always @(posedge clk)
    if (!rst && blt.bgw_active && stage_we_burst_w && stage_ok_w) check_waddr();

  initial begin
    for (i = 0; i < MEMQW; i = i + 1) mem[i] = 64'd0;
    mem[32'h200000] = 64'd0; mem[32'h200005] = 64'd0;
    p0_addr = 27'd0; p0_rd = 1'b0;

    repeat (8) @(posedge clk); rst <= 0;
    // wait for the cache's SDRAM init to complete
    begin : wait_init
      integer wi;
      for (wi = 0; wi < 30000; wi = wi + 1) begin
        @(posedge clk);
        if (!u_cache.init) disable wait_init;
      end
    end
    repeat (4) @(posedge clk);

`ifdef BGPLANE_BASEWRAP_FULL
    // FULL: dedicated whole-cell NORMAL bake (no overflow anywhere), then the whole-
    // cell WRAP bake (row 0 straddles the boundary, everything above wraps).
    $display("BGPLANE BASE-WRAP XL: FULL mode (whole-cell normal + wrap bakes)");
    run_bgw_full(BASE_NORMAL, STRIDE);
    run_bgw_full(BASE_WRAP,   STRIDE);
`else
    // PR: single WRAP bake, observed only until both regimes are covered (~2 rows),
    // then finish — no readback, no full 19200-qword drain.
    $display("BGPLANE BASE-WRAP XL: PR mode (wrap bake, observe %0d qwords)", OBS_TARGET);
    launch_bgw(BASE_WRAP, STRIDE);
    // wait until the monitor has observed enough accepted bake qwords
    begin : wait_obs
      integer wo;
      for (wo = 0; wo < 4000000; wo = wo + 1) begin
        @(posedge clk);
        if (obs_count >= OBS_TARGET) disable wait_obs;
      end
    end
`endif

    // ---- coverage: both regimes must actually have been exercised ----
    if (obs_count < 80) begin
      $display("  MISMATCH coverage: only %0d bake qwords observed (need >=80)", obs_count);
      errors = errors + 1;
    end
    if (cov_exact == 0) begin
      $display("  MISMATCH coverage: no non-overflow (exact-sum) cell observed");
      errors = errors + 1;
    end
    if (cov_ovf == 0) begin
      $display("  MISMATCH coverage: no overflow (clamped) cell observed — carry never driven");
      errors = errors + 1;
    end

    $display("BASE-WRAP XL: observed=%0d  exact(no-ovf)=%0d  clamped(ovf)=%0d  errors=%0d",
             obs_count, cov_exact, cov_ovf, errors);
    if (errors == 0) $display("RESULT: PASS");
    else             $display("RESULT: FAIL (%0d address mismatches)", errors);
    $finish;
  end

  initial begin #60000000 $display("RESULT: FAIL (watchdog/hang)"); $finish; end
endmodule
`default_nettype wire
