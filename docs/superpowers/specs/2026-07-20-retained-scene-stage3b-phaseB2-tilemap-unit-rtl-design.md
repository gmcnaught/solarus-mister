# Stage 3b Phase B2 — `tilemap_unit` RTL + bgplane RTL removal (design)

**Date:** 2026-07-20
**Depends on:** Phase B1 (`feat/stage3b-b1-grid-wire-format`, PR #132 merged) — the frozen wire
format, emitter, and golden model `blt_ref_tilemap`.
**Handoff read first:** `docs/superpowers/2026-07-20-stage3b-b1-to-b2-handoff.md`.
**Next phase:** B3 — engine patches, renderer wiring behind `SOLARUS_TILEMAPCH` (default OFF),
device HW gate.

## Purpose

Implement `BLT_OP_TILEMAP` (opcode `8'd11`) in the fabric so the compositor walks a per-layer
8px cell grid in `GRID_BUF` and issues one coalesced blit per horizontal run — the RTL half of
the contract B1 froze host-side. Validated **in simulation only**, bit-for-bit against B1's
golden model. The now-inert bgplane RTL is removed in the same Quartus build so the project pays
one build / STA / seed-sweep cycle, not two.

### Non-goals (explicitly B3, not B2)

- No engine patches, no renderer wiring, no `SOLARUS_TILEMAPCH` seam.
- No device run. B2 ends at a sim-clean `tilemap_unit` plus a Quartus fit + seed sweep + STA pass.
- No DDR HW-soak of the grown `GRID_BUF` tail — nothing reads that region until B3.

## Frozen contract this RTL must match

Golden model: `blt_ref_tilemap` (`patches/mister/blitter/blitter_ref.c`). B2's sim must match it
bit-for-bit — both the issued **transaction sequence** and the resulting `comp_fbram` pixels.

Cell encoding (`grid_cell.h`), one 32-bit `blt_grid_cell_t` per cell, row-major:

```
[11:0]  pid      (0xFFF = EMPTY, walker skips)
[15:12] sub_x    x offset inside the pattern, in 8px cells
[19:16] sub_y    y offset inside the pattern, in 8px cells
[23:20] run_m1   (cells remaining horizontally from this cell) - 1   -> run = run_m1 + 1, 1..16
[31:24] spare    written 0; decode MUST mask and ignore
```

Command-header field overload (already documented in `blitter_defs.vh`, verified against
`mister_blitter_renderer.cpp`):

- `w | h<<16`         = `grid_w | grid_h<<16` — grid rectangle **in 8px cells**, not pixels, not
  an entry count.
- `dst_x | dst_y<<16` = `cells_off`, the byte offset of the cell array within `GRID_BUF`.
- `src_x / src_y`     = signed per-batch dst bias (map-coord → screen), the SAME convention as
  `OP_TILELIST` / `OP_TILELIST_RES` / `OP_SPRITELIST` (routinely negative = −camera).
- `src_off / src_stride` = shared tileset texture base (same field, same meaning as the other ops).

The walk, stated exactly (from the golden model):

1. `grid_w == 0 || grid_h == 0` → cull.
2. Visible pixel window = biased grid ∩ framebuffer:
   `vis_lo_x = max(bias_x, 0)`, `vis_hi_x = min(bias_x + grid_w*8, FB_WIDTH)`, same for y.
   `vis_lo >= vis_hi` on either axis → **cull the whole op** before any cell read or blit
   (this is what makes an off-screen grid emit zero blits instead of a negative-dst blit).
3. Cell-index window: `cx0 = (vis_lo_x - bias_x)/8` (**floor**),
   `cx1 = (vis_hi_x - bias_x + 7)/8` (**ceil**), clamped to `grid_w`; same for y clamped to
   `grid_h`. Numerators are non-negative (`vis_lo >= bias`), so `/8` is a plain `>>3`; ceil is
   `(n+7)>>3`. The floor/ceil asymmetry is load-bearing — it is how partially-visible edge cells
   survive.
4. For `cy` in `[cy0, cy1)`, `cx = cx0`, left→right while `cx < cx1`:
   read cell `(cy*grid_w + cx)`; EMPTY → `cx += 1`, continue; else
   `run = run_m1 + 1`, clamped `if (cx + run > cx1) run = cx1 - cx`;
   resolve `pid → CFT[pid] → FRT[pid*MAXF + frame]` (identical to `OP_TILELIST_RES`);
   issue ONE blit `run*8 × 8` px, src `(FRT.src_x + sub_x*8, FRT.src_y + sub_y*8)`,
   dst `(cx*8 + bias_x, cy*8 + bias_y)`; `cx += run`.
5. **#24 rule:** dst is computed wide+signed, and clipped against the framebuffer *while still
   signed*, strictly before any cast to an unsigned pixel index — a negative dst clips, it never
   wraps to a huge positive. In RTL this is inherited by riding the existing
   `comp_pipeline` clip that the shipping ops already use for negative dsts.

**Run-coalescing invariant:** a run spans one pattern instance only (`sub_x` +1 per cell, `sub_y`
constant, same pid). A run of N is pixel-identical to N 1-cell blits. The builder guarantees it;
the walker relies on it.

**Right-edge run clamp** (`cx + run > cx1 → run = cx1 - cx`) is invisible to a framebuffer memcmp
(`comp_pipeline` clips the off-screen pixels anyway) but changes the issued blit **width /
count** — so it is asserted via the transaction-sequence check, not just the pixel check.

## Resolved decisions (approved 2026-07-20)

1. **FSM state budget — reclaim retired slots, keep `reg [5:0]`.** The walker needs 5 new states;
   the reclaimable pool is `14, 27, 28, 29, 31, 40, 41` plus `62, 63` free (9), further widened
   by the 2 slots bgplane removal retires (`S_BGW_WAIT=54`, `S_BGW_BUSY=55`). Widening the state
   field to 7-bit was rejected: it adds a bit to every FSM comparator, to `rd_ret`/`wr_ret`, and
   to the `dbg[5:0]` post-mortem probe — extra critical-path logic against the thin +0.361 ns
   blitter-clock margin. Allocate the 5 grid states from the reclaimed pool (e.g. `14, 27, 28,
   29, 31`), leaving `40/41/54/55/62/63` as headroom.

2. **Implicit destination — reuse the `res_dx/res_dy + res_bias` convention.** Feed the
   cell-derived `cx*8`/`cy*8` into `res_dx`/`res_dy` (the "map-coord dst" slot every list op
   already uses), and let the existing `c_dst <= $signed(res_dx) + res_bias_x` produce the screen
   dst. Zero new datapath, matches the golden model's `cx*8 + bias`, and inherits the #24
   signed-clip for free via the shared `comp_pipeline` issue path. A separate direct-to-`c_dst`
   datapath was rejected — it duplicates the signed-clip convention and diverges from every other
   op.

3. **`GRID_BUF` sizing — 2 MiB stands, no bounds-check state.** A scroll transition does **not**
   grid both maps at once: Stage 3a scrolls the outgoing map as a retained alias blit, not a
   second grid, so only the incoming map's static layers are gridded. `GRID_BUF` stays 2 MiB at
   `0x3BFF3000` / `GRID_BUF_QW = 0x077FE600`; the existing sizing comment is correct; no
   `grid_used` enforcement is added this phase.

## FSM design (`blitter_top.sv`)

Five new states. The walker is the resident-tile path (`S_TLR*`) with a 2D run-coalescing front
end; it **shares** the pattern-resolve states and the `comp_pipeline` handshake, and keeps its
**own** slice + wait states.

- **`S_GRID_SETUP`** — decode arm off `S_SETUP` when `c_opcode == OP_TILEMAP`. Inputs:
  `grid_w = c_w`, `grid_h = c_h`, `cells_off = {c_dst_y, c_dst_x}`, `res_bias_{x,y} =
  $signed(c_src_{x,y})` (already latched by the shared `S_SETUP` bias load). Compute the visible
  pixel window and `cx0/cx1/cy0/cy1` per the walk above; full-cull (`grid_w==0 || grid_h==0` or
  empty window) → `S_NEXT_CMD`. Latch `cx=cx0`, `cy=cy0`, and `row_base = cy0*grid_w` — the ONLY
  multiply; per-row it is maintained incrementally (`row_base += grid_w`), so there is no
  per-cell multiply on the walk.

- **`S_GRID_FETCH`** — `cell_idx = row_base + cx`; issue the `GRID_BUF` read at
  `` `GRID_BUF_QW + ((cells_off + cell_idx*4) >> 3)``; record the 32-bit half select `= cell_idx[0]`
  (low half = even, high half = odd — correct for odd `grid_w` because it keys off `cell_idx`, not
  `cx`). `rd_ret = S_GRID_DECODE`. (`cells_off` is qword-aligned by construction; note as an
  invariant.)

- **`S_GRID_DECODE`** — select `cell = cell_idx[0] ? rd_data[63:32] : rd_data[31:0]`; extract
  `pid = cell[11:0]`, `sub_x = cell[15:12]`, `sub_y = cell[19:16]`, `run = cell[23:20] + 1`;
  **`cell[31:24]` masked and ignored.** If EMPTY (`pid == 12'hFFF`): `cx += 1`; if `cx >= cx1`
  do the row advance (`cy += 1; cx = cx0; row_base += grid_w`; `cy >= cy1 → S_NEXT_CMD` else
  `S_GRID_FETCH`), else `S_GRID_FETCH`. Else: run-clamp `if (cx + run > cx1) run = cx1 - cx`;
  latch `res_pid = pid`, `res_dx = cx*8`, `res_dy = cy*8`, `g_sub_x = sub_x`, `g_sub_y = sub_y`,
  `g_run = run`; set the `tl_grid` mode reg; → **shared `S_TLR_CFT` → `S_TLR_FRT`**.

- **shared `S_TLR_CFT` / `S_TLR_FRT`** — unchanged pid→`cft_mem`→`frt_bram` resolve, except the
  terminal branch becomes `state <= tl_grid ? S_GRID_SLICE : S_TLR_SLICE`.

- **`S_GRID_SLICE`** — `c_src_x = frt_q.src_x + g_sub_x*8`, `c_src_y = frt_q.src_y + g_sub_y*8`,
  `c_w = g_run*8`, `c_h = 8`, `c_dst_x = $signed(res_dx) + res_bias_x`,
  `c_dst_y = $signed(res_dy) + res_bias_y`; pulse `pipe_start` → `S_GRID_WAIT`.

- **`S_GRID_WAIT`** — on `p_blit_done`: `cx += g_run`; if `cx >= cx1` row advance
  (`cy += 1; cx = cx0; row_base += grid_w`; `cy >= cy1 → S_NEXT_CMD` else `S_GRID_FETCH`), else
  `S_GRID_FETCH`.

**Design refinement (approved):** the B1 outline said "converge on the shared `S_TL_ISSUE`," but
that state's advance is the flat-list `tl_idx++/tl_byte+=stride`, whereas the grid advance is 2D.
Rather than branch the shared issue/wait tail that three shipping ops (`OP_TILELIST`,
`OP_TILELIST_RES`, `OP_SPRITELIST`) depend on — a regression risk against the thin margin — the
grid keeps its own `S_GRID_SLICE`/`S_GRID_WAIT` and shares only the *resolve* states and the
`pipe_start`/`p_blit_done` compositor handshake. Grid cells inside the window are never
fully-empty, so the `empty` cull in `S_TL_ISSUE` is not needed on this path anyway.

New registers: `grid_w`, `grid_h`, `cells_off`, `cx`, `cx1`, `cy`, `cy1` (`cx0`/`cy0` needed only
to reset `cx`), `row_base`, `g_sub_x`, `g_sub_y`, `g_run`, `tl_grid`, `cell_half`. Sized to the
worst-case map (382×282 cells → `cx/cy` 9-bit, `row_base` up to ~107k → 17-bit, `cells_off` 21-bit).

## Cell-bitfield cross-check (closes handoff gap #2)

`test_wire_constants.py` currently pins the opcode and `GRID_BUF` base/size on both sides but
**not** the cell bit positions — until B2 there was no fabric decode to grep. B2 names the cell
bit ranges as localparams in the decode (e.g. `GRID_CELL_PID_HI/LO`, `SUB_X_*`, `SUB_Y_*`,
`RUN_*`) and adds a cross-check asserting they match `grid_cell.h`'s shifts/masks. The sim diff
remains the primary correctness gate; this pins the wire numbering by a cheap test too.

## `frt_bram` widen `MAXP` 128 → 256

Map 3 has a measured 251 distinct patterns; `MAXP = 128` cannot hold them. Widen `MAXP` to 256 in
`blitter_defs.vh` (and the host `BLT_MAXP` mirror), growing `cft_mem` (256 u16) and `frt_bram`
(`MAXP*MAXF` qwords). **Note (found during execution):** this doubles the FRT *DDR region* 8→16 KiB,
and the FRT..GRID_BUF span is flush-packed — so FRT is **relocated to the top headroom above GRID_BUF**
(`0x3C1F3000`), leaving CFT/CLUT/SP_BUF/GRID_BUF bases frozen (user decision 2026-07-20). It is not a
free two-constant widen. **Confirm against a real Quartus fit report, not bit arithmetic** — the
frame-rect table is ~61% by bits but ~84% by M10K blocks (~8 blocks against 86 free), so blocks
bind and the bit count understates cost. If the fit is marginal, that is a finding for the
verification step, not an assumption to ship on.

## bgplane RTL removal (same build)

Delete the inert bgplane datapath so it rides B2's build:

- Files: `fbram_to_sdram.sv`, `bgw_ch0_mux.sv`, `bgplane_coverage.sv`.
- `blitter_top.sv`: the ~85 refs, the `OP_BGPLANE_WRITE` decode arm, and states `S_BGW_WAIT`
  (54) / `S_BGW_BUSY` (55) — which return to the reclaimable pool.
- The twelve `tb_bgplane_*` TBs.
- **Retained deliberately:** host-side `BLT_OP_BGPLANE_WRITE = 8` and `BLT_F_BGCOV = 0x80` in
  `blitter_ref.h` stay as RESERVED wire-ABI constants so `test_wire_constants.py` passes unedited
  and host↔RTL numbering stays stable. Do not recycle opcode 8; the grid op already owns 11.

## Simulation: `fpga/sim/tb_tilemap.sv`

Auto-discovered by `run_sims.sh` (`TBS=(tb_*.sv)`) — no workflow registration. Modeled on
`tb_spritelist.sv`: assert an **identical issue-transaction sequence** (order-sensitive; catches
reorder / drop / dup / wrong width) **and** identical `comp_fbram` pixels versus a reference driven
from the same cells. Cover the cases no B1 test pins:

- **Full-cull:** non-zero grid, bias moves it entirely off-screen → zero blits.
- **Maximal 16-cell run end-to-end:** a 128px-wide run blit walked (B1 pins the builder emitting
  run=16, but its equivalence gate's widest walked run is 5).
- **`pid == 0xFFE`** (max non-empty; B1's `pid += 7` loop skips 4094).
- **Spare bits `[31:24]` set** on read → decoded identically to spare=0.
- **Multi-row 2.0× case:** patterns taller than one cell (the walk issues one blit per row of a
  run; rows are not coalesced) — the worst-case transaction ratio.
- **Negative-bias #24 clip:** partially-off-left grid, first run clipped by `comp_pipeline`.
- **Right-edge run clamp:** a run that would pass `cx1`, asserted via the transaction sequence
  (width/count), since it is pixel-invisible.

## Verification

- Quartus **fit** — confirms the `MAXP=256` M10K fit against a real report.
- **Seed sweep** + STA against the **+0.361 ns** blitter-clock baseline. A single passing RBF is
  **not** evidence — Stage 2's own delta on this clock was non-attributable placement variance.
- `run_sims.sh` clean, including `tb_tilemap.sv`.

## Measurements inherited (not estimates)

Grid-walk vs per-tile blit ratio: worst-case **2.0×** (multi-row patterns), all B1 scenarios
0.6×–2.0×. Throughput is explicitly **not** gated this stage; the op bounds work by *screen* size
(the win on big maps) at up to ~2× the transactions on a small parallax scene like map 119 —
expected. Record `tilemap_unit` cyc/px on map 119 in B3, measured not gated.

## Carried to B3

- DDR HW-soak of the grown `GRID_BUF` tail (`0x3C000000..0x3C200000`), architecturally inside the
  kernel-reserved window but only the old 16 MiB was HW pattern-verified.
- Two engine patches (`resident_record_static` `tokens` param; forward map `width8`/`height8`).
- Renderer wiring into `resident_emit_static_layer()` behind `SOLARUS_TILEMAPCH` (default OFF).
- HW gate: map 119 (parallax load-bearing) and map 3 (251 patterns, pins `MAXP`). Operator's
  eyes, never self-declared.
