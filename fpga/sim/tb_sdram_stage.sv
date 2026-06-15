// tb_sdram_stage.sv — issue #19 staging round-trip sim.
//
// Exercises BLT_OP_STAGE: the blitter must copy a source region from DDR3
// (SRC_QW + off) into SDRAM at the heap-relative byte offset `off` (the same
// address the C_SRCSEL=1 source-read path uses). After the blit signals C_DONE,
// the SDRAM (chip model store) must hold the SAME bytes as the DDR3 source.
//
// Topology mirrors tb_blitter_system: blitter_top + ddr_blitter_arb + a
// backpressuring behavioral DDR3 + sdram_src_arb + sdram_psx + sdram_chip_model.
// The blitter's NEW staging WRITE outputs route through sdram_src_arb -> sdram_psx.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"

module tb_sdram_stage;
  localparam [28:0] WBASE = 29'h07400000;    // window base; mem index = addr-WBASE
  localparam        MEMQW = 32'h202000;       // 131072 qwords window

  reg clk=0, reset=1; always #5 clk=~clk;

  // ---- reader (m0) fake master (idle here; the arbiter needs it wired) ----
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

  // ---- SDRAM SOURCE/STAGE path (issue #19) ----
  wire [26:0] bs_addr; wire bs_rd; wire [63:0] bs_dout64; wire bs_dready; wire bs_busy;
  // NEW staging write outputs from blitter_top
  wire        bs_we; wire [15:0] bs_din; wire [26:0] bs_waddr;

  blitter_top blt(
    .clk(clk), .rst(reset),
    .mem_addr(bt_addr), .mem_rd(b_rd), .mem_wr(b_we), .mem_din(b_din), .mem_be(b_be),
    .mem_dout(d_dout), .mem_dout_ready(d_dready & b_grant), .mem_busy(b_busy),
    .src_sdram_addr(bs_addr), .src_sdram_rd(bs_rd), .src_sdram_dout64(bs_dout64),
    .src_sdram_dout_ready(bs_dready), .src_sdram_busy(bs_busy),
    .src_sdram_we(bs_we), .src_sdram_din(bs_din), .src_sdram_waddr(bs_waddr),
    .idle(bt_idle));
  assign b_addr = bt_addr[28:0];

  // arbiter -> sdram_psx (single-beat line: BURST_BEATS=1).
  wire        sps_ready, sps_dready; wire [63:0] sps_dout64;
  wire [26:0] sc_addr; wire sc_rd; wire sc_we; wire [15:0] sc_din;
  wire sc_busy = ~sps_ready;
  wire [15:0] SDQ; wire [12:0] SA; wire SDQML, SDQMH; wire [1:0] SBA;
  wire        SnCS, SnWE, SnRAS, SnCAS, SCLK, SCKE;

  sdram_src_arb src_arb(
    .clk(clk), .reset(reset),
    .p0_addr(bs_addr), .p0_rd(bs_rd), .p0_grant(), .p0_busy(bs_busy),
    .p0_we(bs_we), .p0_din(bs_din), .p0_waddr(bs_waddr),
    .c_addr(sc_addr), .c_rd(sc_rd), .c_we(sc_we), .c_din(sc_din),
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
    .din(sc_din), .we(sc_we), .rd(sc_rd), .ready(sps_ready));
  sdram_chip_model schip(
    .clk(clk), .DQ(SDQ), .A(SA), .BA(SBA),
    .nCS(SnCS), .nRAS(SnRAS), .nCAS(SnCAS), .nWE(SnWE), .CKE(SCKE),
    .DQML(SDQML), .DQMH(SDQMH), .proto_errors());

  // ---- behavioral DDRAM with backpressure (busy 2/3), burst-capable ----
  reg [63:0] mem [0:MEMQW-1];
  reg [1:0] bp=0; always @(posedge clk) bp <= (bp==2'd2)?2'd0:bp+2'd1;
  integer i;
  reg [7:0]  rbeats; reg [28:0] raddr; reg [2:0] rlat;
  assign d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  always @(posedge clk) begin
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

  task wmem(input [31:0] idx, input [63:0] val); mem[idx]=val; endtask

  // ---- staging round-trip parameters ----
  // off = 0x40 heap byte offset; copy N qwords (each = 4 source words / 8 bytes).
  localparam integer STAGE_OFF  = 32'h40;
  localparam integer STAGE_QWS  = 6;                         // qwords to stage
  localparam integer STAGE_SIZE = STAGE_QWS * 8;             // bytes
  // DDR3 source qword index for off: SRC_QW + (off>>3). SRC_QW window idx = 0x201000.
  localparam integer SRC_QW_IDX = 32'h201000;                // SRC heap base, window-relative

  integer q, errors=0, t;
  reg [63:0] expect_qw [0:STAGE_QWS-1];

  initial begin
    for(i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    r_burst=0; r_addr=0; r_rd=0; r_din=0; r_be=8'hFF; r_we=0;

    // Seed a distinct source region in DDR3 at SRC_QW + off.
    for (q=0; q<STAGE_QWS; q=q+1) begin
      expect_qw[q] = {16'hD000 + 16'(q*4+3), 16'hD000 + 16'(q*4+2),
                      16'hD000 + 16'(q*4+1), 16'hD000 + 16'(q*4+0)};
      mem[SRC_QW_IDX + (STAGE_OFF>>3) + q] = expect_qw[q];
    end

    // control block @ BLTCTRL (window 0x200000)
    wmem(32'h200000, 64'd1);          // submit_seq = 1
    wmem(32'h200001, 64'd2);          // cmd_count = 2 (STAGE + END)
    wmem(32'h200002, 64'd0);          // target_buf = 0
    wmem(32'h200003, 64'd0);          // clear_color
    wmem(32'h200004, 64'd0);          // flags = 0 (no CLEAR)
    wmem(32'h200005, 64'd0);          // done_seq = 0
    wmem(32'h200007, 64'd0);          // C_SRCSEL = 0
    // ring @ 0x200008 : cmd0 = STAGE {off, size}; cmd1 = END
    // qw0 = {u32[1]=src_off, u32[0]=opcode}; opcode=4 in byte0.
    // qw1 = {u32[3]=w|h<<16, u32[2]=0}; size split w=size[15:0], h=size[31:16].
    wmem(32'h200008, {32'(STAGE_OFF), 32'h0000_0004});                 // op=STAGE, src_off=off
    wmem(32'h200009, {{16'(STAGE_SIZE>>16), 16'(STAGE_SIZE & 16'hFFFF)}, 32'd0}); // u32[3]=w|h<<16
    wmem(32'h20000A, 64'd0);
    wmem(32'h20000B, 64'd0);
    wmem(32'h20000C, 64'd1);                                           // cmd1 END
    wmem(32'h20000D, 64'd0); wmem(32'h20000E, 64'd0); wmem(32'h20000F, 64'd0);

    repeat(8) @(posedge clk); reset<=0;

    // wait for blitter done (done_seq == submit_seq)
    t=0;
    while(mem[32'h200005][31:0] !== mem[32'h200000][31:0] && t<4000000) begin @(posedge clk); t=t+1; end
    repeat(20) @(posedge clk);

    $display("=== STAGE done_seq=%0d submit=%0d t=%0d ===",
             mem[32'h200005][31:0], mem[32'h200000][31:0], t);

    if (mem[32'h200005][31:0] !== mem[32'h200000][31:0]) begin
      errors=errors+1; $display("  STAGE never completed (hang/timeout)");
    end

    // Read SDRAM back via the chip model store. For small heap-relative byte
    // offsets the address stays in row0/bank0, so the chip key reduces to col =
    // byte_addr[9:1] = word index. Each staged qword = 4 consecutive 16-bit words
    // at byte off + q*8, i.e. words (off>>1)+q*4 .. +3.
    for (q=0; q<STAGE_QWS; q=q+1) begin : verify
      reg [63:0] got;
      integer wbase;
      wbase = (STAGE_OFF>>1) + q*4;
      got = {schip.store[wbase+3], schip.store[wbase+2],
             schip.store[wbase+1], schip.store[wbase+0]};
      if (got !== expect_qw[q]) begin
        errors=errors+1;
        $display("  SDRAM mismatch qw%0d: got=%h expect=%h", q, got, expect_qw[q]);
      end
    end
    // non-vacuous: the SDRAM must not be all-zero (proves the copy happened)
    if (schip.store[(STAGE_OFF>>1)] === 16'd0) begin
      errors=errors+1; $display("  SDRAM staging vacuous (word0=0)");
    end

    $display("errors=%0d", errors);
    if (errors==0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end
  initial begin #200000000 $display("RESULT: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire
