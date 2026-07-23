#!/usr/bin/env python3
"""Offline fabric-cost attribution model (Task 5 — implementation not yet written).

This file is a placeholder created by Task 4 solely to carry the MEASURED
grid-walk calibration constants forward for Task 5 to consume, per the Task 4
brief's Step 5. Task 5 owns filling in the actual attribution model.

[Task 4 calibration] Measured via fpga/sim/tb_tilemap.sv's CALIB counters
(instance `blt`, DUT `state` bucketed by S_GRID_FETCH/DECODE/SLICE/WAIT and
S_TLR_CFT/FRT — see the "[Task 4]" comments in that file), run against
Scenario 6 (S6_RIGHT_EDGE_CLAMP: 38 empty cells walked one-at-a-time + one
coalesced 2-cell/16px-wide, 8px-tall run), 2026-07-23:

    CALIB grid: empty_state_cyc=78 resolve_cyc=3 wait_cyc=287 n_runs=1 n_empty_known=38

Derived constants:

    empty_cyc_per_cell = empty_state_cyc / n_empty_known
                       = 78 / 38 = 2.05 cycles per empty grid cell
                       (S_GRID_FETCH + S_GRID_DECODE, ~1 cycle each — matches
                       the 2-state walk-loop-per-empty-cell RTL structure)

    run_cyc_fixed  = (resolve_cyc + wait_cyc - pixel_cyc) / n_runs
                   = (3 + 287 - 134) / 1 = 156 cycles fixed cost per run
                       (S_GRID_SLICE/S_TLR_CFT/S_TLR_FRT dispatch + the
                       per-row row_base/setup overhead S_GRID_WAIT absorbs
                       while polling p_blit_done)

    px_cyc_per_col = 8 cycles per 8px-tall column
                       (ASSUMED from the "issue-interval-1 compositor" design
                       — comp_pipeline #36 — i.e. 1 cycle/pixel throughput,
                       NOT independently fit: this scenario has only n_runs=1
                       so fixed vs. per-pixel cost cannot be separated from a
                       single data point. pixel_cyc above = run's 16x8=128px
                       * 1 cyc/px + ~6 cycle pipeline drain (PIPE_DEPTH~6,
                       see fpga-colormod-pipeline-timing memory) = 134.)

CAVEAT: single-scenario, single-run calibration — order-of-magnitude only
(per the Task 4 brief's Step 5 allowance). A second scenario with a longer
empty span and/or multiple runs of varying width would let run_cyc_fixed and
px_cyc_per_col be fit independently instead of assuming the latter.
"""
