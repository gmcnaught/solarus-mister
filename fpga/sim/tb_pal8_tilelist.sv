// tb_pal8_tilelist.sv — PAL8 × BLT_OP_TILELIST gate (issue #84 tile-path fix).
//
// Proves the fabric renders a PAL8 (8bpp palette-indexed) tile-list IDENTICALLY to
// the same frame expressed as N expanded per-tile PAL8 BLITs — i.e. the TILELIST
// header's latched c_format=COMP_PAL8 and c_color(=pal_id/base_off) apply to every
// entry through comp_pipeline's index→CLUT decode, exactly as they do for a single
// BLIT (which tb_pal8_fill_8bpp / tb_pal8_lookup already prove correct).
//
// This is the sim gate for the host change that makes map tilesets render paletted
// via BLT_OP_TILELIST: if the fabric already carries format+pal_id per TILELIST
// entry, this PASSES with NO RTL change (host-only fix); if the TILELIST path drops
// format/pal_id, path A renders 16bpp-misdecoded garbage ≠ path B → FAIL, localizing
// the fabric gap.
//
// Structure = tb_tilelist.sv's A(TILELIST)==B(N-BLITs) equivalence scaffold, plus:
//   * a CLUTBUF DDR window + BLT_OP_CLUT_UPLOAD submit (from tb_pal8_fill_8bpp.sv),
//   * an 8bpp INDEX tileset source (1 B/px, stride=TW),
//   * a non-zero pal_id (bank 5) packed into the header/blit color field,
//   * a golden spot-check (composited pixel == CLUT[pal_id*256 + base + index]) so a
//     both-paths-render-garbage case can't false-PASS the pure equivalence.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
`include "comp_clut.vh"
`include "comp_defs.vh"
module tb_pal8_tilelist;
  localparam integer NENT = `CLUT_BANKS * `CLUT_ENTRIES;   // 32*256 = 8192
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h8000;   // ctrl/ring/source-heap window
  localparam [28:0] SRC_WIN = `SRC_QW - WBASE;                     // source-heap window base
  localparam [31:0] RINGB   = 32'h200008;                         // ring slot0 (window idx)
  localparam        TL_SPAN = 29'h1000;                           // tlmem depth (qwords)

  // PAL8 params: bank 5 (proves header pal_id bank-select), base_off 0.
  localparam integer PAL_ID = 5;
  localparam integer PAL_BASE = 0;
  // color field wire packing (blt_pal_color): {pal_id[4:0]<<8 | base_off[7:0]}.
  localparam [15:0] PAL_COLOR = (PAL_ID << 8) | PAL_BASE;

  reg clk=0, rst=1; always #5 clk=~clk;

  reg vs=0; integer vsc=0;
  always @(posedge clk) begin
    vsc <= vsc + 1;
    if (vsc >= 256) begin vs <= ~vs; vsc <= 0; end
  end

  wire [31:0] bt_addr; wire b_rd, b_we; wire [63:0] b_din; wire [7:0] b_be; wire bt_idle;
  wire [7:0]  bt_burst;
  reg  d_dready; reg [63:0] d_dout;

  // ---- behavioral DDR (single-beat reads, latency + backpressure) ----
  reg [63:0] mem      [0:MEMQW-1];
  reg [63:0] tlmem    [0:TL_SPAN-1];         // TILELIST entry buffer (TL_BUF_QW region)
  reg [63:0] clut_mem [0:NENT-1];            // CLUTBUF region (BLT_OP_CLUT_UPLOAD source)
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat; reg [1:0] bp=0;
  always @(posedge clk) bp <= bp+2'd1;
  wire d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  integer i;

  // ---- P_SRC cache-ok source model: serves the source heap from `mem` ----
  localparam P_SRC_LAT = 3;
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

  // on-chip dest framebuffer [FB-in-BRAM]
  wire fb_wr_en; wire [14:0] fb_wr_qw; wire [1:0] fb_wr_lane; wire [15:0] fb_wr_pix;
  wire fb_rd_en; wire [14:0] fb_rd_qw; wire [63:0] fb_rd_qword;
  comp_fbram fbram(.clk(clk),
    .wr_en(fb_wr_en), .wr_qw(fb_wr_qw), .wr_lane(fb_wr_lane), .wr_pix(fb_wr_pix),
    .rd_en(fb_rd_en), .rd_qw(fb_rd_qw), .rd_qword(fb_rd_qword));

  blitter_top blt(.clk(clk), .rst(rst), .vs(vs),
    .mem_addr(bt_addr), .mem_rd(b_rd), .mem_wr(b_we), .mem_burstcnt(bt_burst),
    .mem_din(b_din), .mem_be(b_be),
    .mem_dout(d_dout), .mem_dout_ready(d_dready), .mem_busy(d_busy),
    .p0_addr(s_src_addr), .p0_rd(s_src_rd), .p0_dout(s_src_dout), .p0_ok(s_src_ok),
    .src_sdram_ok(1'b1), .stage_barrier_busy(1'b0),
    .fb_wr_en(fb_wr_en), .fb_wr_qw(fb_wr_qw), .fb_wr_lane(fb_wr_lane), .fb_wr_pix(fb_wr_pix),
    .fb_rd_en(fb_rd_en), .fb_rd_qw(fb_rd_qw), .fb_rd_qword(fb_rd_qword),
    .idle(bt_idle));

  // DDR read/write engine; TL_BUF_QW reads served from tlmem, CLUT_BUF_QW from clut_mem.
  always @(posedge clk) begin
    d_dready <= 1'b0;
    d_dout   <= 64'hDEAD_BEEF_DEAD_BEEF;
    if (rst) begin rbeats<=0; rlat<=0; end
    else begin
      if (rlat != 3'd0) rlat <= rlat - 3'd1;
      else if (rbeats != 8'd0) begin
        if (bp == 2'd2) begin
          if (raddr >= `TL_BUF_QW && raddr < (`TL_BUF_QW + TL_SPAN))
            d_dout <= tlmem[raddr - `TL_BUF_QW];
          else if (raddr >= `CLUT_BUF_QW && raddr < (`CLUT_BUF_QW + NENT))
            d_dout <= clut_mem[raddr - `CLUT_BUF_QW];
          else
            d_dout <= mem[raddr-WBASE];
          d_dready <= 1'b1; raddr <= raddr + 29'd1; rbeats <= rbeats - 8'd1;
        end
      end else if (!d_busy) begin
        if (b_rd) begin rbeats<=bt_burst; raddr<=bt_addr[28:0]; rlat<=3'd3; end
        else if (b_we) for(i=0;i<8;i=i+1) if(b_be[i]) mem[(bt_addr[28:0]-WBASE)][i*8 +:8]<=b_din[i*8 +:8];
      end
    end
  end

  // ── 8bpp INDEX tileset source: 64x64, stride = TW bytes (1 B/px), src_off 0.
  localparam integer TW=64, TH=64, PAL_TSTRIDE=TW;   // 1 B/px
  function [7:0] idx_at(input integer sx, input integer sy);
    idx_at = (sx*7 + sy*13) & 8'hFF;                 // varied index in 0..255 (base_off=0)
  endfunction
  task seed_tileset;
    integer sx, sy, bo;
    begin
      for (sy=0; sy<TH; sy=sy+1) for (sx=0; sx<TW; sx=sx+1) begin
        bo = sy*PAL_TSTRIDE + sx;                     // 1 B/px source byte offset
        mem[SRC_WIN + (bo>>3)][(bo&7)*8 +: 8] = idx_at(sx,sy);
      end
    end
  endtask

  // ── CLUT: global entry g = bank*256+slot decodes to {A4=F, RGB565 = g[15:0]}.
  // So a PAL8 pixel with index i, bank PAL_ID, base_off b decodes to RGB565 =
  // (PAL_ID*256 + b + i) & 0xFFFF — a deterministic golden the spot-check uses.
  function [15:0] clut_decode(input integer g);
    clut_decode = g[15:0];
  endfunction
  task seed_clut;
    integer g;
    begin
      for (g=0; g<NENT; g=g+1)
        clut_mem[g] = {32'd0, `CLUT_MAKE(4'hF, clut_decode(g))};
    end
  endtask

  // ── entry table ──
  localparam integer MAXN=64;
  integer NN;
  integer ent_sx [0:MAXN-1], ent_sy [0:MAXN-1];
  integer ent_w  [0:MAXN-1], ent_h  [0:MAXN-1];
  integer ent_dx [0:MAXN-1], ent_dy [0:MAXN-1];

  task tl_put16(input integer byteoff, input [15:0] v);
    begin tlmem[byteoff>>3][(byteoff&7)*8 +: 16] = v; end
  endtask
  task tl_load(input integer eoff);
    integer k, b;
    begin
      for (k=0; k<NN; k=k+1) begin
        b = eoff + k*12;
        tl_put16(b+0,  ent_sx[k][15:0]);
        tl_put16(b+2,  ent_sy[k][15:0]);
        tl_put16(b+4,  ent_w [k][15:0]);
        tl_put16(b+6,  ent_h [k][15:0]);
        tl_put16(b+8,  ent_dx[k][15:0]);
        tl_put16(b+10, ent_dy[k][15:0]);
      end
    end
  endtask

  integer submit_n=0;

  task set_ctrl(input integer ncmds);
    begin
      mem[32'h200001]=ncmds;
      mem[32'h200002]=64'd0;        // target_buf=0
      mem[32'h200003]=64'd0;        // clear_color=0
      mem[32'h200004]=64'd1;        // flags: CLEAR
      mem[32'h200007]=64'd2;        // C_PIPE (no-op)
    end
  endtask

  // TILELIST header at ring slot 0 + END; color field carries pal_id/base_off.
  task wr_tilelist(input [7:0] blend, input [7:0] fmt, input [7:0] flags,
                   input [15:0] stride, input [15:0] alpha, input [15:0] ck,
                   input [15:0] color, input [31:0] eoff,
                   input signed [15:0] bias_x, input signed [15:0] bias_y);
    begin
      mem[RINGB+0] = {32'd0, {flags, fmt, blend, 8'd5}};            // op=TILELIST, src_off=0
      mem[RINGB+1] = {NN[31:0], {bias_x, stride}};
      mem[RINGB+2] = {eoff, {16'd0, bias_y}};
      mem[RINGB+3] = {{16'd0, color}, {8'd0, alpha[7:0], ck}};      // u32[7][15:0]=color (c_color)
      mem[RINGB+4] = 64'd1;                                         // END
    end
  endtask

  // NN expanded PAL8 BLITs + END; each carries the same color (pal_id/base_off).
  task wr_blits(input [7:0] blend, input [7:0] fmt, input [7:0] flags,
                input [15:0] stride, input [15:0] alpha, input [15:0] ck,
                input [15:0] color, input signed [15:0] bias_x, input signed [15:0] bias_y);
    integer k; integer base;
    begin
      for (k=0; k<NN; k=k+1) begin
        base = RINGB + k*4;
        mem[base+0] = {32'd0, {flags, fmt, blend, 8'd3}};          // op=BLIT, src_off=0
        mem[base+1] = {ent_h[k][15:0], ent_w[k][15:0], ent_sx[k][15:0], stride};
        mem[base+2] = {(ent_dy[k][15:0]+bias_y), (ent_dx[k][15:0]+bias_x), 16'd0, ent_sy[k][15:0]};
        mem[base+3] = {{16'd0, color}, {8'd0, alpha[7:0], ck}};
      end
      mem[RINGB + NN*4] = 64'd1;                                    // END
    end
  endtask

  integer to;
  task run_submit;
    begin
      submit_n = submit_n + 1;
      mem[32'h200000] = submit_n;
      to=0;
      while (mem[32'h200005][31:0] !== submit_n[31:0] && to<8000000) begin @(posedge clk); to=to+1; end
      if (mem[32'h200005][31:0] !== submit_n[31:0]) $display("  WEDGE: submit %0d never acked (to=%0d)", submit_n, to);
      repeat(4) @(posedge clk);
    end
  endtask

  function [15:0] getpx(input integer dx, input integer dy);
    integer idx;
    begin
      idx = dy*80 + (dx>>2);
      getpx = ((dx&3)==0)?fbram.bank0[idx]:((dx&3)==1)?fbram.bank1[idx]:
              ((dx&3)==2)?fbram.bank2[idx]:fbram.bank3[idx];
    end
  endfunction

  reg [15:0] fb_a [0:76799];
  integer errs=0, case_errs;
  integer xx, yy;

  task capture_a;
    begin for (yy=0;yy<240;yy=yy+1) for (xx=0;xx<320;xx=xx+1) fb_a[yy*320+xx]=getpx(xx,yy); end
  endtask

  // expected composited RGB565 for the top-left entry's pixel at source (sx,sy),
  // COPY/opaque: CLUT[PAL_ID*256 + PAL_BASE + idx_at(sx,sy)].
  function [15:0] golden_px(input integer sx, input integer sy);
    golden_px = clut_decode(PAL_ID*256 + PAL_BASE + idx_at(sx,sy));
  endfunction

  task run_case(input [127:0] name, input [7:0] blend, input [7:0] flags,
                input [31:0] eoff);
    begin
      case_errs = 0;
      // A: PAL8 TILELIST
      tl_load(eoff);
      set_ctrl(2);
      wr_tilelist(blend, `COMP_PAL8, flags, 16'(PAL_TSTRIDE), 16'd0, 16'd0, PAL_COLOR, eoff, 16'sd0, 16'sd0);
      run_submit;
      capture_a;
      // B: NN expanded PAL8 BLITs
      set_ctrl(NN+1);
      wr_blits(blend, `COMP_PAL8, flags, 16'(PAL_TSTRIDE), 16'd0, 16'd0, PAL_COLOR, 16'sd0, 16'sd0);
      run_submit;
      // compare A==B (equivalence)
      for (yy=0;yy<240;yy=yy+1) for (xx=0;xx<320;xx=xx+1)
        if (getpx(xx,yy) !== fb_a[yy*320+xx]) begin
          if (case_errs < 6)
            $display("  MISMATCH %0s (%0d,%0d): tilelist=%h nblit=%h",
                     name, xx, yy, fb_a[yy*320+xx], getpx(xx,yy));
          case_errs = case_errs + 1;
        end
      if (case_errs==0) $display("  %0s (N=%0d): equivalence PASS", name, NN);
      else              $display("  %0s (N=%0d): equivalence FAIL (%0d mismatches)", name, NN, case_errs);
      errs = errs + case_errs;
    end
  endtask

  integer k, gerr;
  reg [15:0] got, exp;
  initial begin
    for(i=0;i<MEMQW;i=i+1)   mem[i]=64'd0;
    for(i=0;i<TL_SPAN;i=i+1) tlmem[i]=64'd0;
    mem[32'h200000]=64'd0; mem[32'h200005]=64'd0;
    seed_tileset;
    seed_clut;

    repeat(8) @(posedge clk); rst<=0;
    repeat(4) @(posedge clk);

    // ---- submit 0: BLT_OP_CLUT_UPLOAD (load clut_mem -> fabric clut_bram) ----
    mem[32'h200001]=64'd2;                 // cmd_count = CLUT_UPLOAD + END
    mem[32'h200002]=64'd0; mem[32'h200003]=64'd0; mem[32'h200004]=64'd0; mem[32'h200007]=64'd0;
    // BLT_OP_CLUT_UPLOAD: w|h<<16 = qword count = NENT; src_off field = CLUTBUF byte off.
    mem[RINGB+0] = {32'd0, {8'd0, 8'd0, 8'd0, 8'(`BLT_OP_CLUT_UPLOAD)}};
    mem[RINGB+1] = {NENT[31:0], 32'd0};    // u32[3]=count-low ; NENT<65536 so high=0
    mem[RINGB+2] = 64'd0;
    mem[RINGB+3] = 64'd0;
    mem[RINGB+4] = 64'd1;                  // END
    run_submit;

    // Case 1: N=1 PAL8 COPY — plus golden spot-check (real decode, not both-garbage).
    NN=1;
    ent_sx[0]=4;  ent_sy[0]=4;  ent_w[0]=8;  ent_h[0]=8;  ent_dx[0]=10; ent_dy[0]=10;
    run_case("PAL8_N1_COPY", 8'd0, 8'd0, 32'd0);
    // golden: dst (10..17,10..17) maps to source (4..11,4..11).
    gerr = 0;
    for (yy=0; yy<8; yy=yy+1) for (xx=0; xx<8; xx=xx+1) begin
      got = getpx(10+xx, 10+yy);
      exp = golden_px(4+xx, 4+yy);
      if (got !== exp) begin
        if (gerr < 6) $display("  GOLDEN MISMATCH (%0d,%0d): got=%h exp=%h", 10+xx, 10+yy, got, exp);
        gerr = gerr + 1;
      end
    end
    if (gerr==0) $display("  PAL8_N1_COPY: golden CLUT-decode PASS (bank %0d)", PAL_ID);
    else       begin $display("  PAL8_N1_COPY: golden FAIL (%0d mismatches)", gerr); errs = errs + gerr; end

    // Case 2: N=6 overlapping/clipped PAL8 COPY (draw order, partials, cull) — equivalence only.
    NN=6;
    ent_sx[0]=0;  ent_sy[0]=0;  ent_w[0]=8;  ent_h[0]=8;  ent_dx[0]=10; ent_dy[0]=10;
    ent_sx[1]=8;  ent_sy[1]=0;  ent_w[1]=8;  ent_h[1]=8;  ent_dx[1]=14; ent_dy[1]=12;
    ent_sx[2]=0;  ent_sy[2]=8;  ent_w[2]=16; ent_h[2]=16; ent_dx[2]=30; ent_dy[2]=30;
    ent_sx[3]=16; ent_sy[3]=16; ent_w[3]=8;  ent_h[3]=8;  ent_dx[3]=-4; ent_dy[3]=50;
    ent_sx[4]=0;  ent_sy[4]=0;  ent_w[4]=8;  ent_h[4]=8;  ent_dx[4]=315;ent_dy[4]=200;
    ent_sx[5]=0;  ent_sy[5]=0;  ent_w[5]=8;  ent_h[5]=8;  ent_dx[5]=400;ent_dy[5]=300;
    run_case("PAL8_N6_OVL_CLIP", 8'd0, 8'd0, 32'd4);

    // Case 3: N=20 tiled span, non-8-aligned entry offset (eoff=6) — equivalence.
    NN=20;
    for (k=0;k<20;k=k+1) begin
      ent_sx[k]=(k%8); ent_sy[k]=(k%5); ent_w[k]=10; ent_h[k]=10;
      ent_dx[k]=(k%10)*16; ent_dy[k]=(k/10)*16 + 80;
    end
    run_case("PAL8_N20_SPAN", 8'd0, 8'd0, 32'd6);

    if (errs==0) $display("TB_PAL8_TILELIST: PASS");
    else         $display("TB_PAL8_TILELIST: FAIL (%0d total mismatches)", errs);
    $finish;
  end

  initial begin #800000000 $display("TB_PAL8_TILELIST: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire
