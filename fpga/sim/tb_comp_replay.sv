// tb_comp_replay.sv — replay the REAL captured title command-ring through the
// compositor write path and dump the composited framebuffer (#44 banding hunt).
//
// We froze the engine on the Mystery-of-Solarus-DX title (submit==done_seq), dumped
// the 2 MiB blitter DDR region (control block @0x3B000000 + ring @+0x40 + source heap
// @+0x8000) via /dev/mem, and load it here verbatim into the behavioral DDR (mem index
// 0x200000 == DDR byte 0x3B000000). Re-triggering the blitter (bump submit) makes the
// REAL command list (FILL + 11 PALPHA blits: full-screen cloud bg + 4 clipped cloud
// tiles + logo/text + END) composite into FB0 through the exact RTL path. We then dump
// FB0 (320x240 RGB565) to fb0_replay.bin for visual diff against the HW screenshot.
//
//   sim FB banded  -> a WRITE-PATH / command bug (debuggable in sim, deterministic)
//   sim FB clean   -> the on-HW banding is HW-only (timing/electrical), since the exact
//                     same commands + source pixels compose cleanly here.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
`include "vram_defs.vh"

module tb_comp_replay;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = 32'h240000;             // covers loaded 0x200000..0x240000
  localparam integer FBW = 320, FBH = 240, ROW_QW = FBW/4, ROW_B = FBW*2;

  reg clk_sys = 0;   always #5 clk_sys   = ~clk_sys;
  reg clk_sdram = 1; always #5 clk_sdram = ~clk_sdram;
  reg reset = 1;

  // ---- blitter -> vram_demux ----
  wire [31:0] bt_addr; wire bt_rd, bt_wr; wire [63:0] bt_din; wire [7:0] bt_be;
  wire [7:0]  bt_burstcnt; wire bt_idle; wire [31:0] blt_dbg;
  wire [63:0] blt_demux_dout; wire blt_demux_dready, blt_busy_w;
  wire [28:0] bd_addr; wire bd_rd, bd_wr; wire [63:0] bd_din; wire [7:0] bd_be;
  wire        b_grant; wire blt_arb_busy;
  wire [26:0] bs_p0_addr; wire bs_p0_rd;
  wire        bs_we; wire [15:0] bs_din; wire [26:0] bs_waddr;
  wire        bs_we_burst; wire [63:0] bs_din64; wire [3:0] vdemux_dbg;

  // [collapse-single-source] source read is hardwired to SDRAM (src_in_sdram=1):
  // serve p0_* from the captured source heap loaded into mem at SRC_QW
  // (mem[0x201000+]). Decls here; always block placed after mem[] so the read binds.
  localparam P_SRC_LAT = 3;
  localparam [28:0] SRC_WIN = `SRC_QW - WBASE;   // 0x201000
  reg  [63:0] bs_p0_dout; reg bs_p0_ok = 1'b0;
  reg         bs_rd_d;
  reg [26:0]  bs_lat_addr [0:P_SRC_LAT-1];
  reg         bs_lat_v    [0:P_SRC_LAT-1];
  integer     bsli;

  blitter_top blt (
    .clk(clk_sys), .rst(reset),
    .mem_addr(bt_addr), .mem_rd(bt_rd), .mem_wr(bt_wr), .mem_burstcnt(bt_burstcnt),
    .mem_din(bt_din), .mem_be(bt_be),
    .mem_dout(blt_demux_dout), .mem_dout_ready(blt_demux_dready), .mem_busy(blt_busy_w),
    .p0_addr(bs_p0_addr), .p0_rd(bs_p0_rd), .p0_dout(bs_p0_dout), .p0_ok(bs_p0_ok),
    .src_sdram_we(bs_we), .src_sdram_din(bs_din), .src_sdram_waddr(bs_waddr),
    .src_sdram_we_burst(bs_we_burst), .src_sdram_din64(bs_din64), .src_sdram_ok(1'b1),
    .idle(bt_idle), .dbg(blt_dbg));

  wire [26:0] dst_addr; wire dst_rd, dst_wr;
  wire [63:0] dst_din;  wire [7:0] dst_wdsn;
  wire [63:0] dst_dout; wire dst_ok;
  wire [7:0] d_burst; wire [28:0] d_addr; wire d_rd; wire [63:0] d_din;
  wire [7:0] d_be;    wire d_we;
  wire       d_busy;  reg d_dready = 0; reg [63:0] d_dout = 0;

  vram_demux vdemux (
    .clk(clk_sys), .reset(reset),
    .blt_addr(bt_addr), .blt_rd(bt_rd), .blt_wr(bt_wr), .blt_din(bt_din), .blt_be(bt_be),
    .blt_burstcnt(bt_burstcnt),
    .blt_dout(blt_demux_dout), .blt_dout_ready(blt_demux_dready), .blt_busy(blt_busy_w),
    .ddr_addr(bd_addr), .ddr_rd(bd_rd), .ddr_wr(bd_wr), .ddr_din(bd_din), .ddr_be(bd_be),
    .ddr_dout(d_dout), .ddr_dout_ready(d_dready & b_grant), .ddr_busy(blt_arb_busy),
    .sd_addr(dst_addr), .sd_rd(dst_rd), .sd_wr(dst_wr),
    .sd_din(dst_din), .sd_wdsn(dst_wdsn), .sd_dout(dst_dout), .sd_ok(dst_ok),
    .dbg(vdemux_dbg));

  ddr_blitter_arb #(.ENABLE(1'b1)) arb_ddr (
    .clk(clk_sys), .reset(reset),
    .rdr_burstcnt(8'd0), .rdr_addr(29'd0), .rdr_rd(1'b0), .rdr_din(64'd0),
    .rdr_be(8'd0), .rdr_we(1'b0), .rdr_busy(), .rdr_grant(),
    .blt_burstcnt(bt_burstcnt), .blt_addr(bd_addr), .blt_rd(bd_rd), .blt_din(bd_din),
    .blt_be(bd_be), .blt_we(bd_wr), .blt_busy(blt_arb_busy), .blt_grant(b_grant),
    .ddram_busy(d_busy), .ddram_dout_ready(d_dready),
    .ddram_burstcnt(d_burst), .ddram_addr(d_addr), .ddram_rd(d_rd),
    .ddram_din(d_din), .ddram_be(d_be), .ddram_we(d_we), .dbg());

  reg  [26:0] scan_addr_r = 27'd0;  reg scan_rd_r = 1'b0;
  wire [63:0] scan_dout;  wire scan_ok;
  reg         vs_r = 1'b0;  wire coh_busy;
  wire [15:0] SDQ; wire [12:0] SA; wire SDQML, SDQMH; wire [1:0] SBA;
  wire        SnCS, SnWE, SnRAS, SnCAS, SCKE, cache_sdram_clk;

  sdram_fb_cache fbcache (
    .clk(clk_sys), .clk_sdram(clk_sys), .rst(reset), .init(),
    .dst_addr(dst_addr), .dst_rd(dst_rd), .dst_wr(dst_wr),
    .dst_din(dst_din), .dst_wdsn(dst_wdsn), .dst_dout(dst_dout), .dst_ok(dst_ok),
    .scan_addr(scan_addr_r), .scan_rd(scan_rd_r), .scan_dout(scan_dout), .scan_ok(scan_ok),
    .p0_addr(27'd0), .p0_rd(1'b0), .p0_dout(), .p0_ok(),
    .stage_addr(27'd0), .stage_wr(1'b0), .stage_din(64'd0), .stage_wdsn(8'hff), .stage_ok(),
    .stage_barrier(1'b0), .stage_busy(),   // no STAGE in this bench
    .dst_barrier(1'b0), .dst_busy(),       // no carry-forward in this bench
    .vs(vs_r), .coh_busy(coh_busy),
    .sdram_dq(SDQ), .sdram_a(SA), .sdram_dqml(SDQML), .sdram_dqmh(SDQMH),
    .sdram_ba(SBA), .sdram_nwe(SnWE), .sdram_ncas(SnCAS), .sdram_nras(SnRAS),
    .sdram_ncs(SnCS), .sdram_cke(SCKE), .sdram_clk(cache_sdram_clk));

  mt48lc16m16a2 #(.addr_bits(13), .col_bits(10)) schip (
    .Dq(SDQ), .Addr(SA), .Ba(SBA), .Clk(clk_sdram), .Cke(SCKE),
    .Cs_n(SnCS), .Ras_n(SnRAS), .Cas_n(SnCAS), .We_n(SnWE), .Dqm({SDQMH, SDQML}),
    .downloading(1'b0), .VS(1'b0), .frame_cnt(32'd0));

  // ---- behavioral DDR3 ----
  reg [63:0] mem [0:MEMQW-1];

  // P_SRC cache-ok behavioral source model (after mem[] so the read binds).
  always @(posedge clk_sys) bs_rd_d <= bs_p0_rd;
  always @(posedge clk_sys) begin
    bs_p0_ok <= 1'b0;
    bs_lat_v   [0] <= bs_p0_rd & ~bs_rd_d;
    bs_lat_addr[0] <= bs_p0_addr;
    for (bsli = 1; bsli < P_SRC_LAT; bsli = bsli + 1) begin
      bs_lat_v   [bsli] <= bs_lat_v   [bsli-1];
      bs_lat_addr[bsli] <= bs_lat_addr[bsli-1];
    end
    if (bs_lat_v[P_SRC_LAT-1]) begin
      bs_p0_dout <= mem[SRC_WIN + (bs_lat_addr[P_SRC_LAT-1] >> 3)];
      bs_p0_ok   <= 1'b1;
    end
  end

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

  wire [31:0] done_seq = mem[32'h200005][31:0];
  wire [31:0] cmd_count = mem[32'h200001][31:0];

  task scan_read(input [26:0] byte_addr, output [63:0] q);
    integer cyc;
    begin
      cyc=0; @(posedge clk_sys); #1;
      scan_addr_r = byte_addr; scan_rd_r = 1'b1;
      @(posedge clk_sys); #1; scan_rd_r = 1'b0;
      while (!scan_ok) begin @(posedge clk_sys); cyc=cyc+1;
        if (cyc>5000) begin $display("RESULT: FAIL - scan_read timeout @%h", byte_addr); $finish; end end
      q = scan_dout;
    end
  endtask

  // heartbeat
  integer hb=0;
  always @(posedge clk_sys) if (!reset) begin
    hb=hb+1;
    if (hb % 1_000_000 == 0)
      $display("[hb %0t] blt.state=%0d done=%0d cmdcnt=%0d", $time, blt.state, done_seq, cmd_count);
  end

  integer y, qw, fd, settle, cap_submit;
  reg [63:0] q, qb;
  reg [15:0] px;
  initial begin
    for (i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    $readmemh("bltdump.hex", mem, 32'h200000);   // load captured DDR image
    $display("loaded capture: submit=%0d cmd_count=%0d target=%0d flags=%0d csrcsel=%0d",
             mem[32'h200000][31:0], mem[32'h200001][31:0], mem[32'h200002][31:0],
             mem[32'h200004][31:0], mem[32'h200007][31:0]);

    repeat (16) @(posedge clk_sys);
    reset = 1'b0;
    repeat (8) @(posedge clk_sys);

    // re-trigger the captured command list (bump submit)
    cap_submit = mem[32'h200000][31:0];
    mem[32'h200000] = (cap_submit + 1);
    $display("re-triggered: submit %0d -> %0d", cap_submit, cap_submit+1);

    settle = 0;
    while (done_seq !== (cap_submit+1) && settle < 200_000_000) begin
      @(posedge clk_sys); settle=settle+1;
      if (settle % 100_000 == 0) $display("  ...settle=%0d done=%0d blt.state=%0d", settle, done_seq, blt.state);
    end
    if (done_seq !== (cap_submit+1)) begin
      $display("RESULT: FAIL - compositor never completed (done=%0d want=%0d blt.state=%0d)",
               done_seq, cap_submit+1, blt.state);
      $finish;
    end
    $display("composited real frame in %0d cyc (blt.state=%0d)", settle, blt.state);

    // coherency flush
    @(posedge clk_sys); #1; vs_r=1'b1; repeat(4) @(posedge clk_sys); #1; vs_r=1'b0;
    settle=0; while (coh_busy) begin @(posedge clk_sys); settle=settle+1;
      if (settle>2_000_000) begin $display("RESULT: FAIL - coh_busy stuck"); $finish; end end
    $display("flush complete; dumping FB0...");

    // dump FB0 320x240 RGB565 -> fb0_replay.bin (little-endian per pixel)
    fd = $fopen("fb0_replay.bin","wb");
    for (y=0; y<FBH; y=y+1) begin
      for (qw=0; qw<ROW_QW; qw=qw+1) begin
        scan_read(27'(`SDRAM_FB0_BASE) + 27'(y*ROW_B + qw*8), q);
        for (i=0;i<4;i=i+1) begin
          px = q[i*16 +:16];
          $fwrite(fd, "%c", px[7:0]); $fwrite(fd, "%c", px[15:8]);
        end
      end
      if (y % 40 == 0) $display("  dumped row %0d/%0d", y, FBH);
    end
    $fclose(fd);
    $display("RESULT: PASS  (FB0 dumped to fb0_replay.bin - inspect for banding)");
    $finish;
  end

  initial begin
    #4_000_000_000;
    $display("RESULT: FAIL - global timeout (done=%0d)", done_seq);
    $finish;
  end
endmodule
`default_nettype wire
