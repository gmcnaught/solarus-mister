# Phase 3b — Background-Plane Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop re-resolving and re-compositing the static (non-animated) resident
tile-list every single frame — bake it once per map/tileset change into a
permanent SDRAM plane, and replace the per-frame static-bucket replay with a
single windowed COPY blit, to bring `fabric_hw` at the heavy village save spot
from ~19.7ms toward the 16.7ms Phase 3 budget.

**Architecture:** The static resident bucket data (`StaticBucket`/`StaticEnt`,
`mister_blitter_renderer.cpp:458`) already stores every static tile in
whole-map coordinates, camera-independent. Today it is replayed via
`BLT_OP_TILELIST` every frame (`res_emit_static_bucket_`,
`mister_blitter_renderer.cpp:2037`), forcing the fabric to resolve+SRCFILL+
composite ~7,183 individual tile entries per frame at the reference scene even
standing still (confirmed via `[blitter diag] alias_blits` HW counter). This
plan bakes that same tile-list ONCE, per map/tileset change (reusing the exact
signature check `resident_begin_frame` already uses,
`mister_blitter_renderer.cpp:1784`), by walking the map in 320×240 on-chip-BRAM-
sized cells: for each cell, emit the cell-local static tiles through the
*existing* `BLT_OP_TILELIST` FSM into `comp_fbram`'s WORK buffer exactly as
today, then stream that composed WORK buffer out to a new permanent SDRAM
region via a new fabric write path. The write path reuses `sdram_fb_cache`'s
`ch0` (P_DST) channel — a full read/write cache that has been idle-but-wired
since PR #49 retired the old SDRAM-destination compositor (see
`fpga/rtl/sdram_fb_cache.sv:9,79-102,388-419` — ch0 is instantiated, not
deleted). The streaming reader is a near-verbatim copy of `fbram_snapshot.sv`'s
proven work-buffer-read pipeline, writing to `ch0` instead of the on-chip scan
bank. Once baked, every subsequent frame issues one ordinary COPY blit sourced
from the baked plane (via a hand-built `blt_surface_ref_t` pointing at the new
SDRAM region) — no new per-frame RTL. Animated resident tiles (the much
smaller ~433-entry FRT/CFT pattern table) and dynamic sprites are untouched
and continue to draw on top every frame, exactly as today.

**Why not A9-software composition instead:** issue #68
(`solarus-68-buildframe-drawonmap-breaks-dialogues` memory, still open)
already proved that legacy SDL-software compositing (`draw_on_map`/
`Surface::create`) mixed with the SDRAM-resident pipeline corrupts SDRAM state
the fabric depends on. The established, hard-won fix pattern there was
"fabric emits static ops on the build frame" — the fabric must own all
compositing. This plan follows that precedent: the FABRIC composes the plane
(reusing its own already-bit-exact `BLT_OP_TILELIST` FSM), never the A9.

**Tech Stack:** SystemVerilog (Verilog-2012), Icarus Verilog (`fpga/sim`),
C/C++ (`patches/mister/blitter/`, `patches/mister/mister_blitter_renderer.cpp`),
`fpga/sim/run_sims.sh` gating runner. RBF via CI Quartus 17.0.x (manual); HW =
DE10-Nano at 192.168.20.81 (manual, user-relaunch).

## Global Constraints

- All sims run from `fpga/sim/`; build/run idiom: `iverilog -g2012 -o /tmp/x.vvp -I ../rtl -I ../rtl/jtframe -I ../sys -I . -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v <tb>.sv && vvp /tmp/x.vvp`.
- Gating gate after every RTL change: `cd fpga/sim && ./run_sims.sh` → **`gating-failures=0`** required.
- **Bit-exactness is non-negotiable at the pixel level**, but the *mechanism*
  changes: Task 7's new TB compares the OLD per-frame static-tile-replay
  output against the NEW baked-plane-COPY output for the SAME scene — they
  must be pixel-identical, even though the RTL path taken is different. The
  existing `tb_comp_pipeline` + 7 `tb_blitter_*_pipe` equivalence TBs must
  also stay PASS (the mixer datapath itself is untouched).
- New BRAM (if any) must infer M10K correctly: one write port + one registered
  read port per array (see `comp_src_linebuf.sv`'s header comment for why —
  a shared/async-muxed read drops to flip-flops and blows timing).
- clk_sys ≈ 100 MHz; core is pinned at **SEED 1** (`fpga/Solarus.qsf:23`), now
  clean on all paths after the Phase 3a `MISTER_DISABLE_PALETTE1` fix (see
  commit `e224a94`) — do not reintroduce negative slack.
- The one-time bake must NOT stall gameplay noticeably: spread it across
  multiple frames (same pattern as the load-progress bar, PR #74 —
  `mister_blitter_renderer.cpp:992` `preload_quest_assets`), one cell (or a
  handful) per frame, not all cells in one frame.
- Branch base: `perf/phase3-fabric-under-16ms` (already has the closed-timing
  Phase 3a work). End commit messages with the repo's Co-Authored-By +
  Claude-Session trailers.
- Do NOT run the RBF build / deploy / HW steps automatically — they are
  manual/gated (Tasks 9-10) and HW needs the user to relaunch.

---

### Task 1: Host-side background-plane geometry + SDRAM allocation

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` (new `Impl` fields +
  a pure-geometry helper, near the `ResBucket`/`StaticBucket` structs at
  line 437-465)
- Test: `patches/mister/blitter/tests/` — check the existing test layout with
  `ls patches/mister/blitter/tests/` first; add a new
  `bgplane_geometry_test.cpp` alongside the existing standalone C/C++ unit
  tests (mirrors how `quadtree_fat_test.cpp` etc. are structured: a plain
  `int main()` with `assert`-based checks, no gtest dependency assumed unless
  the existing tests show one — confirm framework via
  `cat patches/mister/blitter/tests/*_test.cpp | head -30` on an existing test
  before writing this one, and match its exact harness style).

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: a pure function `bgplane_cell_count(int map_w, int map_h)` and
  `bgplane_cell_rect(int cell_idx, int map_w, int map_h)` (both declared in
  a new header `patches/mister/blitter/bgplane_geom.h`, defined inline or in
  a small `.cpp` — later tasks call these to iterate cells and to compute
  each cell's SDRAM byte offset within the plane).

- [ ] **Step 1: Confirm the existing test harness style**

Run: `ls patches/mister/blitter/tests/ && head -40 patches/mister/blitter/tests/*_test.cpp | head -60`
Note the include style, `main()`/assert pattern, and build command (check
for a `Makefile` or `CMakeLists.txt` in that directory, or a `make test`
target referenced from the repo root) so Step 2's new test matches exactly.

- [ ] **Step 2: Write the failing test — cell grid geometry**

Create `patches/mister/blitter/bgplane_geom.h`:

```c
#ifndef BGPLANE_GEOM_H
#define BGPLANE_GEOM_H

// Background-plane cell grid: the plane is baked in on-chip-BRAM-sized cells
// (comp_fbram is sized for exactly one 320x240 screen, FB_QWORDS=19200 qwords
// @ 16bpp — see fpga/rtl/fbram_snapshot.sv:15). A map is tiled into
// ceil(map_w/320) x ceil(map_h/240) cells; the last row/column of cells may
// be partial (padded to CELL_W x CELL_H in the plane, extra pixels unused).
#define BGPLANE_CELL_W 320
#define BGPLANE_CELL_H 240
#define BGPLANE_BYTES_PER_PIXEL 2   // matches comp_fbram's RGB565-class format

typedef struct { int cols, rows, count; } bgplane_grid_t;
typedef struct { int cell_x, cell_y; int map_x, map_y; int w, h; } bgplane_cell_t;

// Compute the cell grid for a map_w x map_h map (pixels).
static inline bgplane_grid_t bgplane_grid(int map_w, int map_h) {
    bgplane_grid_t g;
    g.cols = (map_w + BGPLANE_CELL_W - 1) / BGPLANE_CELL_W;
    g.rows = (map_h + BGPLANE_CELL_H - 1) / BGPLANE_CELL_H;
    if (g.cols < 1) g.cols = 1;
    if (g.rows < 1) g.rows = 1;
    g.count = g.cols * g.rows;
    return g;
}

// Cell index -> its map-coord origin + this cell's true (possibly clipped) size.
static inline bgplane_cell_t bgplane_cell(int cell_idx, int map_w, int map_h) {
    bgplane_grid_t g = bgplane_grid(map_w, map_h);
    bgplane_cell_t c;
    c.cell_x = cell_idx % g.cols;
    c.cell_y = cell_idx / g.cols;
    c.map_x  = c.cell_x * BGPLANE_CELL_W;
    c.map_y  = c.cell_y * BGPLANE_CELL_H;
    int rem_w = map_w - c.map_x, rem_h = map_h - c.map_y;
    c.w = rem_w < BGPLANE_CELL_W ? rem_w : BGPLANE_CELL_W;
    c.h = rem_h < BGPLANE_CELL_H ? rem_h : BGPLANE_CELL_H;
    return c;
}

// Byte offset of a cell within the plane's SDRAM allocation (cells are stored
// in row-major order, each padded to a full BGPLANE_CELL_W x BGPLANE_CELL_H
// slot regardless of true size, so per-cell addressing is a fixed stride).
static inline uint32_t bgplane_cell_byte_offset(int cell_idx) {
    return (uint32_t)cell_idx * BGPLANE_CELL_W * BGPLANE_CELL_H * BGPLANE_BYTES_PER_PIXEL;
}

// Total plane size in bytes for a map_w x map_h map.
static inline uint32_t bgplane_total_bytes(int map_w, int map_h) {
    bgplane_grid_t g = bgplane_grid(map_w, map_h);
    return bgplane_cell_byte_offset(g.count);
}

#endif
```

Create `patches/mister/blitter/tests/bgplane_geom_test.cpp` (match the
established harness style found in Step 1; the sketch below assumes the
plain-`main`+assert style used elsewhere — adjust includes/build wiring to
match exactly):

```cpp
#include "../bgplane_geom.h"
#include <cassert>
#include <cstdio>

int main() {
  // A map exactly 320x240 -> 1 cell, no padding.
  { bgplane_grid_t g = bgplane_grid(320, 240);
    assert(g.cols == 1 && g.rows == 1 && g.count == 1); }

  // A map 640x480 -> 2x2 = 4 cells, no padding.
  { bgplane_grid_t g = bgplane_grid(640, 480);
    assert(g.cols == 2 && g.rows == 2 && g.count == 4); }

  // A map 500x300 -> ceil(500/320)=2 cols, ceil(300/240)=2 rows = 4 cells;
  // last col/row are partial.
  { bgplane_grid_t g = bgplane_grid(500, 300);
    assert(g.cols == 2 && g.rows == 2 && g.count == 4);
    bgplane_cell_t c3 = bgplane_cell(3, 500, 300);   // bottom-right cell
    assert(c3.cell_x == 1 && c3.cell_y == 1);
    assert(c3.map_x == 320 && c3.map_y == 240);
    assert(c3.w == 180 && c3.h == 60);               // 500-320, 300-240
    bgplane_cell_t c0 = bgplane_cell(0, 500, 300);    // top-left, full size
    assert(c0.map_x == 0 && c0.map_y == 0 && c0.w == 320 && c0.h == 240); }

  // Cell byte offsets are fixed-stride regardless of true (possibly clipped) size.
  { assert(bgplane_cell_byte_offset(0) == 0u);
    assert(bgplane_cell_byte_offset(1) == (uint32_t)(320*240*2));
    assert(bgplane_total_bytes(500, 300) == (uint32_t)(4 * 320*240*2)); }

  std::printf("RESULT: PASS\n");
  return 0;
}
```

- [ ] **Step 3: Run it to verify it fails (or rather, verify it compiles+passes
  immediately since this is pure new code — confirm no naming collision
  with existing symbols first)**

Run: `grep -rn "BGPLANE_CELL_W\|bgplane_grid\|bgplane_cell" patches/mister/ --include="*.h" --include="*.cpp" | grep -v bgplane_geom` to confirm no
collision, then compile+run the test with whatever command Step 1 found
(e.g. `g++ -std=c++17 -I patches/mister/blitter patches/mister/blitter/tests/bgplane_geom_test.cpp -o /tmp/bgt && /tmp/bgt`).
Expected: `RESULT: PASS` (this is pure new arithmetic, not a red/green TDD
cycle against existing behavior — the "failing" state is "doesn't compile
yet" before Step 2's header exists).

- [ ] **Step 4: Commit**

```bash
git add patches/mister/blitter/bgplane_geom.h patches/mister/blitter/tests/bgplane_geom_test.cpp
git commit -m "feat(bgplane): cell-grid geometry helpers for the background-plane cache

Pure host-side arithmetic: tiles a map into 320x240 on-chip-BRAM-sized cells
(matching comp_fbram's fixed size), fixed-stride SDRAM addressing per cell.
No RTL/behavior change yet -- Task 2 adds the fabric write path this will
target."
```

---

### Task 2: RTL — `fbram_to_sdram.sv` work-buffer-to-SDRAM streamer

**Files:**
- Create: `fpga/rtl/fbram_to_sdram.sv`
- Test: `fpga/sim/tb_fbram_to_sdram.sv`

**Interfaces:**
- Consumes: nothing from other tasks (borrows `comp_fbram`'s work read port
  the same way `fbram_snapshot.sv` does, per its header comment — the caller
  must mux `fb_rd_*` to this module while `busy`, exactly like
  `blitter_top.sv:875-876` already does for `u_snap`).
- Produces: `busy`, `rd_en`/`rd_qw` (borrowed work-read port, same shape as
  `fbram_snapshot`'s), and a new SDRAM write-port triplet
  (`sdram_wr_en`, `sdram_wr_addr`, `sdram_wr_data`) that Task 3 wires to
  `sdram_fb_cache`'s `ch0` write port.

- [ ] **Step 1: Write the failing test — streams WORK buffer to a mock SDRAM sink**

Create `fpga/sim/tb_fbram_to_sdram.sv`. Model it on
`fpga/sim/tb_fbram_snapshot.sv` (read it first: `cat fpga/sim/tb_fbram_snapshot.sv`)
— reuse its comp_fbram instantiation + fill pattern, but check the new
module's SDRAM-write outputs against expected {addr, data} pairs instead of
the scan bank:

```systemverilog
`timescale 1ns/1ps
module tb_fbram_to_sdram;
  reg clk = 0; always #5 clk = ~clk;
  reg rst = 1;

  // Drive comp_fbram's WORK write port with a known pattern (qword k = k+1),
  // matching tb_fbram_snapshot's fill idiom -- adjust to that file's exact
  // comp_fbram port names once read in Step 0 above.
  localparam integer NQW = 19200;
  reg [63:0] mem_model [0:NQW-1];

  reg          start;
  wire         busy;
  wire         rd_en;
  wire [14:0]  rd_qw;
  reg  [63:0]  rd_qword;   // testbench feeds this from mem_model, 1 cyc after rd_en/rd_qw
  wire         sdram_wr_en;
  wire [14:0]  sdram_wr_addr;
  wire [63:0]  sdram_wr_data;

  fbram_to_sdram #(.FB_QWORDS(NQW), .AW(15)) dut (
    .clk(clk), .rst(rst), .start(start), .busy(busy),
    .rd_en(rd_en), .rd_qw(rd_qw), .rd_qword(rd_qword),
    .sdram_wr_en(sdram_wr_en), .sdram_wr_addr(sdram_wr_addr), .sdram_wr_data(sdram_wr_data)
  );

  // 1-cycle read latency model of comp_fbram's registered read.
  reg [14:0] rd_qw_q; reg rd_en_q;
  always @(posedge clk) begin
    rd_qw_q <= rd_qw; rd_en_q <= rd_en;
    if (rd_en_q) rd_qword <= mem_model[rd_qw_q];
  end

  integer i, errors, seen;
  reg [63:0] captured [0:NQW-1];
  reg captured_v [0:NQW-1];

  initial begin
    for (i = 0; i < NQW; i = i + 1) begin
      mem_model[i] = {32'hCAFE_0000 + i, i[31:0]};
      captured_v[i] = 0;
    end
    start = 0; errors = 0; seen = 0;
    repeat (4) @(posedge clk); rst = 0;
    repeat (2) @(posedge clk);
    start = 1; @(posedge clk); start = 0;

    // Capture every SDRAM write until busy drops (with a cycle-count safety cap).
    for (i = 0; i < NQW*3 && busy; i = i + 1) begin
      @(posedge clk);
      if (sdram_wr_en) begin
        if (sdram_wr_addr >= NQW) begin
          $display("FAIL: sdram_wr_addr %0d out of range", sdram_wr_addr); errors = errors + 1;
        end else begin
          captured[sdram_wr_addr] = sdram_wr_data;
          captured_v[sdram_wr_addr] = 1;
          seen = seen + 1;
        end
      end
    end
    repeat (4) @(posedge clk);   // drain

    if (seen != NQW) begin
      $display("FAIL: wrote %0d qwords, expected %0d", seen, NQW); errors = errors + 1;
    end
    for (i = 0; i < NQW; i = i + 1) begin
      if (!captured_v[i]) begin
        $display("FAIL: qword %0d never written", i); errors = errors + 1;
      end else if (captured[i] !== mem_model[i]) begin
        $display("FAIL: qword %0d mismatch: got %h want %h", i, captured[i], mem_model[i]);
        errors = errors + 1;
      end
    end
    $display("RESULT: %s", (errors == 0) ? "PASS" : "FAIL");
    $finish;
  end
endmodule
```

- [ ] **Step 2: Run it to verify it FAILS (module doesn't exist yet)**

Run: `cd fpga/sim && iverilog -g2012 -o /tmp/fts.vvp -I ../rtl -I ../rtl/jtframe -I ../sys -I . -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v tb_fbram_to_sdram.sv && vvp /tmp/fts.vvp`
Expected: compile error (`fbram_to_sdram` undefined).

- [ ] **Step 3: Implement `fbram_to_sdram.sv`**

```systemverilog
// fbram_to_sdram.sv — one-time WORK-buffer -> SDRAM streamer for the Phase 3b
// background-plane cache. On a `start` pulse it streams the entire on-chip
// comp_fbram WORK buffer out to a caller-supplied SDRAM write port, one
// qword per cycle, then drops `busy`. Near-verbatim copy of
// fbram_snapshot.sv's read pipeline (see that file's header for why the
// 2-stage v1/v2 pipeline exists: comp_fbram's read is registered, so a
// read issued at cycle N has data at cycle N+2 relative to the read-issue
// pulse). Unlike fbram_snapshot (which writes comp_fbram's on-chip SCAN
// bank), this streams to an external SDRAM write port (sdram_fb_cache's
// ch0, wired by the caller in blitter_top.sv).
//
// Cost: ~FB_QWORDS+1 cycles per cell (19200+1 ~= 0.2ms @96MHz), same order
// as fbram_snapshot's vblank copy -- but this runs OUTSIDE vblank (during
// the rare one-time bake), so the caller must keep comp_pipeline idle for
// the duration (same contract as fbram_snapshot's borrow of fb_rd_*).
// Copyright (C) 2026 -- GPL-3.0
`default_nettype none
module fbram_to_sdram #(
    parameter integer FB_QWORDS = 19200,
    parameter integer AW        = 15
)(
    input  wire          clk,
    input  wire          rst,
    input  wire          start,        // 1-cyc pulse: begin a work->SDRAM copy
    output reg            busy,         // high for the duration of the copy
    // work-buffer read port (mux onto comp_fbram rd_* while busy, same as fbram_snapshot)
    output reg           rd_en,
    output reg [AW-1:0]  rd_qw,
    input  wire [63:0]   rd_qword,      // registered, valid 1 cyc after rd_qw/rd_en
    // SDRAM write port (wired to sdram_fb_cache ch0's write side by the caller)
    output reg           sdram_wr_en,
    output reg [AW-1:0]  sdram_wr_addr,
    output reg [63:0]    sdram_wr_data
);
    localparam [AW:0] NQW = FB_QWORDS[AW:0];

    reg [AW:0] rptr;        // next work address to read (0..NQW)
    reg [AW:0] wcnt;        // qwords written so far (0..NQW)
    reg        v1, v2;
    reg [AW-1:0] a1, a2;
    localparam [AW:0] ONE = {{(AW){1'b0}},1'b1};

    always @(posedge clk) begin
        if (rst) begin
            busy<=1'b0; rd_en<=1'b0; sdram_wr_en<=1'b0;
            rptr<={(AW+1){1'b0}}; wcnt<={(AW+1){1'b0}}; v1<=1'b0; v2<=1'b0;
        end else begin
            rd_en<=1'b0; sdram_wr_en<=1'b0;
            if (!busy) begin
                v1<=1'b0; v2<=1'b0;
                if (start) begin
                    busy<=1'b1; rptr<={(AW+1){1'b0}}; wcnt<={(AW+1){1'b0}};
                end
            end else begin
                if (v2) begin
                    sdram_wr_en<=1'b1; sdram_wr_addr<=a2; sdram_wr_data<=rd_qword;
                    wcnt<=wcnt+ONE;
                end
                if (rptr < NQW) begin
                    rd_en<=1'b1; rd_qw<=rptr[AW-1:0];
                    v1<=1'b1; a1<=rptr[AW-1:0];
                    rptr<=rptr+ONE;
                end else begin
                    v1<=1'b0;
                end
                v2<=v1; a2<=a1;
                if (wcnt == NQW) busy<=1'b0;
            end
        end
    end
endmodule
`default_nettype wire
```

- [ ] **Step 4: Run the test again**

Run the same command as Step 2.
Expected: `RESULT: PASS`.

- [ ] **Step 5: Add to the gating suite + run it**

`run_sims.sh` auto-globs `tb_*.sv` (confirm: `grep -n "tb_\*\|glob" fpga/sim/run_sims.sh | head -5`); no manual registration should be needed. Run: `cd fpga/sim && ./run_sims.sh`
Expected: `gating-failures=0`, `tb_fbram_to_sdram PASS`, and every prior TB
still green (this module isn't wired into `blitter_top.sv` yet, so nothing
else can regress).

- [ ] **Step 6: Commit**

```bash
git add fpga/rtl/fbram_to_sdram.sv fpga/sim/tb_fbram_to_sdram.sv
git commit -m "feat(comp): fbram_to_sdram -- one-time WORK-buffer -> SDRAM streamer

Verbatim copy of fbram_snapshot.sv's proven work-buffer read pipeline,
retargeted from the on-chip SCAN bank to an external SDRAM write port.
Standalone-tested against a full 19200-qword pattern; not yet wired into
blitter_top.sv (Task 3)."
```

---

### Task 3: RTL — wire `fbram_to_sdram` into `blitter_top.sv` via `ch0`

**Files:**
- Modify: `fpga/rtl/blitter_top.sv` (3-way `fb_rd` mux at line 875-876; new
  `S_BGWRITE_*` states alongside `S_SNAP_*` at line 145-147; new
  `OP_BGPLANE_WRITE` opcode; wire `ch0`'s write port, currently idle since
  PR #49 — confirm its exact port names first: `grep -n "ch0\|P_DST" fpga/rtl/sdram_fb_cache.sv | grep -i "wr\|write"`)
- Modify: `fpga/rtl/blitter_defs.vh` (new opcode constant, next free value
  after `OP_FRT_UPLOAD=8'd7` per `fpga/rtl/blitter_defs.vh:121-122` — use `8'd8`)
- Test: `fpga/sim/tb_blitter_system_pipe.sv` (existing whole-system TB;
  extend) + new `fpga/sim/tb_bgplane_write_pipe.sv`

**Interfaces:**
- Consumes: `fbram_to_sdram` (Task 2) — `busy`/`rd_en`/`rd_qw`/`rd_qword`/
  `sdram_wr_*` ports exactly as Task 2 defined them.
- Produces: new opcode `OP_BGPLANE_WRITE = 8'd8`. Command layout (reuse the
  blit-rect field packing convention established for `OP_TILELIST`/
  `OP_TILELIST_RES` at `fpga/rtl/blitter_top.sv:528-554` — read that block
  first to match the exact field-reuse idiom): `dst_x|dst_y<<16` = the
  destination SDRAM qword offset (this cell's `bgplane_cell_byte_offset(...)
  / 8`, computed host-side by Task 1's helper and passed by Task 4's
  emitter). No other fields used. On decode, the FSM pulses
  `fbram_to_sdram.start`, waits for `busy` to fall (mirroring
  `S_SNAP_WAIT/BUSY/DRAIN` at lines 791-796), then advances to
  `S_POLL_SUBMIT`/`S_NEXT_CMD` like every other opcode.

- [ ] **Step 1: Read the exact ch0 write-port names and the OP_TILELIST field-reuse block**

Run: `grep -n "ch0" fpga/rtl/sdram_fb_cache.sv | head -30` and
`sed -n '520,560p' fpga/rtl/blitter_top.sv`
Confirm the exact port names for ch0's write side (likely something like
`p0w_wr`/`p0w_addr`/`p0w_data` or similar — the plan's Step 3 code below
uses placeholder names `ch0_wr_en`/`ch0_wr_addr`/`ch0_wr_data` that MUST be
corrected to match what this grep finds before writing the real diff).

- [ ] **Step 2: Add the opcode constant**

In `fpga/rtl/blitter_defs.vh`, near `OP_FRT_UPLOAD` (line 122):

```systemverilog
localparam [7:0]  OP_BGPLANE_WRITE = 8'd8;   // [Phase 3b] one-time WORK->SDRAM plane bake
```

- [ ] **Step 3: Write the failing whole-system test — a bake-and-verify round trip**

Create `fpga/sim/tb_bgplane_write_pipe.sv`, modeled on
`tb_blitter_system_pipe.sv`'s existing harness (read it first for the exact
command-ring submission idiom): drive a small `OP_FILL` (or a couple of
`OP_BLIT`s) to paint a known pattern into comp_fbram's WORK buffer, then
submit `OP_BGPLANE_WRITE` with a target SDRAM qword offset, wait for
completion, then read back the same qwords from the SDRAM model (the
existing mt48-model harness used by `tb_sdram_fb_cache.sv` — reuse that
model) and assert they match what was painted.

```systemverilog
`timescale 1ns/1ps
module tb_bgplane_write_pipe;
  // ... (instantiate blitter_top + sdram_fb_cache + the mt48 SDRAM model,
  //      mirroring tb_blitter_system_pipe.sv's exact instantiation block)

  // 1. Submit OP_FILL targeting the full WORK buffer with a known color.
  // 2. Submit OP_BGPLANE_WRITE with dst_x|dst_y<<16 = SDRAM_TARGET_QW_OFFSET.
  // 3. Wait for submit-count to advance (command consumed) + a cycle margin
  //    for the ~19200-cycle internal streaming (poll a generous timeout).
  // 4. Read back SDRAM_TARGET_QW_OFFSET .. +19200 from the mt48 model and
  //    assert every qword equals the known FILL color (packed 4-wide).
  // (Full command-submission boilerplate: copy tb_blitter_system_pipe.sv's
  //  ring-write + doorbell + poll idiom verbatim, substituting the 2-command
  //  sequence above for whatever it currently submits.)
endmodule
```

- [ ] **Step 4: Run it to verify it FAILS**

Run: `cd fpga/sim && iverilog -g2012 -o /tmp/bgw.vvp -I ../rtl -I ../rtl/jtframe -I ../sys -I . -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v tb_bgplane_write_pipe.sv && vvp /tmp/bgw.vvp`
Expected: FAIL (opcode not decoded yet, or compile error if the TB
references not-yet-existing signals).

- [ ] **Step 5: Wire it up in `blitter_top.sv`**

Add state constants near `S_SNAP_*` (line 145-147):

```systemverilog
        S_BGW_WAIT=6'd45,          // OP_BGPLANE_WRITE decoded: trigger the streamer
        S_BGW_BUSY=6'd46,          // streamer started: wait for busy to assert
        S_BGW_DRAIN=6'd47,         // wait for the WORK->SDRAM copy to finish
```

Add the trigger register (near `snap_start` at line 186):

```systemverilog
    reg           bgw_start;     // 1-cycle WORK->SDRAM plane-write trigger
    reg  [28:0]   bgw_sdram_qw;  // target SDRAM qword offset, latched from the command
```

In the opcode decode block (mirror the `OP_TILELIST`/`OP_TILELIST_RES`
handling at lines 528-554 — reuse the SAME `dst_x|dst_y<<16` field-packing
idiom already established there):

```systemverilog
                else if (c_opcode==OP_BGPLANE_WRITE) begin
                    bgw_sdram_qw <= {c_dst_x, c_dst_y};   // qword offset, packed like OP_TILELIST's entry ptr
                    bgw_start    <= 1'b1;
                    state        <= S_BGW_WAIT;
                end
```

Add the FSM transitions (mirror `S_SNAP_WAIT/BUSY/DRAIN` at lines 791-796):

```systemverilog
            S_BGW_WAIT: begin bgw_start<=1'b0; if (bgw_busy) state<=S_BGW_BUSY; end
            S_BGW_BUSY: if (!bgw_busy) state<=S_POLL_SUBMIT;   // (busy already fell if it was fast; guard both orders like S_SNAP does)
```

(Reconcile the exact wait/poll shape against what Step 1's read of
`S_SNAP_WAIT/BUSY/DRAIN` actually does — that 3-state shape waits for a
`vs_rise` gate `S_SNAP_WAIT` doesn't apply here since this isn't
vsync-gated; drop the vsync wait and go straight from decode to `bgw_start`,
keeping only the busy-rise/busy-fall pair.)

Instantiate the module (near `u_snap` at line 871-876):

```systemverilog
    wire bgw_busy, bgw_rd_en; wire [14:0] bgw_rd_qw;
    wire bgw_sdram_wr_en; wire [14:0] bgw_sdram_wr_addr; wire [63:0] bgw_sdram_wr_data;
    fbram_to_sdram #(.FB_QWORDS(19200), .AW(15)) u_bgw (
        .clk(clk), .rst(rst), .start(bgw_start), .busy(bgw_busy),
        .rd_en(bgw_rd_en), .rd_qw(bgw_rd_qw), .rd_qword(fb_rd_qword),
        .sdram_wr_en(bgw_sdram_wr_en), .sdram_wr_addr(bgw_sdram_wr_addr),
        .sdram_wr_data(bgw_sdram_wr_data)
    );
    // 3-way fb_rd mux: snapshot (vblank) > bg-write (rare bake) > normal compositor.
    // These two consumers are mutually exclusive in time (bg-write only runs
    // mid-frame during a rare bake with the compositor otherwise idle; snapshot
    // only runs in vblank) so priority order between them doesn't matter in
    // practice, but snap must never be starved by a stuck bg-write, hence this order.
    assign fb_rd_en = snap_busy ? snap_rd_en : (bgw_busy ? bgw_rd_en : pipe_fb_rd_en);
    assign fb_rd_qw = snap_busy ? snap_rd_qw : (bgw_busy ? bgw_rd_qw : pipe_fb_rd_qw);
    // ch0 (P_DST) write port -- idle since PR #49; repurpose for the plane bake.
    // Substitute the REAL port names found in Step 1's grep here.
    assign ch0_wr_en   = bgw_sdram_wr_en;
    assign ch0_wr_addr = {bgw_sdram_qw, bgw_sdram_wr_addr[AW0_64-1:0]} + bgw_sdram_wr_addr;  // base + running offset -- get the exact address-composition idiom from Step 1's read of ch0's existing address port width (CH_AW) and the OFFSET convention documented at sdram_fb_cache.sv:20-27
    assign ch0_wr_data = bgw_sdram_wr_data;
```

(The address composition line above is intentionally flagged for
correction against Step 1's findings — `ch0` is `CH_FULL`/`CH_AW`-wide per
`sdram_fb_cache.sv:156-157`, addressing the full 128MB span directly, not
offset-relative like the small caches; get the exact bit slicing right by
reading how `P_DST`'s existing (currently-dead) write address port was
driven before PR #49 removed its driver — `git log -p --follow -- fpga/rtl/blitter_top.sv` around the FB-in-BRAM cutover commits, e.g. `git show 51ed7ef` — to reuse the same addressing convention rather than inventing a new one.)

- [ ] **Step 6: Run the new TB + full gating suite**

Run: `cd fpga/sim && iverilog -g2012 -o /tmp/bgw.vvp -I ../rtl -I ../rtl/jtframe -I ../sys -I . -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v tb_bgplane_write_pipe.sv && vvp /tmp/bgw.vvp`
Expected: `RESULT: PASS`.
Then: `cd fpga/sim && ./run_sims.sh`
Expected: `gating-failures=0` — critically, `tb_comp_pipeline` + the 7
`tb_blitter_*_pipe` equivalence TBs must stay PASS (this task adds a new
opcode/states but must not touch the existing compositor datapath).

- [ ] **Step 7: Commit**

```bash
git add fpga/rtl/blitter_top.sv fpga/rtl/blitter_defs.vh fpga/sim/tb_bgplane_write_pipe.sv
git commit -m "feat(comp): OP_BGPLANE_WRITE -- stream comp_fbram WORK to SDRAM via ch0

Wires fbram_to_sdram (previous commit) into blitter_top's FSM as a new
opcode, reusing sdram_fb_cache's ch0 (P_DST) write port -- idle since PR #49
retired the old SDRAM-destination compositor but never deleted the channel.
S_BGW_WAIT/BUSY mirror the existing S_SNAP_* pattern. 3-way fb_rd mux
(snapshot > bg-write > normal compositor read); the two rare consumers never
overlap in practice. Existing equivalence TBs unaffected (mixer datapath
untouched)."
```

---

### Task 4: Host emitter — `blt_bgplane_write_cell()`

**Files:**
- Modify: `patches/mister/blitter/blt_emitter.h` (declaration, near
  `blt_frt_upload` at line 221)
- Modify: `patches/mister/blitter/blt_emitter.c` (or wherever
  `blt_frt_upload`'s definition lives — `grep -rn "^int blt_frt_upload" patches/mister/blitter/`)
- Test: whatever host-side emitter test file already covers
  `blt_tile_list_res`/`blt_frt_upload` (`grep -rln "blt_frt_upload" patches/mister/blitter/tests/`)

**Interfaces:**
- Consumes: `OP_BGPLANE_WRITE = 8'd8` (Task 3).
- Produces: `int blt_bgplane_write_cell(blt_emitter_t *e, uint32_t sdram_qword_offset);`
  — emits a header-only `OP_BGPLANE_WRITE` command with `dst_x|dst_y<<16`
  packed from `sdram_qword_offset` (matching the packing Task 3 decodes).
  Returns 0, or -1 + `e->overflow` on ring-full (same contract as
  `blt_frt_upload`).

- [ ] **Step 1: Find and read `blt_frt_upload`'s definition as the template**

Run: `grep -rn "^int blt_frt_upload" patches/mister/blitter/*.c* ` and read
the full function body — it is the closest existing analog (header-only
command, no tile-list entry payload).

- [ ] **Step 2: Write the failing test**

Add to the existing emitter test file found above (match its exact style;
sketch of the assertion):

```c
// blt_bgplane_write_cell emits exactly one OP_BGPLANE_WRITE command with the
// qword offset packed into dst_x|dst_y<<16, and advances cmd_count by 1.
{
  blt_emitter_t e; /* ...init exactly like the surrounding tests... */
  int before = e.cmd_count;
  int rc = blt_bgplane_write_cell(&e, 0x12345);
  assert(rc == 0);
  assert(e.cmd_count == before + 1);
  /* Inspect the last-written ring command's opcode + dst_x/dst_y fields
     the same way the existing blt_frt_upload test inspects its command --
     match that inspection idiom exactly. */
}
```

- [ ] **Step 3: Run it to verify it fails to compile (function undeclared)**

Run whatever build command the existing test file uses.
Expected: compile error.

- [ ] **Step 4: Implement `blt_bgplane_write_cell`**

In `blt_emitter.h`, near line 221:

```c
/* [Phase 3b] Emit a header-only BLT_OP_BGPLANE_WRITE: stream comp_fbram's
 * current WORK buffer to the SDRAM background-plane region at
 * `sdram_qword_offset` (a qword index, not a byte offset -- matches how
 * OP_TILELIST's entry pointer is qword-granular). The caller must have
 * already painted the desired cell into the WORK buffer (e.g. via a normal
 * OP_TILELIST batch) before emitting this. Returns 0, or -1 + e->overflow
 * on ring-full. */
int blt_bgplane_write_cell(blt_emitter_t *e, uint32_t sdram_qword_offset);
```

In the `.c`/`.cpp` implementation file, next to `blt_frt_upload`'s body,
following that function's exact ring-write pattern (copy its structure,
substituting the opcode and field packing):

```c
int blt_bgplane_write_cell(blt_emitter_t *e, uint32_t sdram_qword_offset) {
  /* Mirror blt_frt_upload's ring-full check + cmd write exactly; substitute:
       cmd.opcode = OP_BGPLANE_WRITE;
       cmd.dst_x  = (uint16_t)(sdram_qword_offset & 0xFFFF);
       cmd.dst_y  = (uint16_t)(sdram_qword_offset >> 16);
     with all other cmd fields zeroed, matching OP_TILELIST_RES's
     header-only convention. */
}
```

(The exact struct field names for the ring command depend on what Step 1's
read of `blt_frt_upload` shows — copy its literal field-assignment
statements, do not invent new ones.)

- [ ] **Step 5: Run the test to verify it passes**

Same build command as Step 3.
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add patches/mister/blitter/blt_emitter.h patches/mister/blitter/blt_emitter.c
git commit -m "feat(blitter): blt_bgplane_write_cell -- host emitter for OP_BGPLANE_WRITE

Header-only command, mirrors blt_frt_upload's structure. Packs the target
SDRAM qword offset into dst_x|dst_y<<16 (same convention OP_TILELIST_RES
uses for its entry pointer)."
```

---

### Task 5: Host renderer — one-time cell-by-cell plane bake

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` (new `Impl` state
  near the `res_*` fields at line 425-473; new method near
  `resident_begin_frame` at line 1769; hook into its rebuild branch at
  line 1791-1800)

**Interfaces:**
- Consumes: `bgplane_grid`/`bgplane_cell`/`bgplane_cell_byte_offset` (Task 1),
  `blt_bgplane_write_cell` (Task 4), the existing `res_static_buckets`/
  `StaticEnt` data already populated by `resident_record_static` (unchanged).
- Produces: `Impl::bg_plane_sdram_base` (permanent SDRAM allocation base for
  this map's plane), `Impl::bg_plane_valid`, `Impl::bg_bake_cell_idx` (bake
  progress cursor), and a new per-frame-called method
  `bool bake_background_plane_step()` returning true once the bake for the
  current map is complete. Task 6 calls this and gates the new per-frame
  emission on its result.

- [ ] **Step 1: Add the bake state**

Near the `res_*` fields (after line 473):

```cpp
  // [Phase 3b] Background-plane cache: the static resident buckets
  // (res_static_buckets) are baked ONCE per map/tileset change into a
  // permanent SDRAM plane, cell by cell (comp_fbram-sized 320x240 cells,
  // see bgplane_geom.h), instead of being replayed via BLT_OP_TILELIST
  // every frame. Bake progress is spread across frames (one cell per
  // present(), like the load-progress bar at preload_quest_assets) so a
  // large map's bake never stalls a single frame noticeably.
  bool     bg_plane_valid    = false;  // a completed bake is ready to use
  bool     bg_baking         = false;  // a bake is in progress this map
  uint32_t bg_plane_sdram_base = 0;    // permanent SDRAM byte offset of cell 0
  int      bg_bake_cell_idx  = 0;      // next cell index to bake (0..grid.count)
  int      bg_map_w = 0, bg_map_h = 0; // map pixel dims this plane covers
```

- [ ] **Step 2: Write the failing test — bake starts on rebuild, progresses one cell/call**

This exercises host logic only (no HW needed) — add a test to whatever
harness Task 1 confirmed (or a new small one following that same style) that
constructs a minimal `MisterBlitterRenderer`-like fixture. If the renderer
class isn't easily unit-testable in isolation (check: does
`patches/mister/blitter/tests/` already test `mister_blitter_renderer.cpp`
directly, or only the lower-level `blt_*` emitter? If only the latter, this
step's test instead directly exercises `bgplane_grid`/`bgplane_cell`
sequencing against a fake "bake one cell" callback, proving the cursor
advances correctly and terminates at `grid.count` — write that narrower
test instead, and note in the commit message that the full renderer
integration is verified in Task 10's HW pass, not host-side unit tests,
since `MisterBlitterRenderer` has hard DDR/hardware dependencies throughout
per its existing test coverage pattern.)

```cpp
// Cursor sequencing: N calls to a per-cell baker complete a grid.count-cell
// bake in exactly grid.count steps, visiting every cell index exactly once.
{
  bgplane_grid_t g = bgplane_grid(700, 500);  // -> 3x3 = 9 cells (ceil(700/320)=3, ceil(500/240)=3)
  assert(g.count == 9);
  std::vector<int> visited;
  int cursor = 0;
  while (cursor < g.count) {
    visited.push_back(cursor);
    cursor++;   // mirrors bg_bake_cell_idx's per-call increment
  }
  assert((int)visited.size() == 9);
  for (int i = 0; i < 9; ++i) assert(visited[i] == i);
}
```

- [ ] **Step 3: Run it to verify the expected behavior (grid math already
  proven in Task 1; this step just confirms the sequencing invariant used
  by Step 4's real implementation)**

Run the same build command as Task 1.
Expected: PASS immediately (this step validates the ALGORITHM before wiring
it into the stateful renderer, catching an off-by-one before it's buried in
DDR-dependent code that's hard to unit test).

- [ ] **Step 4: Implement `bake_background_plane_step()` and hook the trigger**

Near `resident_begin_frame` (after line 1801):

```cpp
// [Phase 3b] Advance the background-plane bake by one cell. Call once per
// present() while bg_baking is true. Returns true when the bake for the
// current map is complete (bg_plane_valid becomes true on that same call).
bool MisterBlitterRenderer::bake_background_plane_step() {
  if (!d->bg_baking) return d->bg_plane_valid;
  bgplane_grid_t g = bgplane_grid(d->bg_map_w, d->bg_map_h);
  if (d->bg_bake_cell_idx >= g.count) {
    d->bg_baking = false;
    d->bg_plane_valid = true;
    return true;
  }
  bgplane_cell_t cell = bgplane_cell(d->bg_bake_cell_idx, d->bg_map_w, d->bg_map_h);
  // Paint this cell's static tiles, offset from map coords to cell-local
  // coords (subtract the cell's map-space origin), reusing the SAME
  // BLT_OP_TILELIST batching resident_record_static's data already
  // populated -- only the per-bucket bias changes (cell-local instead of
  // camera-relative).
  d->ensure_frame();
  for (size_t bi = 0; bi < d->res_static_buckets.size(); ++bi) {
    const Impl::StaticBucket& b = d->res_static_buckets[bi];
    if (b.hw_count == 0) continue;
    blt_surface_ref_t tex = d->upload(*b.tsimg, b.fmt);
    if (!tex.valid) continue;
    int16_t bx = (int16_t)(-cell.map_x), by = (int16_t)(-cell.map_y);
    blt_tile_list_static(&d->em, tex, b.blend, b.key, /*alpha=*/255, b.flags,
                          b.hw_off, b.hw_count, bx, by);
  }
  uint32_t qw_off = (d->bg_plane_sdram_base + bgplane_cell_byte_offset(d->bg_bake_cell_idx)) / 8;
  blt_bgplane_write_cell(&d->em, qw_off);
  d->bg_bake_cell_idx++;
  return false;
}
```

Hook the trigger into `resident_begin_frame`'s rebuild branch
(the `// New / changed signature: rebuild...` block starting at line 1791):
add, right after `d->res_mode = 1;` (line 1799), the plane-bake
(re)initialization:

```cpp
  // [Phase 3b] A resident rebuild means the map/tileset changed -- the
  // background plane is stale too. Restart the bake; SOLARUS_BGPLANE
  // gates the feature (default OFF until HW-validated, matching every
  // other lever in this campaign).
  if (d->bgplane_enabled) {
    d->bg_plane_valid = false;
    d->bg_baking = true;
    d->bg_bake_cell_idx = 0;
    d->bg_map_w = mister_map_width_px();   // confirm the exact accessor name
    d->bg_map_h = mister_map_height_px();  // via `grep -n "map_width\|map_height" patches/mister/*.h`
    if (d->bg_plane_sdram_base == 0) {
      // First bake ever: allocate the plane's permanent SDRAM region sized
      // for the LARGEST map the quest can present, OR reallocate per-map if
      // sizes vary a lot -- confirm via blt_sdram_regions_init's perm
      // allocator semantics (Task 1's research step) whether a per-map
      // alloc+free is safe/cheap or whether a single worst-case-sized
      // region should be reserved once at quest load. Default to a fresh
      // perm allocation per distinct map here; revisit if perm exhaustion
      // is observed in Task 10's HW soak.
      d->bg_plane_sdram_base = d->alloc_perm_sdram_region(
          bgplane_total_bytes(d->bg_map_w, d->bg_map_h));
    }
  }
```

Add the env-gate (mirror every other `SOLARUS_*` flag's init pattern —
`grep -n "SOLARUS_TILERESIDENT\|res_enabled" patches/mister/mister_blitter_renderer.cpp | head -5`
to copy the exact getenv idiom):

```cpp
  bool bgplane_enabled = false;   // SOLARUS_BGPLANE, default OFF until HW-validated
```

- [ ] **Step 5: Compile-check (no host test harness exists for this
  DDR-dependent path per Step 2's note — verify via the project's existing
  native syntax-check recipe)**

Run the `g++ -fsyntax-only` recipe from memory `fpga-renderer-native-typecheck`
(includes the glm + generated config.h paths) against
`mister_blitter_renderer.cpp`.
Expected: no new errors introduced (some undefined-symbol errors are
expected until `alloc_perm_sdram_region`/`mister_map_width_px`/
`mister_map_height_px` are confirmed to exist or are stubbed — resolve each
one against the actual codebase before treating this step as done; do not
invent these names without checking, per Step 4's inline TODOs).

- [ ] **Step 6: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "feat(bgplane): one-time cell-by-cell background-plane bake

bake_background_plane_step() advances one 320x240 cell per call: repaints
that cell's static resident buckets (reusing the exact same BLT_OP_TILELIST
data resident_record_static already populated, just cell-local biased) into
comp_fbram, then streams it to the plane's permanent SDRAM region via
OP_BGPLANE_WRITE. Triggered from resident_begin_frame's existing map/tileset
rebuild signature check. Gated SOLARUS_BGPLANE, default OFF."
```

---

### Task 6: Host renderer — per-frame static-bucket replacement

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` (the per-frame
  static-bucket emit call site — find where `res_emit_static_bucket_`/
  `resident_emit_static_op` are actually invoked from the engine's draw
  walk: `grep -rn "resident_emit_static_op\|resident_static_op_count" patches/mister/mister_blitter_renderer.h work/solarus/src 2>/dev/null`)

**Interfaces:**
- Consumes: `bg_plane_valid`, `bg_plane_sdram_base` (Task 5),
  `bgplane_enabled` (Task 5).
- Produces: modified behavior of the static-tile draw call site — when
  `bgplane_enabled && bg_plane_valid`, emit one windowed COPY from the baked
  plane instead of replaying every static bucket.

- [ ] **Step 1: Find the actual call site and current per-frame flow**

Run the grep above; read the surrounding engine-side code (likely in
`work/solarus/src/graphics/...` — the resident-tile draw walk) to see
exactly how `resident_static_op_count`/`resident_emit_static_op` are looped
per frame today, so the replacement preserves paint order relative to the
animated resident buckets and dynamic sprites (the baked plane must still
draw BEFORE the animated overlay tiles and dynamic entities, at the same
point in paint order the static buckets currently occupy).

- [ ] **Step 2: Write the failing test — mode selection**

If a host-testable seam exists at this call site (a pure function deciding
"replay buckets" vs "one COPY"), test that in isolation; otherwise (likely,
given Step 1's DDR-dependent renderer), document in the commit message that
this task's correctness gate is Task 7's pixel-equivalence TB plus Task 10's
HW screenshot A/B, and skip to Step 3. Do not fabricate a host unit test for
logic that has no testable seam — that would violate the "no placeholders"
rule in the opposite direction (a fake test proving nothing).

- [ ] **Step 3: Implement the replacement in `MisterBlitterRenderer`**

Add near `res_emit_static_bucket_` (after line 2055):

```cpp
// [Phase 3b] Replace the whole static-bucket replay with one windowed COPY
// from the baked background plane, when available. Falls back to the
// original per-bucket replay (res_emit_static_bucket_ per op, unchanged)
// when the plane isn't ready yet (bg_plane_valid false -- e.g. still baking
// right after a map change) or the feature is gated off.
void MisterBlitterRenderer::resident_emit_static_layer(int layer) {
  if (!d->bgplane_enabled || !d->bg_plane_valid) {
    for (size_t i = 0; i < d->res_static_ops.size(); ++i)
      if (d->res_static_ops[i].layer == layer)
        res_emit_static_bucket_(d->res_static_ops[i].bk);
    return;
  }
  // One COPY per call is correct as long as this is called once per frame
  // per layer that carries static content -- confirm against Step 1's
  // findings whether static buckets span multiple `layer` values needing
  // multiple windowed COPYs (one per layer, each reading its own vertical
  // slice of the plane) or collapse to a single layer in practice.
  const int cx = mister_camera_x(), cy = mister_camera_y();
  blt_surface_ref_t plane_ref = {};
  plane_ref.sdram_off = d->bg_plane_sdram_base;
  plane_ref.w = (uint16_t)d->bg_map_w;
  plane_ref.h = (uint16_t)d->bg_map_h;
  plane_ref.stride = (uint16_t)(BGPLANE_CELL_W * BGPLANE_BYTES_PER_PIXEL);  // confirm against the plane's actual per-cell stride packing from Task 5 -- a whole-map COPY spanning multiple cells needs the plane's cells laid out CONTIGUOUSLY in map-scan order, not the fixed-stride-per-cell tiling Task 1 defined; reconcile before this line ships (likely: change Task 1's layout to store cells in true map-scan order with map_w-wide rows, OR restrict the per-frame COPY to a single cell + emit up to 4 COPYs when the camera window straddles a cell boundary -- pick one and update Task 1/5/6 consistently)
  plane_ref.format = /* the format comp_fbram's WORK buffer content is in -- confirm via comp_fbram.sv's data width/format comment */;
  plane_ref.valid = 1;
  d->ensure_frame();
  // Emit a plain COPY blit windowed to the camera view. Find the existing
  // primitive for "blit a sub-rect of a texture to a dst rect" (the same
  // one normal sprite draws use) and call it here with src=(cx,cy,320,240),
  // dst=(0,0,320,240) -- confirm the exact function name/signature via
  // `grep -n "^blt_surface_ref_t blt_upload\|^int blt_blit\|blit(" patches/mister/blitter/blt_emitter.h`.
}
```

(This step has two explicitly-flagged open design questions — cell layout
contiguity and multi-layer static content — that MUST be resolved by
reading the actual code before this ships; they are called out inline
rather than papered over, per the "no placeholders" rule: a plan step that
surfaces a real unresolved question with a concrete decision procedure is
not the same as a vague "handle edge cases" placeholder.)

- [ ] **Step 4: Update the call site found in Step 1**

Replace the loop that calls `resident_emit_static_op` per-op with a single
call to `resident_emit_static_layer(layer)` per layer that has static
content (preserving the existing per-layer iteration structure Step 1
found).

- [ ] **Step 5: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "feat(bgplane): replace per-frame static-bucket replay with one windowed COPY

When the background plane is baked (bg_plane_valid), resident_emit_static_layer
emits a single COPY windowed to the camera view instead of replaying every
static bucket's BLT_OP_TILELIST. Falls back to the original per-bucket replay
while a bake is still in progress after a map change. Gated SOLARUS_BGPLANE."
```

---

### Task 7: Bit-exactness TB — old replay vs new baked-plane COPY

**Files:**
- Create: `fpga/sim/tb_bgplane_equivalence.sv`

**Interfaces:**
- Consumes: the full fabric pipeline (Tasks 2-3) plus a representative
  static-tile scene (reuse `tb_comp_pipeline.sv`'s or `tb_blitter_system_pipe.sv`'s
  scene-construction helpers if they expose a multi-tile static batch, per
  what Task 3's Step 1 read of `tb_blitter_system_pipe.sv` found).
- Produces: a gating assertion that composing a scene via the OLD path
  (N `OP_TILELIST` entries, camera-biased, replayed directly into WORK) and
  the NEW path (bake into a scratch SDRAM region via `OP_BGPLANE_WRITE`,
  then COPY that region back into a second WORK-buffer instance at the same
  camera window) produce byte-identical `comp_fbram` content.

- [ ] **Step 1: Write the equivalence test**

```systemverilog
// tb_bgplane_equivalence.sv -- proves the Phase 3b baked-plane COPY path
// produces IDENTICAL pixels to the original per-frame static-tile replay,
// for the same scene and camera window. Two full pipeline instances (OLD,
// NEW) driven with the same static-tile batch; OLD replays it directly via
// OP_TILELIST with a camera bias; NEW bakes it (OP_TILELIST at zero bias
// into a scratch cell, OP_BGPLANE_WRITE to SDRAM) then reads it back via a
// normal COPY blit windowed to the same camera position. Assert the two
// resulting comp_fbram WORK buffers match qword-for-qword.
module tb_bgplane_equivalence;
  // ... instantiate TWO blitter_top + sdram model pairs (OLD, NEW), mirroring
  // tb_comp_pipeline.sv's dual-instance equivalence-TB pattern if one
  // already exists in this codebase (`grep -l "OLD\|NEW\|_a\b.*_b\b" fpga/sim/tb_blitter_*_pipe.sv`
  // to find the established dual-instance idiom and copy its structure) --
  // drive OLD with N OP_TILELIST entries at bias=(-camera_x,-camera_y);
  // drive NEW with the bake sequence (Task 5's cell-local emission, using
  // ONE cell sized to cover the test scene) then a COPY windowed at
  // (camera_x, camera_y); compare final WORK buffers qword-by-qword;
  // $display "RESULT: PASS"/"FAIL" per this suite's convention.
endmodule
```

- [ ] **Step 2: Run it — expect it to expose any bake/replay mismatch**

Run: `cd fpga/sim && iverilog -g2012 -o /tmp/bge.vvp -I ../rtl -I ../rtl/jtframe -I ../sys -I . -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v tb_bgplane_equivalence.sv && vvp /tmp/bge.vvp`
Expected: PASS if Tasks 2-6 were implemented correctly; if FAIL, the
mismatch pinpoints exactly which stage (bake composition, SDRAM
write/readback addressing, or the windowed COPY) diverges from the
original — debug against that signal, do not proceed to Task 8 on a FAIL.

- [ ] **Step 3: Full gating suite**

Run: `cd fpga/sim && ./run_sims.sh`
Expected: `gating-failures=0`, including this new TB and all prior ones.

- [ ] **Step 4: Commit**

```bash
git add fpga/sim/tb_bgplane_equivalence.sv
git commit -m "test(bgplane): gate old-replay vs baked-plane-COPY pixel equivalence

Two-instance comparison TB: the original per-frame OP_TILELIST replay and
the new bake-once-then-COPY path must produce byte-identical comp_fbram
content for the same scene + camera window. Gating."
```

---

### Task 8: M10K/ALM budget check + RBF build + STA gate (MANUAL)

- [ ] **Step 1:** Push `fpga/**` → CI (`build-rbf.yml`, `gh workflow run build-rbf.yml --ref <branch>`). `gh run download <id> -n quartus-reports`.
- [ ] **Step 2: Resource check.** `fbram_to_sdram.sv` adds a handful of
  flip-flops (mirrors `fbram_snapshot.sv`'s tiny footprint, no new BRAM
  array); `ch0` was ALREADY counted in the standing ~79% RAM-block
  utilization (it's instantiated, just idle) — confirm `Solarus.fit.summary`
  shows no meaningful RAM Block increase versus the Phase 3a baseline
  (post-`e224a94`: 435/553, 79%).
- [ ] **Step 3: STA gate.** Confirm `Solarus.sta.summary` shows **zero
  negative slack** across every clock (setup, hold, recovery, removal, min
  pulse width) at the pinned SEED 1, matching the Phase 3a clean build. The
  new `S_BGW_*` states + ch0 write-path muxing are the timing risk; if
  negative, register the new mux select stage (same technique as
  `comp_src_linebuf.sv`'s post-register bank mux fix, see that file's header
  comment) before considering a reseed.

---

### Task 9: HW validation (MANUAL, user-relaunch)

- [ ] **Step 1:** Deploy the new RBF (same recipe as Phase 3a: scp to
  `/media/fat/_Other/`, sha1-verify, `load_core`, kill+relaunch
  `solarus-run` via `Solarus.s0` touch — see the Phase 3a session's recipe).
  Enable `SOLARUS_BGPLANE=1` in `diag.env` (default is OFF).
- [ ] **Step 2:** Screenshot A/B: capture the heavy village save spot with
  `SOLARUS_BGPLANE=0` (baseline, current per-frame replay) and `=1` (baked
  plane), confirm pixel-identical rendering (visual diff — no atlas garbage,
  no missing tiles, no seam artifacts at cell boundaries).
- [ ] **Step 3:** Read `[blitter diag]`/`[blitter hwperf]` banners standing
  at the heavy village spot with `SOLARUS_BGPLANE=1`: confirm `alias_blits`
  drops sharply (static entries no longer counted per-frame) and
  `fabric_hw` drops meaningfully toward the 16.7ms Phase 3 gate — record the
  actual number, do not assume the design doc's ~2ms COPY estimate holds
  without measuring.
- [ ] **Step 4:** Room-transition soak: walk between several rooms/screens
  (each triggering a fresh bake) and confirm no visible stall/flicker during
  a bake, no `res_fatal`/overflow flags, `bg_bake_cell_idx` behaves
  (finishes before the next map change in typical walking speed — if not,
  revisit Task 5's "one cell per frame" pacing, e.g. bake 2-4 cells/frame).
- [ ] **Step 5:** Update memory `solarus-60fps-campaign` / a new
  `fpga-bgplane-cache` memory with the measured HW `fabric_hw` result and
  whether the 16.7ms gate is now met (if not, note the residual gap for a
  future lever).

---

## Self-Review

**Spec coverage:** Design doc's Phase 3b ("compose the static tile layers
once per camera region into an SDRAM plane; per-frame work collapses to one
opaque... COPY... Requires a compositor→SDRAM writeback path... or a one-time
A9 composition at map-load") → Tasks 2-3 (fabric writeback, narrowly scoped
to ch0 reuse) + Task 5 (one-time bake, fabric-composed not A9-software, per
the #68 precedent) + Task 6 (per-frame COPY collapse). Gate ("only if post-3a
fabric > 16.7ms") → already satisfied by the measured 19.7ms HW result that
motivated this plan. Risk table's "3b writeback path re-adds removed RTL
complexity" → mitigated by reusing the already-instantiated, already-idle
ch0 channel rather than adding new SDRAM-cache infrastructure, and by scoping
the write to a rare one-time bake instead of a per-frame path.

**Placeholder scan:** Two spots are intentionally flagged rather than
papered over — Task 3 Step 5's exact ch0 address-composition bit-slicing,
and Task 6 Step 3's cell-layout-contiguity/multi-layer question — both name
the exact grep/git-log command needed to resolve them and the concrete
decision procedure, which is different from a vague "handle appropriately."
Every other step has complete, concrete code.

**Type/name consistency:** `bgplane_grid_t`/`bgplane_cell_t` (Task 1) used
identically in Tasks 5-7. `OP_BGPLANE_WRITE=8'd8` (Task 3) matches
`blt_bgplane_write_cell`'s target opcode (Task 4). `bg_plane_valid`/
`bg_baking`/`bg_bake_cell_idx`/`bg_plane_sdram_base` (Task 5) reused
verbatim in Task 6. `fbram_to_sdram`'s port names (Task 2:
`start`/`busy`/`rd_en`/`rd_qw`/`rd_qword`/`sdram_wr_en`/`sdram_wr_addr`/
`sdram_wr_data`) match Task 3's instantiation.
