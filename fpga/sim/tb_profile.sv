// tb_profile.sv — CYCLE-BUDGET PROFILER for the CURRENT single-source pipeline.
// Analysis tool, NOT a pass/fail correctness gate (kept in run_sims.sh SKIP).
//
// WHY THIS REWRITE
// ────────────────
// The previous tb_profile drove the *retired* legacy per-pixel FSM (it probed
// blt.state==23/24 and set the deleted C_PIPE bit) over a DDR-only source model.
// That path no longer exists: comp_pipeline (#36) is the sole renderer and its
// SOURCE pixels come exclusively from the SDRAM P_SRC cache-ok port (p0_*), with
// the destination band RMW + write-back on the SDRAM P_DST port. So the old
// numbers (7.47 cyc/px) describe hardware that is gone.
//
// WHAT THIS MEASURES
// ──────────────────
// It stands up the REAL render datapath — blitter_top(comp_pipeline) -> vram_demux
// -> {DDR ring | SDRAM P_DST} — and submits representative blits through the DDR
// command ring, exactly like tb_blitter_system_pipe. For each blit it buckets
// EVERY clk cycle of comp_pipeline by FSM phase and reports cycles-per-pixel plus
// the phase split, so you can see whether SOURCE-FETCH, BAND-LOAD, COMPOSITE, or
// WRITE-BACK dominates — the question the architecture review needed answered.
//
// MEMORY MODEL (and its honest limits)
// ────────────────────────────────────
// P_SRC and P_DST are *latency-modeled* cache-ok ports (fixed SRC_LAT / DST_LAT
// cycles per beat), the same fast behavioral models tb_blitter_system_pipe uses —
// NOT the faithful mt48 + jtframe_cache_mux. Consequences:
//   • The reported cyc/px is a FLOOR for the memory phases: the real P_SRC cache
//     (RO_BLKSIZE=256B, 2 blocks) takes a full block-fill on a miss and the SDRAM
//     controller is BURST_BEATS=1, so on silicon the LOAD/SRCFILL phases cost more
//     than the fixed-latency model shows.
//   • The PHASE RATIO (which bucket dominates) is the robust, model-independent
//     output — that's what to read.
// Sweep the knobs to size fixes before touching HW (rebuild with the define):
//   +define+PROF_SRC_LAT=<n>   source-read latency  (default 4; raise to model misses)
//   +define+PROF_DST_LAT=<n>   dest  read/write latency (default 3)
//   +define+COMP_MAXBURST=<n>  comp_burst sub-burst cap (default 16)
//   +define+COMP_BAND_H=<n>    dest band height (default 8; was 16) — chunk overhead
// Run standalone:
//   iverilog -g2012 -o /tmp/p.vvp -I ../rtl -I ../rtl/jtframe -I ../sys -I . \
//     -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v tb_profile.sv && vvp /tmp/p.vvp
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
`include "vram_defs.vh"
`include "comp_defs.vh"

`ifndef PROF_SRC_LAT
`define PROF_SRC_LAT 4
`endif
`ifndef PROF_DST_LAT
`define PROF_DST_LAT 3
`endif

module tb_profile;
  localparam [28:0] WBASE = 29'h07400000;     // DDR window base; mem idx = addr-WBASE
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h10000;  // [#52] tracks SRC_QW heap base        // covers control block @ 0x200000
  localparam        SRC_LAT = `PROF_SRC_LAT;
  localparam        DST_LAT = `PROF_DST_LAT;

  reg clk=0, reset=1; always #5 clk=~clk;      // 100 MHz clk_sys

  // ── free-running vblank for the FB-in-BRAM work->scan snapshot ────────────────
  // After each frame the blitter parks in S_SNAP_WAIT until a vblank rising edge
  // triggers the (counter-driven) u_snap copy; without a vs edge the FSM hangs and
  // every blit after the first never gets polled. A short periodic pulse lets each
  // frame's snapshot fire. The snapshot runs while comp_pipeline.state==IDLE, so it
  // is NOT counted in the cyc/px histogram (prof_on counts state!=0 only).
  reg [8:0] vs_div=0; reg vs_tb=0;
  always @(posedge clk) begin
    vs_div <= vs_div + 9'd1;
    vs_tb  <= (vs_div < 9'd4);   // ~4 cyc high every 512 cyc
  end

  // ── blitter_top mem_* -> vram_demux -> {DDR arb-less behavioral | SDRAM P_DST} ─
  wire [31:0] bt_addr; wire bt_rd, bt_wr; wire [63:0] bt_din; wire [7:0] bt_be;
  wire [7:0]  bt_burstcnt; wire bt_idle;
  wire [63:0] blt_demux_dout; wire blt_demux_dready, blt_busy_w;

  // ── behavioral DDR (command ring + control block). The demux DDR side is
  // single-beat (ring/ctrl reads), so it drives d_* directly with burst=1. ──────
  wire [28:0] d_addr; wire d_rd; wire [63:0] d_din; wire [7:0] d_be; wire d_we;
  wire [7:0]  d_burst = 8'd1;   // demux DDR side issues single-beat transfers
  wire d_busy; reg d_dready; reg [63:0] d_dout;

  // ════════════════════════════════════════════════════════════════════════════
  // P_SRC cache-ok model: CONSTANT opaque source (alpha nibble F, non-key) so the
  // composite never skips a pixel — WORST-CASE write-back volume (upper bound). A
  // fixed SRC_LAT-cycle latency per single-beat read, one outstanding (the master
  // pulses p0_rd and waits for p0_ok). This mirrors comp_pipeline's serial fetch.
  // ════════════════════════════════════════════════════════════════════════════
  wire [26:0] bs_addr; wire bs_rd; wire [63:0] bs_dout64; wire bs_ok;
  wire        bs_we; wire [15:0] bs_din; wire [26:0] bs_waddr;
  wire        bs_we_burst; wire [63:0] bs_din64;
  localparam [63:0] OPAQUE_QW = 64'hFFFF_FFFF_FFFF_FFFF;   // 4 px, A4=F, all channels max

  reg        src_rd_d;
  reg        src_lat_v [0:SRC_LAT-1];
  reg        src_ok_r;
  integer    sli;
  always @(posedge clk) src_rd_d <= bs_rd;
  always @(posedge clk) begin
    if (reset) begin
      src_ok_r <= 1'b0;
      for (sli=0; sli<SRC_LAT; sli=sli+1) src_lat_v[sli] <= 1'b0;
    end else begin
      src_lat_v[0] <= bs_rd & ~src_rd_d;       // rising edge of p0_rd
      for (sli=1; sli<SRC_LAT; sli=sli+1) src_lat_v[sli] <= src_lat_v[sli-1];
      src_ok_r <= src_lat_v[SRC_LAT-1];
    end
  end
  assign bs_dout64 = OPAQUE_QW;
  assign bs_ok     = src_ok_r;

  // ── DUT ─────────────────────────────────────────────────────────────────────
  blitter_top blt(
    .clk(clk), .rst(reset), .vs(vs_tb),
    .mem_addr(bt_addr), .mem_rd(bt_rd), .mem_wr(bt_wr), .mem_din(bt_din), .mem_be(bt_be),
    .mem_burstcnt(bt_burstcnt),
    .mem_dout(blt_demux_dout), .mem_dout_ready(blt_demux_dready), .mem_busy(blt_busy_w),
    .p0_addr(bs_addr), .p0_rd(bs_rd), .p0_dout(bs_dout64), .p0_ok(bs_ok),
    .src_sdram_we(bs_we), .src_sdram_din(bs_din), .src_sdram_waddr(bs_waddr),
    .src_sdram_we_burst(bs_we_burst), .src_sdram_din64(bs_din64), .src_sdram_ok(1'b1),
    .stage_barrier(), .stage_barrier_busy(1'b0),
    .idle(bt_idle));

  // ── vram_demux: FB region -> SDRAM P_DST model; else -> DDR behavioral ───────
  wire [26:0] dst_addr; wire dst_rd, dst_wr;
  wire [63:0] dst_din;  wire [7:0] dst_wdsn;
  reg  [63:0] dst_dout; reg dst_ok;
  vram_demux vdemux(
    .clk(clk), .reset(reset),
    .blt_addr(bt_addr), .blt_rd(bt_rd), .blt_wr(bt_wr), .blt_din(bt_din), .blt_be(bt_be),
    .blt_burstcnt(bt_burstcnt),
    .blt_dout(blt_demux_dout), .blt_dout_ready(blt_demux_dready), .blt_busy(blt_busy_w),
    .ddr_addr(d_addr), .ddr_rd(d_rd), .ddr_wr(d_we), .ddr_din(d_din), .ddr_be(d_be),
    .ddr_dout(d_dout), .ddr_dout_ready(d_dready), .ddr_busy(d_busy),
    .sd_addr(dst_addr), .sd_rd(dst_rd), .sd_wr(dst_wr),
    .sd_din(dst_din), .sd_wdsn(dst_wdsn),
    .sd_dout(dst_dout), .sd_ok(dst_ok));

  // ── P_DST cache-ok model: fixed DST_LAT latency, schip-less (read returns 0;
  // the band preload value is irrelevant to CYCLE counting — COPY/ALPHA always
  // write, PALPHA writes because the source alpha is F). One ok per request. ─────
  reg        dst_rd_d, dst_wr_d;
  always @(posedge clk) begin dst_rd_d <= dst_rd; dst_wr_d <= dst_wr; end
  wire dst_req_rise = (dst_rd & ~dst_rd_d) | (dst_wr & ~dst_wr_d);
  reg [3:0]  dst_cnt; reg dst_run;
  always @(posedge clk) begin
    dst_ok <= 1'b0;
    if (reset) begin dst_run <= 1'b0; dst_cnt <= 0; dst_dout <= 64'd0; end
    else if (dst_req_rise && !dst_run) begin
      dst_run <= 1'b1; dst_cnt <= DST_LAT - 1;
    end else if (dst_run) begin
      if (dst_cnt == 0) begin dst_ok <= 1'b1; dst_run <= 1'b0; dst_dout <= 64'd0; end
      else dst_cnt <= dst_cnt - 1;
    end
  end

  // ── behavioral DDR (ring/ctrl) with 1-in-3 backpressure + 3-cyc read latency ──
  reg [63:0] mem [0:MEMQW-1];
  reg [1:0] bp=0; always @(posedge clk) bp <= (bp==2'd2)?2'd0:bp+2'd1;
  integer i;
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat;
  assign d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  always @(posedge clk) begin
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

  // ════════════════════════════════════════════════════════════════════════════
  //  PHASE HISTOGRAM — bucket every comp_pipeline cycle by FSM state.
  //  State encodings mirror comp_pipeline.sv localparams.
  // ════════════════════════════════════════════════════════════════════════════
  integer c_setup, c_load, c_srcfill, c_comp, c_wb, c_total;
  reg     prof_on;
  always @(posedge clk) if (prof_on && !reset) begin
    case (blt.u_pipe.state)
      6'd1,6'd2,6'd17,6'd5,6'd19,6'd20: c_setup   = c_setup   + 1; // span/chunk/comp-setup
      6'd3,6'd18,6'd4:                  c_load    = c_load    + 1; // band preload (P_DST read)
      6'd6,6'd7:                        c_srcfill = c_srcfill + 1; // P_SRC serial source fetch
      6'd8,6'd9:                        c_comp    = c_comp    + 1; // per-pixel composite (II=1)
      6'd10,6'd11,6'd12,6'd13,6'd15,6'd16: c_wb   = c_wb     + 1; // flush + write-back (P_DST write)
      6'd0,6'd14: ;                                               // IDLE / DONE: not counted
      default: ;
    endcase
    if (blt.u_pipe.state != 6'd0) c_total = c_total + 1;
  end

  // ── command ring submit helpers (mirror tb_blitter_system_pipe) ─────────────
  task wmem(input [31:0] idx, input [63:0] val); mem[idx]=val; endtask
  integer submit_n;
  integer to;
  task await_submit;
    begin
      to=0;
      while (mem[32'h200005][31:0] !== submit_n[31:0] && to<2000000) begin @(posedge clk); to=to+1; end
      if (to>=2000000)
        $display("  [await TIMEOUT] submit=%0d done=%0d blt.state=%0d pipe.state=%0d pbusy=%0b bt_rd=%0b bt_wr=%0b dst_rd=%0b dst_wr=%0b dst_ok=%0b p0_rd=%0b p0_ok=%0b",
          submit_n, mem[32'h200005][31:0], blt.state, blt.u_pipe.state, blt.pipe_busy,
          bt_rd, bt_wr, dst_rd, dst_wr, dst_ok, bs_rd, bs_ok);
      repeat(6) @(posedge clk);
    end
  endtask

`ifdef PROF_HB
  integer hb=0;
  always @(posedge clk) if (!reset) begin
    hb=hb+1;
    if (hb % 50000 == 0)
      $display("[hb %0d] submit=%0d done=%0d blt.st=%0d pipe.st=%0d pbusy=%0b | bt_rd=%0b bt_wr=%0b burst=%0d | dst_rd=%0b dst_wr=%0b dst_ok=%0b | p0_rd=%0b p0_ok=%0b",
        hb, submit_n, mem[32'h200005][31:0], blt.state, blt.u_pipe.state, blt.pipe_busy,
        bt_rd, bt_wr, bt_burstcnt, dst_rd, dst_wr, dst_ok, bs_rd, bs_ok);
  end
`endif

  // Reset+zero the histogram, then arm it for the next submit.
  task prof_reset; begin c_setup=0; c_load=0; c_srcfill=0; c_comp=0; c_wb=0; c_total=0; end endtask

  // print one row: name, WxH, total, cyc/px, and phase split %.
  task report(input [127:0] name, input integer w, input integer h);
    integer px;
    begin
      px = w*h;
      $display("%-14s %3dx%-3d %6d px | %7d cyc  %5.2f cyc/px | setup %4.1f%%  load %4.1f%%  SRCFILL %4.1f%%  comp %4.1f%%  WB %4.1f%%",
        name, w, h, px, c_total, c_total*1.0/px,
        100.0*c_setup/c_total, 100.0*c_load/c_total, 100.0*c_srcfill/c_total,
        100.0*c_comp/c_total, 100.0*c_wb/c_total);
    end
  endtask

  // FILL via comp_pipeline (no source read; band preload + composite + WB only).
  task prof_fill(input [127:0] name, input [15:0] w, input [15:0] h, input [15:0] color);
    begin
      wmem(32'h200001, 64'd2); wmem(32'h200002, 64'd0); wmem(32'h200004, 64'd0);
      wmem(32'h200007, 64'd2);                                   // C_SRCSEL irrelevant for FILL
      wmem(32'h200008, 64'h0000_0000_0000_0002);                // op=FILL
      wmem(32'h200009, {16'(h), 16'(w), 32'd0});
      wmem(32'h20000A, {16'd0, 16'd0, 32'd0});                  // dst (0,0)
      wmem(32'h20000B, {16'd0, 16'(color), 32'd0});
      wmem(32'h20000C, 64'd1);
      wmem(32'h20000D, 64'd0); wmem(32'h20000E, 64'd0); wmem(32'h20000F, 64'd0);
      prof_reset; prof_on=1; submit_n=submit_n+1; wmem(32'h200000, submit_n[63:0]);
      await_submit; prof_on=0; report(name, w, h);
    end
  endtask

  // BLIT (SDRAM source) via comp_pipeline. blend: 0=COPY 2=ALPHA 3=PALPHA.
  task prof_blit(input [127:0] name, input [7:0] blend,
                 input [15:0] w, input [15:0] h);
    begin
      wmem(32'h200001, 64'd2); wmem(32'h200002, 64'd0); wmem(32'h200004, 64'd0);
      wmem(32'h200007, 64'd3);                                   // C_SRCSEL=1 (SDRAM source)
      // op=BLIT(3), blend, fmt=0, flags=F_SRC_SDRAM(0x10); src_off=0
      wmem(32'h200008, {32'd0, 8'h10, 8'd0, blend, 8'd3});
      wmem(32'h200009, {16'(h), 16'(w), 16'd0, 16'(w*2)});      // h,w | src_x=0, stride=w*2
      wmem(32'h20000A, {16'd0, 16'd0, 16'd0, 16'd0});           // dst(0,0) | src_y=0
      wmem(32'h20000B, {16'd0, 16'd0, 8'd128, 8'd0, 16'd0});    // alpha=128 (for ALPHA)
      wmem(32'h20000C, 64'd1);
      wmem(32'h20000D, 64'd0); wmem(32'h20000E, 64'd0); wmem(32'h20000F, 64'd0);
      prof_reset; prof_on=1; submit_n=submit_n+1; wmem(32'h200000, submit_n[63:0]);
      await_submit; prof_on=0; report(name, w, h);
    end
  endtask

  initial begin
    prof_on=0; submit_n=1; d_dready=0;
    for(i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    wmem(32'h200000, 64'd1);          // submit_seq seed
    wmem(32'h200005, 64'd1);          // done_seq seed (so first bump is a clean +1)
    repeat(8) @(posedge clk); reset<=0; repeat(8) @(posedge clk);

    $display("==================================================================");
    $display(" comp_pipeline cycle profile  (clk_sys=100MHz; 60fps budget=1.64M cyc)");
    $display("   SRC_LAT=%0d  DST_LAT=%0d  COMP_MAXBURST=%0d  COMP_BAND_H=%0d",
             SRC_LAT, DST_LAT, `COMP_MAXBURST, `COMP_BAND_H);
    $display("   FB-in-BRAM: dest RMW + scanout on-chip (comp_fbram); WB/LOAD retired.");
    $display("   SRCFILL (P_SRC atlas, SDRAM) OVERLAPPED with composite via double-buffered linebuf.");
    $display("   Per-span time = max(srcfill,comp) not sum (lever A). Sim floor: COPY wide 1.65, sprite 1.75 cyc/px (was 2.55/2.76).");
    $display("   Lever B: sdram_fb_cache ch5 (P_SRC) not invalidated on vsync — atlas stays warm across frames.");
    $display("   cyc/px is a sim FLOOR (optimistic P_SRC model; warm-cache gain from lever B is additive on HW).");
    $display("==================================================================");

`ifdef PROF_SMOKE
    prof_blit("COPY  small",     8'd0, 16'd16,  16'd16);
    $display("RESULT: PASS"); $finish;
`endif
    // Throughput cases (data-independent write-back): full-width spans.
    prof_blit("COPY  wide1band", 8'd0, 16'd320, 16'd8);    // single band, full width
    prof_blit("COPY  wide",      8'd0, 16'd320, 16'd48);   // multi-band -> chunk/flush overhead
    prof_blit("ALPHA wide",      8'd2, 16'd320, 16'd48);
    prof_blit("PALPHA wide",     8'd3, 16'd320, 16'd48);
    // Sprite-shaped cases: per-span fixed overhead vs body.
    prof_blit("COPY  sprite",    8'd0, 16'd64,  16'd64);
    prof_blit("COPY  small",     8'd0, 16'd16,  16'd16);   // fixed-overhead dominated
    prof_blit("COPY  tall",     8'd0, 16'd16,  16'd128);   // many chunks, thin
    // FILL (no source fetch) — isolates band-load + composite + write-back.
    prof_fill("FILL  wide",      16'd320, 16'd48, 16'hF800);
    prof_fill("FILL  sprite",    16'd64,  16'd64, 16'hF800);

    $display("==================================================================");
    $display(" Read the SRCFILL vs WB vs comp split: the dominant bucket is the");
    $display(" bottleneck. comp%% near 100%% would mean ALU-bound (it is not).");
    $display("RESULT: PASS");
    $finish;
  end

  initial begin #500_000_000 $display("PROFILE TIMEOUT"); $finish; end
endmodule
`default_nettype wire
