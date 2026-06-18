// tb_capture_race.sv — directed reproduction attempt for #34 VRAM bug #3:
// the blitter MISSES a delivered SDRAM dst-RMW beat (frozen in S_RD_WAIT with
// rd_issued=1 while the demux is back in S_IDLE, rd_on_sdram=0).
//
// Unlike tb_vram_contention (real blitter, real workload, timing falls where it
// may), this tb DENSELY hammers the dst-read <-> SCAN-preemption boundary at
// EVERY relative phase: a tight "mini-blitter" that mirrors blitter_top's exact
// S_DST_RDISS -> S_RD_WAIT capture logic does back-to-back SDRAM dst reads while
// a continuous SCAN client preempts, with a per-read variable phase gap so the
// dst-issue / scan-grant alignment drifts across all offsets. Real sdram_src_arb
// + real sdram_psx(BURST_BEATS=1) + chip model (zero-delay or -DUSE_MICRON).
//
// If a capture race exists in the single-clock logic, sustained dense contention
// at all phases will strand the mini-blitter in B_RDWAIT (rd_issued=1, demux
// idle) -> watchdog WEDGE. If it runs clean across the full sweep under Micron
// timing, that is strong evidence the HW wedge is NOT a logic race (-> timing
// closure on a critical reg in the dst-RMW path).
//
// Build (zero-delay):  iverilog -g2012 -o b.vvp -I ../rtl -I ../sys -I . \
//                         -y ../rtl -y ../sys -y . -Y .sv -Y .v *_stub.sv tb_capture_race.sv
// Build (Micron):      add  -DUSE_MICRON  -y ../../jtcores/modules/jtframe/hdl/ver
`timescale 1ns/1ps
`default_nettype none
`include "vram_defs.vh"

module tb_capture_race;
  reg clk = 0; always #5 clk = ~clk;   // 100 MHz
  reg reset = 1;

  // ---- vram_demux blt_* side (driven by the mini-blitter) -------------------
  reg  [31:0] mem_addr = 0;
  reg         mem_rd   = 0;
  wire [63:0] mem_dout;
  wire        mem_dout_ready;
  wire        mem_busy;
  // DDR side of the demux — unused here (all reads target the FB -> SDRAM)
  wire [28:0] ddr_addr; wire ddr_rd, ddr_wr; wire [63:0] ddr_din; wire [7:0] ddr_be;
  reg  [63:0] ddr_dout = 0; reg ddr_dready = 0; reg ddr_busy = 0;
  wire [3:0]  vdemux_dbg;

  // ---- demux SDRAM side -> arbiter P_DST ------------------------------------
  wire [26:0] dst_addr; wire dst_rd, dst_we, dst_we_burst;
  wire [15:0] dst_din;  wire [63:0] dst_din64;
  wire        dst_busy; wire [63:0] dst_dout64; wire dst_dready;

  vram_demux vdemux (
    .clk(clk), .reset(reset),
    .blt_addr(mem_addr), .blt_rd(mem_rd), .blt_wr(1'b0), .blt_din(64'd0), .blt_be(8'd0),
    .blt_dout(mem_dout), .blt_dout_ready(mem_dout_ready), .blt_busy(mem_busy),
    .ddr_addr(ddr_addr), .ddr_rd(ddr_rd), .ddr_wr(ddr_wr), .ddr_din(ddr_din), .ddr_be(ddr_be),
    .ddr_dout(ddr_dout), .ddr_dout_ready(ddr_dready), .ddr_busy(ddr_busy),
    .sd_addr(dst_addr), .sd_rd(dst_rd), .sd_din(dst_din), .sd_we(dst_we),
    .sd_din64(dst_din64), .sd_we_burst(dst_we_burst),
    .sd_dout64(dst_dout64), .sd_dready(dst_dready), .sd_busy(dst_busy),
    .dbg(vdemux_dbg));

  // ---- continuous SCAN client (highest priority, the preemptor) -------------
  reg  [26:0] scan_addr = 27'h0400000;   // FB0 base — any valid row
  reg         scan_rd   = 0;
  wire        scan_busy; wire [63:0] scan_dout64; wire scan_dready;

  // ---- P_SRC client (3rd arbiter client: source reads + staging burst-writes)
  wire        p0_dready; wire [63:0] p0_dout64;
  reg  [26:0] p0_addr = 27'h0440000;     // FB1 source region
  reg         p0_rd = 0;
  reg         p0_we_burst = 0;
  reg  [26:0] p0_waddr = 27'h0100000;    // staging dest region
  reg  [63:0] p0_din64 = 64'hA5A5_5A5A_1234_5678;
  wire        p0_busy_w;

  // ---- controller-facing nets ----------------------------------------------
  wire        sps_ready, sps_dready; wire [63:0] sps_dout64;
  wire [26:0] sc_addr; wire sc_rd, sc_we, sc_we_burst; wire [15:0] sc_din; wire [63:0] sc_din64;
  wire        sc_busy = ~sps_ready;

  sdram_src_arb src_arb (
    .clk(clk), .reset(reset),
    .scan_addr(scan_addr), .scan_rd(scan_rd), .scan_burst(8'd1),
    .scan_busy(scan_busy), .scan_dout64(scan_dout64), .scan_dready(scan_dready),
    .p0_addr(p0_addr), .p0_rd(p0_rd), .p0_grant(), .p0_busy(p0_busy_w),
    .p0_we(1'b0), .p0_din(16'd0), .p0_waddr(p0_waddr),
    .p0_we_burst(p0_we_burst), .p0_din64(p0_din64), .p0_dready(p0_dready), .p0_dout64(p0_dout64),
    .dst_addr(dst_addr), .dst_rd(dst_rd), .dst_we(dst_we), .dst_din(dst_din),
    .dst_we_burst(dst_we_burst), .dst_din64(dst_din64),
    .dst_busy(dst_busy), .dst_dout64(dst_dout64), .dst_dready(dst_dready),
    .c_addr(sc_addr), .c_rd(sc_rd), .c_we(sc_we), .c_din(sc_din),
    .c_we_burst(sc_we_burst), .c_din64(sc_din64),
    .c_ready(sps_ready), .c_busy(sc_busy),
    .c_dready(sps_dready), .c_dout64(sps_dout64));

  // ---- SDRAM controller + chip ----------------------------------------------
  wire [15:0] SDQ; wire [12:0] SA; wire SDQML, SDQMH; wire [1:0] SBA;
  wire        SnCS, SnWE, SnRAS, SnCAS, SCLK, SCKE;

  sdram_psx #(.BURST_BEATS(1)) sps (
    .init(reset), .clk(clk),
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
    .clk(clk), .DQ(SDQ), .A(SA), .BA(SBA),
    .nCS(SnCS), .nRAS(SnRAS), .nCAS(SnCAS), .nWE(SnWE), .CKE(SCKE),
    .DQML(SDQML), .DQMH(SDQMH), .proto_errors());
`endif

  // ==========================================================================
  // Mini-blitter: EXACT mirror of blitter_top S_DST_RDISS -> S_RD_WAIT capture.
  //   - mem_rd defaults to 0 every cycle (blitter_top line 317), re-asserted only
  //     while !rd_issued in B_RDWAIT (S_RD_WAIT) and in B_ISSUE (S_DST_RDISS).
  //   - rd_issued latches on !mem_busy; capture requires rd_issued & mem_dout_ready.
  // A variable per-read phase gap (phase) drifts the dst-issue vs scan-grant
  // alignment across all offsets so every collision phase is exercised.
  // ==========================================================================
  localparam [1:0] B_IDLE=2'd0, B_ISSUE=2'd1, B_RDWAIT=2'd2;
  localparam [31:0] DST_QW = `FB_DDR1_QW + 32'h2275;   // inside FB1 (HW stuck addr region)
  reg  [1:0]  bst = B_IDLE;
  reg         rd_issued = 0;
  reg  [63:0] rd_data = 0;
  integer     reads_done = 0;
  reg  [5:0]  phase = 0;          // inter-read gap, drifts 0..40
  reg  [5:0]  gap = 0;

  always @(posedge clk) begin
    mem_rd <= 1'b0;               // per-cycle default (blitter_top line 317)
    if (reset) begin
      bst <= B_IDLE; mem_rd <= 0; rd_issued <= 0; reads_done <= 0;
      phase <= 0; gap <= 0; mem_addr <= 0;
    end else case (bst)
      B_IDLE: begin
        if (gap == 0) begin
          bst <= B_ISSUE;
          // advance the phase for the NEXT read (drift across all alignments)
          phase <= (phase == 6'd40) ? 6'd0 : phase + 6'd1;
        end else gap <= gap - 6'd1;
      end
      B_ISSUE: begin              // mirror S_DST_RDISS
        mem_rd   <= 1'b1;
        mem_addr <= DST_QW;
        rd_issued<= 1'b0;
        bst      <= B_RDWAIT;
      end
      B_RDWAIT: begin             // mirror S_RD_WAIT (blitter_top:694)
        if (!rd_issued) begin
          mem_rd <= 1'b1;
          if (!mem_busy) rd_issued <= 1'b1;
        end else if (mem_dout_ready) begin
          rd_data    <= mem_dout;
          rd_issued  <= 1'b0;
          reads_done <= reads_done + 1;
          gap        <= phase;    // variable gap before the next read
          bst        <= B_IDLE;
        end
      end
    endcase
  end

  // ==========================================================================
  // Continuous SCAN client: assert scan_rd when !scan_busy, hold until
  // scan_dready (mirrors the real reader's hold-until-beat contract), then a
  // short gap and repeat — so the arbiter is frequently mid-SCAN, preempting
  // P_DST at a sliding phase. scan_addr walks to keep the controller working.
  // ==========================================================================
  // Bursty SCAN, mirroring the real reader: a LINE of LINE_BEATS back-to-back
  // single-beat reads (re-issued per beat, holding scan_rd until each dready),
  // then an inter-line GAP_CYC idle window in which P_DST (the mini-blitter dst
  // reads) actually gets serviced. The mini-blitter's drifting phase slides the
  // dst-issue alignment across the line/gap boundary so every collision phase is
  // exercised — including a dst read that gets granted/completed right as SCAN
  // resumes (the bug #3 capture-miss suspect window).
  localparam integer LINE_BEATS = 80;
  localparam integer GAP_CYC    = 40;
  localparam [1:0] SC_REQ=2'd0, SC_WAIT=2'd1, SC_GAP=2'd2;
  reg [1:0] scst = SC_REQ;
  reg [6:0] sc_beats = 0;
  reg [9:0] sc_gapc  = 0;
  always @(posedge clk) begin
    if (reset) begin
      scst <= SC_REQ; scan_rd <= 0; sc_beats <= 0; sc_gapc <= 0;
      scan_addr <= 27'h0400000;
    end else case (scst)
      SC_REQ: begin
        if (!scan_busy) begin scan_rd <= 1'b1; scst <= SC_WAIT; end
      end
      SC_WAIT: begin
        scan_rd <= 1'b1;                       // hold until the beat lands
        if (scan_dready) begin
          scan_rd   <= 1'b0;
          scan_addr <= scan_addr + 27'h8;       // next qword
          if (sc_beats + 7'd1 >= LINE_BEATS[6:0]) begin
            sc_beats  <= 7'd0;
            sc_gapc   <= GAP_CYC[9:0];
            scan_addr <= 27'h0400000;           // restart the line
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

  // ==========================================================================
  // P_SRC client: mirrors the blitter source path (SOLARUS_SDRAM_SRC=1) — a
  // staging BL=4 burst-write then a source read, with a drifting gap so its
  // arbiter traffic interleaves with SCAN and DST at all phases. This makes the
  // sweep a true 3-client contention (the HW note: the wedge only appears under
  // SCAN+SRC+DST together).
  // ==========================================================================
  // Alternate a staging BL=4 burst-write and a source read, each held until the
  // arbiter services it, with a drifting inter-op gap (pphase) so SRC traffic
  // interleaves against SCAN/DST at all phases.
  localparam [1:0] P_WR=2'd0, P_RD=2'd1, P_GAP=2'd2;
  reg  [1:0] pst = P_WR;
  reg  [5:0] pgap = 0, pphase = 0;
  reg        p_do_read = 0;   // toggles WR <-> RD between gaps
  always @(posedge clk) begin
    if (reset) begin
      pst <= P_WR; p0_rd <= 0; p0_we_burst <= 0; pgap <= 0; pphase <= 0;
      p_do_read <= 0; p0_addr <= 27'h0440000; p0_waddr <= 27'h0100000;
    end else case (pst)
      P_WR: begin
        p0_we_burst <= 1'b1;                  // hold burst-write until serviced
        if (!p0_busy_w) begin                 // SRC granted (owner==SRC, !c_busy)
          p0_we_burst <= 1'b0;
          p0_waddr    <= p0_waddr + 27'h8;
          pgap <= pphase; pphase <= (pphase==6'd37)?6'd0:pphase+6'd1;
          p_do_read <= 1'b1; pst <= P_GAP;
        end
      end
      P_RD: begin
        p0_rd <= 1'b1;                         // hold read until the beat lands
        if (p0_dready) begin
          p0_rd   <= 1'b0;
          p0_addr <= p0_addr + 27'h8;
          pgap <= pphase; pphase <= (pphase==6'd37)?6'd0:pphase+6'd1;
          p_do_read <= 1'b0; pst <= P_GAP;
        end
      end
      P_GAP: begin
        p0_rd <= 1'b0; p0_we_burst <= 1'b0;
        if (pgap == 0) pst <= p_do_read ? P_RD : P_WR;
        else pgap <= pgap - 6'd1;
      end
    endcase
  end

  // ==========================================================================
  // Watchdog: reads_done must keep advancing. If it stalls, the mini-blitter is
  // stranded in B_RDWAIT (the #34 wedge). Dump arbiter/demux/controller state.
  // ==========================================================================
  parameter integer STALL_LIMIT = 100_000;   // ~1 ms @ 100 MHz; >> any single read
  parameter integer TARGET_READS = 8_000;      // dense sweep across all phases
  integer prog_q = -1, stall = 0;
  reg done = 0;
  always @(posedge clk) begin
    if (reset) begin prog_q <= -1; stall <= 0; end
    else if (!done) begin
      if (reads_done != prog_q) begin prog_q <= reads_done; stall <= 0; end
      else begin
        stall <= stall + 1;
        if (stall + 1 >= STALL_LIMIT) begin
          done <= 1;
          $display("WEDGE: dst read stuck after %0d reads (phase=%0d gap=%0d)", reads_done, phase, gap);
          $display("  mini-blt: bst=%0d rd_issued=%0b mem_rd=%0b mem_addr=%h mem_busy=%0b mem_dout_ready=%0b",
                   bst, rd_issued, mem_rd, mem_addr, mem_busy, mem_dout_ready);
          $display("  demux:    st=%0d rd_on_sdram=%0b (dbg=%h) | dst_rd=%0b dst_busy=%0b dst_dready=%0b",
                   vdemux.st, vdemux_dbg[3], vdemux_dbg, dst_rd, dst_busy, dst_dready);
          $display("  arb:      owner=%0d held_txn=%0b | scan_rd=%0b scan_busy=%0b | c_rd=%0b c_addr=%h",
                   src_arb.owner, src_arb.held_txn, scan_rd, scan_busy, src_arb.c_rd, src_arb.c_addr);
          $display("  psx:      state=%0d cmd=%0b reads_issued=%0d beat_idx=%0d ready=%0b dready=%0b",
                   sps.fsm.state, sps.command, sps.reads_issued, sps.beat_idx, sps_ready, sps_dready);
          $display("RESULT: WEDGE");
          $finish;
        end
      end
      if (reads_done != prog_q && (reads_done % 1000 == 0))
        $display("[progress] reads_done=%0d phase=%0d", reads_done, phase);
      if (reads_done >= TARGET_READS) begin
        done <= 1;
        $display("=== completed %0d dst reads under continuous SCAN preemption (all phases) ===", reads_done);
        $display("RESULT: PASS");
        $finish;
      end
    end
  end

  initial begin
    repeat (16) @(posedge clk);
    reset <= 1'b0;
    // wait for the controller to finish startup (ready=1)
    @(posedge sps_ready);
    $display("controller ready; starting dense dst-read/scan contention sweep");
  end

  // focused per-cycle trace of the first reads (enable with +trace)
  integer tc = 0;
  reg sps_ready_seen = 0;
  always @(posedge clk) if (sps_ready) sps_ready_seen <= 1'b1;
  always @(posedge clk) begin
    if (!reset && sps_ready_seen && tc < 200 && $test$plusargs("trace")) begin
      tc = tc + 1;
      $display("[%0d] blt.bst=%0d rd_iss=%0b mem_rd=%0b mbusy=%0b mdr=%0b | dmx.st=%0d ros=%0b dst_rd=%0b dst_busy=%0b dst_dr=%0b | arb own=%0d held=%0b scan_rd=%0b scan_busy=%0b c_rd=%0b cbusy=%0b | psx st=%0d ri=%0d bi=%0d rdy=%0b dr=%0b",
        tc, bst, rd_issued, mem_rd, mem_busy, mem_dout_ready,
        vdemux.st, vdemux_dbg[3], dst_rd, dst_busy, dst_dready,
        src_arb.owner, src_arb.held_txn, scan_rd, scan_busy, src_arb.c_rd, sc_busy,
        sps.fsm.state, sps.reads_issued, sps.beat_idx, sps_ready, sps_dready);
    end
  end

  // hard backstop
  initial begin #200_000_000 $display("RESULT: WEDGE (backstop timeout, reads=%0d)", reads_done); $finish; end
endmodule
`default_nettype wire
