#!/usr/bin/env python3
"""Phase-0 comp attribution: combine a GRIDSTATS capture + overlay A/B Δcomp +
tb_tilemap-calibrated cycle constants into a ranked breakdown of comp's ms.

Consumes:
  - a GRIDSTATS capture log (Task 3's SOLARUS_GRIDSTATS engine dump), lines of
    the form `GRIDSTATS layer=<L> ratio=<r> win=... nonempty=<n> empty=<e>
    runs=<r> hist=...` — this module reads `nonempty=`, `empty=`, `runs=`.
  - `--overlay-ms`: the overlay channel's comp cost, i.e. baseline comp minus
    the SOLARUS_OVERLAYNOCOMP probe's comp (Task 1's HW A/B, Δcomp).
  - `--empty-cyc` / `--run-cyc` / `--px-cyc-per-col`: the tb_tilemap-calibrated
    fabric constants (Task 4), see below.
  - `--comp-ms`: the measured steady-state comp ms this attribution is
    checked against (the SUM check).

Produces ranked stdout lines `slice <name> <ms> <pct>` for
{overlay-palpha, tilemap-empty-walk, tilemap-resolve, tilemap-pixels, sprite}
plus a `SUM check` line comparing the modeled total to measured comp ms.

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

    px_cyc_per_col: the placeholder derivation below (8 cyc/col, i.e. 1
    cyc/px) is SUPERSEDED — it assumed the "issue-interval-1 compositor"
    design (comp_pipeline #36) throughput applied directly, but the single
    calibration data point does not actually support separating fixed
    per-run cost from per-pixel-column cost (n_runs=1, so this scenario
    can't fit two unknowns). The better-supported derivation divides the
    run's *entire* wait_cyc by its pixel-column count instead of assuming a
    fixed/variable split up front:

        px_cyc_per_col ≈ wait_cyc / run_width_px = 287 / 16 ≈ 18 cyc/col

    (run_width_px = 16, the S6 run's width; each "column" is one 8px-tall
    strip per the grid's 8px cell pitch, so a 16px-wide run is 2 columns —
    wait_cyc/run_width_px is cyc-per-px-wide-column, folding in whatever
    fixed dispatch/pipeline-drain cost the single data point can't isolate).
    Use ≈18, not 8, until a second scenario (longer run, varying width) lets
    fixed vs. per-column cost be fit independently — see the CAVEAT below.

    Original (superseded) note, kept for the arithmetic trail:
    pixel_cyc above = run's 16x8=128px * 1 cyc/px + ~6 cycle pipeline drain
    (PIPE_DEPTH~6, see fpga-colormod-pipeline-timing memory) = 134, which is
    where run_cyc_fixed's "156" and the old "8 cyc/col" came from.

CAVEAT: single-scenario, single-run calibration — order-of-magnitude only
(per the Task 4 brief's Step 5 allowance). A second scenario with a longer
empty span and/or multiple runs of varying width would let run_cyc_fixed and
px_cyc_per_col be fit independently instead of assuming/approximating either.
This attribution script's `SUM check` line (modeled total vs. measured comp)
is the on-HW-data validation of these constants: if that ratio comes back far
from ~1.0 when run against a real capture, treat the constants (or the model
shape itself) as unproven and reconcile before using the ranked slices to
pick a Phase-1 lever — see the runbook's Step 5 gate.
"""
import argparse
import sys

FABRIC_HZ = 98.4375e6


def parse_gridstats(lines):
    empty = runs = nonempty = 0
    for t in lines:
        if not t.startswith("GRIDSTATS"):
            continue
        kv = dict(tok.split("=", 1) for tok in t.split() if "=" in tok and "," not in tok.split("=")[0])
        empty += int(kv.get("empty", 0))
        runs += int(kv.get("runs", 0))
        nonempty += int(kv.get("nonempty", 0))
    return empty, runs, nonempty


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("gridlog", help="path to a SOLARUS_GRIDSTATS capture log")
    ap.add_argument("--comp-ms", type=float, required=True,
                    help="measured steady-state comp ms ([blitter hwperf] comp=)")
    ap.add_argument("--overlay-ms", type=float, required=True,
                    help="overlay channel's comp cost (Task 1 A/B Δcomp)")
    ap.add_argument("--sprite-ms", type=float, default=0.0,
                    help="sprite channel's comp cost, if separately measured")
    ap.add_argument("--empty-cyc", type=float, required=True,
                    help="calibrated cycles per empty grid cell walked")
    ap.add_argument("--run-cyc", type=float, required=True,
                    help="calibrated fixed cycles per coalesced run")
    ap.add_argument("--px-cyc-per-col", type=float, required=True,
                    help="calibrated cycles per 8px-tall pixel column")
    a = ap.parse_args(argv)

    with open(a.gridlog) as fh:
        empty, runs, nonempty = parse_gridstats(fh)

    def ms(cyc):
        return cyc / FABRIC_HZ * 1e3

    empty_ms = ms(empty * a.empty_cyc)
    resolve_ms = ms(runs * a.run_cyc)
    pixels_ms = ms(nonempty * 8 * a.px_cyc_per_col)  # each cell = 8 cols * 8 rows; px model per col

    slices = {
        "overlay-palpha": a.overlay_ms,
        "tilemap-empty-walk": empty_ms,
        "tilemap-resolve": resolve_ms,
        "tilemap-pixels": pixels_ms,
        "sprite": a.sprite_ms,
    }
    total = sum(slices.values())

    for name, v in sorted(slices.items(), key=lambda kv: -kv[1]):
        print("slice %-20s %6.2f ms  %5.1f%%" % (name, v, 100.0 * v / total if total else 0))

    print("SUM check: modeled=%.2f ms vs measured comp=%.2f ms (ratio %.2f)"
          % (total, a.comp_ms, total / a.comp_ms if a.comp_ms else 0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
