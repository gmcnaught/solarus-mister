// tb_blitter_palpha_pipe.sv (C_PIPE=1 equivalence: comp_pipeline burst path BIT-EXACT to the
// legacy FSM) — validate BLEND_PALPHA (per-pixel alpha, v2). The source
// surface is ARGB4444 ({A4,R4,G4,B4}, A in [15:12]); each src pixel composites
// source-over onto the RGB565 dest using its OWN alpha. CLEAR sets a known
// background, then a BLEND_PALPHA BLIT of a 2x2 sprite whose four pixels exercise:
//   - A4==0   -> fully transparent: dest must keep background (skip-write)
//   - A4==15  -> fully opaque:      dest = expanded source color
//   - A4==8   -> ~half:             dest = blend4444 reference
//   - A4==4   -> light:             dest = blend4444 reference
// The expected result is computed by ref_blend4444 below, which REPLICATES the
// divide-free reduction in blend4444() in blitter_top.sv (and blt_blend4444 in
// blitter_ref.h) — all three MUST agree bit-for-bit.
//
// Same garbage-on-mem_dout backpressured DDR model as tb_blitter_blend, so the
// rd_data capture is exercised on the dst read-modify-write of the palpha path.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
module tb_blitter_palpha_pipe;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h10000;  // [#52] tracks SRC_QW heap base
  localparam [15:0] BG = 16'h8410;   // a mid grey RGB565 background

  reg clk=0, rst=1; always #5 clk=~clk;
  wire [31:0] bt_addr; wire b_rd, b_we; wire [63:0] b_din; wire [7:0] b_be; wire bt_idle;
  reg  d_dready; reg [63:0] d_dout;
  reg [63:0] mem [0:MEMQW-1];
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat; reg [1:0] bp=0;
  always @(posedge clk) bp <= bp+2'd1;
  wire d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  integer i;

  // ── P_SRC cache-ok source model (single source pipeline) ────────────────────
  // [collapse-single-source] The per-blit source read is hardwired to SDRAM
  // (src_in_sdram=1), so comp_pipeline fetches source rows through p0_* — NOT the
  // DDR mem_* path. Serve them from the SAME SRC window (mem[0x201000 + heap_qw])
  // so the existing source-data population below is unchanged. p0_addr is the
  // heap byte offset; heap_qw = p0_addr>>3; mem index = (SRC_QW-WBASE) + heap_qw.
  localparam P_SRC_LAT = 3;
  localparam [28:0] SRC_WIN = `SRC_QW - WBASE;   // 0x201000
  wire [26:0] s_src_addr; wire s_src_rd;
  reg  [63:0] s_src_dout; reg s_src_ok=1'b0;
  reg         s_rd_d;
  reg [26:0]  s_lat_addr [0:P_SRC_LAT-1];
  reg         s_lat_v    [0:P_SRC_LAT-1];
  integer     sli;
  always @(posedge clk) s_rd_d <= s_src_rd;
  always @(posedge clk) begin
    s_src_ok <= 1'b0;
    s_lat_v   [0] <= s_src_rd & ~s_rd_d;
    s_lat_addr[0] <= s_src_addr;
    for (sli = 1; sli < P_SRC_LAT; sli = sli + 1) begin
      s_lat_v   [sli] <= s_lat_v   [sli-1];
      s_lat_addr[sli] <= s_lat_addr[sli-1];
    end
    if (s_lat_v[P_SRC_LAT-1]) begin
      s_src_dout <= mem[SRC_WIN + (s_lat_addr[P_SRC_LAT-1] >> 3)];
      s_src_ok   <= 1'b1;
    end
  end

  wire [7:0] bt_burst;
  // on-chip dest framebuffer [FB-in-BRAM] — comp_pipeline composites here now.
  wire fb_wr_en; wire [14:0] fb_wr_qw; wire [1:0] fb_wr_lane; wire [15:0] fb_wr_pix;
  wire fb_rd_en; wire [14:0] fb_rd_qw; wire [63:0] fb_rd_qword;
  comp_fbram fbram(.clk(clk),
    .wr_en(fb_wr_en), .wr_qw(fb_wr_qw), .wr_lane(fb_wr_lane), .wr_pix(fb_wr_pix),
    .rd_en(fb_rd_en), .rd_qw(fb_rd_qw), .rd_qword(fb_rd_qword));
  blitter_top blt(.clk(clk), .rst(rst),
    .mem_addr(bt_addr), .mem_rd(b_rd), .mem_wr(b_we), .mem_burstcnt(bt_burst),
    .mem_din(b_din), .mem_be(b_be),
    .mem_dout(d_dout), .mem_dout_ready(d_dready), .mem_busy(d_busy),
    .p0_addr(s_src_addr), .p0_rd(s_src_rd), .p0_dout(s_src_dout), .p0_ok(s_src_ok),
    .fb_wr_en(fb_wr_en), .fb_wr_qw(fb_wr_qw), .fb_wr_lane(fb_wr_lane), .fb_wr_pix(fb_wr_pix),
    .fb_rd_en(fb_rd_en), .fb_rd_qw(fb_rd_qw), .fb_rd_qword(fb_rd_qword),
    .idle(bt_idle));

  always @(posedge clk) begin
    d_dready <= 1'b0; d_dout <= 64'hDEAD_BEEF_DEAD_BEEF;
    if (rst) begin rbeats<=0; rlat<=0; end
    else begin
      if (rlat!=3'd0) rlat<=rlat-3'd1;
      else if (rbeats!=8'd0) begin
        if (bp==2'd2) begin d_dout<=mem[raddr-WBASE]; d_dready<=1'b1; raddr<=raddr+29'd1; rbeats<=rbeats-8'd1; end
      end else if (!d_busy) begin
        if (b_rd) begin rbeats<=bt_burst; raddr<=bt_addr[28:0]; rlat<=3'd3; end
        else if (b_we) for(i=0;i<8;i=i+1) if(b_be[i]) mem[(bt_addr[28:0]-WBASE)][i*8 +:8]<=b_din[i*8 +:8];
      end
    end
  end

  // reference per-pixel-alpha blend (REPLICATES blend4444 in blitter_top.sv and
  // blt_blend4444 in blitter_ref.h). Caller handles a4==0 skip outside.
  function [15:0] ref_blend4444(input [15:0] s, input [15:0] d);
    reg [3:0] a4,r4,g4,b4; reg [7:0] a8,na;
    reg [4:0] sr,br,dr,db; reg [5:0] sg,dg;
    integer tr,tg,tb,orr,ogg,obb;
    begin
      a4=s[15:12]; r4=s[11:8]; g4=s[7:4]; b4=s[3:0];
      a8={a4,a4}; na=8'd255-a8;
      sr={r4,r4[3]}; sg={g4,g4[3:2]}; br={b4,b4[3]};
      dr=d[15:11]; dg=d[10:5]; db=d[4:0];
      tr=sr*a8+dr*na; orr=(tr+128+((tr+128)>>8))>>8;
      tg=sg*a8+dg*na; ogg=(tg+128+((tg+128)>>8))>>8;
      tb=br*a8+db*na; obb=(tb+128+((tb+128)>>8))>>8;
      ref_blend4444={orr[4:0],ogg[5:0],obb[4:0]};
    end
  endfunction

  // the four ARGB4444 source pixels
  localparam [15:0] SP00 = 16'h0F00;  // A=0  R=15 G=0  B=0   -> transparent
  localparam [15:0] SP10 = 16'hFF00;  // A=15 R=15 G=0  B=0   -> opaque red
  localparam [15:0] SP01 = 16'h80F0;  // A=8  R=0  G=15 B=0   -> half green
  localparam [15:0] SP11 = 16'h400F;  // A=4  R=0  G=0  B=15  -> light blue

  integer errs=0;
  initial begin
    for(i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    // seed the on-chip FB with BG (CLEAR no longer reaches comp_fbram post-cutover).
    for(i=0;i<`FB_QWORDS;i=i+1) begin
      fbram.bank0[i]=BG; fbram.bank1[i]=BG; fbram.bank2[i]=BG; fbram.bank3[i]=BG; end
    mem[32'h200007]=64'd2;  // C_PIPE: bit1 -> route via comp_pipeline (Spec A)
    // control: submit=1, 2 cmds (PALPHA BLIT, END), CLEAR to BG
    mem[32'h200000]=64'd1; mem[32'h200001]=64'd2; mem[32'h200002]=64'd0;
    mem[32'h200003]={48'd0,BG}; mem[32'h200004]=64'd0; mem[32'h200005]=64'd0;  // no CLEAR: FB pre-seeded BG (Phase 0a)
    // cmd0 PALPHA BLIT: blend=3(PALPHA) format=1(ARGB4444), src_off=0, w=2 h=2
    //   stride=4, dst=(70,70). (colorkey/alpha fields unused for palpha)
    mem[32'h200008]={32'd0, 8'd0,8'd1,8'd3,8'd3};   // op=BLIT(3) blend=PALPHA(3) fmt=ARGB4444(1)
    mem[32'h200009]={16'd2,16'd2,16'd0,16'd4};       // h=2 w=2 src_x=0 stride=4
    mem[32'h20000A]={16'd70,16'd70,16'd0,16'd0};     // dst=(70,70) src_y=0
    mem[32'h20000B]={16'd0,16'd0,8'd0,16'd0};        // (no key/alpha)
    mem[32'h20000C]=64'd1;                           // cmd1 END
    // ARGB4444 source @ SRC (0xF000): 2x2, stride 4B. With stride=4 the whole
    // 2x2 surface is 16 bytes = TWO qwords' worth but PACKED: row0 at bytes 0..3
    // (qw 0xF000 [31:0]), row1 at bytes 4..7 (qw 0xF000 [63:32]). So a single
    // qword holds the entire sprite: {px(1,1),px(0,1),px(1,0),px(0,0)}.
    mem[(SRC_WIN + 29'h00)]={SP11, SP01, SP10, SP00};
  end

  task ckpix(input integer dx, input integer dy, input [15:0] exp, input [127:0] tag);
    integer idx; reg [15:0] got;
    begin
      idx = dy*80 + (dx>>2);   // comp_fbram qword; lane = dx[1:0]
      got = ((dx&3)==0) ? fbram.bank0[idx] : ((dx&3)==1) ? fbram.bank1[idx] :
            ((dx&3)==2) ? fbram.bank2[idx] : fbram.bank3[idx];
      if (got!==exp) begin errs=errs+1; $display("  MISMATCH %0s (%0d,%0d): got %h exp %h",tag,dx,dy,got,exp); end
      else $display("  ok %0s (%0d,%0d) = %h",tag,dx,dy,got);
    end
  endtask

  integer to;
  initial begin
    repeat(8) @(posedge clk); rst<=0;
    to=0; while(mem[32'h200005][31:0]!==mem[32'h200000][31:0] && to<3000000) begin @(posedge clk); to=to+1; end
    repeat(10) @(posedge clk);
    $display("=== done_seq=%0d submit=%0d (to=%0d) ===", mem[32'h200005][31:0], mem[32'h200000][31:0], to);
    // px(0,0): A4==0 -> skip-write -> dest keeps BG background
    ckpix(70,70, BG, "palpha-transparent");
    // px(1,0): A4==15 -> fully opaque -> blend4444(SP10,BG) == expanded source
    ckpix(71,70, ref_blend4444(SP10, BG), "palpha-opaque");
    // px(0,1): A4==8  -> half blend
    ckpix(70,71, ref_blend4444(SP01, BG), "palpha-half");
    // px(1,1): A4==4  -> light blend
    ckpix(71,71, ref_blend4444(SP11, BG), "palpha-light");
    if (mem[32'h200005][31:0]==mem[32'h200000][31:0] && errs==0) $display("RESULT: PASS");
    else $display("RESULT: FAIL (errs=%0d)", errs);
    $finish;
  end
  initial begin #80000000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
