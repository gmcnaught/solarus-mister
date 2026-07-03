// tb_tilelist_res.sv — BIT-EXACT equivalence gate for BLT_OP_TILELIST_RES (#52 Tier B,
// resident pattern-indexed tile list).
//
// Proves the fabric TILELIST_RES FSM (blitter_top.sv) renders a frame IDENTICALLY to the
// same frame expressed as the N expanded per-tile BLITs with the RESOLVED rects. For each
// case we:
//   A) submit  CLEAR + FRT_UPLOAD + one TILELIST_RES (8-byte pid+dst entries in TL_BUF),
//      capture comp_fbram;
//   B) submit  CLEAR + the N expanded BLITs (rect = FRT[pid][CFT[pid]], same dst), capture;
//   C) assert  framebuffer A == framebuffer B, pixel for pixel.
// The resolution (pattern_id -> CFT[pid] -> FRT[pid*MAXF+f] -> src rect) happens INSIDE the
// fabric for A and is reproduced by the testbench for B; any divergence (wrong table index,
// dropped entry, bad cull) shows as a pixel mismatch.
//
// Memory model mirrors tb_tilelist: a windowed behavioral DDR `mem` (ctrl/ring/source-heap)
// plus small arrays serving the high TL_BUF / FRT / CFT regions the fabric reads.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
module tb_tilelist_res;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h8000;
  localparam [28:0] SRC_WIN = `SRC_QW - WBASE;
  localparam [31:0] RINGB   = 32'h200008;
  localparam        TL_SPAN  = 29'h1000;     // tlmem depth (qwords)
  localparam        FRT_SPAN = MAXP*MAXF;    // 1024 qwords
  localparam        CFT_SPAN = MAXP/4;       // 32 qwords (4 u16 per qword)

  reg clk=0, rst=1; always #5 clk=~clk;

  reg vs=0; integer vsc=0;
  always @(posedge clk) begin
    vsc <= vsc + 1;
    if (vsc >= 256) begin vs <= ~vs; vsc <= 0; end
  end

  wire [31:0] bt_addr; wire b_rd, b_we; wire [63:0] b_din; wire [7:0] b_be; wire bt_idle;
  wire [7:0]  bt_burst;
  reg  d_dready; reg [63:0] d_dout;

  reg [63:0] mem    [0:MEMQW-1];
  reg [63:0] tlmem  [0:TL_SPAN-1];
  reg [63:0] frtmem [0:FRT_SPAN-1];          // FRT region (FRT_BUF_QW)
  reg [63:0] cftmem [0:CFT_SPAN-1];          // CFT region (CFT_BUF_QW)
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat; reg [1:0] bp=0;
  always @(posedge clk) bp <= bp+2'd1;
  wire d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  integer i;

  // P_SRC cache-ok source model: serves the source heap from `mem`.
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

  // DDR read/write engine; TL_BUF / FRT / CFT reads come from their dedicated arrays.
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
          else if (raddr >= `FRT_BUF_QW && raddr < (`FRT_BUF_QW + FRT_SPAN))
            d_dout <= frtmem[raddr - `FRT_BUF_QW];
          else if (raddr >= `CFT_BUF_QW && raddr < (`CFT_BUF_QW + CFT_SPAN))
            d_dout <= cftmem[raddr - `CFT_BUF_QW];
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

  // tileset source: 64x64, stride 128B, src_off 0.
  localparam integer TW=64, TH=64, TSTRIDE=128;
  function [15:0] pat(input integer sx, input integer sy);
    pat = (sx*73 + sy*151 + 'h9E37) & 16'hFFFF;
  endfunction
  task seed_tileset;
    integer sx, sy, bo;
    begin
      for (sy=0; sy<TH; sy=sy+1) for (sx=0; sx<TW; sx=sx+1) begin
        bo = sy*TSTRIDE + sx*2;
        mem[SRC_WIN + (bo>>3)][(bo&7)*8 +: 16] = pat(sx,sy);
      end
    end
  endtask

  // ── frame-rect table (host-side model of FRT) ──
  // frt_sx/sy/w/h[pid*MAXF+f]. seeded per pattern; written into frtmem (qword each).
  integer frt_sx [0:MAXP*MAXF-1], frt_sy [0:MAXP*MAXF-1];
  integer frt_w  [0:MAXP*MAXF-1], frt_h  [0:MAXP*MAXF-1];
  integer cur_f  [0:MAXP-1];                 // CFT: current frame per pattern
  task tables_clear;
    integer k;
    begin
      for (k=0;k<MAXP*MAXF;k=k+1) begin frt_sx[k]=0; frt_sy[k]=0; frt_w[k]=0; frt_h[k]=0; end
      for (k=0;k<MAXP;k=k+1) cur_f[k]=0;
    end
  endtask
  // push the host tables into the DDR FRT/CFT regions the fabric uploads/preloads.
  task tables_to_ddr;
    integer k, q, lane;
    begin
      for (k=0;k<MAXP*MAXF;k=k+1)
        frtmem[k] = { frt_h[k][15:0], frt_w[k][15:0], frt_sy[k][15:0], frt_sx[k][15:0] };
      for (q=0;q<CFT_SPAN;q=q+1) cftmem[q]=64'd0;
      for (k=0;k<MAXP;k=k+1) begin
        q = k/4; lane = k%4;
        cftmem[q][lane*16 +: 16] = cur_f[k][15:0];
      end
    end
  endtask
  // resolve one entry's src rect (pid -> cur_f[pid] -> frt[pid*MAXF+f]).
  function [15:0] rsv_sx(input integer pid); rsv_sx = frt_sx[pid*MAXF + cur_f[pid]][15:0]; endfunction
  function [15:0] rsv_sy(input integer pid); rsv_sy = frt_sy[pid*MAXF + cur_f[pid]][15:0]; endfunction
  function [15:0] rsv_w (input integer pid); rsv_w  = frt_w [pid*MAXF + cur_f[pid]][15:0]; endfunction
  function [15:0] rsv_h (input integer pid); rsv_h  = frt_h [pid*MAXF + cur_f[pid]][15:0]; endfunction

  // ── resident entries (8 bytes each): pid, dst_x, dst_y, _rsvd ──
  localparam integer MAXN=64;
  integer NN;
  integer ent_pid [0:MAXN-1], ent_dx [0:MAXN-1], ent_dy [0:MAXN-1];

  task tl_put16(input integer byteoff, input [15:0] v);
    begin tlmem[byteoff>>3][(byteoff&7)*8 +: 16] = v; end
  endtask
  task tl_load_res(input integer eoff);     // 8-byte aligned entry array
    integer k, b;
    begin
      for (k=0; k<NN; k=k+1) begin
        b = eoff + k*8;
        tl_put16(b+0, ent_pid[k][15:0]);
        tl_put16(b+2, ent_dx [k][15:0]);
        tl_put16(b+4, ent_dy [k][15:0]);
        tl_put16(b+6, 16'd0);
      end
    end
  endtask

  integer submit_n=0;
  task set_ctrl(input integer ncmds);
    begin
      mem[32'h200001]=ncmds; mem[32'h200002]=64'd0; mem[32'h200003]=64'd0;
      mem[32'h200004]=64'd1; mem[32'h200007]=64'd2;
    end
  endtask

  // A: FRT_UPLOAD (slot0) + TILELIST_RES (slot1) + END (slot2)
  // [#52 camera-independent bias] bias_x/bias_y are a signed per-batch dst bias
  // (map-coord -> screen), carried in the header's src_x/src_y slots (the
  // otherwise-informational tileset-bounds fields for this opcode) -- same ABI
  // as the host emitter (tl_emit_header, Task 1, commit 871776d). The fabric
  // (Task 3) adds them to every resolved entry's dst in S_TLR_SLICE.
  task wr_resident(input [7:0] blend, input [7:0] fmt, input [7:0] flags,
                   input [15:0] stride, input signed [15:0] bias_x,
                   input signed [15:0] bias_y, input [31:0] eoff);
    begin
      // FRT_UPLOAD: op=7, u32[3]=w|h<<16 = MAXP*MAXF qwords.
      mem[RINGB+0] = {32'd0, {8'd0, 8'd0, 8'd0, 8'd7}};
      mem[RINGB+1] = {32'(MAXP*MAXF), 32'd0};            // u32[3]=count ; u32[2]=0
      mem[RINGB+2] = 64'd0;
      mem[RINGB+3] = 64'd0;
      // TILELIST_RES header (op=6), same packing as TILELIST except src_x/src_y
      // carry the signed dst bias instead of tileset w/h (unused by the RES path).
      mem[RINGB+4] = {32'd0, {flags, fmt, blend, 8'd6}};
      mem[RINGB+5] = {NN[31:0], {bias_x, stride}};
      mem[RINGB+6] = {eoff, {16'd0, bias_y}};
      mem[RINGB+7] = 64'd0;                              // alpha/colorkey unused (always 0 here)
      mem[RINGB+8] = 64'd1;                              // END
    end
  endtask

  // B: NN expanded BLITs (resolved rect, dst shifted by the same bias) + END
  task wr_blits(input [7:0] blend, input [7:0] fmt, input [7:0] flags,
                input [15:0] stride, input signed [15:0] bias_x,
                input signed [15:0] bias_y);
    integer k; integer base; integer dxb, dyb;
    begin
      for (k=0; k<NN; k=k+1) begin
        base = RINGB + k*4;
        dxb = ent_dx[k] + bias_x;
        dyb = ent_dy[k] + bias_y;
        mem[base+0] = {32'd0, {flags, fmt, blend, 8'd3}};
        mem[base+1] = {rsv_h(ent_pid[k]), rsv_w(ent_pid[k]),
                       rsv_sx(ent_pid[k]), stride};
        mem[base+2] = {dyb[15:0], dxb[15:0], 16'd0, rsv_sy(ent_pid[k])};
        mem[base+3] = 64'd0;                              // alpha/colorkey unused (always 0 here)
      end
      mem[RINGB + NN*4] = 64'd1;
    end
  endtask

  integer to;
  task run_submit;
    begin
      submit_n = submit_n + 1; mem[32'h200000] = submit_n; to=0;
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

  // bias_x/bias_y: signed per-batch dst bias (map-coord -> screen); 0,0 for the
  // legacy (no-bias) cases. See wr_resident/wr_blits for the ABI.
  task run_case(input [127:0] name, input [7:0] blend, input [7:0] fmt, input [7:0] flags,
                input signed [15:0] bias_x, input signed [15:0] bias_y, input [31:0] eoff);
    begin
      case_errs = 0;
      tables_to_ddr;
      tl_load_res(eoff);
      set_ctrl(3);                                   // FRT_UPLOAD + TILELIST_RES + END
      wr_resident(blend, fmt, flags, 16'(TSTRIDE), bias_x, bias_y, eoff);
      run_submit; capture_a;
      set_ctrl(NN+1);
      wr_blits(blend, fmt, flags, 16'(TSTRIDE), bias_x, bias_y);
      run_submit;
      for (yy=0;yy<240;yy=yy+1) for (xx=0;xx<320;xx=xx+1)
        if (getpx(xx,yy) !== fb_a[yy*320+xx]) begin
          if (case_errs < 6)
            $display("  MISMATCH %0s (%0d,%0d): res=%h nblit=%h",
                     name, xx, yy, fb_a[yy*320+xx], getpx(xx,yy));
          case_errs = case_errs + 1;
        end
      if (case_errs==0) $display("  %0s (N=%0d): PASS", name, NN);
      else              $display("  %0s (N=%0d): FAIL (%0d mismatches)", name, NN, case_errs);
      errs = errs + case_errs;
    end
  endtask

  // Same A/B comparison as run_case, but WITHOUT tables_to_ddr/tl_load_res --
  // the caller has already written TL_BUF entries (and any CFT update) and is
  // reusing them as-is. Used by Case 7 to prove a moving/animating resident
  // batch needs only a header {bias, CFT} update, no entry rebuild.
  task run_case_noload(input [127:0] name, input [7:0] blend, input [7:0] fmt, input [7:0] flags,
                       input signed [15:0] bias_x, input signed [15:0] bias_y, input [31:0] eoff);
    begin
      case_errs = 0;
      set_ctrl(3);                                   // FRT_UPLOAD + TILELIST_RES + END
      wr_resident(blend, fmt, flags, 16'(TSTRIDE), bias_x, bias_y, eoff);
      run_submit; capture_a;
      set_ctrl(NN+1);
      wr_blits(blend, fmt, flags, 16'(TSTRIDE), bias_x, bias_y);
      run_submit;
      for (yy=0;yy<240;yy=yy+1) for (xx=0;xx<320;xx=xx+1)
        if (getpx(xx,yy) !== fb_a[yy*320+xx]) begin
          if (case_errs < 6)
            $display("  MISMATCH %0s (%0d,%0d): res=%h nblit=%h",
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
    for(i=0;i<MEMQW;i=i+1)    mem[i]=64'd0;
    for(i=0;i<TL_SPAN;i=i+1)  tlmem[i]=64'd0;
    for(i=0;i<FRT_SPAN;i=i+1) frtmem[i]=64'd0;
    for(i=0;i<CFT_SPAN;i=i+1) cftmem[i]=64'd0;
    mem[32'h200000]=64'd0; mem[32'h200005]=64'd0;
    seed_tileset;
    tables_clear;
    // pattern 0: 3 frames (8x8); pattern 1: 2 frames (16x16); pattern 2: 4 frames (8x8).
    frt_sx[0*MAXF+0]=0;  frt_sy[0*MAXF+0]=0;  frt_w[0*MAXF+0]=8;  frt_h[0*MAXF+0]=8;
    frt_sx[0*MAXF+1]=8;  frt_sy[0*MAXF+1]=0;  frt_w[0*MAXF+1]=8;  frt_h[0*MAXF+1]=8;
    frt_sx[0*MAXF+2]=16; frt_sy[0*MAXF+2]=0;  frt_w[0*MAXF+2]=8;  frt_h[0*MAXF+2]=8;
    frt_sx[1*MAXF+0]=0;  frt_sy[1*MAXF+0]=8;  frt_w[1*MAXF+0]=16; frt_h[1*MAXF+0]=16;
    frt_sx[1*MAXF+1]=16; frt_sy[1*MAXF+1]=8;  frt_w[1*MAXF+1]=16; frt_h[1*MAXF+1]=16;
    frt_sx[2*MAXF+0]=0;  frt_sy[2*MAXF+0]=32; frt_w[2*MAXF+0]=8;  frt_h[2*MAXF+0]=8;
    frt_sx[2*MAXF+1]=8;  frt_sy[2*MAXF+1]=32; frt_w[2*MAXF+1]=8;  frt_h[2*MAXF+1]=8;
    frt_sx[2*MAXF+2]=16; frt_sy[2*MAXF+2]=32; frt_w[2*MAXF+2]=8;  frt_h[2*MAXF+2]=8;
    frt_sx[2*MAXF+3]=24; frt_sy[2*MAXF+3]=32; frt_w[2*MAXF+3]=8;  frt_h[2*MAXF+3]=8;

    repeat(8) @(posedge clk); rst<=0;
    repeat(4) @(posedge clk);

    // Case 1: N=1, pattern 0 at frame 2, COPY.
    cur_f[0]=2; cur_f[1]=0; cur_f[2]=0;
    NN=1; ent_pid[0]=0; ent_dx[0]=10; ent_dy[0]=10;
    run_case("R1_COPY", 8'd0, 8'd0, 8'd0, 16'd0, 16'd0, 32'd0);

    // Case 2: N=6, mixed patterns, overlap + negative-x partial + right-edge + fully
    // offscreen (cull), COPY. eoff=16 (8-aligned).
    cur_f[0]=1; cur_f[1]=1; cur_f[2]=3;
    NN=6;
    ent_pid[0]=0; ent_dx[0]=10;  ent_dy[0]=10;
    ent_pid[1]=2; ent_dx[1]=14;  ent_dy[1]=12;   // overlaps [0]
    ent_pid[2]=1; ent_dx[2]=30;  ent_dy[2]=30;
    ent_pid[3]=0; ent_dx[3]=-4;  ent_dy[3]=50;   // x<0 partial
    ent_pid[4]=2; ent_dx[4]=315; ent_dy[4]=200;  // right-edge partial
    ent_pid[5]=1; ent_dx[5]=400; ent_dy[5]=300;  // fully offscreen (cull)
    run_case("R6_MIX_CLIP", 8'd0, 8'd0, 8'd0, 16'd0, 16'd0, 32'd16);

    // Case 3: PALPHA over ARGB4444 (per-pixel alpha incl. A4==0 skip).
    cur_f[0]=0; cur_f[1]=0; cur_f[2]=2;
    NN=4;
    ent_pid[0]=1; ent_dx[0]=20; ent_dy[0]=20;
    ent_pid[1]=1; ent_dx[1]=26; ent_dy[1]=24;    // overlaps [0]
    ent_pid[2]=0; ent_dx[2]=40; ent_dy[2]=40;
    ent_pid[3]=2; ent_dx[3]=-3; ent_dy[3]=60;    // partial
    run_case("R_PALPHA", 8'd3, 8'd1, 8'd0, 16'd0, 16'd0, 32'd0);

    // Case 4: N=24 small tiles tiled across the screen, COPY, eoff=8 (8-aligned).
    cur_f[0]=2; cur_f[1]=0; cur_f[2]=1;
    NN=24;
    for (k=0;k<24;k=k+1) begin
      ent_pid[k]=(k%3); ent_dx[k]=(k%12)*16; ent_dy[k]=(k/12)*16 + 80;
    end
    run_case("R24_SPAN", 8'd0, 8'd0, 8'd0, 16'd0, 16'd0, 32'd8);

    // Case 5: reuse Case 2's entities, signed per-batch dst bias (+7,-9). Proves
    // the header bias (Task 1 ABI) is applied to every resolved entry's dst by
    // the fabric (Task 3) -- same cull/clip/overlap coverage as Case 2, shifted.
    cur_f[0]=1; cur_f[1]=1; cur_f[2]=3;
    NN=6;
    ent_pid[0]=0; ent_dx[0]=10;  ent_dy[0]=10;
    ent_pid[1]=2; ent_dx[1]=14;  ent_dy[1]=12;   // overlaps [0]
    ent_pid[2]=1; ent_dx[2]=30;  ent_dy[2]=30;
    ent_pid[3]=0; ent_dx[3]=-4;  ent_dy[3]=50;   // x<0 partial
    ent_pid[4]=2; ent_dx[4]=315; ent_dy[4]=200;  // right-edge partial
    ent_pid[5]=1; ent_dx[5]=400; ent_dy[5]=300;  // fully offscreen (cull)
    run_case("R5_BIAS", 8'd0, 8'd0, 8'd0, 16'sd7, -16'sd9, 32'd16);

    // Case 6: whole-map cull. NN=64 entries spread across map-space: 12 land
    // inside the 320x240 screen under bias=(-500,-300) (a large camera pan),
    // the other 52 are placed far outside the viewport (some at large positive
    // map coords, some at large negative map coords) so they land fully
    // off-screen after the same bias and must be culled by the fabric's
    // per-entry clip (empty -> zero writes, S_TL_ISSUE) with no reference
    // contribution. eoff=512 (8-aligned, past all prior cases' entry spans).
    cur_f[0]=1; cur_f[1]=1; cur_f[2]=2;
    NN=64;
    for (k=0;k<12;k=k+1) begin
      ent_pid[k] = k % 3;
      ent_dx[k]  = 500 + (k%4)*40;      // -> 0,40,80,120 on-screen after bias
      ent_dy[k]  = 300 + (k/4)*40;      // -> 0,40,80     on-screen after bias
    end
    for (k=12;k<64;k=k+1) begin
      ent_pid[k] = k % 3;
      if (k[0]) begin                   // odd k: far positive map coord
        ent_dx[k] = 4000 + k*3;
        ent_dy[k] = 4000 + k*3;
      end else begin                    // even k: far negative map coord
        ent_dx[k] = -4000 - k*3;
        ent_dy[k] = -4000 - k*3;
      end
    end
    run_case("R6_CULL", 8'd0, 8'd0, 8'd0, -16'sd500, -16'sd300, 32'd512);

    // Case 7: the movement proof. NN=12 entries written ONCE to TL_BUF (eoff
    // fixed at 2048, well clear of every other case's span) at map-space
    // positions. (a) render with bias=(0,0), cur_f=f0: verifies the baseline
    // resolve. (b) WITHOUT touching TL_BUF again -- same eoff, same entries --
    // pan the camera to bias=(-16,-8) and advance every pattern's cur_f to
    // f0+1 (re-uploaded via tables_to_ddr, which only rewrites the FRT/CFT DDR
    // regions, never tlmem), then re-issue the SAME TILELIST_RES header with
    // just the new bias. The per-render reference (wr_blits) recomputes
    // map_dst+bias against the then-current cur_f, so each render is checked
    // against its own honest expectation.
    cur_f[0]=0; cur_f[1]=0; cur_f[2]=0;               // f0: valid for all 3 patterns
    NN=12;
    for (k=0;k<12;k=k+1) begin
      ent_pid[k] = k % 3;
      ent_dx[k]  = 60  + (k%4)*30;
      ent_dy[k]  = 60  + (k/4)*30;
    end
    tables_to_ddr;
    tl_load_res(32'd2048);                            // write entries ONCE
    run_case_noload("R7_PAN_ADVANCE_a", 8'd0, 8'd0, 8'd0, 16'd0, 16'd0, 32'd2048);

    cur_f[0]=1; cur_f[1]=1; cur_f[2]=1;               // f0+1: advance the anim tick
    tables_to_ddr;                                    // CFT/FRT only -- tlmem untouched
    run_case_noload("R7_PAN_ADVANCE_b", 8'd0, 8'd0, 8'd0, -16'sd16, -16'sd8, 32'd2048);

    if (errs==0) $display("TB_TILELIST_RES: PASS");
    else         $display("TB_TILELIST_RES: FAIL (%0d total mismatches)", errs);
    $finish;
  end

  initial begin #800000000 $display("TB_TILELIST_RES: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire
