# Per-Layer ARGB4444 Plane Bake Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `SOLARUS_BGPLANE`'s baked-plane optimization work correctly and fast on every layer of every map — including maps with base-layer parallax (Mystery of Solarus DX map 119, currently disqualified at ~52.8ms/frame) — by giving each layer's bake real per-pixel transparency instead of an opaque RGB565 fill.

**Architecture:** Add a small on-chip per-cell coverage tracker that mirrors every pixel write the compositor makes into `comp_fbram` during a bake; a bake-mode `OP_FILL` clears it, and `OP_BGPLANE_WRITE` reads it back to pack ARGB4444 (alpha=0xF covered / 0x0 uncovered) instead of RGB565 into the SDRAM plane. The read-back COPY becomes a `BLT_BLEND_PALPHA` blit — reusing the fabric's existing, HW-validated per-pixel-alpha blend path unchanged. Host-side, generalize the single base-layer-only bake into one bake per eligible layer, and remove the scroll_ratio disqualification and the now-unneeded background-color-baking workaround. See `docs/superpowers/specs/2026-07-09-parallax-layer-compositor-design.md` for the full design rationale, including the two alternative approaches (reserved-colorkey, steal-a-bit) and the reorder-to-ARGB4444-everywhere approach considered and rejected.

**Tech Stack:** SystemVerilog (Icarus Verilog sim via `fpga/sim/run_sims.sh`), C/C++ (armhf cross-build via Docker, `scripts/docker_run.sh scripts/build_engine.sh`), Solarus 1.6 engine patch series (`work/solarus` + `scripts/export_patches.sh`).

## Global Constraints

- Correctness is non-negotiable — every task that changes rendering behavior must pass its sim/host test before moving on, and no task may regress a previously-passing HW validation.
- Cross-build compiles ONLY inside Docker (`scripts/docker_run.sh scripts/build_engine.sh`); host `g++ -fsyntax-only` is a pre-check only, not a gate.
- RTL sims run via `bash fpga/sim/run_sims.sh <tb_name>` (Icarus Verilog); a testbench is GATING by default unless explicitly listed NONGATING in that script.
- Host unit tests run via `bash tests/run_tests.sh` (plain `cc`, no framework).
- Files under `patches/mister/` are edited directly (whole-file copies, applied verbatim by `apply_mister_files.sh`) — no patch regeneration needed for them.
- Files that are part of the upstream-Solarus patch series (`Entities.cpp`, `Renderer.h`) are edited in the live clone at `work/solarus/src/...` / `work/solarus/include/...`, committed there (`git -C work/solarus commit -am "..."`), then `scripts/export_patches.sh` regenerates `patches/series/*.patch` from the whole commit history.
- SDRAM plane budget: this design adds N per-layer planes instead of 1, each ≤ map_width×map_height×2 bytes — verify no map blows a reasonable budget only if HW validation surfaces a problem; not expected given the 128 MB module.
- M10K on-chip BRAM is scarce (PR #49's history: a prior design needed "more than 553 blocks" against ~118 blocks of headroom). The new coverage tracker is a hard Quartus-fit gate — Task 1 verifies this before any other RTL work proceeds.

---

### Task 1: RTL — per-cell coverage tracker + write-side tap

**Files:**
- Create: `fpga/rtl/bgplane_coverage.sv`
- Modify: `fpga/rtl/blitter_top.sv` (instantiate + wire the new module; new `S_DECODE`/`S_SETUP` flag latch)
- Modify: `patches/mister/blitter/blitter_ref.h` (new `BLT_F_BGCOV` flag constant)
- Create: `fpga/sim/tb_bgplane_coverage.sv`

**Interfaces:**
- Produces: `bgplane_coverage` module with ports `clk, rst, wr_en, wr_qw[14:0], wr_lane[1:0], wr_clear, rd_en, rd_qw[14:0], rd_nibble[3:0]` (registered read, same 1-cycle latency contract as `comp_fbram`'s `rd_qword`).
- Produces: `BLT_F_BGCOV = 0x80` in `blitter_ref.h`, consumed by Task 2 and Task 3.

Background: `comp_pipeline.sv` already exposes `fb_wr_en/fb_wr_qw/fb_wr_lane/fb_wr_pix` — one pulse per pixel actually written to `comp_fbram` (respecting existing KEY/blend skip logic). A 19200-entry × 4-bit array (one bit per lane, same `AW=15` address space as `comp_fbram`) mirrors every one of those pulses. On an ordinary paint write it sets the touched lane's bit to 1; on a coverage-clearing `OP_FILL` (Task 3 adds the trigger) it clears the touched lane's bit to 0 instead — since a full-screen FILL touches every lane at every address exactly once, this needs no separate clear-sweep state machine at all, it rides the FILL's own existing pixel-write loop.

- [ ] **Step 1: Write `fpga/rtl/bgplane_coverage.sv`**

```systemverilog
// bgplane_coverage.sv -- per-cell pixel-coverage tracker for the Phase 3b+ ARGB4444
// plane bake. Mirrors comp_pipeline's fb_wr_en/fb_wr_qw/fb_wr_lane pulses (one per
// pixel actually written to comp_fbram) into a 19200x4-bit array, addressed
// identically to comp_fbram's own AW=15 qword space (4 lanes/qword, matching
// comp_fbram's 16-bit-pixel x 4-lane/64-bit-qword layout).
//
// wr_clear selects what a pulse WRITES: 0 (normal paint) sets the touched lane's
// bit to 1 ("covered"); 1 (bake-mode OP_FILL, see blitter_top.sv's BLT_F_BGCOV
// decode) clears it to 0. A full-screen FILL touches every lane at every address
// exactly once as part of its own existing pixel-write loop, so this doubles as
// the clear-sweep with no separate FSM: no address is ever "not yet cleared" by
// the time OP_BGPLANE_WRITE reads it, because the FILL that must precede any
// bake-cell paint (see mister_blitter_renderer.cpp's bake_background_plane_step)
// always visits the whole cell before the paint's own tile-list ops run.
//
// Read port mirrors comp_fbram's registered-read contract exactly (rd_nibble valid
// 1 cycle after rd_qw/rd_en) so fbram_to_sdram.sv can read it in lockstep with
// rd_qword with zero new pipeline-timing bookkeeping.
// Copyright (C) 2026 -- GPL-3.0
`default_nettype none
module bgplane_coverage #(
    parameter integer AW = 15
)(
    input  wire          clk,
    input  wire          rst,
    // write side: tap comp_pipeline's fb_wr_* directly (fan-out, not exclusive use)
    input  wire          wr_en,
    input  wire [AW-1:0] wr_qw,
    input  wire [1:0]    wr_lane,
    input  wire          wr_clear,   // 0=paint (set bit) 1=bake-FILL (clear bit)
    // read side: tap the fb_rd_* bus (already muxed for whichever consumer owns it)
    input  wire          rd_en,
    input  wire [AW-1:0] rd_qw,
    output reg  [3:0]    rd_nibble   // registered, valid 1 cyc after rd_qw/rd_en
);
    reg [3:0] mem [0:19199];

    always @(posedge clk) begin
        if (wr_en) mem[wr_qw][wr_lane] <= !wr_clear;
        if (rd_en) rd_nibble <= mem[rd_qw];
    end
endmodule
`default_nettype wire
```

- [ ] **Step 2: Add `BLT_F_BGCOV` to `patches/mister/blitter/blitter_ref.h`**

Find the existing flag block (around line 131-142) and add after `BLT_F_COLORMOD`:

```c
#define BLT_F_COLORMOD  0x40u  /* [v2 escape-elim] color-mod (tint) present: _pad[0..2] = {cr,cg,cb} (u8).
                                   ... (existing comment unchanged) */
#define BLT_F_BGCOV     0x80u  /* [ARGB4444 plane bake] dual meaning by opcode: on OP_FILL,
                                   clear the bake-coverage tracker (bgplane_coverage.sv) as
                                   this fill's own pixel-write loop runs, instead of setting
                                   coverage bits; on OP_BGPLANE_WRITE, pack the streamed plane
                                   as ARGB4444 (alpha=0xF covered/0x0 uncovered) using the
                                   tracker instead of raw RGB565. See fbram_to_sdram.sv. */
```

- [ ] **Step 3: Instantiate `bgplane_coverage` in `fpga/rtl/blitter_top.sv`**

Add right after the `fbram_snapshot`/`fbram_to_sdram` instantiation block (after line 992, before the ch0 wiring comment at line 994):

```systemverilog
    // ── [ARGB4444 plane bake] per-cell coverage tracker ─────────────────────
    // Write side taps comp_pipeline's own fb_wr_* directly (fan-out — comp_fbram
    // remains the sole consumer of record; this is a passive mirror). wr_clear is
    // driven by a new c_bgcov_clear register (Task 3) latched from BLT_F_BGCOV on
    // an OP_FILL. Read side taps the already-muxed fb_rd_* bus so it tracks
    // whichever consumer (only bgw ever reads it in practice) currently owns it.
    wire [3:0] bgcov_rd_nibble;
    bgplane_coverage #(.AW(15)) u_bgcov (
        .clk(clk), .rst(rst),
        .wr_en(pipe_fb_wr_en), .wr_qw(pipe_fb_wr_qw), .wr_lane(pipe_fb_wr_lane),
        .wr_clear(c_bgcov_clear),
        .rd_en(fb_rd_en), .rd_qw(fb_rd_qw), .rd_nibble(bgcov_rd_nibble)
    );
```

Note: this references `pipe_fb_wr_en/pipe_fb_wr_qw/pipe_fb_wr_lane` — check the exact signal names comp_pipeline's write port uses at its instantiation site in this file (search `fb_wr_en` in `blitter_top.sv`); if the instantiation wires comp_pipeline's ports directly to top-level `fb_wr_*` without a `pipe_` prefix, use those names instead. `c_bgcov_clear` is added in Task 3.

- [ ] **Step 4: Write `fpga/sim/tb_bgplane_coverage.sv`**

A focused unit-level TB instantiating `bgplane_coverage` directly (no `blitter_top`/`comp_pipeline` in the loop yet — that full-system path is Task 3's `tb_bgplane_equivalence` extension). Proves the module's own read/write/clear semantics in isolation.

```systemverilog
// tb_bgplane_coverage.sv -- unit TB for bgplane_coverage.sv: proves paint-writes set
// bits, bake-FILL writes (wr_clear=1) clear bits, and the registered read matches
// comp_fbram's 1-cycle-later contract.
`timescale 1ns/1ps
`default_nettype none
module tb_bgplane_coverage;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  reg          wr_en, wr_clear, rd_en;
  reg  [14:0]  wr_qw, rd_qw;
  reg  [1:0]   wr_lane;
  wire [3:0]   rd_nibble;

  bgplane_coverage #(.AW(15)) dut (
    .clk(clk), .rst(rst),
    .wr_en(wr_en), .wr_qw(wr_qw), .wr_lane(wr_lane), .wr_clear(wr_clear),
    .rd_en(rd_en), .rd_qw(rd_qw), .rd_nibble(rd_nibble)
  );

  integer errs = 0;
  task check(input [3:0] got, input [3:0] want, input [255:0] msg);
    begin
      if (got !== want) begin
        $display("  FAIL %0s: got=%b want=%b", msg, got, want);
        errs = errs + 1;
      end
    end
  endtask

  task do_write(input [14:0] qw, input [1:0] lane, input clr);
    begin
      @(posedge clk);
      wr_en <= 1'b1; wr_qw <= qw; wr_lane <= lane; wr_clear <= clr;
      @(posedge clk);
      wr_en <= 1'b0;
    end
  endtask

  task do_read(input [14:0] qw, output [3:0] nib);
    begin
      @(posedge clk);
      rd_en <= 1'b1; rd_qw <= qw;
      @(posedge clk);
      rd_en <= 1'b0;
      @(posedge clk);          // registered: valid 1 cyc after the read pulse
      nib = rd_nibble;
    end
  endtask

  reg [3:0] got;
  initial begin
    wr_en=0; wr_clear=0; rd_en=0; wr_qw=0; wr_lane=0; rd_qw=0;
    repeat (4) @(posedge clk); rst <= 0; repeat (4) @(posedge clk);

    // fresh cell (post-rst, all-X in sim but never read before a clear in real use):
    // paint lane 2 of qword 100 -> bit set.
    do_write(15'd100, 2'd2, 1'b0);
    do_read(15'd100, got);
    check(got, 4'b0100, "lane2 set after paint write");

    // paint lane 0 of the SAME qword -> both bits now set, lane1/3 untouched (still 0
    // from the two do_write calls below establishing a known baseline first).
    do_write(15'd100, 2'd0, 1'b0);
    do_read(15'd100, got);
    check(got, 4'b0101, "lane0+lane2 set, lane1/3 still 0");

    // bake-FILL clear (wr_clear=1) on lane 2 -> only that bit clears.
    do_write(15'd100, 2'd2, 1'b1);
    do_read(15'd100, got);
    check(got, 4'b0001, "lane2 cleared by bake-FILL write, lane0 unaffected");

    // a different qword address is untouched by any of the above.
    do_read(15'd200, got);
    check(got, 4'b0000, "untouched qword reads all-zero after rst+clears elsewhere");

    if (errs == 0) $display("RESULT: PASS");
    else           $display("RESULT: FAIL (%0d mismatches)", errs);
    $finish;
  end

  initial begin #100000 $display("RESULT: FAIL (timeout/hang)"); $finish; end
endmodule
`default_nettype wire
```

- [ ] **Step 5: Run the new TB and confirm it PASSes**

Run: `bash fpga/sim/run_sims.sh tb_bgplane_coverage`
Expected: `tb_bgplane_coverage    PASS` and overall `RESULT: PASS`. If Step 3's port names were wrong (the `pipe_fb_wr_*` guess), this TB doesn't exercise `blitter_top.sv` at all so it will still pass — fix the wiring accuracy in Task 3's full-system TB instead.

- [ ] **Step 6: Quartus fit check (BRAM budget gate)**

This is the task's real risk gate, given the tight M10K headroom documented in PR #49's history. Build the RBF with the new module present (even though nothing drives real data through it yet) and confirm the fit report shows no M10K overflow:

Run: the project's normal RBF build path (see `.github/workflows/build-rbf.yml` for the exact `docker run ... raetro/quartus:17.0` invocation, or trigger the `build-rbf` CI workflow on this branch) and check the fit summary for M10K block usage.
Expected: fit succeeds, M10K usage increase ≈ 8 blocks (19200×4 bits ≈ 76,800 bits ≈ 8×10Kb blocks) over the pre-Task-1 baseline, comfortably within headroom. **If it does not fit, stop and re-scope this task before proceeding to Task 2** — do not build further logic on top of a coverage tracker that doesn't fit.

- [ ] **Step 7: Commit**

```bash
git add fpga/rtl/bgplane_coverage.sv fpga/rtl/blitter_top.sv \
        patches/mister/blitter/blitter_ref.h fpga/sim/tb_bgplane_coverage.sv
git commit -m "feat(fpga): per-cell bake-coverage tracker (bgplane_coverage.sv)"
```

---

### Task 2: RTL — ARGB4444 packing in the plane writeback

**Files:**
- Modify: `fpga/rtl/fbram_to_sdram.sv`
- Modify: `fpga/rtl/blitter_top.sv` (wire `bgcov_rd_nibble` + `argb4444_mode` into `u_bgw`)
- Modify: `fpga/sim/tb_bgplane_write_pipe.sv` (extend with an ARGB4444-mode case)

**Interfaces:**
- Consumes: `bgplane_coverage`'s `rd_nibble[3:0]` (Task 1), same address/timing contract as `comp_fbram`'s `rd_qword`.
- Produces: `fbram_to_sdram` gains an `argb4444_mode` input (latched at `start`, alongside the existing `dst_stride_qw`) and a `cov_rd_nibble[3:0]` input; when `argb4444_mode` is set, `sdram_wr_data` is the packed ARGB4444 qword instead of raw `rd_qword`.

- [ ] **Step 1: Add ARGB4444 packing to `fbram_to_sdram.sv`**

Add a pack function near the top (after the module parameter/port list, before the `always @(posedge clk)` block):

```systemverilog
    // RGB565 {r[4:0],g[5:0],b[4:0]} -> ARGB4444 {a[3:0],r[3:0],g[3:0],b[3:0]}, alpha
    // from the coverage nibble's corresponding lane bit (0xF covered / 0x0 not).
    // Truncates (not rounds) the low bits of each channel -- acceptable for a
    // static-tile plane bake, same precision loss any 565->444 conversion incurs.
    function automatic [15:0] pack_argb4444(input [15:0] rgb565, input cov_bit);
        reg [3:0] a4, r4, g4, b4;
        begin
            a4 = cov_bit ? 4'hF : 4'h0;
            r4 = rgb565[15:12];   // top 4 of the 5-bit R
            g4 = rgb565[10:7];    // top 4 of the 6-bit G
            b4 = rgb565[4:1];     // top 4 of the 5-bit B
            pack_argb4444 = {a4, r4, g4, b4};
        end
    endfunction

    function automatic [63:0] pack_qword_argb4444(input [63:0] qw, input [3:0] cov);
        begin
            pack_qword_argb4444 = {
                pack_argb4444(qw[63:48], cov[3]),
                pack_argb4444(qw[47:32], cov[2]),
                pack_argb4444(qw[31:16], cov[1]),
                pack_argb4444(qw[15: 0], cov[0])
            };
        end
    endfunction
```

Add two new ports (after `dst_stride_qw`, before `busy`):

```systemverilog
    input  wire          argb4444_mode,   // latched at start, alongside dst_stride_qw
    input  wire [3:0]    rd_cov,          // registered, same 1-cyc-after-rd_qw/rd_en
                                           // contract as rd_qword; caller wires this to
                                           // bgplane_coverage's rd_nibble (same rd_qw/rd_en)
```

Latch `argb4444_mode` at `start` (in the `if (!busy) begin ... if (start) begin` block, alongside the existing `stride_q<=dst_stride_qw;` line):

```systemverilog
                    stride_q<=dst_stride_qw;
                    argb_mode_q<=argb4444_mode;
```

(add `reg argb_mode_q;` to the register declarations near `stride_q`)

Change the SLOT A data capture (the line `sdram_wr_data <= rd_qword;   // v1_rdy guarantees this is valid for a1`) to:

```systemverilog
                    sdram_wr_data <= argb_mode_q ? pack_qword_argb4444(rd_qword, rd_cov)
                                                  : rd_qword;   // v1_rdy guarantees both are valid for a1
```

- [ ] **Step 2: Wire the new ports at `blitter_top.sv`'s `u_bgw` instantiation**

Modify the `fbram_to_sdram` instantiation (lines 985-992):

```systemverilog
    fbram_to_sdram #(.FB_QWORDS(19200), .AW(15), .CELL_ROW_QW(BGW_CELL_ROW_QW), .CELL_ROWS(240)) u_bgw (
        .clk(clk), .rst(rst), .start(bgw_start), .dst_stride_qw(bgw_stride_qw),
        .argb4444_mode(bgw_argb4444), .rd_cov(bgcov_rd_nibble),
        .busy(bgw_busy),
        .rd_en(bgw_rd_en), .rd_qw(bgw_rd_qw), .rd_qword(fb_rd_qword),
        .sdram_wr_en(bgw_sdram_wr_en), .sdram_wr_addr(bgw_sdram_wr_addr),
        .sdram_wr_data(bgw_sdram_wr_data),
        .consumer_ready(dst_ok)
    );
```

`bgw_argb4444` is declared and latched from the command's `BLT_F_BGCOV` flag in Task 3 (it needs `c_flags` at the `OP_BGPLANE_WRITE` decode site, which Task 3 also touches) — declare it here as `reg bgw_argb4444;` near the other `bgw_*` registers (line ~221-223) so this task's wiring compiles standalone; Task 3 adds the line that actually sets it.

- [ ] **Step 3: Extend `tb_bgplane_write_pipe.sv` with an ARGB4444-mode case**

Add a second scenario after the existing quadrant-fill test (before the final `errs==0` check), reusing the same harness. This paints only TWO of the four quadrants (leaving the other two at whatever `comp_fbram` last held — in this fresh submit, unpainted) so the alpha channel has both covered and uncovered content to check:

```systemverilog
    // ---- ARGB4444 mode: paint only TL+BR quadrants, bake with BLT_F_BGCOV,
    // verify covered quadrants pack as alpha=0xF+truncated-color and uncovered
    // ones as alpha=0x0 (color bits don't matter when alpha=0, not checked). ----
    localparam integer BASE_QW2 = 32'h0000_5000;
    for (r = 0; r < CELL_ROWS; r = r + 1)
      for (c = 0; c < STRIDE_QW; c = c + 1)
        preload_qword((BASE_QW2 + r*STRIDE_QW + c) * 8, SENTINEL);

    // Submit 3: bake-coverage-clearing FILL (BLT_F_BGCOV) over the whole cell,
    // then paint only TL + BR quadrants (leaving TR/BL "uncovered").
    set_ctrl(3, 0);
    mem[RINGB + 0*4] = {32'd0, 8'h80, 8'd0, 8'd0, 8'd2};           // FILL, flags=BLT_F_BGCOV
    mem[RINGB + 0*4 + 1] = {16'd240, 16'd320, 32'd0};              // full 320x240
    mem[RINGB + 0*4 + 2] = 64'd0;                                   // dst 0,0
    mem[RINGB + 0*4 + 3] = {16'd0, COLOR_TL, 32'd0};                // clear color irrelevant (alpha wins)
    wr_fill(1, 16'd0,   16'd0,   16'd160, 16'd120, COLOR_TL);       // TL covered
    wr_fill(2, 16'd160, 16'd120, 16'd160, 16'd120, COLOR_BR);       // BR covered
    mem[RINGB + 3*4] = 64'd1;                                       // END
    run_submit;

    // Submit 4: OP_BGPLANE_WRITE with BLT_F_BGCOV (ARGB4444 pack mode).
    set_ctrl(2, 0);
    mem[RINGB + 0*4] = {32'd0, 8'h80, 8'd0, 8'd0, OP_BGPLANE_WRITE}; // flags=BLT_F_BGCOV
    mem[RINGB + 0*4 + 1] = {32'd0, STRIDE_QW[15:0], 16'd0};
    mem[RINGB + 0*4 + 2] = {BASE_QW2[31:16], BASE_QW2[15:0], 32'd0};
    mem[RINGB + 0*4 + 3] = 64'd0;
    mem[RINGB + 1*4] = 64'd1;                                       // END
    run_submit;
    flush_to_sdram;

    // verify: TL/BR quadrants packed as alpha=0xF + truncated color; TR/BL as alpha=0x0.
    mism = 0;
    for (r = 0; r < CELL_ROWS; r = r + 1) begin
      for (c = 0; c < CELL_ROW_QW; c = c + 1) begin
        got = read_qword((BASE_QW2 + r*STRIDE_QW + c) * 8);
        begin : per_pixel
          integer lane; reg [15:0] px; reg covered;
          for (lane = 0; lane < 4; lane = lane + 1) begin
            px = got[lane*16 +: 16];
            covered = (r < 120) ? (c < 40) : (c >= 40);   // TL(r<120,c<40) or BR(r>=120,c>=40)
            if (covered && px[15:12] !== 4'hF) begin
              if (mism < 8) $display("  FAIL argb (row=%0d col=%0d lane=%0d): want alpha=F got=%h", r, c, lane, px);
              mism = mism + 1;
            end
            if (!covered && px[15:12] !== 4'h0) begin
              if (mism < 8) $display("  FAIL argb (row=%0d col=%0d lane=%0d): want alpha=0 got=%h", r, c, lane, px);
              mism = mism + 1;
            end
          end
        end
      end
    end
    if (mism == 0) $display("ARGB4444 PACK: PASS");
    else           $display("ARGB4444 PACK: FAIL (%0d mismatches)", mism);
    errs = errs + mism;
```

(Note: this snippet assumes per-quadrant coverage is uniform per-pixel within each 160×120 block, matching the existing `expect_color` quadrant convention already in this file — verify the `covered` boolean above against the ACTUAL `wr_fill` rects used, TL=(0,0,160,120) and BR=(160,120,160,120), before trusting the mismatch counts.)

- [ ] **Step 4: Run and confirm PASS**

Run: `bash fpga/sim/run_sims.sh tb_bgplane_write_pipe`
Expected: `RESULT: PASS` including the new `ARGB4444 PACK: PASS` line. Iterate on Step 1-3 if it fails — this is the real correctness gate for the packing math.

- [ ] **Step 5: Commit**

```bash
git add fpga/rtl/fbram_to_sdram.sv fpga/rtl/blitter_top.sv fpga/sim/tb_bgplane_write_pipe.sv
git commit -m "feat(fpga): ARGB4444 pack mode for OP_BGPLANE_WRITE writeback"
```

---

### Task 3: RTL — wire `BLT_F_BGCOV` through the command decode + full-loop equivalence test

**Files:**
- Modify: `fpga/rtl/comp_pipeline.sv` (drive `c_bgcov_clear` from `c_opcode==OP_FILL && (c_flags & BLT_F_BGCOV)`)
- Modify: `fpga/rtl/blitter_top.sv` (latch `bgw_argb4444` from `c_flags` at the `OP_BGPLANE_WRITE` decode branch; declare `c_bgcov_clear`)
- Modify: `fpga/sim/tb_bgplane_equivalence.sv` (extend with a gap/parallax-shaped scenario read back via PALPHA)

**Interfaces:**
- Consumes: `BLT_F_BGCOV` (Task 1), `bgplane_coverage` (Task 1), `fbram_to_sdram`'s `argb4444_mode`/`rd_cov` (Task 2).
- Produces: a fully working bake-and-readback loop — the last piece before host integration (Task 5) can use it for real.

- [ ] **Step 1: Drive `c_bgcov_clear` in `blitter_top.sv`**

`c_bgcov_clear` gates `bgplane_coverage`'s `wr_clear` input (Task 1 Step 3's instantiation). It must be high for the duration of a `BLT_F_BGCOV`-flagged `OP_FILL`'s pixel-write loop — i.e. it's a function of the currently-latched command, not a pulse. Add near the other `c_*` decode registers (alongside `c_flags` itself, right after the `S_DECODE` state's `c_flags <= cmd_qw[0][31:24];` line has already latched flags — this can be a plain combinational wire, not a new register):

```systemverilog
    // [ARGB4444 plane bake] high for the whole duration of a BLT_F_BGCOV-flagged
    // OP_FILL -- gates bgplane_coverage's wr_clear so this fill's own pixel-write
    // loop clears coverage instead of setting it. Combinational: c_opcode/c_flags
    // are already latched and held stable for the whole blit (S_DECODE through
    // blit completion), same lifetime pipe_start/pipe_busy already rely on.
    wire c_bgcov_clear = (c_opcode == OP_FILL) && ((c_flags & 8'h80) != 0);
```

Place this near the `OP_FILL`/`OP_BLIT`/`OP_NOP` localparam block (~line 188) so it's in scope for the `bgplane_coverage` instantiation added in Task 1 Step 3.

- [ ] **Step 2: Latch `bgw_argb4444` at the `OP_BGPLANE_WRITE` decode branch**

Modify the existing branch (lines 632-641) to also latch the flag:

```systemverilog
                else if (c_opcode==OP_BGPLANE_WRITE) begin
                    // [Phase 3b] one-time WORK->SDRAM plane bake. ... (existing comment unchanged)
                    bgw_base_qw   <= {c_dst_y, c_dst_x};
                    bgw_stride_qw <= {8'd0, c_src_x};
                    bgw_argb4444  <= (c_flags & 8'h80) != 0;   // [ARGB4444 plane bake] BLT_F_BGCOV
                    bgw_start     <= 1'b1;
                    state         <= S_BGW_WAIT;
                end
```

- [ ] **Step 3: Extend `tb_bgplane_equivalence.sv` with a gap-and-readback scenario**

Read the existing file first (`fpga/sim/tb_bgplane_equivalence.sv`, 419 lines) to match its harness conventions — it already exercises a real `sdram_fb_cache` + `mt48lc16m16a2` model per its own description ("GATING equivalence TB against the REAL sdram_fb_cache+mt48"). Add a new scenario, following its existing structure, that:
1. Paints a cell with a deliberate gap (e.g. one quadrant left unpainted, mirroring Task 2's TL/BR pattern).
2. Bakes it with `BLT_F_BGCOV` (both the clearing FILL and the ARGB4444 `OP_BGPLANE_WRITE`).
3. Pre-paints a DIFFERENT, distinguishable color into `comp_fbram`'s WORK buffer at the same coordinates the gap covers (simulating "content from a lower layer/parallax that already drew this frame").
4. Issues a `BLT_BLEND_PALPHA` `blt_blit` reading the baked plane back onto WORK (mirroring what `resident_emit_static_layer`'s host-side COPY will do after Task 5).
5. Verifies: covered-quadrant pixels now show the baked plane's color (opaque overwrite), gap-quadrant pixels still show the pre-existing "lower layer" color (untouched — this is the actual bug #1/parallax-order correctness property this whole design exists to prove in RTL, not just host logic).

Expected PASS marker: follow the file's existing convention (check its `$display("RESULT: ...")` usage before writing the new block, and append to the same `errs` accumulator pattern rather than introducing a second one).

- [ ] **Step 4: Run and confirm PASS**

Run: `bash fpga/sim/run_sims.sh tb_bgplane_coverage tb_bgplane_write_pipe tb_bgplane_equivalence`
Expected: all three `PASS`, `RESULT: PASS` overall. This is the last RTL-only gate — do not proceed to host integration until this passes.

- [ ] **Step 5: Full sim suite regression**

Run: `bash fpga/sim/run_sims.sh`
Expected: `RESULT: PASS` (`gating-failures=0`) — confirms nothing else in the fabric regressed from the `comp_pipeline.sv`/`blitter_top.sv` edits in this task and Task 1/2.

- [ ] **Step 6: Commit**

```bash
git add fpga/rtl/comp_pipeline.sv fpga/rtl/blitter_top.sv fpga/sim/tb_bgplane_equivalence.sv
git commit -m "feat(fpga): wire BLT_F_BGCOV through FILL/BGPLANE_WRITE decode + equivalence test"
```

---

### Task 4: Host emitter — `BLT_F_BGCOV` on `blt_fill`/`blt_bgplane_write_cell`

**Files:**
- Modify: `patches/mister/blitter/blt_emitter.h`
- Modify: `patches/mister/blitter/blt_emitter.c`
- Modify: `tests/blt_bgplane_write_test.c`

**Interfaces:**
- Consumes: `BLT_F_BGCOV` (Task 1).
- Produces: `blt_fill_flags(e, x, y, w, h, color, flags)` and an updated `blt_bgplane_write_cell(e, sdram_qword_offset, dst_stride_qw, uint8_t flags)` signature — Task 5 calls both with `BLT_F_BGCOV` set.

- [ ] **Step 1: Add a flags-carrying FILL emitter**

`blt_fill` (declared `patches/mister/blitter/blt_emitter.h:113`, defined `blt_emitter.c:95`) currently has no `flags` parameter. Rather than changing its signature (other call sites depend on it), add a sibling function. In `blt_emitter.h`, after the existing `blt_fill` declaration:

```c
int  blt_fill(blt_emitter_t *e, int x, int y, int w, int h, uint16_t color);
/* [ARGB4444 plane bake] Same as blt_fill, but with an explicit BLT_F_* flags byte
 * (BLT_F_BGCOV clears the bake-coverage tracker as this fill's pixel-write loop
 * runs — see bgplane_coverage.sv — instead of setting coverage bits). */
int  blt_fill_flags(blt_emitter_t *e, int x, int y, int w, int h, uint16_t color,
                    uint8_t flags);
```

In `blt_emitter.c`, read the existing `blt_fill` (line 95) first to match its exact body, then add `blt_fill_flags` right after it with the same body plus a `c.flags = flags;` line (the existing `blt_fill` presumably calls `memset(&c, 0, sizeof(c))` then sets `c.opcode = BLT_OP_FILL` etc. — mirror that exactly, just parameterizing `flags` instead of hardcoding 0).

- [ ] **Step 2: Add a flags parameter to `blt_bgplane_write_cell`**

Modify `blt_emitter.h`:

```c
int blt_bgplane_write_cell(blt_emitter_t *e, uint32_t sdram_qword_offset,
                           uint32_t dst_stride_qw, uint8_t flags);
```

Modify `blt_emitter.c` (the existing function at line 351-359):

```c
int blt_bgplane_write_cell(blt_emitter_t *e, uint32_t sdram_qword_offset,
                           uint32_t dst_stride_qw, uint8_t flags)
{
    blt_cmd_t c; memset(&c, 0, sizeof(c));
    c.opcode = BLT_OP_BGPLANE_WRITE;
    c.flags  = flags;
    c.dst_x = (uint16_t)(sdram_qword_offset & 0xFFFF);      /* offset low  16 */
    c.dst_y = (uint16_t)(sdram_qword_offset >> 16);         /* offset high 16 */
    c.src_x = (uint16_t)(dst_stride_qw & 0xFFFF);           /* stride */
    return emit(e, &c);
}
```

This is a breaking signature change — Task 5's host renderer update is the only caller (`mister_blitter_renderer.cpp`); confirm no other call site exists before proceeding:

Run: `grep -rn "blt_bgplane_write_cell(" --include="*.c" --include="*.cpp" . | grep -v /work/`
Expected: only the declaration/definition (`blt_emitter.h`/`.c`) and the host renderer's one call site.

- [ ] **Step 3: Extend `tests/blt_bgplane_write_test.c` for the new flag**

Read the existing test file (67 field-mapping assertions per its header comment) first to match its `CHECK`/decode-roundtrip style, then add a case asserting `blt_bgplane_write_cell(..., BLT_F_BGCOV)` round-trips with `c.flags == BLT_F_BGCOV` after decode (mirroring however the existing test decodes `c.opcode`/`c.dst_x`/etc. from the emitted ring bytes — follow that exact pattern for `c.flags`).

- [ ] **Step 4: Run the host test and confirm PASS**

Run: `bash tests/run_tests.sh 2>&1 | grep -A2 "blt_bgplane_write"`
Expected: the `blt_bgplane_write` section runs with no `FAIL` lines.

- [ ] **Step 5: Commit**

```bash
git add patches/mister/blitter/blt_emitter.h patches/mister/blitter/blt_emitter.c \
        tests/blt_bgplane_write_test.c
git commit -m "feat(host): BLT_F_BGCOV-carrying blt_fill_flags/blt_bgplane_write_cell"
```

---

### Task 5: Host — switch the base-layer bake to ARGB4444/PALPHA, flip ordering (first real fix for map 119)

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp`

**Interfaces:**
- Consumes: `blt_fill_flags`, `blt_bgplane_write_cell(..., flags)` (Task 4), `BLT_BLEND_PALPHA`/`BLT_FMT_ARGB4444` (already exist, used elsewhere in this file for sprites).
- Produces: no new interface — this task changes *behavior* of the existing single-base-layer bake without yet generalizing to multi-layer (Task 6). This is the first task where map 119's actual perf number should move.

This is the highest-value, most self-contained increment: it makes the EXISTING base-layer-only bake alpha-aware and flips its ordering, without touching the per-layer generalization yet. It should already fix map 119 (base layer no longer disqualified by parallax) and is independently HW-validatable before Task 6's larger refactor.

- [ ] **Step 1: Bake as ARGB4444 with coverage-clearing FILL**

In `bake_background_plane_step()` (around line 2041, the per-cell clear), change:

```cpp
  blt_fill(&d->em, 0, 0, FB_W, FB_H, d->bg_clear_rgb565);
```

to:

```cpp
  // [ARGB4444 plane bake] clear-color is irrelevant now -- BLT_F_BGCOV makes this
  // FILL's own pixel-write loop clear the bake-coverage tracker (bgplane_coverage.sv)
  // instead of painting a background-color fill. Any tile subsequently painted this
  // cell sets its own covered pixels' coverage back to 1; anything left untouched
  // stays 0 (transparent) when OP_BGPLANE_WRITE packs this cell as ARGB4444 below.
  blt_fill_flags(&d->em, 0, 0, FB_W, FB_H, 0, BLT_F_BGCOV);
```

(leave the tile-painting loop below it — `blt_tile_list_static` calls — unchanged; their existing blend/key logic is what the fabric's write-tap already respects, per Task 1's design)

- [ ] **Step 2: Bake with `BLT_F_BGCOV` (ARGB4444 pack mode)**

Find the `blt_bgplane_write_cell` call site in `bake_background_plane_step()` (search for it — the function that emits `BLT_OP_BGPLANE_WRITE` after the per-cell paint) and add the flag:

```cpp
  blt_bgplane_write_cell(&d->em, qw_off, stride_qw, BLT_F_BGCOV);
```

- [ ] **Step 3: Read the plane back as ARGB4444 + PALPHA**

In `resident_emit_static_layer()` (lines 2500-2524), change:

```cpp
  plane_ref.format    = BLT_FMT_RGB565;   // matches comp_fbram's RGB565-class content
```

to:

```cpp
  plane_ref.format    = BLT_FMT_ARGB4444;   // [ARGB4444 plane bake] real per-pixel alpha;
                                             // gaps (alpha=0) leave whatever's already
                                             // drawn on this layer untouched -- see
                                             // BLT_BLEND_PALPHA below.
```

and:

```cpp
  blt_blit(&d->em, plane_ref, cx, cy, FB_W, FB_H, 0, 0, BLT_BLEND_COPY, 0, 255, 0);
```

to:

```cpp
  blt_blit(&d->em, plane_ref, cx, cy, FB_W, FB_H, 0, 0, BLT_BLEND_PALPHA, 0, 255, 0);
```

- [ ] **Step 4: Flip ordering — neuter `resident_static_before_animated`**

The plane COPY no longer needs to fire before anything else on its layer (alpha=0 gaps make it safe to fire after animated ops, matching the per-bucket path's existing order — see the design spec's "Root cause" section on patch 0031). Change (line 2526-2533):

```cpp
bool MisterBlitterRenderer::resident_static_before_animated(int layer) const {
  // Only while the flattened plane is actually what's about to draw for THIS
  // layer -- i.e. only the base layer (bg_base_layer, latched from
  // map.get_min_layer() in resident_begin_frame). Every other layer's
  // per-bucket replay fallback is order-independent, same as the default
  // no-op renderer's false. See docs/superpowers/specs/2026-07-08-bgplane-base-layer-occlusion-design.md.
  return d->bgplane_enabled && d->bg_plane_valid && layer == d->bg_base_layer;
}
```

to:

```cpp
bool MisterBlitterRenderer::resident_static_before_animated(int /*layer*/) const {
  // [ARGB4444 plane bake] Always false now: the plane COPY is BLT_BLEND_PALPHA,
  // safe to fire in the SAME position the per-bucket path already uses (after
  // animated ops -- patch 0031), for every layer including the base layer. This
  // override (and the whole resident_static_before_animated mechanism) becomes
  // dead code once Task 6/7 confirm nothing else needs it -- see
  // docs/superpowers/specs/2026-07-09-parallax-layer-compositor-design.md.
  return false;
}
```

(Full removal of the mechanism is deferred to Task 7, once Task 6's generalization confirms no other layer-ordering need surfaces — keep the change minimal and easy to bisect here.)

- [ ] **Step 5: Cross-build and confirm it compiles**

Run: `bash scripts/docker_run.sh scripts/build_engine.sh 2>&1 | tail -20`
Expected: `[100%] Built target solarus-run`.

- [ ] **Step 6: Host regression — full suite**

Run: `bash tests/run_tests.sh`
Expected: no `FAIL` lines (this task doesn't change `compute_bgplane_bounds` or any other host-tested pure function, so this is a regression check, not new coverage).

- [ ] **Step 7: HW validate — map 4 (regression) and map 119 (the actual fix)**

Deploy per this repo's standard recipe (`./deploy.py --no-rbf --host 192.168.20.81`, engine-only — the RTL from Tasks 1-3 needs its own RBF build+deploy first if not already on the device from CI). Confirm:
1. Map 4: canopy/doorframe occlusion still correct (walk the hero under tree canopy — should stay hidden, same as the PR #79 validation).
2. Map 119: parallax now renders correctly (behind the ground, not in front) AND `fabric_hw` diag counter drops from ~52.8ms toward the map-4 ballpark (~9ms) — this is the actual perf fix landing.

Expected: both correct, map 119's `fabric_hw` comfortably under 16.7ms.

- [ ] **Step 8: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "fix(render): base-layer plane bake as ARGB4444/PALPHA, fire after animated ops"
```

---

### Task 6: Host — generalize to per-layer baking, remove the scroll_ratio disqualification

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp`
- Modify: `patches/mister/blitter/bgplane_bounds.h` (confirm/adjust the existing per-layer parametrization — likely no change needed, per the design spec's note that it's already layer-parametrized)
- Modify: `tests/bgplane_bounds_test.cpp`

**Interfaces:**
- Consumes: Task 5's ARGB4444/PALPHA bake path (now proven correct for one layer).
- Produces: every layer with static content gets its own bake; `d->bg_base_layer` and the single flat `bg_*` field set are replaced by a per-layer table.

- [ ] **Step 1: Replace the flat `bg_*` fields with a per-layer struct**

In the `Impl` struct (around lines 507-548), replace:

```cpp
  bool     bgplane_enabled  = false;
  bool     bg_plane_valid   = false;
  bool     bg_baking        = false;
  bool     bg_plane_copied_this_frame = false;
  uint32_t bg_plane_sdram_base = 0;
  bool     bg_plane_sdram_allocated = false;
  int      bg_bake_cell_idx = 0;
  int      bg_base_layer = 0;
  int      bg_map_w = 0, bg_map_h = 0;
  int      bg_origin_x = 0, bg_origin_y = 0;
  uint16_t bg_clear_rgb565 = 0;
```

with:

```cpp
  bool bgplane_enabled = false;   // SOLARUS_BGPLANE, opt-in (unchanged)
  // [ARGB4444 plane bake] one bake per layer that has static content, keyed by
  // layer instead of a single hardcoded bg_base_layer. bg_clear_rgb565 is gone --
  // ARGB4444 alpha=0 gaps need no clear-color tracking (see patch 0033 removal,
  // Task 7).
  struct BgPlane {
    bool     valid = false;
    bool     baking = false;
    bool     copied_this_frame = false;
    uint32_t sdram_base = 0;
    bool     sdram_allocated = false;
    int      bake_cell_idx = 0;
    int      map_w = 0, map_h = 0;
    int      origin_x = 0, origin_y = 0;
  };
  std::unordered_map<int, BgPlane> bg_planes;   // keyed by layer
```

- [ ] **Step 2: Generalize `res_arm_()` to compute bounds per eligible layer**

Read the current `res_arm_()` (lines 2213-2363) in full before editing — it currently: (a) computes bounds ONLY from `bg_base_layer`-tagged buckets via `compute_bgplane_bounds`, (b) scans for `scroll_ratio != 1` on the base layer to disqualify the whole map. Change it to:
- Collect the DISTINCT set of layers present in `d->res_static_buckets` (a `std::set<int>` or similar).
- For each such layer, call `compute_bgplane_bounds()` filtered to that layer (the function is already layer-parametrized per `bgplane_bounds.h` — confirm its signature takes a target layer, adjust the call site accordingly), and populate `d->bg_planes[layer]` (allocate its own SDRAM region via the same `blt_alloc` path the single plane used, sized to that layer's own bounds).
- Delete the `scroll_ratio != 1` disqualification scan entirely — no per-layer or per-map disqualification remains; every layer with static content gets a plane.

- [ ] **Step 3: Generalize `bake_background_plane_step()` to iterate whichever layer(s) are baking**

Currently bakes cells for the single implicit base-layer plane. Change to iterate `d->bg_planes`, advancing whichever plane(s) still have `baking == true` and `bake_cell_idx < total_cells_for_that_layer`, one cell per `present()` call as today (the incremental cells/frame budget is unchanged — just now shared/sequenced across however many layers are baking).

- [ ] **Step 4: Generalize `resident_emit_static_layer(layer)`**

Change the condition (currently `layer != d->bg_base_layer` falls back to per-bucket) to look up `d->bg_planes.find(layer)` — if absent, invalid, or still baking, fall back to per-bucket (`res_emit_static_bucket_`) for that layer only; if present and valid, emit the `BLT_BLEND_PALPHA` COPY using that layer's own `sdram_base`/`map_w`/`map_h`/`origin_x`/`origin_y` (same logic Task 5 already built for the single-plane case, just reading from `d->bg_planes[layer]` instead of the flat fields).

- [ ] **Step 5: Extend `tests/bgplane_bounds_test.cpp` for true multi-layer bakes**

Read the existing test first (67 lines, covers "multi-layer filtering, negative-origin compensation, the zero-match case, and an empty-input case" per the design spec's Testing section) — add a case that computes bounds for TWO different layers from the SAME input bucket set and asserts they produce independent, correctly-filtered bounding boxes (not just that filtering excludes the wrong layer, which existing cases likely already cover, but that two calls with different target layers on the same data don't interfere with each other — relevant now that `res_arm_()` calls this function in a loop).

- [ ] **Step 6: Run host tests, cross-build**

Run: `bash tests/run_tests.sh 2>&1 | grep -A2 bgplane_bounds`
Expected: no `FAIL`.

Run: `bash scripts/docker_run.sh scripts/build_engine.sh 2>&1 | tail -10`
Expected: `[100%] Built target solarus-run`.

- [ ] **Step 7: HW validate — a non-base-layer occlusion map**

Find (or note as a gap if none exists in Mystery of Solarus DX and construct a minimal test map) a map with static occluding content on a layer OTHER than the base layer that also has enough content to be worth baking. Confirm: occlusion still correct, and that layer's `fabric_hw` contribution drops versus its old per-bucket cost. Re-confirm map 4 and map 119 (Task 5's cases) still pass — this task changes shared code paths (`res_arm_`, `bake_background_plane_step`) even though its main new behavior is additive.

- [ ] **Step 8: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp tests/bgplane_bounds_test.cpp
git commit -m "feat(render): generalize plane bake to every layer, remove scroll_ratio disqualification"
```

---

### Task 7: Cleanup — remove patch 0033 and `resident_static_before_animated`

**Files:**
- Modify: `work/solarus/src/entities/Entities.cpp` (edit in the live clone, then export)
- Modify: `work/solarus/include/solarus/graphics/Renderer.h` (edit in the live clone, then export)
- Modify: `patches/mister/mister_blitter_renderer.cpp` (remove `mister_set_background_color`'s bake-side consumer if any remains; keep the publish call itself — `Game::draw` still needs it for the per-frame fill)
- Modify: `patches/mister/mister_blitter_renderer.h` (remove the now-unused override declaration if the base virtual is deleted)
- Regenerate: `patches/series/*.patch` (via `scripts/export_patches.sh`)

**Interfaces:**
- Removes: `Renderer::resident_static_before_animated(int)` (base virtual + override), the `_static_first` branch in `Entities::draw()`, `Impl::bg_clear_rgb565` and its consumer (already gone after Task 5/6, confirm no dangling reference remains).

This is pure deletion of now-dead code, made safe by Task 5's ordering flip (every layer already returns `false` in practice) and Task 6's removal of the last field that referenced `bg_clear_rgb565`. Deferred to its own task so Tasks 5-6 stay bisectable if HW validation surfaces a problem.

- [ ] **Step 1: Confirm nothing still calls the true branch**

Run: `grep -n "resident_static_before_animated\|bg_clear_rgb565" patches/mister/mister_blitter_renderer.cpp patches/mister/mister_blitter_renderer.h`
Expected: only the (now-always-false) override from Task 5, no `bg_clear_rgb565` references (Task 6 already removed the field).

- [ ] **Step 2: Delete the override from the host renderer**

Remove `resident_static_before_animated`'s declaration from `mister_blitter_renderer.h` (line 93 area) and its definition from `mister_blitter_renderer.cpp` (Task 5's now-dead `return false;` version).

- [ ] **Step 3: Delete the base virtual and the `_static_first` branch in the live clone**

In `work/solarus/include/solarus/graphics/Renderer.h`, remove the `virtual bool resident_static_before_animated(int /*layer*/) const { return false; }` line (~line 139).

In `work/solarus/src/entities/Entities.cpp`, find the `_static_first` usage (the code patch 0034/0035 introduced — search `resident_static_before_animated` in this file) and restore the unconditional animated-then-static order patch 0031 established (remove the `if (_static_first) { ... } else { ... }` branching entirely, keeping just the unconditional animated-ops-then-static-emit sequence).

- [ ] **Step 4: Commit in the live clone and export**

```bash
cd work/solarus
git add include/solarus/graphics/Renderer.h src/entities/Entities.cpp
git commit -m "chore: remove resident_static_before_animated (dead after ARGB4444 plane bake)"
cd ../..
bash scripts/export_patches.sh
```

- [ ] **Step 5: Confirm the regenerated series still applies clean and builds**

Run: `bash scripts/docker_run.sh scripts/build_engine.sh 2>&1 | tail -20`
Expected: `[apply] OK` (the `git am --3way` + ast-grep verify gate) followed by `[100%] Built target solarus-run`.

- [ ] **Step 6: Full regression — host tests + sim suite**

Run: `bash tests/run_tests.sh && bash fpga/sim/run_sims.sh`
Expected: both `RESULT: PASS`.

- [ ] **Step 7: HW re-validate map 4 + map 119**

Confirm both still correct after the dead-code removal (should be a no-op behaviorally — this task is not expected to change any HW-visible behavior, only delete code that was already unreachable).

- [ ] **Step 8: Commit the outer-repo changes**

```bash
git add patches/mister/mister_blitter_renderer.cpp patches/mister/mister_blitter_renderer.h \
        patches/series/
git commit -m "chore(render): delete resident_static_before_animated mechanism (dead code)"
```

---

### Task 8: Docs + full HW validation matrix

**Files:**
- Modify: `docs/frame-dataflow.md` (note the generalized per-layer plane bake in the "What replaced what" section)
- Modify: `docs/env-variables.md` (add/update the `SOLARUS_BGPLANE` entry if one doesn't already describe the per-layer behavior)

- [ ] **Step 1: Update `docs/frame-dataflow.md`**

Add a short entry to the "What replaced what" list (after the `#66` bullet) describing the per-layer ARGB4444 plane bake, referencing this plan's design spec and citing the map-119 perf number before/after.

- [ ] **Step 2: Update/add the `SOLARUS_BGPLANE` entry in `docs/env-variables.md`**

Run: `grep -n "SOLARUS_" docs/env-variables.md | head -5` first to match the existing entry format/style, then document: default state, that it now applies per-layer (not just the base layer), and that the scroll_ratio disqualification no longer exists.

- [ ] **Step 3: Full HW validation matrix (per the design spec's Testing section)**

1. Map 4: canopy/doorframe occlusion + background color correct, no patch-0033 workaround needed, `fabric_hw` ≤ today's ~9.2ms.
2. Map 119: parallax correct, `fabric_hw` near the map-4 ballpark (well under 16.7ms).
3. The non-base-layer occlusion map from Task 6 Step 7: still correct.
4. Forced per-layer bake failure (temporarily shrink an SDRAM allocation budget to force one layer's `blt_alloc` to fail) — confirm that layer alone falls back to per-bucket, every other layer's plane unaffected, no crash/corruption.
5. Regression sweep: the existing perf-campaign map set referenced in the design spec (idlepark/staticpark maps) — confirm no fps regression from this session's changes.

Expected: all five pass. Record actual `fabric_hw` numbers for cases 1-2 in the commit message / a follow-up doc note, mirroring how the design spec recorded PR #79's numbers.

- [ ] **Step 4: Commit**

```bash
git add docs/frame-dataflow.md docs/env-variables.md
git commit -m "docs: per-layer ARGB4444 plane bake in frame-dataflow + env-variables"
```

---

## Self-Review

**Spec coverage:** Task 1-3 implement the design's "Fabric: OP_BGPLANE_WRITE's writeback mux gains an ARGB4444 pack mode" + "read side needs no new RTL" (confirmed — Task 5 only changes the host-side `blt_blit` call, zero RTL touched for the read path). Task 5 implements "the plane COPY becomes a BLT_BLEND_PALPHA blit... fires after that layer's animated ops." Task 6 implements "generalize into one bake per layer... delete the scroll_ratio scan entirely." Task 7 implements "patch 0033... should be removed" and the base-layer ordering special case removal. Task 8 covers the design's full HW validation matrix. The "Open question for the implementation plan" (dedicated op variant vs. mode bit) is resolved in Task 1/3: reused `BLT_F_BGCOV` on the existing `OP_FILL`/`OP_BGPLANE_WRITE` opcodes rather than a new opcode, since `c_flags` was already fully decoded and available for every opcode with zero new plumbing.

**Placeholder scan:** no TBD/TODO. Task 6 Step 7 and Task 8 Step 3 both note "find or construct" a non-base-layer test map as a real open item rather than hiding it — flagged explicitly, not silently assumed to exist.

**Type consistency:** `blt_bgplane_write_cell`'s signature change (Task 4) is consumed with the new `flags` argument consistently in Task 5 Step 2. `d->bg_planes[layer]` (Task 6) is referenced with the same field names (`sdram_base`, `map_w`, `map_h`, `origin_x`, `origin_y`, `valid`, `baking`, `copied_this_frame`, `bake_cell_idx`) in Tasks 6 Step 3-4 as defined in Task 6 Step 1. `bgplane_coverage`'s port names (`wr_en/wr_qw/wr_lane/wr_clear/rd_en/rd_qw/rd_nibble`) are used identically across Task 1 Step 3 (instantiation) and Task 2/3 (consumption via `fbram_to_sdram`'s new `rd_cov` port, fed from `bgcov_rd_nibble`).
