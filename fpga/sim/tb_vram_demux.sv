`timescale 1ns/1ps
`default_nettype none
`include "../rtl/vram_defs.vh"
module tb_vram_demux;
  reg clk=0; always #5 clk=~clk;
  reg reset=1;

  // blitter side
  reg  [31:0] blt_addr=0; reg blt_rd=0, blt_wr=0; reg [63:0] blt_din=0; reg [7:0] blt_be=0;
  reg  [7:0]  blt_burstcnt=8'd1;   // SDRAM read beats (1 = legacy single-beat)
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
    .blt_burstcnt(blt_burstcnt),
    .blt_dout(blt_dout),.blt_dout_ready(blt_dready),.blt_busy(blt_busy),
    .ddr_addr(ddr_addr),.ddr_rd(ddr_rd),.ddr_wr(ddr_wr),.ddr_din(ddr_din),.ddr_be(ddr_be),
    .ddr_dout(ddr_dout),.ddr_dout_ready(ddr_dready),.ddr_busy(ddr_busy),
    .sd_addr(sd_addr),.sd_rd(sd_rd),.sd_din(sd_din),.sd_we(sd_we),
    .sd_din64(sd_din64),.sd_we_burst(sd_we_burst),
    .sd_dout64(sd_dout64),.sd_dready(sd_dready),.sd_busy(sd_busy));

  integer errs=0;
  integer burst_count=0;
  integer we_count=0;   // counts sd_we pulses for multi-lane partial-write tests
  always @(posedge clk) if (sd_we) we_count <= we_count + 1;

  // Burst-read monitors (single driver each; test snapshots the counters).
  // dready_total: every blt_dout_ready beat the demux returns.
  // rd_issued[]: the SDRAM byte address on each accepted sd_rd, in issue order.
  integer dready_total=0;
  always @(posedge clk) if (blt_dready) dready_total = dready_total + 1;
  integer rd_issue_n=0; reg [26:0] rd_issued [0:31];
  always @(posedge clk) if (sd_rd && !sd_busy) begin
    if (rd_issue_n < 32) rd_issued[rd_issue_n] = sd_addr;
    rd_issue_n = rd_issue_n + 1;
  end

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

    // -----------------------------------------------------------------------
    // 9) S_WLANES 2-lane partial write — lanes 0+2 (blt_be=8'h33).
    //    Verifies S_WLANES serializes exactly 2 sd_we writes to the correct
    //    word addresses with the correct 16-bit data; disabled lanes 1 and 3
    //    are NOT written; blt_busy is held during S_WLANES serialization and
    //    released when serialization completes (FSM enters S_WWAIT).
    //
    //    qword 30 of FB0:
    //      qw_byte = SDRAM_FB0_BASE + 30*8 = 0x4000F0
    //      lane0 word addr = 0x4000F0>>1       = 0x200078  data=16'hAB12
    //      lane1 word addr = (0x4000F0+2)>>1   = 0x200079  NOT written (blt_be=8'h33)
    //      lane2 word addr = (0x4000F0+4)>>1   = 0x20007A  data=16'hCD56
    //      lane3 word addr = (0x4000F0+6)>>1   = 0x20007B  NOT written
    // -----------------------------------------------------------------------
    we_count = 0;
    // Pre-poison sdmem slots for disabled lanes so we can detect accidental writes.
    // Use distinct poison values that differ from lane 0/2 data.
    sdmem[(27'h4000F0 + 2) >> 1] = 16'hFF01; // lane1 slot — must remain FF01
    sdmem[(27'h4000F0 + 6) >> 1] = 16'hFF03; // lane3 slot — must remain FF03
    @(negedge clk);
    blt_addr = {3'd0, `FB_DDR0_QW + 29'd30};
    blt_wr   = 1;
    // blt_din layout: [15:0]=lane0, [31:16]=lane1, [47:32]=lane2, [63:48]=lane3
    blt_din  = 64'hDEAD_CD56_BEEF_AB12;
    blt_be   = 8'h33; // lane_active = {0,1,0,1} -> lanes 0 and 2 active
    // posedge 1: S_IDLE fires lane0 (sd_we); FSM->S_WLANES(lane=2); st changes on posedge.
    @(posedge clk);
    // Between posedge 1 and posedge 2: st=S_WLANES so blt_busy must be 1.
    @(negedge clk);
    if (!blt_busy) begin $display("FAIL T9: blt_busy not asserted in S_WLANES after lane0"); errs=errs+1; end
    // posedge 2: S_WLANES fires lane2 (sd_we); wl_next_found=0 -> FSM->S_WWAIT.
    @(posedge clk);
    // Now st=S_WWAIT; blt_busy drops (S_WWAIT not in blt_busy assign).
    // Deassert blt_wr so FSM can exit S_WWAIT on the next posedge.
    @(negedge clk);
    blt_wr = 0;
    @(posedge clk); // FSM: S_WWAIT->S_IDLE (blt_wr=0 seen at this posedge)
    wait_idle;
    // Check write count: exactly 2 sd_we pulses (one per enabled lane).
    if (we_count !== 2)
      begin $display("FAIL T9: expected 2 sd_we writes, got %0d", we_count); errs=errs+1; end
    // Check lane0 word: SDRAM_FB0_BASE + 30*8 = 0x4000F0; word addr = 0x4000F0>>1 = 0x200078
    if (sdmem[27'h4000F0 >> 1] !== 16'hAB12)
      begin $display("FAIL T9: lane0 word wrong (got %h, want AB12)", sdmem[27'h4000F0>>1]); errs=errs+1; end
    // Check lane2 word: byte offset +4 -> word addr = (0x4000F0+4)>>1 = 0x20007A
    if (sdmem[(27'h4000F0 + 4) >> 1] !== 16'hCD56)
      begin $display("FAIL T9: lane2 word wrong (got %h, want CD56)", sdmem[(27'h4000F0+4)>>1]); errs=errs+1; end
    // Check disabled lane1: must NOT have been overwritten (stays FF01).
    if (sdmem[(27'h4000F0 + 2) >> 1] !== 16'hFF01)
      begin $display("FAIL T9: disabled lane1 was written (got %h, want FF01)", sdmem[(27'h4000F0+2)>>1]); errs=errs+1; end
    // Check disabled lane3: must NOT have been overwritten (stays FF03).
    if (sdmem[(27'h4000F0 + 6) >> 1] !== 16'hFF03)
      begin $display("FAIL T9: disabled lane3 was written (got %h, want FF03)", sdmem[(27'h4000F0+6)>>1]); errs=errs+1; end

    // -----------------------------------------------------------------------
    // 10) S_WLANES 3-lane partial write — lanes 0+1+3 (blt_be=8'hCF).
    //     Exercises 3 serialized sd_we writes with S_WLANES iterating twice
    //     (lane0 in S_IDLE, lane1 in first S_WLANES, lane3 in second S_WLANES).
    //     Lane2 must NOT be written.
    //
    //     qword 40 of FB0:
    //       qw_byte = SDRAM_FB0_BASE + 40*8 = 0x400140
    //       lane0 word addr = 0x400140>>1       = 0x2000A0  data=16'h1111
    //       lane1 word addr = (0x400140+2)>>1   = 0x2000A1  data=16'h2222
    //       lane2 word addr = (0x400140+4)>>1   = 0x2000A2  NOT written (blt_be=8'hCF)
    //       lane3 word addr = (0x400140+6)>>1   = 0x2000A3  data=16'h4444
    // -----------------------------------------------------------------------
    we_count = 0;
    // Pre-poison disabled lane2 slot.
    sdmem[(27'h400140 + 4) >> 1] = 16'hFF02; // lane2 slot — must remain FF02
    @(negedge clk);
    blt_addr = {3'd0, `FB_DDR0_QW + 29'd40};
    blt_wr   = 1;
    blt_din  = 64'h4444_CAFE_2222_1111; // lane0=1111, lane1=2222, lane2=CAFE, lane3=4444
    blt_be   = 8'hCF; // lane_active = {1,0,1,1} -> lanes 0,1,3 active
    // posedge 1: S_IDLE fires lane0; FSM->S_WLANES(lane=1).
    @(posedge clk);
    // st=S_WLANES after posedge 1; blt_busy must be asserted.
    @(negedge clk);
    if (!blt_busy) begin $display("FAIL T10: blt_busy not asserted in S_WLANES after lane0"); errs=errs+1; end
    // posedge 2: S_WLANES fires lane1; wl_next=lane3 -> FSM stays S_WLANES(lane=3).
    @(posedge clk);
    // st=S_WLANES(lane=3) after posedge 2; blt_busy still asserted.
    @(negedge clk);
    if (!blt_busy) begin $display("FAIL T10: blt_busy not asserted in S_WLANES after lane1"); errs=errs+1; end
    // posedge 3: S_WLANES fires lane3; wl_next_found=0 -> FSM->S_WWAIT.
    @(posedge clk);
    // st=S_WWAIT; deassert blt_wr so FSM exits.
    @(negedge clk);
    blt_wr = 0;
    @(posedge clk); // FSM: S_WWAIT->S_IDLE
    wait_idle;
    // Check write count: exactly 3 sd_we pulses.
    if (we_count !== 3)
      begin $display("FAIL T10: expected 3 sd_we writes, got %0d", we_count); errs=errs+1; end
    // Check lane0 word.
    if (sdmem[27'h400140 >> 1] !== 16'h1111)
      begin $display("FAIL T10: lane0 word wrong (got %h, want 1111)", sdmem[27'h400140>>1]); errs=errs+1; end
    // Check lane1 word: (0x400140+2)>>1 = 0x2000A1
    if (sdmem[(27'h400140 + 2) >> 1] !== 16'h2222)
      begin $display("FAIL T10: lane1 word wrong (got %h, want 2222)", sdmem[(27'h400140+2)>>1]); errs=errs+1; end
    // Check lane3 word: (0x400140+6)>>1 = 0x2000A3
    if (sdmem[(27'h400140 + 6) >> 1] !== 16'h4444)
      begin $display("FAIL T10: lane3 word wrong (got %h, want 4444)", sdmem[(27'h400140+6)>>1]); errs=errs+1; end
    // Check disabled lane2: must NOT have been written (stays FF02).
    if (sdmem[(27'h400140 + 4) >> 1] !== 16'hFF02)
      begin $display("FAIL T10: disabled lane2 was written (got %h, want FF02)", sdmem[(27'h400140+4)>>1]); errs=errs+1; end

    // -----------------------------------------------------------------------
    // 11) N-beat FB burst READ decomposed to N single-beat SDRAM reads.
    //     comp_burst issues ONE read with burstcnt=N (single start address) and
    //     expects N streamed blt_dout_ready beats. The demux must auto-increment
    //     the SDRAM byte address by 8 per beat and return exactly N beats in
    //     order. Old (single-beat) demux returns only beat 0 -> no 2nd sd_rd ->
    //     this test FAILs cleanly (bounded wait, not a hang).
    // -----------------------------------------------------------------------
    begin : burst_read_test
      integer b; integer wc; integer e0; integer d0; integer ri0;
      reg [26:0] base_byte;
      e0           = errs;                   // snapshot to detect this test's failures
      d0           = dready_total;           // beats returned before this test
      ri0          = rd_issue_n;             // sd_rd issues before this test
      base_byte    = `SDRAM_FB0_BASE;       // FB0 qword 0 -> SDRAM byte base
      blt_burstcnt = 8'd4;
      @(negedge clk);
      blt_addr = {3'd0, `FB_DDR0_QW};        // start qword of FB0
      blt_rd   = 1'b1; sd_busy = 1'b0;
      @(posedge clk);                         // S_IDLE accepts beat0 (sd_rd) -> S_RDLAT
      @(negedge clk); blt_rd = 1'b0;          // comp_burst drops mem_rd after accept
      // Serve 4 beats. Synchronize on the demux being in S_RDLAT (=3'd1, waiting
      // for this beat's sd_dready); beats 1..3 are re-issued from S_RDISS in between.
      for (b = 0; b < 4; b = b + 1) begin
        wc = 0;
        while (dut.st !== 3'd1 && wc < 200) begin @(posedge clk); wc = wc + 1; end
        if (dut.st !== 3'd1) begin
          $display("FAIL T11: demux not in S_RDLAT for beat %0d (st=%0d)", b, dut.st);
          errs = errs + 1; b = 4;
        end else begin
          @(negedge clk); sd_dready = 1'b1; sd_dout64 = 64'hA0A0_0000_0000_0000 + b;
          @(posedge clk);                     // S_RDLAT samples dready, forwards beat
          @(negedge clk); sd_dready = 1'b0;
        end
      end
      wait_idle;                              // FSM must be back in S_IDLE
      // Exactly 4 beats returned.
      if ((dready_total - d0) !== 4) begin
        $display("FAIL T11: returned %0d/4 beats", dready_total - d0); errs = errs + 1;
      end
      // 4 reads issued, addresses walking +8 bytes from the FB0 base.
      if ((rd_issue_n - ri0) !== 4) begin
        $display("FAIL T11: issued %0d/4 sd_rd reads", rd_issue_n - ri0); errs = errs + 1;
      end else for (b = 0; b < 4; b = b + 1)
        if (rd_issued[ri0 + b] !== (base_byte + b*8)) begin
          $display("FAIL T11: beat %0d addr=%h exp=%h", b, rd_issued[ri0+b], base_byte + b*8);
          errs = errs + 1;
        end
      // Last beat's data must have propagated through the registered capture.
      if (cap_dout !== (64'hA0A0_0000_0000_0000 + 3)) begin
        $display("FAIL T11: last beat data cap_dout=%h", cap_dout); errs = errs + 1;
      end
      if (errs == e0) $display("Test 11 burst-read N=4: PASS");
      blt_burstcnt = 8'd1;                     // restore single-beat default
    end

    // -----------------------------------------------------------------------
    // 12) comp_burst back-to-back full-qword cadence: write B is presented while
    //     the demux is still completing write A (S_BWAIT, sd_busy held); when
    //     sd_busy drops, B must NOT be dropped. Models comp_burst's contract:
    //     it advances the cycle blt_busy goes low. Without the new_wr_pending
    //     hold, blt_busy drops with B unaccepted -> B is silently lost.
    // -----------------------------------------------------------------------
    begin : bb_full_qword
      // write A (full qword) accepted from S_IDLE -> S_BWAIT
      @(negedge clk);
      blt_addr = {3'd0, `FB_DDR0_QW + 29'd60}; blt_din = 64'hA1A1A1A1A1A1A1A1;
      blt_be = 8'hFF; blt_wr = 1'b1; sd_busy = 1'b0;
      @(posedge clk);                       // S_IDLE accepts A -> S_BWAIT (A lands)
      // SDRAM busy with A; present B (different qword) during S_BWAIT
      @(negedge clk); sd_busy = 1'b1;
      blt_addr = {3'd0, `FB_DDR0_QW + 29'd61}; blt_din = 64'hB2B2B2B2B2B2B2B2;  // blt_wr held
      @(posedge clk); @(posedge clk);       // hold in S_BWAIT (sd_busy=1)
      @(negedge clk); sd_busy = 1'b0;       // A completes; demux must hold busy for B
      @(posedge clk);
      while (blt_busy) @(posedge clk);       // faithful producer: advance when busy drops
      @(negedge clk); blt_wr = 1'b0;
      wait_idle;
      if (sdmem[(`SDRAM_FB0_BASE + 60*8) >> 1] !== 16'hA1A1) begin
        $display("FAIL T12: write A lost"); errs = errs + 1; end
      if (sdmem[(`SDRAM_FB0_BASE + 61*8) >> 1] !== 16'hB2B2) begin
        $display("FAIL T12: write B DROPPED (back-to-back cadence bug)"); errs = errs + 1; end
      else $display("Test 12 back-to-back full-qword cadence: PASS");
    end

    // -----------------------------------------------------------------------
    // 13) Partial (multi-lane) write must hold blt_din stable across S_WLANES
    //     serialization. Models comp_burst advancing (changing din) the cycle
    //     blt_busy drops. Without the idle_partial_wr hold, the producer advances
    //     after lane 0 and the remaining lane is written with the wrong data.
    //     be=8'hF0 -> lanes 2,3 active; lane2=din[47:32], lane3=din[63:48].
    // -----------------------------------------------------------------------
    begin : partial_hold
      we_count = 0;
      @(negedge clk);
      blt_addr = {3'd0, `FB_DDR0_QW + 29'd70}; blt_din = 64'h7777_8888_9999_AAAA;
      blt_be = 8'hF0; blt_wr = 1'b1; sd_busy = 1'b0;
      @(posedge clk);
      while (blt_busy) @(posedge clk);       // hold across lane2 (S_IDLE) + lane3 (S_WLANES)
      @(negedge clk); blt_din = 64'hDEAD_DEAD_DEAD_DEAD; blt_wr = 1'b0;  // advance: din poisoned
      wait_idle;
      if (sdmem[(`SDRAM_FB0_BASE + 70*8 + 4) >> 1] !== 16'h8888) begin
        $display("FAIL T13: lane2 wrong/lost"); errs = errs + 1; end
      if (sdmem[(`SDRAM_FB0_BASE + 70*8 + 6) >> 1] !== 16'h7777) begin
        $display("FAIL T13: lane3 corrupted/DROPPED (partial-hold bug)"); errs = errs + 1; end
      else if (we_count == 2) $display("Test 13 partial-write hold: PASS");
      else begin $display("FAIL T13: expected 2 lane writes, got %0d", we_count); errs = errs + 1; end
      blt_be = 8'h00;
    end

    if (errs==0) $display("RESULT: PASS"); else $display("RESULT: FAIL (%0d)", errs);
    $finish;
  end
endmodule
`default_nettype wire
