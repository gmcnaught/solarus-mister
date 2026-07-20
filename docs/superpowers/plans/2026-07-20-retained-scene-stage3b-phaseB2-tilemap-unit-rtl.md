# Stage 3b Phase B2 — `tilemap_unit` RTL + bgplane RTL removal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `BLT_OP_TILEMAP` (opcode `8'd11`) in the fabric so the compositor walks a per-layer 8px cell grid and issues one coalesced blit per horizontal run, validated in simulation bit-for-bit against B1's golden model `blt_ref_tilemap`, and remove the now-inert bgplane RTL in the same Quartus build.

**Architecture:** The walker is the resident-tile FSM path (`S_TLR*`) with a 2D run-coalescing front end. Five new states (`S_GRID_SETUP/FETCH/DECODE/SLICE/WAIT`) reclaim retired 6-bit encodings; they **share** the pattern-resolve states (`S_TLR_CFT`/`S_TLR_FRT`) and the `comp_pipeline` `pipe_start`/`p_blit_done` handshake, and keep their own slice + wait states so the shared `S_TL_ISSUE`/`S_TL_WAIT` tail that three shipping ops depend on is untouched. The per-cell destination reuses the existing `res_dx/res_dy + res_bias` convention, inheriting the #24 signed-clip for free.

**Tech Stack:** SystemVerilog (Icarus Verilog for sim, Quartus Prime Lite 17.0 for the build), Python 3 (host↔fabric wire cross-check), C (host golden model — reference only, not rebuilt here).

**Design spec:** `docs/superpowers/specs/2026-07-20-retained-scene-stage3b-phaseB2-tilemap-unit-rtl-design.md`
**Handoff:** `docs/superpowers/2026-07-20-stage3b-b1-to-b2-handoff.md`
**Golden model:** `blt_ref_tilemap` in `patches/mister/blitter/blitter_ref.c` — the RTL must match its walk exactly.

**Branch:** create `feat/stage3b-b2-tilemap-unit` off `master` before Task 1 (master is the default branch; do not commit to it directly).

## Global Constraints

- **State register stays `reg [5:0]`.** Allocate the 5 new grid states from the reclaimable pool (`14, 27, 28, 29, 31`); do NOT widen the field, and do NOT touch `rd_ret`/`wr_ret` widths or the `dbg[5:0]` probe packing.
- **`GRID_BUF` stays 2 MiB** at `0x3BFF3000` / `` `GRID_BUF_QW = 29'h077FE600``. No `grid_used` bounds-check state this phase.
- **Cell encoding is frozen** (`grid_cell.h`): `pid=[11:0]` (`0xFFF`=EMPTY), `sub_x=[15:12]`, `sub_y=[19:16]`, `run_m1=[23:20]` (run = `run_m1+1`, 1..16), `spare=[31:24]` (mask and ignore).
- **Header field overload** (`blitter_defs.vh`): `grid_w|grid_h = c_w|c_h<<16`; `cells_off = {c_dst_y, c_dst_x}`; bias = `$signed(c_src_x/c_src_y)`; tileset base = `c_src_off/c_src_stride`.
- **`comp_fbram` is 320×240.** `BLT_FB_WIDTH=320`, `BLT_FB_HEIGHT=240`.
- **Retain RESERVED host constants:** `BLT_OP_BGPLANE_WRITE = 8` and `BLT_F_BGCOV = 0x80` in `blitter_ref.h` stay after bgplane RTL removal. Never recycle opcode 8.
- **Verification is sim + STA only.** No device run, no engine patches, no renderer wiring — those are B3. A passing RBF is NOT evidence of passing timing; the seed sweep + STA is the gate.
- **Sim runner:** `cd fpga/sim && ./run_sims.sh <tb_name>` (name with or without `.sv`); a new `tb_*.sv` is auto-discovered.
- Every commit message ends with the two trailers from CLAUDE.md (`Co-Authored-By:` + `Claude-Session:`).

---

### Task 1: Widen `MAXP` 128 → 256 and confirm the M10K fit

Map 3 has 251 distinct patterns; the grid op resolves `pid` through the same `cft_mem`/`frt_bram` tables the resident path uses, so `MAXP=128` cannot hold a real map. This task widens it and confirms the block-memory fit *before* the FSM is written (the frame-rect table is ~84% by M10K blocks, so blocks bind and bit arithmetic understates cost).

**Files:**
- Modify: `fpga/rtl/blitter_defs.vh:129` (`MAXP`)
- Modify: `patches/mister/blitter/blitter_ref.h:137` (`BLT_MAXP`)
- Test: `fpga/sim/run_sims.sh` (existing resident/tilelist TBs must stay green); `fpga/output_files/Solarus.fit.rpt` (M10K utilization)

**Interfaces:**
- Consumes: nothing.
- Produces: `MAXP = 256` (fabric), `BLT_MAXP = 256` (host) — the widened pattern-table depth every later task's `pid` resolve relies on.

- [ ] **Step 1: Widen the fabric constant**

In `fpga/rtl/blitter_defs.vh:129`, change:
```systemverilog
localparam integer MAXP = 128;            // max distinct animated patterns
```
to:
```systemverilog
localparam integer MAXP = 256;            // max distinct animated patterns (Stage 3b B2: map 3 = 251)
```

- [ ] **Step 2: Widen the host mirror**

In `patches/mister/blitter/blitter_ref.h:137`, change:
```c
#define BLT_MAXP  128   /* max distinct animated patterns per scene */
```
to:
```c
#define BLT_MAXP  256   /* max distinct animated patterns per scene (Stage 3b B2: map 3 = 251) */
```

- [ ] **Step 3: Run the resident/tilelist sims to confirm the widen is behaviour-neutral**

Run: `cd fpga/sim && ./run_sims.sh tb_tilelist_res && ./run_sims.sh tb_spritelist`
Expected: both print their PASS marker (`RESULT: PASS` / `errors=0`), no FAIL.

- [ ] **Step 4: Run a Quartus fit and capture M10K utilization**

Run (from `fpga/`, needs Quartus 17.0 in PATH, ~20-40 min):
```bash
cd fpga && ./build_solarus.sh 2>&1 | tee build_maxp256_probe.log
grep -E "M10K|Total block memory bits|Total RAM Blocks" output_files/Solarus.fit.rpt
```
Expected: fit completes; M10K block count is within the device budget (86 free before this change; the widen costs ~8). Record the exact "Total RAM Blocks" line.

- [ ] **Step 5: Decide on the fit result**

If M10K blocks fit with margin → proceed. If the fit is marginal or over budget → STOP and report; the design's `MAXP=256` assumption needs revisiting (e.g. narrower `frt_bram` packing) before any FSM work. This is the de-risk gate.

- [ ] **Step 6: Commit**

```bash
git add fpga/rtl/blitter_defs.vh patches/mister/blitter/blitter_ref.h
git commit -m "feat(blitter): widen MAXP 128->256 for grid pattern tables

Map 3 has 251 distinct patterns; the grid op resolves pid through the
same cft_mem/frt_bram tables as the resident path. Fit report M10K
utilization recorded in the commit that follows / build log.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WNuJ2Q7B4D2zmCV8u4dAae"
```

---

### Task 2: Cell-bitfield localparams + `test_wire_constants.py` cross-check

Closes handoff gap #2: today `test_wire_constants.py` pins the opcode and `GRID_BUF` base/size but not the cell bit positions, because there was no fabric decode to grep. Name the cell bit ranges as localparams now (the FSM in Task 3 uses them) and pin them against `grid_cell.h`.

**Files:**
- Modify: `fpga/rtl/blitter_defs.vh` (add cell-bitfield localparams near `OP_TILEMAP`, ~line 201)
- Modify: `scripts/tests/test_wire_constants.py` (add the cross-check)
- Test: `scripts/tests/test_wire_constants.py` (self-gating)

**Interfaces:**
- Consumes: nothing.
- Produces: `GRID_CELL_SUBX_LSB=12`, `GRID_CELL_SUBY_LSB=16`, `GRID_CELL_RUN_LSB=20`, `GRID_CELL_PID_W=12`, `GRID_CELL_PID_EMPTY=12'hFFF` in `blitter_defs.vh` — the named bit positions Task 3's decode uses.

- [ ] **Step 1: Add the failing cross-check to `test_wire_constants.py`**

In `scripts/tests/test_wire_constants.py`, after the existing GRID_BUF checks (~line 198), add extraction of the shift constants from `grid_cell.h` and the new fabric localparams, then append equality checks. Insert:
```python
# [Stage 3b Phase B2] Cell bitfield positions: grid_cell.h shifts <-> blitter_defs.vh localparams.
gc = read("patches/mister/blitter/grid_cell.h")
H["CELL_SUBX_LSB"]   = grab(gc, r"sub_x\s*&\s*0x0Fu\)\s*<<\s*(\d+)", c_int, "host cell sub_x shift")
H["CELL_SUBY_LSB"]   = grab(gc, r"sub_y\s*&\s*0x0Fu\)\s*<<\s*(\d+)", c_int, "host cell sub_y shift")
H["CELL_RUN_LSB"]    = grab(gc, r"run_m1\s*&\s*0x0Fu\)\s*<<\s*(\d+)", c_int, "host cell run shift")
H["CELL_PID_EMPTY"]  = grab(gc, r"BLT_GRID_PID_EMPTY\s+(0x[0-9A-Fa-f]+)u?", c_int, "host cell PID_EMPTY")
F["CELL_SUBX_LSB"]   = grab(defs, r"GRID_CELL_SUBX_LSB\s*=\s*(\d+)", int, "fabric cell sub_x LSB")
F["CELL_SUBY_LSB"]   = grab(defs, r"GRID_CELL_SUBY_LSB\s*=\s*(\d+)", int, "fabric cell sub_y LSB")
F["CELL_RUN_LSB"]    = grab(defs, r"GRID_CELL_RUN_LSB\s*=\s*(\d+)", int, "fabric cell run LSB")
F["CELL_PID_EMPTY"]  = grab(defs, r"GRID_CELL_PID_EMPTY\s*=\s*\d+'[hH]([0-9A-Fa-f]+)", lambda s: int(s, 16), "fabric cell PID_EMPTY")
checks.append(("cell sub_x LSB", H["CELL_SUBX_LSB"], F["CELL_SUBX_LSB"]))
checks.append(("cell sub_y LSB", H["CELL_SUBY_LSB"], F["CELL_SUBY_LSB"]))
checks.append(("cell run LSB",   H["CELL_RUN_LSB"],  F["CELL_RUN_LSB"]))
checks.append(("cell PID_EMPTY", H["CELL_PID_EMPTY"], F["CELL_PID_EMPTY"]))
```
(`defs` is the already-read text of `blitter_defs.vh`; confirm the variable name matches the existing fabric-side reads around line 159.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `python3 scripts/tests/test_wire_constants.py`
Expected: FAIL / non-zero exit — the four fabric `GRID_CELL_*` localparams don't exist yet (reported under MISSING lookups).

- [ ] **Step 3: Add the localparams to `blitter_defs.vh`**

In `fpga/rtl/blitter_defs.vh`, immediately after `localparam [7:0] OP_TILEMAP = 8'd11;` (line 201), add:
```systemverilog
// [Stage 3b Phase B2] Cell bitfield positions — MUST MATCH host grid_cell.h.
// Pinned by scripts/tests/test_wire_constants.py. pid occupies [PID_W-1:0].
localparam integer GRID_CELL_PID_W     = 12;      // pid = cell[11:0]
localparam integer GRID_CELL_SUBX_LSB  = 12;      // sub_x = cell[15:12]
localparam integer GRID_CELL_SUBY_LSB  = 16;      // sub_y = cell[19:16]
localparam integer GRID_CELL_RUN_LSB   = 20;      // run_m1 = cell[23:20]; run = run_m1+1
localparam [11:0]  GRID_CELL_PID_EMPTY = 12'hFFF; // walker skips
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `python3 scripts/tests/test_wire_constants.py`
Expected: PASS / exit 0, all pairs agree including the four new cell-bitfield checks.

- [ ] **Step 5: Commit**

```bash
git add fpga/rtl/blitter_defs.vh scripts/tests/test_wire_constants.py
git commit -m "test(wire): pin grid cell bitfield positions host<->fabric

Names the cell bit ranges as blitter_defs.vh localparams (used by the B2
FSM decode) and cross-checks them against grid_cell.h, closing the B1->B2
handoff gap where nothing but the sim diff pinned the RTL bit ranges.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WNuJ2Q7B4D2zmCV8u4dAae"
```

---

### Task 3: `tb_tilemap.sv` harness + grid FSM (basic walk green)

The core task. Write the equivalence testbench (modeled on `tb_spritelist.sv`) with a first, simplest scenario, watch it fail (no FSM decodes `OP_TILEMAP`), then implement the five grid states and make it pass. Because an FSM cannot be half-tested, the harness + first scenario + full walk implementation are one deliverable.

**Files:**
- Create: `fpga/sim/tb_tilemap.sv`
- Modify: `fpga/rtl/blitter_top.sv` (decode arm in `S_SETUP`; five new states; `tl_grid` branch in `S_TLR_FRT`; new grid registers)
- Test: `fpga/sim/tb_tilemap.sv` via `./run_sims.sh tb_tilemap`

**Interfaces:**
- Consumes: `MAXP=256` (Task 1); `GRID_CELL_*` localparams (Task 2); `OP_TILEMAP`, `` `GRID_BUF_QW`` (already in `blitter_defs.vh`); shared `S_TLR_CFT`/`S_TLR_FRT` resolve and `pipe_start`/`p_blit_done` handshake (existing `blitter_top.sv`).
- Produces: a working `BLT_OP_TILEMAP` walk — the RTL that Task 4 stress-tests and Task 6 times.

**FSM reference (implement exactly this — matches `blt_ref_tilemap`):**
- `S_GRID_SETUP`: `grid_w=c_w`, `grid_h=c_h`, `cells_off={c_dst_y,c_dst_x}`, bias already in `res_bias_{x,y}`. Compute `vis_lo_x=(res_bias_x>0)?res_bias_x:0`, `vis_hi_x=min(res_bias_x+grid_w*8, 320)`, same y with 240; cull to `S_NEXT_CMD` if `grid_w==0||grid_h==0||vis_lo_x>=vis_hi_x||vis_lo_y>=vis_hi_y`. Then `cx0=(vis_lo_x-res_bias_x)>>3`, `cx1=(vis_hi_x-res_bias_x+7)>>3` capped at `grid_w`, same y capped at `grid_h`. Latch `cx=cx0`, `cy=cy0`, `row_base=cy0*grid_w`. → `S_GRID_FETCH`.
- `S_GRID_FETCH`: `cell_idx=row_base+cx`; `bm_rd<=1; bm_addr <= `GRID_BUF_QW + ((cells_off + (cell_idx<<2)) >> 3)`; `cell_half<=cell_idx[0]`; `rd_ret<=S_GRID_DECODE; state<=S_RD_WAIT`.
- `S_GRID_DECODE`: `cell = cell_half ? rd_data[63:32] : rd_data[31:0]`. `pid=cell[GRID_CELL_PID_W-1:0]`, `sub_x=cell[GRID_CELL_SUBX_LSB+3:GRID_CELL_SUBX_LSB]`, `sub_y=cell[GRID_CELL_SUBY_LSB+3:GRID_CELL_SUBY_LSB]`, `run=cell[GRID_CELL_RUN_LSB+3:GRID_CELL_RUN_LSB]+5'd1`. If `pid==GRID_CELL_PID_EMPTY`: `cx<=cx+1`; if `cx+1>=cx1` do ROW-ADVANCE else `state<=S_GRID_FETCH`. Else: if `cx+run>cx1` `run<=cx1-cx`; `res_pid<=pid`, `res_dx<=cx<<3`, `res_dy<=cy<<3`, `g_sub_x<=sub_x`, `g_sub_y<=sub_y`, `g_run<=(cx+run>cx1)?(cx1-cx):run`, `tl_grid<=1'b1`; `state<=S_TLR_CFT`.
  - ROW-ADVANCE (a shared inline block, reused by `S_GRID_WAIT`): `cy<=cy+1; cx<=cx0; row_base<=row_base+grid_w; state<=(cy+1>=cy1)?S_NEXT_CMD:S_GRID_FETCH`.
- shared `S_TLR_FRT` terminal: change `state<=S_TLR_SLICE;` to `state <= tl_grid ? S_GRID_SLICE : S_TLR_SLICE;`.
- `S_GRID_SLICE`: `c_src_x<=frt_q[15:0]+(g_sub_x<<3)`, `c_src_y<=frt_q[31:16]+(g_sub_y<<3)`, `c_w<=g_run<<3`, `c_h<=16'd8`, `c_dst_x<=$signed(res_dx)+res_bias_x`, `c_dst_y<=$signed(res_dy)+res_bias_y`, `pipe_start<=1'b1; state<=S_GRID_WAIT`.
- `S_GRID_WAIT`: `if (p_blit_done)` then `cx<=cx+g_run`; if `cx+g_run>=cx1` ROW-ADVANCE else `state<=S_GRID_FETCH`.
- Also: clear `tl_grid<=1'b0` on the FSM reset and at `S_NEXT_CMD` (so a following non-grid command resolves via `S_TLR_SLICE`).

- [ ] **Step 1: Write `tb_tilemap.sv` with scenario 0 (one opaque cell, bias 0)**

Create `fpga/sim/tb_tilemap.sv` modeled on `fpga/sim/tb_spritelist.sv`. Reuse its harness verbatim where possible: the behavioral DDR `mem` + control-block/ring setup, the `comp_pipeline` issue-transaction recorder (records `c_src_x/y, c_w/h, c_dst_x/y` per `pipe_start`), the `comp_fbram` capture, and the FRT/CFT preload (`BLT_OP_TILELIST_RES` uses the same tables). Adapt these pieces:
  1. **A GRID cell memory** served whenever the FSM reads the `` `GRID_BUF_QW`` region (mirror how `tb_spritelist` serves `spmem` for `SP_BUF_QW`). Two 32-bit cells per qword.
  2. **Path A:** submit `CLEAR` + one `OP_TILEMAP` header (`w=grid_w`, `h=grid_h`, `dst_x/dst_y=cells_off`, `src_x/src_y=bias`, `src_off/src_stride=tileset base`) with the cells written into the grid memory.
  3. **Path B:** submit `CLEAR` + the expanded per-run `OP_BLIT`s that the golden walk must produce, hand-built per scenario.
  4. **Compare:** the two issue-transaction sequences field-for-field AND the two `comp_fbram` images pixel-for-pixel — exactly `tb_spritelist`'s Path-A-vs-Path-B assertion.

Scenario 0: `grid_w=1, grid_h=1`, one cell `pid=P0, sub_x=0, sub_y=0, run_m1=0`, `bias=(0,0)`, one FRT entry for `P0` (`src rect 0,0,8,8`, `CFT[P0]=0`). Path B = one `OP_BLIT` src `(0,0)` w8 h8 dst `(0,0)`.

- [ ] **Step 2: Run the sim to verify it fails**

Run: `cd fpga/sim && ./run_sims.sh tb_tilemap`
Expected: FAIL — the FSM has no `OP_TILEMAP` arm, so Path A issues zero transactions while Path B issues one; the transaction-sequence compare mismatches.

- [ ] **Step 3: Add the grid registers to `blitter_top.sv`**

In the reg-declaration region (near the `S_TLR` regs, ~line 390), add:
```systemverilog
// [Stage 3b B2] BLT_OP_TILEMAP grid-walk state.
reg  [15:0] grid_w, grid_h;        // grid rectangle in 8px cells (from header w/h)
reg  [20:0] cells_off;             // byte offset of the cell array within GRID_BUF
reg  [8:0]  cx, cx0, cx1;          // cell-column cursor / window [cx0,cx1)
reg  [8:0]  cy, cy1;               // cell-row cursor / window end (cy0 folded into setup)
reg  [16:0] row_base;              // cy*grid_w, maintained incrementally (+grid_w per row)
reg  [3:0]  g_sub_x, g_sub_y;      // sub-pattern offset of the current run
reg  [4:0]  g_run;                 // coalesced run length in cells (1..16)
reg         tl_grid;               // 1 = resolve path terminates in S_GRID_SLICE
reg         cell_half;             // 1 = current cell is the high 32 bits of its qword
```
Add `tl_grid<=1'b0;` to the reset block (near the other `tl_*` resets, ~line 535).

- [ ] **Step 4: Add the decode arm and the five grid states**

In `S_SETUP`, add a decode arm alongside the existing op arms (mirroring the `OP_SPRITELIST` arm at ~line 795):
```systemverilog
else if (c_opcode==OP_TILEMAP) begin
    res_bias_x <= $signed(c_src_x);
    res_bias_y <= $signed(c_src_y);
    state      <= S_GRID_SETUP;
end
```
Add the five states (use encodings `S_GRID_SETUP=6'd14, S_GRID_FETCH=6'd27, S_GRID_DECODE=6'd28, S_GRID_SLICE=6'd29, S_GRID_WAIT=6'd31` in the localparam block) implementing the FSM reference above. Change the `S_TLR_FRT` terminal line `state <= S_TLR_SLICE;` to `state <= tl_grid ? S_GRID_SLICE : S_TLR_SLICE;`. Set `tl_grid<=1'b0;` in `S_NEXT_CMD`.

- [ ] **Step 5: Run the sim to verify scenario 0 passes**

Run: `cd fpga/sim && ./run_sims.sh tb_tilemap`
Expected: PASS — Path A's single issued transaction and framebuffer match Path B.

- [ ] **Step 6: Commit**

```bash
git add fpga/sim/tb_tilemap.sv fpga/rtl/blitter_top.sv
git commit -m "feat(blitter): BLT_OP_TILEMAP grid-walk FSM (basic walk)

Five reclaimed 6-bit states (S_GRID_SETUP/FETCH/DECODE/SLICE/WAIT) walking
the GRID_BUF cell array; shares the S_TLR_CFT/FRT resolve and the
comp_pipeline handshake, keeps its own slice/wait so S_TL_ISSUE is
untouched. Per-cell dst reuses res_dx/res_bias. tb_tilemap scenario 0
(single opaque cell) green vs the expanded-BLIT reference.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WNuJ2Q7B4D2zmCV8u4dAae"
```

---

### Task 4: Full edge-case scenario coverage in `tb_tilemap.sv`

The scenarios B1 pinned nowhere. Each is added as a Path-A/Path-B pair; a failing scenario means an FSM bug to fix in `blitter_top.sv` before moving on. Add them one at a time.

**Files:**
- Modify: `fpga/sim/tb_tilemap.sv` (add scenarios)
- Modify: `fpga/rtl/blitter_top.sv` (only if a scenario exposes a bug)
- Test: `./run_sims.sh tb_tilemap`

**Interfaces:**
- Consumes: the working walk from Task 3.
- Produces: full-coverage `tb_tilemap` — the sim gate Task 6 depends on being green.

- [ ] **Step 1: Scenario 1 — horizontal run coalescing.** `grid_w=5, grid_h=1`, one cell `pid=P0, sub_x=0, run_m1=4` (run=5), bias 0. Path B = ONE `OP_BLIT` src `(0,0)` w40 h8 dst `(0,0)` (a run is one blit, not five). Run: PASS.

- [ ] **Step 2: Scenario 2 — multi-row (the 2.0× case).** `grid_w=2, grid_h=2`, four cells forming a 16×16 pattern: `(0,0)`=`{P0,sub0,0,run1}`, `(1,0)`=empty? No — a 2-wide run on row 0 (`sub_x` 0,1) and a separate 2-wide run on row 1 (`sub_y=1`, `sub_x` 0,1). Cells: row0 `{P0,sx0,sy0,run_m1=1}` at (0,0); row1 `{P0,sx0,sy1,run_m1=1}` at (0,1). Path B = TWO `OP_BLIT`s: row0 src `(0,0)` w16 h8 dst `(0,0)`; row1 src `(0,8)` w16 h8 dst `(0,8)`. Confirms rows are not coalesced (2 blits for a 2×2 → the 2.0× ratio). Run: PASS.

- [ ] **Step 3: Scenario 3 — negative bias / #24 clip.** `grid_w=3, grid_h=1`, one run `run_m1=2` (run=3, 24px wide) at cell (0,0), `bias=(-8, 0)`. Visible window starts at cell cx0 such that `cx0*8+bias>=0`; the first partially-off-left run is clipped by `comp_pipeline`. Path B = the expanded `OP_BLIT`(s) with dst `(cx*8-8, 0)` (signed negative), relying on the same clip. Assert framebuffer identical AND no OOB write (a negative dst that wrapped would corrupt far-away pixels — the pixel compare catches it). Run: PASS.

- [ ] **Step 4: Scenario 4 — full-cull.** `grid_w=2, grid_h=2` non-empty, `bias=(-64, 0)` so the whole biased grid is off the left edge (`vis_lo_x>=vis_hi_x`). Path B = CLEAR only, zero blits. Assert Path A issues zero transactions. Run: PASS.

- [ ] **Step 5: Scenario 5 — maximal 16-cell run end-to-end.** `grid_w=16, grid_h=1`, one cell `run_m1=15` (run=16, 128px), bias 0. Path B = ONE `OP_BLIT` w128 h8. Run: PASS.

- [ ] **Step 6: Scenario 6 — right-edge run clamp.** `grid_w=40, grid_h=1` at `bias=(0,0)` (grid is 320px, exactly FB width) with a run that starts at cx=38, `run_m1=4` (run=5) — it would reach cx=43 but `cx1=40`, so `run` clamps to 2. Path B = ONE `OP_BLIT` w16 (2 cells), NOT w40. Assert the ISSUED width is 16 (the clamp is pixel-invisible but transaction-visible — this is why the transaction-sequence compare exists). Run: PASS.

- [ ] **Step 7: Scenario 7 — `pid==0xFFE` (max non-empty).** `grid_w=1, grid_h=1`, `pid=0xFFE`, FRT/CFT populated at index `0xFFE` (needs `MAXP=256`... note `0xFFE=4094 > 256`, so this scenario must use a `pid` that fits the widened table; use the largest in-range `pid = MAXP-1 = 255` instead and document that `0xFFE` is the *encoding* max, not an addressable index under `MAXP=256`). Path B = one `OP_BLIT` resolving `pid=255`. Run: PASS. *(This corrects the handoff's "pid==0xFFE" note: the cell field is 12-bit but the pattern table is `MAXP`-deep; the addressable max is `MAXP-1`. Assert the decode masks exactly 12 bits by also feeding a cell with spare bits set — next step.)*

- [ ] **Step 8: Scenario 8 — spare bits `[31:24]` set-and-ignored.** Same as scenario 0 but the cell word has `[31:24]=0xFF`. Path B identical to scenario 0. Asserts the decode masks the spare bits (a decode that read `pid` from a wider slice would resolve the wrong pattern). Run: PASS.

- [ ] **Step 9: Run the whole tb once more and confirm all scenarios green**

Run: `cd fpga/sim && ./run_sims.sh tb_tilemap`
Expected: PASS with all 9 scenarios (0-8) reporting `errors=0`.

- [ ] **Step 10: Commit**

```bash
git add fpga/sim/tb_tilemap.sv fpga/rtl/blitter_top.sv
git commit -m "test(blitter): full BLT_OP_TILEMAP edge-case coverage

Adds runs, multi-row (2.0x), negative-bias #24 clip, full-cull, maximal
16-cell run, right-edge run clamp (transaction-visible only), max in-range
pid, and spare-bit masking to tb_tilemap. Corrects the handoff's pid==0xFFE
note: the addressable pattern max is MAXP-1, not the 12-bit encoding max.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WNuJ2Q7B4D2zmCV8u4dAae"
```

---

### Task 5: Remove the bgplane RTL

The bgplane datapath is inert (never issued since Phase A) and rides B2's build so timing/STA is paid once. Delete it, retire its FSM states (returning them to the reclaimable pool), and drop its TBs. Keep the host-side RESERVED wire constants.

**Files:**
- Delete: `fpga/rtl/fbram_to_sdram.sv`, `fpga/rtl/bgw_ch0_mux.sv`, `fpga/rtl/bgplane_coverage.sv`
- Delete: `fpga/sim/tb_bgplane_3plane_xl.sv`, `tb_bgplane_base_wrap_xl.sv`, `tb_bgplane_coverage.sv`, `tb_bgplane_equivalence.sv`, `tb_bgplane_inval_teeth.sv`, `tb_bgplane_maptrans.sv`, `tb_bgplane_write_pipe_xl.sv`, `tb_bgplane_write_pipe.sv`, `tb_pal8_bgplane.sv`
- Modify: `fpga/rtl/blitter_top.sv` (remove the ~93 bgw/bgplane refs, the `OP_BGPLANE_WRITE` decode arm, and states `S_BGW_WAIT`/`S_BGW_BUSY`)
- Modify: `fpga/sim/run_sims.sh` (remove any bgplane-specific SKIP/NONGATING tuning lines that now reference deleted TBs)
- Keep unchanged: `patches/mister/blitter/blitter_ref.h` (`BLT_OP_BGPLANE_WRITE=8`, `BLT_F_BGCOV=0x80` stay)

**Interfaces:**
- Consumes: nothing (removal only).
- Produces: a bgplane-free `blitter_top.sv` with `S_BGW_WAIT`/`S_BGW_BUSY` (54/55) freed; the same synthesizable top the Task 6 build compiles.

- [ ] **Step 1: Delete the three RTL modules and nine bgplane TBs**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
git rm fpga/rtl/fbram_to_sdram.sv fpga/rtl/bgw_ch0_mux.sv fpga/rtl/bgplane_coverage.sv
git rm fpga/sim/tb_bgplane_3plane_xl.sv fpga/sim/tb_bgplane_base_wrap_xl.sv \
       fpga/sim/tb_bgplane_coverage.sv fpga/sim/tb_bgplane_equivalence.sv \
       fpga/sim/tb_bgplane_inval_teeth.sv fpga/sim/tb_bgplane_maptrans.sv \
       fpga/sim/tb_bgplane_write_pipe_xl.sv fpga/sim/tb_bgplane_write_pipe.sv \
       fpga/sim/tb_pal8_bgplane.sv
```

- [ ] **Step 2: Strip bgplane from `blitter_top.sv`**

Remove: the `bgplane_coverage`/`bgw_ch0_mux`/`fbram_to_sdram` instantiations and their wiring; the `OP_BGPLANE_WRITE` decode arm in `S_SETUP`; the `S_BGW_WAIT`/`S_BGW_BUSY` state bodies and their localparam lines; every `bgw_*`/`bgplane`/`BGCOV`/`fbram_to_sdram` signal declaration. Verify none remain:
```bash
grep -ni "bgw\|bgplane\|BGCOV\|fbram_to_sdram" fpga/rtl/blitter_top.sv
```
Expected: no output (the RESERVED opcode number lives in the host header only, not here).

- [ ] **Step 3: Remove stale bgplane tuning from `run_sims.sh`**

Delete any `SKIP`/`NONGATING` list entries and comment lines in `fpga/sim/run_sims.sh` that name a `tb_bgplane_*` / `tb_pal8_bgplane` TB (they no longer exist). Confirm:
```bash
grep -n "bgplane" fpga/sim/run_sims.sh
```
Expected: no output.

- [ ] **Step 4: Run the full sim suite**

Run: `cd fpga/sim && ./run_sims.sh`
Expected: the suite completes with every remaining gating TB PASS, including `tb_tilemap`; no build error from a dangling bgplane reference.

- [ ] **Step 5: Confirm host RESERVED constants are intact**

Run: `grep -n "BLT_OP_BGPLANE_WRITE\|BLT_F_BGCOV" patches/mister/blitter/blitter_ref.h && python3 scripts/tests/test_wire_constants.py`
Expected: both constants still present; wire test PASS (it should be unaffected — it never checked the bgplane opcode against fabric).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor(blitter): remove inert bgplane RTL

Deletes fbram_to_sdram / bgw_ch0_mux / bgplane_coverage, the OP_BGPLANE_WRITE
decode arm + S_BGW_WAIT/S_BGW_BUSY states (returned to the reclaimable pool),
and the nine tb_bgplane_* / tb_pal8_bgplane benches. Rides the B2 Quartus
build so timing is paid once. Host RESERVED BLT_OP_BGPLANE_WRITE=8 /
BLT_F_BGCOV=0x80 deliberately retained so the wire numbering stays stable.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WNuJ2Q7B4D2zmCV8u4dAae"
```

---

### Task 6: Quartus fit + seed sweep + STA gate

The verification gate. A single passing RBF is not evidence — Stage 2 saw non-attributable placement variance on the blitter clock. Build across seeds and confirm the worst-case setup slack on the 98.44 MHz core/blitter clock (`general[0]`) does not regress the +0.361 ns baseline.

**Files:**
- Modify (per seed, reverted after): `fpga/Solarus.qsf:64` (`set_global_assignment -name SEED <n>`)
- Read: `fpga/output_files/Solarus.fit.rpt`, `fpga/build_<date>.log` (STA output the build script already emits)

**Interfaces:**
- Consumes: the sim-clean `blitter_top.sv` from Tasks 3-5.
- Produces: a seed-sweep timing table and a pass/fail verdict against +0.361 ns — the phase's exit gate.

- [ ] **Step 1: Build the baseline seed and record the M10K fit**

Run: `cd fpga && ./build_solarus.sh 2>&1 | tee build_seed1.log`
Expected: build completes; capture the `>>> Timing closure check (setup)` and `CORE 98.44MHz (general[0]) worst setup` lines from the log, and `Total RAM Blocks` from `output_files/Solarus.fit.rpt` (confirm `MAXP=256` fit still holds after bgplane removal freed blocks).

- [ ] **Step 2: Sweep seeds**

For `n` in `2 3 4 5 6` (a 5-seed sweep; extend to 10 if any result is within 0.1 ns of the baseline): set `fpga/Solarus.qsf:64` to `set_global_assignment -name SEED <n>`, run `./build_solarus.sh 2>&1 | tee build_seed<n>.log`, and record the worst-case setup slack on `general[0]` from each log. Restore `SEED 1` afterward.

- [ ] **Step 3: Tabulate and gate**

Assemble the per-seed worst-case setup slack (blitter clock). Gate: the sweep's worst slack must be ≥ the +0.361 ns baseline (i.e. no regression). If any seed regresses below baseline, STOP and report — the FSM's `S_GRID_SETUP` arithmetic (visible-window intersect + `cy0*grid_w` multiply) is the likely offender and should be split across two states (the reclaimed pool affords it: `40/41/54/55/62/63` are free).

- [ ] **Step 4: Run the full sim suite once more on the shipped RTL**

Run: `cd fpga/sim && ./run_sims.sh`
Expected: all gating TBs PASS including `tb_tilemap`. (RTL is unchanged since Task 5 unless Step 3 forced a split — if it did, re-run and re-commit the FSM change before this step.)

- [ ] **Step 5: Record results and commit the timing evidence**

Write the seed-sweep table + verdict into `docs/superpowers/2026-07-20-stage3b-phaseB2-hw-timing.md` (seed, blitter-clock worst setup slack, M10K blocks, verdict vs +0.361 ns). Commit:
```bash
git add docs/superpowers/2026-07-20-stage3b-phaseB2-hw-timing.md fpga/Solarus.qsf
git commit -m "docs(blitter): B2 seed-sweep + STA evidence (tilemap_unit + bgplane removal)

N-seed sweep of worst-case setup slack on the 98.44MHz blitter clock vs the
+0.361ns baseline; MAXP=256 M10K fit confirmed post-bgplane-removal. SEED
restored to 1. A passing RBF alone is not the gate — this sweep is.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WNuJ2Q7B4D2zmCV8u4dAae"
```

---

## Self-Review

**Spec coverage:**
- FSM (5 states, reclaimed slots, shared resolve, own slice/wait) → Task 3. ✓
- Implicit dst (res_dx/res_bias) → Task 3 FSM reference (`S_GRID_SLICE`). ✓
- Cell-bitfield localparams + cross-check → Task 2. ✓
- `MAXP` widen + fit confirm → Task 1 (widen) + Task 6 Step 1 (post-removal fit). ✓
- bgplane RTL removal → Task 5. ✓
- `tb_tilemap.sv` + all unpinned behaviours → Task 3 (harness + scenario 0) + Task 4 (runs, multi-row 2.0×, full-cull, 16-run, pid max, spare bits, #24 clip, right-edge clamp). ✓
- Quartus fit + seed sweep + STA → Task 6. ✓
- GRID_BUF 2 MiB stands → Global Constraints (no bounds-check state added). ✓
- Carried-to-B3 items (HW-soak, engine patches, wiring, HW gate) → out of scope, not tasked here (correct). ✓

**Placeholder scan:** No "TBD"/"handle edge cases"/"similar to Task N". Each scenario carries its explicit cells + Path-B expansion. The one deliberate deviation (`pid==0xFFE`) is documented as a correction with the concrete substitute (`pid=MAXP-1`), not left vague.

**Type consistency:** `res_dx/res_dy/res_bias_x/res_bias_y`, `c_src_x/c_src_y/c_w/c_h/c_dst_x/c_dst_y`, `frt_q`, `pipe_start`/`p_blit_done`, `S_TLR_CFT`/`S_TLR_FRT`/`S_TLR_SLICE`/`S_TL_ISSUE`/`S_NEXT_CMD` all match `blitter_top.sv` as read. New names (`grid_w/grid_h/cells_off/cx/cx0/cx1/cy/cy1/row_base/g_sub_x/g_sub_y/g_run/tl_grid/cell_half`, states `S_GRID_*`, localparams `GRID_CELL_*`) are defined once (Task 2/Task 3) and used consistently. `MAXP`/`BLT_MAXP` widened together (Task 1).

**Known follow-up flagged in-plan:** if Step 3 of Task 6 shows a timing regression, `S_GRID_SETUP` splits into two states — the plan calls this out and confirms the state budget affords it.
