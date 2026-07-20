# Stage 3b — B1 → B2 handoff

**Date:** 2026-07-20
**B1 branch:** `feat/stage3b-b1-grid-wire-format` (8 tasks, stacked on Phase A / PR #128 merged + #130 open)
**B1 plan:** `docs/superpowers/plans/2026-07-20-retained-scene-stage3b-phaseB1-grid-wire-format.md`
**Next plan to write:** Phase B2 — `tilemap_unit` RTL + bgplane RTL removal (outline in the B1 plan's tail)

B1 is host-only and merges clean. This doc is what B2 must know before writing the Verilog `tilemap_unit`, gathered from the B1 whole-branch review. Nothing here is a B1 defect — it is all "the RTL author could get this wrong."

## The frozen contract B2 must match

**Cell encoding** (`patches/mister/blitter/grid_cell.h`), decoded by `blt_ref_tilemap` in `blitter_ref.c`:
```
[11:0]  pid      (0xFFF = EMPTY, walker skips)
[15:12] sub_x    x offset inside the pattern, in 8px cells
[19:16] sub_y    y offset inside the pattern, in 8px cells
[23:20] run_m1   (cells remaining horizontally FROM THIS CELL) - 1
[31:24] spare    written 0; B2's decode MUST mask and ignore these
```

**The golden model is `blt_ref_tilemap` (`blitter_ref.c`).** B2's sim must match it bit-for-bit. The walk:
1. `cells_off = dst_x | (dst_y<<16)`; grid is `w` × `h` CELLS (header `w`/`h` carry cell counts, not pixels, not an entry count).
2. Cell (cx,cy) screen pos = `(cx*8 + bias_x, cy*8 + bias_y)`; bias = `(src_x, src_y)` read SIGNED (routinely negative = -camera).
3. Visible cell window = biased grid ∩ framebuffer. **`cx0` = floor, `cx1` = ceil** — this rounding is load-bearing (scenario 8 fails if you use floor for cx1) and is how partially-visible edge cells survive.
4. Per visible row, left→right: read cell; EMPTY → advance 1; else `run = blt_grid_cell_run()` clamped to not pass the window's right edge; resolve pattern src (same `cft[pid] → frt[pid*MAXF+frame]` path as `OP_TILELIST_RES`); issue ONE blit `run*8 × 8` px, src `pattern_src + (sub_x*8, sub_y*8)`, dst `(cx*8+bias_x, cy*8+bias_y)`; advance cx by run.
5. **#24 rule: clip the destination in SIGNED space BEFORE any cast to an unsigned field.** A negative dst clipped after the cast wraps to a huge positive and writes OOB. The reference does the clip in `blit_one` before the array-index cast; B2 must do the equivalent in fixed-width RTL.

**Run coalescing invariant:** a run spans only ONE pattern instance (sub_x incrementing by 1, sub_y constant, same pid). Merging adjacent instances would read past the pattern in the atlas. The builder guarantees this; the walker relies on it. A run of N is pixel-identical to N 1-cell blits (proven: Task 5 mutation 2).

## What B2 must decide / add (from the B1 review)

### 1. GRID_BUF sizing — resolve before writing the FSM
GRID_BUF is **2 MiB** at host `0x3BFF3000` / fabric `GRID_BUF_QW=0x077FE600` (×8 = same address — verified). That is **~1.5× one worst-case map** (382×282 cells × 3 layers × 4 B = 1.23 MiB), **not 2×**. It does NOT hold two full worst-case maps co-resident (needs 2.46 MiB).

**Decision B2 owns:** does a scroll transition ever require the outgoing AND incoming maps *both* fully gridded at once? If yes, GRID_BUF must grow to ≥3 MiB **and** gain a `grid_used` bounds check — `blt_grid_list_init` sets `grid_cap` today but the emitter (`blt_grid_list`) does not enforce it. If no (e.g. the old map stays on the per-tile path during a scroll, or grids aren't both worst-case), 2 MiB stands and the comment is already correct.

### 2. Cell-bitfield cross-check gap
`test_wire_constants.py` pins the opcode (11) and GRID_BUF base/size on both sides, but **not the cell bit positions** — the fabric has no cell decode to grep yet. When B2 writes the decode, the ONLY guard that RTL bit ranges match `grid_cell.h` is B2's own golden-model sim diff. Either add a bitfield cross-check to `test_wire_constants.py`, or treat the sim diff as the deliberate gate.

### 3. Walker behaviours no B1 test pins (cover these in B2's sim)
- **Full-cull:** grid non-zero but bias moves it entirely off-screen → zero blits. Structural in the model, not diff-tested.
- **Maximal 16-cell run end-to-end:** `test_gridbuild` #7 pins the *builder* emitting run=16, but the equivalence gate's widest run is 5 cells — a 128px-wide run blit is never diff-tested through the walker.
- **`pid == 0xFFE`** (max non-empty): `test_gridcell`'s `pid += 7` loop skips 4094.
- **spare bits [31:24] on read:** pinned written-zero; B2's decode must mask+ignore them.

### 4. The right-edge run clamp is count-relevant, not pixel-relevant
`blt_ref_tilemap`'s clamp `if (cx + run > cx1) run = cx1 - cx;` is **invisible to framebuffer memcmp** (blit_one's per-pixel clip discards the off-screen pixels anyway) but **changes the issued blit count / width**. Task 6's `blt_ref_tilemap_max_right_x` assertion guards it. In RTL the clamp's stake is **compositor bandwidth** — an unclamped walker issues a wider blit that the comp pipeline clips. Not a correctness bug, but measure it (see below).

## Measurements B2/B3 inherit (not estimates)

- **Grid-walk vs per-tile blit ratio: worst-case 2.0×** (multi-row patterns — the walk issues one blit per ROW of a run; rows are not coalesced, only horizontal runs). All 9 B1 scenarios 0.6×–2.0×. This is the real number replacing the earlier ~3× estimate. It means the grid op bounds work by *screen* size (the win on big maps) but on a small parallax scene like map 119 issues up to ~2× the transactions — expected, and throughput is explicitly NOT gated this stage.

## Already-owed, carried forward

- **DDR HW-soak.** BLT_DDR_SIZE grew 16→18 MiB for GRID_BUF. The new 2 MiB tail (`0x3C000000..0x3C200000`) is inside the kernel reserved window `[0x1FF00000, 0x40000000)` (memmap=513M$511M) so architecturally safe, but only the old 16 MiB was HW pattern-verified. **HW-soak the grown tail before B2/B3 ships GRID_BUF traffic** (nothing reads it in B1).
- **FSM state budget.** `blitter_top.sv` state is `reg [5:0]`; only `6'd62`/`6'd63` remain above the high-water mark. A multi-state grid walker needs to reclaim retired slots (`14`, `27-29`, `31`, `40`, `41`) or widen the field. Decide before writing states.
- **Implicit destination.** The grid op is the first payload whose dst is derived from cell index, not carried per-entry — the existing `res_bias + entry.dst` convergence onto `S_TL_ISSUE` needs a cell-index→dst computation the other ops don't have.
- **`frt_bram` widen** `MAXP` 128→256 (measured max 251 distinct patterns, map 3). ~8 M10K blocks against 86 free — confirm against a real fit report; block memory is 61% by bits but 84% by blocks, so blocks bind.
- **bgplane RTL removal** rides B2's build: `fbram_to_sdram.sv`, `bgw_ch0_mux.sv`, `bgplane_coverage.sv`, 85 refs in `blitter_top.sv`, twelve `tb_bgplane_*` TBs.
- **New `fpga/sim/tb_tilemap.sv`** is auto-discovered by `run_sims.sh` (`TBS=(tb_*.sv)`) — no workflow registration needed. Model on `tb_spritelist.sv`: assert identical issue-transaction sequences (order-sensitive) plus identical `comp_fbram` pixels.
