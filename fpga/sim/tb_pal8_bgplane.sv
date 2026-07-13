// tb_pal8_bgplane.sv -- proves the bgplane BAKE resolves a PAL8 (8bpp palette-
// indexed) source through the CLUT and writes a correct plane, then reads it back
// identically to a direct PALPHA composite of the same tile. This is the sim gate
// for shipping SOLARUS_BGPLANE default-on on top of the paletted-composition
// (PR #120) atlas: the bake's source read now routes through res_bucket_emit_tex
// as COMP_PAL8 (mister_blitter_renderer.cpp bake_background_plane_step:2875), a
// composition that tb_pal8_tilelist (PAL8 tile-list decode) and
// tb_bgplane_equivalence (bake -> plane -> readback) each prove in isolation but
// that has NEVER been exercised together.
//
// If the bake carries fmt=COMP_PAL8 + pal_id/base through comp_pipeline's
// index->CLUT decode into WORK, packs the resolved RGB565 into the ARGB4444 plane,
// and reads it back, this PASSES with NO RTL change (host-only path). If the bake
// drops the format/pal_id (reads the 8bpp index atlas as 16bpp), the readback is
// misdecoded garbage != the direct composite -> FAIL, localizing the gap before HW.
//
// Scope: BINARY alpha only (opaque index a4=F, transparent index a4=0) -- exactly
// the shipping case (opaque tiles + fully-transparent gaps). Partial-alpha (water,
// a4 in (0,F)) is the separate, still-open KNOWN-DEFECT tracked in
// tb_bgplane_equivalence.sv:634 and handled host-side per the design; not tested here.
//
// Structure = tb_bgplane_equivalence.sv's real sdram_fb_cache + mt48 + STAGE-reroute
// bake/readback harness (verbatim), plus tb_pal8_tilelist.sv's CLUT window +
// BLT_OP_CLUT_UPLOAD + COMP_PAL8 tile-list (verbatim idioms). The one new thing is
// their composition: a PAL8 tile painted into WORK, baked, and read back.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
`include "comp_clut.vh"
`include "comp_defs.vh"

module tb_pal8_bgplane;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h8000;   // ctrl/ring window (mirrors tb_tilelist.sv)
  localparam [31:0] RINGB = 32'h200008;   // ring slot0 (window idx, 0x3B000040)
  localparam        TL_SPAN = 29'h1000;   // tlmem depth (qwords)
  localparam integer NENT = `CLUT_BANKS * `CLUT_ENTRIES;   // 32*256 = 8192

  // PAL8 params: bank 5 (proves the header's pal_id bank-select survives the bake),
  // base_off 0. color-field wire packing (blt_pal_color): {pal_id[4:0]<<8 | base_off}.
  localparam integer PAL_ID = 5, PAL_BASE = 0;
  localparam [15:0]  PAL_COLOR = (PAL_ID << 8) | PAL_BASE;
  // Two indices used by the source: an OPAQUE motif index and a TRANSPARENT surround.
  localparam [7:0]  OP_IDX = 8'd7, TR_IDX = 8'd0;
  localparam [15:0] OP_RGB = 16'hA57B;   // CLUT RGB565 for the opaque index (non-trivial low bits)
  localparam [15:0] KEY_LOWER = 16'h07E0; // pre-existing lower-layer color (readback background)

  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  // free-running vblank so S_SNAP_* drains after every submit, and ch0's vs-edge
  // flush (used by flush_to_sdram below) actually fires.
  reg vs = 0; integer vsc = 0;
  always @(posedge clk) begin
    vsc <= vsc + 1;
    if (vsc >= 256) begin vs <= ~vs; vsc <= 0; end
  end

  // ---- behavioral command-ring/control-block/TL_BUF/CLUTBUF DDR (mirrors tb_tilelist.sv
  //      + tb_pal8_tilelist.sv's CLUT_BUF_QW branch) ----
  reg [63:0] mem      [0:MEMQW-1];
  reg [63:0] tlmem    [0:TL_SPAN-1];
  reg [63:0] clut_mem [0:NENT-1];   // CLUTBUF region (BLT_OP_CLUT_UPLOAD source)
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
          else if (raddr >= `CLUT_BUF_QW && raddr < (`CLUT_BUF_QW + NENT))
            d_dout <= clut_mem[raddr - `CLUT_BUF_QW];
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

  // ---- ch0/ch1(STAGE) + P_SRC(p0): REAL sdram_fb_cache + mt48 (verbatim from
  //      tb_bgplane_equivalence.sv) -- OP_BGPLANE_WRITE streams via ch1(STAGE),
  //      plane read back via p0, a genuine write-then-read through physical SDRAM ----
  wire        dst_wr;   wire [26:0] dst_addr;   wire [63:0] dst_din;
  wire [7:0]  dst_wdsn; wire        dst_ok;     wire        coh_busy;
  wire [26:0] p0_addr_w; wire p0_rd_w; wire [63:0] p0_dout_w; wire p0_ok_w;
  wire [15:0] sdram_dq; wire [12:0] sdram_a; wire sdram_dqml, sdram_dqmh;
  wire [1:0]  sdram_ba;
  wire        sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke, sdram_clk;
  wire        stage_we_burst_w; wire [63:0] stage_din64_w; wire [26:0] stage_waddr_w;
  wire        stage_ok_w; wire stage_barrier_w; wire stage_busy_w;

  sdram_fb_cache u_cache (
    .clk(clk), .clk_sdram(clk), .rst(rst), .init(),
    .dst_addr(dst_addr), .dst_rd(1'b0), .dst_wr(dst_wr),
    .dst_din(dst_din), .dst_wdsn(dst_wdsn), .dst_dout(), .dst_ok(dst_ok),
    .scan_addr(27'd0), .scan_rd(1'b0), .scan_dout(), .scan_ok(),
    .p0_addr(p0_addr_w), .p0_rd(p0_rd_w), .p0_dout(p0_dout_w), .p0_ok(p0_ok_w),
    .stage_addr(stage_waddr_w), .stage_wr(stage_we_burst_w), .stage_din(stage_din64_w),
    .stage_wdsn(8'h00), .stage_ok(stage_ok_w),
    .vs(vs), .coh_busy(coh_busy),
    .stage_barrier(stage_barrier_w), .stage_busy(stage_busy_w),
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

  // client byte addr -> mt48 Bank0 16-bit word base (verbatim from tb_bgplane_equivalence.sv)
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

  // ---- DUT (STAGE-reroute wiring verbatim from tb_bgplane_equivalence.sv) ----
  blitter_top blt (.clk(clk), .rst(rst), .vs(vs),
    .mem_addr(bt_addr), .mem_rd(b_rd), .mem_wr(b_we), .mem_burstcnt(bt_burst),
    .mem_din(b_din), .mem_be(b_be),
    .mem_dout(d_dout), .mem_dout_ready(d_dready), .mem_busy(d_busy),
    .p0_addr(p0_addr_w), .p0_rd(p0_rd_w), .p0_dout(p0_dout_w), .p0_ok(p0_ok_w),
    .src_sdram_we_burst(stage_we_burst_w), .src_sdram_din64(stage_din64_w),
    .src_sdram_waddr(stage_waddr_w), .src_sdram_ok(stage_ok_w),
    .stage_barrier(stage_barrier_w), .stage_barrier_busy(stage_busy_w),
    .fb_wr_en(fb_wr_en), .fb_wr_qw(fb_wr_qw), .fb_wr_lane(fb_wr_lane), .fb_wr_pix(fb_wr_pix),
    .fb_rd_en(fb_rd_en), .fb_rd_qw(fb_rd_qw), .fb_rd_qword(fb_rd_qword),
    .dst_wr(dst_wr), .dst_addr(dst_addr), .dst_din(dst_din), .dst_wdsn(dst_wdsn), .dst_ok(dst_ok),
    .idle(bt_idle));

  // ==== geometry: one 40x40 PAL8 tile at dst (0,0) in a single 320-wide cell ====
  localparam integer KTW = 40, KTH = 40;
  localparam integer PAL_TSTRIDE = KTW;                  // 1 B/px index source
  localparam integer PLANE_STRIDE_QW = 80;               // 320px * 2B / 8, single cell
  localparam integer MOTIF_LO = 16, MOTIF_HI = 24;       // opaque motif window [16,24)
  localparam integer PAL_SRC_BASE_QW   = 32'h0004_0000;  // fresh SDRAM region (index source)
  localparam integer PAL_PLANE_BASE_QW = 32'h0004_8000;  // fresh SDRAM region (baked plane)

  // is source pixel (sx,sy) inside the opaque motif window?
  function automatic is_motif(input integer sx, input integer sy);
    is_motif = (sx >= MOTIF_LO && sx < MOTIF_HI && sy >= MOTIF_LO && sy < MOTIF_HI);
  endfunction

  // Seed the 8bpp INDEX source into mt48 (1 B/px, 8 indices/qword). Motif = OP_IDX,
  // surround = TR_IDX. KTW=40 is a multiple of 8, so every row is qword-aligned.
  task seed_pal8_src;
    integer sx, sy, q, p; reg [63:0] w64;
    begin
      for (sy = 0; sy < KTH; sy = sy + 1)
        for (q = 0; q < KTW/8; q = q + 1) begin
          w64 = 64'd0;
          for (p = 0; p < 8; p = p + 1) begin
            sx = q*8 + p;
            w64[p*8 +: 8] = is_motif(sx, sy) ? OP_IDX : TR_IDX;
          end
          preload_qword((PAL_SRC_BASE_QW + sy*(KTW/8) + q)*8, w64);
        end
    end
  endtask

  // CLUT: default every entry to {a4=F, rgb=g[15:0]}; then override the two indices
  // this test uses in bank PAL_ID -- OP_IDX opaque (a4=F, OP_RGB), TR_IDX transparent
  // (a4=0). global entry g = bank*256 + slot.
  task seed_clut;
    integer g;
    begin
      for (g = 0; g < NENT; g = g + 1)
        clut_mem[g] = {32'd0, `CLUT_MAKE(4'hF, g[15:0])};
      clut_mem[PAL_ID*256 + OP_IDX] = {32'd0, `CLUT_MAKE(4'hF, OP_RGB)};
      clut_mem[PAL_ID*256 + TR_IDX] = {32'd0, `CLUT_MAKE(4'h0, 16'h0000)};
    end
  endtask

  // ---- single-entry PAL8 tile-list (idioms verbatim from tb_pal8_tilelist.sv) ----
  localparam integer NN = 1;
  integer ent_sx [0:NN-1], ent_sy [0:NN-1], ent_w [0:NN-1], ent_h [0:NN-1],
          ent_dx [0:NN-1], ent_dy [0:NN-1];
  task tl_put16(input integer byteoff, input [15:0] v);
    begin tlmem[byteoff>>3][(byteoff&7)*8 +: 16] = v; end
  endtask
  task tl_load(input integer eoff);
    integer k, b;
    begin
      for (k = 0; k < NN; k = k + 1) begin
        b = eoff + k*12;
        tl_put16(b+0,  ent_sx[k][15:0]); tl_put16(b+2,  ent_sy[k][15:0]);
        tl_put16(b+4,  ent_w [k][15:0]); tl_put16(b+6,  ent_h [k][15:0]);
        tl_put16(b+8,  ent_dx[k][15:0]); tl_put16(b+10, ent_dy[k][15:0]);
      end
    end
  endtask

  // ---- command-ring helpers (verbatim from tb_bgplane_equivalence.sv) ----
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

  // FILL at ring slot `slot` (verbatim from tb_bgplane_equivalence.sv)
  task wr_fill(input integer slot, input [7:0] flags, input [15:0] dx, input [15:0] dy,
               input [15:0] w, input [15:0] h, input [15:0] color);
    integer base;
    begin
      base = RINGB + slot*4;
      mem[base+0] = {32'd0, flags, 8'd0, 8'd0, 8'd2};   // opcode=FILL(2)
      mem[base+1] = {h, w, 32'd0};
      mem[base+2] = {dy, dx, 32'd0};
      mem[base+3] = {16'd0, color, 32'd0};
    end
  endtask

  // PAL8 OP_TILELIST header at ring slot0 + END at slot4; color = pal_id/base_off
  // (field layout verbatim from tb_pal8_tilelist.sv wr_tilelist).
  task wr_tilelist_pal8(input [31:0] src_off, input [7:0] blend, input [7:0] flags,
                        input [15:0] stride, input [15:0] color, input [31:0] eoff,
                        input signed [15:0] bias_x, input signed [15:0] bias_y);
    begin
      mem[RINGB+0] = {src_off, {flags, `COMP_PAL8, blend, 8'd5}};     // op=TILELIST(5), src_off
      mem[RINGB+1] = {NN[31:0], {bias_x, stride}};
      mem[RINGB+2] = {eoff, {16'd0, bias_y}};
      mem[RINGB+3] = {{16'd0, color}, {8'd0, 8'd0, 16'd0}};           // u32[7][15:0]=color (c_color)
      mem[RINGB+4] = 64'd1;                                           // END
    end
  endtask

  // OP_BGPLANE_WRITE with explicit flags (verbatim from tb_bgplane_equivalence.sv)
  task wr_bgw_flags(input [7:0] flags, input [31:0] base_qw, input [15:0] stride_qw);
    begin
      mem[RINGB+0] = {32'd0, flags, 8'd0, 8'd0, OP_BGPLANE_WRITE};
      mem[RINGB+1] = {32'd0, stride_qw, 16'd0};
      mem[RINGB+2] = {base_qw[31:16], base_qw[15:0], 32'd0};
      mem[RINGB+3] = 64'd0;
      mem[RINGB+4] = 64'd1;                                           // END
    end
  endtask

  // PALPHA readback BLIT (verbatim from tb_bgplane_equivalence.sv) -- reads the baked
  // plane through P_SRC, respecting the plane's per-pixel alpha (opaque overwrite,
  // transparent skip), exactly as resident_emit_static_layer's host-side COPY does.
  task wr_blit_palpha(input [31:0] src_off, input [15:0] stride,
                      input [15:0] w, input [15:0] h,
                      input [15:0] dst_x, input [15:0] dst_y);
    begin
      mem[RINGB+0] = {src_off, 8'd0, 8'd1, 8'd3, 8'd3};   // op=BLIT(3) blend=PALPHA(3) fmt=ARGB4444(1)
      mem[RINGB+1] = {h, w, 16'd0, stride};
      mem[RINGB+2] = {dst_y, dst_x, 16'd0, 16'd0};
      mem[RINGB+3] = 64'd0;
      mem[RINGB+4] = 64'd1;                                // END
    end
  endtask

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

  // vs-edge + coh_busy drain (verbatim from tb_bgplane_equivalence.sv)
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

  // read a composited pixel from comp_fbram WORK (verbatim from tb_bgplane_equivalence.sv)
  function [15:0] getpx(input integer dx, input integer dy);
    integer idx;
    begin
      idx = dy*80 + (dx>>2);
      getpx = ((dx&3)==0)?fbram.bank0[idx]:((dx&3)==1)?fbram.bank1[idx]:
              ((dx&3)==2)?fbram.bank2[idx]:fbram.bank3[idx];
    end
  endfunction

  // ARGB4444 round-trip of a FULLY-OPAQUE RGB565 pixel (verbatim from
  // tb_bgplane_equivalence.sv) -- the plane stores RGB truncated to 4 bits/channel,
  // so the opaque readback equals this, NOT the raw CLUT RGB565.
  function automatic [15:0] expect_palpha_roundtrip(input [15:0] rgb565);
    reg [3:0] r4, g4, b4;
    begin
      r4 = rgb565[15:12]; g4 = rgb565[10:7]; b4 = rgb565[4:1];
      expect_palpha_roundtrip = {r4, r4[3], g4, g4[3:2], b4, b4[3]};
    end
  endfunction

  integer xx, yy, mism;
  reg [15:0] got, exp;

  initial begin
    for (i = 0; i < MEMQW; i = i + 1)   mem[i]   = 64'd0;
    for (i = 0; i < TL_SPAN; i = i + 1) tlmem[i] = 64'd0;
    mem[32'h200000] = 64'd0; mem[32'h200005] = 64'd0;

    seed_pal8_src;
    seed_clut;
    ent_sx[0]=0; ent_sy[0]=0; ent_w[0]=KTW; ent_h[0]=KTH; ent_dx[0]=0; ent_dy[0]=0;
    tl_load(32'd0);

    repeat (8) @(posedge clk); rst <= 0;
    begin : wait_init
      integer wi;
      for (wi = 0; wi < 30000; wi = wi + 1) begin
        @(posedge clk);
        if (!u_cache.init) disable wait_init;
      end
    end
    repeat (4) @(posedge clk);

    // ---- submit 0: BLT_OP_CLUT_UPLOAD (load clut_mem -> fabric clut_bram) ----
    mem[32'h200001]=64'd2;                 // cmd_count = CLUT_UPLOAD + END
    mem[32'h200002]=64'd0; mem[32'h200003]=64'd0; mem[32'h200004]=64'd0; mem[32'h200007]=64'd0;
    mem[RINGB+0] = {32'd0, {8'd0, 8'd0, 8'd0, 8'(`BLT_OP_CLUT_UPLOAD)}};
    mem[RINGB+1] = {NENT[31:0], 32'd0};    // u32[3]=count-low ; NENT<65536 so high=0
    mem[RINGB+2] = 64'd0;
    mem[RINGB+3] = 64'd0;
    mem[RINGB+4] = 64'd1;                  // END
    run_submit;

    // ==== BAKE the PAL8 tile into the plane ====
    // (1) clear WORK RGB (flags=0) then clear coverage (flags=BLT_F_BGCOV=0x80) --
    //     the #102 order; no CLEAR flag on set_ctrl (would re-cover the whole cell).
    set_ctrl(3, 0);
    wr_fill(0, 8'd0,  16'd0, 16'd0, 16'd320, 16'd240, 16'd0);     // WORK RGB clear
    wr_fill(1, 8'h80, 16'd0, 16'd0, 16'd320, 16'd240, 16'd0);     // BLT_F_BGCOV coverage clear
    mem[RINGB + 2*4] = 64'd1;                                      // END
    run_submit;

    // (2) PAL8 tile-list paint into WORK (blend=PALPHA, fmt=COMP_PAL8, color=pal_id/base).
    //     Motif index (a4=F) -> opaque write + coverage=1; surround (a4=0) -> skip.
    set_ctrl(2, 0);
    wr_tilelist_pal8(PAL_SRC_BASE_QW*8, 8'd3, 8'd0, 16'(PAL_TSTRIDE), PAL_COLOR, 32'd0, 16'sd0, 16'sd0);
    run_submit;

    // (3) OP_BGPLANE_WRITE (BLT_F_BGCOV / ARGB4444 pack) -> plane, then flush to SDRAM.
    set_ctrl(2, 0);
    wr_bgw_flags(8'h80, PAL_PLANE_BASE_QW, PLANE_STRIDE_QW[15:0]);
    run_submit;
    flush_to_sdram;

    // ==== READBACK: paint a lower layer, then PALPHA-read the plane over it ====
    set_ctrl(2, 0);
    wr_fill(0, 8'd0, 16'd0, 16'd0, 16'd320, 16'd240, KEY_LOWER);
    mem[RINGB + 1*4] = 64'd1;                                      // END
    run_submit;

    set_ctrl(2, 0);
    wr_blit_palpha(PAL_PLANE_BASE_QW*8, PLANE_STRIDE_QW[15:0]*8, 16'd320, 16'd240, 16'd0, 16'd0);
    run_submit;

    // ==== verify [0,KTW) x [0,KTH): motif = CLUT RGB (ARGB4444 round-trip), surround = lower ====
    mism = 0;
    for (yy = 0; yy < KTH; yy = yy + 1) for (xx = 0; xx < KTW; xx = xx + 1) begin
      exp = is_motif(xx, yy) ? expect_palpha_roundtrip(OP_RGB) : KEY_LOWER;
      got = getpx(xx, yy);
      if (got !== exp) begin
        if (mism < 12) $display("  PAL8-BGPLANE MISMATCH (%0d,%0d): exp=%h got=%h", xx, yy, exp, got);
        mism = mism + 1;
      end
    end
    if (mism == 0) $display("PAL8-BGPLANE bake==CLUT: RESULT: PASS (%0d px, bank %0d)", KTW*KTH, PAL_ID);
    else           $display("PAL8-BGPLANE bake==CLUT: FAIL (%0d mismatches)", mism);
    $finish;
  end

  initial begin #800000000 $display("PAL8-BGPLANE: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire
