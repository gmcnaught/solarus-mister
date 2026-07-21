# Stage 3b Phase B2 — CI seed sweep + STA evidence

**Date:** 2026-07-21
**Branch:** `feat/stage3b-b2-tilemap-unit`
**Clock under scrutiny:** the 98.44 MHz core/blitter domain (`general[0]`).
**Toolchain:** Quartus Prime Lite 17.0 via CI `build-rbf.yml` (self-hosted Windows runner); Quartus is
not available locally, so all timing numbers come from CI. Seed sweep uses the workflow's `seed`
`workflow_dispatch` input (per-seed concurrency groups); no `Solarus.qsf` edits during the sweep.

## Headline

`BLT_OP_TILEMAP` as first implemented **violated the blitter clock by −0.964 ns** — the grid FSM's
`S_GRID_SETUP` did the whole visible-window computation *and* the `row_base = cy0*grid_w` multiply in
one combinational cycle. Two pipeline splits moved that work off the critical path. On the final RTL
the **grid FSM is no longer in the worst paths on any seed**, and four of five seeds close with
positive slack. **Shipped seed: SEED 3 = +0.175 ns** (committed to `Solarus.qsf`).

## Timing trajectory (SEED 1 unless noted)

| Stage | RTL | Worst setup slack | Worst path |
|---|---|---|---|
| Pre-FSM (Task 1) | MAXP=256 + FRT relocation, no grid FSM | −0.100 ns | (pre-existing) |
| FSM added (Task 3) | grid FSM, single-cycle setup | **−0.964 ns** | `blitter_top\|row_base[*]` — the `cy0*grid_w` multiply chained off `g_cy0=(vlo_y−bias)>>3` |
| 6a split | `row_base` multiply → own cycle (`S_GRID_SETUP2`, from registered `cy`) | −0.229 ns (best of 5 seeds) | `blitter_top\| c_h → cy1[8]` — the y-window arithmetic |
| 6b split | window math → own cycle (`S_GRID_BOUNDS`) | **+0.175 ns (SEED 3)** | `yc_out\|cburst_phase` (composite encoder — NOT grid) |

The −0.100 ns pre-FSM floor is the cost of `MAXP=256` (the `frt_bram` doubling), independent of the
grid FSM; it is not addressed here (see the design spec's `MAXP` note).

## Final-RTL seed sweep (HEAD `011cb32`, doubly-pipelined)

| Seed | Worst setup slack | Worst path (pre-existing block, NOT grid) |
|---|---|---|
| 1 | −0.082 ns (VIOLATED) | `comp_pipeline\|comp_src_linebuf` altsyncram |
| 2 | **+0.096 ns** | `ascal` (video scaler) |
| **3** | **+0.175 ns** | `yc_out\|cburst_phase[7]` (composite Y/C encoder) |
| 4 | **+0.122 ns** | `yc_out\|cburst_phase[5]` |
| 5 | **+0.118 ns** | `yc_out\|cburst_phase[0]` |

**Interpretation:** the grid FSM (`row_base`, `cx*`, `cy*`, window math) appears in *none* of the
seeds' worst paths — the two splits removed it from the critical path entirely. The residual limiters
are pre-existing video blocks (ascal, yc_out, the compositor line buffer) that B2 did not touch. SEED
3's +0.175 ns is clean (Path #1 not VIOLATED). SEED 1 (the previously-committed seed) is marginally
negative at −0.082 ns on a pre-existing `comp_src_linebuf` path — hence the switch to SEED 3.

## Decisions

- **Ship SEED 3.** `Solarus.qsf` `SEED 1 → SEED 3`; the default push build now closes at +0.175 ns.
- The two pipeline splits (6a `S_GRID_SETUP2`, 6b `S_GRID_BOUNDS`) add 2 setup cycles per grid op —
  once per `BLT_OP_TILEMAP` command, not per cell — and are behaviour-identical (verified bit-exact by
  the `tb_tilemap` S0–S8 equivalence suite, which checks issued transactions + framebuffer pixels, not
  cycle count).

## Resource fit (`MAXP=256`)

The RBF builds cleanly (no fit/M10K overflow error). Total block memory bits ≈ 3.49 M. `MAXP=256`
fits; the FRT relocation above GRID_BUF (Task 1) left CFT/CLUT/SP_BUF/GRID_BUF frozen.

## Method note

A passing RBF is not by itself evidence of closed timing (Critical Warning 332148 is a warning, not an
error). The gate here is the per-seed worst-case setup slack on the blitter clock across the sweep,
plus the confirmation that the grid FSM is absent from the worst paths — both recorded above.
