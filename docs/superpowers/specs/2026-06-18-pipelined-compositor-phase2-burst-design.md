# Pipelined Compositor — Phase 2 (Burst Performance Cycle) Design

> **Status:** approved design, pre-implementation.
> **Branch / worktree:** `spec/pipelined-compositor` in `.claude/worktrees/pipelined-compositor/`
> (main checkout stays on `feature-sdram-64mb-geometry`, undisturbed).
> **Predecessor:** Phase 1 (`docs/superpowers/specs/2026-06-17-pipelined-compositor-design.md`, Spec A)
> and the Phase 2 handoff (`docs/superpowers/2026-06-18-pipelined-compositor-phase2-handoff.md`).

## 0. TL;DR

Phase 1 delivered an issue-interval-1 (1 px/clock) compositor, bit-exact to the legacy blitter,
selectable behind `C_PIPE`. Its compute path is already at the throughput ceiling, but it feeds
and drains DDR in **single beats**, so end-to-end it is **memory-bound**. This cycle makes the
throughput real by adding a **burst memory engine** on the DDR `mem_*` path and closing **Quartus
timing**. It deliberately does **not** touch SDRAM-source support, the `vram_demux` partial-byte-
enable fix, or live hardware — those belong to a separate correctness/HW cycle.

The design follows the throughput doctrine of Beasley et al. (TRETS 2020, the project's source
paper): **(1)** locate the bottleneck by dataflow analysis *before* optimizing (§3.6); **(2)** size
each stage to *just meet* the bottleneck, never to exceed it (§5); **(3)** protect `fmax`, since
once every stage is issue-interval-1 the system limiter is the minimum `fmax` of the components (§5).

## 1. Goals & success bar

### In scope (this cycle)

1. **Profile-first measurement.** Extend `tb_profile.sv` to measure the `C_PIPE=1` pipe over DDR
   sources and report the compute-cycle vs memory-wait split. Run it *before* finalizing the burst
   design to establish the measured bottleneck baseline (Beasley §3.6 dataflow analysis), and again
   after to prove the win.
2. **`comp_burst`** — a new, dedicated, shallow burst master.
3. **`ddr_blitter_arb` burst-grant extension** — hold the blitter grant for a bounded burst.
4. **Integration** — route `comp_pipeline`'s three single-beat `mem_*` access sites
   (band LOAD, band FLUSH, source-row fetch) through `comp_burst`.
5. **Re-profile** post-burst to demonstrate the cyc/px improvement (gate **G1**).
6. **Quartus 17.0.x synthesis + STA** — worst-case setup slack ≥ 0 at the f2h clock (gate **G5**).

### Success bar (definition of done for this cycle)

- The Phase-1 equivalence suite stays **bit-exact** green (no functional regression).
- `tb_comp_burst` and the reader-never-starve contention test pass.
- `tb_profile` at `C_PIPE=1` shows a **measured cyc/px improvement** vs the single-beat baseline,
  with compute identified as the now-binding stage (or the residual memory cost quantified).
- Quartus STA reports **worst-case setup slack ≥ 0** at the f2h clock (G5).
- **No live HW run** is required to close this cycle.

### Out of scope (deferred to the next, correctness/HW cycle)

- SDRAM-source (`C_SRCSEL=1`) routing into `comp_pipeline`.
- The `vram_demux` partial-byte-enable SDRAM-dest write fix.
- Re-enabling `tb_blitter_system_pipe` PHASE2A/2B/3/4 (`-DP2_SDRAM_SYS`).
- Live DE10-Nano hardware validation (gate **G2**) and making `C_PIPE=1` the default.

The burst work lives entirely on the DDR `mem_*` path, which is why these stay cleanly separated:
nothing here requires SDRAM-source or the SDRAM-dest demux path.

## 2. Why bursts now (and not 4-wide compute)

The `origin/fabric-4wide-burst` branch profiled the *legacy FSM* blitter as ~60% compute /
25% DDR-wait / 16% SDRAM-read — i.e. **compute-bound** — and concluded a 4-wide blend was the FSM's
fps lever. That result **does not transfer** to the Phase-1 pipe, which is already issue-interval-1
(1 px/clock) by construction. For the II=1 pipe the binding stage flips back to the memory feed,
which the single-beat `mem_*` path cannot saturate. Hence the burst engine, not wider compute, is
this cycle's lever. Task 1 (profiling) **verifies** this on the II=1 pipe rather than assuming it.

Prior burst art is consulted for lessons only, not lifted:
- `origin/burst-dma` — failed STA at **−0.385 ns**; a cautionary tale that the burst path must stay
  shallow to protect `fmax`.
- `origin/sdram-burst` — a burst controller HW-validated at 21.0 fps, but on the **SDRAM** source-
  atlas path, not the DDR f2h path; it belongs to the deferred SDRAM-source work.

## 3. Architecture & components

```
            transfer request (base, len, dir)        blt_* + blt_burstcnt
 comp_pipeline ───────────────────────────▶ comp_burst ───────────────────▶ ddr_blitter_arb ──▶ f2h DDR
   (band-chunk        ◀─────────────────────  (shallow      ◀───────────────  (reader = default
    orchestrator)       streamed beats / done   DMA master)    grant + beats     owner; lends a
                                                                                 bounded burst)
```

### 3.1 `comp_burst.sv` (new)

A pure memory-sequencing helper — a small DMA-style master. It does **not** know about
compositing; it moves contiguous qword runs to/from DDR on behalf of `comp_pipeline`.

- **Request interface (from `comp_pipeline`):** a transfer is `{base_addr (qword-aligned byte
  address), len (qwords), dir (read/write)}` plus a start pulse; `comp_burst` raises `busy` until
  the transfer completes and pulses `done`.
- **Data streaming:** on reads it streams returned qwords (with a valid strobe) to the band /
  linebuf; on writes it accepts a qword stream (with byte-enables for the flush path) and drives
  the beats out.
- **Arbiter interface (to `ddr_blitter_arb`):** drives `blt_addr`, `blt_rd`/`blt_we`,
  `blt_burstcnt`, `blt_din`, `blt_be`, consumes `blt_busy`/`blt_grant`.
- **Bounded bursts:** a transfer longer than the cap `N` is split into back-to-back bursts of ≤ `N`
  beats, re-arbitrating between sub-bursts (see §3.3).
- **Shallowness is a requirement, not a nicety:** control logic is kept to a minimal FSM so it does
  not become the critical path. `fmax` protection is the explicit lesson from `burst-dma`.

### 3.2 `ddr_blitter_arb.sv` (extend)

Today the blitter port is single-beat; the reader port already issues f2h **burst reads** and the
arbiter already tracks the reader's outstanding beats to avoid the black-screen failure (lending the
bus mid-fetch). The extension mirrors that proven pattern for the blitter:

- Add `blt_burstcnt` to the blitter master port.
- Hold the blitter grant for the whole bounded burst's beats (read beats return uninterrupted; write
  beats stream out uninterrupted), exactly as the reader read-beat-hold does.
- The reader remains the **default owner**: the blitter only acquires the bus in a genuine reader-
  idle gap, and the bounded burst length guarantees the reader's worst-case wait stays within
  tolerance. The reader-never-starve invariant is asserted in simulation (§5).

### 3.3 The bounded-burst rule (Beasley §5 "don't exceed the bottleneck")

The compute path consumes/produces **1 px/clock**. The burst engine is sized so that memory
throughput just **reaches** that rate — not the maximum burst the bus allows. A maximal full-row
80-beat burst would monopolize the f2h port for ~80 cycles and risk starving the reader; per §5,
throughput beyond the bottleneck is wasted anyway. Therefore:

- Burst length is capped at a **tunable `N` beats**.
- While a blitter burst holds the bus, `ddram_busy` makes the reader wait; bounding `N` keeps that
  wait short. The arbiter re-arbitrates between sub-bursts so the reader reclaims the bus promptly.
- **`N` is chosen by contention simulation, not guessed** — swept to the smallest value that lifts
  measured memory throughput to ≈ 1 px/clock while the reader loses no beats.

### 3.4 `comp_pipeline.sv` (minimal change)

`comp_pipeline` keeps ownership of the per-blit, band-chunked RMW loop and all Phase-1 compositing
logic (untouched, to preserve bit-exactness). Only its three `mem_*` access sites change from
single-beat transactions to `comp_burst` transfer requests:

1. **Band LOAD** (P_LOAD): read the chunk's FB rows DDR → `comp_dest_band`.
2. **Band FLUSH** (P_FLUSH/P_WB): write dirty qword runs `comp_dest_band` → DDR.
3. **Source-row fetch**: read the row's source qword run DDR → `comp_src_linebuf`.

### 3.5 `tb_profile.sv` (extend)

Add a `C_PIPE=1` measurement mode: drive a large steady-state blit, probe `comp_pipeline` compute
states to separate compute cycles from memory-wait cycles, and report cyc/px. Used pre-burst
(baseline) and post-burst (win).

## 4. Data flow

The three transfers and their burst shapes:

| Transfer | Direction | Contiguity | Typical size |
|---|---|---|---|
| Band LOAD | DDR → `comp_dest_band` | contiguous rows | up to 16 rows × 80 qwords |
| Band FLUSH | `comp_dest_band` → DDR | full-width row = one 80-qword run; coalesced partial = per-run | up to 16 × 80 qwords |
| Source-row fetch | DDR → `comp_src_linebuf` | contiguous qword run covering the row span | per row |

All addresses are qword-aligned by construction (band geometry and the existing coalescing logic
guarantee this). The FLUSH path carries byte-enables; a full-width overworld layer row is the common
case and flushes as a single contiguous run. Partial/coalesced rows flush as one bounded burst per
contiguous dirty run.

Painter order across blits is preserved exactly as in Phase 1 — via the DDR round-trip (LOAD →
COMPOSITE → FLUSH per chunk). Bursting changes only *how* the beats are issued, not the order.

## 5. Verification

- **`tb_comp_burst.sv` (new):** unit-test the burst master against a behavioral DDR + arbiter model —
  aligned bursts, bounded-length splitting, read-beat capture, write-beat streaming with byte-enables,
  `blt_busy`/back-pressure handling, and grant-hold across a burst.
- **Reader-never-starve (extend `tb_vram_contention` / `tb_arb_reader_burst`):** assert the reader
  loses **no** beats while the blitter bursts, and that the blitter's contiguous bus hold ≤ `N`. This
  is the gate for the §3.3 bound and the chosen `N`.
- **No functional regression (existing suite):** `tb_blitter_{copy,blend,coalesce,palpha}_pipe` must
  remain **bit-exact** vs golden, `tb_blitter_system_pipe` PHASE1 must pass, and the legacy
  `C_PIPE=0` suite (`tb_blitter_*`, `tb_blitter_system`) must show no regression, after `comp_burst`
  is inserted.
- **Profiling (G1):** `tb_profile` at `C_PIPE=1` shows a measured cyc/px improvement vs the single-
  beat baseline and identifies compute as the now-binding stage (or quantifies the residual memory
  cost).
- **Synthesis & STA (G5):** add `comp_*` and `comp_burst` to `fpga/files.qip`; build under Quartus
  Prime 17.0.x; report **worst-case setup slack ≥ 0** at the f2h clock. If timing is tight, the
  fallback levers (in order): pipeline only the mixer, then shrink `COMP_BAND_H` (BRAM relief).
  Confirm Quartus picks up the authoritative `comp_defs.vh` values for all `comp_*` files (the
  cross-cutting include-path risk flagged in the Phase-1 ledger).

The runner (`fpga/sim/run_sims.sh`, Icarus `-y` library mode) gates on these. Toolchain gotchas
carried from Phase 1: `-y` single-compilation-unit include-guard interactions, Icarus-13 unsized-
integer-in-concatenation casts, and `initial`-block power-on state (no reset port) for the `comp_*`
family.

## 6. Hard constraints (carried from Spec A — unchanged)

- **Bit-exact to the golden** (`patches/mister/blitter/blitter_ref.h`/`.c`); the host/fabric contract
  (`blt_cmd_t`, opcodes, blend modes, 32-byte ring entry, submit/done handshake) is **frozen**.
- The blitter is a **guest on the f2h DDR port**: the video reader keeps default ownership and **must
  never starve**; the blitter fills genuine idle gaps with bounded bursts. No per-pixel DDR beats.
- New RTL: `module == file name`, in `fpga/rtl/`; headers `// <file> — <purpose>` +
  `// Copyright (C) 2026 — GPL-3.0`. Commit only when asked; end commit bodies with
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- The engine-side overdraw cache is orthogonal and out of scope.

## 7. Carried Phase-1 review findings to fold in opportunistically

- Add a range assert in `comp_pipeline` that a chunk's spans are consecutive rows
  (`cw_row`/`rd_row` are 4-bit and assume `chunk_base_y+i`) — harden the linchpin while editing it.
- Fix stale header comments on the `*_pipe` testbenches.
- Once Quartus include paths are confirmed (G5), consider dropping `comp_dest_band`'s `\`ifndef`
  fallback (or make it `\`error`) so a missing `comp_defs.vh` can't silently diverge.
- `comp_mixer` div255 inline-vs-macro DRY — consider an explicit filelist or a `comp_div255` function.

Full list: `PCOMP-T1..T5` in `.git/sdd/progress.md`.

## 8. Open items resolved during implementation (not blocking the spec)

- **Exact `N`:** determined by the §5 contention sweep.
- **FLUSH partial-run handling:** the existing coalescing already groups dirty qwords; a burst per
  contiguous run is the baseline; whether to merge near-adjacent runs is a sim-driven tuning decision.
