// tb_comp_overlap_pipe.sv — GATING regression: span N+1 P_SRC prefetch overlaps span N composite.
// Copyright (C) 2026 — GPL-3.0
//
// Drives an 8×8 source COPY blit (8 rows → 8 spans in one COMP_BAND_H=8 chunk).
// Asserts that for at least one consecutive span pair (N, N+1), the prefetch sub-FSM
// issues a p0_rd pulse while span N's lb_serve_req is still HIGH (span N compositing).
//
// Why this is meaningful (cannot trivially pass):
//   lb_serve_req is asserted only in P_PIXEL.  The prologue span-0 fill fires while
//   the main FSM is in P_PRO_WAIT (lb_serve_req=0), so that never triggers the check.
//   In a SEQUENTIAL design (fill-then-composite), every span N+1 prefetch would start
//   only after span N's drain, when the FSM is in P_ADVANCE / P_SPAN_BEGIN / P_DEC_RD*,
//   never P_PIXEL — so lb_serve_req=0 for every p0_rd rise and the assertion FAILS.
//   Co-assertion of p0_rd && lb_serve_req can ONLY happen via the Task-3c overlap path,
//   where P_DEC_RD2 kicks fill_start and transitions to P_PIXEL in the same clock:
//   one cycle later both p0_rd (prefetch F_IDLE → F_WALK) and lb_serve_req (first pixel
//   issue) become 1 simultaneously.
//
// Instruments (via hierarchical reference): dut.lb_serve_req (P_PIXEL per-pixel pulse)
// p0_rd is the module output connected in this TB as s_src_rd.
// fb_wr_en (output port) is wired directly.
//
// Pass criterion: saw_overlap=1 after the blit → RESULT: PASS.
// Fail criterion: every p0_rd rise has lb_serve_req=0 → RESULT: FAIL.
`timescale 1ns/1ps
`default_nettype none
`include "comp_defs.vh"
`include "blitter_defs.vh"

module tb_comp_overlap_pipe;
  localparam [15:0] BG = 16'h8410;

  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  // ── P_SRC behavioral model (rising-edge qualified, P_SRC_LAT-cycle latency) ──────
  // Mirrors tb_comp_pipeline.sv exactly: latch address on rising edge of p0_rd,
  // return the srcmem qword P_SRC_LAT cycles later via p0_ok.
  localparam P_SRC_LAT = 3;
  wire [26:0] s_src_addr;
  wire        s_src_rd;       // connected to comp_pipeline p0_rd (output)
  reg  [63:0] s_src_dout;
  reg         s_src_ok = 1'b0;
  reg  [63:0] srcmem   [0:1023];
  reg         s_rd_d;
  reg [26:0]  s_lat_addr [0:P_SRC_LAT-1];
  reg         s_lat_v    [0:P_SRC_LAT-1];
  integer     sli_k;

  always @(posedge clk) s_rd_d <= s_src_rd;
  always @(posedge clk) begin
    s_src_ok      <= 1'b0;
    s_lat_v[0]    <= s_src_rd & ~s_rd_d;   // rising-edge qualified
    s_lat_addr[0] <= s_src_addr;
    for (sli_k = 1; sli_k < P_SRC_LAT; sli_k = sli_k + 1) begin
      s_lat_v[sli_k]    <= s_lat_v[sli_k-1];
      s_lat_addr[sli_k] <= s_lat_addr[sli_k-1];
    end
    if (s_lat_v[P_SRC_LAT-1]) begin
      s_src_dout <= srcmem[s_lat_addr[P_SRC_LAT-1][12:3]];
      s_src_ok   <= 1'b1;
    end
  end

  // ── on-chip dest framebuffer ──────────────────────────────────────────────────────
  wire        fb_wr_en;
  wire [14:0] fb_wr_qw;
  wire  [1:0] fb_wr_lane;
  wire [15:0] fb_wr_pix;
  wire        fb_rd_en;
  wire [14:0] fb_rd_qw;
  wire [63:0] fb_rd_qword;

  comp_fbram fbram (
    .clk(clk),
    .wr_en(fb_wr_en), .wr_qw(fb_wr_qw), .wr_lane(fb_wr_lane), .wr_pix(fb_wr_pix),
    .rd_en(fb_rd_en), .rd_qw(fb_rd_qw), .rd_qword(fb_rd_qword));

  // ── comp_pipeline DUT ─────────────────────────────────────────────────────────────
  reg        blit_start = 0;
  reg        c_srcsel   = 1'b1;
  reg  [7:0] c_opcode, c_blend, c_format, c_flags, c_alpha;
  reg [31:0] c_src_off;
  reg [15:0] c_src_stride, c_src_x, c_src_y, c_w, c_h, c_colorkey, c_color;
  reg signed [15:0] c_dst_x, c_dst_y;
  reg [31:0] target_base;
  wire       blit_done;

  // mem_* (comp_pipeline ties these to 0 with FB-in-BRAM active; kept for port compat)
  wire [31:0] m_addr; wire m_rd, m_wr; wire [63:0] m_din; wire [7:0] m_be, m_bc;
  reg  [63:0] m_dout   = 64'd0;
  reg         m_dready = 1'b0;
  wire        m_busy   = 1'b0;

  comp_pipeline dut (
    .clk(clk), .rst(rst), .blit_start(blit_start),
    .c_opcode(c_opcode),   .c_blend(c_blend),         .c_format(c_format),
    .c_flags(c_flags),     .c_src_off(c_src_off),     .c_src_stride(c_src_stride),
    .c_src_x(c_src_x),    .c_src_y(c_src_y),
    .c_w(c_w),             .c_h(c_h),                 .c_colorkey(c_colorkey),
    .c_alpha(c_alpha),     .c_color(c_color),
    .c_dst_x(c_dst_x),    .c_dst_y(c_dst_y),         .target_base(target_base),
    .mem_addr(m_addr),     .mem_rd(m_rd),             .mem_wr(m_wr),
    .mem_burstcnt(m_bc),   .mem_din(m_din),           .mem_be(m_be),
    .mem_dout(m_dout),     .mem_dout_ready(m_dready), .mem_busy(m_busy),
    .c_srcsel(c_srcsel),
    .p0_addr(s_src_addr),  .p0_rd(s_src_rd),
    .p0_dout(s_src_dout),  .p0_ok(s_src_ok),
    .fb_wr_en(fb_wr_en),   .fb_wr_qw(fb_wr_qw),      .fb_wr_lane(fb_wr_lane),
    .fb_wr_pix(fb_wr_pix), .fb_rd_en(fb_rd_en),       .fb_rd_qw(fb_rd_qw),
    .fb_rd_qword(fb_rd_qword),
    .blit_done(blit_done));

  // ── cycle counter ──────────────────────────────────────────────────────────────────
  integer cyc;
  initial cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // ── overlap monitor ────────────────────────────────────────────────────────────────
  // Records the cycle of each lb_serve_req rising edge (= span composite opens) and
  // each p0_rd rising edge (= new P_SRC qword fetch starts).  At every p0_rd rise,
  // checks whether lb_serve_req is ALSO HIGH in that same cycle → fetch during composite.
  //
  // Per-event recording (capped at 32 of each for display):
  integer comp_start_cyc [0:31];   // lb_serve_req rise cycle per span composite start
  integer fetch_start_cyc [0:31];  // p0_rd rise cycle per P_SRC qword issued
  integer n_spans   = 0;           // span composites started (lb_serve_req rising edges)
  integer n_fetches = 0;           // P_SRC qword fetches started (p0_rd rising edges)
  integer saw_overlap   = 0;       // 1 if at least one co-assertion detected
  integer overlap_cyc   = 0;
  integer overlap_span  = 0;       // span_index (= n_spans-1) when first overlap fires
  integer overlap_fetch = 0;       // fetch_index when first overlap fires
  integer fail          = 0;

  reg prev_lb_serve = 0;
  reg prev_p0_rd    = 0;

  integer ki;
  initial begin
    for (ki = 0; ki < 32; ki = ki + 1) begin
      comp_start_cyc[ki]  = -1;
      fetch_start_cyc[ki] = -1;
    end
  end

  always @(posedge clk) begin
    if (!rst) begin

      // ── Rising edge of lb_serve_req: span N composite window opens ──────────────
      // lb_serve_req is an internal reg of comp_pipeline; accessed via hierarchy.
      if (dut.lb_serve_req && !prev_lb_serve) begin
        if (n_spans < 32) comp_start_cyc[n_spans] = cyc;
        $display("  [cyc %0d] span %0d composite OPEN (lb_serve_req rise)",
                 cyc, n_spans);
        n_spans = n_spans + 1;
      end
      prev_lb_serve = dut.lb_serve_req;

      // ── Rising edge of p0_rd: new P_SRC qword fetch starts ─────────────────────
      // s_src_rd is the module's p0_rd output wired into the TB.
      if (s_src_rd && !prev_p0_rd) begin
        if (n_fetches < 32) fetch_start_cyc[n_fetches] = cyc;

        if (dut.lb_serve_req) begin
          // *** OVERLAP DETECTED: p0_rd and lb_serve_req both HIGH same cycle ***
          // lb_serve_req=1 means the main FSM is in P_PIXEL compositing span N;
          // p0_rd=1 means the prefetch sub-FSM is issuing span N+1's source qword.
          // (By the time we reach this branch, n_spans was already incremented above
          //  if lb_serve_req rose this same cycle, so n_spans-1 is the compositing span.)
          $display("  [cyc %0d] *** OVERLAP *** fetch %0d (p0_rd rise) while span %0d lb_serve_req=1 (comp opened cyc %0d)",
                   cyc, n_fetches, n_spans-1, comp_start_cyc[n_spans-1]);
          if (!saw_overlap) begin
            overlap_cyc   = cyc;
            overlap_span  = n_spans - 1;
            overlap_fetch = n_fetches;
          end
          saw_overlap = 1;
        end else begin
          $display("  [cyc %0d] fetch %0d p0_rd rise, lb_serve_req=0 (prologue or no-overlap span)",
                   cyc, n_fetches);
        end
        n_fetches = n_fetches + 1;
      end
      prev_p0_rd = s_src_rd;

    end // !rst
  end

  // ── main stimulus ───────────────────────────────────────────────────────────────────
  integer x, y, i, to;

  initial begin
    // Source: 8×8 sprite, px(x,y) = 0x3000 + y*8 + x, stride 16B (2 qwords per row).
    // Row y occupies srcmem[y*2] and srcmem[y*2+1].
    for (i = 0; i < 1024; i = i + 1) srcmem[i] = 64'd0;
    for (y = 0; y < 8; y = y + 1)
      for (x = 0; x < 8; x = x + 1)
        srcmem[y*2 + (x>>2)][((x&3)*16) +: 16] = 16'h3000 + y*8 + x;

    // Framebuffer background
    for (i = 0; i < `FB_QWORDS; i = i + 1) begin
      fbram.bank0[i] = BG; fbram.bank1[i] = BG;
      fbram.bank2[i] = BG; fbram.bank3[i] = BG;
    end
    target_base = `FB0_QW;

    repeat(8) @(posedge clk); rst <= 0; repeat(2) @(posedge clk);

    // ── 8×8 COPY blit at dst (4,4): 8 rows → 8 spans (1 chunk with COMP_BAND_H=8). ──
    // Spans 0..6 each trigger an overlapping prefetch of the next span; span 7 is last
    // (no next span to prefetch).  We expect 7 overlap events (at least 1 is enough).
    c_opcode     = 8'd3;   c_blend     = 8'd0;  c_format = 8'd0;  c_flags = 8'd0;
    c_src_off    = 32'd0;  c_src_stride = 16'd16;  // 8 px × 2B = 16B/row
    c_src_x      = 16'd0;  c_src_y      = 16'd0;
    c_w          = 16'd8;  c_h          = 16'd8;
    c_colorkey   = 16'd0;  c_alpha      = 8'd0;   c_color = 16'd0;
    c_dst_x      = 16'd4;  c_dst_y      = 16'd4;

    @(posedge clk); blit_start <= 1'b1;
    @(posedge clk); blit_start <= 1'b0;
    to = 0;
    while (!blit_done && to < 100000) begin @(posedge clk); to = to + 1; end
    repeat(4) @(posedge clk);

    // ── result report ────────────────────────────────────────────────────────────────
    $display("blit complete: cycles=%0d  span-composites=%0d  p0_rd-edges=%0d",
             to, n_spans, n_fetches);
    $display("(8x8 COPY: 8 spans, COMP_BAND_H=8; expect 1 prologue + 7 overlap fetches)");

    if (!saw_overlap) begin
      $display("FAIL: no fetch/composite overlap observed");
      $display("  Every p0_rd rise saw lb_serve_req=0 -- sequential fill-then-composite.");
      $display("  The Task-3c overlap requires p0_rd and lb_serve_req HIGH in the same cycle,");
      $display("  which only happens when P_DEC_RD2 kicks the prefetch and transitions to P_PIXEL.");
      $display("  This assertion would FAIL on any regression to sequential per-span fills.");
      fail = 1;
    end else begin
      $display("PASS: overlap confirmed at cyc %0d", overlap_cyc);
      $display("  fetch %0d (p0_rd rise, cyc %0d) issued while span %0d lb_serve_req=1 (opened cyc %0d)",
               overlap_fetch, fetch_start_cyc[overlap_fetch],
               overlap_span,  comp_start_cyc[overlap_span]);
      $display("  => span %0d P_SRC prefetch (span %0d source) was concurrent with span %0d composite",
               overlap_span+1, overlap_span+1, overlap_span);
    end

    $display("RESULT: %s", fail ? "FAIL" : "PASS");
    $finish;
  end

  initial begin #10000000 $display("RESULT: FAIL (timeout)"); $finish; end

endmodule
`default_nettype wire
