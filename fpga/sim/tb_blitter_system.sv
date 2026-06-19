// tb_blitter_system.sv — full-system sim: arbiter + blitter_top + backpressuring
// DDR + a fake video reader. Preloads a real command list (CLEAR=blue + FILL red
// rect + END) into the DDR command ring, runs the blitter THROUGH the arbiter,
// and checks (a) the blitter composited the framebuffer correctly, (b) it wrote
// the video control word, and (c) the reader's concurrent burst reads are
// uncorrupted (no arbiter misrouting), with no hang. No Altera primitives.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
`include "vram_defs.vh"

module tb_blitter_system;
  localparam [28:0] WBASE = 29'h07400000;    // window base; mem index = addr-WBASE
  localparam        MEMQW = 32'h202000;       // 131072 qwords window

  reg clk=0, reset=1; always #5 clk=~clk;

  // ---- reader (m0) fake master ----
  reg [7:0] r_burst; reg[28:0] r_addr; reg r_rd; reg[63:0] r_din; reg[7:0] r_be; reg r_we;
  wire r_busy, r_grant;
  // ---- blitter (m1) mem_* -> vram_demux -> {DDR arb | SDRAM P_DST} ----
  // The demux's DDR side (bd_*) drives the DDR blitter arb's blt_* port; its SDRAM
  // side (dst_*) drives the arbiter P_DST port. FB0/FB1 accesses go to SDRAM, the
  // command ring / control / VCTRL / source-heap stay on the DDR behavioral mem.
  wire [31:0] bt_addr; wire bt_rd, bt_wr; wire [63:0] bt_din; wire [7:0] bt_be;
  wire bt_idle;
  wire [63:0] blt_demux_dout; wire blt_demux_dready, blt_busy_w;
  // demux DDR side -> ddr_blitter_arb blt_*
  wire [28:0] bd_addr; wire bd_rd, bd_wr; wire [63:0] bd_din; wire [7:0] bd_be;
  wire b_grant; wire blt_arb_busy;
  // ---- DDRAM ----
  wire [7:0] d_burst; wire[28:0] d_addr; wire d_rd; wire[63:0] d_din; wire[7:0] d_be; wire d_we;
  wire d_busy; reg d_dready; reg[63:0] d_dout;

  ddr_blitter_arb #(.ENABLE(1'b1)) arb(
    .clk(clk), .reset(reset),
    .rdr_burstcnt(r_burst), .rdr_addr(r_addr), .rdr_rd(r_rd), .rdr_din(r_din),
    .rdr_be(r_be), .rdr_we(r_we), .rdr_busy(r_busy), .rdr_grant(r_grant),
    .blt_addr(bd_addr), .blt_rd(bd_rd), .blt_din(bd_din), .blt_be(bd_be), .blt_we(bd_wr),
    .blt_busy(blt_arb_busy), .blt_grant(b_grant),
    .ddram_busy(d_busy), .ddram_dout_ready(d_dready),
    .ddram_burstcnt(d_burst), .ddram_addr(d_addr), .ddram_rd(d_rd),
    .ddram_din(d_din), .ddram_be(d_be), .ddram_we(d_we));

  // ---- SDRAM SOURCE/STAGE path (issue #19): blitter ports -> arb P_SRC --------
  // When C_SRCSEL=1 the blitter routes SOURCE reads here instead of the DDR3 mem_*.
  // BLT_OP_STAGE writes also route here (src_sdram_we/din/waddr from blitter_top).
  wire [26:0] bs_addr; wire bs_rd; wire [63:0] bs_dout64; wire bs_dready; wire bs_busy;
  // staging write outputs from blitter_top (BLT_OP_STAGE DDR3->SDRAM copy)
  wire        bs_we; wire [15:0] bs_din; wire [26:0] bs_waddr;
  wire        bs_we_burst; wire [63:0] bs_din64;

  blitter_top blt(
    .clk(clk), .rst(reset),
    .mem_addr(bt_addr), .mem_rd(bt_rd), .mem_wr(bt_wr), .mem_din(bt_din), .mem_be(bt_be),
    // mem read-data + busy now come from vram_demux (DDR or SDRAM per address)
    .mem_dout(blt_demux_dout), .mem_dout_ready(blt_demux_dready), .mem_busy(blt_busy_w),
    .src_sdram_addr(bs_addr), .src_sdram_rd(bs_rd), .src_sdram_dout64(bs_dout64),
    .src_sdram_dout_ready(bs_dready), .src_sdram_busy(bs_busy),
    .src_sdram_we(bs_we), .src_sdram_din(bs_din), .src_sdram_waddr(bs_waddr),
    .src_sdram_we_burst(bs_we_burst), .src_sdram_din64(bs_din64),
    .idle(bt_idle));

  // ---- VRAM demux: route blitter mem_* by address (Task 2/4) -----------------
  // FB0/FB1 -> SDRAM (arbiter P_DST: dst_*); everything else -> DDR (bd_* -> arb).
  wire [26:0] dst_addr; wire dst_rd, dst_we, dst_we_burst;
  wire [15:0] dst_din; wire [63:0] dst_din64;
  wire        dst_busy; wire [63:0] dst_dout64; wire dst_dready;

  vram_demux vdemux(
    .clk(clk), .reset(reset),
    .blt_addr(bt_addr), .blt_rd(bt_rd), .blt_wr(bt_wr), .blt_din(bt_din), .blt_be(bt_be),
    .blt_dout(blt_demux_dout), .blt_dout_ready(blt_demux_dready), .blt_busy(blt_busy_w),
    // DDR side -> ddr_blitter_arb blt_*
    .ddr_addr(bd_addr), .ddr_rd(bd_rd), .ddr_wr(bd_wr), .ddr_din(bd_din), .ddr_be(bd_be),
    .ddr_dout(d_dout), .ddr_dout_ready(d_dready & b_grant), .ddr_busy(blt_arb_busy),
    // SDRAM side -> arbiter P_DST
    .sd_addr(dst_addr), .sd_rd(dst_rd), .sd_din(dst_din), .sd_we(dst_we),
    .sd_din64(dst_din64), .sd_we_burst(dst_we_burst),
    .sd_dout64(dst_dout64), .sd_dready(dst_dready), .sd_busy(dst_busy));

  // arbiter -> sdram_psx (single-beat line: BURST_BEATS=1 -> one 64-bit qword/req).
  // c_busy mapping: the controller has no "busy" output, so busy = ~ready (the
  // controller accepts a new rd ONLY at a line-complete/idle `ready` point). c_ready
  // = sdram_psx.ready (line complete). dst_busy/p0_busy (= c_busy) gate the masters.
  wire        sps_ready, sps_dready; wire [63:0] sps_dout64;
  wire [26:0] sc_addr; wire sc_rd; wire sc_we; wire [15:0] sc_din;
  wire        sc_we_burst; wire [63:0] sc_din64;
  wire sc_busy = ~sps_ready;
  wire [15:0] SDQ; wire [12:0] SA; wire SDQML, SDQMH; wire [1:0] SBA;
  wire        SnCS, SnWE, SnRAS, SnCAS, SCLK, SCKE;
  // arbiter owner-gated P_SRC read-data outputs (only valid when owner==P_SRC)
  wire [63:0] p0_dout64; wire p0_dready;

  // ONE arbiter carries BOTH the blitter SOURCE path (P_SRC) and the DEST path
  // (P_DST, from the demux) into the single sdram_psx — exactly as Solarus.sv.
  sdram_src_arb src_arb(
    .clk(clk), .reset(reset),
    // P_SCAN unused in this regression (tied off)
    .scan_addr(27'd0), .scan_rd(1'b0), .scan_burst(8'd0),
    .scan_busy(), .scan_dout64(), .scan_dready(),
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
  // P_SRC must take the arbiter's owner-gated read-data (never raw sps_*), or a
  // P_DST beat would latch into the source path.
  assign bs_dout64 = p0_dout64;
  assign bs_dready = p0_dready;

  sdram_psx #(.BURST_BEATS(1)) sps(
    .init(reset), .clk(clk),
    .SDRAM_DQ(SDQ), .SDRAM_A(SA), .SDRAM_DQML(SDQML), .SDRAM_DQMH(SDQMH),
    .SDRAM_BA(SBA), .SDRAM_nCS(SnCS), .SDRAM_nWE(SnWE), .SDRAM_nRAS(SnRAS),
    .SDRAM_nCAS(SnCAS), .SDRAM_CLK(SCLK), .SDRAM_CKE(SCKE),
    .wtbt(2'b11), .addr(sc_addr), .dout(),
    .dout64(sps_dout64), .dout_ready(sps_dready),
    .din(sc_din), .din64(sc_din64), .we(sc_we), .we_burst(sc_we_burst),
    .rd(sc_rd), .ready(sps_ready));
  sdram_chip_model schip(
    .clk(clk), .DQ(SDQ), .A(SA), .BA(SBA),
    .nCS(SnCS), .nRAS(SnRAS), .nCAS(SnCAS), .nWE(SnWE), .CKE(SCKE),
    .DQML(SDQML), .DQMH(SDQMH), .proto_errors());

  // ---- SDRAM framebuffer readback (chip-model storage) -----------------------
  // Read a 16-bit RGB565 word straight from the SDRAM chip-model store, given an
  // SDRAM BYTE address. Mirrors sdram_psx's column-low map (row=addr[25:13],
  // bank=addr[12:11], col=addr[10:1]) and the chip's 23-bit key {row[12],row[9:0],
  // bank,col}. Lets the tb assert composited FB pixels without level-sampling the
  // write strobes (per the brief).
  function [15:0] sdword(input [26:0] ba);
    reg [12:0] row; reg [1:0] bank; reg [9:0] col; reg [22:0] k;
    begin
      row  = ba[25:13]; bank = ba[12:11]; col = ba[10:1];
      k    = {row[12], row[9:0], bank, col};
      sdword = schip.store[k];
    end
  endfunction
  // FB pixel (x,y) in SDRAM FB0/FB1: byte = base + (y*320 + x)*2.
  function [15:0] sdram_fb0_px(input integer py, input integer px);
    sdram_fb0_px = sdword(`SDRAM_FB0_BASE + ((py*320+px)*2));
  endfunction
  function [15:0] sdram_fb1_px(input integer py, input integer px);
    sdram_fb1_px = sdword(`SDRAM_FB1_BASE + ((py*320+px)*2));
  endfunction
  // direct seed into SDRAM chip store at a FBx pixel (carry-forward pre-seed / dst wipe)
  task seed_sd_px(input [26:0] fb_base, input integer py, input integer px, input [15:0] v);
    reg [26:0] ba; reg [12:0] row; reg [1:0] bank; reg [9:0] col; reg [22:0] k;
    begin
      ba = fb_base + ((py*320+px)*2);
      row = ba[25:13]; bank = ba[12:11]; col = ba[10:1];
      k   = {row[12], row[9:0], bank, col};
      schip.store[k] = v;
    end
  endtask
  task seed_fb1_px(input integer py, input integer px, input [15:0] v);
    begin seed_sd_px(`SDRAM_FB1_BASE, py, px, v); end
  endtask
  task wipe_fb0_px(input integer py, input integer px);
    begin seed_sd_px(`SDRAM_FB0_BASE, py, px, 16'h0); end
  endtask

  // ---- behavioral DDRAM with backpressure (busy 2/3) ----
  reg [63:0] mem [0:MEMQW-1];
  reg [1:0] bp=0; always @(posedge clk) bp <= (bp==2'd2)?2'd0:bp+2'd1;
  integer i;
  // BURST-capable f2h model: accept a command only when free AND no burst in
  // flight; a read of burstcnt N then streams N beats (gated by bp -> gaps),
  // incrementing the address. d_busy reflects backpressure OR a burst in flight.
  reg [7:0]  rbeats; reg [28:0] raddr; reg [2:0] rlat;
  assign d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  always @(posedge clk) begin
    d_dready <= 1'b0;
    if (reset) begin rbeats<=0; rlat<=0; end
    else begin
      if (rlat != 3'd0) rlat <= rlat - 3'd1;           // read command latency
      else if (rbeats != 8'd0) begin                    // stream burst beats
        if (bp == 2'd2) begin                           // beat gaps (backpressure)
          d_dout <= mem[raddr-WBASE]; d_dready <= 1'b1;
          raddr <= raddr + 29'd1; rbeats <= rbeats - 8'd1;
        end
      end else if (!d_busy) begin                       // accept a new command
        if (d_rd) begin rbeats <= d_burst; raddr <= d_addr; rlat <= 3'd3; end
        else if (d_we) for(i=0;i<8;i=i+1) if(d_be[i]) mem[(d_addr-WBASE)][i*8 +:8]<=d_din[i*8 +:8];
      end
    end
  end

  // ---- command list builder ----
  task wmem(input [31:0] idx, input [63:0] val); mem[idx]=val; endtask
  initial begin
    for(i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    // reader test region (BUF1 window 0x8008+) — producer never writes it
    for(i=0;i<2048;i=i+1) mem[32'h8008+i] = 64'hBEEF_0000_0000_0000 | i;
    // control block @ BLTCTRL (window 0xE000)
    wmem(32'h200000, 64'd1);          // submit_seq = 1
    wmem(32'h200001, 64'd2);          // cmd_count = 2 (FILL + END)
    wmem(32'h200002, 64'd0);          // target_buf = 0 (BUF0)
    wmem(32'h200003, 64'h001F);       // clear_color = blue
    wmem(32'h200004, 64'd1);          // flags = CLEAR
    wmem(32'h200005, 64'd0);          // done_seq = 0
    // ring @ 0xE008 : cmd0 = FILL red rect (128,96) 64x48 ; cmd1 = END
    // qw0={u32[1],u32[0]} opcode=2(FILL); qw1={h<<16|w}; qw2={dst_y<<16|dst_x}; qw3={color}
    wmem(32'h200008, 64'h0000_0000_0000_0002);                 // op=FILL
    wmem(32'h200009, {32'h0030_0040, 32'd0});                  // h=48(0x30) w=64(0x40) (u32[3]) , u32[2]=0
    wmem(32'h20000A, {32'h0060_0080, 32'd0});                  // dst_y=96(0x60) dst_x=128(0x80), u32[4]=0
    wmem(32'h20000B, {32'h0000_F800, 32'd0});                  // color=red 0xF800, u32[6]=0
    wmem(32'h20000C, 64'd1);                                   // cmd1 op=END
    wmem(32'h20000D, 64'd0); wmem(32'h20000E, 64'd0); wmem(32'h20000F, 64'd0);
  end

  // ---- concurrent reader: periodic 80-beat bursts, check every beat ----
  integer errs=0, nbursts=0, gap, k;
  task rd_burst(input [28:0] base);
    begin
      while(r_busy) @(posedge clk);
      r_addr<=base; r_burst<=8'd80; r_rd<=1'b1;     // 80-beat BURST read (like the real reader)
      @(posedge clk);
      gap=0; while(r_busy) begin @(posedge clk); gap=gap+1; if(gap>20000) begin $display("READER STARVED"); $finish; end end
      r_rd<=1'b0;
      for(k=0;k<80;k=k+1) begin @(posedge clk); while(!(d_dready && r_grant)) @(posedge clk);
        if(d_dout !== mem[(base-WBASE)+k]) errs=errs+1; end
      nbursts=nbursts+1;
    end
  endtask

  // ---- issue #19 source-select EQUIVALENCE test plumbing -------------------
  // Run the SAME COPY blit twice (C_SRCSEL=0 DDR3, then C_SRCSEL=1 SDRAM staged
  // via BLT_OP_STAGE) and assert the composited dst pixels are byte-identical.
  // Source sprite: 8x4, px(x,y)=0xC000+y*8+x, at SRC byte_off 0 (qw window 0x1000).
  // Stride=16 bytes/row -> stage_size = SPR_H * 16 = 64 bytes (qword-aligned).
  localparam integer SPR_W=8, SPR_H=4;
  localparam integer EQ_DX=40, EQ_DY=30;            // dst origin of the equivalence blit
  localparam integer SPR_STRIDE=16;                  // source stride in bytes
  localparam integer SPR_BYTES=SPR_H*SPR_STRIDE;     // 64 bytes total to stage
  reg [15:0] eq_ddr [0:SPR_W*SPR_H-1];              // captured dst pixels (DDR3 source run)
  reg [15:0] p3_a [0:SPR_W*SPR_H-1];               // PHASE3: flagged (SDRAM) blit dst
  reg [15:0] p3_b [0:SPR_W*SPR_H-1];               // PHASE3: un-flagged (DDR3) blit dst
  integer ex, ey, submit_n=1, eqi, eqerrs=0, p3errs=0;
  integer cx, cy, p4errs=0;
  reg phase1_ok=0;

  // program the equivalence COPY blit into the control block + ring with a given
  // C_SRCSEL and optional BLT_OP_STAGE prefix (for the SDRAM path), bump submit,
  // and wait for done.
  // do_stage=1: STAGE(cmd0) + BLIT(cmd1) + END(cmd2), cmd_count=3.
  // do_stage=0: BLIT(cmd0) + END(cmd1),                cmd_count=2.
  // bflags = blit command flags byte (u32[0][31:24]); F_SRC_SDRAM=0x10 selects the
  // SDRAM source for THIS blit (per-command mux, #34). soff = source byte offset.
  task run_eq_blit(input ssel, input do_stage, input [7:0] bflags, input [31:0] soff);
    integer t2; reg [31:0] op0; begin
      op0 = {bflags, 8'h00, 8'h00, 8'h03};             // u32[0]: flags|format|blend|opcode(BLIT)
      wmem(32'h200002, 64'd0);                          // target_buf = 0 (BUF0)
      wmem(32'h200004, 64'd0);                          // flags = 0 (no CLEAR)
      wmem(32'h200007, (ssel ? 64'd1 : 64'd0) | 64'h0000_1000); // C_SRCSEL + throttle=0x10 [#34] exercise S_WR_THROTTLE
      if (do_stage) begin
        wmem(32'h200001, 64'd3);                        // cmd_count = 3 (STAGE+BLIT+END)
        // cmd0 STAGE: op=4, src_off=soff, size bytes={h=0,w=SPR_BYTES}
        wmem(32'h200008, {soff, 32'h0000_0004});        // op=STAGE(4), src_off=soff
        wmem(32'h200009, {16'd0, 16'(SPR_BYTES), 32'd0}); // h=0, w=SPR_BYTES, u32[2]=0
        wmem(32'h20000A, 64'd0);
        wmem(32'h20000B, 64'd0);
        // cmd1 COPY BLIT: op=3 (+bflags), src_off=soff, w=8 h=4 stride=16, dst=(EQ_DX,EQ_DY)
        wmem(32'h20000C, {soff, op0});
        wmem(32'h20000D, {16'(SPR_H),16'(SPR_W),16'd0,16'd16});
        wmem(32'h20000E, {16'(EQ_DY),16'(EQ_DX),16'd0,16'd0});
        wmem(32'h20000F, 64'd0);
        // cmd2 END
        wmem(32'h200010, 64'd1);
        wmem(32'h200011, 64'd0); wmem(32'h200012, 64'd0); wmem(32'h200013, 64'd0);
      end else begin
        wmem(32'h200001, 64'd2);                        // cmd_count = 2 (BLIT+END)
        // cmd0 COPY BLIT: op=3 (+bflags), src_off=soff, w=8 h=4 stride=16, dst=(EQ_DX,EQ_DY)
        wmem(32'h200008, {soff, op0});
        wmem(32'h200009, {16'(SPR_H),16'(SPR_W),16'd0,16'd16});
        wmem(32'h20000A, {16'(EQ_DY),16'(EQ_DX),16'd0,16'd0});
        wmem(32'h20000B, 64'd0);
        // cmd1 END
        wmem(32'h20000C, 64'd1);
        wmem(32'h20000D, 64'd0); wmem(32'h20000E, 64'd0); wmem(32'h20000F, 64'd0);
      end
      submit_n = submit_n + 1;
      wmem(32'h200000, submit_n[63:0]);                 // bump submit -> new blit
      t2=0; while(mem[32'h200005][31:0] !== submit_n[31:0] && t2<2000000) begin @(posedge clk); t2=t2+1; end
      repeat(10) @(posedge clk);
    end
  endtask

  // dst pixels now live in SDRAM FB0 (the demux redirected the blitter's FB writes
  // there). Read them back from the SDRAM chip-model store, not DDR mem[].
  function [15:0] dstpix(input integer dx, input integer dy);
    dstpix = sdram_fb0_px(dy, dx);
  endfunction


  integer to;
  initial begin
    r_burst=0; r_addr=0; r_rd=0; r_din=0; r_be=8'hFF; r_we=0;
    repeat(8) @(posedge clk); reset<=0;
    // hammer the reader while the blitter composites in the gaps, until blitter done
    fork
      begin : reader_proc
        forever begin
          rd_burst(29'h07408008 + (nbursts%16)*80);
          repeat(300) @(posedge clk);   // idle gap > QUIET_MAX (like the real reader between scanlines)
        end
      end
      begin : wait_done
        to=0;
        while(mem[32'h200005][31:0] !== mem[32'h200000][31:0] && to<4000000) begin @(posedge clk); to=to+1; end
        disable reader_proc;
      end
    join
    repeat(20) @(posedge clk);
    $display("=== blitter done_seq=%0d submit=%0d ; reader bursts=%0d errs=%0d ===",
             mem[32'h200005][31:0], mem[32'h200000][31:0], nbursts, errs);
    // VCTRL stays on DDR (VCTRL_QW=0x07400000 is BELOW the FB range) -> mem[0].
    // FB0 pixels now live in SDRAM; read them back via the chip-model store.
    $display("VCTRL      = %h (expect 4 = frame1|buf0)", mem[0][31:0]);
    $display("BUF0[0,0]  = %h (expect blue 001F)", sdram_fb0_px(0,0));
    $display("rect px    = %h (expect red F800)", sdram_fb0_px(104,136));
    $display("non-rect   = %h (expect blue 001F, px (8,8))", sdram_fb0_px(8,8));
    phase1_ok = (errs==0 && mem[32'h200005][31:0]==mem[32'h200000][31:0]
                 && mem[0][31:0]==32'd4
                 && sdram_fb0_px(0,0)==16'h001F           // CLEAR=blue landed in SDRAM
                 && sdram_fb0_px(104,136)==16'hF800        // FILL rect center = red
                 && sdram_fb0_px(8,8)==16'h001F);          // outside rect = still blue
    if (phase1_ok) $display("PHASE1 (FILL/reader): PASS"); else $display("PHASE1 (FILL/reader): FAIL");

    // ================= PHASE 2: source-select EQUIVALENCE (issue #19) ==========
    // Seed the 8x4 source sprite into DDR3 mem[] only.  SDRAM starts zero.
    // The C_SRCSEL=1 run will issue a BLT_OP_STAGE to copy the bytes from DDR3
    // into SDRAM before the blit — if STAGE is broken, SDRAM stays zero and the
    // equivalence assertion catches it (non-zero DDR3 pixels vs zero SDRAM pixels).
    for (ey=0; ey<SPR_H; ey=ey+1)
      for (ex=0; ex<SPR_W; ex=ex+1) begin
        // DDR3: SRC heap qword + 16-bit lane (4 px / qword); stride 16B/row
        mem[32'h201000 + ((ey*SPR_STRIDE + ex*2)>>3)][((((ey*SPR_STRIDE+ex*2)>>1)&3)*16) +: 16]
          = 16'hC000 + ey*8 + ex;
      end

    // Run A: C_SRCSEL=0 (DDR3 source), no STAGE prefix. Capture the dst rect.
    run_eq_blit(1'b0, 1'b0, 8'h00, 32'd0);
    for (ey=0; ey<SPR_H; ey=ey+1)
      for (ex=0; ex<SPR_W; ex=ex+1)
        eq_ddr[ey*SPR_W+ex] = dstpix(EQ_DX+ex, EQ_DY+ey);

    // wipe the dst rect in SDRAM so Run B can't pass on stale pixels
    for (ey=0; ey<SPR_H; ey=ey+1)
      for (ex=0; ex<SPR_W; ex=ex+1)
        wipe_fb0_px(EQ_DY+ey, EQ_DX+ex);

    // Run B: C_SRCSEL=1 (SDRAM source), WITH BLT_OP_STAGE prefix to copy DDR3->SDRAM.
    // The ring is: STAGE(src_off=0, size=SPR_BYTES) then BLIT. SDRAM starts blank;
    // only the STAGE populates it — proves the staging path end-to-end. The blit
    // now carries F_SRC_SDRAM (per-command mux, #34) so it reads SDRAM.
    run_eq_blit(1'b1, 1'b1, 8'h10, 32'd0);
    for (ey=0; ey<SPR_H; ey=ey+1)
      for (ex=0; ex<SPR_W; ex=ex+1) begin
        if (dstpix(EQ_DX+ex, EQ_DY+ey) !== eq_ddr[ey*SPR_W+ex]) begin
          eqerrs=eqerrs+1;
          $display("  EQUIV MISMATCH (%0d,%0d): SDRAM=%h DDR3=%h",
                   ex, ey, dstpix(EQ_DX+ex,EQ_DY+ey), eq_ddr[ey*SPR_W+ex]);
        end
      end
    // non-vacuous: the captured DDR3 pixels must actually be the sprite (not all 0)
    if (eq_ddr[0] !== 16'hC000) begin eqerrs=eqerrs+1; $display("  EQUIV: DDR3 capture vacuous (eq_ddr[0]=%h)", eq_ddr[0]); end
    $display("=== PHASE2 (srcsel equiv): eqerrs=%0d (DDR3 px[0]=%h SDRAM px[0]=%h) ===",
             eqerrs, eq_ddr[0], dstpix(EQ_DX,EQ_DY));
    if (eqerrs==0) $display("PHASE2 (srcsel equiv): PASS"); else $display("PHASE2 (srcsel equiv): FAIL");

    // ============ PHASE 3: PER-COMMAND SOURCE MUX (issue #34) ==================
    // The bug: C_SRCSEL is a frame-level master enable, so under C_SRCSEL=1 EVERY
    // blit read SDRAM — corrupting un-staged (DDR3-heap) sources. Fix: a per-command
    // flag F_SRC_SDRAM selects DDR3 vs SDRAM PER BLIT. Make DDR3 and SDRAM hold
    // DIFFERENT data at the SAME src_off=0: SDRAM already holds sprite A (0xC000+..,
    // staged in PHASE2); now overwrite DDR3 with sprite B (0xD000+..). Then under
    // C_SRCSEL=1: a FLAGGED blit must read SDRAM (A); an UN-FLAGGED blit must read
    // DDR3 (B). They must DIFFER. (Pre-fix the un-flagged blit wrongly reads A.)
    for (ey=0; ey<SPR_H; ey=ey+1)
      for (ex=0; ex<SPR_W; ex=ex+1)
        mem[32'h201000 + ((ey*SPR_STRIDE + ex*2)>>3)][((((ey*SPR_STRIDE+ex*2)>>1)&3)*16) +: 16]
          = 16'hD000 + ey*8 + ex;                       // DDR3 now = sprite B

    // (3a) FLAGGED blit, C_SRCSEL=1, NO stage -> reads SDRAM[0] = sprite A.
    for (ey=0; ey<SPR_H; ey=ey+1) for (ex=0; ex<SPR_W; ex=ex+1)
      wipe_fb0_px(EQ_DY+ey, EQ_DX+ex);
    run_eq_blit(1'b1, 1'b0, 8'h10, 32'd0);
    for (ey=0; ey<SPR_H; ey=ey+1) for (ex=0; ex<SPR_W; ex=ex+1)
      p3_a[ey*SPR_W+ex] = dstpix(EQ_DX+ex, EQ_DY+ey);

    // (3b) UN-FLAGGED blit, C_SRCSEL=1, NO stage -> must read DDR3[0] = sprite B.
    for (ey=0; ey<SPR_H; ey=ey+1) for (ex=0; ex<SPR_W; ex=ex+1)
      wipe_fb0_px(EQ_DY+ey, EQ_DX+ex);
    run_eq_blit(1'b1, 1'b0, 8'h00, 32'd0);
    for (ey=0; ey<SPR_H; ey=ey+1) for (ex=0; ex<SPR_W; ex=ex+1)
      p3_b[ey*SPR_W+ex] = dstpix(EQ_DX+ex, EQ_DY+ey);

    for (ey=0; ey<SPR_H; ey=ey+1)
      for (ex=0; ex<SPR_W; ex=ex+1) begin
        eqi = ey*SPR_W+ex;
        if (p3_a[eqi] !== (16'hC000 + ey*8 + ex)) begin
          // #34 dqff: localize the corrupted qword (cap output)
          if (p3errs < 16)
            $display("  P3 mismatch @%0d,%0d: got=%h exp=%h (src=SDRAM)", ey, ex, p3_a[eqi], 16'hC000+ey*8+ex);
          p3errs=p3errs+1;
        end
        if (p3_b[eqi] !== (16'hD000 + ey*8 + ex)) begin
          // #34 dqff: localize the corrupted qword (cap output)
          if (p3errs < 16)
            $display("  P3 mismatch @%0d,%0d: got=%h exp=%h (src=DDR3)", ey, ex, p3_b[eqi], 16'hD000+ey*8+ex);
          p3errs=p3errs+1;
        end
      end
    $display("=== PHASE3 (per-cmd mux): p3errs=%0d (flagged->SDRAM px0=%h | unflagged->DDR3 px0=%h) ===",
             p3errs, p3_a[0], p3_b[0]);
    if (p3errs==0) $display("PHASE3 (per-cmd mux): PASS"); else $display("PHASE3 (per-cmd mux): FAIL");

    // ============ PHASE 4: CARRY-FORWARD full-screen COPY FB1 -> FB0 ===========
    // The Task-6 datapath probe: a full-screen OP_BLIT COPY whose SOURCE is FB1
    // in SDRAM (byte base 0x440000) and whose DEST is FB0 in SDRAM. This forces
    //   (a) the blitter to SOURCE-READ FB1 directly out of SDRAM via src_sdram_*
    //       (src_off = 0x440000, F_SRC_SDRAM set, C_SRCSEL=1) — proving the source
    //       addressing can REACH the framebuffer region (load-bearing for Task 6);
    //   (b) the dest writes to flow FB0-bound through vram_demux -> P_DST.
    // Pre-seed FB1 in the SDRAM chip store with a known per-pixel pattern; after
    // the blit, assert FB0 == FB1 pixel-for-pixel.
    //
    // Use a sparse but spatially representative sample grid (every 16th px in x,
    // every 12th in y, plus the four corners) so the full 320x240 blit runs in a
    // tractable number of cycles while still covering all rows/cols/qword lanes.
    p4errs = 0;
    // pre-seed FB1 with pattern px(x,y) = 0x8000 | ((y<<5) ^ x) and zero FB0.
    for (cy=0; cy<240; cy=cy+1)
      for (cx=0; cx<320; cx=cx+1) begin
        seed_sd_px(`SDRAM_FB1_BASE, cy, cx, 16'h8000 | (((cy<<5) ^ cx) & 16'h7FFF));
        seed_sd_px(`SDRAM_FB0_BASE, cy, cx, 16'h0);
      end

    // Program a full-screen COPY: src_off=0x440000 (SDRAM FB1), F_SRC_SDRAM, C_SRCSEL=1,
    // w=320 h=240 stride=640, dst=(0,0), target=BUF0.
    wmem(32'h200002, 64'd0);                           // target_buf = 0 (BUF0)
    wmem(32'h200004, 64'd0);                           // flags = 0 (no CLEAR)
    wmem(32'h200007, 64'd1);                           // C_SRCSEL=1, throttle=0
    wmem(32'h200001, 64'd2);                           // cmd_count = 2 (BLIT+END)
    // cmd0 COPY BLIT: op=3, flags=F_SRC_SDRAM(0x10), src_off=0x440000
    wmem(32'h200008, {32'h0044_0000, {8'h10,8'h00,8'h00,8'h03}});
    wmem(32'h200009, {16'd240, 16'd320, 16'd0, 16'd640});  // h=240 w=320 stride=640
    wmem(32'h20000A, {16'd0, 16'd0, 16'd0, 16'd0});        // dst_y=0 dst_x=0
    wmem(32'h20000B, 64'd0);
    wmem(32'h20000C, 64'd1);                              // cmd1 END
    wmem(32'h20000D, 64'd0); wmem(32'h20000E, 64'd0); wmem(32'h20000F, 64'd0);
    submit_n = submit_n + 1;
    wmem(32'h200000, submit_n[63:0]);
    to=0; while(mem[32'h200005][31:0] !== submit_n[31:0] && to<8000000) begin @(posedge clk); to=to+1; end
    repeat(20) @(posedge clk);
    if (mem[32'h200005][31:0] !== submit_n[31:0]) begin
      p4errs=p4errs+1; $display("  P4: full-screen COPY did NOT complete (done=%0d submit=%0d, %0d cyc)",
                                mem[32'h200005][31:0], submit_n[31:0], to);
    end

    // assert FB0 == FB1 over a representative sample grid (corners + every step).
    for (cy=0; cy<240; cy=cy+12) begin
      for (cx=0; cx<320; cx=cx+16) begin
        if (sdram_fb0_px(cy,cx) !== sdram_fb1_px(cy,cx)) begin
          if (p4errs < 20) $display("  P4 carry-forward mismatch @%0d,%0d: FB0=%h FB1=%h",
                                    cx, cy, sdram_fb0_px(cy,cx), sdram_fb1_px(cy,cx));
          p4errs=p4errs+1;
        end
      end
    end
    // explicit corners (last col/row are 319/239, not multiples of the step)
    if (sdram_fb0_px(0,319)   !== sdram_fb1_px(0,319))   begin p4errs=p4errs+1; $display("  P4 corner (319,0) mismatch"); end
    if (sdram_fb0_px(239,0)   !== sdram_fb1_px(239,0))   begin p4errs=p4errs+1; $display("  P4 corner (0,239) mismatch"); end
    if (sdram_fb0_px(239,319) !== sdram_fb1_px(239,319)) begin p4errs=p4errs+1; $display("  P4 corner (319,239) mismatch"); end
    // non-vacuous: FB0 must actually hold the seeded FB1 pattern (not stay zero).
    if (sdram_fb0_px(0,0) === 16'h0) begin p4errs=p4errs+1; $display("  P4 vacuous: FB0[0,0] still 0"); end
    $display("=== PHASE4 (carry-forward FB1->FB0): p4errs=%0d (FB0[0,0]=%h FB1[0,0]=%h | FB0[120,160]=%h) ===",
             p4errs, sdram_fb0_px(0,0), sdram_fb1_px(0,0), sdram_fb0_px(120,160));
    if (p4errs==0) $display("PHASE4 (carry-forward): PASS"); else $display("PHASE4 (carry-forward): FAIL");

    if (phase1_ok && eqerrs==0 && p3errs==0 && p4errs==0) $display("RESULT: PASS");
    else $display("RESULT: FAIL");
    $finish;
  end
  initial begin #400000000 $display("RESULT: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire
