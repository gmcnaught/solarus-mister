// tb_pal8_fill_8bpp.sv — Task 3.1 (paletted-composition v1) golden TB: comp_pipeline's
// 8bpp SOURCE FILL — address math (dec_base byte->pixel shift, src_byte_addr helper)
// and data unpack (fill_half / pal8_lanes half-select) — ISOLATED from the CLUT.
//
// Task 1.2's tb_pal8_lookup.sv already proves index -> CLUT -> {A4,RGB565} decode is
// correct; this TB instead proves the NEW Task 3.1 fill plumbing lands the right
// SOURCE BYTE at the right linebuf lane. It uses an IDENTITY CLUT (entry k decodes to
// RGB565==k, A4=0xF opaque) so a COPY blit's composited pixel low bits reduce directly
// to "which source byte got served" — any fill/address/unpack bug shows up as a wrong
// pixel value with nothing else in the way.
//
// Scenario: stage one 16-byte 8bpp index row (byte i = i, i.e. f(i)=i) in the P_SRC
// source heap at c_src_off=0, then run three PAL8 COPY blits (one dst row each) that
// exercise the three fill-plumbing cases named in the design:
//   row0: aligned src_x=0            -> dst x expects source byte x            (0..7)
//   row1: non-qword-aligned src_x=3  -> dst x expects source byte (3+x)        (3..10)
//         (fill_lo=3 is NOT 8-aligned in source-byte terms and spans a source
//          qword boundary at byte 8 -- exercises the half-select + odd base)
//   row2: src_x=0 with F_HFLIP       -> dst x expects source byte (7-x)        (7..0)
// A host-side golden model computes the expected served source byte per dst pixel
// (COPY, so composited pixel == identity-CLUT-decoded source byte) and asserts the
// composited comp_fbram pixels match exactly.
//
// Harness style: identical to tb_pal8_lookup.sv (DDR control/ring/CLUT 3-window
// behavioral memory, P_SRC fixed-latency rising-edge-capture source model, comp_fbram
// readback) -- only the CLUT pattern and test data/assertions differ.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
`include "comp_clut.vh"
`include "comp_defs.vh"

module tb_pal8_fill_8bpp;
  localparam integer NENT = `CLUT_BANKS * `CLUT_ENTRIES;   // 32*256 = 8192

  reg clk=0, reset=1;
  always #5 clk = ~clk;

  // free-running vblank: a rendered frame (FILL/BLIT, unlike CLUT_UPLOAD) only
  // reaches C_DONE after the vsync-gated work->scan snapshot -- mirrors
  // tb_pal8_lookup.sv / tb_blitter_system_pipe.sv's vs toggle.
  reg vs=0; integer vsc=0;
  always @(posedge clk) begin
    vsc <= vsc + 1;
    if (vsc >= 256) begin vs <= ~vs; vsc <= 0; end
  end

  // ── behavioral DDR: 3 small flat windows (VCTRL / BLTCTRL+ring / CLUTBUF) ──────
  // Same decoded-by-range model as tb_pal8_lookup.sv; 1-cycle read latency.
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
  // p0_addr is heap-relative, so a small standalone array indexed directly by
  // p0_addr>>3 is sufficient (mirrors tb_pal8_lookup.sv's src_mem model).
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
  // tb_pal8_lookup.sv's getpx).
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
    // P_SRC cache-ok channel: the 8bpp index row is staged here.
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

  // ── IDENTITY CLUT: entry k decodes to RGB565==k[15:0], A4=0xF (opaque). Isolates
  // the fill/address/unpack path from CLUT decode -- a COPY blit's composited pixel
  // reduces directly to "which source byte got served at this lane".
  function [31:0] pattern_word(input integer k);
    pattern_word = `CLUT_MAKE(4'hF, k[15:0]);
  endfunction

  // ── golden model: expected served source BYTE for dst pixel x of an 8px COPY span --
  function [7:0] exp_byte(input integer src_x, input integer len, input integer hflip,
                           input integer x);
    exp_byte = hflip ? (src_x + len - 1 - x) : (src_x + x);
  endfunction

  // ── test data: 16-byte 8bpp index row, byte i = i (f(i)=i), staged at c_src_off=0 --
  reg [7:0] ROW [0:15];

  integer k, x;
  integer errs;
  reg [63:0] done_val;
  integer t;
  reg [15:0] got16, exp16;

  initial begin
    for (k = 0; k < 16; k = k + 1) ROW[k] = k[7:0];

    // ---- upload the identity CLUT into the DDR CLUTBUF region ---------------------
    for (k = 0; k < NENT; k = k + 1)
      wmem(`CLUT_BUF_QW + k, {32'd0, pattern_word(k)});

    // ---- stage the 16-byte 8bpp index row into the P_SRC source model -------------
    // [Task 3.1] 8bpp: 8 bytes/qword, byte i at qword (i>>3), lane-byte (i%8)*8.
    for (k = 0; k < 16; k = k + 1)
      src_mem[k>>3][(k%8)*8 +: 8] = ROW[k];

    // ---- submit 1: BLT_OP_CLUT_UPLOAD (mirrors tb_pal8_lookup.sv) -----------------
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

    // ---- submit 2: FILL background + 3 PAL8 COPY blits + END ----------------------
    // Ring layout (qwords relative to RING_QW): cmd0=FILL(0..3), cmd1=row0 aligned
    // src_x=0 (4..7), cmd2=row1 non-aligned src_x=3 (8..11), cmd3=row2 HFLIP src_x=0
    // (12..15), cmd4=END (16..19). All three BLITs read the same 16-byte src_off=0
    // row staged above; c_src_stride is irrelevant here (h=1, no second row read).
    wmem(`BLTCTRL_QW + `C_CMDCOUNT, 64'd5);
    wmem(`BLTCTRL_QW + `C_TARGET,   64'd0);
    wmem(`BLTCTRL_QW + `C_CLEAR,    64'd0);
    wmem(`BLTCTRL_QW + `C_FLAGS,    64'd0);

    // cmd0: FILL background, dst (0,0) 8x3, colour=BG (distinct from any CLUT decode
    // value 0..15 so an un-driven pixel reads as an obvious mismatch, not a false PASS).
    wmem(`RING_QW + 0, 64'h0000_0000_0000_0002);                      // opcode=FILL
    wmem(`RING_QW + 1, {16'd3, 16'd8, 32'd0});                        // h=3 w=8
    wmem(`RING_QW + 2, {16'd0, 16'd0, 32'd0});                        // dst_y=0 dst_x=0
    wmem(`RING_QW + 3, {16'd0, 16'hBEEF, 32'd0});                     // color=BEEF

    // cmd1: row0, PAL8 COPY, src_off=0, src_x=0, no flip. dst row 0.
    wmem(`RING_QW + 4,  {32'd0, 8'd0, `COMP_PAL8, `BLT_BLEND_COPY, 8'd3});
    wmem(`RING_QW + 5,  {16'd1, 16'd8, 16'd0, 16'd16});               // h=1 w=8 src_x=0
    wmem(`RING_QW + 6,  {16'd0, 16'd0, 16'd0, 16'd0});                // dst_y=0 dst_x=0
    wmem(`RING_QW + 7,  64'd0);

    // cmd2: row1, PAL8 COPY, src_off=0, src_x=3 (non-qword-aligned), no flip. dst row1.
    wmem(`RING_QW + 8,  {32'd0, 8'd0, `COMP_PAL8, `BLT_BLEND_COPY, 8'd3});
    wmem(`RING_QW + 9,  {16'd1, 16'd8, 16'd3, 16'd16});               // h=1 w=8 src_x=3
    wmem(`RING_QW + 10, {16'd1, 16'd0, 16'd0, 16'd0});                // dst_y=1 dst_x=0
    wmem(`RING_QW + 11, 64'd0);

    // cmd3: row2, PAL8 COPY, src_off=0, src_x=0, F_HFLIP=8'h01. dst row2.
    wmem(`RING_QW + 12, {32'd0, 8'h01, `COMP_PAL8, `BLT_BLEND_COPY, 8'd3});
    wmem(`RING_QW + 13, {16'd1, 16'd8, 16'd0, 16'd16});               // h=1 w=8 src_x=0
    wmem(`RING_QW + 14, {16'd2, 16'd0, 16'd0, 16'd0});                // dst_y=2 dst_x=0
    wmem(`RING_QW + 15, 64'd0);

    wmem(`RING_QW + 16, 64'd1);                                          // cmd4 = END
    wmem(`RING_QW + 17, 64'd0); wmem(`RING_QW + 18, 64'd0); wmem(`RING_QW + 19, 64'd0);

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

    // ---- verify: row0=aligned src_x=0, row1=src_x=3, row2=src_x=0+HFLIP -----------
    for (x = 0; x < 8; x = x + 1) begin
      got16 = getpx(x, 0);
      exp16 = {8'd0, exp_byte(0, 8, 0, x)};
      if (got16 !== exp16) begin
        errs = errs + 1;
        $display("MISMATCH row0(aligned) x=%0d got=%h exp=%h", x, got16, exp16);
      end
    end
    for (x = 0; x < 8; x = x + 1) begin
      got16 = getpx(x, 1);
      exp16 = {8'd0, exp_byte(3, 8, 0, x)};
      if (got16 !== exp16) begin
        errs = errs + 1;
        $display("MISMATCH row1(src_x=3) x=%0d got=%h exp=%h", x, got16, exp16);
      end
    end
    for (x = 0; x < 8; x = x + 1) begin
      got16 = getpx(x, 2);
      exp16 = {8'd0, exp_byte(0, 8, 1, x)};
      if (got16 !== exp16) begin
        errs = errs + 1;
        $display("MISMATCH row2(hflip) x=%0d got=%h exp=%h", x, got16, exp16);
      end
    end

    if (errs == 0) $display("RESULT: PASS (3 rows x 8 px: aligned, non-qword-aligned src_x, hflip)");
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
