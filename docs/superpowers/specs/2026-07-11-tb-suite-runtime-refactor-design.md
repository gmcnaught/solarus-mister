# TB Suite Runtime Refactor — Design

**Date:** 2026-07-11
**Status:** Approved scope (Phases 0–2), pending spec review
**Owner:** solarus-mister FPGA sim suite (`fpga/sim/`)

## 1. Problem & goal

`fpga/sim/run_sims.sh` builds + runs ~42 Icarus Verilog testbenches sequentially.
Measured baseline (8-core local, iverilog 13.0): **818s wall (13.6 min)**, of which
**809.5s (99.1%) is `vvp` runtime** and only **7.1s (0.9%) is compilation**.

Goal: cut total suite wall-clock while **maintaining correctness**. Correctness bar
(user-approved): aggressive refactors allowed — including reducing sim geometry,
running scanout at full-rate `ce_pix`, and restructuring — provided each change is
**verified bit-exact PASS before/after** and the full HW-faithful configuration
remains runnable behind a `+define+*_FULL` nightly knob.

## 2. Where the time goes (all measured)

Six TBs account for **~660s of 818s (81%)**:

| TB | run s | gating? | root cause |
|---|---|---|---|
| tb_bgplane_equivalence | ~250–314 | gating | faithful mt48 × large SDRAM volume (96 tiles × 3 phases + 640×240 plane write + 320×240 readback). **Critical-path floor.** |
| tb_blitter_system_pipe | 120 (timeout+FAIL) | non-gating | stale readback: reads SDRAM FB the FB-in-BRAM compositor no longer writes → vacuous 0000; also can't finish in budget |
| tb_audio_burst_wedge | 81 | gating | frame-paced ÷8 `ce_pix` scanout (no mt48) |
| tb_bgplane_write_pipe | 77 | gating | faithful mt48 + full 240-row cell walk (19,200 qword writes) |
| tb_scanout_fbram | 74 | gating | frame-paced ÷8 `ce_pix` scanout, 3 full frames (no mt48) |
| tb_vram_contention | 60 | gating | faithful mt48 + full comp_pipeline+cache+reader every cycle (already reduced-geometry) |
| tb_tilelist_res / tb_tilelist | 35 / 21 | gating | composite pixel *volume* (not FSM-decode coverage) |
| tb_comp_replay | 30 (timeout) | non-gating | needs ~350s to PASS; caps every run; visual-dump tool |
| 6× blitter color-op TBs | ~3.3 ea | gating | redundant full-screen CLEAR over an already-pre-seeded FB |

**Two measured conclusions that shape the design:**
1. **Build caching is a non-lever** — total compile is 7.1s; a perfect cache saves ≤7s.
   iverilog `-y` is demand-loaded (each unit TB compiles only the 1–3 modules it
   instantiates). Do not build cache machinery.
2. **The faithful mt48 model is not the universal culprit** — 6 TBs use it and finish
   <5s. It only bites at large SDRAM *volume* (bgplane_equivalence) or stacked with a
   full datapath every cycle (vram_contention). The #3/#5 heavyweights (scanout_fbram,
   audio_burst_wedge) contain no mt48 at all — pure frame-pacing cost.

## 3. Approved scope

- **Phases 0, 1, 2** (below). Phase 3 (mt48→behavioral model swap, blitter-family
  TB merge) is **out of scope** — deferred, documented in §8.
- **CI strategy: single runner + tiering** (no matrix sharding). PR-tier CI leans on
  the geometry/rate cuts and the parallel job pool (GitHub `ubuntu-latest` has 2–4
  vCPUs, so `--jobs=nproc` helps opportunistically without sharding).

## 4. Correctness discipline (applies to every geometry/rate change in Phase 2)

For each TB touched:
1. Capture the current PASS output/checked-pixel count.
2. Make the reduction.
3. Re-run reduced; assert the TB still PASSes and still exercises the same property
   (same assertion, same golden diff — only the scene size / clock rate changes).
4. Add a `+define+<TB>_FULL` that restores the exact HW-faithful geometry/rate.
5. Wire the `_FULL` variants into the **nightly** tier so full coverage runs daily.

A reduction that cannot demonstrate (3) is rejected and the TB stays at full geometry.

## 5. Phase 0 — Free, zero-risk, zero coverage change (~163s)

**0a. Drop redundant CLEAR in 6 blitter color-op TBs** (~13s).
`tb_blitter_{add,blend,cafill,colormod,mul,palpha}_pipe.sv` each pre-seed the entire
`comp_fbram` to background in their init block, then *also* submit a full-screen CLEAR
to the same BG — repainting BG over BG. Change the control-block flag
`mem[32'h200004] = 64'd1` → `64'd0`. BlitterPipe proved all 6 stay bit-exact PASS
(run 3.3s → ~1.2s each). No `_FULL` needed — the CLEAR was pure redundancy, not coverage.

**0b. Tier out the 2 non-gating always-timeout TBs** (~150s).
`tb_comp_replay` (needs ~350s) and `tb_blitter_system_pipe` (>120s, and currently FAILs)
are **non-gating and can never pass in the PR budget** — they burn ~150s/run producing
no verdict and add per-PR noise. Move both to the nightly/`workflow_dispatch` tier.
Their PR-tier coverage is already provided by tb_comp_pipeline + the 7 tb_blitter_*_pipe
TBs (pipe cutover) and tb_vram_demux (plumbing), per the run_sims.sh header.

## 6. Phase 1 — Parallel runner architecture

Rewrite `run_sims.sh` to a tiered parallel job pool. `N=1` reproduces today's exact
serial order (safety hatch).

```
run_sims.sh [--tier=pr|nightly|all] [--jobs=N] [TB ...]
  TIERS (a data table beside the existing SKIP / NONGATING lists):
    pr      = all gating TBs at reduced geometry;
              EXCLUDE tb_comp_replay, tb_blitter_system_pipe
    nightly = full suite + all +*_FULL defines + the 2 excluded non-gating TBs
    all     = everything, no exclusions (developer convenience)
  JOB POOL (default N = nproc-2; N=1 => today's serial order):
    - enqueue (compile -> run) per TB; iverilog already uses per-pid temp dirs,
      so parallel compiles into .simbuild do not collide (distinct .vvp names)
    - each job writes results/<top>.result: "top,gating,verdict,secs"
  REDUCE:
    - read results/*.result -> deterministic-sorted table + counts
    - exit 1 iff any GATING verdict != PASS   (semantics unchanged from today)
  BUILD CACHE: omitted (measured 7.1s total — not worth the machinery)
```

**Exit-code / verdict preservation (verified safe by RunnerInfra):** each TB already
writes its own `.vvp` / `.build.log` / `.run.log`; the verdict derives from that TB's
own log, not shared stdout. The only shared mutable state today is the pass/fail
counters and printed table order — both handled by the per-job result files + reducer.
Live interleaved stdout affects only the human-readable table (buffer per job, print in
deterministic order at the end).

**Projected:** local `--jobs=8` → **818s → ~250s** (floor = slowest single TB,
tb_bgplane_equivalence, until Phase 2 shrinks it). CI single runner benefits
opportunistically from `--jobs=nproc`.

## 7. Phase 2 — Geometry / rate reductions (each behind `_FULL` nightly, each bit-exact)

Ranked by savings:

**2a. `tb_bgplane_equivalence` geometry reduction** (~230s — biggest single win, MED risk).
314s is SDRAM-access volume × mt48 stalls. Cut 96 tiles (16×6) → ~12 and shrink the
64×64 atlas / narrow the camera window, **while KEEPING**: the 2-cell 640-wide map, a
camera window straddling x=320, non-degenerate cross-cell stride, and varied per-tile
sx/sy. The qword-exact OLD-vs-COPY assertion is unchanged. Guard full scene behind
`+define+BGPLANE_EQUIVALENCE_FULL`. Risk: a careless cut goes degenerate (loses the
shifted/dropped/misaligned-entry → pixel-mismatch property) — reduce carefully and
diff against the full run.

**2b. Full-rate `ce_pix` on `tb_scanout_fbram` + `tb_audio_burst_wedge`** (~155s, near-zero risk).
Both hardcode `CE_DIV=8` (HW ÷8 pixel clock). `tb_vram_contention` and the retired
`tb_scan_qworddup` already prove `ce_pix <= ~reset` (full-rate) shrinks frame-paced sync
~8× with identical addresses/pixel mapping. Also drop scanout's scan loop 3→1 frame and
lower its `px_checked>200000` threshold. Restore HW behavior behind
`+define+SCANOUT_FBRAM_FULL` / `+define+AUDIO_WEDGE_FULL`. scanout 74→~12s, audio 81→~10s.

**2c. `tb_bgplane_write_pipe` rows 240 → ~12** (~70s, LOW risk).
The streamer property (strided per-row advance + gap-skip) needs only a few rows that
straddle both stride phases (the row<120 quadrant split) and keep `STRIDE_QW > CELL_ROW_QW`.
NQW 19,200 → ~960. Guard full walk behind `+define+BGPLANE_WRITE_FULL`.

**2d. `tb_tilelist` + `tb_tilelist_res` compositing volume** (~40s, LOW–MED risk).
Cost scales with pixels composited, not FSM-decode coverage. Reduce the big-N tile w/h
(N=20/24/64 cases don't need 8–16 px tiles) and/or compare only the touched bbox.
**Keep every case shape** (clip / cull / neg-x / right-edge / offscreen / non-8-aligned
eoff / bias / whole-map-cull / pan+advance). Bit-exact vs N-BLIT expansion preserved.
35→~22s, 21→~14s. Guard full sizes behind `+define+TILELIST_FULL`.

**2e. `tb_fbram_to_sdram` + `_backpressure` rows 240 → ~24** (~2s, LOW risk).
CELL_ROWS 240→24 (keep CELL_ROW_QW=80, STRIDE=160). NQW 19,200→1,920. 24 rows still
crosses many stride wraps and dozens of freeze/resume transitions. Guard behind
`+define+FBRAM_SDRAM_FULL`.

## 8. Out of scope (Phase 3 — deferred, not in this effort)

Documented so the deferral is deliberate:
- **mt48 → shared fast behavioral model.** Doable in principle (no TB verifies SDRAM
  electrical timing) but the heavy TBs drive `jtframe_burst_sdram`, not the `rtl/sdram.sv`
  the existing fast `sdram_chip_model.sv` was tuned to; a mis-timed model silently
  produces false greens exactly where bgplane's bit-exact assertion lives. Only safe as a
  nightly-cross-checked effort (both models must agree for a release).
- **Merge blitter color-op family → ~2 parametrized TBs + shared `blitter_pipe_harness.vh`.**
  Attacks the ~1.2s × N vvp process-startup floor; medium effort, loses per-op isolation.
- **Re-point OR retire `tb_blitter_system_pipe`.** Would fix the currently-failing test
  (stale readback → read `comp_fbram` instead of SDRAM FB) as a bonus. Deferred with the
  rest of Phase 3; in the meantime Phase 0b removes it from the PR tier so it stops
  gating-noising, and it continues to run (non-gating) nightly.

## 9. Success criteria

- **PR-tier CI: 818s → ~120–180s** (single runner + tiering + geometry cuts).
- **Local `--jobs=8`: ~70–120s.**
- **Nightly tier** runs the full suite at full geometry (`+*_FULL`, plus comp_replay &
  system_pipe) as the correctness safety net.
- **Zero loss of verified properties**: every reduced TB PASSes bit-exact and its full
  configuration runs nightly; PR-tier gating semantics and exit codes unchanged.
- Bonus: PR runs stop carrying the `tb_comp_replay` timeout and `tb_blitter_system_pipe`
  FAIL as standing noise.
