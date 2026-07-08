// tb_bgw_ch0_mux.sv — standalone TB for bgw_ch0_mux [Phase 3b bg-plane bake].
//
// Verifies the ch0 (P_DST) write-side priority mux in isolation:
//   (a) bgw_active=0 -> dst_* == vd_sd_* exactly (vram_demux passthrough).
//   (b) bgw_active=1 -> dst_* == bgw_dst_* exactly (bake gets exclusive control).
//   (c) dst_ok is not part of this module (it fans out unconditionally at the
//       Solarus.sv integration layer, unmodified, to both consumers) -- this
//       TB documents that contract by exercising the mux only on the write
//       side, matching bgw_ch0_mux's actual port list (no dst_ok port at all).
`timescale 1ns/1ps
`default_nettype none

module tb_bgw_ch0_mux;
  reg         bgw_active;
  reg         bgw_dst_wr;
  reg  [26:0] bgw_dst_addr;
  reg  [63:0] bgw_dst_din;
  reg  [7:0]  bgw_dst_wdsn;
  reg         vd_sd_wr;
  reg  [26:0] vd_sd_addr;
  reg  [63:0] vd_sd_din;
  reg  [7:0]  vd_sd_wdsn;
  wire        dst_wr;
  wire [26:0] dst_addr;
  wire [63:0] dst_din;
  wire [7:0]  dst_wdsn;

  bgw_ch0_mux dut (
    .bgw_active   (bgw_active),
    .bgw_dst_wr   (bgw_dst_wr),
    .bgw_dst_addr (bgw_dst_addr),
    .bgw_dst_din  (bgw_dst_din),
    .bgw_dst_wdsn (bgw_dst_wdsn),
    .vd_sd_wr     (vd_sd_wr),
    .vd_sd_addr   (vd_sd_addr),
    .vd_sd_din    (vd_sd_din),
    .vd_sd_wdsn   (vd_sd_wdsn),
    .dst_wr       (dst_wr),
    .dst_addr     (dst_addr),
    .dst_din      (dst_din),
    .dst_wdsn     (dst_wdsn)
  );

  integer errs = 0;

  task check_vd_side(input [255:0] tag);
    begin
      if (dst_wr !== vd_sd_wr) begin
        $display("  FAIL %0s: dst_wr=%b want vd_sd_wr=%b", tag, dst_wr, vd_sd_wr); errs = errs + 1;
      end
      if (dst_addr !== vd_sd_addr) begin
        $display("  FAIL %0s: dst_addr=%h want vd_sd_addr=%h", tag, dst_addr, vd_sd_addr); errs = errs + 1;
      end
      if (dst_din !== vd_sd_din) begin
        $display("  FAIL %0s: dst_din=%h want vd_sd_din=%h", tag, dst_din, vd_sd_din); errs = errs + 1;
      end
      if (dst_wdsn !== vd_sd_wdsn) begin
        $display("  FAIL %0s: dst_wdsn=%h want vd_sd_wdsn=%h", tag, dst_wdsn, vd_sd_wdsn); errs = errs + 1;
      end
    end
  endtask

  task check_bgw_side(input [255:0] tag);
    begin
      if (dst_wr !== bgw_dst_wr) begin
        $display("  FAIL %0s: dst_wr=%b want bgw_dst_wr=%b", tag, dst_wr, bgw_dst_wr); errs = errs + 1;
      end
      if (dst_addr !== bgw_dst_addr) begin
        $display("  FAIL %0s: dst_addr=%h want bgw_dst_addr=%h", tag, dst_addr, bgw_dst_addr); errs = errs + 1;
      end
      if (dst_din !== bgw_dst_din) begin
        $display("  FAIL %0s: dst_din=%h want bgw_dst_din=%h", tag, dst_din, bgw_dst_din); errs = errs + 1;
      end
      if (dst_wdsn !== bgw_dst_wdsn) begin
        $display("  FAIL %0s: dst_wdsn=%h want bgw_dst_wdsn=%h", tag, dst_wdsn, bgw_dst_wdsn); errs = errs + 1;
      end
    end
  endtask

  initial begin
    // ---- (a) bgw_active=0: dst_* must track vd_sd_* exactly, regardless of
    // whatever bgw_dst_* happens to be driving (it must be fully ignored). ----
    bgw_active   = 1'b0;
    vd_sd_wr     = 1'b1;
    vd_sd_addr   = 27'h0AA_AAAA;
    vd_sd_din    = 64'hCAFE_F00D_1234_5678;
    vd_sd_wdsn   = 8'h00;
    bgw_dst_wr   = 1'b1;              // deliberately conflicting/nonzero
    bgw_dst_addr = 27'h055_5555;
    bgw_dst_din  = 64'h1111_2222_3333_4444;
    bgw_dst_wdsn = 8'hFF;
    #1;
    check_vd_side("a1: bgw_active=0, vd_sd_wr=1");

    vd_sd_wr = 1'b0;
    #1;
    check_vd_side("a2: bgw_active=0, vd_sd_wr=0");

    // ---- (b) bgw_active=1: dst_* must track bgw_dst_* exactly, regardless of
    // whatever vd_sd_* happens to be driving (it must be fully held off). ----
    bgw_active = 1'b1;
    #1;
    check_bgw_side("b1: bgw_active=1, vd_sd_wr=0");

    vd_sd_wr   = 1'b1;   // vram_demux "wants" the bus too -- must still be held off
    #1;
    check_bgw_side("b2: bgw_active=1, vd_sd_wr=1 (must be held off)");

    bgw_dst_wr = 1'b0;
    #1;
    check_bgw_side("b3: bgw_active=1, bgw_dst_wr=0");

    // ---- randomized sweep for extra confidence ----
    begin : sweep
      integer i;
      for (i = 0; i < 200; i = i + 1) begin
        bgw_active   = $urandom;
        bgw_dst_wr   = $urandom;
        bgw_dst_addr = $urandom;
        bgw_dst_din  = {$urandom, $urandom};
        bgw_dst_wdsn = $urandom;
        vd_sd_wr     = $urandom;
        vd_sd_addr   = $urandom;
        vd_sd_din    = {$urandom, $urandom};
        vd_sd_wdsn   = $urandom;
        #1;
        if (bgw_active) check_bgw_side("sweep(bgw_active=1)");
        else            check_vd_side("sweep(bgw_active=0)");
      end
    end

    if (errs == 0) $display("RESULT: PASS");
    else           $display("RESULT: FAIL (%0d mismatches)", errs);
    $finish;
  end

  initial begin #100000 $display("RESULT: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire
