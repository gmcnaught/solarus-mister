`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
// tb_blitter_src_hold.sv — #34 regression guard for the S_SRC_SDRAM_WAIT issue-side
// miss. The blitter must HOLD src_sdram_rd until the data beat (src_sdram_dout_ready);
// it must NOT infer acceptance from !src_sdram_busy. A source adversary models the HW
// hazard: bs_busy=0 ALWAYS (a stale "not busy"), and the beat is delivered ONLY if the
// request is HELD for >=3 cycles (i.e. the arbiter only grants/returns a sustained
// request). The blitter runs one tiny F_SRC_SDRAM copy via mem_* (command ring + dst)
// with the SOURCE on the adversary.
//   - OLD blitter (drops src_sdram_rd on !busy): request lasts 1 cycle -> never held
//     -> no beat -> hang in S_SRC_SDRAM_WAIT -> watchdog FAIL.
//   - FIXED blitter (holds until dout_ready): beat delivered -> blit completes -> PASS.
module tb_blitter_src_hold;
  localparam AW = 32;
  localparam [28:0] WBASE = 29'h07400000;     // window base; mem index = addr - WBASE
  localparam        MEMQW = 32'h202000;        // covers BLTCTRL window (idx 0x200000)

  reg clk=0, reset=1; always #5 clk=~clk;

  // ---- blitter mem_* (command ring + dst writes) ----
  wire [AW-1:0] mem_addr; wire mem_rd, mem_wr; wire [63:0] mem_din; wire [7:0] mem_be;
  reg  [63:0]   mem_dout; reg mem_dout_ready; wire mem_busy = 1'b0;
  wire          bt_idle;
  // ---- blitter src_sdram_* (SOURCE on the adversary) ----
  wire [26:0] bs_addr; wire bs_rd; reg [63:0] bs_dout64; reg bs_dready; wire bs_busy;
  wire        bs_we; wire [15:0] bs_din; wire [26:0] bs_waddr;
  wire        bs_we_burst; wire [63:0] bs_din64;

  blitter_top #(.AW(AW)) blt(
    .clk(clk), .rst(reset),
    .mem_addr(mem_addr), .mem_rd(mem_rd), .mem_wr(mem_wr), .mem_din(mem_din), .mem_be(mem_be),
    .mem_dout(mem_dout), .mem_dout_ready(mem_dout_ready), .mem_busy(mem_busy),
    .src_sdram_addr(bs_addr), .src_sdram_rd(bs_rd), .src_sdram_dout64(bs_dout64),
    .src_sdram_dout_ready(bs_dready), .src_sdram_busy(bs_busy),
    .src_sdram_we(bs_we), .src_sdram_din(bs_din), .src_sdram_waddr(bs_waddr),
    .src_sdram_we_burst(bs_we_burst), .src_sdram_din64(bs_din64),
    .idle(bt_idle));

  // ---- behavioral DDR mem on mem_* : 1-cycle read latency, byte-enabled writes ----
  reg [63:0] mem [0:MEMQW-1];
  reg rd_q; reg [AW-1:0] addr_q; integer ii;
  always @(posedge clk) begin
    mem_dout_ready <= 1'b0;
    if (reset) rd_q <= 1'b0;
    else begin
      rd_q <= mem_rd; addr_q <= mem_addr;
      if (rd_q) begin mem_dout <= mem[addr_q - WBASE]; mem_dout_ready <= 1'b1; end
      if (mem_wr)
        for (ii=0; ii<8; ii=ii+1)
          if (mem_be[ii]) mem[(mem_addr - WBASE)][ii*8 +: 8] <= mem_din[ii*8 +: 8];
    end
  end

  // ---- SOURCE adversary : busy=0 always; beat ONLY when bs_rd held >=3 cycles ----
  assign bs_busy = 1'b0;     // the stale "not busy" that made the OLD code drop early
  reg [3:0] held;
  always @(posedge clk) begin
    bs_dready <= 1'b0;
    if (reset) held <= 4'd0;
    else if (bs_rd) begin
      held <= (held==4'hF) ? 4'hF : held + 4'd1;
      if (held == 4'd2) begin bs_dready <= 1'b1; bs_dout64 <= 64'hABCD_0123_4567_89AB; end
    end else held <= 4'd0;
  end

  // ---- program control block + one F_SRC_SDRAM copy + END ----
  task wmem(input [31:0] idx, input [63:0] val); mem[idx]=val; endtask
  integer i, to;
  initial begin
    for (i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    // control block @ BLTCTRL (window idx 0x200000)
    wmem(32'h200000 + `C_SUBMIT,   64'd1);   // submit_seq = 1
    wmem(32'h200000 + `C_CMDCOUNT, 64'd2);   // BLIT + END
    wmem(32'h200000 + `C_TARGET,   64'd0);   // BUF0
    wmem(32'h200000 + `C_CLEAR,    64'd0);
    wmem(32'h200000 + `C_FLAGS,    64'd0);   // no CLEAR
    wmem(32'h200000 + `C_DONE,     64'd0);
    wmem(32'h200000 + `C_SRCSEL,   64'd1);   // srcsel=1 (SDRAM source path enabled)
    // ring @ RING (window idx 0x200008): cmd0 COPY BLIT (op=3 + F_SRC_SDRAM), w=2 h=1
    // qw0 = {src_off=0, op0}; op0 = {flags=F_SRC_SDRAM, fmt=0, blend=0, opcode=OP_BLIT}
    wmem(32'h200008, {32'd0, 8'h10, 8'h00, 8'h00, 8'h03});   // 0x10=F_SRC_SDRAM, 0x03=OP_BLIT
    wmem(32'h200009, {16'd1, 16'd2, 16'd0, 16'd4});          // h=1, w=2, -, stride=4
    wmem(32'h20000A, {16'd0, 16'd0, 16'd0, 16'd0});          // dst_y=0, dst_x=0
    wmem(32'h20000B, 64'd0);
    // cmd1 END
    wmem(32'h20000C, 64'd1);
    wmem(32'h20000D, 64'd0); wmem(32'h20000E, 64'd0); wmem(32'h20000F, 64'd0);

    repeat(8) @(posedge clk); reset <= 0;
    // wait for the blit to complete (C_DONE == submit) or hang
    to = 0;
    while (mem[32'h200000 + `C_DONE][31:0] !== 32'd1 && to < 200000) begin @(posedge clk); to=to+1; end

    if (mem[32'h200000 + `C_DONE][31:0] === 32'd1)
      $display("RESULT: PASS");
    else begin
      $display("FAIL: blit never completed — blitter hung in S_SRC_SDRAM_WAIT (dropped src_sdram_rd before the held beat)");
      $display("RESULT: FAIL");
    end
    $finish;
  end

  initial begin #2000000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
