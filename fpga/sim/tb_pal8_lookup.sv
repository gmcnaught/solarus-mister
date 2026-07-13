// tb_pal8_lookup.sv — Task 1.2 (paletted-composition v1) golden TB: comp_pipeline's
// COMP_PAL8 index -> CLUT -> {A4,RGB565} decode, exercised across every blend mode
// PAL8 supports (COPY, COLORKEY, PALPHA, ADD, MULTIPLY).
//
// Scenario: upload a deterministic CLUT (bank 0, all `CLUT_BANKS*`CLUT_ENTRIES
// entries -- same style as tb_clut_upload) via BLT_OP_CLUT_UPLOAD, stage an 8-pixel
// 16bpp INDEX row in the P_SRC-reachable source heap (index in the low byte, high
// byte 0), pre-fill a 8x5 destination rect with a known background colour, then run
// one BLIT per blend mode (same 8 indices, one dst row each). A host-side golden
// model replays the SAME CLUT decode + the SAME per-mode blend arithmetic as
// comp_mixer.sv (COMP_COPY/COMP_KEY/COMP_CA/COMP_ADD/COMP_MUL) and asserts the
// composited comp_fbram pixels match exactly, including the PALPHA a4==0 (fully
// transparent) "dst unchanged" case.
//
// Harness style: the DDR control/ring/CLUT model is tb_clut_upload's 3-window
// behavioral memory; the P_SRC (cache-ok) source model is the small fixed-latency
// rising-edge-capture pattern proven in tb_blitter_copy_pipe.sv / tb_blitter_
// system_pipe.sv. comp_fbram readback (getpx) mirrors tb_blitter_system_pipe.sv.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
`include "comp_clut.vh"
`include "comp_defs.vh"

module tb_pal8_lookup;
  localparam integer NENT = `CLUT_BANKS * `CLUT_ENTRIES;   // 32*256 = 8192

  reg clk=0, reset=1;
  always #5 clk = ~clk;

  // free-running vblank: a rendered frame (FILL/BLIT, unlike CLUT_UPLOAD) only
  // reaches C_DONE after the vsync-gated work->scan snapshot (S_SNAP_WAIT/BUSY/
  // DRAIN) — mirrors tb_blitter_system_pipe.sv's vs toggle.
  reg vs=0; integer vsc=0;
  always @(posedge clk) begin
    vsc <= vsc + 1;
    if (vsc >= 256) begin vs <= ~vs; vsc <= 0; end
  end

  // ── behavioral DDR: 3 small flat windows (VCTRL / BLTCTRL+ring / CLUTBUF) ──────
  // Same decoded-by-range model as tb_clut_upload.sv; 1-cycle read latency.
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
  integer     jb;

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
        rmem = 64'hDEAD_DEAD_DEAD_DEAD;   // out-of-modeled-range guard value
    end
  endfunction

  // [hdl-lint] byte-enable merge lives in a function so the clocked block below holds
  // only non-blocking assignments (blocking-assignment-in-sequential is a ratchet error).
  function automatic [63:0] merge_be(input [63:0] cur, input [63:0] din, input [7:0] be);
    integer jf;
    begin
      merge_be = cur;
      for (jf = 0; jf < 8; jf = jf + 1)
        if (be[jf]) merge_be[jf*8 +: 8] = din[jf*8 +: 8];
    end
  endfunction
  always @(posedge clk) begin
    mem_dout_ready_r <= mem_rd;
    if (mem_rd) mem_dout_r <= rmem(mem_addr);
    if (mem_wr) wmem(mem_addr, merge_be(rmem(mem_addr), mem_din, mem_be));
  end

  // ── P_SRC cache-ok source model: fixed-latency, rising-edge capture ─────────────
  // p0_addr is heap-relative (driven from c_src_off, NOT the absolute DDR address —
  // see comp_pipeline.sv's gpix0/src_row_base_q), so a small standalone array
  // indexed directly by p0_addr>>3 is sufficient (mirrors tb_blitter_copy_pipe.sv's
  // s_src_* model, minus its SRC_WIN offset into the shared DDR array).
  localparam integer SRC_QWORDS = 4;
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

  // ── on-chip composite framebuffer (comp_fbram) — the real dest [FB-in-BRAM] ─────
  wire        fb_wr_en; wire [14:0] fb_wr_qw; wire [1:0] fb_wr_lane; wire [15:0] fb_wr_pix;
  wire        fb_rd_en; wire [14:0] fb_rd_qw; wire [63:0] fb_rd_qword;
  comp_fbram fbram(.clk(clk),
    .wr_en(fb_wr_en), .wr_qw(fb_wr_qw), .wr_lane(fb_wr_lane), .wr_pix(fb_wr_pix),
    .rd_en(fb_rd_en), .rd_qw(fb_rd_qw), .rd_qword(fb_rd_qword));

  // FB pixel (dx,dy): qword = dy*80 + (dx>>2), lane = dx[1:0] (mirrors
  // tb_blitter_system_pipe.sv's getpx / tb_blitter_copy_pipe.sv's check task).
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
    // P_SRC cache-ok channel: the PAL8 index row is staged here.
    .p0_addr(p0_addr_w), .p0_rd(p0_rd_w), .p0_dout(p0_dout_r), .p0_ok(p0_ok_r),
    // on-chip framebuffer dest port [FB-in-BRAM]
    .fb_wr_en(fb_wr_en), .fb_wr_qw(fb_wr_qw), .fb_wr_lane(fb_wr_lane), .fb_wr_pix(fb_wr_pix),
    .fb_rd_en(fb_rd_en), .fb_rd_qw(fb_rd_qw), .fb_rd_qword(fb_rd_qword),
    .fb_snap_we(fb_snap_we), .fb_snap_qw(fb_snap_qw), .fb_snap_qword(fb_snap_qword),
    // OP_BGPLANE_WRITE ch0 path: never exercised
    .dst_wr(dst_wr), .dst_addr(dst_addr), .dst_din(dst_din), .dst_wdsn(dst_wdsn), .dst_ok(1'b0),
    .bgw_active(bgw_active),
    // OP_STAGE path: never exercised
    .src_sdram_we(src_sdram_we), .src_sdram_din(src_sdram_din), .src_sdram_waddr(src_sdram_waddr),
    .src_sdram_we_burst(src_sdram_we_burst), .src_sdram_din64(src_sdram_din64), .src_sdram_ok(1'b1),
    .stage_barrier(stage_barrier), .stage_barrier_busy(1'b0),
    .idle(idle_w),
    .dbg(dbg_w)
  );

  // ── CLUT pattern: entry k (k = pal_id*CLUT_ENTRIES + index, 0..NENT-1) ──────────
  // a4 cycles 0..15 every 16 entries (so every bank/index run hits BOTH a4=0
  // transparent and a4=15 opaque); r5/g6/b5 are simple XOR spreads of k's low bits
  // so distinct low indices decode to distinct RGB565 (catches channel-position bugs).
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

  // ── golden blend model — bit-identical to comp_mixer.sv's stage B/C math ────────
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

  function [15:0] golden_add(input [15:0] src, input [15:0] dst);
    reg [4:0] sr, dr; reg [5:0] sg, dg; reg [4:0] sb, db;
    reg [16:0] tr, tg, tb; reg [4:0] r, b; reg [5:0] g;
    begin
      sr = src[15:11]; sg = src[10:5]; sb = src[4:0];
      dr = dst[15:11]; dg = dst[10:5]; db = dst[4:0];
      tr = {12'd0,sr} + {12'd0,dr};
      tg = {11'd0,sg} + {11'd0,dg};
      tb = {12'd0,sb} + {12'd0,db};
      r = (tr > 17'd31) ? 5'd31 : tr[4:0];
      g = (tg > 17'd63) ? 6'd63 : tg[5:0];
      b = (tb > 17'd31) ? 5'd31 : tb[4:0];
      golden_add = {r, g, b};
    end
  endfunction

  function [15:0] golden_mul(input [15:0] src, input [15:0] dst);
    reg [4:0] sr, dr; reg [5:0] sg, dg; reg [4:0] sb, db;
    reg [16:0] tr, tg, tb, mr, mg, mb;
    begin
      sr = src[15:11]; sg = src[10:5]; sb = src[4:0];
      dr = dst[15:11]; dg = dst[10:5]; db = dst[4:0];
      tr = {12'd0,sr} * {12'd0,dr};
      tg = {11'd0,sg} * {11'd0,dg};
      tb = {12'd0,sb} * {12'd0,db};
      mr = ((tr + 17'd16) + ((tr + 17'd16) >> 5)) >> 5;
      mg = ((tg + 17'd32) + ((tg + 17'd32) >> 6)) >> 6;
      mb = ((tb + 17'd16) + ((tb + 17'd16) >> 5)) >> 5;
      golden_mul = {mr[4:0], mg[5:0], mb[4:0]};
    end
  endfunction

  // ── test data ────────────────────────────────────────────────────────────────
  // 8-pixel index row (bank0). Spread hits a4=0 (idx0, transparent) and a4=15
  // (idx15, opaque) plus mid-range alphas; idx7 doubles as the COLORKEY match.
  reg [7:0] IDX [0:7];
  localparam integer BG = 16'h39C6;          // pre-fill background colour
  localparam [15:0] KEYVAL_IDX = 8'd7;       // row position whose colour == colorkey

  integer k, m, x;
  integer errs;
  reg [63:0] done_val;
  integer t;
  reg [15:0] src16, dst16, exp16, got16;
  reg [3:0]  a4;

  initial begin
    IDX[0]=8'd0;  IDX[1]=8'd1;  IDX[2]=8'd3;  IDX[3]=8'd5;
    IDX[4]=8'd7;  IDX[5]=8'd10; IDX[6]=8'd12; IDX[7]=8'd15;

    // ---- upload the full CLUT pattern into the DDR CLUTBUF region -----------------
    for (k = 0; k < NENT; k = k + 1)
      wmem(`CLUT_BUF_QW + k, {32'd0, pattern_word(k)});

    // ---- stage the 8-pixel PAL8 index row into the P_SRC source model -------------
    // [PAL8 v1, Task 3.1] PAL8 sources are staged 8bpp (1 B/px, src_stride=width) so
    // comp_pipeline's fill can address them at 1 B/px (was 16bpp/2 B/px pre-Task-3.1).
    // 8 pixels/qword, pixel k at byte (k*8 +: 8) of qword 0 (comp_pipeline's Change 2/3
    // source-qword addressing + half-select expand this back to 16bpp linebuf lanes).
    for (k = 0; k < 8; k = k + 1)
      src_mem[0][k*8 +: 8] = IDX[k];

    // ---- submit 1: BLT_OP_CLUT_UPLOAD (mirrors tb_clut_upload.sv) -----------------
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

    // ---- submit 2: FILL background + one PAL8 BLIT per blend mode + END -----------
    // Ring layout (qwords relative to RING_QW): cmd0=FILL(0..3), cmd1..cmd5=BLIT
    // COPY/COLORKEY/PALPHA/ADD/MULTIPLY (4..23), cmd6=END (24..27).
    wmem(`BLTCTRL_QW + `C_CMDCOUNT, 64'd7);
    wmem(`BLTCTRL_QW + `C_TARGET,   64'd0);
    wmem(`BLTCTRL_QW + `C_CLEAR,    64'd0);
    wmem(`BLTCTRL_QW + `C_FLAGS,    64'd0);

    // cmd0: FILL background, dst (0,0) 8x5, colour=BG.
    wmem(`RING_QW + 0, 64'h0000_0000_0000_0002);                      // opcode=FILL
    wmem(`RING_QW + 1, {16'd5, 16'd8, 32'd0});                        // h=5 w=8
    wmem(`RING_QW + 2, {16'd0, 16'd0, 32'd0});                        // dst_y=0 dst_x=0
    wmem(`RING_QW + 3, {16'd0, 16'(BG), 32'd0});                      // color=BG

    // cmd1..cmd5: PAL8 BLIT, one blend mode per dst row (0..4), same 8-pixel src row.
    // color field packs {pal_id[3:0], base_off[7:0]} = {4'd0,4'd0,8'd0} = 0 for all
    // (pal_id=0, base_off=0). colorkey = pal_rgb_of(IDX[4]) (== the row's idx7 pixel)
    // for the COLORKEY command only.
    wmem(`RING_QW + 4,  {32'd0, 8'd0, `COMP_PAL8, `BLT_BLEND_COPY,      8'd3}); // cmd1: COPY
    wmem(`RING_QW + 5,  {16'd1, 16'd8, 16'd0, 16'd8});
    wmem(`RING_QW + 6,  {16'd0, 16'd0, 16'd0, 16'd0});
    wmem(`RING_QW + 7,  64'd0);

    wmem(`RING_QW + 8,  {32'd0, 8'd0, `COMP_PAL8, `BLT_BLEND_COLORKEY, 8'd3}); // cmd2: COLORKEY
    wmem(`RING_QW + 9,  {16'd1, 16'd8, 16'd0, 16'd8});
    wmem(`RING_QW + 10, {16'd1, 16'd0, 16'd0, 16'd0});
    wmem(`RING_QW + 11, {16'd0, 16'd0, 8'd0, 8'd0, pal_rgb_of(IDX[4])});

    wmem(`RING_QW + 12, {32'd0, 8'd0, `COMP_PAL8, `BLT_BLEND_PALPHA,   8'd3}); // cmd3: PALPHA
    wmem(`RING_QW + 13, {16'd1, 16'd8, 16'd0, 16'd8});
    wmem(`RING_QW + 14, {16'd2, 16'd0, 16'd0, 16'd0});
    wmem(`RING_QW + 15, 64'd0);

    wmem(`RING_QW + 16, {32'd0, 8'd0, `COMP_PAL8, `BLT_BLEND_ADD,      8'd3}); // cmd4: ADD
    wmem(`RING_QW + 17, {16'd1, 16'd8, 16'd0, 16'd8});
    wmem(`RING_QW + 18, {16'd3, 16'd0, 16'd0, 16'd0});
    wmem(`RING_QW + 19, 64'd0);

    wmem(`RING_QW + 20, {32'd0, 8'd0, `COMP_PAL8, `BLT_BLEND_MULTIPLY, 8'd3}); // cmd5: MULTIPLY
    wmem(`RING_QW + 21, {16'd1, 16'd8, 16'd0, 16'd8});
    wmem(`RING_QW + 22, {16'd4, 16'd0, 16'd0, 16'd0});
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

    // ---- verify: row m = blend mode m, cols 0..7 = IDX[0..7] ----------------------
    for (m = 0; m < 5; m = m + 1) begin
      for (x = 0; x < 8; x = x + 1) begin
        src16 = pal_rgb_of(IDX[x]);
        a4    = pal_a4_of(IDX[x]);
        dst16 = BG;
        got16 = getpx(x, m);
        case (m)
          0: exp16 = golden_copy(src16);                              // COPY
          1: exp16 = golden_key(src16, dst16, pal_rgb_of(IDX[4]));     // COLORKEY
          2: exp16 = (a4 == 4'd0) ? dst16 : golden_ca(src16, dst16, {a4, a4}); // PALPHA
          3: exp16 = golden_add(src16, dst16);                        // ADD
          4: exp16 = golden_mul(src16, dst16);                        // MULTIPLY
          default: exp16 = 16'hXXXX;
        endcase
        if (got16 !== exp16) begin
          errs = errs + 1;
          $display("MISMATCH mode=%0d x=%0d idx=%0d a4=%0d src=%h dst=%h got=%h exp=%h",
                    m, x, IDX[x], a4, src16, dst16, got16, exp16);
        end
      end
    end

    if (errs == 0) $display("RESULT: PASS (5 blend modes x 8 pixels, incl. PALPHA a4=0 skip)");
    else           $display("RESULT: FAIL (%0d pixel mismatches)", errs);
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
