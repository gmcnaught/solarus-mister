// tb_bgplane_equivalence.sv -- proves the Phase 3b baked-plane COPY path produces
// IDENTICAL comp_fbram WORK content to the original per-frame static-tile replay,
// for the same scene and camera window.
//
// Structural choice (single instance, sequential reuse -- see task-7-report.md for
// the full reasoning): ONE blitter_top + ONE real sdram_fb_cache + ONE real
// mt48lc16m16a2 SDRAM model, driven through THREE phases in sequence against the
// same live DUT (mirrors tb_tilelist.sv's "capture A, then reconfigure, capture B,
// compare" idiom, and tb_bgplane_write_pipe.sv's real-hardware-model precedent --
// a prior simplified shadow-SDRAM-model attempt for this exact fabric was found
// buggy and replaced with the real model, so this TB does not repeat that mistake):
//   Phase OLD:  CLEAR + one OP_TILELIST (N map-coord entries, header bias =
//               -camera) replayed directly into WORK -> capture WORK.
//   Phase NEW:  the Task 5 bake sequence, run for BOTH cells of a 640x240 (2-cell)
//               map: per cell, CLEAR + OP_TILELIST at header bias = -cell.origin
//               (cell-local paint) then OP_BGPLANE_WRITE (streams that cell's WORK
//               to its slot in a real map-scan-order SDRAM plane, stride = the
//               whole padded map width -- NOT a degenerate single-cell/no-gap
//               case: the camera window below straddles both cells). A vs-edge +
//               coh_busy flush commits ch0's dirty lines before...
//   Phase COPY: one ordinary windowed OP_BLIT (blend=COPY) reads the plane back at
//               the SAME camera position via the P_SRC (p0) channel -- wired
//               directly to the same real sdram_fb_cache+mt48 instance ch0 wrote
//               into, so this is a genuine write-then-read round trip through
//               physical SDRAM, not a shadow model -> capture WORK.
// Assert phase-COPY's WORK == phase-OLD's WORK, qword-for-qword.
//
// Scene: 96 static tiles (16 cols x 6 rows of 40x40 px) exactly tiling a 640x240
// map (2 cells of 320x240, cell boundary at map x=320, no clipped cells -- both
// bake passes are full 320x240 paints, keeping cell geometry simple while the
// STRIDE/cross-cell addressing is still genuinely exercised). Each tile samples a
// distinct sub-window of a 64x64 procedurally-patterned source atlas (varied
// per-entry sx/sy) so a shifted/misaligned/dropped-entry bug would show up as a
// pixel mismatch, not be hidden by a solid fill colour. Camera = (200, 0): the
// COPY's 320-wide read window spans x=[200,519], straddling the cell boundary at
// x=320 (120px from cell0, 200px from cell1) -- the meaningful multi-cell case the
// brief asked for, not a single-cell degenerate one.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"

module tb_bgplane_equivalence;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h8000;   // ctrl/ring window (mirrors tb_tilelist.sv)
  localparam [31:0] RINGB = 32'h200008;   // ring slot0 (window idx, 0x3B000040)
  localparam        TL_SPAN = 29'h1000;   // tlmem depth (qwords)

  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  // free-running vblank so S_SNAP_* drains after every submit, and ch0's vs-edge
  // flush (used by flush_to_sdram below) actually fires.
  reg vs = 0; integer vsc = 0;
  always @(posedge clk) begin
    vsc <= vsc + 1;
    if (vsc >= 256) begin vs <= ~vs; vsc <= 0; end
  end

  // ---- behavioral command-ring/control-block/TL_BUF DDR (mirrors tb_tilelist.sv) ----
  reg [63:0] mem   [0:MEMQW-1];
  reg [63:0] tlmem [0:TL_SPAN-1];
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat; reg [1:0] bp = 0;
  always @(posedge clk) bp <= bp + 2'd1;
  wire [31:0] bt_addr; wire b_rd, b_we; wire [63:0] b_din; wire [7:0] b_be; wire bt_idle;
  wire [7:0] bt_burst;
  reg  d_dready; reg [63:0] d_dout;
  wire d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  integer i;
  always @(posedge clk) begin
    d_dready <= 1'b0;
    if (rst) begin rbeats <= 0; rlat <= 0; end
    else begin
      if (rlat != 3'd0) rlat <= rlat - 3'd1;
      else if (rbeats != 8'd0) begin
        if (bp == 2'd2) begin
          if (raddr >= `TL_BUF_QW && raddr < (`TL_BUF_QW + TL_SPAN))
            d_dout <= tlmem[raddr - `TL_BUF_QW];
          else
            d_dout <= mem[raddr - WBASE];
          d_dready <= 1'b1; raddr <= raddr + 29'd1; rbeats <= rbeats - 8'd1;
        end
      end else if (!d_busy) begin
        if (b_rd) begin rbeats <= bt_burst; raddr <= bt_addr[28:0]; rlat <= 3'd3; end
        else if (b_we) for (i = 0; i < 8; i = i + 1)
          if (b_be[i]) mem[(bt_addr[28:0] - WBASE)][i*8 +: 8] <= b_din[i*8 +: 8];
      end
    end
  end

  // ---- on-chip dest framebuffer [FB-in-BRAM] ----
  wire fb_wr_en; wire [14:0] fb_wr_qw; wire [1:0] fb_wr_lane; wire [15:0] fb_wr_pix;
  wire fb_rd_en; wire [14:0] fb_rd_qw; wire [63:0] fb_rd_qword;
  comp_fbram fbram (.clk(clk),
    .wr_en(fb_wr_en), .wr_qw(fb_wr_qw), .wr_lane(fb_wr_lane), .wr_pix(fb_wr_pix),
    .rd_en(fb_rd_en), .rd_qw(fb_rd_qw), .rd_qword(fb_rd_qword));

  // ---- ch0 (P_DST, write) + P_SRC (p0, read) ports: REAL sdram_fb_cache + mt48 ----
  // Both the OP_BGPLANE_WRITE bake (ch0) and the tileset-atlas / plane-COPY source
  // reads (p0) route through the SAME physical SDRAM model, exactly like the real
  // system (SDRAM asset residency preloads atlases into the same SDRAM the bake
  // plane lives in) -- so the COPY phase genuinely reads back what the bake wrote.
  wire        dst_wr;
  wire [26:0] dst_addr;
  wire [63:0] dst_din;
  wire [7:0]  dst_wdsn;
  wire        dst_ok;
  wire        coh_busy;

  wire [26:0] p0_addr_w;
  wire        p0_rd_w;
  wire [63:0] p0_dout_w;
  wire        p0_ok_w;

  wire [15:0] sdram_dq;
  wire [12:0] sdram_a;
  wire        sdram_dqml, sdram_dqmh;
  wire [1:0]  sdram_ba;
  wire        sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke, sdram_clk;

  sdram_fb_cache u_cache (
    .clk(clk), .clk_sdram(clk), .rst(rst),
    .init(),
    .dst_addr(dst_addr), .dst_rd(1'b0), .dst_wr(dst_wr),
    .dst_din(dst_din), .dst_wdsn(dst_wdsn), .dst_dout(), .dst_ok(dst_ok),
    .scan_addr(27'd0), .scan_rd(1'b0), .scan_dout(), .scan_ok(),
    .p0_addr(p0_addr_w), .p0_rd(p0_rd_w), .p0_dout(p0_dout_w), .p0_ok(p0_ok_w),
    .stage_addr(27'd0), .stage_wr(1'b0), .stage_din(64'd0), .stage_wdsn(8'hff), .stage_ok(),
    .vs(vs), .coh_busy(coh_busy),
    .stage_barrier(1'b0), .stage_busy(),
    .dst_barrier(1'b0), .dst_busy(),
    .sdram_dq(sdram_dq), .sdram_a(sdram_a),
    .sdram_dqml(sdram_dqml), .sdram_dqmh(sdram_dqmh), .sdram_ba(sdram_ba),
    .sdram_nwe(sdram_nwe), .sdram_ncas(sdram_ncas), .sdram_nras(sdram_nras),
    .sdram_ncs(sdram_ncs), .sdram_cke(sdram_cke), .sdram_clk(sdram_clk)
  );

  mt48lc16m16a2 #(.addr_bits(13), .col_bits(10)) u_sdram (
    .Clk(clk), .Cke(sdram_cke), .Dq(sdram_dq), .Addr(sdram_a), .Ba(sdram_ba),
    .Cs_n(sdram_ncs), .Ras_n(sdram_nras), .Cas_n(sdram_ncas), .We_n(sdram_nwe),
    .Dqm({sdram_dqmh, sdram_dqml}), .downloading(1'b0), .VS(1'b0), .frame_cnt(0)
  );

  // word_base/preload_qword: verbatim from tb_bgplane_write_pipe.sv's address model
  // (client byte addr, qword-aligned -> SDRAM 16-bit word base, OFFSET=0). Used only
  // to seed the tileset atlas directly (mirrors real SDRAM-residency preload, which
  // is out of this task's scope to re-derive) -- the plane itself is never poked
  // directly; it is written ONLY via OP_BGPLANE_WRITE and read ONLY via the COPY's
  // p0 fetch, so the equivalence proof is genuinely end-to-end through the fabric.
  function automatic integer word_base(input integer byte_addr);
    begin word_base = (byte_addr >> 3) * 4; end
  endfunction
  task preload_qword(input integer byte_addr, input [63:0] data);
    integer wb;
    begin
      wb = word_base(byte_addr);
      u_sdram.Bank0[wb+0] = data[15: 0];
      u_sdram.Bank0[wb+1] = data[31:16];
      u_sdram.Bank0[wb+2] = data[47:32];
      u_sdram.Bank0[wb+3] = data[63:48];
    end
  endtask

  // ---- DUT ----
  blitter_top blt (.clk(clk), .rst(rst), .vs(vs),
    .mem_addr(bt_addr), .mem_rd(b_rd), .mem_wr(b_we), .mem_burstcnt(bt_burst),
    .mem_din(b_din), .mem_be(b_be),
    .mem_dout(d_dout), .mem_dout_ready(d_dready), .mem_busy(d_busy),
    .p0_addr(p0_addr_w), .p0_rd(p0_rd_w), .p0_dout(p0_dout_w), .p0_ok(p0_ok_w),
    .src_sdram_ok(1'b1), .stage_barrier_busy(1'b0),
    .fb_wr_en(fb_wr_en), .fb_wr_qw(fb_wr_qw), .fb_wr_lane(fb_wr_lane), .fb_wr_pix(fb_wr_pix),
    .fb_rd_en(fb_rd_en), .fb_rd_qw(fb_rd_qw), .fb_rd_qword(fb_rd_qword),
    .dst_wr(dst_wr), .dst_addr(dst_addr), .dst_din(dst_din), .dst_wdsn(dst_wdsn), .dst_ok(dst_ok),
    .idle(bt_idle));

  // ==== scene: 640x240 map, 96 static tiles (16x6 of 40x40), 64x64 source atlas ====
  localparam integer MAP_W = 640, MAP_H = 240;
  localparam integer TILE_W = 40, TILE_H = 40, COLS = MAP_W/TILE_W, ROWS = MAP_H/TILE_H; // 16x6=96
  localparam integer NN = COLS*ROWS;
  localparam integer ATW = 64, ATH = 64, ATSTRIDE = 128;   // atlas: bytes/row = 64px*2B

  localparam integer ATLAS_BASE_QW = 32'h0000_0800;         // byte 0x4000 -- p0 src_off base
  localparam integer PLANE_BASE_QW = 32'h0000_2000;         // byte 0x10000 -- plane origin (cell0)
  localparam integer PLANE_STRIDE_QW = (MAP_W*2)/8;          // 160 (640px * 2B / 8) -- no padding, MAP_W is a cell-width multiple

  localparam integer CAM_X = 200, CAM_Y = 0;                 // straddles the x=320 cell boundary

  // ---- [Task 3] Phase GAP: real BLT_F_BGCOV decode + gap/parallax-order scenario ----
  localparam integer GAP_PLANE_BASE_QW = 32'h0001_0000;   // well clear of PLANE_BASE_QW's footprint
  localparam integer GAP_STRIDE_QW     = 80;              // single cell, no stride padding (320px*2B/8)
  localparam [15:0] COLOR_COVERED = 16'hA57B;   // non-trivial low bits -> real truncation coverage
  localparam [15:0] COLOR_LOWER   = 16'h07E0;   // distinguishable "pre-existing lower layer" content

  // ---- atlas: procedurally patterned source image, staged directly into SDRAM ----
  function automatic [15:0] pat(input integer sx, input integer sy);
    pat = (sx*73 + sy*151 + 'h9E37) & 16'hFFFF;
  endfunction
  reg [63:0] atlas_stage [0:(ATW*ATSTRIDE/8)-1];
  task seed_atlas;
    integer sx, sy, bo;
    begin
      for (sy = 0; sy < ATH; sy = sy + 1) for (sx = 0; sx < ATW; sx = sx + 1) begin
        bo = sy*ATSTRIDE + sx*2;
        atlas_stage[bo>>3][(bo&7)*8 +: 16] = pat(sx, sy);
      end
    end
  endtask
  task upload_atlas;
    integer qw;
    begin
      for (qw = 0; qw < (ATW*ATSTRIDE/8); qw = qw + 1)
        preload_qword((ATLAS_BASE_QW + qw) * 8, atlas_stage[qw]);
    end
  endtask

  // ---- 96-entry static tile table: map-coord dst, varied atlas sample window ----
  integer ent_sx [0:NN-1], ent_sy [0:NN-1], ent_dx [0:NN-1], ent_dy [0:NN-1];
  task build_entries;
    integer k, col, row;
    begin
      for (k = 0; k < NN; k = k + 1) begin
        col = k % COLS; row = k / COLS;
        ent_dx[k] = col*TILE_W; ent_dy[k] = row*TILE_H;
        ent_sx[k] = (k*5) % (ATW-TILE_W+1);    // in [0, 24]
        ent_sy[k] = (k*11) % (ATH-TILE_H+1);   // in [0, 24]
      end
    end
  endtask

  // little-endian 16-bit field write into byte-addressed tlmem (mirrors tb_tilelist.sv)
  task tl_put16(input integer byteoff, input [15:0] v);
    begin tlmem[byteoff>>3][(byteoff&7)*8 +: 16] = v; end
  endtask
  task tl_load;
    integer k, b;
    begin
      for (k = 0; k < NN; k = k + 1) begin
        b = k*12;
        tl_put16(b+0,  ent_sx[k][15:0]);
        tl_put16(b+2,  ent_sy[k][15:0]);
        tl_put16(b+4,  TILE_W[15:0]);
        tl_put16(b+6,  TILE_H[15:0]);
        tl_put16(b+8,  ent_dx[k][15:0]);
        tl_put16(b+10, ent_dy[k][15:0]);
      end
    end
  endtask

  // ---- command-ring helpers ----
  integer submit_n = 0;
  task set_ctrl(input integer ncmds, input integer flags);
    begin
      mem[32'h200001] = ncmds;
      mem[32'h200002] = 64'd0;      // target_buf=0
      mem[32'h200003] = 64'd0;      // clear_color
      mem[32'h200004] = flags;      // bit0 = CLEAR
      mem[32'h200007] = 64'd2;      // C_PIPE=1
    end
  endtask

  // OP_TILELIST header, ring slot0 + END at slot1 (field layout verbatim from
  // tb_tilelist.sv's wr_tilelist / blitter_top.sv S_DECODE / S_SETUP OP_TILELIST decode).
  task wr_tilelist(input [31:0] src_off, input [31:0] eoff,
                    input signed [15:0] bias_x, input signed [15:0] bias_y);
    begin
      mem[RINGB+0] = {src_off, 8'd0, 8'd0, 8'd0, 8'd5};             // op=TILELIST(5), src_off
      mem[RINGB+1] = {NN[31:0], {bias_x, 16'(ATSTRIDE)}};           // u32[3]=N ; u32[2]=stride|bias_x<<16
      mem[RINGB+2] = {eoff, {16'd0, bias_y}};                       // u32[5]=eoff ; u32[4]=bias_y
      mem[RINGB+3] = 64'd0;
      mem[RINGB+4] = 64'd1;                                         // END
    end
  endtask

  // OP_BGPLANE_WRITE, ring slot0 + END at slot1 (field layout verbatim from
  // tb_bgplane_write_pipe.sv's wr_bgw / blitter_top.sv S_SETUP OP_BGPLANE_WRITE decode).
  task wr_bgw(input [31:0] base_qw, input [15:0] stride_qw);
    begin
      mem[RINGB+0] = {32'd0, 8'd0, 8'd0, 8'd0, OP_BGPLANE_WRITE};
      mem[RINGB+1] = {32'd0, stride_qw, 16'd0};
      mem[RINGB+2] = {base_qw[31:16], base_qw[15:0], 32'd0};
      mem[RINGB+3] = 64'd0;
      mem[RINGB+4] = 64'd1;                                         // END
    end
  endtask

  // OP_BLIT (opcode=3, blend=COPY=0, fmt=0/RGB565), ring slot0 + END at slot1
  // (field layout verbatim from tb_blitter_copy_pipe.sv / blitter_top.sv S_DECODE).
  task wr_blit_copy(input [31:0] src_off, input [15:0] stride,
                     input [15:0] src_x, input [15:0] src_y,
                     input [15:0] w, input [15:0] h,
                     input [15:0] dst_x, input [15:0] dst_y);
    begin
      mem[RINGB+0] = {src_off, 8'd0, 8'd0, 8'd0, 8'd3};             // op=BLIT(3), blend=COPY(0), fmt=0
      mem[RINGB+1] = {h, w, src_x, stride};
      mem[RINGB+2] = {dst_y, dst_x, 16'd0, src_y};
      mem[RINGB+3] = 64'd0;
      mem[RINGB+4] = 64'd1;                                         // END
    end
  endtask

  // ==== [Task 3] BLT_F_BGCOV real-decode gap/parallax-order scenario helpers ====

  // Plain FILL, ring slot `slot` (4-qword stride, mirrors tb_bgplane_write_pipe.sv's
  // wr_fill) -- takes an explicit `flags` byte so the SAME task can emit both the
  // coverage-clearing whole-cell FILL (flags=BLT_F_BGCOV) and ordinary paint FILLs
  // (flags=0) within one multi-command submit, exercising the REAL per-command
  // c_bgcov_clear decode (Step 1) as each command rotates through S_DECODE -- no
  // force/release needed here, unlike tb_bgplane_write_pipe.sv's Task-2-era
  // workaround, since Task 3 is what makes the flag decode real.
  task wr_fill(input integer slot, input [7:0] flags, input [15:0] dx, input [15:0] dy,
               input [15:0] w, input [15:0] h, input [15:0] color);
    integer base;
    begin
      base = RINGB + slot*4;
      mem[base+0] = {32'd0, flags, 8'd0, 8'd0, 8'd2};                // opcode=FILL(2)
      mem[base+1] = {h, w, 32'd0};
      mem[base+2] = {dy, dx, 32'd0};
      mem[base+3] = {16'd0, color, 32'd0};
    end
  endtask

  // OP_BGPLANE_WRITE with an explicit flags byte (wr_bgw above hardcodes flags=0;
  // this variant lets the ARGB4444-mode scenario set BLT_F_BGCOV for real).
  task wr_bgw_flags(input [7:0] flags, input [31:0] base_qw, input [15:0] stride_qw);
    begin
      mem[RINGB+0] = {32'd0, flags, 8'd0, 8'd0, OP_BGPLANE_WRITE};
      mem[RINGB+1] = {32'd0, stride_qw, 16'd0};
      mem[RINGB+2] = {base_qw[31:16], base_qw[15:0], 32'd0};
      mem[RINGB+3] = 64'd0;
      mem[RINGB+4] = 64'd1;                                         // END
    end
  endtask

  // PALPHA readback BLIT (opcode=3/BLIT, blend=3/PALPHA, fmt=1/ARGB4444) -- reads
  // the baked plane back through P_SRC exactly as resident_emit_static_layer's
  // host-side COPY will after Task 5, field layout verbatim from wr_blit_copy
  // above / tb_blitter_palpha_pipe.sv's cmd0 (colorkey/alpha fields unused for
  // PALPHA, left 0).
  task wr_blit_palpha(input [31:0] src_off, input [15:0] stride,
                       input [15:0] w, input [15:0] h,
                       input [15:0] dst_x, input [15:0] dst_y);
    begin
      mem[RINGB+0] = {src_off, 8'd0, 8'd1, 8'd3, 8'd3};       // op=BLIT(3) blend=PALPHA(3) fmt=ARGB4444(1)
      mem[RINGB+1] = {h, w, 16'd0, stride};
      mem[RINGB+2] = {dst_y, dst_x, 16'd0, 16'd0};
      mem[RINGB+3] = 64'd0;
      mem[RINGB+4] = 64'd1;                                         // END
    end
  endtask

  // Bit-exact reconstruction of the PALPHA/ARGB4444 round trip for a FULLY OPAQUE
  // (a4=0xF, a8=0xFF) source pixel: div255_round(src*255 + dst*0) == src exactly
  // (the /255 rounding identity every blend helper in this codebase relies on),
  // so the blended result reduces to the 4-bit-truncated-then-expanded channels --
  // matches blitter_ref.c's argb4444_expand() (r4<<1|r4>>3 / g4<<2|g4>>2 /
  // b4<<1|b4>>3, i.e. bit-replicate the MSB into the new LSB) applied to
  // fbram_to_sdram.sv's pack_argb4444() truncation (r4=rgb565[15:12] etc.). Lets
  // the readback check assert the EXACT expected pixel (truncation-math coverage,
  // reviewer's Task 2 finding) instead of only the alpha nibble.
  function automatic [15:0] expect_palpha_roundtrip(input [15:0] rgb565);
    reg [3:0] r4, g4, b4;
    begin
      r4 = rgb565[15:12]; g4 = rgb565[10:7]; b4 = rgb565[4:1];
      expect_palpha_roundtrip = {r4, r4[3], g4, g4[3:2], b4, b4[3]};
    end
  endfunction

  integer to;
  task run_submit;
    begin
      submit_n = submit_n + 1;
      mem[32'h200000] = submit_n;
      to = 0;
      while (mem[32'h200005][31:0] !== submit_n[31:0] && to < 4000000) begin @(posedge clk); to = to + 1; end
      if (mem[32'h200005][31:0] !== submit_n[31:0]) $display("  WEDGE: submit %0d never acked (to=%0d)", submit_n, to);
      repeat (10) @(posedge clk);
    end
  endtask

  // vs-edge + coh_busy drain: commits ch0's dirty cache lines to the physical mt48
  // model so the (separate-channel) p0 read of the same addresses is coherent --
  // mirrors tb_bgplane_write_pipe.sv's flush_to_sdram, needed here for the same
  // reason (ch0 write and p0 read are independent cache channels on sdram_fb_cache).
  task flush_to_sdram;
    integer t;
    begin
      t = 0;
      while (!vs && t < 400) begin @(posedge clk); t = t + 1; end
      while (vs  && t < 400) begin @(posedge clk); t = t + 1; end
      t = 0;
      while (coh_busy && t < 40000) begin @(posedge clk); t = t + 1; end
      repeat (10) @(posedge clk);
    end
  endtask

  // ---- read a composited pixel from comp_fbram WORK (mirrors tb_tilelist.sv) ----
  function [15:0] getpx(input integer dx, input integer dy);
    integer idx;
    begin
      idx = dy*80 + (dx>>2);
      getpx = ((dx&3)==0)?fbram.bank0[idx]:((dx&3)==1)?fbram.bank1[idx]:
              ((dx&3)==2)?fbram.bank2[idx]:fbram.bank3[idx];
    end
  endfunction

  reg [15:0] fb_old [0:76799];
  integer xx, yy, errs, mism;

  // icarus does not support unpacked-array task ports (S_TL sorry: "Subroutine ports
  // with unpacked dimensions are not yet supported"); capture directly into fb_old
  // (the only capture the compare needs -- phase COPY's result is compared live).
  task capture_old;
    begin for (yy=0; yy<240; yy=yy+1) for (xx=0; xx<320; xx=xx+1) fb_old[yy*320+xx] = getpx(xx,yy); end
  endtask

  initial begin
    for (i=0; i<MEMQW; i=i+1)   mem[i]=64'd0;
    for (i=0; i<TL_SPAN; i=i+1) tlmem[i]=64'd0;
    mem[32'h200000]=64'd0; mem[32'h200005]=64'd0;
    errs = 0;

    seed_atlas;
    build_entries;
    tl_load;

    repeat (8) @(posedge clk); rst <= 0;
    begin : wait_init
      integer wi;
      for (wi = 0; wi < 30000; wi = wi + 1) begin
        @(posedge clk);
        if (!u_cache.init) disable wait_init;
      end
    end
    repeat (4) @(posedge clk);

    upload_atlas;

    // ==== Phase OLD: camera-biased direct replay ====
    set_ctrl(2, 1);   // TILELIST + END, CLEAR
    wr_tilelist(ATLAS_BASE_QW*8, 32'd0, -CAM_X, -CAM_Y);
    run_submit;
    capture_old;
    $display("Phase OLD: captured (camera=%0d,%0d, N=%0d entries)", CAM_X, CAM_Y, NN);

    // ==== Phase NEW: bake cell0 (map origin 0,0) then cell1 (map origin 320,0) ====
    // cell0: paint cell-local (bias=0,0) -> WORK ; stream to plane base PLANE_BASE_QW
    set_ctrl(2, 1);   // TILELIST + END, CLEAR
    wr_tilelist(ATLAS_BASE_QW*8, 32'd0, 16'sd0, 16'sd0);
    run_submit;
    set_ctrl(2, 0);   // BGPLANE_WRITE + END, no CLEAR
    wr_bgw(PLANE_BASE_QW, PLANE_STRIDE_QW[15:0]);
    run_submit;
    $display("Phase NEW: baked cell0 (map_x=0,map_y=0) -> plane_qw=%0d stride_qw=%0d", PLANE_BASE_QW, PLANE_STRIDE_QW);

    // cell1: paint cell-local (bias=-320,0) -> WORK ; stream to plane base + 320px*2B/8
    set_ctrl(2, 1);
    wr_tilelist(ATLAS_BASE_QW*8, 32'd0, -16'sd320, 16'sd0);
    run_submit;
    set_ctrl(2, 0);
    wr_bgw(PLANE_BASE_QW + (320*2)/8, PLANE_STRIDE_QW[15:0]);
    run_submit;
    $display("Phase NEW: baked cell1 (map_x=320,map_y=0) -> plane_qw=%0d", PLANE_BASE_QW + (320*2)/8);

    flush_to_sdram;

    // ==== Phase COPY: ordinary windowed BLIT reads the plane back at the same camera ====
    set_ctrl(2, 1);   // BLIT + END, CLEAR
    wr_blit_copy(PLANE_BASE_QW*8, PLANE_STRIDE_QW[15:0]*8, CAM_X[15:0], CAM_Y[15:0],
                 16'd320, 16'd240, 16'd0, 16'd0);
    run_submit;
    $display("Phase COPY: windowed COPY from baked plane (src=%0d,%0d, w=320,h=240)", CAM_X, CAM_Y);

    // ==== compare: phase-COPY's live comp_fbram WORK vs phase-OLD's captured WORK ====
    mism = 0;
    for (yy=0; yy<240; yy=yy+1) for (xx=0; xx<320; xx=xx+1) begin
      if (getpx(xx,yy) !== fb_old[yy*320+xx]) begin
        if (mism < 12)
          $display("  MISMATCH (%0d,%0d): old=%h new=%h", xx, yy, fb_old[yy*320+xx], getpx(xx,yy));
        mism = mism + 1;
      end
    end
    if (mism == 0) $display("EQUIVALENCE: PASS (76800 pixels)");
    else           $display("EQUIVALENCE: FAIL (%0d mismatches)", mism);
    errs = errs + mism;

    // ==== [Task 3] Phase GAP: real BLT_F_BGCOV decode + gap/parallax-order
    // correctness -- the actual bug #1/parallax-order property this whole design
    // exists to prove in RTL, not just host logic. Single fresh cell (own SDRAM
    // region, no interaction with the OLD/NEW/COPY phases above):
    //   1. whole-cell FILL (flags=BLT_F_BGCOV, clears coverage) + TL/BR paint
    //      FILLs (flags=0, leaves TR/BL "uncovered") -- ONE submit, THREE real
    //      commands, each decoded through S_DECODE with its own flags byte, so
    //      c_bgcov_clear evaluates correctly per-command with no force/release
    //      needed (unlike tb_bgplane_write_pipe.sv's Task-2-era workaround --
    //      this is the real path that workaround stood in for).
    //   2. OP_BGPLANE_WRITE (flags=BLT_F_BGCOV, real ARGB4444 pack mode).
    //   3. flush to SDRAM, then paint a DIFFERENT whole-cell color into WORK
    //      (simulates a lower/parallax layer that already drew this frame).
    //   4. PALPHA BLIT reads the baked plane back onto WORK (mirrors what
    //      resident_emit_static_layer's host-side COPY will do after Task 5).
    //   5. verify: covered quadrants show the baked plane's EXACT truncated/
    //      re-expanded color (opaque overwrite); gap quadrants still show the
    //      untouched lower-layer color.
    set_ctrl(4, 0);   // 3 real cmds (clear-FILL, TL paint, BR paint) + END
    wr_fill(0, 8'h80, 16'd0,   16'd0,   16'd320, 16'd240, COLOR_COVERED);  // whole-cell, BLT_F_BGCOV clear
    wr_fill(1, 8'd0,  16'd0,   16'd0,   16'd160, 16'd120, COLOR_COVERED); // TL covered
    wr_fill(2, 8'd0,  16'd160, 16'd120, 16'd160, 16'd120, COLOR_COVERED); // BR covered
    mem[RINGB + 3*4] = 64'd1;                                             // END
    run_submit;

    set_ctrl(2, 0);   // OP_BGPLANE_WRITE + END, BLT_F_BGCOV (ARGB4444 pack mode)
    wr_bgw_flags(8'h80, GAP_PLANE_BASE_QW, GAP_STRIDE_QW[15:0]);
    run_submit;
    $display("Phase GAP: baked gap cell (TL+BR covered) -> plane_qw=%0d", GAP_PLANE_BASE_QW);

    flush_to_sdram;

    // simulate a lower/parallax layer that already painted this frame
    set_ctrl(2, 0);   // plain FILL + END, no flags
    wr_fill(0, 8'd0, 16'd0, 16'd0, 16'd320, 16'd240, COLOR_LOWER);
    mem[RINGB + 1*4] = 64'd1;                                             // END
    run_submit;

    // PALPHA readback: opaque overwrite where covered, transparent (skip) where not.
    // MUST be flags=0 (no CLEAR) here -- set_ctrl's CLEAR bit wipes the ENTIRE
    // WORK buffer to black BEFORE the ring runs (a legacy pre-ring full-screen
    // FILL(clear_color=0), same mechanism S_GOT_CLEAR/cfg_flags[0] uses elsewhere
    // in this file), which would destroy the lower-layer paint above right before
    // this PALPHA blit is supposed to leave it untouched -- caught via a real
    // mismatch (uncovered pixels read back 0x0000 instead of COLOR_LOWER) when
    // this was accidentally copied as `1` from the unrelated Phase COPY pattern.
    set_ctrl(2, 0);   // BLIT + END, no CLEAR
    wr_blit_palpha(GAP_PLANE_BASE_QW*8, GAP_STRIDE_QW[15:0]*8, 16'd320, 16'd240, 16'd0, 16'd0);
    run_submit;
    $display("Phase GAP: PALPHA readback done");

    mism = 0;
    for (yy=0; yy<240; yy=yy+1) for (xx=0; xx<320; xx=xx+1) begin
      begin : gap_px
        reg covered; reg [15:0] want;
        covered = (yy<120) ? (xx<160) : (xx>=160);   // TL(y<120,x<160) or BR(y>=120,x>=160)
        want = covered ? expect_palpha_roundtrip(COLOR_COVERED) : COLOR_LOWER;
        if (getpx(xx,yy) !== want) begin
          if (mism < 12)
            $display("  GAP MISMATCH (%0d,%0d) covered=%0d: got=%h want=%h", xx, yy, covered, getpx(xx,yy), want);
          mism = mism + 1;
        end
      end
    end
    if (mism == 0) $display("GAP READBACK: PASS (76800 pixels)");
    else           $display("GAP READBACK: FAIL (%0d mismatches)", mism);
    errs = errs + mism;

    if (errs == 0) $display("RESULT: PASS");
    else           $display("RESULT: FAIL (%0d total mismatches)", errs);
    $finish;
  end

  initial begin #160000000 $display("RESULT: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire
