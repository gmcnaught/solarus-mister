// tb_argb4444_blendmodes.sv — issue #115 (follow-up of #100): POSITIVE ARGB4444
// coverage across ALL blend modes.
//
// DUT LEVEL: comp_pipeline (NOT comp_mixer). The ARGB4444 -> {R5,G6,B5} channel
// decode is NOT done by comp_mixer — that module's in_fmt input is unused for the
// colour decode and it always treats in_src as RGB565. The #100 fix that decodes
// ARGB4444 for every blend mode lives ENTIRELY in comp_pipeline.sv (the wires
// pa_expanded / c_color_exp / feed_src / fill_src / is_argb4444), which expands the
// 4-bit channels to 5/6/5 and drops A4 BEFORE the pixel reaches comp_mixer. So the
// only place this behaviour can be exercised is comp_pipeline. We reuse the
// tb_comp_pipeline harness pattern (P_SRC source model + comp_fbram dest + read the
// composited pixel back).
//
// WHAT IT ASSERTS: for c_format = FMT_ARGB4444 (`COMP_ARGB4444 = 8'd1) we drive a
// representative ARGB4444 source (or c_color for FILL) through each of COPY, KEY
// (colour-key hit + miss), ADD (blend mode 4), MULTIPLY (blend mode 5) and an
// ARGB4444 FILL, and check the composited FB pixel equals a golden computed from the
// ARGB4444 field layout {A4=src[15:12], R4=src[11:8], G4=src[7:4], B4=src[3:0]},
// expanded R5={R4,R4[3]}, G6={G4,G4[3:2]}, B5={B4,B4[3]}, A4 dropped for these modes.
//
// REGRESSION NET: the source values are chosen so ARGB4444-decode DIVERGES from an
// RGB565 misread of the same 16 bits. E.g. COPY src 0x8ABC decodes to 0xADD9 but the
// old (pre-#100) code fed the raw 0x8ABC straight through as RGB565 — a regression to
// that interpretation writes 0x8ABC and trips the COPY assertion. Alpha classes are
// covered on the COPY blit: a4==0 (0x0ABC), a4==15 (0xF13F), a4==8 (0x8ABC); since A4
// is dropped, each must decode to its A4-independent colour — a regression that leaked
// A4 into the colour would fail these too.
//
`timescale 1ns/1ps
`default_nettype none
`include "comp_defs.vh"
`include "blitter_defs.vh"
module tb_argb4444_blendmodes;
  localparam [28:0] WBASE = 29'h07400000;     // window base (qword)
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h10000;
  localparam [15:0] BG = 16'h8410;            // mid-grey RGB565 dest background

  reg clk=0, rst=1; always #5 clk=~clk;

  // ── comp_pipeline command interface ─────────────────────────────────────────
  reg        blit_start;
  reg        c_srcsel;
  reg  [7:0] c_opcode, c_blend, c_format, c_flags, c_alpha;
  reg [31:0] c_src_off;
  reg [15:0] c_src_stride, c_src_x, c_src_y, c_w, c_h, c_colorkey, c_color;
  reg signed [15:0] c_dst_x, c_dst_y;
  reg [31:0] target_base;
  wire       blit_done;

  // color-mod tied to identity (F_COLORMOD clear -> true no-op)
  wire [7:0] c_cmod_r = 8'd255, c_cmod_g = 8'd255, c_cmod_b = 8'd255;

  // ── behavioural DDR (mem_* master is idle in comp_pipeline post FB-in-BRAM, but
  //    the port must be wired; model it like tb_comp_pipeline) ──────────────────
  wire [31:0] m_addr; wire m_rd, m_wr; wire [63:0] m_din; wire [7:0] m_be;
  wire [7:0]  m_burstcnt;
  reg  [63:0] m_dout; reg m_dready;
  reg [63:0] mem [0:MEMQW-1];
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat; reg [1:0] bp=0;
  always @(posedge clk) bp <= bp+2'd1;
  wire m_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  integer i;

  // ── P_SRC cache-ok source model (identical to tb_comp_pipeline) ─────────────
  localparam P_SRC_LAT = 3;
  wire [26:0] s_src_addr; wire s_src_rd;
  reg  [63:0] s_src_dout; reg s_src_ok=1'b0;
  reg  [63:0] srcmem [0:1023];
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
      s_src_dout <= srcmem[s_lat_addr[P_SRC_LAT-1][12:3]];
      s_src_ok   <= 1'b1;
    end
  end

  // ── on-chip destination framebuffer (comp_fbram) ────────────────────────────
  wire        fb_wr_en;  wire [14:0] fb_wr_qw; wire [1:0] fb_wr_lane; wire [15:0] fb_wr_pix;
  wire        fb_rd_en;  wire [14:0] fb_rd_qw; wire [63:0] fb_rd_qword;
  comp_fbram fbram(
    .clk(clk),
    .wr_en(fb_wr_en), .wr_qw(fb_wr_qw), .wr_lane(fb_wr_lane), .wr_pix(fb_wr_pix),
    .rd_en(fb_rd_en), .rd_qw(fb_rd_qw), .rd_qword(fb_rd_qword));

  comp_pipeline dut(
    .clk(clk), .rst(rst),
    .blit_start(blit_start),
    .c_opcode(c_opcode), .c_blend(c_blend), .c_format(c_format), .c_flags(c_flags),
    .c_src_off(c_src_off), .c_src_stride(c_src_stride), .c_src_x(c_src_x), .c_src_y(c_src_y),
    .c_w(c_w), .c_h(c_h), .c_colorkey(c_colorkey), .c_alpha(c_alpha), .c_color(c_color),
    .c_cmod_r(c_cmod_r), .c_cmod_g(c_cmod_g), .c_cmod_b(c_cmod_b),
    .c_dst_x(c_dst_x), .c_dst_y(c_dst_y), .target_base(target_base),
    .mem_addr(m_addr), .mem_rd(m_rd), .mem_wr(m_wr), .mem_burstcnt(m_burstcnt),
    .mem_din(m_din), .mem_be(m_be),
    .mem_dout(m_dout), .mem_dout_ready(m_dready), .mem_busy(m_busy),
    .c_srcsel(c_srcsel),
    .p0_addr(s_src_addr), .p0_rd(s_src_rd),
    .p0_dout(s_src_dout), .p0_ok(s_src_ok),
    .fb_wr_en(fb_wr_en), .fb_wr_qw(fb_wr_qw), .fb_wr_lane(fb_wr_lane), .fb_wr_pix(fb_wr_pix),
    .fb_rd_en(fb_rd_en), .fb_rd_qw(fb_rd_qw), .fb_rd_qword(fb_rd_qword),
    .blit_done(blit_done));

  always @(posedge clk) begin
    m_dready <= 1'b0; m_dout <= 64'hDEAD_BEEF_DEAD_BEEF;
    if (rst) begin rbeats<=0; rlat<=0; end
    else begin
      if (rlat!=3'd0) rlat<=rlat-3'd1;
      else if (rbeats!=8'd0) begin
        if (bp==2'd2) begin m_dout<=mem[raddr-WBASE]; m_dready<=1'b1; raddr<=raddr+29'd1; rbeats<=rbeats-8'd1; end
      end else if (!m_busy) begin
        if (m_rd) begin rbeats<=m_burstcnt; raddr<=m_addr[28:0]; rlat<=3'd3; end
        else if (m_wr) for(i=0;i<8;i=i+1) if(m_be[i]) mem[(m_addr[28:0]-WBASE)][i*8 +:8]<=m_din[i*8 +:8];
      end
    end
  end

  // ══════════════════════════════════════════════════════════════════════════
  //  GOLDEN reference — the ARGB4444 field decode comp_pipeline performs.
  //  (Intermediate-variable idiom: Icarus cannot part-select macro/expr results.)
  // ══════════════════════════════════════════════════════════════════════════
  // Expand ARGB4444 -> RGB565, dropping A4 (correct for COPY/KEY/ADD/MUL/FILL).
  function [15:0] argb_to_565(input [15:0] s);
    reg [3:0] r4,g4,b4;
    begin
      r4=s[11:8]; g4=s[7:4]; b4=s[3:0];
      argb_to_565 = {r4, r4[3], g4, g4[3:2], b4, b4[3]};
    end
  endfunction

  // per-channel saturating ADD of two RGB565 pixels (matches comp_mixer COMP_ADD)
  function [15:0] ref_add(input [15:0] s565, input [15:0] d);
    integer sr,sg,sb,dr,dg,db,rr,gg,bb;
    begin
      sr=s565[15:11]; sg=s565[10:5]; sb=s565[4:0];
      dr=d[15:11]; dg=d[10:5]; db=d[4:0];
      rr=sr+dr; if(rr>31) rr=31;
      gg=sg+dg; if(gg>63) gg=63;
      bb=sb+db; if(bb>31) bb=31;
      ref_add = {rr[4:0], gg[5:0], bb[4:0]};
    end
  endfunction

  // per-channel MULTIPLY, divide-free round(p/chan_max) (matches comp_mixer COMP_MUL)
  function [15:0] ref_mul(input [15:0] s565, input [15:0] d);
    integer sr,sg,sb,dr,dg,db, pr,pg,pb, rr,gg,bb;
    begin
      sr=s565[15:11]; sg=s565[10:5]; sb=s565[4:0];
      dr=d[15:11]; dg=d[10:5]; db=d[4:0];
      pr=sr*dr; rr=((pr+16)+((pr+16)>>5))>>5;
      pg=sg*dg; gg=((pg+32)+((pg+32)>>6))>>6;
      pb=sb*db; bb=((pb+16)+((pb+16)>>5))>>5;
      ref_mul = {rr[4:0], gg[5:0], bb[4:0]};
    end
  endfunction

  // ── FB peek: pixel (dx,dy) -> qword dy*80+(dx>>2), lane dx[1:0] ──────────────
  function [15:0] getpx(input integer dx, input integer dy);
    integer qw, lane;
    begin
      qw = dy*80 + (dx>>2);
      lane = dx & 3;
      case (lane)
        0:       getpx = fbram.bank0[qw];
        1:       getpx = fbram.bank1[qw];
        2:       getpx = fbram.bank2[qw];
        default: getpx = fbram.bank3[qw];
      endcase
    end
  endfunction

  integer errs=0, x, y, to;
  reg [15:0] gpx;
  task ckpix(input integer dx, input integer dy, input [15:0] exp, input [127:0] tag);
    reg [15:0] got; begin got=getpx(dx,dy);
      if (got!==exp) begin errs=errs+1; $display("  MISMATCH %0s (%0d,%0d): got %h exp %h",tag,dx,dy,got,exp); end
      else $display("  ok %0s (%0d,%0d) = %h",tag,dx,dy,got);
    end
  endtask

  task run_blit; begin
    @(posedge clk); blit_start<=1'b1; @(posedge clk); blit_start<=1'b0;
    to=0; while(!blit_done && to<500000) begin @(posedge clk); to=to+1; end
    repeat(4) @(posedge clk);
  end endtask

  // ── ARGB4444 source pixels (chosen so decode != RGB565 misread) ─────────────
  //  COPY (a4 classes): a4==0, a4==15, a4==8
  localparam [15:0] CP0 = 16'h0ABC;   // a4==0
  localparam [15:0] CP1 = 16'hF13F;   // a4==15
  localparam [15:0] CP2 = 16'h8ABC;   // a4==8  -> decodes 0xADD9, raw misread 0x8ABC
  //  KEY: KP0 decodes to the colour-key (hit -> skip), KP1 decodes elsewhere (miss)
  localparam [15:0] KP0 = 16'hF00F;   // -> 0x001F == c_colorkey -> keyed skip -> keep BG
  localparam [15:0] KP1 = 16'h8ABC;   // -> 0xADD9 != key         -> write
  localparam [15:0] KEYVAL = 16'h001F;
  //  ADD: AP0 no saturation, AP1 saturates all channels
  localparam [15:0] AP0 = 16'h8123;   // -> 0x1106
  localparam [15:0] AP1 = 16'h8ABC;   // -> 0xADD9 (saturates against BG)
  //  MUL
  localparam [15:0] MP0 = 16'h8ABC;   // -> 0xADD9
  localparam [15:0] MP1 = 16'h8123;   // -> 0x1106
  //  FILL colour (ARGB4444 in c_color)
  localparam [15:0] FCOL = 16'h8ABC;  // -> 0xADD9

  initial begin
    for(i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    for(i=0;i<1024;i=i+1) srcmem[i]=64'd0;
    blit_start=0; c_srcsel=1'b1;
    target_base = `FB0_QW;
    // seed the on-chip FB with BG (the dest the blend RMW reads back)
    for(i=0;i<`FB_QWORDS;i=i+1) begin
      fbram.bank0[i]=BG; fbram.bank1[i]=BG; fbram.bank2[i]=BG; fbram.bank3[i]=BG;
    end

    // source atlases in srcmem (indexed by heap qword = c_src_off>>3):
    // COPY @ off 0x000 (qw 0):    3 px, stride 6 -> {px2,px1,px0} in one qword
    srcmem[16'h00] = {16'h0000, CP2, CP1, CP0};
    // KEY  @ off 0x080 (qw 0x10): 2 px, stride 4 -> {px1,px0}
    srcmem[16'h10] = {32'h0000_0000, KP1, KP0};
    // ADD  @ off 0x100 (qw 0x20): 2 px, stride 4
    srcmem[16'h20] = {32'h0000_0000, AP1, AP0};
    // MUL  @ off 0x180 (qw 0x30): 2 px, stride 4
    srcmem[16'h30] = {32'h0000_0000, MP1, MP0};

    repeat(8) @(posedge clk); rst<=0; repeat(2) @(posedge clk);

    // ─────────────────────────────────────────────────────────────────────────
    // BLIT 1: COPY, ARGB4444, 3x1 @ (20,10). Covers a4 = 0 / 15 / 8.
    c_opcode=8'd3; c_blend=`COMP_COPY; c_format=`COMP_ARGB4444; c_flags=8'd0;
    c_src_off=32'h000; c_src_stride=16'd6; c_src_x=16'd0; c_src_y=16'd0;
    c_w=16'd3; c_h=16'd1; c_colorkey=16'd0; c_alpha=8'd0; c_color=16'd0;
    c_dst_x=16'd20; c_dst_y=16'd10;
    run_blit;
    $display("=== COPY ARGB4444 done (to=%0d) ===", to);
    ckpix(20,10, argb_to_565(CP0), "copy-a0");   // a4==0
    ckpix(21,10, argb_to_565(CP1), "copy-a15");  // a4==15
    ckpix(22,10, argb_to_565(CP2), "copy-a8");   // a4==8
    // meaningful-test guard: the decoded golden MUST differ from an RGB565 misread
    // of the raw 16 bits, else a regression could not be caught.
    if (argb_to_565(CP2) === CP2) begin
      errs=errs+1; $display("  NONDIVERGENT copy: decode==rawbits %h (test would not catch RGB565 regression)", CP2);
    end else
      $display("  divergence-ok copy: decode %h != rawbits %h", argb_to_565(CP2), CP2);

    // ─────────────────────────────────────────────────────────────────────────
    // BLIT 2: KEY (colour-key), ARGB4444, 2x1 @ (30,20). px0 hit (skip), px1 miss.
    c_opcode=8'd3; c_blend=`COMP_KEY; c_format=`COMP_ARGB4444; c_flags=8'd0;
    c_src_off=32'h080; c_src_stride=16'd4; c_src_x=16'd0; c_src_y=16'd0;
    c_w=16'd2; c_h=16'd1; c_colorkey=KEYVAL; c_alpha=8'd0; c_color=16'd0;
    c_dst_x=16'd30; c_dst_y=16'd20;
    run_blit;
    $display("=== KEY ARGB4444 done (to=%0d) ===", to);
    ckpix(30,20, BG,               "key-hit-skip");   // decode==key -> keep BG
    ckpix(31,20, argb_to_565(KP1), "key-miss-write"); // decode!=key -> write decoded

    // ─────────────────────────────────────────────────────────────────────────
    // BLIT 3: ADD (blend mode 4), ARGB4444, 2x1 @ (40,30) over BG.
    c_opcode=8'd3; c_blend=8'd4; c_format=`COMP_ARGB4444; c_flags=8'd0;
    c_src_off=32'h100; c_src_stride=16'd4; c_src_x=16'd0; c_src_y=16'd0;
    c_w=16'd2; c_h=16'd1; c_colorkey=16'd0; c_alpha=8'd0; c_color=16'd0;
    c_dst_x=16'd40; c_dst_y=16'd30;
    run_blit;
    $display("=== ADD ARGB4444 done (to=%0d) ===", to);
    ckpix(40,30, ref_add(argb_to_565(AP0), BG), "add-nosat"); // 0x1106 + BG
    ckpix(41,30, ref_add(argb_to_565(AP1), BG), "add-sat");   // 0xADD9 + BG (saturates)

    // ─────────────────────────────────────────────────────────────────────────
    // BLIT 4: MULTIPLY (blend mode 5), ARGB4444, 2x1 @ (50,40) over BG.
    c_opcode=8'd3; c_blend=8'd5; c_format=`COMP_ARGB4444; c_flags=8'd0;
    c_src_off=32'h180; c_src_stride=16'd4; c_src_x=16'd0; c_src_y=16'd0;
    c_w=16'd2; c_h=16'd1; c_colorkey=16'd0; c_alpha=8'd0; c_color=16'd0;
    c_dst_x=16'd50; c_dst_y=16'd40;
    run_blit;
    $display("=== MULTIPLY ARGB4444 done (to=%0d) ===", to);
    ckpix(50,40, ref_mul(argb_to_565(MP0), BG), "mul0"); // 0xADD9 * BG
    ckpix(51,40, ref_mul(argb_to_565(MP1), BG), "mul1"); // 0x1106 * BG

    // ─────────────────────────────────────────────────────────────────────────
    // BLIT 5: FILL, ARGB4444 colour in c_color, 2x1 @ (60,50).
    c_opcode=8'd2; c_blend=`COMP_COPY; c_format=`COMP_ARGB4444; c_flags=8'd0;
    c_src_off=32'd0; c_src_stride=16'd0; c_src_x=16'd0; c_src_y=16'd0;
    c_w=16'd2; c_h=16'd1; c_colorkey=16'd0; c_alpha=8'd0; c_color=FCOL;
    c_dst_x=16'd60; c_dst_y=16'd50;
    run_blit;
    $display("=== FILL ARGB4444 done (to=%0d) ===", to);
    ckpix(60,50, argb_to_565(FCOL), "fill0"); // c_color expanded 4->5/6/5
    ckpix(61,50, argb_to_565(FCOL), "fill1");

    if (errs==0) $display("RESULT: PASS"); else $display("RESULT: FAIL (errs=%0d)", errs);
    $finish;
  end
  initial begin #50000000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
