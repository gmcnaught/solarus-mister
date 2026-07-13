// tb_clut_upload.sv — Task 1.1 (paletted-composition v1): BLT_OP_CLUT_UPLOAD DMA +
// clut_bram read port. Preloads a deterministic 8-bank x 256-entry palette pattern
// into the DDR CLUTBUF region, submits ONE BLT_OP_CLUT_UPLOAD command (qword count
// = CLUT_BANKS*CLUT_ENTRIES, one 32-bit entry per 64-bit qword per the wire
// contract), waits for the frame to complete (C_DONE), then drives clut_rd_addr
// across all CLUT_BANKS*CLUT_ENTRIES addresses and asserts clut_rd_data matches.
//
// Minimal harness (unlike tb_blitter_system_pipe): CLUT_UPLOAD never touches the
// on-chip framebuffer or the SDRAM P_SRC/P_DST paths, and C_DONE is written
// (S_WR_DONE) BEFORE the vsync-gated work->scan snapshot (S_SNAP_WAIT/BUSY/DRAIN),
// so this TB never needs to drive `vs` or wire up comp_fbram/SDRAM models — it just
// needs a behavioral DDR and can $finish right after checking C_DONE + the CLUT
// readback. The three regions touched (VCTRL_QW, BLTCTRL+ring, CLUTBUF) are far
// apart in the 32-bit qword address space, so rather than one giant flat array
// (or an associative array — unsupported by the installed Icarus build) this
// model uses three small flat windows, decoded by address range.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
`include "comp_clut.vh"

module tb_clut_upload;
  localparam integer NENT = `CLUT_BANKS * `CLUT_ENTRIES;   // 32*256 = 8192

  reg clk=0, reset=1;
  always #5 clk = ~clk;

  // ---- behavioral DDR: 3 small flat windows, decoded by address range -----------
  // VCTRL_QW (1 qword), BLTCTRL_QW.. (control block + our 2-command ring, 128
  // qwords of headroom), CLUT_BUF_QW.. (exactly NENT qwords — the FSM only ever
  // reads within clut_cnt). 1-cycle read latency (mem_dout_ready_r mirrors mem_rd
  // one cycle later, matching the rd_issued/mem_dout_ready protocol in
  // blitter_top's S_RD_WAIT); writes commit synchronously honoring byte-enables.
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

  // ---- unused ports (CLUT_UPLOAD never exercises these) tied off safely --------
  wire [26:0] p0_addr; wire p0_rd;
  wire        fb_wr_en; wire [14:0] fb_wr_qw; wire [1:0] fb_wr_lane; wire [15:0] fb_wr_pix;
  wire        fb_rd_en; wire [14:0] fb_rd_qw;
  wire        fb_snap_we; wire [14:0] fb_snap_qw; wire [63:0] fb_snap_qword;
  wire        dst_wr; wire [26:0] dst_addr; wire [63:0] dst_din; wire [7:0] dst_wdsn;
  wire        bgw_active;
  wire        src_sdram_we; wire [15:0] src_sdram_din; wire [26:0] src_sdram_waddr;
  wire        src_sdram_we_burst; wire [63:0] src_sdram_din64;
  wire        stage_barrier;
  wire        idle_w;
  wire [31:0] dbg_w;

  blitter_top blt (
    .clk(clk), .rst(reset), .vs(1'b0),
    .osd_restart(1'b0), .osd_fps_on(1'b0),
    .mem_addr(mem_addr), .mem_rd(mem_rd), .mem_wr(mem_wr), .mem_burstcnt(mem_burstcnt),
    .mem_din(mem_din), .mem_be(mem_be),
    .mem_dout(mem_dout_r), .mem_dout_ready(mem_dout_ready_r), .mem_busy(1'b0),
    // P_SRC cache-ok channel: never exercised (no BLIT/FILL in this test)
    .p0_addr(p0_addr), .p0_rd(p0_rd), .p0_dout(64'd0), .p0_ok(1'b0),
    // on-chip framebuffer dest port: never exercised
    .fb_wr_en(fb_wr_en), .fb_wr_qw(fb_wr_qw), .fb_wr_lane(fb_wr_lane), .fb_wr_pix(fb_wr_pix),
    .fb_rd_en(fb_rd_en), .fb_rd_qw(fb_rd_qw), .fb_rd_qword(64'd0),
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

  // ---- CLUT pattern: entry k (k = bank*CLUT_ENTRIES + index, 0..NENT-1) --------
  function [31:0] pattern_word(input integer k);
    begin pattern_word = `CLUT_MAKE(k[3:0], k[15:0]); end
  endfunction

  integer k;
  integer errs;
  integer t;
  reg [63:0] submit_n;
  reg [63:0] done_val;
  reg [31:0] want_word;

  initial begin
    // Preload the CLUT pattern into the DDR CLUTBUF region, one 32-bit entry
    // (high 32 = 0) per 64-bit qword, matching the wire contract in the brief.
    for (k = 0; k < NENT; k = k + 1)
      wmem(`CLUT_BUF_QW + k, {32'd0, pattern_word(k)});

    // Control block: submit=1, cmd_count=2 (CLUT_UPLOAD + END), target/flags=0.
    wmem(`BLTCTRL_QW + `C_SUBMIT,   64'd1);
    wmem(`BLTCTRL_QW + `C_CMDCOUNT, 64'd2);
    wmem(`BLTCTRL_QW + `C_TARGET,   64'd0);
    wmem(`BLTCTRL_QW + `C_CLEAR,    64'd0);
    wmem(`BLTCTRL_QW + `C_FLAGS,    64'd0);   // no CLEAR-before-list
    wmem(`BLTCTRL_QW + `C_DONE,     64'd0);
    wmem(`BLTCTRL_QW + `C_STATUS,   64'd0);
    wmem(`BLTCTRL_QW + `C_SRCSEL,   64'd0);   // no throttle

    // Ring cmd0: BLT_OP_CLUT_UPLOAD, {c_h,c_w} = NENT (qword count == entry count).
    wmem(`RING_QW + 0, {32'd0, 24'd0, 8'(OP_CLUT_UPLOAD)});           // qw0: opcode
    wmem(`RING_QW + 1, {16'(NENT[31:16]), 16'(NENT[15:0]), 32'd0});    // qw1: c_h|c_w
    wmem(`RING_QW + 2, 64'd0);
    wmem(`RING_QW + 3, 64'd0);
    // Ring cmd1: BLT_OP_END.
    wmem(`RING_QW + 4, 64'd1);
    wmem(`RING_QW + 5, 64'd0);
    wmem(`RING_QW + 6, 64'd0);
    wmem(`RING_QW + 7, 64'd0);
  end

  initial begin
    errs = 0;
    repeat (8) @(posedge clk);
    reset <= 0;

    // Poll C_DONE for the submit to complete (written in S_WR_DONE, well before
    // the vsync-gated snapshot phase — no need to drive vs for this test).
    t = 0;
    done_val = rmem(`BLTCTRL_QW + `C_DONE);
    while (done_val[31:0] !== 32'd1 && t < 200000) begin
      @(posedge clk); t = t + 1;
      done_val = rmem(`BLTCTRL_QW + `C_DONE);
    end
    if (done_val[31:0] !== 32'd1) begin
      $display("RESULT: FAIL (timeout waiting for C_DONE, t=%0d)", t);
      $finish;
    end
    $display("[%0t] C_DONE seen after %0d cycles", $time, t);

    // [Task 1.2] clut_rd_addr/clut_rd_data are no longer top-level ports (the CLUT
    // read is now internal, driven by comp_pipeline). Observe the uploaded CLUT via
    // a HIERARCHICAL reference straight into blitter_top's clut_bram instead.
    for (k = 0; k < NENT; k = k + 1) begin
      want_word = pattern_word(k);
      if (blt.clut_bram[k][19:0] !== want_word[19:0]) begin
        errs = errs + 1;
        if (errs <= 8)
          $display("MISMATCH k=%0d got=%h want=%h", k, blt.clut_bram[k], want_word);
      end
    end

    if (errs == 0) $display("RESULT: PASS (%0d/%0d CLUT entries verified)", NENT, NENT);
    else           $display("RESULT: FAIL (%0d/%0d CLUT entries mismatched)", errs, NENT);
    $finish;
  end

  // safety watchdog
  initial begin
    #2_000_000;
    $display("RESULT: FAIL (global timeout)");
    $finish;
  end
endmodule
