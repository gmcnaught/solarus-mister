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
  // model the SDRAM 16-bit word writes
  // Use sd_addr>>1 (full word address) so the write index matches the check index
  // (which computes (SDRAM_FBx_BASE + byte_offset)>>1 directly).
  always @(posedge clk) begin
    if (sd_we)        sdmem[sd_addr>>1] <= sd_din;
    if (sd_we_burst)  begin
      sdmem[(sd_addr>>1)+0]<=sd_din64[15:0];  sdmem[(sd_addr>>1)+1]<=sd_din64[31:16];
      sdmem[(sd_addr>>1)+2]<=sd_din64[47:32]; sdmem[(sd_addr>>1)+3]<=sd_din64[63:48];
    end
  end

  initial begin
    repeat(4) @(posedge clk); reset=0; @(posedge clk);

    // 1) NON-FB write routes to DDR (RING region), NOT SDRAM
    blt_addr=32'h07600008; blt_wr=1; blt_din=64'h1; blt_be=8'hFF; @(posedge clk);
    if (!ddr_wr || sd_we || sd_we_burst) begin $display("FAIL: ring write not on DDR"); errs=errs+1; end
    blt_wr=0; @(posedge clk);

    // 2) FB0 full-qword write routes to SDRAM as a BURST write, address remapped
    blt_addr={3'd0,`FB_DDR0_QW};               // first qword of FB0
    blt_wr=1; blt_din=64'hAAAA_BBBB_CCCC_DDDD; blt_be=8'hFF; @(posedge clk);
    if (!sd_we_burst || ddr_wr) begin $display("FAIL: FB full-qword not a SDRAM burst"); errs=errs+1; end
    if (sd_addr !== `SDRAM_FB0_BASE) begin $display("FAIL: FB0 base addr remap %h", sd_addr); errs=errs+1; end
    blt_wr=0; @(posedge clk);

    // 3) FB1 single-pixel (one lane) write -> a SINGLE 16-bit SDRAM word at lane col
    blt_addr={3'd0,`FB_DDR1_QW + 29'd5};        // qword 5 of FB1
    blt_wr=1; blt_din=64'h0000_0000_1234_0000; blt_be=8'h0C; @(posedge clk); // lane1 (bytes 2-3)
    // expect one sd_we to SDRAM_FB1_BASE + 5*8 + 1*2 (col word = qw*4 + lane)
    @(posedge clk);
    if (sdmem[(`SDRAM_FB1_BASE + 5*8 + 1*2) >> 1] !== 16'h1234) begin
      $display("FAIL: FB1 lane write wrong word"); errs=errs+1; end
    blt_wr=0; @(posedge clk);

    // 4) FB read routes to SDRAM, dout returns from sd_dout64
    sd_dout64=64'hCAFE_CAFE_CAFE_CAFE;
    blt_addr={3'd0,`FB_DDR0_QW + 29'd10}; blt_rd=1; @(posedge clk); blt_rd=0;
    sd_dready=1; @(posedge clk); sd_dready=0;
    if (blt_dout !== 64'hCAFE_CAFE_CAFE_CAFE) begin $display("FAIL: FB read dout not from SDRAM"); errs=errs+1; end

    // 5) NON-FB read routes to DDR, dout returns from ddr_dout
    blt_addr=32'h07600008; blt_rd=1; @(posedge clk); blt_rd=0;
    ddr_dready=1; @(posedge clk); ddr_dready=0;
    if (blt_dout !== 64'hD00D_D00D_D00D_D00D) begin $display("FAIL: ring read dout not from DDR"); errs=errs+1; end

    if (errs==0) $display("RESULT: PASS"); else $display("RESULT: FAIL (%0d)", errs);
    $finish;
  end
endmodule
`default_nettype wire
