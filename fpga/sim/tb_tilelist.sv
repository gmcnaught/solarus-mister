// tb_tilelist.sv — BIT-EXACT equivalence gate for BLT_OP_TILELIST (#52 dumb emitter).
//
// Proves the fabric TILELIST FSM (blitter_top.sv) renders a frame IDENTICALLY to the
// same frame expressed as the N expanded per-tile BLITs. For each case we:
//   A) submit  CLEAR + one TILELIST (header + N entries in the TL buffer), capture comp_fbram;
//   B) submit  CLEAR + the N expanded BLITs (same shared params + per-entry rects), capture;
//   C) assert  framebuffer A == framebuffer B, pixel for pixel.
// The comparison is the gate: TILELIST and its N-BLIT expansion go through the SAME
// comp_pipeline issue path, so any FSM divergence (wrong entry decode, miscounted N,
// dropped/duplicated entry, bad cull) shows up as a pixel mismatch.
//
// Memory model (windowed, mirrors tb_blitter_copy_pipe):
//   * command ring + control block + source heap live in behavioral DDR `mem`
//     (FSM bm_* master, and the P_SRC cache-ok model serves the source heap).
//   * the 12-byte TILELIST entries live in `tlmem`, a small array the DDR model
//     serves whenever the FSM reads the TL_BUF_QW region (0x3BF40000) — this is the
//     same physical region the host writes; keeping it separate avoids a 32 MB `mem`.
//
// Cases: N=1; N=5 overlapping dst + partial-offscreen + fully-offscreen (cull);
//        PALPHA over ARGB4444 (per-pixel alpha incl. A4==0 skip); N=20 spanning many
//        source fetches with a non-8-aligned entry-array offset (3-qword entry window);
//        [static tile-list] N=3 with a non-zero header dst bias (map-coord entries +
//        per-batch bias, mirroring BLT_OP_TILELIST_RES) incl. a post-bias partial clip.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
module tb_tilelist;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h8000;   // ctrl/ring/source-heap window
  localparam [28:0] SRC_WIN = `SRC_QW - WBASE;                     // source-heap window base
  localparam [31:0] RINGB   = 32'h200008;                         // ring slot0 (window idx)
  localparam        TL_SPAN = 29'h1000;                           // tlmem depth (qwords)

  reg clk=0, rst=1; always #5 clk=~clk;

  // ---- vblank: free-running so the per-frame work->scan snapshot (S_SNAP_*) drains
  // and the FSM returns to poll for the next submit. (Rises every ~512 cycles.) ----
  reg vs=0; integer vsc=0;
  always @(posedge clk) begin
    vsc <= vsc + 1;
    if (vsc >= 256) begin vs <= ~vs; vsc <= 0; end
  end

  wire [31:0] bt_addr; wire b_rd, b_we; wire [63:0] b_din; wire [7:0] b_be; wire bt_idle;
  wire [7:0]  bt_burst;
  reg  d_dready; reg [63:0] d_dout;

  // ---- behavioral DDR (single-beat reads, latency + backpressure) ----
  reg [63:0] mem   [0:MEMQW-1];
  reg [63:0] tlmem [0:TL_SPAN-1];           // TILELIST entry buffer (TL_BUF_QW region)
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

  // DDR read/write engine; TL_BUF_QW reads are served from tlmem.
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

  // ── tileset source: 64x64, stride 128 B, src_off 0. Varied 16-bit pattern so the
  //    top nibble (ARGB4444 A4) spans 0 (skip) and non-zero for the PALPHA case. ──
  localparam integer TW=64, TH=64, TSTRIDE=128;
  function [15:0] pat(input integer sx, input integer sy);
    pat = (sx*73 + sy*151 + 'h9E37) & 16'hFFFF;
  endfunction
  task seed_tileset;
    integer sx, sy, bo;
    begin
      for (sy=0; sy<TH; sy=sy+1) for (sx=0; sx<TW; sx=sx+1) begin
        bo = sy*TSTRIDE + sx*2;                       // source byte offset
        mem[SRC_WIN + (bo>>3)][(bo&7)*8 +: 16] = pat(sx,sy);
      end
    end
  endtask

  // ── entry table (driven into both the TL buffer and the expanded BLITs) ──
  localparam integer MAXN=64;
  integer NN;
  integer ent_sx [0:MAXN-1], ent_sy [0:MAXN-1];
  integer ent_w  [0:MAXN-1], ent_h  [0:MAXN-1];
  integer ent_dx [0:MAXN-1], ent_dy [0:MAXN-1];

  // write one little-endian 16-bit field into the byte-addressed tlmem
  task tl_put16(input integer byteoff, input [15:0] v);
    begin tlmem[byteoff>>3][(byteoff&7)*8 +: 16] = v; end
  endtask
  // pack the NN entries (12 bytes each) into tlmem starting at byte offset `eoff`
  task tl_load(input integer eoff);
    integer k, b;
    begin
      for (k=0; k<NN; k=k+1) begin
        b = eoff + k*12;
        tl_put16(b+0,  ent_sx[k][15:0]);
        tl_put16(b+2,  ent_sy[k][15:0]);
        tl_put16(b+4,  ent_w [k][15:0]);
        tl_put16(b+6,  ent_h [k][15:0]);
        tl_put16(b+8,  ent_dx[k][15:0]);   // i16 (two's complement bits)
        tl_put16(b+10, ent_dy[k][15:0]);
      end
    end
  endtask

  // shared header/blit params
  integer submit_n=0;

  task set_ctrl(input integer ncmds);
    begin
      mem[32'h200001]=ncmds;        // cmd_count
      mem[32'h200002]=64'd0;        // target_buf=0 (BUF0)
      mem[32'h200003]=64'd0;        // clear_color=0
      mem[32'h200004]=64'd1;        // flags: bit0=CLEAR (wipe comp_fbram before the list)
      mem[32'h200007]=64'd2;        // C_PIPE (no-op; throttle=0)
    end
  endtask

  // write the TILELIST header at ring slot 0 + END at slot 1.
  // [static tile-list] bias_x/bias_y (default 0) occupy the same header slots the
  // fabric now reads as the per-batch dst bias (c_src_x/c_src_y) — mirroring
  // BLT_OP_TILELIST_RES's wr_tilelist_res convention. (These slots previously carried
  // the TW/TH texture dims, which the FSM never read for this op; dead value, safe
  // to repurpose.)
  task wr_tilelist(input [7:0] blend, input [7:0] fmt, input [7:0] flags,
                   input [15:0] stride, input [15:0] alpha, input [15:0] ck,
                   input [31:0] eoff,
                   input signed [15:0] bias_x = 16'sd0, input signed [15:0] bias_y = 16'sd0);
    begin
      mem[RINGB+0] = {32'd0, {flags, fmt, blend, 8'd5}};            // op=TILELIST, src_off=0
      mem[RINGB+1] = {NN[31:0], {bias_x, stride}};                  // u32[3]=N ; u32[2]=stride|bias_x<<16
      mem[RINGB+2] = {eoff, {16'd0, bias_y}};                       // u32[5]=eoff ; u32[4]=bias_y
      mem[RINGB+3] = {32'd0, {8'd0, alpha[7:0], ck}};               // u32[6]=ck|alpha<<16
      mem[RINGB+4] = 64'd1;                                         // END
    end
  endtask

  // write the NN expanded BLITs at ring slots 0..NN-1 + END at slot NN. bias_x/bias_y
  // (default 0) are added to each entry's dst here so the expansion mirrors what the
  // TILELIST FSM now applies from its header bias.
  task wr_blits(input [7:0] blend, input [7:0] fmt, input [7:0] flags,
                input [15:0] stride, input [15:0] alpha, input [15:0] ck,
                input signed [15:0] bias_x = 16'sd0, input signed [15:0] bias_y = 16'sd0);
    integer k; integer base;
    begin
      for (k=0; k<NN; k=k+1) begin
        base = RINGB + k*4;
        mem[base+0] = {32'd0, {flags, fmt, blend, 8'd3}};          // op=BLIT, src_off=0
        mem[base+1] = {ent_h[k][15:0], ent_w[k][15:0], ent_sx[k][15:0], stride};
        mem[base+2] = {(ent_dy[k][15:0]+bias_y), (ent_dx[k][15:0]+bias_x), 16'd0, ent_sy[k][15:0]};
        mem[base+3] = {32'd0, {8'd0, alpha[7:0], ck}};
      end
      mem[RINGB + NN*4] = 64'd1;                                    // END
    end
  endtask

  // bump submit and wait for the frame's done handshake
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

  // read a composited pixel from comp_fbram
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

  // run one case end-to-end and compare TILELIST vs N-BLITs. bias_x/bias_y (default 0)
  // exercise the header per-batch dst bias: applied by the FSM in path A (via the
  // TILELIST header), and folded into path B's expanded-BLIT dsts here so both paths
  // render the same final composite.
  task run_case(input [127:0] name, input [7:0] blend, input [7:0] fmt, input [7:0] flags,
                input [15:0] alpha, input [15:0] ck, input [31:0] eoff,
                input signed [15:0] bias_x = 16'sd0, input signed [15:0] bias_y = 16'sd0);
    begin
      case_errs = 0;
      // A: TILELIST
      tl_load(eoff);
      set_ctrl(2);                                   // header + END
      wr_tilelist(blend, fmt, flags, 16'(TSTRIDE), alpha, ck, eoff, bias_x, bias_y);
      run_submit;
      capture_a;
      // B: N expanded BLITs
      set_ctrl(NN+1);                                // N BLITs + END
      wr_blits(blend, fmt, flags, 16'(TSTRIDE), alpha, ck, bias_x, bias_y);
      run_submit;
      // compare
      for (yy=0;yy<240;yy=yy+1) for (xx=0;xx<320;xx=xx+1)
        if (getpx(xx,yy) !== fb_a[yy*320+xx]) begin
          if (case_errs < 6)
            $display("  MISMATCH %0s (%0d,%0d): tilelist=%h nblit=%h",
                     name, xx, yy, fb_a[yy*320+xx], getpx(xx,yy));
          case_errs = case_errs + 1;
        end
      if (case_errs==0) $display("  %0s (N=%0d): PASS", name, NN);
      else              $display("  %0s (N=%0d): FAIL (%0d mismatches)", name, NN, case_errs);
      errs = errs + case_errs;
    end
  endtask

  integer k;
  initial begin
    for(i=0;i<MEMQW;i=i+1)   mem[i]=64'd0;
    for(i=0;i<TL_SPAN;i=i+1) tlmem[i]=64'd0;
    mem[32'h200000]=64'd0; mem[32'h200005]=64'd0;     // submit=done=0
    seed_tileset;

    repeat(8) @(posedge clk); rst<=0;
    repeat(4) @(posedge clk);

    // Case 1: N=1, plain COPY (RGB565).
    NN=1;
    ent_sx[0]=4;  ent_sy[0]=4;  ent_w[0]=8;  ent_h[0]=8;  ent_dx[0]=10; ent_dy[0]=10;
    run_case("N1_COPY", 8'd0, 8'd0, 8'd0, 16'd0, 16'd0, 32'd0);

    // Case 2: N=6, overlapping dst (draw order), a NEGATIVE-x partial, a right-edge
    // partial, and a FULLY-offscreen entry (cull == no writes), COPY (RGB565).
    NN=6;
    ent_sx[0]=0;  ent_sy[0]=0;  ent_w[0]=8;  ent_h[0]=8;  ent_dx[0]=10; ent_dy[0]=10;
    ent_sx[1]=8;  ent_sy[1]=0;  ent_w[1]=8;  ent_h[1]=8;  ent_dx[1]=14; ent_dy[1]=12; // overlaps [0]
    ent_sx[2]=0;  ent_sy[2]=8;  ent_w[2]=16; ent_h[2]=16; ent_dx[2]=30; ent_dy[2]=30;
    ent_sx[3]=16; ent_sy[3]=16; ent_w[3]=8;  ent_h[3]=8;  ent_dx[3]=-4; ent_dy[3]=50; // x<0 partial
    ent_sx[4]=0;  ent_sy[4]=0;  ent_w[4]=8;  ent_h[4]=8;  ent_dx[4]=315;ent_dy[4]=200;// right-edge partial
    ent_sx[5]=0;  ent_sy[5]=0;  ent_w[5]=8;  ent_h[5]=8;  ent_dx[5]=400;ent_dy[5]=300;// fully offscreen (cull)
    run_case("N6_OVL_CLIP", 8'd0, 8'd0, 8'd0, 16'd0, 16'd0, 32'd4); // eoff=4 -> bitoff alternates 32/0

    // Case 3: PALPHA over ARGB4444 (per-pixel alpha; A4==0 pixels skip-write).
    NN=4;
    ent_sx[0]=2;  ent_sy[0]=2;  ent_w[0]=12; ent_h[0]=12; ent_dx[0]=20; ent_dy[0]=20;
    ent_sx[1]=10; ent_sy[1]=5;  ent_w[1]=12; ent_h[1]=12; ent_dx[1]=26; ent_dy[1]=24; // overlaps [0]
    ent_sx[2]=0;  ent_sy[2]=20; ent_w[2]=16; ent_h[2]=10; ent_dx[2]=40; ent_dy[2]=40;
    ent_sx[3]=20; ent_sy[3]=20; ent_w[3]=10; ent_h[3]=10; ent_dx[3]=-3; ent_dy[3]=60; // partial
    run_case("PALPHA_4444", 8'd3, 8'd1, 8'd0, 16'd0, 16'd0, 32'd0);

    // Case 4: N=20 small tiles tiled across the screen, COPY, with a NON-8-ALIGNED
    // entry-array offset (eoff=6) so the 3-qword entry window + bitoff path is
    // stressed across many entries and source fetches.
    NN=20;
    for (k=0;k<20;k=k+1) begin
      ent_sx[k]=(k%8); ent_sy[k]=(k%5); ent_w[k]=10; ent_h[k]=10;
      ent_dx[k]=(k%10)*16; ent_dy[k]=(k/10)*16 + 80;
    end
    run_case("N20_SPAN", 8'd0, 8'd0, 8'd0, 16'd0, 16'd0, 32'd6);

    // Case 5: [static tile-list] header dst bias (bias_x=-4, bias_y=+3). Entries carry
    // MAP-coord dsts; the FSM must add the header bias to land each at the same screen
    // dst as path B's pre-biased expanded BLITs (wr_blits folds the same bias in).
    // Proves BLT_OP_TILELIST is now bit-exact-with-bias to BLT_OP_TILELIST_RES's
    // convention. COPY, N=3 incl. one dst that only clips on-screen once biased.
    NN=3;
    ent_sx[0]=0; ent_sy[0]=0; ent_w[0]=8;  ent_h[0]=8;  ent_dx[0]=100; ent_dy[0]=100;
    ent_sx[1]=4; ent_sy[1]=4; ent_w[1]=16; ent_h[1]=16; ent_dx[1]=200; ent_dy[1]=150;
    ent_sx[2]=0; ent_sy[2]=0; ent_w[2]=8;  ent_h[2]=8;  ent_dx[2]=3;   ent_dy[2]=5;   // biased dst (-1,8): x<0 partial
    run_case("N3_BIAS", 8'd0, 8'd0, 8'd0, 16'd0, 16'd0, 32'd0, -16'sd4, 16'sd3);

    if (errs==0) $display("TB_TILELIST: PASS");
    else         $display("TB_TILELIST: FAIL (%0d total mismatches)", errs);
    $finish;
  end

  initial begin #800000000 $display("TB_TILELIST: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire
