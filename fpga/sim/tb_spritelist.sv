// tb_spritelist.sv — BIT-EXACT equivalence gate for BLT_OP_SPRITELIST (Stage 2 sprite channel).
//
// Proves the fabric SPRITELIST FSM (blitter_top.sv, S_SPR_FETCH0..S_SPR_LATCH ->
// the SHARED S_TL_ISSUE/S_TL_WAIT loop) is indistinguishable from the same batch
// expressed as N expanded per-sprite BLITs. For each case we:
//   A) submit CLEAR + one SPRITELIST (header + N 24-byte entries in SP_BUF),
//      recording every comp_pipeline issue transaction and capturing comp_fbram;
//   B) submit CLEAR + the N expanded BLITs (same shared params, per-entry src_off /
//      rect / dst / palette), recording the same;
//   C) assert the two ISSUE TRANSACTION SEQUENCES are identical field-for-field
//      (c_src_off, c_src_x/y, c_w/c_h, c_dst_x/y, c_color) AND the two framebuffers
//      are identical pixel-for-pixel.
//
// The transaction compare is the primary gate: it is order-sensitive (so a
// reordered or dropped/duplicated entry fails even if the pixels happen to
// coincide) and it checks c_color directly, which the pixel compare only reaches
// indirectly. The pixel compare is the backstop that proves those transactions
// actually composited.
//
// Why this op needs its own gate (and what would break without the RTL):
//   * ENTRY STRIDE — sprite entries are 24 bytes (3 qwords), not TILELIST's 12.
//     A wrong stride desyncs every entry after the first: caught by case N>=2.
//   * PER-ENTRY src_off — sprites do NOT share one texture. If the FSM kept the
//     header's src_off (as OP_TILELIST legitimately does), every sprite from the
//     second sheet reads the wrong atlas. Cases use TWO distinct src_off values.
//   * PER-ENTRY color (pal_id|base_off) — 220/220 of the quest's sprite sheets are
//     PAL8 and Y-sorted sprites come from sheets with DIFFERENT palettes, so the
//     palette cannot live in the header the way a one-tileset tile layer's can.
//     The SPRITELIST header here deliberately carries color=0 (bank 0), so an FSM
//     that failed to latch c_color per entry would decode every sprite through the
//     wrong CLUT bank. Cases use TWO distinct pal_ids.
//   * ORDER — sprites overlap and Z-order == emission order. Cases overlap.
//
// Memory model (windowed, mirrors tb_tilelist / tb_pal8_tilelist):
//   * command ring + control block + source heap live in behavioral DDR `mem`
//     (FSM bm_* master; the P_SRC cache-ok model serves the source heap).
//   * the 24-byte sprite entries live in `spmem`, served whenever the FSM reads the
//     `SP_BUF_QW region (0x3BFD3000) — the same physical region the host writes.
//     NOTE this is a DIFFERENT region from TL_BUF: the sprite lane deliberately
//     shares no storage with the tile-list/resident/bgplane machinery.
//   * `clut_mem` serves the CLUTBUF region for the one-time BLT_OP_CLUT_UPLOAD.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
`include "comp_clut.vh"
`include "comp_defs.vh"
module tb_spritelist;
  localparam integer NENT = `CLUT_BANKS * `CLUT_ENTRIES;   // 32*256 = 8192
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h8000;  // ctrl/ring/source-heap window
  localparam [28:0] SRC_WIN = `SRC_QW - WBASE;                    // source-heap window base
  localparam [31:0] RINGB   = 32'h200008;                        // ring slot0 (window idx)
  localparam        SP_SPAN = 29'h1000;                          // spmem depth (qwords)

  // Two 8bpp sprite sheets at DISTINCT heap byte offsets (per-entry src_off) and
  // two DISTINCT palette banks (per-entry color). SHEET0_OFF is 0 so a regression
  // that ignores the entry's src_off still "works" for sheet 0 and fails only on
  // sheet 1 — which is exactly the bug shape we want localized.
  localparam integer SHEET0_OFF = 0;
  localparam integer SHEET1_OFF = 32'h4000;
  localparam integer PAL_A = 5,  PAL_B = 9;      // distinct CLUT banks
  localparam integer BASE_A = 0, BASE_B = 16;    // distinct base_off, too
  // color wire packing (blt_pal_color): {pal_id[4:0]<<8 | base_off[7:0]}.
  localparam [15:0] COLOR_A = (PAL_A << 8) | BASE_A;
  localparam [15:0] COLOR_B = (PAL_B << 8) | BASE_B;

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
  reg [63:0] mem      [0:MEMQW-1];
  reg [63:0] spmem    [0:SP_SPAN-1];         // sprite-entry buffer (SP_BUF_QW region)
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

  // DDR read/write engine; SP_BUF_QW reads served from spmem, CLUT_BUF_QW from clut_mem.
  always @(posedge clk) begin
    d_dready <= 1'b0;
    d_dout   <= 64'hDEAD_BEEF_DEAD_BEEF;
    if (rst) begin rbeats<=0; rlat<=0; end
    else begin
      if (rlat != 3'd0) rlat <= rlat - 3'd1;
      else if (rbeats != 8'd0) begin
        if (bp == 2'd2) begin
          if (raddr >= `SP_BUF_QW && raddr < (`SP_BUF_QW + SP_SPAN))
            d_dout <= spmem[raddr - `SP_BUF_QW];
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

  // ── comp_pipeline ISSUE-TRANSACTION recorder ────────────────────────────────
  // Every pipe_start pulse is one issue. The CLEAR-before-list pass also pulses
  // pipe_start, but it does so with c_opcode==OP_FILL(2) (see the S_CLR_FILL setup
  // in blitter_top); filtering that out leaves exactly the per-sprite issues, which
  // is what both paths must agree on.
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

  // ── 8bpp INDEX sheets: 64x64 each, stride = SW bytes (1 B/px) ───────────────
  localparam integer SW=64, SH=64, SSTRIDE=SW;
  function [7:0] idx_at(input integer sheet, input integer sx, input integer sy);
    idx_at = (sheet ? (sx*11 + sy*29 + 8'h5A) : (sx*7 + sy*13)) & 8'hFF;
  endfunction
  task seed_sheet(input integer sheet, input integer off);
    integer sx, sy, bo;
    begin
      for (sy=0; sy<SH; sy=sy+1) for (sx=0; sx<SW; sx=sx+1) begin
        bo = off + sy*SSTRIDE + sx;                   // 1 B/px source byte offset
        mem[SRC_WIN + (bo>>3)][(bo&7)*8 +: 8] = idx_at(sheet,sx,sy);
      end
    end
  endtask

  // ── CLUT: global entry g = bank*256+slot decodes to {A4=F, RGB565 = g[15:0]}.
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

  // ── sprite table (drives both SP_BUF entries and the expanded BLITs) ───────
  localparam integer MAXN=64;
  integer NN;
  integer   ent_off [0:MAXN-1];                       // per-entry src_off
  integer   ent_sx  [0:MAXN-1], ent_sy [0:MAXN-1];
  integer   ent_w   [0:MAXN-1], ent_h  [0:MAXN-1];
  integer   ent_dx  [0:MAXN-1], ent_dy [0:MAXN-1];
  reg [15:0] ent_col[0:MAXN-1];                       // per-entry pal_id|base_off

  task sp_put16(input integer byteoff, input [15:0] v);
    begin spmem[byteoff>>3][(byteoff&7)*8 +: 16] = v; end
  endtask
  task sp_put32(input integer byteoff, input [31:0] v);
    begin spmem[byteoff>>3][(byteoff&7)*8 +: 32] = v; end
  endtask
  // Pack the NN entries (24 bytes each) into spmem starting at byte offset `eoff`.
  // Field offsets are read straight off blt_wire.h's blt_sprite_entry_t:
  //   +0 u32 src_off | +4 u16 src_x | +6 u16 src_y | +8 u16 w | +10 u16 h
  //   | +12 i16 dst_x | +14 i16 dst_y | +16 u16 color | +18 u16 _rsvd | +20 u32 _rsvd2
  task sp_load(input integer eoff);
    integer k, b;
    begin
      for (k=0; k<NN; k=k+1) begin
        b = eoff + k*24;
        sp_put32(b+0,  ent_off[k][31:0]);
        sp_put16(b+4,  ent_sx [k][15:0]);
        sp_put16(b+6,  ent_sy [k][15:0]);
        sp_put16(b+8,  ent_w  [k][15:0]);
        sp_put16(b+10, ent_h  [k][15:0]);
        sp_put16(b+12, ent_dx [k][15:0]);   // i16 (two's complement bits)
        sp_put16(b+14, ent_dy [k][15:0]);
        sp_put16(b+16, ent_col[k]);
        sp_put16(b+18, 16'hDEAD);           // _rsvd: poison — the FSM must IGNORE it
        sp_put32(b+20, 32'hDEADBEEF);       // _rsvd2: poison likewise
      end
    end
  endtask

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

  // SPRITELIST header at ring slot 0 + END. Header packing is IDENTICAL to
  // OP_TILELIST's: w|h<<16 = N, dst_x|dst_y<<16 = entry byte offset, src_x/src_y =
  // signed per-batch dst bias. The header src_off AND color are deliberately left 0
  // — both are per-entry for this op, so a header-carrying regression fails loudly.
  task wr_spritelist(input [7:0] blend, input [7:0] fmt, input [7:0] flags,
                     input [15:0] stride, input [15:0] alpha, input [15:0] ck,
                     input [31:0] eoff,
                     input signed [15:0] bias_x, input signed [15:0] bias_y);
    begin
      mem[RINGB+0] = {32'd0, {flags, fmt, blend, 8'd10}};           // op=SPRITELIST, src_off=0
      mem[RINGB+1] = {NN[31:0], {bias_x, stride}};                  // u32[3]=N ; u32[2]=stride|bias_x<<16
      mem[RINGB+2] = {eoff, {16'd0, bias_y}};                       // u32[5]=eoff ; u32[4]=bias_y
      mem[RINGB+3] = {{16'd0, 16'd0}, {8'd0, alpha[7:0], ck}};      // u32[7][15:0]=color=0 (per-entry!)
      mem[RINGB+4] = 64'd1;                                         // END
    end
  endtask

  // The NN expanded BLITs at ring slots 0..NN-1 + END. Each carries the entry's OWN
  // src_off and color, and the header bias pre-folded into its dst — i.e. exactly
  // what the SPRITELIST FSM must synthesize per entry.
  task wr_blits(input [7:0] blend, input [7:0] fmt, input [7:0] flags,
                input [15:0] stride, input [15:0] alpha, input [15:0] ck,
                input signed [15:0] bias_x, input signed [15:0] bias_y);
    integer k; integer base;
    begin
      for (k=0; k<NN; k=k+1) begin
        base = RINGB + k*4;
        mem[base+0] = {ent_off[k][31:0], {flags, fmt, blend, 8'd3}}; // op=BLIT, per-entry src_off
        mem[base+1] = {ent_h[k][15:0], ent_w[k][15:0], ent_sx[k][15:0], stride};
        mem[base+2] = {(ent_dy[k][15:0]+bias_y), (ent_dx[k][15:0]+bias_x), 16'd0, ent_sy[k][15:0]};
        mem[base+3] = {{16'd0, ent_col[k]}, {8'd0, alpha[7:0], ck}};
      end
      mem[RINGB + NN*4] = 64'd1;                                     // END
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
      idx = dy*`FB_ROW_QW + (dx>>2);
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

  // expected composited RGB565 for a sheet/palette/source pixel under COPY:
  // CLUT[pal*256 + base + index].
  function [15:0] golden_px(input integer sheet, input integer pal, input integer base,
                            input integer sx, input integer sy);
    golden_px = clut_decode(pal*256 + base + idx_at(sheet,sx,sy));
  endfunction

  task run_case(input [159:0] name, input [7:0] blend, input [7:0] fmt, input [7:0] flags,
                input [15:0] stride, input [15:0] alpha, input [15:0] ck, input [31:0] eoff,
                input signed [15:0] bias_x, input signed [15:0] bias_y);
    begin
      case_errs = 0; tx_errs = 0;
      // ---- A: one SPRITELIST ----
      sp_load(eoff);
      set_ctrl(2);                                   // header + END
      wr_spritelist(blend, fmt, flags, stride, alpha, ck, eoff, bias_x, bias_y);
      tn = 32'd0;
      run_submit;
      an = tn;
      for (tt=0; tt<MAXT; tt=tt+1) begin
        a_soff[tt]=t_soff[tt]; a_sx[tt]=t_sx[tt]; a_sy[tt]=t_sy[tt];
        a_w   [tt]=t_w   [tt]; a_h [tt]=t_h [tt];
        a_dx  [tt]=t_dx  [tt]; a_dy[tt]=t_dy[tt]; a_col[tt]=t_col[tt];
      end
      capture_a;
      // ---- B: NN expanded BLITs ----
      set_ctrl(NN+1);                                // N BLITs + END
      wr_blits(blend, fmt, flags, stride, alpha, ck, bias_x, bias_y);
      tn = 32'd0;
      run_submit;
      // ---- C1: issue-transaction sequence equality (order-sensitive) ----
      if (an !== tn) begin
        $display("  TX-COUNT %0s: spritelist=%0d nblit=%0d", name, an, tn);
        tx_errs = tx_errs + 1;
      end
      for (tt=0; tt<((an<tn)?an:tn) && tt<MAXT; tt=tt+1)
        if (a_soff[tt]!==t_soff[tt] || a_sx[tt]!==t_sx[tt] || a_sy[tt]!==t_sy[tt] ||
            a_w[tt]!==t_w[tt] || a_h[tt]!==t_h[tt] ||
            a_dx[tt]!==t_dx[tt] || a_dy[tt]!==t_dy[tt] || a_col[tt]!==t_col[tt]) begin
          if (tx_errs < 6)
            $display("  TX-MISMATCH %0s #%0d: spritelist{off=%h sx=%0d sy=%0d w=%0d h=%0d dx=%0d dy=%0d col=%h}",
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
            $display("  PX-MISMATCH %0s (%0d,%0d): spritelist=%h nblit=%h",
                     name, xx, yy, fb_a[yy*320+xx], getpx(xx,yy));
          case_errs = case_errs + 1;
        end
      if (tx_errs==0 && case_errs==0)
        $display("  %0s (N=%0d, %0d issues): equivalence PASS", name, NN, an);
      else
        $display("  %0s (N=%0d): FAIL (%0d tx, %0d px mismatches)", name, NN, tx_errs, case_errs);
      errs = errs + tx_errs + case_errs;
    end
  endtask

  integer k, gerr;
  reg [15:0] got, exp;
  initial begin
    for(i=0;i<MEMQW;i=i+1)   mem[i]=64'd0;
    for(i=0;i<SP_SPAN;i=i+1) spmem[i]=64'd0;
    mem[32'h200000]=64'd0; mem[32'h200005]=64'd0;     // submit=done=0
    tn = 32'd0; an = 32'd0;
    seed_sheet(0, SHEET0_OFF);
    seed_sheet(1, SHEET1_OFF);
    seed_clut;

    repeat(8) @(posedge clk); rst<=0;
    repeat(4) @(posedge clk);

    // ---- submit 0: BLT_OP_CLUT_UPLOAD (load clut_mem -> fabric clut_bram) ----
    mem[32'h200001]=64'd2;                 // cmd_count = CLUT_UPLOAD + END
    mem[32'h200002]=64'd0; mem[32'h200003]=64'd0; mem[32'h200004]=64'd0; mem[32'h200007]=64'd0;
    mem[RINGB+0] = {32'd0, {8'd0, 8'd0, 8'd0, 8'(`BLT_OP_CLUT_UPLOAD)}};
    mem[RINGB+1] = {NENT[31:0], 32'd0};    // u32[3]=count ; NENT<65536 so high=0
    mem[RINGB+2] = 64'd0;
    mem[RINGB+3] = 64'd0;
    mem[RINGB+4] = 64'd1;                  // END
    run_submit;

    // ── Case 1: N=1, PAL8 COPY from sheet 0. Plus a GOLDEN spot-check so a
    //    both-paths-garbage result cannot pass as "equivalent".
    NN=1;
    ent_off[0]=SHEET0_OFF; ent_col[0]=COLOR_A;
    ent_sx[0]=4; ent_sy[0]=4; ent_w[0]=8; ent_h[0]=8; ent_dx[0]=10; ent_dy[0]=10;
    run_case("N1_COPY", 8'd0, `COMP_PAL8, 8'd0, 16'(SSTRIDE), 16'd0, 16'd0, 32'd0, 16'sd0, 16'sd0);
    gerr = 0;
    for (yy=0; yy<8; yy=yy+1) for (xx=0; xx<8; xx=xx+1) begin
      got = getpx(10+xx, 10+yy);
      exp = golden_px(0, PAL_A, BASE_A, 4+xx, 4+yy);
      if (got !== exp) begin
        if (gerr < 6) $display("  GOLDEN MISMATCH (%0d,%0d): got=%h exp=%h", 10+xx, 10+yy, got, exp);
        gerr = gerr + 1;
      end
    end
    if (gerr==0) $display("  N1_COPY: golden CLUT-decode PASS (bank %0d)", PAL_A);
    else begin $display("  N1_COPY: golden FAIL (%0d mismatches)", gerr); errs = errs + gerr; end

    // ── Case 2: N=6 — TWO sheets (per-entry src_off) x TWO palettes (per-entry
    //    color), OVERLAPPING dsts so Z-order == emission order is observable, a
    //    negative-x partial, a right-edge partial, and a fully-offscreen entry
    //    (cull path). This is the case that fails on a wrong 24-byte stride, a
    //    header-carried src_off, or a header-carried palette.
    NN=6;
    ent_off[0]=SHEET0_OFF; ent_col[0]=COLOR_A;
    ent_sx[0]=0;  ent_sy[0]=0;  ent_w[0]=16; ent_h[0]=16; ent_dx[0]=40; ent_dy[0]=40;
    ent_off[1]=SHEET1_OFF; ent_col[1]=COLOR_B;                       // other sheet AND palette,
    ent_sx[1]=0;  ent_sy[1]=0;  ent_w[1]=16; ent_h[1]=16; ent_dx[1]=48; ent_dy[1]=44; // overlapping [0]
    ent_off[2]=SHEET0_OFF; ent_col[2]=COLOR_B;                       // sheet 0 with the OTHER palette
    ent_sx[2]=8;  ent_sy[2]=8;  ent_w[2]=16; ent_h[2]=16; ent_dx[2]=52; ent_dy[2]=48; // overlapping [1]
    ent_off[3]=SHEET1_OFF; ent_col[3]=COLOR_A;                       // sheet 1 with the OTHER palette
    ent_sx[3]=16; ent_sy[3]=16; ent_w[3]=8;  ent_h[3]=8;  ent_dx[3]=-4; ent_dy[3]=90; // x<0 partial
    ent_off[4]=SHEET0_OFF; ent_col[4]=COLOR_A;
    ent_sx[4]=0;  ent_sy[4]=0;  ent_w[4]=8;  ent_h[4]=8;  ent_dx[4]=315;ent_dy[4]=200;// right-edge partial
    ent_off[5]=SHEET1_OFF; ent_col[5]=COLOR_B;
    ent_sx[5]=0;  ent_sy[5]=0;  ent_w[5]=8;  ent_h[5]=8;  ent_dx[5]=400;ent_dy[5]=300;// fully offscreen (cull)
    run_case("N6_2SHEET_2PAL", 8'd0, `COMP_PAL8, 8'd0, 16'(SSTRIDE), 16'd0, 16'd0, 32'd0, 16'sd0, 16'sd0);

    // ── Case 3: same batch shape at a NON-ZERO entry-array offset (eoff=24, i.e.
    //    one entry in) AND a non-zero signed header dst bias. Proves the entry
    //    address math (SP_BUF_QW + (eoff + i*24)>>3) and the per-batch bias add.
    run_case("N6_EOFF24_BIAS", 8'd0, `COMP_PAL8, 8'd0, 16'(SSTRIDE), 16'd0, 16'd0, 32'd24,
             -16'sd6, 16'sd5);

    // ── Case 4: N=24 alternating sheets/palettes across the screen — many entries,
    //    many source fetches, entry-array offset well past the first qword page.
    NN=24;
    for (k=0;k<24;k=k+1) begin
      ent_off[k] = (k & 1) ? SHEET1_OFF : SHEET0_OFF;
      ent_col[k] = (k & 1) ? COLOR_B    : COLOR_A;
      ent_sx[k]=(k%8); ent_sy[k]=(k%5); ent_w[k]=12; ent_h[k]=12;
      ent_dx[k]=(k%8)*20 + 4; ent_dy[k]=(k/8)*20 + 140;
    end
    run_case("N24_ALT_SHEETS", 8'd0, `COMP_PAL8, 8'd0, 16'(SSTRIDE), 16'd0, 16'd0, 32'd48,
             16'sd0, 16'sd0);

    // ── Case 5: PALPHA over ARGB4444 (16bpp, no CLUT) from two sheets — proves the
    //    shared header blend/format still apply per entry and the per-entry color is
    //    inert for a non-PAL8 format (matching the expanded BLITs, which carry it too).
    NN=4;
    ent_off[0]=SHEET0_OFF; ent_col[0]=16'd0;
    ent_sx[0]=2;  ent_sy[0]=2;  ent_w[0]=12; ent_h[0]=12; ent_dx[0]=20; ent_dy[0]=20;
    ent_off[1]=SHEET1_OFF; ent_col[1]=16'd0;
    ent_sx[1]=4;  ent_sy[1]=1;  ent_w[1]=12; ent_h[1]=12; ent_dx[1]=26; ent_dy[1]=24; // overlaps [0]
    ent_off[2]=SHEET0_OFF; ent_col[2]=16'd0;
    ent_sx[2]=0;  ent_sy[2]=10; ent_w[2]=16; ent_h[2]=10; ent_dx[2]=40; ent_dy[2]=40;
    ent_off[3]=SHEET1_OFF; ent_col[3]=16'd0;
    ent_sx[3]=10; ent_sy[3]=10; ent_w[3]=10; ent_h[3]=10; ent_dx[3]=-3; ent_dy[3]=60; // partial
    // ARGB4444 reads the SAME bytes 2-per-pixel, so use a 2 B/px stride here.
    run_case("PALPHA_4444_2SHEET", 8'd3, `COMP_ARGB4444, 8'd0, 16'(SW*2), 16'd0, 16'd0, 32'd0,
             16'sd0, 16'sd0);

    if (errs==0) $display("TB_SPRITELIST: PASS");
    else         $display("TB_SPRITELIST: FAIL (%0d total mismatches)", errs);
    $finish;
  end

  initial begin #900000000 $display("TB_SPRITELIST: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire
