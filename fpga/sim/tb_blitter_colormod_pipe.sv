// tb_blitter_colormod_pipe.sv — v2 escape elimination: COLOUR-MOD (BLT_F_COLORMOD
// = 0x40) modulates the SOURCE by an 8-bit-per-channel tint BEFORE the blend, and
// composes with EVERY blend mode. Bit-exact to the C golden blt_tint565, through
// the comp_pipeline burst path (C_PIPE=1). Cases proven:
//   - COLORMOD over COPY  (BLIT)            -> dst = tint(src)
//   - COLORMOD over CONST_ALPHA (BLIT)      -> dst = blend(tint(src), bg, alpha)
//   - COLORMOD over PALPHA (ARGB4444 BLIT)  -> per-px src-over of tinted RGB
//   - COLORMOD over COPY  (FILL)            -> dst = tint(cmd.color)
//
//   tint:  out_ch = round(src_ch * mod_ch / 255)  via the canonical /255 reduce
//          out = (t + 128 + ((t+128)>>8)) >> 8,  t = src_ch*mod   (mod=255 => identity)
//
// MODULATION-COLOUR WIRE PLACEMENT — INTEGRATION CONTRACT for Workstream B.
// The frozen 32-byte command has no dedicated tint field yet (header _pad
// "reserved -> future tint"). This TB carries the 24-bit {cmod_r,cmod_g,cmod_b}
// in currently-RESERVED command bits; B's comp_pipeline must read EXACTLY these
// (or reconcile this TB + the C blt_execute _pad mapping to the final field):
//   CANONICAL wire layout (matches blt_wire.h + blitter_top.sv c_cmod_*):
//     cmod_b = cmd_qw[3][31:24]   (byte27, free above alpha in u32[6])
//     cmod_r = cmd_qw[3][55:48]   (byte30, free above color in u32[7])
//     cmod_g = cmd_qw[3][63:56]   (byte31)
// blend_mode (qw0[15:8]) and the COLORMOD flag (qw0[31:24] bit6=0x40) already
// reach comp_pipeline as c_blend / c_flags, so no new RTL port is required for
// those — only the tint colour extraction above.
//
// INTEGRATION NOTE: pre-B the pipeline ignores COLORMOD, so the source is written
// un-tinted and these checks FAIL — expected until B's RTL lands.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
module tb_blitter_colormod_pipe;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h10000;  // [#52] tracks SRC_QW heap base
  localparam [15:0] BG = 16'h8410, SRCP = 16'hFFFF, FILLC = 16'hAD55;
  // tint colour (8-bit per channel)
  localparam [7:0]  CR = 8'd128, CG = 8'd64, CB = 8'd255;
  localparam [7:0]  ALPHA = 8'd128;
  // ARGB4444 source for the PALPHA case: A=0x8, R=0xF, G=0x3, B=0xC
  localparam [15:0] PSRC = 16'h8F3C;

  reg clk=0, rst=1; always #5 clk=~clk;
  wire [31:0] bt_addr; wire b_rd, b_we; wire [63:0] b_din; wire [7:0] b_be; wire bt_idle;
  reg  d_dready; reg [63:0] d_dout;
  reg [63:0] mem [0:MEMQW-1];
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat; reg [1:0] bp=0;
  always @(posedge clk) bp <= bp+2'd1;
  wire d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  integer i;

  localparam P_SRC_LAT = 3;
  localparam [28:0] SRC_WIN = `SRC_QW - WBASE;
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

  // ── reference golden helpers (mirror blt_tint565 / blt_blend565 / blt_blend4444) ─
  function [15:0] ref_tint(input [15:0] s, input [7:0] cr, input [7:0] cg, input [7:0] cb);
    integer sr,sg,sb,tr,tg,tb,orr,ogg,obb;
    begin
      sr=s[15:11]; sg=s[10:5]; sb=s[4:0];
      tr=sr*cr; orr=(tr+128+((tr+128)>>8))>>8;
      tg=sg*cg; ogg=(tg+128+((tg+128)>>8))>>8;
      tb=sb*cb; obb=(tb+128+((tb+128)>>8))>>8;
      ref_tint={orr[4:0],ogg[5:0],obb[4:0]};
    end
  endfunction
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
  // PALPHA with colour-mod: expand ARGB4444, tint the RGB channels, src-over.
  function [15:0] ref_palpha_mod(input [15:0] s16, input [15:0] d16,
                                 input [7:0] cr, input [7:0] cg, input [7:0] cb);
    integer a4,r4,g4,b4,a8,na,sr,sg,sb,dr,dg,db,tr,tg,tb,mr,mg,mb,orr,ogg,obb;
    begin
      a4=s16[15:12]; r4=s16[11:8]; g4=s16[7:4]; b4=s16[3:0];
      if (a4==0) ref_palpha_mod=d16;
      else begin
        a8=(a4<<4)|a4; na=255-a8;
        sr=(r4<<1)|(r4>>3); sg=(g4<<2)|(g4>>2); sb=(b4<<1)|(b4>>3);
        // tint expanded channels
        mr=sr*cr; sr=(mr+128+((mr+128)>>8))>>8;
        mg=sg*cg; sg=(mg+128+((mg+128)>>8))>>8;
        mb=sb*cb; sb=(mb+128+((mb+128)>>8))>>8;
        dr=d16[15:11]; dg=d16[10:5]; db=d16[4:0];
        tr=sr*a8+dr*na; orr=(tr+128+((tr+128)>>8))>>8;
        tg=sg*a8+dg*na; ogg=(tg+128+((tg+128)>>8))>>8;
        tb=sb*a8+db*na; obb=(tb+128+((tb+128)>>8))>>8;
        ref_palpha_mod={orr[4:0],ogg[5:0],obb[4:0]};
      end
    end
  endfunction

  localparam [7:0] FLG_CM = 8'h40;   // BLT_F_COLORMOD

  integer errs=0;
  initial begin
    for(i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    // seed the on-chip FB with BG (CLEAR no longer reaches comp_fbram post-cutover).
    for(i=0;i<`FB_QWORDS;i=i+1) begin
      fbram.bank0[i]=BG; fbram.bank1[i]=BG; fbram.bank2[i]=BG; fbram.bank3[i]=BG; end
    mem[32'h200007]=64'd2;  // C_PIPE
    mem[32'h200000]=64'd1; mem[32'h200001]=64'd5; mem[32'h200002]=64'd0;
    mem[32'h200003]={48'd0,BG}; mem[32'h200004]=64'd0; mem[32'h200005]=64'd0;  // no CLEAR: FB pre-seeded BG (Phase 0a)

    // cmd0 COLORMOD+COPY BLIT: blend=0, flags=0x40, src@0, w=1 h=1, dst=(30,30)
    mem[32'h200008]={32'd0, FLG_CM,8'd0,8'd0,8'd3};   // op=BLIT flags=CM blend=COPY
    mem[32'h200009]={16'd1,16'd1,16'd0,16'd2};         // h=1 w=1 stride=2
    mem[32'h20000A]={16'd30,16'd30, 32'd0};            // dst=(30,30)
    mem[32'h20000B]={CG, CR, 16'd0, 8'(CB), 8'd0, 16'd0}; // cg@[63:56] cr@[55:48] color cb@[31:24]

    // cmd1 COLORMOD+CONST_ALPHA BLIT: blend=2, flags=0x40, alpha, dst=(40,40)
    mem[32'h20000C]={32'h0000_0008, FLG_CM,8'd0,8'd2,8'd3}; // src_off=8B, blend=ALPHA
    mem[32'h20000D]={16'd1,16'd1,16'd0,16'd2};
    mem[32'h20000E]={16'd40,16'd40, 32'd0};
    mem[32'h20000F]={CG, CR, 16'd0, 8'(CB), ALPHA, 16'd0}; // cg cr color cb alpha@[23:16]

    // cmd2 COLORMOD+PALPHA BLIT (ARGB4444): blend=3, fmt=1, flags=0x40, dst=(50,50)
    mem[32'h200010]={32'h0000_0010, FLG_CM,8'd1,8'd3,8'd3}; // src_off=16B fmt=ARGB4444 blend=PALPHA
    mem[32'h200011]={16'd1,16'd1,16'd0,16'd2};
    mem[32'h200012]={16'd50,16'd50, 32'd0};
    mem[32'h200013]={CG, CR, 16'd0, 8'(CB), 8'd0, 16'd0};

    // cmd3 COLORMOD+COPY FILL: blend=0, flags=0x40, color=FILLC, dst=(60,60)
    mem[32'h200014]={32'd0, FLG_CM,8'd0,8'd0,8'd2};   // op=FILL flags=CM
    mem[32'h200015]={16'd1,16'd1,16'd0,16'd0};
    mem[32'h200016]={16'd60,16'd60, 32'd0};
    mem[32'h200017]={CG, CR, FILLC, 8'(CB), 8'd0, 16'd0}; // cg cr color@[47:32] cb@[31:24]

    mem[32'h200018]=64'd1;                             // cmd4 END

    // sources @ SRC heap:
    mem[(SRC_WIN + 29'h00)][15:0] = SRCP;   // byte 0  -> COPY source (RGB565 white)
    mem[(SRC_WIN + 29'h00)][79:64]= 16'd0;  // (placeholder)
    mem[(SRC_WIN + 29'h01)][15:0] = SRCP;   // byte 8  -> CONST_ALPHA source
    mem[(SRC_WIN + 29'h02)][15:0] = PSRC;   // byte 16 -> PALPHA source (ARGB4444)
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
    ckpix(30,30, ref_tint(SRCP, CR,CG,CB),                       "cm-copy-blit");
    ckpix(40,40, ref_blend(ref_tint(SRCP,CR,CG,CB), BG, ALPHA),  "cm-alpha-blit");
    ckpix(50,50, ref_palpha_mod(PSRC, BG, CR,CG,CB),             "cm-palpha-blit");
    ckpix(60,60, ref_tint(FILLC, CR,CG,CB),                      "cm-copy-fill");
    if (mem[32'h200005][31:0]==mem[32'h200000][31:0] && errs==0) $display("RESULT: PASS");
    else $display("RESULT: FAIL (errs=%0d)", errs);
    $finish;
  end
  initial begin #80000000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
