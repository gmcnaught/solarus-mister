// tb_blitter_system.sv — full-system sim: arbiter + blitter_top + backpressuring
// DDR + a fake video reader. Preloads a real command list (CLEAR=blue + FILL red
// rect + END) into the DDR command ring, runs the blitter THROUGH the arbiter,
// and checks (a) the blitter composited the framebuffer correctly, (b) it wrote
// the video control word, and (c) the reader's concurrent burst reads are
// uncorrupted (no arbiter misrouting), with no hang. No Altera primitives.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"

module tb_blitter_system;
  localparam [28:0] WBASE = 29'h07400000;    // window base; mem index = addr-WBASE
  localparam        MEMQW = 32'h202000;       // 131072 qwords window

  reg clk=0, reset=1; always #5 clk=~clk;

  // ---- reader (m0) fake master ----
  reg [7:0] r_burst; reg[28:0] r_addr; reg r_rd; reg[63:0] r_din; reg[7:0] r_be; reg r_we;
  wire r_busy, r_grant;
  // ---- blitter (m1) <-> arbiter ----
  wire [28:0] b_addr; wire b_rd; wire[63:0] b_din; wire[7:0] b_be; wire b_we;
  wire b_busy, b_grant; wire [31:0] bt_addr; wire bt_idle;
  // ---- DDRAM ----
  wire [7:0] d_burst; wire[28:0] d_addr; wire d_rd; wire[63:0] d_din; wire[7:0] d_be; wire d_we;
  wire d_busy; reg d_dready; reg[63:0] d_dout;

  ddr_blitter_arb #(.ENABLE(1'b1)) arb(
    .clk(clk), .reset(reset),
    .rdr_burstcnt(r_burst), .rdr_addr(r_addr), .rdr_rd(r_rd), .rdr_din(r_din),
    .rdr_be(r_be), .rdr_we(r_we), .rdr_busy(r_busy), .rdr_grant(r_grant),
    .blt_addr(b_addr), .blt_rd(b_rd), .blt_din(b_din), .blt_be(b_be), .blt_we(b_we),
    .blt_busy(b_busy), .blt_grant(b_grant),
    .ddram_busy(d_busy), .ddram_dout_ready(d_dready),
    .ddram_burstcnt(d_burst), .ddram_addr(d_addr), .ddram_rd(d_rd),
    .ddram_din(d_din), .ddram_be(d_be), .ddram_we(d_we));

  // ---- SDRAM SOURCE/STAGE path (issue #19): blitter ports -> arb -> sdram_psx --
  // When C_SRCSEL=1 the blitter routes SOURCE reads here instead of the DDR3 mem_*.
  // BLT_OP_STAGE writes also route here (src_sdram_we/din/waddr from blitter_top).
  wire [26:0] bs_addr; wire bs_rd; wire [63:0] bs_dout64; wire bs_dready; wire bs_busy;
  // staging write outputs from blitter_top (BLT_OP_STAGE DDR3->SDRAM copy)
  wire        bs_we; wire [15:0] bs_din; wire [26:0] bs_waddr;
  wire        bs_we_burst; wire [63:0] bs_din64;

  blitter_top blt(
    .clk(clk), .rst(reset),
    .mem_addr(bt_addr), .mem_rd(b_rd), .mem_wr(b_we), .mem_din(b_din), .mem_be(b_be),
    .mem_dout(d_dout), .mem_dout_ready(d_dready & b_grant), .mem_busy(b_busy),
    .src_sdram_addr(bs_addr), .src_sdram_rd(bs_rd), .src_sdram_dout64(bs_dout64),
    .src_sdram_dout_ready(bs_dready), .src_sdram_busy(bs_busy),
    .src_sdram_we(bs_we), .src_sdram_din(bs_din), .src_sdram_waddr(bs_waddr),
    .src_sdram_we_burst(bs_we_burst), .src_sdram_din64(bs_din64),
    .idle(bt_idle));
  assign b_addr = bt_addr[28:0];

  // arbiter -> sdram_psx (single-beat line: BURST_BEATS=1 -> one 64-bit qword/req).
  // c_busy mapping: the controller has no "busy" output, so busy = ~ready (the
  // controller accepts a new rd ONLY at a line-complete/idle `ready` point). c_ready
  // = sdram_psx.ready (line complete). p0_busy (= c_busy) is the blitter's hold gate.
  wire        sps_ready, sps_dready; wire [63:0] sps_dout64;
  wire [26:0] sc_addr; wire sc_rd; wire sc_we; wire [15:0] sc_din;
  wire        sc_we_burst; wire [63:0] sc_din64;
  wire sc_busy = ~sps_ready;
  wire [15:0] SDQ; wire [12:0] SA; wire SDQML, SDQMH; wire [1:0] SBA;
  wire        SnCS, SnWE, SnRAS, SnCAS, SCLK, SCKE;

  sdram_src_arb src_arb(
    .clk(clk), .reset(reset),
    .p0_addr(bs_addr), .p0_rd(bs_rd), .p0_grant(), .p0_busy(bs_busy),
    .p0_we(bs_we), .p0_din(bs_din), .p0_waddr(bs_waddr),
    .p0_we_burst(bs_we_burst), .p0_din64(bs_din64),
    .c_addr(sc_addr), .c_rd(sc_rd), .c_we(sc_we), .c_din(sc_din),
    .c_we_burst(sc_we_burst), .c_din64(sc_din64),
    .c_ready(sps_ready), .c_busy(sc_busy));
  assign bs_dout64 = sps_dout64;
  assign bs_dready = sps_dready;

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
      wmem(32'h200007, ssel ? 64'd1 : 64'd0);           // C_SRCSEL (offset 7)
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

  function [15:0] dstpix(input integer dx, input integer dy);
    dstpix = mem[8 + ((dy*320+dx)>>2)][((dy*320+dx)%4)*16 +: 16];
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
    $display("VCTRL      = %h (expect 4 = frame1|buf0)", mem[0][31:0]);
    $display("BUF0[0]    = %h (expect blue 001F x4)", mem[8]);
    // rect center px (128+8,96+8)=(136,104): idx=104*320+136=33416 -> qw=8354, +window8
    $display("rect px    = %h (expect red F800 x4)", mem[8 + (104*320+136)/4]);
    $display("non-rect   = %h (expect blue, px (8,8): idx=2568 qw=642)", mem[8 + (8*320+8)/4]);
    phase1_ok = (errs==0 && mem[32'h200005][31:0]==mem[32'h200000][31:0]
                 && mem[0][31:0]==32'd4 && mem[8]==64'h001F001F001F001F);
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

    // wipe the dst rect so Run B can't pass on stale pixels
    for (ey=0; ey<SPR_H; ey=ey+1)
      for (ex=0; ex<SPR_W; ex=ex+1)
        mem[8 + (((EQ_DY+ey)*320+(EQ_DX+ex))>>2)][(((EQ_DY+ey)*320+(EQ_DX+ex))%4)*16 +: 16] = 16'h0;

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
      mem[8+(((EQ_DY+ey)*320+(EQ_DX+ex))>>2)][(((EQ_DY+ey)*320+(EQ_DX+ex))%4)*16 +: 16]=16'h0;
    run_eq_blit(1'b1, 1'b0, 8'h10, 32'd0);
    for (ey=0; ey<SPR_H; ey=ey+1) for (ex=0; ex<SPR_W; ex=ex+1)
      p3_a[ey*SPR_W+ex] = dstpix(EQ_DX+ex, EQ_DY+ey);

    // (3b) UN-FLAGGED blit, C_SRCSEL=1, NO stage -> must read DDR3[0] = sprite B.
    for (ey=0; ey<SPR_H; ey=ey+1) for (ex=0; ex<SPR_W; ex=ex+1)
      mem[8+(((EQ_DY+ey)*320+(EQ_DX+ex))>>2)][(((EQ_DY+ey)*320+(EQ_DX+ex))%4)*16 +: 16]=16'h0;
    run_eq_blit(1'b1, 1'b0, 8'h00, 32'd0);
    for (ey=0; ey<SPR_H; ey=ey+1) for (ex=0; ex<SPR_W; ex=ex+1)
      p3_b[ey*SPR_W+ex] = dstpix(EQ_DX+ex, EQ_DY+ey);

    for (ey=0; ey<SPR_H; ey=ey+1)
      for (ex=0; ex<SPR_W; ex=ex+1) begin
        eqi = ey*SPR_W+ex;
        if (p3_a[eqi] !== (16'hC000 + ey*8 + ex)) begin
          p3errs=p3errs+1;
          $display("  P3 FLAGGED(SDRAM) (%0d,%0d): got=%h exp A=%h", ex, ey, p3_a[eqi], 16'hC000+ey*8+ex);
        end
        if (p3_b[eqi] !== (16'hD000 + ey*8 + ex)) begin
          p3errs=p3errs+1;
          $display("  P3 UNFLAGGED(DDR3) (%0d,%0d): got=%h exp B=%h", ex, ey, p3_b[eqi], 16'hD000+ey*8+ex);
        end
      end
    $display("=== PHASE3 (per-cmd mux): p3errs=%0d (flagged->SDRAM px0=%h | unflagged->DDR3 px0=%h) ===",
             p3errs, p3_a[0], p3_b[0]);
    if (p3errs==0) $display("PHASE3 (per-cmd mux): PASS"); else $display("PHASE3 (per-cmd mux): FAIL");

    if (phase1_ok && eqerrs==0 && p3errs==0) $display("RESULT: PASS");
    else $display("RESULT: FAIL");
    $finish;
  end
  initial begin #200000000 $display("RESULT: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire
