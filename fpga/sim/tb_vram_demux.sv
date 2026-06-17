`timescale 1ns/1ps
`default_nettype none
`include "../rtl/vram_defs.vh"
module tb_vram_demux;
  reg clk=0; always #5 clk=~clk;
  reg reset=1;

  // blitter side
  reg  [31:0] blt_addr=0; reg blt_rd=0, blt_wr=0; reg [63:0] blt_din=0; reg [7:0] blt_be=0;
  wire [63:0] blt_dout; wire blt_dready; wire blt_busy;
  // DDR side (behavioral)
  wire [28:0] ddr_addr; wire ddr_rd, ddr_wr; wire [63:0] ddr_din; wire [7:0] ddr_be;
  reg  [63:0] ddr_dout=64'hD00D_D00D_D00D_D00D; reg ddr_dready=0; reg ddr_busy=0;
  // SDRAM side (behavioral 16-word memory)
  wire [26:0] sd_addr; wire sd_rd, sd_we, sd_we_burst; wire [15:0] sd_din; wire [63:0] sd_din64;
  reg  [63:0] sd_dout64=64'hBEEF_BEEF_BEEF_BEEF; reg sd_dready=0; reg sd_busy=0;
  // sdmem must cover the full SDRAM FB address space.
  // SDRAM_FB1_BASE=0x440000, max offset ~19200*8=153600 => max word addr ~0x280000.
  // Use [0:1<<23] (8M entries = 16 MB) so both the write model (sd_addr>>1) and
  // the check ((SDRAM_FBx_BASE + offset)>>1) index the same element.
  reg [15:0] sdmem [0:1<<23];

  vram_demux dut(.clk(clk),.reset(reset),
    .blt_addr(blt_addr),.blt_rd(blt_rd),.blt_wr(blt_wr),.blt_din(blt_din),.blt_be(blt_be),
    .blt_dout(blt_dout),.blt_dout_ready(blt_dready),.blt_busy(blt_busy),
    .ddr_addr(ddr_addr),.ddr_rd(ddr_rd),.ddr_wr(ddr_wr),.ddr_din(ddr_din),.ddr_be(ddr_be),
    .ddr_dout(ddr_dout),.ddr_dout_ready(ddr_dready),.ddr_busy(ddr_busy),
    .sd_addr(sd_addr),.sd_rd(sd_rd),.sd_din(sd_din),.sd_we(sd_we),
    .sd_din64(sd_din64),.sd_we_burst(sd_we_burst),
    .sd_dout64(sd_dout64),.sd_dready(sd_dready),.sd_busy(sd_busy));

  integer errs=0;
  integer burst_count=0;

  // Registered dout capture: latches blt_dout whenever blt_dout_ready pulses.
  // Real downstream consumers register on dready; this models that behaviour and
  // avoids sampling combinatorial blt_dout in the same NBA delta as blt_dready.
  //
  // Icarus event-ordering convention used throughout this testbench:
  //
  //   All inputs that feed registered RTL (FSM or capture) are driven at
  //   @(negedge clk) so they settle before the next @(posedge clk). This
  //   eliminates the race between the initial-block @(posedge clk) continuation
  //   and the FSM's always @(posedge clk).
  //
  //   blt_rd (FB reads — must latch rd_on_sdram):
  //     @(negedge clk); blt_rd=1;
  //     @(posedge clk);               // posedge 1: FSM S_IDLE→S_RDLAT; ros=1
  //     @(posedge clk); blt_rd=0;    // posedge 2: ros latched; initial clears blt_rd
  //
  //   dready return (sd_dready / ddr_dready):
  //     @(negedge clk); {sd|ddr}_dready=1;
  //     @(posedge clk);               // posedge 1: FSM sees dready; blt_dready=1; cap latches
  //     @(posedge clk); {sd|ddr}_dready=0;   // posedge 2: cap_ready=1; initial clears
  //     // check cap_ready / cap_dout here
  //
  //   sd_busy deassert (back-pressure release):
  //     @(negedge clk); sd_busy=0;   // set at negedge so burst fires cleanly at posedge
  //
  //   Checks for combinatorial signals (sd_we_burst, sd_we) that change based on
  //   sd_busy are done at @(negedge clk) (mid-cycle) to avoid posedge NBA races.
  reg [63:0] cap_dout=64'hX;
  reg        cap_ready=0;
  always @(posedge clk) begin
    cap_ready <= blt_dready;
    if (blt_dready) cap_dout <= blt_dout;
  end

  // model the SDRAM 16-bit word writes.
  // Use sd_addr>>1 (full word address) so the write index matches the check index
  // (which computes (SDRAM_FBx_BASE + byte_offset)>>1 directly).
  //
  // FIX A reconciliation: vram_demux now HOLDS sd_we_burst high (= sd_busy) until
  // the arbiter ACCEPTS the burst (the real sdram_src_arb drops dst_busy on the
  // accept cycle). The ACCEPT — and the moment the qword lands in SDRAM — is the
  // single cycle `sd_we_burst & ~sd_busy`. Count/commit on the accept, mirroring
  // the real datapath, so exactly ONE qword lands per full-qword write request.
  wire sd_burst_accept = sd_we_burst & ~sd_busy;
  always @(posedge clk) begin
    if (sd_we)         sdmem[sd_addr>>1] <= sd_din;
    if (sd_burst_accept) begin
      burst_count <= burst_count + 1;
      sdmem[(sd_addr>>1)+0]<=sd_din64[15:0];  sdmem[(sd_addr>>1)+1]<=sd_din64[31:16];
      sdmem[(sd_addr>>1)+2]<=sd_din64[47:32]; sdmem[(sd_addr>>1)+3]<=sd_din64[63:48];
    end
  end

  // Helper task: wait until blt_busy deasserts (with timeout).
  task wait_idle;
    integer i;
    begin
      for (i = 0; i < 20 && blt_busy; i = i + 1) @(posedge clk);
      if (blt_busy) begin $display("FAIL: blt_busy stuck"); errs = errs + 1; end
    end
  endtask

  initial begin
    repeat(4) @(posedge clk); reset=0; @(posedge clk);

    // -----------------------------------------------------------------------
    // 1) NON-FB write routes to DDR (RING region), NOT SDRAM
    // -----------------------------------------------------------------------
    blt_addr=32'h07600008; blt_wr=1; blt_din=64'h1; blt_be=8'hFF; @(posedge clk);
    if (!ddr_wr || sd_we || sd_we_burst) begin $display("FAIL: ring write not on DDR"); errs=errs+1; end
    blt_wr=0; @(posedge clk);

    // -----------------------------------------------------------------------
    // 2) FB0 full-qword write routes to SDRAM as a BURST write, address remapped.
    //    blt_busy must be 1 while FSM is in S_BWAIT; clears after blt_wr=0.
    // -----------------------------------------------------------------------
    blt_addr={3'd0,`FB_DDR0_QW};               // first qword of FB0
    blt_wr=1; blt_din=64'hAAAA_BBBB_CCCC_DDDD; blt_be=8'hFF; @(posedge clk);
    if (!sd_we_burst || ddr_wr) begin $display("FAIL: FB full-qword not a SDRAM burst"); errs=errs+1; end
    if (sd_addr !== `SDRAM_FB0_BASE) begin $display("FAIL: FB0 base addr remap %h", sd_addr); errs=errs+1; end
    blt_wr=0;
    // After burst fires, FSM transitions to S_BWAIT; wait for it to exit.
    @(posedge clk); wait_idle;

    // -----------------------------------------------------------------------
    // 3) FB1 single-pixel (one lane) write -> a SINGLE 16-bit SDRAM word at lane col
    // -----------------------------------------------------------------------
    blt_addr={3'd0,`FB_DDR1_QW + 29'd5};        // qword 5 of FB1
    blt_wr=1; blt_din=64'h0000_0000_1234_0000; blt_be=8'h0C; @(posedge clk); // lane1 (bytes 2-3)
    // expect one sd_we to SDRAM_FB1_BASE + 5*8 + 1*2 (col word = qw*4 + lane)
    @(posedge clk);
    if (sdmem[(`SDRAM_FB1_BASE + 5*8 + 1*2) >> 1] !== 16'h1234) begin
      $display("FAIL: FB1 lane write wrong word"); errs=errs+1; end
    blt_wr=0; wait_idle;

    // -----------------------------------------------------------------------
    // 4) FB read routes to SDRAM; dout captured from sd_dout64 via rd_on_sdram latch.
    //    Realistic multi-cycle latency: blt_rd is set at negedge and held for two
    //    posedges so the FSM reliably samples it and latches rd_on_sdram. sd_dready
    //    arrives 3 cycles later using the 2-posedge hold pattern.
    //    blt_dout_ready must be silent in the wait cycles (no spurious ready).
    // -----------------------------------------------------------------------
    sd_dout64=64'hCAFE_CAFE_CAFE_CAFE;
    blt_addr={3'd0,`FB_DDR0_QW + 29'd10};
    @(negedge clk); blt_rd=1;    // set at negedge: FSM sees blt_rd=1 at next posedge
    @(posedge clk);               // posedge 1: FSM S_IDLE→S_RDLAT; ros=1
    @(posedge clk); blt_rd=0;    // posedge 2: FSM in S_RDLAT; blt_rd cleared (ros latched)
    // Verify blt_dout_ready is silent in wait cycles (rd_on_sdram gates the mux).
    @(posedge clk);
    if (blt_dready) begin $display("FAIL: FB read blt_dout_ready spurious cycle 1"); errs=errs+1; end
    @(posedge clk);
    if (blt_dready) begin $display("FAIL: FB read blt_dout_ready spurious cycle 2"); errs=errs+1; end
    @(posedge clk);
    if (blt_dready) begin $display("FAIL: FB read blt_dout_ready spurious cycle 3"); errs=errs+1; end
    // Return SDRAM data: 2-posedge hold ensures FSM and cap register both fire cleanly.
    @(negedge clk); sd_dready=1;
    @(posedge clk);               // posedge 1: FSM S_RDLAT→S_IDLE; ros=0; blt_dready=1; cap latches
    @(posedge clk); sd_dready=0;  // posedge 2: cap_ready=1; initial clears dready
    if (!cap_ready)
      begin $display("FAIL: FB read cap_ready not asserted"); errs=errs+1; end
    if (cap_dout !== 64'hCAFE_CAFE_CAFE_CAFE)
      begin $display("FAIL: FB read dout not from SDRAM (got %h)", cap_dout); errs=errs+1; end
    @(posedge clk); // settle

    // -----------------------------------------------------------------------
    // 5) NON-FB read routes to DDR; dout returns from ddr_dout.
    //    rd_on_sdram=0 so blt_dout = ddr_dout, not sd_dout64. The FSM stays in
    //    S_IDLE for DDR reads (no state transition needed). SDRAM data must not leak.
    // -----------------------------------------------------------------------
    blt_addr=32'h07600008;  // non-FB address; rd_on_sdram=0 (cleared after test 4)
    @(negedge clk); ddr_dready=1;  // blt_dout_ready = ros?sd_dready:ddr_dready = 0?0:1 = 1
    @(posedge clk);                  // posedge 1: blt_dready=1; cap latches ddr_dout
    @(posedge clk); ddr_dready=0;   // posedge 2: cap_ready=1; initial clears dready
    if (!cap_ready)
      begin $display("FAIL: DDR read cap_ready not asserted"); errs=errs+1; end
    if (cap_dout !== 64'hD00D_D00D_D00D_D00D)
      begin $display("FAIL: ring read dout not from DDR (got %h)", cap_dout); errs=errs+1; end
    // Verify SDRAM data (CAFE) did NOT leak for a DDR read.
    if (cap_dout === 64'hCAFE_CAFE_CAFE_CAFE)
      begin $display("FAIL: DDR read leaked SDRAM dout"); errs=errs+1; end
    @(posedge clk); // settle

    // -----------------------------------------------------------------------
    // 6) Full-qword burst single-LAND + re-fire guard (Issue #1 + FIX A reconcile).
    //    Models the REAL sdram_src_arb protocol: on the accept cycle
    //    (sd_we_burst & ~sd_busy) the arbiter latches held_txn and raises dst_busy
    //    (=sd_busy) for the transaction, dropping it at write-complete. Here we
    //    drive sd_busy high the cycle AFTER the accept so S_BWAIT holds (blt_busy=1),
    //    the blitter de-asserts blt_wr while busy, and the FSM returns to S_IDLE
    //    with blt_wr already low — so NO second burst lands. Invariant: exactly ONE
    //    qword lands per full-qword write request, counted on the accept.
    // -----------------------------------------------------------------------
    burst_count=0;
    blt_addr={3'd0,`FB_DDR0_QW + 29'd1};
    blt_wr=1; blt_din=64'hDEAD_BEEF_DEAD_BEEF; blt_be=8'hFF;
    @(posedge clk);              // cycle 1: burst presented & accepted (sd_busy=0); FSM → S_BWAIT
    @(negedge clk); sd_busy=1;   // arbiter raises dst_busy for the held transaction
    @(posedge clk);              // cycle 2: S_BWAIT holds (sd_busy=1); blt_busy=1
    if (!blt_busy) begin $display("FAIL: burst blt_busy not held while arbiter busy"); errs=errs+1; end
    blt_wr=0;                    // blitter de-asserts blt_wr while it sees mem_busy
    @(negedge clk); sd_busy=0;   // write completes; arbiter drops dst_busy
    @(posedge clk);              // cycle 3: S_BWAIT exits → S_IDLE; blt_wr already low → no re-fire
    wait_idle;
    if (burst_count !== 1) begin $display("FAIL: burst LANDED %0d times (expected exactly 1)", burst_count); errs=errs+1; end
    if (blt_busy) begin $display("FAIL: blt_busy still asserted after blt_wr=0"); errs=errs+1; end

    // -----------------------------------------------------------------------
    // 7) sd_busy back-pressure on full-qword burst (Issue #1 back-pressure test).
    //    While sd_busy=1, no burst fires and blt_busy=1. Once sd_busy clears,
    //    exactly one burst fires. sd_we_burst is combinatorial so its "firing"
    //    check is done at @(negedge clk) to avoid posedge NBA races.
    // -----------------------------------------------------------------------
    burst_count=0;
    sd_busy=1;
    blt_addr={3'd0,`FB_DDR0_QW + 29'd2};
    blt_wr=1; blt_din=64'hFACE_CAFE_FACE_CAFE; blt_be=8'hFF;
    @(posedge clk); // cycle 1: sd_busy stalls; blt_busy=1 (is_fb & blt_wr & sd_busy)
    // Check at negedge: burst must not have fired; blt_busy must be 1.
    @(negedge clk);
    if (sd_we_burst) begin $display("FAIL: burst fired while sd_busy=1"); errs=errs+1; end
    if (!blt_busy)   begin $display("FAIL: blt_busy not asserted during sd_busy stall"); errs=errs+1; end
    @(posedge clk); // cycle 2: still stalled
    @(negedge clk);
    if (sd_we_burst) begin $display("FAIL: burst fired while sd_busy=1 (cycle 2)"); errs=errs+1; end
    // Clear sd_busy at negedge so the burst fires cleanly at the next posedge.
    sd_busy=0;
    @(posedge clk); // burst fires this posedge; burst_count → 1 (via NBA)
    blt_wr=0; @(posedge clk); wait_idle;
    if (burst_count !== 1) begin $display("FAIL: back-pressure burst fired %0d times (expected 1)", burst_count); errs=errs+1; end

    // -----------------------------------------------------------------------
    // 8) FB read multi-cycle latency + DDR dready cross-bus isolation (Issue #2).
    //    During an in-flight SDRAM read (rd_on_sdram=1), a spurious ddr_dready
    //    must NOT assert blt_dout_ready (cap_ready must not pulse).
    //    The correct SDRAM data must appear when sd_dready eventually fires.
    // -----------------------------------------------------------------------
    sd_dout64=64'h5555_AAAA_5555_AAAA;
    ddr_dout=64'hD00D_D00D_D00D_D00D;
    // Ensure cap_ready is 0 at test start (previous cap_ready from test 7 is 0).
    @(posedge clk);
    if (cap_ready) begin $display("FAIL: cap_ready not 0 at test 8 start"); errs=errs+1; end
    blt_addr={3'd0,`FB_DDR0_QW + 29'd20};
    @(negedge clk); blt_rd=1;
    @(posedge clk);               // FSM: S_IDLE→S_RDLAT; ros=1
    @(posedge clk); blt_rd=0;    // blt_rd cleared; ros latched
    // Spuriously pulse ddr_dready during SDRAM latency.
    // blt_dout_ready = ros ? sd_dready : ddr_dout_ready = 1?0:1 = 0 (ros blocks DDR dready).
    @(negedge clk); ddr_dready=1;
    @(posedge clk);               // blt_dready=0 (ros gates it out); cap must NOT fire
    @(posedge clk); ddr_dready=0; // cap_ready would be 1 if DDR dready leaked through
    if (cap_ready)
      begin $display("FAIL: DDR dready leaked during in-flight SDRAM read"); errs=errs+1; end
    @(posedge clk);
    // Now return the correct SDRAM data.
    @(negedge clk); sd_dready=1;
    @(posedge clk);               // FSM: S_RDLAT→S_IDLE; ros=0; blt_dready=1; cap latches
    @(posedge clk); sd_dready=0;  // cap_ready=1 this cycle
    if (!cap_ready)
      begin $display("FAIL: FB multi-cycle read cap_ready not asserted"); errs=errs+1; end
    if (cap_dout !== 64'h5555_AAAA_5555_AAAA)
      begin $display("FAIL: FB multi-cycle read dout wrong (got %h)", cap_dout); errs=errs+1; end

    if (errs==0) $display("RESULT: PASS"); else $display("RESULT: FAIL (%0d)", errs);
    $finish;
  end
endmodule
`default_nettype wire
