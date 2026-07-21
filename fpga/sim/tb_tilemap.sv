// tb_tilemap.sv — BIT-EXACT equivalence gate for BLT_OP_TILEMAP (Stage 3b Phase B2,
// the grid-walk FSM). Golden model: blt_ref_tilemap (blitter_ref.c).
//
// Proves the fabric grid-walk FSM (blitter_top.sv: S_GRID_SETUP/FETCH/DECODE/SLICE/
// WAIT, sharing the S_TLR_CFT/S_TLR_FRT pattern-resolve and the comp_pipeline
// pipe_start/p_blit_done handshake) renders a frame IDENTICALLY to the same frame
// expressed as the expanded per-run OP_BLITs the walk must produce. For each scenario:
//   A) submit CLEAR + BLT_OP_FRT_UPLOAD + one BLT_OP_TILEMAP (grid cells in GRID_BUF),
//      recording every comp_pipeline issue transaction and capturing comp_fbram;
//   B) submit CLEAR + the hand-built expanded per-run OP_BLITs, recording the same;
//   C) assert the two ISSUE TRANSACTION SEQUENCES are identical field-for-field
//      (c_src_off, c_src_x/y, c_w/c_h, c_dst_x/y, c_color) AND the two framebuffers
//      are identical pixel-for-pixel — exactly tb_spritelist's Path-A-vs-Path-B gate.
//
// The transaction compare is the primary, order-sensitive gate (a reordered/dropped/
// duplicated run fails even if pixels coincide); the pixel compare is the backstop
// that proves those transactions actually composited.
//
// CFT residency: the golden resolves src via FRT[pid][CFT[pid]], the SAME per-pattern
// tables OP_TILELIST_RES uses. A header-only BLT_OP_TILEMAP (blt_grid_list) does NOT
// carry a CFT preload — the fabric grid-walk assumes the current-frame table (cft_mem)
// is already RESIDENT (loaded by a prior command in a real frame; static tile layers
// resolve to frame 0). This TB models that residency by presetting the DUT's cft_mem
// directly (preset_cft), while FRT is loaded through the real BLT_OP_FRT_UPLOAD path.
//
// Memory model (windowed, mirrors tb_tilelist_res / tb_spritelist):
//   * command ring + control block + source heap live in behavioral DDR `mem`
//     (FSM bm_* master; the P_SRC cache-ok model serves the source heap).
//   * the 32-bit grid cells live in `gridmem`, served whenever the FSM reads the
//     `GRID_BUF_QW region — the same physical region the host writes. Two cells/qword.
//   * `frtmem` serves the FRT region for the one BLT_OP_FRT_UPLOAD.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
module tb_tilemap;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h8000;   // ctrl/ring/source-heap window
  localparam [28:0] SRC_WIN = `SRC_QW - WBASE;                     // source-heap window base
  localparam [31:0] RINGB   = 32'h200008;                          // ring slot0 (window idx)
  localparam        GRID_SPAN = 29'h1000;    // gridmem depth (qwords)
  localparam        FRT_SPAN  = MAXP*MAXF;   // 2048 qwords

  reg clk=0, rst=1; always #5 clk=~clk;

  // free-running vblank so the per-frame work->scan snapshot drains
  reg vs=0; integer vsc=0;
  always @(posedge clk) begin
    vsc <= vsc + 1;
    if (vsc >= 256) begin vs <= ~vs; vsc <= 0; end
  end

  wire [31:0] bt_addr; wire b_rd, b_we; wire [63:0] b_din; wire [7:0] b_be; wire bt_idle;
  wire [7:0]  bt_burst;
  reg  d_dready; reg [63:0] d_dout;

  // ---- behavioral DDR (single-beat reads, latency + backpressure) ----
  reg [63:0] mem     [0:MEMQW-1];
  reg [63:0] gridmem [0:GRID_SPAN-1];        // grid-cell array (GRID_BUF_QW region)
  reg [63:0] frtmem  [0:FRT_SPAN-1];         // FRT region (FRT_BUF_QW)
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

  // DDR read/write engine; GRID_BUF reads from gridmem, FRT reads from frtmem.
  always @(posedge clk) begin
    d_dready <= 1'b0;
    d_dout   <= 64'hDEAD_BEEF_DEAD_BEEF;
    if (rst) begin rbeats<=0; rlat<=0; end
    else begin
      if (rlat != 3'd0) rlat <= rlat - 3'd1;
      else if (rbeats != 8'd0) begin
        if (bp == 2'd2) begin
          if (raddr >= `GRID_BUF_QW && raddr < (`GRID_BUF_QW + GRID_SPAN))
            d_dout <= gridmem[raddr - `GRID_BUF_QW];
          else if (raddr >= `FRT_BUF_QW && raddr < (`FRT_BUF_QW + FRT_SPAN))
            d_dout <= frtmem[raddr - `FRT_BUF_QW];
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

  // ── comp_pipeline ISSUE-TRANSACTION recorder ────────────────────────────────
  // Every pipe_start pulse is one issue. The CLEAR-before-list pass also pulses
  // pipe_start, but with c_opcode==OP_FILL(2) (the S_CLR_FILL setup); filtering that
  // out leaves exactly the per-run grid issues (c_opcode==OP_TILEMAP, 11) for Path A
  // and the per-blit issues (c_opcode==OP_BLIT, 3) for Path B — which must agree.
  localparam integer MAXT = 256;
  reg [31:0] t_soff [0:MAXT-1];  reg [15:0] t_sx [0:MAXT-1];  reg [15:0] t_sy [0:MAXT-1];
  reg [15:0] t_w    [0:MAXT-1];  reg [15:0] t_h  [0:MAXT-1];  reg [15:0] t_col[0:MAXT-1];
  reg [15:0] t_dx   [0:MAXT-1];  reg [15:0] t_dy [0:MAXT-1];
  reg [31:0] tn;                                   // transactions recorded this run
  // snapshot of run A
  reg [31:0] a_soff [0:MAXT-1];  reg [15:0] a_sx [0:MAXT-1];  reg [15:0] a_sy [0:MAXT-1];
  reg [15:0] a_w    [0:MAXT-1];  reg [15:0] a_h  [0:MAXT-1];  reg [15:0] a_col[0:MAXT-1];
  reg [15:0] a_dx   [0:MAXT-1];  reg [15:0] a_dy [0:MAXT-1];
  reg [31:0] an;

  always @(posedge clk) begin
    if (blt.pipe_start && blt.c_opcode != 8'd2) begin
      if (tn < MAXT) begin
        t_soff[tn] <= blt.c_src_off; t_sx[tn] <= blt.c_src_x; t_sy[tn] <= blt.c_src_y;
        t_w   [tn] <= blt.c_w;       t_h [tn] <= blt.c_h;
        t_dx  [tn] <= blt.c_dst_x;   t_dy[tn] <= blt.c_dst_y;
        t_col [tn] <= blt.c_color;
      end
      tn <= tn + 32'd1;
    end
  end

  // ── tileset source: 64x64, stride 128B, src_off 0 ───────────────────────────
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
  // Layout matches S_TLR_SLICE's frt_q decode: {h,w,sy,sx} (LE).
  integer frt_sx [0:MAXP*MAXF-1], frt_sy [0:MAXP*MAXF-1];
  integer frt_w  [0:MAXP*MAXF-1], frt_h  [0:MAXP*MAXF-1];
  integer cur_f  [0:MAXP-1];                 // CFT: current frame per pattern (all 0 = static)
  task tables_clear;
    integer k;
    begin
      for (k=0;k<MAXP*MAXF;k=k+1) begin frt_sx[k]=0; frt_sy[k]=0; frt_w[k]=0; frt_h[k]=0; end
      for (k=0;k<MAXP;k=k+1) cur_f[k]=0;
    end
  endtask
  task frt_to_ddr;
    integer k;
    begin
      for (k=0;k<MAXP*MAXF;k=k+1)
        frtmem[k] = { frt_h[k][15:0], frt_w[k][15:0], frt_sy[k][15:0], frt_sx[k][15:0] };
    end
  endtask
  // CFT residency: preset the DUT's cft_mem directly (see the CFT residency note in
  // the header) — the header-only OP_TILEMAP carries no CFT preload, so the walk
  // assumes it is already resident. cft_mem is not touched by the fabric reset nor by
  // a TILEMAP-only frame, so a one-time preset survives.
  task preset_cft;
    integer k;
    begin
      for (k=0;k<MAXP;k=k+1) blt.cft_mem[k] = cur_f[k][15:0];
    end
  endtask
  // resolve one pattern's src rect (pid -> cur_f[pid] -> frt[pid*MAXF+f]).
  function [15:0] rsv_sx(input integer pid); rsv_sx = frt_sx[pid*MAXF + cur_f[pid]][15:0]; endfunction
  function [15:0] rsv_sy(input integer pid); rsv_sy = frt_sy[pid*MAXF + cur_f[pid]][15:0]; endfunction

  // ── grid cells (32-bit each, two per qword) ──────────────────────────────────
  // pack per grid_cell.h: pid[11:0] | sub_x[15:12] | sub_y[19:16] | run_m1[23:20].
  function [31:0] gcell(input integer pid, input integer sub_x,
                        input integer sub_y, input integer run_m1);
    gcell = (pid[11:0]) | (sub_x[3:0] << 12) | (sub_y[3:0] << 16) | (run_m1[3:0] << 20);
  endfunction
  task grid_clear;
    integer q;
    begin for (q=0;q<GRID_SPAN;q=q+1) gridmem[q]=64'd0; end
  endtask
  // write one 32-bit cell at byte offset `boff` within GRID_BUF (4-aligned).
  task grid_put(input integer boff, input [31:0] v);
    begin gridmem[boff>>3][(boff&7)*8 +: 32] = v; end
  endtask

  // ── expected Path-B blits (final resolved rects, post-bias) ──────────────────
  localparam integer MAXB=64;
  integer NB;
  integer b_soff [0:MAXB-1];
  integer b_sx   [0:MAXB-1], b_sy [0:MAXB-1];
  integer b_w    [0:MAXB-1], b_h  [0:MAXB-1];
  integer b_dx   [0:MAXB-1], b_dy [0:MAXB-1];
  reg [15:0] b_col[0:MAXB-1];

  integer submit_n=0;
  task set_ctrl(input integer ncmds);
    begin
      mem[32'h200001]=ncmds;
      mem[32'h200002]=64'd0;        // target_buf=0 (BUF0)
      mem[32'h200003]=64'd0;        // clear_color=0
      mem[32'h200004]=64'd1;        // flags: bit0=CLEAR
      mem[32'h200007]=64'd2;        // C_PIPE (no-op; throttle=0)
    end
  endtask

  // A: FRT_UPLOAD (slot0) + TILEMAP (slot1) + END (slot2).
  // TILEMAP header reuses the 32-byte command layout but OVERLOADS:
  //   w|h<<16          = grid_w | grid_h<<16  (grid dims IN CELLS)
  //   dst_x|dst_y<<16  = cells_off (byte offset of the cell array in GRID_BUF)
  //   src_x/src_y      = signed per-batch dst bias
  //   src_off/stride   = shared tileset base
  task wr_tilemap(input [7:0] blend, input [7:0] fmt, input [7:0] flags,
                  input [15:0] stride, input [15:0] alpha, input [15:0] ck,
                  input [15:0] color,
                  input [31:0] src_off, input [31:0] cells_off,
                  input [15:0] grid_w, input [15:0] grid_h,
                  input signed [15:0] bias_x, input signed [15:0] bias_y);
    begin
      // FRT_UPLOAD: op=7, u32[3]=w|h<<16 = MAXP*MAXF qwords.
      mem[RINGB+0] = {32'd0, {8'd0, 8'd0, 8'd0, 8'd7}};
      mem[RINGB+1] = {32'(MAXP*MAXF), 32'd0};
      mem[RINGB+2] = 64'd0;
      mem[RINGB+3] = 64'd0;
      // TILEMAP header (op=11).
      mem[RINGB+4] = {src_off, {flags, fmt, blend, 8'd11}};
      mem[RINGB+5] = {grid_h, grid_w, bias_x, stride};       // u32[3]=h|w ; u32[2]=src_x|stride
      mem[RINGB+6] = {cells_off, {16'd0, bias_y}};           // u32[5]=cells_off ; u32[4]=src_y
      mem[RINGB+7] = {{16'd0, color}, {8'd0, alpha[7:0], ck}};
      mem[RINGB+8] = 64'd1;                                  // END
    end
  endtask

  // B: NB expanded OP_BLITs (final resolved rect + absolute dst) + END.
  task wr_blits(input [7:0] blend, input [7:0] fmt, input [7:0] flags, input [15:0] stride,
                input [15:0] alpha, input [15:0] ck);
    integer k, base;
    begin
      for (k=0; k<NB; k=k+1) begin
        base = RINGB + k*4;
        mem[base+0] = {b_soff[k][31:0], {flags, fmt, blend, 8'd3}};
        mem[base+1] = {b_h[k][15:0], b_w[k][15:0], b_sx[k][15:0], stride};
        mem[base+2] = {b_dy[k][15:0], b_dx[k][15:0], 16'd0, b_sy[k][15:0]};
        mem[base+3] = {{16'd0, b_col[k]}, {8'd0, alpha[7:0], ck}};
      end
      mem[RINGB + NB*4] = 64'd1;                             // END
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
  integer errs=0, case_errs, tx_errs;
  integer xx, yy, tt;

  task capture_a;
    begin for (yy=0;yy<240;yy=yy+1) for (xx=0;xx<320;xx=xx+1) fb_a[yy*320+xx]=getpx(xx,yy); end
  endtask

  // A-vs-B equivalence: transaction sequence (order-sensitive) + framebuffer pixels.
  task run_case(input [199:0] name, input [7:0] blend, input [7:0] fmt, input [7:0] flags,
                input [15:0] stride, input [15:0] alpha, input [15:0] ck, input [15:0] color,
                input [31:0] src_off, input [31:0] cells_off,
                input [15:0] grid_w, input [15:0] grid_h,
                input signed [15:0] bias_x, input signed [15:0] bias_y);
    begin
      case_errs = 0; tx_errs = 0;
      // ---- A: one TILEMAP ----
      frt_to_ddr;
      preset_cft;
      set_ctrl(3);                                   // FRT_UPLOAD + TILEMAP + END
      wr_tilemap(blend, fmt, flags, stride, alpha, ck, color, src_off, cells_off,
                 grid_w, grid_h, bias_x, bias_y);
      tn = 32'd0;
      run_submit;
      an = tn;
      for (tt=0; tt<MAXT; tt=tt+1) begin
        a_soff[tt]=t_soff[tt]; a_sx[tt]=t_sx[tt]; a_sy[tt]=t_sy[tt];
        a_w   [tt]=t_w   [tt]; a_h [tt]=t_h [tt];
        a_dx  [tt]=t_dx  [tt]; a_dy[tt]=t_dy[tt]; a_col[tt]=t_col[tt];
      end
      capture_a;
      // ---- B: NB expanded BLITs ----
      set_ctrl(NB+1);                                // NB BLITs + END
      wr_blits(blend, fmt, flags, stride, alpha, ck);
      tn = 32'd0;
      run_submit;
      // ---- C1: issue-transaction sequence equality (order-sensitive) ----
      if (an !== tn) begin
        $display("  TX-COUNT %0s: tilemap=%0d nblit=%0d", name, an, tn);
        tx_errs = tx_errs + 1;
      end
      for (tt=0; tt<((an<tn)?an:tn) && tt<MAXT; tt=tt+1)
        if (a_soff[tt]!==t_soff[tt] || a_sx[tt]!==t_sx[tt] || a_sy[tt]!==t_sy[tt] ||
            a_w[tt]!==t_w[tt] || a_h[tt]!==t_h[tt] ||
            a_dx[tt]!==t_dx[tt] || a_dy[tt]!==t_dy[tt] || a_col[tt]!==t_col[tt]) begin
          if (tx_errs < 6)
            $display("  TX-MISMATCH %0s #%0d: tilemap{off=%h sx=%0d sy=%0d w=%0d h=%0d dx=%0d dy=%0d col=%h}",
                     name, tt, a_soff[tt], a_sx[tt], a_sy[tt], a_w[tt], a_h[tt],
                     $signed(a_dx[tt]), $signed(a_dy[tt]), a_col[tt]);
          if (tx_errs < 6)
            $display("                      nblit{off=%h sx=%0d sy=%0d w=%0d h=%0d dx=%0d dy=%0d col=%h}",
                     t_soff[tt], t_sx[tt], t_sy[tt], t_w[tt], t_h[tt],
                     $signed(t_dx[tt]), $signed(t_dy[tt]), t_col[tt]);
          tx_errs = tx_errs + 1;
        end
      // ---- C2: framebuffer equality (the transactions really composited) ----
      for (yy=0;yy<240;yy=yy+1) for (xx=0;xx<320;xx=xx+1)
        if (getpx(xx,yy) !== fb_a[yy*320+xx]) begin
          if (case_errs < 6)
            $display("  PX-MISMATCH %0s (%0d,%0d): tilemap=%h nblit=%h",
                     name, xx, yy, fb_a[yy*320+xx], getpx(xx,yy));
          case_errs = case_errs + 1;
        end
      if (tx_errs==0 && case_errs==0)
        $display("  %0s (%0d issues): equivalence PASS", name, an);
      else
        $display("  %0s: FAIL (%0d tx, %0d px mismatches)", name, tx_errs, case_errs);
      errs = errs + tx_errs + case_errs;
    end
  endtask

  initial begin
    for(i=0;i<MEMQW;i=i+1)    mem[i]=64'd0;
    for(i=0;i<FRT_SPAN;i=i+1) frtmem[i]=64'd0;
    grid_clear;
    mem[32'h200000]=64'd0; mem[32'h200005]=64'd0;     // submit=done=0
    tn = 32'd0; an = 32'd0;
    seed_tileset;
    tables_clear;

    repeat(8) @(posedge clk); rst<=0;
    repeat(4) @(posedge clk);

    // ── Scenario 0: single opaque 8x8 cell, grid_w=grid_h=1, bias (0,0). One FRT
    //    entry for P0 (src rect 0,0,8,8), CFT[P0]=0. Path B = one OP_BLIT
    //    src (0,0) w8 h8 dst (0,0). This is the simplest possible grid walk:
    //    one non-empty cell, run=1, no clipping, no bias, no sub-offset.
    frt_sx[0*MAXF+0]=0; frt_sy[0*MAXF+0]=0; frt_w[0*MAXF+0]=8; frt_h[0*MAXF+0]=8;
    cur_f[0]=0;
    grid_clear;
    grid_put(0, gcell(0, 0, 0, 0));                  // cell (0,0): pid=0, sub 0,0, run_m1=0
    NB=1;
    b_soff[0]=0; b_sx[0]=0; b_sy[0]=0; b_w[0]=8; b_h[0]=8; b_dx[0]=0; b_dy[0]=0; b_col[0]=16'd0;
    run_case("S0_1x1_OPAQUE", 8'd0, 8'd0, 8'd0, 16'(TSTRIDE), 16'd0, 16'd0, 16'd0,
             32'd0, 32'd0, 16'd1, 16'd1, 16'sd0, 16'sd0);
    // Guard against a both-paths-empty false pass: scenario 0 MUST issue one blit.
    if (an !== 32'd1) begin
      $display("  S0 SANITY: expected exactly 1 tilemap issue, got %0d", an);
      errs = errs + 1;
    end

    if (errs==0) $display("TB_TILEMAP: PASS");
    else         $display("TB_TILEMAP: FAIL (%0d total mismatches)", errs);
    $finish;
  end

  initial begin #900000000 $display("TB_TILEMAP: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire
