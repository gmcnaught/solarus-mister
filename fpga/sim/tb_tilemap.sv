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
  // fill cells [lo,hi) of row `row` (grid width gw) with the EMPTY sentinel
  // (0xFFF, GRID_CELL_PID_EMPTY). grid_clear only zero-fills gridmem, which
  // decodes as pid=0 -- a VALID pattern, NOT empty -- so any column a
  // scenario wants the walker to skip over one-at-a-time (as opposed to
  // jumping over via a coalesced run) must be written explicitly.
  task grid_fill_empty(input integer row, input integer gw,
                       input integer lo, input integer hi_excl);
    integer c;
    begin
      for (c = lo; c < hi_excl; c = c + 1)
        grid_put((row*gw + c)*4, gcell(GRID_CELL_PID_EMPTY, 0, 0, 0));
    end
  endtask

  // ── [Task 4 carry-forward] cells_off MUST be qword(8-byte)-aligned ──────────
  // blitter_top.sv's S_GRID_FETCH picks the cell's 32-bit half with
  // `cell_half <= grid_cell_idx[0]` -- the CELL INDEX's parity, not the actual
  // byte-offset-within-qword parity of grid_cell_boff = cells_off + idx*4.
  // Those two only agree when cells_off is a multiple of 8: idx even always
  // lands on a qword's low half and idx odd on its high half ONLY if the
  // array's own base (cells_off) doesn't itself straddle a qword boundary. A
  // cells_off that is 4-aligned but not 8-aligned (e.g. cells_off=4) would
  // make idx=0's cell live in the HIGH half of its qword while cell_half=
  // idx[0]=0 selects the LOW half -- the FSM would silently decode whatever
  // adjacent garbage happens to be there instead of the intended cell.
  //
  // FINDING (reported per the Task 4 brief): nothing in the B1 emitter
  // enforces this today. blt_grid_list_init/blt_grid_list (blt_emitter.c)
  // take `cells_off` as a raw caller-supplied byte offset with zero alignment
  // validation, and the real per-map GRID_BUF allocator that would COMPUTE
  // non-zero cells_off values for actual map layers does not exist in this
  // codebase yet (blt_emitter_t.grid_used is tracked but never advanced by
  // any allocator function -- that's evidently later work). Whoever writes
  // that allocator must round every layer's cells_off up to 8 bytes, or this
  // walker will silently misdecode cells the first time a layer's cell count
  // is odd and a subsequent layer's array isn't re-based to a qword.
  //
  // Every scenario below passes cells_off=0 (trivially qword-aligned); run_case
  // asserts this literal so a future scenario can't silently violate the
  // invariant this comment pins.

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
      // INVARIANT (see the cells_off qword-alignment note above grid_fill_empty):
      // cell_half = grid_cell_idx[0] only picks the right 32-bit half when
      // cells_off is qword(8-byte)-aligned. Assert it live so a future scenario
      // can't silently violate it.
      if (cells_off[2:0] !== 3'd0) begin
        $display("  %0s: cells_off=0x%h is NOT qword-aligned -- cell_half (grid_cell_idx[0]) would select the WRONG 32-bit half", name, cells_off);
        errs = errs + 1;
      end
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

    // ── Scenario 1: horizontal run coalescing. grid_w=5, grid_h=1, one cell
    //    pid=P0 sub(0,0) run_m1=4 (run=5, 40px), bias 0. A run is ONE blit,
    //    not five -- proves the coalescing itself (not just a length-1 run).
    frt_sx[0*MAXF+0]=0; frt_sy[0*MAXF+0]=0; frt_w[0*MAXF+0]=8; frt_h[0*MAXF+0]=8;
    cur_f[0]=0;
    grid_clear;
    grid_put(0, gcell(0, 0, 0, 4));                   // cell (0,0): pid=0, run_m1=4 (run=5)
    NB=1;
    b_soff[0]=0; b_sx[0]=0; b_sy[0]=0; b_w[0]=40; b_h[0]=8; b_dx[0]=0; b_dy[0]=0; b_col[0]=16'd0;
    run_case("S1_RUN_COALESCE", 8'd0, 8'd0, 8'd0, 16'(TSTRIDE), 16'd0, 16'd0, 16'd0,
             32'd0, 32'd0, 16'd5, 16'd1, 16'sd0, 16'sd0);
    if (an !== 32'd1) begin
      $display("  S1 SANITY: expected exactly 1 tilemap issue (coalesced run), got %0d", an);
      errs = errs + 1;
    end

    // ── Scenario 2: multi-row (the 2.0x case). grid_w=2, grid_h=2. Row0: cell
    //    (0,0)={P0,sub(0,0),run_m1=1} (run=2) covers cx 0..1. Row1: cell
    //    (0,1)={P0,sub(0,1),run_m1=1} covers cx 0..1 at sub_y=1 (src row +8).
    //    TWO blits -- confirms rows are never coalesced together (2 blits for
    //    a 2x2 grid = the 2.0x issue ratio the retained-scene work measured).
    frt_sx[0*MAXF+0]=0; frt_sy[0*MAXF+0]=0; frt_w[0*MAXF+0]=8; frt_h[0*MAXF+0]=8;
    cur_f[0]=0;
    grid_clear;
    grid_put(0, gcell(0, 0, 0, 1));                   // (cx=0,cy=0): run=2
    grid_put(8, gcell(0, 0, 1, 1));                   // (cx=0,cy=1): run=2, sub_y=1
    NB=2;
    b_soff[0]=0; b_sx[0]=0; b_sy[0]=0; b_w[0]=16; b_h[0]=8; b_dx[0]=0; b_dy[0]=0; b_col[0]=16'd0;
    b_soff[1]=0; b_sx[1]=0; b_sy[1]=8; b_w[1]=16; b_h[1]=8; b_dx[1]=0; b_dy[1]=8; b_col[1]=16'd0;
    run_case("S2_MULTIROW_2x2", 8'd0, 8'd0, 8'd0, 16'(TSTRIDE), 16'd0, 16'd0, 16'd0,
             32'd0, 32'd0, 16'd2, 16'd2, 16'sd0, 16'sd0);
    if (an !== 32'd2) begin
      $display("  S2 SANITY: expected exactly 2 tilemap issues (rows not coalesced), got %0d", an);
      errs = errs + 1;
    end

    // ── Scenario 2b: TALL vertical pattern, sub_y 0..3 (the on-device dungeon-wall
    //    repro: 8x32 = 1 cell wide, 4 tall). S2_MULTIROW_2x2 only reaches sub_y=0,1;
    //    sub_y=2,3 have never been exercised through the grid walk. grid_w=1 grid_h=4,
    //    one column, sub_y 0..3, run=1 each. Expect FOUR blits, src_y=sub_y*8
    //    (0,8,16,24), dst_y=cy*8 (0,8,16,24).
    frt_sx[0*MAXF+0]=0; frt_sy[0*MAXF+0]=0; frt_w[0*MAXF+0]=8; frt_h[0*MAXF+0]=8;
    cur_f[0]=0;
    grid_clear;
    grid_put(0*4, gcell(0, 0, 0, 0));
    grid_put(1*4, gcell(0, 0, 1, 0));
    grid_put(2*4, gcell(0, 0, 2, 0));
    grid_put(3*4, gcell(0, 0, 3, 0));
    NB=4;
    b_soff[0]=0; b_sx[0]=0; b_sy[0]=0;  b_w[0]=8; b_h[0]=8; b_dx[0]=0; b_dy[0]=0;  b_col[0]=16'd0;
    b_soff[1]=0; b_sx[1]=0; b_sy[1]=8;  b_w[1]=8; b_h[1]=8; b_dx[1]=0; b_dy[1]=8;  b_col[1]=16'd0;
    b_soff[2]=0; b_sx[2]=0; b_sy[2]=16; b_w[2]=8; b_h[2]=8; b_dx[2]=0; b_dy[2]=16; b_col[2]=16'd0;
    b_soff[3]=0; b_sx[3]=0; b_sy[3]=24; b_w[3]=8; b_h[3]=8; b_dx[3]=0; b_dy[3]=24; b_col[3]=16'd0;
    run_case("S2b_TALL_VERT_4", 8'd0, 8'd0, 8'd0, 16'(TSTRIDE), 16'd0, 16'd0, 16'd0,
             32'd0, 32'd0, 16'd1, 16'd4, 16'sd0, 16'sd0);
    if (an !== 32'd4) begin
      $display("  S2b SANITY: expected exactly 4 tilemap issues (4 rows), got %0d", an);
      errs = errs + 1;
    end

    // ── Scenario 3: negative bias / #24 clip. grid_w=3, grid_h=1, one run
    //    run_m1=2 (run=3, 24px) at cell (0,0), bias=(-3,0).
    //    NOTE on the bias value: an EXACTLY 8-aligned bias (e.g. -8, as the
    //    handoff brief's illustrative value) can NEVER produce a negative
    //    resolved dst_x here. blt_ref_tilemap's cx0 = floor((0-bias_x)/8) is
    //    chosen precisely so cx0*8+bias_x lands at EXACTLY 0 when bias_x is a
    //    multiple of the 8px cell, and the walk never visits cx<cx0 -- so an
    //    8-aligned bias only ever window-culls whole cells, it never exercises
    //    a genuinely negative dst. A non-8-aligned bias (-3) makes
    //    cx0=floor(3/8)=0 -- the run's true start column IS inside the visible
    //    window -- so its resolved dst_x = 0*8-3 = -3, a REAL negative dst that
    //    must be clipped by comp_pipeline's signed compare rather than the
    //    cell-window math (the #24 OOB rule in blt_ref_tilemap: dst is a plain
    //    signed int, cast to int16_t, and clipped while still signed --
    //    strictly before it could ever become a huge unsigned coordinate).
    //    Path B = ONE blit with dst_x=-3 (signed negative), relying on the
    //    same clip. The pixel compare spans the FULL 320x240 framebuffer (not
    //    just the tile region) specifically so a wrap-around corruption
    //    elsewhere would be caught, not just a wrong pixel at the tile itself.
    frt_sx[0*MAXF+0]=0; frt_sy[0*MAXF+0]=0; frt_w[0*MAXF+0]=8; frt_h[0*MAXF+0]=8;
    cur_f[0]=0;
    grid_clear;
    grid_put(0, gcell(0, 0, 0, 2));                   // (cx=0,cy=0): run=3 (24px)
    NB=1;
    b_soff[0]=0; b_sx[0]=0; b_sy[0]=0; b_w[0]=24; b_h[0]=8; b_dx[0]=-3; b_dy[0]=0; b_col[0]=16'd0;
    run_case("S3_NEG_BIAS_CLIP", 8'd0, 8'd0, 8'd0, 16'(TSTRIDE), 16'd0, 16'd0, 16'd0,
             32'd0, 32'd0, 16'd3, 16'd1, -16'sd3, 16'sd0);
    if (an !== 32'd1) begin
      $display("  S3 SANITY: expected exactly 1 tilemap issue, got %0d", an);
      errs = errs + 1;
    end

    // ── Scenario 4: full-cull. grid_w=2, grid_h=2 non-empty (same two 2-wide
    //    runs as scenario 2), bias=(-64,0) so the ENTIRE biased grid (16px
    //    wide) sits off the left edge (vis_lo_x=0 >= vis_hi_x=-48) --
    //    blt_ref_tilemap's early "nothing visible: cull" return fires BEFORE
    //    any cell is fetched or any blit issued. Path B = CLEAR only, zero
    //    blits; assert Path A issues zero transactions too.
    frt_sx[0*MAXF+0]=0; frt_sy[0*MAXF+0]=0; frt_w[0*MAXF+0]=8; frt_h[0*MAXF+0]=8;
    cur_f[0]=0;
    grid_clear;
    grid_put(0, gcell(0, 0, 0, 1));
    grid_put(8, gcell(0, 0, 1, 1));
    NB=0;
    run_case("S4_FULL_CULL", 8'd0, 8'd0, 8'd0, 16'(TSTRIDE), 16'd0, 16'd0, 16'd0,
             32'd0, 32'd0, 16'd2, 16'd2, -16'sd64, 16'sd0);
    if (an !== 32'd0) begin
      $display("  S4 SANITY: expected exactly 0 tilemap issues (full cull), got %0d", an);
      errs = errs + 1;
    end

    // ── Scenario 5: maximal 16-cell run end-to-end. grid_w=16, grid_h=1, one
    //    cell run_m1=15 (run=16, 128px -- BLT_GRID_MAX_RUN, the widest run the
    //    4-bit run_m1 field can express), bias 0. Path B = ONE blit w128 h8.
    frt_sx[0*MAXF+0]=0; frt_sy[0*MAXF+0]=0; frt_w[0*MAXF+0]=8; frt_h[0*MAXF+0]=8;
    cur_f[0]=0;
    grid_clear;
    grid_put(0, gcell(0, 0, 0, 15));                  // run_m1=15 -> run=16 (128px)
    NB=1;
    b_soff[0]=0; b_sx[0]=0; b_sy[0]=0; b_w[0]=128; b_h[0]=8; b_dx[0]=0; b_dy[0]=0; b_col[0]=16'd0;
    run_case("S5_MAX_RUN16", 8'd0, 8'd0, 8'd0, 16'(TSTRIDE), 16'd0, 16'd0, 16'd0,
             32'd0, 32'd0, 16'd16, 16'd1, 16'sd0, 16'sd0);
    if (an !== 32'd1) begin
      $display("  S5 SANITY: expected exactly 1 tilemap issue (max run), got %0d", an);
      errs = errs + 1;
    end

    // ── Scenario 6: right-edge run clamp. grid_w=40, grid_h=1 (320px, exactly
    //    FB width), bias=(0,0). Columns 0..37 EMPTY (walked one at a time --
    //    see grid_fill_empty's header note on why grid_clear alone isn't
    //    enough). Cell (38,0)={P0,sub(0,0),run_m1=4} asks for run=5 (reaching
    //    cx=43) but the window caps cx1=40, so the FSM clamps to run=2
    //    (cx=38,39). blit_one's own per-pixel clip would silently discard the
    //    extra columns too if they weren't clamped (PIXEL-invisible: dst_x=304
    //    w=16 already reaches exactly the FB's right edge, 304+16=320, so an
    //    unclamped w=40 would only be caught by the per-pixel clip, not by
    //    going out of bounds visibly) -- the clamp changes the ISSUED width,
    //    which is what the transaction-sequence compare (not the pixel
    //    compare) is here to catch.
    frt_sx[0*MAXF+0]=0; frt_sy[0*MAXF+0]=0; frt_w[0*MAXF+0]=8; frt_h[0*MAXF+0]=8;
    cur_f[0]=0;
    grid_clear;
    grid_fill_empty(0, 40, 0, 38);
    grid_put(38*4, gcell(0, 0, 0, 4));                // (cx=38,cy=0): asks run=5, clamped to 2
    NB=1;
    b_soff[0]=0; b_sx[0]=0; b_sy[0]=0; b_w[0]=16; b_h[0]=8; b_dx[0]=304; b_dy[0]=0; b_col[0]=16'd0;
    run_case("S6_RIGHT_EDGE_CLAMP", 8'd0, 8'd0, 8'd0, 16'(TSTRIDE), 16'd0, 16'd0, 16'd0,
             32'd0, 32'd0, 16'd40, 16'd1, 16'sd0, 16'sd0);
    if (an !== 32'd1) begin
      $display("  S6 SANITY: expected exactly 1 tilemap issue (clamped run), got %0d", an);
      errs = errs + 1;
    end

    // ── Scenario 7: max in-range pid = MAXP-1 = 255 (NOT the 12-bit encoding
    //    max 0xFFE=4094 -- the cell's pid field is 12 bits wide but the
    //    pattern tables (FRT/CFT, and the RTL's res_pid[$clog2(MAXP)-1:0]
    //    index into them) are only MAXP=256 deep, so 255 is the largest
    //    ADDRESSABLE pid; 256..0xFFE are representable-but-unallocated
    //    encodings and 0xFFF is the empty sentinel. This corrects the
    //    handoff brief's "pid==0xFFE" note -- see the Task 4 report.
    //    grid_w=grid_h=1, pid=255, FRT/CFT populated at index 255 with a
    //    DIFFERENT src rect than P0's (24,16) so a decode that read the wrong
    //    pid (e.g. pid=0, still-resident from earlier scenarios) would
    //    resolve the wrong source and fail the pixel compare, not just the
    //    transaction compare.
    frt_sx[255*MAXF+0]=24; frt_sy[255*MAXF+0]=16; frt_w[255*MAXF+0]=8; frt_h[255*MAXF+0]=8;
    cur_f[255]=0;
    grid_clear;
    grid_put(0, gcell(255, 0, 0, 0));                 // pid=255 (MAXP-1), run=1
    NB=1;
    b_soff[0]=0; b_sx[0]=24; b_sy[0]=16; b_w[0]=8; b_h[0]=8; b_dx[0]=0; b_dy[0]=0; b_col[0]=16'd0;
    run_case("S7_MAX_PID_255", 8'd0, 8'd0, 8'd0, 16'(TSTRIDE), 16'd0, 16'd0, 16'd0,
             32'd0, 32'd0, 16'd1, 16'd1, 16'sd0, 16'sd0);
    if (an !== 32'd1) begin
      $display("  S7 SANITY: expected exactly 1 tilemap issue (pid=255), got %0d", an);
      errs = errs + 1;
    end

    // ── Scenario 8: spare bits [31:24] set-and-ignored. Identical to
    //    scenario 0 except the cell word's spare byte is 0xFF (grid_cell.h:
    //    "written 0, ignored on read"). Asserts the decode masks exactly the
    //    12-bit pid field -- a decode that read pid from a wider slice would
    //    resolve a different (likely empty-sentinel-colliding or OOB) pattern
    //    instead of pattern 0, and either mis-render or wrongly skip the cell.
    frt_sx[0*MAXF+0]=0; frt_sy[0*MAXF+0]=0; frt_w[0*MAXF+0]=8; frt_h[0*MAXF+0]=8;
    cur_f[0]=0;
    grid_clear;
    grid_put(0, gcell(0, 0, 0, 0) | 32'hFF00_0000);   // spare[31:24]=0xFF
    NB=1;
    b_soff[0]=0; b_sx[0]=0; b_sy[0]=0; b_w[0]=8; b_h[0]=8; b_dx[0]=0; b_dy[0]=0; b_col[0]=16'd0;
    run_case("S8_SPARE_BITS", 8'd0, 8'd0, 8'd0, 16'(TSTRIDE), 16'd0, 16'd0, 16'd0,
             32'd0, 32'd0, 16'd1, 16'd1, 16'sd0, 16'sd0);
    if (an !== 32'd1) begin
      $display("  S8 SANITY: expected exactly 1 tilemap issue (spare bits ignored), got %0d", an);
      errs = errs + 1;
    end

    if (errs==0) $display("TB_TILEMAP: PASS");
    else         $display("TB_TILEMAP: FAIL (%0d total mismatches)", errs);
    $finish;
  end

  initial begin #900000000 $display("TB_TILEMAP: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire
