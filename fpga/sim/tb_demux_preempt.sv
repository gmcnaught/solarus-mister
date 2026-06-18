// tb_demux_preempt.sv — directed reproduction of the #34 blitter-wedge:
// vram_demux's SDRAM dst READ is lost when sdram_src_arb preempts it (grants a
// higher-priority SCAN/SRC client) on the exact issue edge.
//
// The HW probe (devmem 0x3A070004) caught the blitter frozen in S_RD_WAIT with
// the demux in S_RDLAT, the SDRAM controller IDLE (sps_ready=1) and P_DST FREE
// (dst_busy=0) — i.e. a dst read that was issued but never serviced. Root cause:
// S_IDLE asserts sd_rd for ONE combinatorial cycle (gated on !sd_busy), but
// !sd_busy does not guarantee a grant under the strict-priority arbiter; a
// concurrent SCAN/SRC request wins and the one-cycle pulse is dropped, stranding
// the demux in S_RDLAT forever. (The write path already holds-until-accepted via
// S_BWAIT; the read path did not.)
//
// This tb models the arbiter with a behavioral SDRAM that, on the demux's first
// sd_rd, PREEMPTS it (busy for a few cycles, read NOT accepted), then services
// the read only if sd_rd is STILL asserted afterward — exactly what a held
// request needs. Pre-fix (pulse) => demux hangs in S_RDLAT (watchdog WEDGE).
// Post-fix (sd_rd held until sd_dready) => the read completes => PASS.
`timescale 1ns/1ps
`default_nettype none
`include "vram_defs.vh"

module tb_demux_preempt;
  reg clk=0; always #5 clk=~clk;
  reg reset=1;

  // blitter side
  reg  [31:0] blt_addr=0; reg blt_rd=0, blt_wr=0; reg [63:0] blt_din=0; reg [7:0] blt_be=0;
  wire [63:0] blt_dout; wire blt_dready; wire blt_busy;
  // DDR side (unused here — FB reads go to SDRAM)
  wire [28:0] ddr_addr; wire ddr_rd, ddr_wr; wire [63:0] ddr_din; wire [7:0] ddr_be;
  reg  [63:0] ddr_dout=0; reg ddr_dready=0; reg ddr_busy=0;
  // SDRAM side
  wire [26:0] sd_addr; wire sd_rd, sd_we, sd_we_burst; wire [15:0] sd_din; wire [63:0] sd_din64;
  reg  [63:0] sd_dout64=64'hCAFE_CAFE_CAFE_CAFE; reg sd_dready=0; reg sd_busy=0;
  // #34: behavioral arbiter grant pulse (P_DST accepted while not busy). This tb
  // exercises READS (which use sd_dready, not sd_grant), but the demux input must
  // be driven; model it like the real arbiter for completeness.
  reg sd_grant=0;
  always @(posedge clk) sd_grant <= (sd_we_burst | sd_we | sd_rd) & ~sd_busy;
  wire [3:0]  vdemux_dbg;

  vram_demux dut(.clk(clk),.reset(reset),
    .blt_addr(blt_addr),.blt_rd(blt_rd),.blt_wr(blt_wr),.blt_din(blt_din),.blt_be(blt_be),
    .blt_dout(blt_dout),.blt_dout_ready(blt_dready),.blt_busy(blt_busy),
    .ddr_addr(ddr_addr),.ddr_rd(ddr_rd),.ddr_wr(ddr_wr),.ddr_din(ddr_din),.ddr_be(ddr_be),
    .ddr_dout(ddr_dout),.ddr_dout_ready(ddr_dready),.ddr_busy(ddr_busy),
    .sd_addr(sd_addr),.sd_rd(sd_rd),.sd_din(sd_din),.sd_we(sd_we),
    .sd_din64(sd_din64),.sd_we_burst(sd_we_burst),
    .sd_dout64(sd_dout64),.sd_dready(sd_dready),.sd_busy(sd_busy),.sd_grant(sd_grant),
    .dbg(vdemux_dbg));

  // ---- behavioral SDRAM + arbiter PREEMPTION model -------------------------
  // PRE: idle (sd_busy=0). On the demux's first sd_rd, model the arbiter granting
  //      a higher-priority SCAN burst instead: go BUSY for SCAN_CYCLES, do NOT
  //      accept the dst read.
  // ARM: SCAN done (sd_busy=0). If sd_rd is STILL asserted, accept -> READ.
  //      (Pre-fix the demux dropped sd_rd one cycle after issue, so sd_rd=0 here
  //       and the read is never serviced.)
  // RD : after READ_LAT, pulse sd_dready once -> back to PRE.
  localparam integer SCAN_CYCLES = 6;
  localparam integer READ_LAT    = 3;
  localparam [1:0] M_PRE=2'd0, M_SCAN=2'd1, M_ARM=2'd2, M_RD=2'd3;
  reg [1:0] m = M_PRE;
  integer cnt = 0;
  always @(posedge clk) begin
    sd_dready <= 1'b0;
    if (reset) begin m <= M_PRE; sd_busy <= 1'b0; cnt <= 0; end
    else case (m)
      M_PRE: begin
        sd_busy <= 1'b0;
        if (sd_rd) begin           // demux issued -> arbiter gives the bus to SCAN
          m <= M_SCAN; cnt <= SCAN_CYCLES; sd_busy <= 1'b1;
        end
      end
      M_SCAN: begin                // SCAN burst owns the bus; dst read NOT accepted
        if (cnt <= 1) begin m <= M_ARM; sd_busy <= 1'b0; end
        else cnt <= cnt - 1;
      end
      M_ARM: begin                 // bus free again: service the read IFF still requested
        if (sd_rd) begin m <= M_RD; cnt <= READ_LAT; sd_busy <= 1'b1; end
        else        m <= M_PRE;    // pulse was lost -> read never serviced (the bug)
      end
      M_RD: begin
        if (cnt <= 1) begin sd_dready <= 1'b1; sd_busy <= 1'b0; m <= M_PRE; end
        else cnt <= cnt - 1;
      end
    endcase
  end

  // ---- stimulus: issue ONE FB (SDRAM) read, expect it to complete -----------
  localparam S_RDLAT = 3'd1;
  integer i; reg got;
  initial begin
    repeat (4) @(posedge clk); reset <= 0;
    @(negedge clk);
    blt_addr <= `FB_DDR0_QW + 32'd100;   // FB region -> demux routes to SDRAM
    blt_rd   <= 1'b1;
    // hold blt_rd like the blitter does in S_RD_WAIT (until data returns)
    got = 0;
    for (i = 0; i < 2000; i = i + 1) begin
      @(posedge clk);
      if (blt_dready) begin got = 1; end
      if (got) i = 2000;
    end
    blt_rd <= 1'b0;
    if (got) $display("RESULT: PASS (preempted dst read recovered; demux held sd_rd)");
    else begin
      $display("WEDGE: dst read lost to arbiter preemption; demux stuck in S_RDLAT=%0d (dbg=%h)",
               dut.st, vdemux_dbg);
      $display("RESULT: WEDGE");
    end
    $finish;
  end
  initial begin #200000 $display("RESULT: WEDGE (timeout)"); $finish; end
endmodule
`default_nettype wire
