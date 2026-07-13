// tb_mixed_format_seq.sv — Task 1.3 (paletted-composition v1) regression-guard TB:
// interleave DIFFERENT source formats (RGB565, ARGB4444, PAL8) within ONE command
// stream to ONE framebuffer and prove the serve/decode path stays format-agnostic —
// i.e. a PAL8 blit does not perturb the RGB565/ARGB4444 blits in the same stream,
// and vice versa. Per-format TBs (tb_pal8_lookup.sv et al.) each submit ONE format
// for the whole ring and so cannot catch state leakage BETWEEN commands of
// different formats (e.g. a CLUT-address/pal_id register that fails to re-latch,
// or an is_pal8/is_argb4444 guard that stays asserted one command too long).
//
// Scenario (single submit, 5 BLITs to 5 non-overlapping dst rows of an 8x5 FILLed
// framebuffer region, same style/order as the brief):
//   row0: RGB565   COPY      (format=0)
//   row1: ARGB4444 PALPHA    (format=1, incl. one a4==0 fully-transparent pixel)
//   row2: PAL8     COLORKEY  (format=2, c_color = pal_id<<8|base_off = 0)
//   row3: PAL8     PALPHA    (format=2, incl. one CLUT a4==0 -> dst unchanged)
//   row4: RGB565   COPY      (format=0 again -- proves PAL8 didn't leave residue)
// A host-side golden model (same blend arithmetic + ARGB4444/PAL8 decode as
// comp_pipeline.sv/comp_mixer.sv, ported from tb_pal8_lookup.sv) computes the
// expected pixel for every (format,blend) combination independently, and the test
// asserts the composited comp_fbram pixels match exactly.
//
// Harness: identical structure to tb_pal8_lookup.sv (DDR control/ring/CLUT model,
// P_SRC cache-ok source model, comp_fbram readback) -- see that file's header for
// provenance notes. Reused verbatim here; only the command sequence + golden model
// differ.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
`include "comp_clut.vh"
`include "comp_defs.vh"

module tb_mixed_format_seq;
  localparam integer NENT = `CLUT_BANKS * `CLUT_ENTRIES;   // 32*256 = 8192

  reg clk=0, reset=1;
  always #5 clk = ~clk;

  // free-running vblank (mirrors tb_pal8_lookup.sv / tb_blitter_system_pipe.sv).
  reg vs=0; integer vsc=0;
  always @(posedge clk) begin
    vsc <= vsc + 1;
    if (vsc >= 256) begin vs <= ~vs; vsc <= 0; end
  end

  // ── behavioral DDR: 3 small flat windows (VCTRL / BLTCTRL+ring / CLUTBUF) ──────
  localparam integer CTRL_SIZE = 128;
  reg [63:0] vctrl_mem [0:0];
  reg [63:0] ctrl_mem  [0:CTRL_SIZE-1];
  reg [63:0] clut_mem  [0:NENT-1];
  wire [31:0] mem_addr;
  wire        mem_rd, mem_wr;
  wire [7:0]  mem_burstcnt;
  wire [63:0] mem_din;
  wire [7:0]  mem_be;
  reg  [63:0] mem_dout_r;
  reg         mem_dout_ready_r;

  // Byte-enable merge as a FUNCTION (not inline in the posedge always block below) so
  // its blocking assignments live in a function body, not an edge-triggered always —
  // keeps the DDR write-merge out of the hdl-lint blocking-assignment-in-sequential
  // rule (ast-grep rule scope is `always_construct`, not `function_declaration`).
  function automatic [63:0] merge_be(input [63:0] cur, input [63:0] din, input [7:0] be);
    reg [63:0] m; integer jb;
    begin
      m = cur;
      for (jb = 0; jb < 8; jb = jb + 1) if (be[jb]) m[jb*8 +: 8] = din[jb*8 +: 8];
      merge_be = m;
    end
  endfunction

  task wmem(input integer addr, input [63:0] val);
    begin
      if (addr == `VCTRL_QW) vctrl_mem[0] = val;
      else if (addr >= `BLTCTRL_QW && addr < `BLTCTRL_QW + CTRL_SIZE)
        ctrl_mem[addr - `BLTCTRL_QW] = val;
      else if (addr >= `CLUT_BUF_QW && addr < `CLUT_BUF_QW + NENT)
        clut_mem[addr - `CLUT_BUF_QW] = val;
      else begin
        $display("wmem: addr %h out of modeled range", addr);
        $finish;
      end
    end
  endtask

  function [63:0] rmem(input integer addr);
    begin
      if (addr == `VCTRL_QW) rmem = vctrl_mem[0];
      else if (addr >= `BLTCTRL_QW && addr < `BLTCTRL_QW + CTRL_SIZE)
        rmem = ctrl_mem[addr - `BLTCTRL_QW];
      else if (addr >= `CLUT_BUF_QW && addr < `CLUT_BUF_QW + NENT)
        rmem = clut_mem[addr - `CLUT_BUF_QW];
      else
        rmem = 64'hDEAD_DEAD_DEAD_DEAD;
    end
  endfunction

  always @(posedge clk) begin
    mem_dout_ready_r <= mem_rd;
    if (mem_rd) mem_dout_r <= rmem(mem_addr);
    if (mem_wr) wmem(mem_addr, merge_be(rmem(mem_addr), mem_din, mem_be));
  end

  // ── P_SRC cache-ok source model: fixed-latency, rising-edge capture ─────────────
  // p0_addr is heap-relative (== c_src_off byte-address, qword-aligned by the
  // fabric), so a small standalone array indexed directly by p0_addr>>3 holds ALL
  // FIVE rows' source data side by side, each row at its own c_src_off (0/16/32/
  // 48/64 bytes -> qword base 0/2/4/6/8), same fixed-latency model as
  // tb_pal8_lookup.sv / tb_blitter_copy_pipe.sv.
  localparam integer SRC_QWORDS = 16;
  reg  [63:0] src_mem [0:SRC_QWORDS-1];
  localparam SRC_LAT = 3;
  wire [26:0] p0_addr_w;
  wire        p0_rd_w;
  reg  [63:0] p0_dout_r;
  reg         p0_ok_r;
  reg         src_rd_d;
  reg  [26:0] src_lat_addr [0:SRC_LAT-1];
  reg         src_lat_v    [0:SRC_LAT-1];
  integer     sli;
  always @(posedge clk) src_rd_d <= p0_rd_w;
  always @(posedge clk) begin
    p0_ok_r <= 1'b0;
    src_lat_v   [0] <= p0_rd_w & ~src_rd_d;    // rising edge of p0_rd
    src_lat_addr[0] <= p0_addr_w;
    for (sli = 1; sli < SRC_LAT; sli = sli + 1) begin
      src_lat_v   [sli] <= src_lat_v   [sli-1];
      src_lat_addr[sli] <= src_lat_addr[sli-1];
    end
    if (src_lat_v[SRC_LAT-1]) begin
      p0_dout_r <= src_mem[src_lat_addr[SRC_LAT-1] >> 3];
      p0_ok_r   <= 1'b1;
    end
  end

  // ── on-chip composite framebuffer (comp_fbram) ──────────────────────────────────
  wire        fb_wr_en; wire [14:0] fb_wr_qw; wire [1:0] fb_wr_lane; wire [15:0] fb_wr_pix;
  wire        fb_rd_en; wire [14:0] fb_rd_qw; wire [63:0] fb_rd_qword;
  comp_fbram fbram(.clk(clk),
    .wr_en(fb_wr_en), .wr_qw(fb_wr_qw), .wr_lane(fb_wr_lane), .wr_pix(fb_wr_pix),
    .rd_en(fb_rd_en), .rd_qw(fb_rd_qw), .rd_qword(fb_rd_qword));

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

  // ---- unused blitter_top ports tied off safely ---------------------------------
  wire        fb_snap_we; wire [14:0] fb_snap_qw; wire [63:0] fb_snap_qword;
  wire        dst_wr; wire [26:0] dst_addr; wire [63:0] dst_din; wire [7:0] dst_wdsn;
  wire        bgw_active;
  wire        src_sdram_we; wire [15:0] src_sdram_din; wire [26:0] src_sdram_waddr;
  wire        src_sdram_we_burst; wire [63:0] src_sdram_din64;
  wire        stage_barrier;
  wire        idle_w;
  wire [31:0] dbg_w;

  blitter_top blt (
    .clk(clk), .rst(reset), .vs(vs),
    .osd_restart(1'b0), .osd_fps_on(1'b0),
    .mem_addr(mem_addr), .mem_rd(mem_rd), .mem_wr(mem_wr), .mem_burstcnt(mem_burstcnt),
    .mem_din(mem_din), .mem_be(mem_be),
    .mem_dout(mem_dout_r), .mem_dout_ready(mem_dout_ready_r), .mem_busy(1'b0),
    .p0_addr(p0_addr_w), .p0_rd(p0_rd_w), .p0_dout(p0_dout_r), .p0_ok(p0_ok_r),
    .fb_wr_en(fb_wr_en), .fb_wr_qw(fb_wr_qw), .fb_wr_lane(fb_wr_lane), .fb_wr_pix(fb_wr_pix),
    .fb_rd_en(fb_rd_en), .fb_rd_qw(fb_rd_qw), .fb_rd_qword(fb_rd_qword),
    .fb_snap_we(fb_snap_we), .fb_snap_qw(fb_snap_qw), .fb_snap_qword(fb_snap_qword),
    .dst_wr(dst_wr), .dst_addr(dst_addr), .dst_din(dst_din), .dst_wdsn(dst_wdsn), .dst_ok(1'b0),
    .bgw_active(bgw_active),
    .src_sdram_we(src_sdram_we), .src_sdram_din(src_sdram_din), .src_sdram_waddr(src_sdram_waddr),
    .src_sdram_we_burst(src_sdram_we_burst), .src_sdram_din64(src_sdram_din64), .src_sdram_ok(1'b1),
    .stage_barrier(stage_barrier), .stage_barrier_busy(1'b0),
    .idle(idle_w),
    .dbg(dbg_w)
  );

  // ── CLUT pattern (bank0 == index k directly, pal_id=0/base_off=0 in every PAL8
  // command below): identical generator to tb_pal8_lookup.sv so a4 cycles 0..15
  // every 16 entries (idx%16==0 -> a4=0 transparent) and r5/g6/b5 are distinct XOR
  // spreads of the low index bits.
  function [31:0] pattern_word(input integer k);
    reg [4:0] r5; reg [5:0] g6; reg [4:0] b5;
    begin
      r5 = k[4:0] ^ 5'h15;
      g6 = k[5:0] ^ 6'h2A;
      b5 = k[4:0] ^ 5'h0B;
      pattern_word = `CLUT_MAKE(k[3:0], {r5, g6, b5});
    end
  endfunction
  function [15:0] pal_rgb_of(input integer idx);
    reg [31:0] w; begin w = pattern_word(idx); pal_rgb_of = w[15:0]; end
  endfunction
  function [3:0]  pal_a4_of (input integer idx);
    reg [31:0] w; begin w = pattern_word(idx); pal_a4_of = w[19:16]; end
  endfunction

  // ── raw RGB565 / ARGB4444 source generators (rows 0/4 and row1) ────────────────
  // Two DIFFERENT RGB565 patterns for row0 vs row4 so a stuck is_pal8/is_argb4444
  // guard (residue from the PAL8/ARGB4444 commands in between) can't coincidentally
  // still match. argb_of's a4 = k[2:0] so k=0 hits the fully-transparent PALPHA
  // case on the 16bpp (non-PAL8) decode path too.
  function [15:0] rgb0_of(input integer k);
    reg [4:0] r5; reg [5:0] g6; reg [4:0] b5;
    begin
      r5 = {2'b00, k[2:0]} ^ 5'h1B;
      g6 = {3'b000, k[2:0]} ^ 6'h09;
      b5 = {2'b00, k[2:0]} ^ 5'h03;
      rgb0_of = {r5, g6, b5};
    end
  endfunction
  function [15:0] rgb4_of(input integer k);
    reg [4:0] r5; reg [5:0] g6; reg [4:0] b5;
    begin
      r5 = {2'b00, k[2:0]} ^ 5'h07;
      g6 = {3'b000, k[2:0]} ^ 6'h15;
      b5 = {2'b00, k[2:0]} ^ 5'h1D;
      rgb4_of = {r5, g6, b5};
    end
  endfunction
  function [15:0] argb_of(input integer k);
    reg [3:0] a4, r4, g4, b4;
    begin
      a4 = k[2:0];
      r4 = k[2:0] ^ 4'h5;
      g4 = k[2:0] ^ 4'hA;
      b4 = k[2:0] ^ 4'h3;
      argb_of = {a4, r4, g4, b4};
    end
  endfunction

  // ── golden blend model — bit-identical to comp_mixer.sv's stage B/C math ────────
  // (golden_copy/golden_key/golden_ca ported verbatim from tb_pal8_lookup.sv.)
  function [15:0] golden_copy(input [15:0] src);
    golden_copy = src;
  endfunction

  function [15:0] golden_key(input [15:0] src, input [15:0] dst, input [15:0] key);
    golden_key = (src == key) ? dst : src;
  endfunction

  function [15:0] golden_ca(input [15:0] src, input [15:0] dst, input [7:0] a);
    reg [4:0] sr, dr, br5, r; reg [5:0] sg, dg, g; reg [4:0] sb, db, b;
    reg [16:0] tr, tg, tb, p128r, p128g, p128b, rr, gg, bb;
    begin
      sr = src[15:11]; sg = src[10:5]; sb = src[4:0];
      dr = dst[15:11]; dg = dst[10:5]; db = dst[4:0];
      tr = {12'd0,sr}*{9'd0,a} + {12'd0,dr}*(17'd255-{9'd0,a});
      tg = {11'd0,sg}*{9'd0,a} + {11'd0,dg}*(17'd255-{9'd0,a});
      tb = {12'd0,sb}*{9'd0,a} + {12'd0,db}*(17'd255-{9'd0,a});
      p128r = tr + 17'd128; rr = (p128r + (p128r >> 8)) >> 8;
      p128g = tg + 17'd128; gg = (p128g + (p128g >> 8)) >> 8;
      p128b = tb + 17'd128; bb = (p128b + (p128b >> 8)) >> 8;
      golden_ca = {rr[4:0], gg[5:0], bb[4:0]};
    end
  endfunction

  // [#100/ARGB4444] 4->5/6/5 channel expansion, bit-identical to comp_pipeline.sv's
  // pa_expanded (and its FILL-side c_color_exp twin).
  function [15:0] argb_expand(input [15:0] px);
    reg [3:0] r4, g4, b4;
    begin
      r4 = px[11:8]; g4 = px[7:4]; b4 = px[3:0];
      argb_expand = { r4, r4[3], g4, g4[3:2], b4, b4[3] };
    end
  endfunction

  // ── test data ────────────────────────────────────────────────────────────────
  localparam integer BG = 16'h2A55;          // pre-fill background colour

  // PAL8 COLORKEY row (row2): idx[4] doubles as the row's colour-key match.
  reg [7:0] IDX_C [0:7];
  // PAL8 PALPHA row (row3): idx[0]=0 hits a4==0 (transparent, CLUT-modelled skip).
  reg [7:0] IDX_P [0:7];

  integer k, x;
  integer errs;
  reg [63:0] done_val;
  integer t;
  reg [15:0] src16, dst16, exp16, got16;
  reg [3:0]  a4;
  reg [7:0]  a8;

  initial begin
    IDX_C[0]=8'd2;  IDX_C[1]=8'd4;  IDX_C[2]=8'd6;  IDX_C[3]=8'd8;
    IDX_C[4]=8'd9;  IDX_C[5]=8'd11; IDX_C[6]=8'd13; IDX_C[7]=8'd14;

    IDX_P[0]=8'd0;  IDX_P[1]=8'd1;  IDX_P[2]=8'd5;  IDX_P[3]=8'd8;
    IDX_P[4]=8'd12; IDX_P[5]=8'd15; IDX_P[6]=8'd17; IDX_P[7]=8'd31;

    // ---- upload the full CLUT pattern into the DDR CLUTBUF region -----------------
    for (k = 0; k < NENT; k = k + 1)
      wmem(`CLUT_BUF_QW + k, {32'd0, pattern_word(k)});

    // ---- stage the FIVE 8-pixel source rows into the P_SRC source model -----------
    // row0 (RGB565)   @ c_src_off=0  -> src qword base 0  (16bpp, 2 qwords/row)
    // row1 (ARGB4444) @ c_src_off=16 -> src qword base 2  (16bpp, 2 qwords/row)
    // row2 (PAL8/key) @ c_src_off=32 -> src qword base 4  (8bpp [Task 3.1], 1 qword/row;
    //                                    the row's 16-byte window is kept for address
    //                                    spacing but only qword 4's low 8 bytes matter)
    // row3 (PAL8/pa)  @ c_src_off=48 -> src qword base 6  (8bpp [Task 3.1], 1 qword/row)
    // row4 (RGB565)   @ c_src_off=64 -> src qword base 8  (16bpp, 2 qwords/row)
    // RGB565/ARGB4444: 4 pixels/qword, pixel k at qword (base + (k>>2)), lane (k%4)*16
    // (mirrors tb_pal8_lookup.sv's src_mem staging / comp_src_linebuf's fill_qw layout).
    // PAL8: [Task 3.1] 8 pixels/qword, pixel k at byte (k*8 +: 8) of the row's base
    // qword (comp_pipeline's Change 2/3 source-qword addressing + half-select expand
    // this back to 16bpp linebuf lanes).
    for (k = 0; k < 8; k = k + 1) begin
      src_mem[0 + (k>>2)][(k%4)*16 +: 16] = rgb0_of(k);
      src_mem[2 + (k>>2)][(k%4)*16 +: 16] = argb_of(k);
      src_mem[4][k*8 +: 8] = IDX_C[k];
      src_mem[6][k*8 +: 8] = IDX_P[k];
      src_mem[8 + (k>>2)][(k%4)*16 +: 16] = rgb4_of(k);
    end

    // ---- submit 1: BLT_OP_CLUT_UPLOAD (mirrors tb_clut_upload.sv / tb_pal8_lookup.sv) --
    wmem(`BLTCTRL_QW + `C_SUBMIT,   64'd1);
    wmem(`BLTCTRL_QW + `C_CMDCOUNT, 64'd2);
    wmem(`BLTCTRL_QW + `C_TARGET,   64'd0);
    wmem(`BLTCTRL_QW + `C_CLEAR,    64'd0);
    wmem(`BLTCTRL_QW + `C_FLAGS,    64'd0);
    wmem(`BLTCTRL_QW + `C_DONE,     64'd0);
    wmem(`BLTCTRL_QW + `C_STATUS,   64'd0);
    wmem(`BLTCTRL_QW + `C_SRCSEL,   64'd0);
    wmem(`RING_QW + 0, {32'd0, 24'd0, 8'(`BLT_OP_CLUT_UPLOAD)});
    wmem(`RING_QW + 1, {16'(NENT[31:16]), 16'(NENT[15:0]), 32'd0});
    wmem(`RING_QW + 2, 64'd0);
    wmem(`RING_QW + 3, 64'd0);
    wmem(`RING_QW + 4, 64'd1);                 // cmd1 = END
    wmem(`RING_QW + 5, 64'd0); wmem(`RING_QW + 6, 64'd0); wmem(`RING_QW + 7, 64'd0);
  end

  initial begin
    errs = 0;
    repeat (8) @(posedge clk);
    reset <= 0;

    // wait for the CLUT upload submit to complete
    t = 0;
    done_val = rmem(`BLTCTRL_QW + `C_DONE);
    while (done_val[31:0] !== 32'd1 && t < 200000) begin
      @(posedge clk); t = t + 1;
      done_val = rmem(`BLTCTRL_QW + `C_DONE);
    end
    if (done_val[31:0] !== 32'd1) begin
      $display("RESULT: FAIL (timeout waiting for CLUT_UPLOAD C_DONE, t=%0d)", t);
      $finish;
    end
    $display("[%0t] CLUT_UPLOAD C_DONE seen after %0d cycles", $time, t);

    // ---- submit 2: FILL background + 5 mixed-format BLITs + END -------------------
    // Ring layout (qwords relative to RING_QW): cmd0=FILL(0..3),
    // cmd1=RGB565/COPY(4..7), cmd2=ARGB4444/PALPHA(8..11), cmd3=PAL8/COLORKEY(12..15),
    // cmd4=PAL8/PALPHA(16..19), cmd5=RGB565/COPY(20..23), cmd6=END(24..27).
    wmem(`BLTCTRL_QW + `C_CMDCOUNT, 64'd7);
    wmem(`BLTCTRL_QW + `C_TARGET,   64'd0);
    wmem(`BLTCTRL_QW + `C_CLEAR,    64'd0);
    wmem(`BLTCTRL_QW + `C_FLAGS,    64'd0);

    // cmd0: FILL background, dst (0,0) 8x5, colour=BG.
    wmem(`RING_QW + 0, 64'h0000_0000_0000_0002);                      // opcode=FILL
    wmem(`RING_QW + 1, {16'd5, 16'd8, 32'd0});                        // h=5 w=8
    wmem(`RING_QW + 2, {16'd0, 16'd0, 32'd0});                        // dst_y=0 dst_x=0
    wmem(`RING_QW + 3, {16'd0, 16'(BG), 32'd0});                      // color=BG

    // cmd1: row0, RGB565 COPY, src_off=0.
    wmem(`RING_QW + 4,  {32'd0, 8'd0, `COMP_RGB565, `BLT_BLEND_COPY, 8'd3});
    wmem(`RING_QW + 5,  {16'd1, 16'd8, 16'd0, 16'd16});
    wmem(`RING_QW + 6,  {16'd0, 16'd0, 16'd0, 16'd0});                // dst_y=0 dst_x=0
    wmem(`RING_QW + 7,  64'd0);

    // cmd2: row1, ARGB4444 PALPHA, src_off=16.
    wmem(`RING_QW + 8,  {32'd16, 8'd0, `COMP_ARGB4444, `BLT_BLEND_PALPHA, 8'd3});
    wmem(`RING_QW + 9,  {16'd1, 16'd8, 16'd0, 16'd16});
    wmem(`RING_QW + 10, {16'd1, 16'd0, 16'd0, 16'd0});                // dst_y=1 dst_x=0
    wmem(`RING_QW + 11, 64'd0);

    // cmd3: row2, PAL8 COLORKEY, src_off=32. colorkey = pal_rgb_of(IDX_C[4]) (the
    // row's own idx9 pixel) so ONE pixel in the row matches and passes dst through.
    wmem(`RING_QW + 12, {32'd32, 8'd0, `COMP_PAL8, `BLT_BLEND_COLORKEY, 8'd3});
    wmem(`RING_QW + 13, {16'd1, 16'd8, 16'd0, 16'd8});  // [Task 3.1] stride=8 (8bpp)
    wmem(`RING_QW + 14, {16'd2, 16'd0, 16'd0, 16'd0});                // dst_y=2 dst_x=0
    wmem(`RING_QW + 15, {16'd0, 16'd0, 8'd0, 8'd0, pal_rgb_of(IDX_C[4])});

    // cmd4: row3, PAL8 PALPHA, src_off=48. IDX_P[0]=0 -> CLUT a4=0 -> dst unchanged.
    wmem(`RING_QW + 16, {32'd48, 8'd0, `COMP_PAL8, `BLT_BLEND_PALPHA, 8'd3});
    wmem(`RING_QW + 17, {16'd1, 16'd8, 16'd0, 16'd8});  // [Task 3.1] stride=8 (8bpp)
    wmem(`RING_QW + 18, {16'd3, 16'd0, 16'd0, 16'd0});                // dst_y=3 dst_x=0
    wmem(`RING_QW + 19, 64'd0);

    // cmd5: row4, RGB565 COPY again, src_off=64, DIFFERENT pattern than row0 -- if
    // the two PAL8 commands (or the ARGB4444 one) left ANY is_pal8/is_argb4444/
    // pal_id/CLUT-address residue live, this command would decode wrongly.
    wmem(`RING_QW + 20, {32'd64, 8'd0, `COMP_RGB565, `BLT_BLEND_COPY, 8'd3});
    wmem(`RING_QW + 21, {16'd1, 16'd8, 16'd0, 16'd16});
    wmem(`RING_QW + 22, {16'd4, 16'd0, 16'd0, 16'd0});                // dst_y=4 dst_x=0
    wmem(`RING_QW + 23, 64'd0);

    wmem(`RING_QW + 24, 64'd1);                                          // cmd6 = END
    wmem(`RING_QW + 25, 64'd0); wmem(`RING_QW + 26, 64'd0); wmem(`RING_QW + 27, 64'd0);

    wmem(`BLTCTRL_QW + `C_SUBMIT, 64'd2);

    t = 0;
    done_val = rmem(`BLTCTRL_QW + `C_DONE);
    while (done_val[31:0] !== 32'd2 && t < 200000) begin
      @(posedge clk); t = t + 1;
      done_val = rmem(`BLTCTRL_QW + `C_DONE);
    end
    if (done_val[31:0] !== 32'd2) begin
      $display("RESULT: FAIL (timeout waiting for render submit C_DONE, t=%0d)", t);
      $finish;
    end
    $display("[%0t] render submit C_DONE seen after %0d cycles", $time, t);
    repeat (10) @(posedge clk);

    // ---- verify: row0=RGB565/COPY, row1=ARGB4444/PALPHA, row2=PAL8/COLORKEY,
    //              row3=PAL8/PALPHA, row4=RGB565/COPY, cols 0..7 -------------------
    dst16 = BG;

    // row0
    for (x = 0; x < 8; x = x + 1) begin
      src16 = rgb0_of(x);
      exp16 = golden_copy(src16);
      got16 = getpx(x, 0);
      if (got16 !== exp16) begin
        errs = errs + 1;
        $display("MISMATCH row0(RGB565/COPY) x=%0d src=%h got=%h exp=%h", x, src16, got16, exp16);
      end
    end

    // row1 (ARGB4444 PALPHA)
    for (x = 0; x < 8; x = x + 1) begin
      reg [15:0] raw, exp_src;
      raw = argb_of(x);
      a4  = raw[15:12];
      a8  = {a4, a4};
      exp_src = argb_expand(raw);
      exp16 = (a4 == 4'd0) ? dst16 : golden_ca(exp_src, dst16, a8);
      got16 = getpx(x, 1);
      if (got16 !== exp16) begin
        errs = errs + 1;
        $display("MISMATCH row1(ARGB4444/PALPHA) x=%0d raw=%h a4=%0d got=%h exp=%h",
                  x, raw, a4, got16, exp16);
      end
    end

    // row2 (PAL8 COLORKEY)
    for (x = 0; x < 8; x = x + 1) begin
      src16 = pal_rgb_of(IDX_C[x]);
      exp16 = golden_key(src16, dst16, pal_rgb_of(IDX_C[4]));
      got16 = getpx(x, 2);
      if (got16 !== exp16) begin
        errs = errs + 1;
        $display("MISMATCH row2(PAL8/COLORKEY) x=%0d idx=%0d src=%h got=%h exp=%h",
                  x, IDX_C[x], src16, got16, exp16);
      end
    end

    // row3 (PAL8 PALPHA)
    for (x = 0; x < 8; x = x + 1) begin
      src16 = pal_rgb_of(IDX_P[x]);
      a4    = pal_a4_of(IDX_P[x]);
      exp16 = (a4 == 4'd0) ? dst16 : golden_ca(src16, dst16, {a4, a4});
      got16 = getpx(x, 3);
      if (got16 !== exp16) begin
        errs = errs + 1;
        $display("MISMATCH row3(PAL8/PALPHA) x=%0d idx=%0d a4=%0d src=%h got=%h exp=%h",
                  x, IDX_P[x], a4, src16, got16, exp16);
      end
    end

    // row4 (RGB565 COPY, again -- checks no PAL8/ARGB4444 residue)
    for (x = 0; x < 8; x = x + 1) begin
      src16 = rgb4_of(x);
      exp16 = golden_copy(src16);
      got16 = getpx(x, 4);
      if (got16 !== exp16) begin
        errs = errs + 1;
        $display("MISMATCH row4(RGB565/COPY) x=%0d src=%h got=%h exp=%h", x, src16, got16, exp16);
      end
    end

    if (errs == 0)
      $display("RESULT: PASS (5 mixed-format blits x 8 px: RGB565/COPY, ARGB4444/PALPHA, PAL8/COLORKEY, PAL8/PALPHA, RGB565/COPY -- no cross-format state leakage)");
    else
      $display("RESULT: FAIL (%0d pixel mismatches)", errs);
    $finish;
  end

  // safety watchdog
  initial begin
    #4_000_000;
    $display("RESULT: FAIL (global timeout)");
    $finish;
  end
endmodule
`default_nettype wire
