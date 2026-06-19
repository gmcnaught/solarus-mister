// tb_blitter_rd_desync.sv — directed reproduction of the #34 blitter read-ISSUE
// desync (the bug the 2026-06-18 HW probe re-grounded).
//
// HW fingerprint (commit 66f852b / RBF 618g, mystery quest):
//   frame_ctr 0x3A000000 = 0 (blitter not completing),
//   probe_st  0x3A070004 -> blitter S_RD_WAIT (state 23) + rd_issued=1,
//                           demux S_IDLE (st 0) + rd_on_sdram=0 + dst_busy=0,
//   capt_diag 0x3A07000C -> missed_ever=0, dst_dready beats FROZEN.
// i.e. the blitter is parked in S_RD_WAIT waiting for a read the demux NEVER
// issued — it mis-read a blt_busy=0 (a PRIOR txn completing) as ITS read being
// accepted (S_RD_WAIT: rd_issued<=1 on !mem_busy), advanced, and the demux went
// back to S_IDLE without ever forwarding the read. Shared-blt_busy desync.
//
// WHY EXISTING SIMS MISS IT:
//   - tb_vram_contention runs the REAL blitter blend dst-RMW under 3-client
//     contention but with the real reader's FIXED scan cadence -> never lands a
//     SCAN grant on the write-complete -> read-issue seam.
//   - tb_capture_race phase-SWEEPS the SCAN/DST alignment but with a MINI-blitter
//     that only does reads (no real write-then-read pipeline).
// This tb is the INTERSECTION: the REAL blitter_top (real S_WR_WAIT -> write
// completes -> S_DST_RDISS -> S_RD_WAIT pipeline, blend RMW into an SDRAM FB)
// + a PHASE-SWEPT bursty SCAN preemptor on sdram_src_arb.scan_* (from
// tb_capture_race) so the SCAN grant drifts across the seam every blend qword.
//
// Datapath mirrors Solarus.sv exactly (real blitter_top + vram_demux +
// ddr_blitter_arb + sdram_src_arb + sdram_psx + chip; behavioral DDR3 for the
// control block / ring / staging source). The reader is dropped — SCAN is the
// synthetic preemptor (we only need its arbiter preemption, not pixels).
//
// VERDICT: a healthy (fixed) RTL keeps the blitter COMPLETING blend frames
// (done_seq advances). The UNFIXED RTL parks in the S_RD_WAIT fingerprint and
// the watchdog fires -> RESULT: WEDGE = the reproduction. Re-run as a gating
// test once it passes post-fix.
//
// Build: default = zero-delay sdram_chip_model; -DUSE_MICRON = mt48lc16m16a2.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
`include "vram_defs.vh"

module tb_blitter_rd_desync;
  localparam [28:0] WBASE = 29'h07400000;     // DDR window base; mem idx = addr-WBASE
  localparam        MEMQW = 32'h202000;        // covers control block @ 0x200000

  reg clk_sys = 0; always #5 clk_sys = ~clk_sys;   // 100 MHz
  reg reset = 1;

  // ---- behavioral DDR3 bus nets --------------------------------------------
  wire [7:0] d_burst; wire [28:0] d_addr; wire d_rd; wire [63:0] d_din;
  wire [7:0] d_be;    wire d_we;
  wire       d_busy;  reg d_dready = 0; reg [63:0] d_dout = 0;
  wire [31:0] blt_dbg;
  wire [3:0]  vdemux_dbg;

  // ---- SCAN preemptor port (phase-swept; drives sdram_src_arb.scan_*) -------
  reg  [26:0] scan_addr = 27'h0400000;
  reg         scan_rd   = 0;
  wire        scan_busy; wire [63:0] scan_dout64; wire scan_dready;

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

  // ================= DDR blitter arbiter (rdr tied off — no reader) ==========
  wire rdr_busy_w, rdr_grant_w;
  ddr_blitter_arb #(.ENABLE(1'b1)) arb_ddr (
    .clk(clk_sys), .reset(reset),
    .rdr_burstcnt(8'd0), .rdr_addr(29'd0), .rdr_rd(1'b0), .rdr_din(64'd0),
    .rdr_be(8'd0), .rdr_we(1'b0), .rdr_busy(rdr_busy_w), .rdr_grant(rdr_grant_w),
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
  wire [15:0] SDQ; wire [12:0] SA; wire SDQML, SDQMH; wire [1:0] SBA;
  wire        SnCS, SnWE, SnRAS, SnCAS, SCLK, SCKE;

  sdram_src_arb src_arb (
    .clk(clk_sys), .reset(reset),
    // P_SCAN: the synthetic phase-swept preemptor
    .scan_addr(scan_addr), .scan_rd(scan_rd), .scan_burst(8'd1),
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
  mt48lc16m16a2 schip (
    .Dq(SDQ), .Addr(SA), .Ba(SBA), .Clk(SCLK), .Cke(SCKE),
    .Cs_n(SnCS), .Ras_n(SnRAS), .Cas_n(SnCAS), .We_n(SnWE), .Dqm({SDQMH, SDQML}),
    .downloading(1'b0), .VS(1'b0), .frame_cnt(32'd0));
`else
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

  // ================= command-list builder (blend dst-RMW frame) =============
  task wmem(input [31:0] idx, input [63:0] val); mem[idx]=val; endtask

  // Program ONE frame: STAGE 8KiB DDR->SDRAM (P_SRC burst-writes) + a full-screen
  // BLEND_ALPHA blit (op=3, blend=2, F_SRC_SDRAM, src=FB1). The blend does a dst
  // READ-MODIFY-WRITE per coalesced qword: dst-READ FB0 (P_DST via S_DST_RDISS ->
  // S_RD_WAIT) then dst-WRITE FB0 -> a write-then-read seam at every qword. 3
  // clients: SCAN (preemptor) + SRC (staging/source) + DST (the RMW). Verbatim
  // from tb_vram_contention's proven builder.
  integer submit_n = 0;
  reg [7:0] throttle_val = 8'd0;   // swept per frame by the stimulus
  task submit_blend_frame;
    begin
      wmem(32'h200002, 64'd0);          // target_buf = 0 (BUF0 -> SDRAM FB0)
      wmem(32'h200004, 64'd0);          // flags = 0 (no CLEAR)
      // C_SRCSEL[0]=1 (SDRAM src), C_SRCSEL[15:8]=throttle_cfg. HW runs THROTTLED
      // (idle cycles after each accepted write) — the S_WR_THROTTLE bus-idle window
      // reshapes the write->read seam and lets the arbiter re-arbitrate to SCAN
      // mid-seam. Swept via THROTTLE param to cover seam alignments.
      wmem(32'h200007, {48'd0, throttle_val, 8'h01});
      wmem(32'h200001, 64'd3);          // cmd_count = 3 (STAGE + BLEND + END)
      // cmd0 STAGE op=4: copy 8 KiB DDR3->SDRAM at off 0x100000 (P_SRC burst-writes)
      wmem(32'h200008, {32'h0010_0000, 32'h0000_0004});
      wmem(32'h200009, {16'd0, 16'd8192, 32'd0});
      wmem(32'h20000A, 64'd0);
      wmem(32'h20000B, 64'd0);
      // cmd1 BLEND_ALPHA op=3 blend=2 flags=F_SRC_SDRAM(0x10) src_off=0x440000(FB1)
      // NARROW, ODD-OFFSET blit so EVERY row is a PARTIAL-qword dst write (demux
      // S_WWAIT, the unguarded blt_busy=0 drain) immediately followed by the next
      // row's dst READ — the write-then-read seam that triggers the rd-issue desync.
      // (A full 320-wide aligned blit is almost all FULL-qword writes = S_BWAIT,
      // which IS guarded, so it never exercises the bug — why prior sims passed.)
      wmem(32'h20000C, {32'h0044_0000, {8'h10, 8'h02, 8'h00, 8'h03}});
      wmem(32'h20000D, {16'd240, 16'd6, 16'd0, 16'd640});    // h=240 w=6 (PARTIAL) stride=640
      wmem(32'h20000E, {16'd0, 16'd1, 16'd0, 16'd0});        // dst_y=0 dst_x=1 (odd -> unaligned)
      wmem(32'h20000F, 64'h0000_0000_0080_0000);             // c_alpha = 0x80
      wmem(32'h200010, 64'd1);          // cmd2 = END
      wmem(32'h200011, 64'd0); wmem(32'h200012, 64'd0); wmem(32'h200013, 64'd0);
      submit_n = submit_n + 1;
      wmem(32'h200000, submit_n[63:0]); // bump submit -> blitter composites a frame
    end
  endtask

  wire [31:0] done_seq = mem[32'h200005][31:0];

  // ================= PHASE-SWEPT bursty SCAN preemptor ======================
  // A LINE of LINE_BEATS back-to-back single-beat reads (re-issued per beat,
  // holding scan_rd until each dready), then an inter-line GAP. The gap length
  // DRIFTS (gap_phase) so the SCAN grant slides across the blitter's write-
  // complete -> read-issue seam every line — exercising every collision phase.
  localparam integer LINE_BEATS = 80;
  localparam [1:0] SC_REQ=2'd0, SC_WAIT=2'd1, SC_GAP=2'd2;
  reg [1:0] scst = SC_REQ;
  reg [6:0] sc_beats = 0;
  reg [9:0] sc_gapc  = 0;
  reg [5:0] gap_phase = 0;     // drifts 0..47, the swept alignment knob
  always @(posedge clk_sys) begin
    if (reset) begin
      scst <= SC_REQ; scan_rd <= 0; sc_beats <= 0; sc_gapc <= 0;
      scan_addr <= 27'h0400000; gap_phase <= 0;
    end else case (scst)
      SC_REQ: if (!scan_busy) begin scan_rd <= 1'b1; scst <= SC_WAIT; end
      SC_WAIT: begin
        scan_rd <= 1'b1;
        if (scan_dready) begin
          scan_rd   <= 1'b0;
          scan_addr <= scan_addr + 27'h8;
          if (sc_beats + 7'd1 >= LINE_BEATS[6:0]) begin
            sc_beats  <= 7'd0;
            sc_gapc   <= {4'd0, gap_phase};               // drifting gap
            gap_phase <= (gap_phase == 6'd47) ? 6'd0 : gap_phase + 6'd1;
            scan_addr <= 27'h0400000;
            scst      <= SC_GAP;
          end else begin
            sc_beats <= sc_beats + 7'd1;
            scst     <= SC_REQ;
          end
        end
      end
      SC_GAP: begin
        scan_rd <= 1'b0;
        if (sc_gapc == 0) scst <= SC_REQ; else sc_gapc <= sc_gapc - 10'd1;
      end
    endcase
  end

  // ================= fingerprint detector + wedge watchdog ==================
  // EXACT desync fingerprint: blitter parked in S_RD_WAIT having latched rd_issued
  // AND dropped mem_rd (bt_rd=0), while the demux sits in S_IDLE and is NOT busy
  // (blt_busy=0) — so the read can never be issued nor completed. This is the
  // shared-blt_busy mis-latch during the demux's S_WWAIT partial-write drain.
  localparam [5:0] BLT_S_RD_WAIT = 6'd23;
  localparam [2:0] DMX_S_IDLE    = 3'd0;
  wire fp_hit = (blt.state == BLT_S_RD_WAIT) && blt.rd_issued && !bt_rd
              && (vdemux.st == DMX_S_IDLE) && !blt_busy_w;
  integer fp_cnt = 0;

  // generic progress watchdog (blitter must keep completing blend frames)
  parameter integer STALL_LIMIT = 2_000_000;   // ~20 ms @ 100 MHz
  integer prog_q = -1, stall = 0, cur_prog;

  task dump_state(input [255:0] tag);
    begin
      $display("%0s @%0t", tag, $time);
      $display("  blt.state=%0d rd_issued=%0b mem_rd=%0b mem_addr=%h | dmx.st=%0d rd_on_sdram=%0b blt_busy=%0b",
               blt.state, blt.rd_issued, bt_rd, bt_addr, vdemux.st, vdemux.rd_on_sdram, blt_busy_w);
      $display("  src_arb.owner=%0d held_txn=%0b just_granted=%0b | dst_rd=%0b dst_we_burst=%0b dst_busy=%0b dst_dready=%0b",
               src_arb.owner, src_arb.held_txn, src_arb.just_granted,
               dst_rd, dst_we_burst, dst_busy, dst_dready);
      $display("  scan_rd=%0b scan_busy=%0b | sps_ready=%0b c_rd=%0b c_we_burst=%0b | done_seq=%0d submit=%0d",
               scan_rd, scan_busy, sps_ready, src_arb.c_rd, src_arb.c_we_burst, done_seq, submit_n);
    end
  endtask

  always @(posedge clk_sys) begin
    if (reset) begin prog_q <= -1; stall <= 0; fp_cnt <= 0; end
    else begin
      // fingerprint dwell counter
      if (fp_hit) fp_cnt <= fp_cnt + 1; else fp_cnt <= 0;
      if (fp_cnt == 2000) begin
        dump_state("FINGERPRINT: blitter S_RD_WAIT+rd_issued, demux S_IDLE, read NEVER issued");
        $display("RESULT: WEDGE (read-issue desync fingerprint held 2000 cyc)");
        $finish;
      end
      // generic no-progress watchdog (backstop / other wedge shapes)
      cur_prog = done_seq + (blt.dy*320 + blt.dx);
      if (cur_prog != prog_q) begin prog_q <= cur_prog; stall <= 0; end
      else begin
        stall <= stall + 1;
        if (stall + 1 >= STALL_LIMIT) begin
          dump_state("WEDGE: no progress");
          $display("RESULT: WEDGE (no progress %0d cyc)", STALL_LIMIT);
          $finish;
        end
      end
    end
  end

  // ================= stimulus ===============================================
  // Throttle sweep: each frame uses a different throttle_cfg so the write->read
  // seam alignment is exercised across the whole range (HW value is unknown; cover
  // it). Combined with the per-line drifting SCAN gap, this sweeps both knobs.
  localparam integer NSWEEP = 14;
  reg [7:0] thr_seq [0:NSWEEP-1];
  initial begin
    thr_seq[0]=0;  thr_seq[1]=1;  thr_seq[2]=2;  thr_seq[3]=3;  thr_seq[4]=4;
    thr_seq[5]=5;  thr_seq[6]=6;  thr_seq[7]=8;  thr_seq[8]=10; thr_seq[9]=12;
    thr_seq[10]=16; thr_seq[11]=20; thr_seq[12]=24; thr_seq[13]=32;
  end

  localparam integer TARGET_FRAMES = NSWEEP;   // run the full throttle sweep
  integer settle, t;
  initial begin
    for (i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    repeat (16) @(posedge clk_sys);
    reset = 1'b0;

    fork
      begin : blitter_proc
        for (t = 0; t < TARGET_FRAMES; t = t + 1) begin
          throttle_val = thr_seq[t];
          submit_blend_frame;
          settle = 0;
          while (done_seq !== submit_n[31:0] && settle < 4_000_000) begin
            @(posedge clk_sys); settle = settle + 1;
          end
        end
      end
      begin : judge_proc
        while (done_seq < TARGET_FRAMES) @(posedge clk_sys);
        $display("=== PROGRESS OK: done_seq=%0d (no rd-issue desync over %0d frames, throttle 0..32) ===",
                 done_seq, TARGET_FRAMES);
        $display("RESULT: PASS");
        $finish;
      end
    join
  end

  initial begin
    #2_000_000_000;
    $display("RESULT: WEDGE (sim backstop timeout: done_seq=%0d)", done_seq);
    $finish;
  end
endmodule
`default_nettype wire
