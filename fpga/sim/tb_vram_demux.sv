`timescale 1ns/1ps
`default_nettype none
`include "../rtl/vram_defs.vh"
// tb_vram_demux.sv — Stage 5 Phase 2, Task 3.
//
// vram_demux is now a stateless pass-through from blt_* to ddr_*: the legacy
// SDRAM P_DST leg (sd_*, its write/read FSM, the FB0/FB1 SDRAM-base remap) is
// DELETED, because FB writes/reads already carry a DDR-relative qword address
// (`FB_DDR0_QW`/`FB_DDR1_QW` + offset) and the framebuffer's scanout copy has
// moved off-chip to DDR3. This TB verifies:
//   1) non-FB traffic still passes straight through to DDR (unchanged from
//      before Task 3);
//   2) the FB0/FB1 region ALSO passes straight through to DDR now, unremapped
//      -- no sd_* signals exist any more to divert it elsewhere;
//   3) blt_busy/blt_dout/blt_dout_ready track the DDR side combinationally,
//      for both regions, with no leftover FB-only latching;
//   4) a multi-beat DDR read forwards every beat untouched (guards the
//      historical "burst truncated to 1" class of bug at the demux boundary;
//      real burst sequencing now lives entirely in ddr_blitter_arb).
module tb_vram_demux;
  reg clk=0; always #5 clk=~clk;
  reg reset=1;

  // blitter side
  reg  [31:0] blt_addr=0; reg blt_rd=0, blt_wr=0; reg [63:0] blt_din=0; reg [7:0] blt_be=0;
  reg  [7:0]  blt_burstcnt=8'd1;   // informational only now (see vram_demux.sv header)
  wire [63:0] blt_dout; wire blt_dready; wire blt_busy;
  // DDR side (behavioral, driven directly by the testbench)
  wire [28:0] ddr_addr; wire ddr_rd, ddr_wr; wire [63:0] ddr_din; wire [7:0] ddr_be;
  reg  [63:0] ddr_dout=64'hD00D_D00D_D00D_D00D; reg ddr_dready=0; reg ddr_busy=0;

  vram_demux dut(.clk(clk),.reset(reset),
    .blt_addr(blt_addr),.blt_rd(blt_rd),.blt_wr(blt_wr),.blt_din(blt_din),.blt_be(blt_be),
    .blt_burstcnt(blt_burstcnt),
    .blt_dout(blt_dout),.blt_dout_ready(blt_dready),.blt_busy(blt_busy),
    .ddr_addr(ddr_addr),.ddr_rd(ddr_rd),.ddr_wr(ddr_wr),.ddr_din(ddr_din),.ddr_be(ddr_be),
    .ddr_dout(ddr_dout),.ddr_dout_ready(ddr_dready),.ddr_busy(ddr_busy),
    .dbg());

  integer errs=0;

  initial begin
    repeat(4) @(posedge clk); reset=0; @(posedge clk);

    // -----------------------------------------------------------------------
    // 1) NON-FB write passes straight through to DDR (ring region). Unchanged
    //    behavior from before Task 3.
    // -----------------------------------------------------------------------
    blt_addr=32'h07600008; blt_wr=1; blt_din=64'hAAAA_1111_BBBB_2222; blt_be=8'hFF;
    #1;
    if (!ddr_wr) begin $display("FAIL T1: ring write not on ddr_wr"); errs=errs+1; end
    if (ddr_addr !== blt_addr[28:0])
      begin $display("FAIL T1: ddr_addr mismatch (got %h want %h)", ddr_addr, blt_addr[28:0]); errs=errs+1; end
    if (ddr_din !== blt_din) begin $display("FAIL T1: ddr_din mismatch"); errs=errs+1; end
    if (ddr_be !== blt_be)   begin $display("FAIL T1: ddr_be mismatch"); errs=errs+1; end
    @(posedge clk); blt_wr=0;

    // -----------------------------------------------------------------------
    // 2) FB0 write ALSO passes straight through to DDR, unremapped.
    //    [Stage 5 Phase 2] This is the region that used to divert to the
    //    SDRAM P_DST cache (sd_wr, addr remapped to `SDRAM_FB0_BASE`); it must
    //    now behave identically to non-FB traffic -- same ddr_wr, same
    //    (unremapped) address.
    // -----------------------------------------------------------------------
    @(negedge clk);
    blt_addr={3'd0,`FB_DDR0_QW}; blt_wr=1; blt_din=64'hAAAA_BBBB_CCCC_DDDD; blt_be=8'hFF;
    #1;
    if (!ddr_wr) begin $display("FAIL T2: FB0 write did not route to DDR"); errs=errs+1; end
    if (ddr_addr !== `FB_DDR0_QW)
      begin $display("FAIL T2: FB0 ddr_addr=%h, want %h (unremapped)", ddr_addr, `FB_DDR0_QW); errs=errs+1; end
    if (ddr_din !== blt_din) begin $display("FAIL T2: FB0 ddr_din mismatch"); errs=errs+1; end
    if (ddr_be !== 8'hFF)    begin $display("FAIL T2: FB0 ddr_be mismatch"); errs=errs+1; end
    @(posedge clk); blt_wr=0;

    // -----------------------------------------------------------------------
    // 3) FB1 partial write: ddr_be passes through as raw blt_be. The
    //    active-low wdsn byte-mask conversion lived in the now-deleted SDRAM
    //    FSM; downstream (ddr_blitter_arb/DDR3) now sees blt_be directly.
    // -----------------------------------------------------------------------
    @(negedge clk);
    blt_addr={3'd0,`FB_DDR1_QW + 29'd5}; blt_wr=1; blt_din=64'h0000_0000_1234_0000; blt_be=8'h0C;
    #1;
    if (!ddr_wr) begin $display("FAIL T3: FB1 write did not route to DDR"); errs=errs+1; end
    if (ddr_addr !== (`FB_DDR1_QW + 29'd5))
      begin $display("FAIL T3: FB1 ddr_addr wrong (got %h)", ddr_addr); errs=errs+1; end
    if (ddr_be !== 8'h0C)
      begin $display("FAIL T3: FB1 ddr_be should equal blt_be unmasked (got %h)", ddr_be); errs=errs+1; end
    @(posedge clk); blt_wr=0;

    // -----------------------------------------------------------------------
    // 4) NON-FB read: ddr_rd asserted; blt_busy/blt_dout/blt_dout_ready track
    //    ddr_busy/ddr_dout/ddr_dout_ready combinationally.
    // -----------------------------------------------------------------------
    @(negedge clk);
    blt_addr=32'h07600008; blt_rd=1; ddr_busy=1;
    #1;
    if (!ddr_rd)    begin $display("FAIL T4: ring read not on ddr_rd"); errs=errs+1; end
    if (!blt_busy)  begin $display("FAIL T4: blt_busy did not track ddr_busy"); errs=errs+1; end
    ddr_busy=0; ddr_dout=64'hCAFE_CAFE_CAFE_CAFE; ddr_dready=1;
    #1;
    if (blt_busy)     begin $display("FAIL T4: blt_busy did not clear with ddr_busy"); errs=errs+1; end
    if (!blt_dready)  begin $display("FAIL T4: blt_dout_ready did not track ddr_dout_ready"); errs=errs+1; end
    if (blt_dout !== 64'hCAFE_CAFE_CAFE_CAFE)
      begin $display("FAIL T4: blt_dout mismatch (got %h)", blt_dout); errs=errs+1; end
    @(posedge clk); blt_rd=0; ddr_dready=0;

    // -----------------------------------------------------------------------
    // 5) FB0 read: identical treatment to non-FB (no special-casing left).
    //    [Stage 5 Phase 2] Previously this asserted sd_rd and returned
    //    sd_dout via the rd_on_sdram latch; now it is the same DDR
    //    passthrough as test 4, just at an FB address.
    // -----------------------------------------------------------------------
    @(negedge clk);
    blt_addr={3'd0,`FB_DDR0_QW + 29'd10}; blt_rd=1; ddr_busy=1;
    #1;
    if (!ddr_rd)   begin $display("FAIL T5: FB0 read not on ddr_rd"); errs=errs+1; end
    if (!blt_busy) begin $display("FAIL T5: FB0 read blt_busy did not track ddr_busy"); errs=errs+1; end
    if (ddr_addr !== (`FB_DDR0_QW + 29'd10))
      begin $display("FAIL T5: FB0 read ddr_addr wrong (got %h)", ddr_addr); errs=errs+1; end
    ddr_busy=0; ddr_dout=64'h5555_AAAA_5555_AAAA; ddr_dready=1;
    #1;
    if (blt_busy)    begin $display("FAIL T5: FB0 read blt_busy did not clear"); errs=errs+1; end
    if (!blt_dready) begin $display("FAIL T5: FB0 read blt_dout_ready not asserted"); errs=errs+1; end
    if (blt_dout !== 64'h5555_AAAA_5555_AAAA)
      begin $display("FAIL T5: FB0 read dout wrong (got %h)", blt_dout); errs=errs+1; end
    @(posedge clk); blt_rd=0; ddr_dready=0;

    // -----------------------------------------------------------------------
    // 6) N-beat burst read: burstcnt=4 is informational only -- the demux is
    //    stateless and does not walk beats itself (ddr_blitter_arb now owns
    //    burst sequencing). Every ddr_dout_ready pulse the DDR side produces
    //    must reach blt_dout_ready with matching data; none may be dropped.
    //    Guards the historical "multi-beat DDR read returns one beat" wedge
    //    at the demux boundary.
    // -----------------------------------------------------------------------
    begin : burst_test
      integer b; integer seen;
      reg [63:0] beat_data [0:3];
      seen = 0;
      blt_burstcnt = 8'd4;
      @(negedge clk);
      blt_addr = {3'd0, `FB_DDR0_QW}; blt_rd = 1'b1;
      for (b = 0; b < 4; b = b + 1) begin
        beat_data[b] = 64'hB000_0000_0000_0000 + b;
        @(negedge clk);
        ddr_dout = beat_data[b]; ddr_dready = 1'b1;
        #1;
        if (!blt_dready) begin
          $display("FAIL T6: beat %0d blt_dout_ready not asserted", b); errs = errs + 1;
        end else begin
          if (blt_dout !== beat_data[b]) begin
            $display("FAIL T6: beat %0d data mismatch (got %h want %h)", b, blt_dout, beat_data[b]);
            errs = errs + 1;
          end
          seen = seen + 1;
        end
        @(negedge clk); ddr_dready = 1'b0;
      end
      blt_rd = 1'b0;
      if (seen !== 4) begin $display("FAIL T6: only %0d/4 beats forwarded", seen); errs = errs + 1; end
      else $display("Test 6 burst-read N=4 forwarded intact: PASS");
      blt_burstcnt = 8'd1;
    end
    @(posedge clk);

    if (errs==0) $display("RESULT: PASS"); else $display("RESULT: FAIL (%0d)", errs);
    $finish;
  end
endmodule
`default_nettype wire
