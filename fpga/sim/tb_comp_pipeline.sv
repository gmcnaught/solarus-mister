// tb_comp_pipeline.sv — standalone check of comp_pipeline against a behavioural DDR.
// Copyright (C) 2026 — GPL-3.0
//
// Drives comp_pipeline directly (no blitter_top) for two blits:
//   (1) a small COPY blit  — assert the dest qwords land the source pixels.
//   (2) a CONST_ALPHA blit — assert the blended result vs the golden formula.
// The DDR model mirrors tb_blitter_copy: single-beat reads with latency +
// backpressure, garbage on mem_dout except the dready beat, byte-enable writes.
`timescale 1ns/1ps
`default_nettype none
`include "comp_defs.vh"
`include "blitter_defs.vh"
module tb_comp_pipeline;
  localparam [28:0] WBASE = 29'h07400000;     // window base (qword) shared by FB+SRC
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h10000;  // [#52] tracks SRC_QW heap base
  localparam [15:0] BG = 16'h8410;

  reg clk=0, rst=1; always #5 clk=~clk;

  // comp_pipeline command interface
  reg        blit_start;
  reg        c_srcsel;                          // 1 = fetch source from SDRAM P_SRC
  reg  [7:0] c_opcode, c_blend, c_format, c_flags, c_alpha;
  reg [31:0] c_src_off;
  reg [15:0] c_src_stride, c_src_x, c_src_y, c_w, c_h, c_colorkey, c_color;
  reg signed [15:0] c_dst_x, c_dst_y;
  reg [31:0] target_base;
  wire       blit_done;

  // mem master
  wire [31:0] m_addr; wire m_rd, m_wr; wire [63:0] m_din; wire [7:0] m_be;
  wire [7:0]  m_burstcnt;
  reg  [63:0] m_dout; reg m_dready;

  reg [63:0] mem [0:MEMQW-1];
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat; reg [1:0] bp=0;
  always @(posedge clk) bp <= bp+2'd1;
  wire m_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  integer i;

  // ── P_SRC cache-ok behavioral model (Task 5: port rename + ok protocol). ──
  // The sprite atlas lives outside the FB range, so it reaches SDRAM only
  // through p0_* (the cache-ok channel), never the DDR mem_* path for FB.
  // Protocol: on p0_rd rising edge, after P_SRC_LAT cycles assert p0_ok with
  // the qword from srcmem indexed by p0_addr[12:3].
  localparam P_SRC_LAT = 3;
  wire [26:0] s_src_addr; wire s_src_rd;
  reg  [63:0] s_src_dout; reg s_src_ok=1'b0;
  reg  [63:0] srcmem [0:1023];
  reg         s_rd_d;
  reg [26:0]  s_lat_addr [0:P_SRC_LAT-1];
  reg         s_lat_v    [0:P_SRC_LAT-1];
  integer     sli_cp;
  always @(posedge clk) s_rd_d <= s_src_rd;
  always @(posedge clk) begin
    s_src_ok <= 1'b0;
    s_lat_v   [0] <= s_src_rd & ~s_rd_d;
    s_lat_addr[0] <= s_src_addr;
    for (sli_cp = 1; sli_cp < P_SRC_LAT; sli_cp = sli_cp + 1) begin
      s_lat_v   [sli_cp] <= s_lat_v   [sli_cp-1];
      s_lat_addr[sli_cp] <= s_lat_addr[sli_cp-1];
    end
    if (s_lat_v[P_SRC_LAT-1]) begin
      s_src_dout <= srcmem[s_lat_addr[P_SRC_LAT-1][12:3]];
      s_src_ok   <= 1'b1;
    end
  end

  // ── on-chip destination framebuffer [FB-in-BRAM] ───────────────────────────
  // The composite dest now lives in comp_fbram (not the SDRAM/mem[] FB). comp_pipeline
  // drives the RMW read (fb_rd_*) and composite write (fb_wr_*); we seed it with BG and
  // read composited pixels back from it (getpx peeks the banks).
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

  // golden const-alpha blend (matches comp_mixer / blend565)
  function [15:0] ref_blend(input [15:0] s, input [15:0] d, input [7:0] a);
    integer sr,sg,sb,dr,dg,db,ia,na,tr,tg,tb,orr,ogg,obb;
    begin
      sr=s[15:11]; sg=s[10:5]; sb=s[4:0]; dr=d[15:11]; dg=d[10:5]; db=d[4:0];
      ia=a; na=255-a;
      tr=sr*ia+dr*na; orr=(tr+128+((tr+128)>>8))>>8;
      tg=sg*ia+dg*na; ogg=(tg+128+((tg+128)>>8))>>8;
      tb=sb*ia+db*na; obb=(tb+128+((tb+128)>>8))>>8;
      ref_blend={orr[4:0],ogg[5:0],obb[4:0]};
    end
  endfunction

  // golden per-pixel-alpha blend = legacy blitter_top blend4444 (bit-exact target).
  // comp_pipeline pre-expands the ARGB4444 source to RGB565 (sr={r4,r4[3]}, etc.)
  // and feeds comp_mixer in COMP_CA mode with a8={a4,a4}, so the pipeline result
  // matches this reference (and the C-reference blt_blend4444).
  function [15:0] ref_pa(input [15:0] s, input [15:0] d);
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
      ref_pa={orr[4:0],ogg[5:0],obb[4:0]};
    end
  endfunction

  integer errs=0, x, y, to;
  // FB pixel (dx,dy) now lives in comp_fbram: qword = dy*80+(dx>>2), lane = dx[1:0].
  // (dy*320 contributes 0 to the lane since 320%4==0.) Peek the four lane banks.
  function [15:0] getpx(input integer dx, input integer dy);
    integer qw; integer lane;
    begin
      qw   = dy*80 + (dx>>2);
      lane = dx & 3;
      getpx = (lane==0) ? fbram.bank0[qw] :
              (lane==1) ? fbram.bank1[qw] :
              (lane==2) ? fbram.bank2[qw] : fbram.bank3[qw];
    end
  endfunction
  task ckpix(input integer dx, input integer dy, input [15:0] exp, input [127:0] tag);
    reg [15:0] got; begin got=getpx(dx,dy);
      if (got!==exp) begin errs=errs+1; $display("  MISMATCH %0s (%0d,%0d): got %h exp %h",tag,dx,dy,got,exp); end
      else $display("  ok %0s (%0d,%0d) = %h",tag,dx,dy,got);
    end endtask

  task run_blit; begin
    @(posedge clk); blit_start<=1'b1; @(posedge clk); blit_start<=1'b0;
    to=0; while(!blit_done && to<500000) begin @(posedge clk); to=to+1; end
    repeat(4) @(posedge clk);
  end endtask

`ifdef PROBE
  always @(posedge clk) if(!rst) begin
    if (dut.db_cw_we) $display("[%0t] CW we x=%0d row=%0d pix=%h", $time, dut.db_cw_x, dut.db_cw_row, dut.db_cw_pix);
    if (dut.db_fl_valid) $display("[%0t] FL idx=%0d qw=%h be=%h", $time, dut.db_fl_idx, dut.db_fl_qw, dut.db_fl_be);
    if (dut.mem_wr && !dut.mem_busy) $display("[%0t] MEMWR addr=%h be=%h din=%h", $time, dut.mem_addr, dut.mem_be, dut.mem_din);
    if (dut.mx_in_valid) $display("[%0t] MXIN src=%h dst=%h mode=%0d", $time, dut.mx_in_src, dut.mx_in_dst, dut.mx_in_mode);
  end
`endif

  initial begin
    for(i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    for(i=0;i<1024;i=i+1) srcmem[i]=64'd0;
    blit_start=0; c_srcsel=1'b1;   // single source pipeline: source always from P_SRC
    target_base = `FB0_QW;     // BUF0 = WBASE+8 in this window
    // fill the on-chip FB (comp_fbram) with BG — the dest the blend RMW reads back.
    for(i=0;i<`FB_QWORDS;i=i+1) begin
      fbram.bank0[i]=BG; fbram.bank1[i]=BG; fbram.bank2[i]=BG; fbram.bank3[i]=BG;
    end

    // [collapse-single-source] ALL source atlases now live in srcmem (the P_SRC /
    // SDRAM model), indexed by the heap-relative qword (= c_src_off>>3 + row*qw/row),
    // because the DDR3 live-source path was removed and comp_pipeline fetches every
    // source row through p0_* (byte addr = heap qword << 3). Each blit uses a distinct
    // c_src_off so the atlases never alias. The P_SRC model reads srcmem[p0_addr>>3].
    //
    // ── COPY source @ off 0: 8x4 sprite, px(x,y)=0x1000+y*8+x, stride 16B (2 qw/row) ──
    for(y=0;y<4;y=y+1) for(x=0;x<8;x=x+1)
      srcmem[0 + y*2 + (x>>2)][(x%4)*16 +: 16] = 16'h1000 + y*8 + x;
    // ── ALPHA source @ off 0x80 = qw 0x10: 2x2 solid REDS ──
    srcmem[16'h10]={16'hF800,16'hF800,16'hF800,16'hF800};
    srcmem[16'h11]={16'hF800,16'hF800,16'hF800,16'hF800};
    // ── COLORKEY source @ off 0x100 = qw 0x20: 4x1, px1==KEY (0x07E0); stride 8B ──
    srcmem[16'h20]={16'h3003, 16'h07E0, 16'h3001, 16'h3000};
    // ── PALPHA (ARGB4444) source @ off 0x180 = qw 0x30: 2x2, stride 4B ──
    //    {px11,px01,px10,px00}; A=0 transparent, A=15 opaque, A=8/4 blends.
    srcmem[16'h30]={16'h400F, 16'h80F0, 16'hFF00, 16'h0F00};
    // ── HFLIP source @ off 0x200 = qw 0x40: 5x1, px(x)=0x4000+x, stride 10B ──
    for(x=0;x<5;x=x+1) srcmem[16'h40 + (x*2)/8][((x*2)%8)*8 +:16] = 16'h4000+x;
    // ── TALL source @ off 0x800 = qw 0x100: 2 wide x 20 rows, stride 4B ──
    //    px(x,y)=0x5000+y*2+x. one qword per row.
    for(y=0;y<20;y=y+1) srcmem[16'h100 + y] = {16'd0, 16'd0,
        16'(16'h5000 + y*2 + 1), 16'(16'h5000 + y*2 + 0)};
    // ── SDRAM-source COPY atlas @ off 0x900 = qw 0x120: 6px run 0x7000..0x7005 ──
    srcmem[16'h120]={16'h7003,16'h7002,16'h7001,16'h7000};
    srcmem[16'h121]={16'h7007,16'h7006,16'h7005,16'h7004};

    repeat(8) @(posedge clk); rst<=0; repeat(2) @(posedge clk);

    // ── BLIT 1: COPY 8x4 to (20,10) ──
    c_opcode=8'd3; c_blend=8'd0; c_format=8'd0; c_flags=8'd0;
    c_src_off=32'd0; c_src_stride=16'd16; c_src_x=16'd0; c_src_y=16'd0;
    c_w=16'd8; c_h=16'd4; c_colorkey=16'd0; c_alpha=8'd0; c_color=16'd0;
    c_dst_x=16'd20; c_dst_y=16'd10;
    run_blit;
    $display("=== COPY done (to=%0d) ===", to);
    ckpix(20,10, 16'h1000, "copy-tl"); ckpix(27,10, 16'h1007, "copy-tr");
    ckpix(20,13, 16'h1018, "copy-bl"); ckpix(27,13, 16'h101F, "copy-br");
    ckpix(24,11, 16'h100C, "copy-mid");
    ckpix(19,10, BG, "copy-leftbg"); ckpix(28,10, BG, "copy-rightbg");

    // ── BLIT 2: CONST_ALPHA 2x2 REDS @ (60,60), alpha=128, over BG ──
    c_opcode=8'd3; c_blend=8'd2; c_format=8'd0; c_flags=8'd0;
    c_src_off=32'h80; c_src_stride=16'd4; c_src_x=16'd0; c_src_y=16'd0;
    c_w=16'd2; c_h=16'd2; c_colorkey=16'd0; c_alpha=8'd128; c_color=16'd0;
    c_dst_x=16'd60; c_dst_y=16'd60;
    run_blit;
    $display("=== ALPHA done (to=%0d) ===", to);
    ckpix(60,60, ref_blend(16'hF800, BG, 8'd128), "alpha00");
    ckpix(61,60, ref_blend(16'hF800, BG, 8'd128), "alpha10");
    ckpix(60,61, ref_blend(16'hF800, BG, 8'd128), "alpha01");
    ckpix(61,61, ref_blend(16'hF800, BG, 8'd128), "alpha11");

    // ── BLIT 3: COLORKEY 4x1 @ (80,80); src px1==KEY -> skip (keep BG) ──
    c_opcode=8'd3; c_blend=8'd1; c_format=8'd0; c_flags=8'd0;
    c_src_off=32'h100; c_src_stride=16'd8; c_src_x=16'd0; c_src_y=16'd0;
    c_w=16'd4; c_h=16'd1; c_colorkey=16'h07E0; c_alpha=8'd0; c_color=16'd0;
    c_dst_x=16'd80; c_dst_y=16'd80;
    run_blit;
    $display("=== COLORKEY done (to=%0d) ===", to);
    ckpix(80,80, 16'h3000, "key0");  ckpix(81,80, 16'h3001, "key1");
    ckpix(82,80, BG, "key2-skip");   ckpix(83,80, 16'h3003, "key3");

    // ── BLIT 4: PALPHA (ARGB4444) 2x2 @ (90,90) ──
    c_opcode=8'd3; c_blend=8'd3; c_format=8'd1; c_flags=8'd0;
    c_src_off=32'h180; c_src_stride=16'd4; c_src_x=16'd0; c_src_y=16'd0;
    c_w=16'd2; c_h=16'd2; c_colorkey=16'd0; c_alpha=8'd0; c_color=16'd0;
    c_dst_x=16'd90; c_dst_y=16'd90;
    run_blit;
    $display("=== PALPHA done (to=%0d) ===", to);
    ckpix(90,90, BG, "pa-transparent");              // A=0 skip
    ckpix(91,90, ref_pa(16'hFF00, BG), "pa-opaque"); // A=15
    ckpix(90,91, ref_pa(16'h80F0, BG), "pa-half");   // A=8
    ckpix(91,91, ref_pa(16'h400F, BG), "pa-light");  // A=4

    // ── BLIT 5: FILL 3x2 rect @ (100,100) with c_color ──
    c_opcode=8'd2; c_blend=8'd0; c_format=8'd0; c_flags=8'd0;
    c_src_off=32'd0; c_src_stride=16'd0; c_src_x=16'd0; c_src_y=16'd0;
    c_w=16'd3; c_h=16'd2; c_colorkey=16'd0; c_alpha=8'd0; c_color=16'hABCD;
    c_dst_x=16'd100; c_dst_y=16'd100;
    run_blit;
    $display("=== FILL done (to=%0d) ===", to);
    ckpix(100,100, 16'hABCD, "fill00"); ckpix(102,100, 16'hABCD, "fill20");
    ckpix(100,101, 16'hABCD, "fill01"); ckpix(102,101, 16'hABCD, "fill21");
    ckpix(99,100, BG, "fill-leftbg"); ckpix(103,100, BG, "fill-rightbg");

    // ── BLIT 6: HFLIP COPY 5x1 @ (110,110); dst(110+i)=src(4-i) ──
    c_opcode=8'd3; c_blend=8'd0; c_format=8'd0; c_flags=8'h01;
    c_src_off=32'h200; c_src_stride=16'd10; c_src_x=16'd0; c_src_y=16'd0;
    c_w=16'd5; c_h=16'd1; c_colorkey=16'd0; c_alpha=8'd0; c_color=16'd0;
    c_dst_x=16'd110; c_dst_y=16'd110;
    run_blit;
    $display("=== HFLIP done (to=%0d) ===", to);
    for(x=0;x<5;x=x+1) ckpix(110+x,110, 16'h4000+(4-x), "hflip");

    // ── BLIT 7: TALL COPY 2x20 @ (5,1) -> spans >16 rows = 2 chunks ──
    //    stride 8B = one source qword per row (qw 0x201100+y).
    c_opcode=8'd3; c_blend=8'd0; c_format=8'd0; c_flags=8'd0;
    c_src_off=32'h800; c_src_stride=16'd8; c_src_x=16'd0; c_src_y=16'd0;
    c_w=16'd2; c_h=16'd20; c_colorkey=16'd0; c_alpha=8'd0; c_color=16'd0;
    c_dst_x=16'd5; c_dst_y=16'd1;
    run_blit;
    $display("=== TALL done (to=%0d) ===", to);
    // verify rows spanning the 16-row chunk boundary (rows 0..15 then 16..19)
    ckpix(5,1,  16'h5000, "tall-r0a");  ckpix(6,1,  16'h5001, "tall-r0b");
    ckpix(5,16, 16'h501E, "tall-r15a"); ckpix(6,16, 16'h501F, "tall-r15b"); // y=16 -> src row15
    ckpix(5,17, 16'h5020, "tall-r16a"); ckpix(6,17, 16'h5021, "tall-r16b"); // y=17 -> src row16 (chunk2)
    ckpix(5,20, 16'h5026, "tall-r19a"); ckpix(6,20, 16'h5027, "tall-r19b"); // y=20 -> src row19

    // ── BLIT 8: SDRAM-SOURCE COPY 6x1 @ (40,40) — src @ off 0x900 (srcmem qw 0x120) ──
    //    Same P_SRC path as every other blit now; distinct off so it doesn't alias
    //    the off-0 COPY atlas. src qwords come from srcmem[0x120..0x121].
    c_opcode=8'd3; c_blend=8'd0; c_format=8'd0; c_flags=8'd0;
    c_src_off=32'h900; c_src_stride=16'd8; c_src_x=16'd0; c_src_y=16'd0;
    c_w=16'd6; c_h=16'd1; c_colorkey=16'd0; c_alpha=8'd0; c_color=16'd0;
    c_dst_x=16'd40; c_dst_y=16'd40;
    run_blit;
    $display("=== SDRAM-COPY done (to=%0d) ===", to);
    for(x=0;x<6;x=x+1) ckpix(40+x,40, 16'(16'h7000+x), "sdram-copy");

    if (errs==0) $display("RESULT: PASS"); else $display("RESULT: FAIL (errs=%0d)", errs);
    $finish;
  end
  initial begin #50000000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
