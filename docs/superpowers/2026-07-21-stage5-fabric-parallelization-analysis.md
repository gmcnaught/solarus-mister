# Stage 5 — is the fabric compositor parallelizable? (measured 2026-07-21)

**Question:** can we speed the FPGA compositor via parallelization? **Answer: not by
parallel COMPUTE — the ALU is ~80% idle. The compositor is FETCH-STALL-bound; the lever
is a larger on-chip source cache (memory-parallelism).**

## Method (RBF-free, ~6s/run)

`fpga/sim/tb_profile.sv` — cycle-budget profiler on the REAL datapath
(blitter_top→comp_pipeline→vram_demux) with the FAST latency-modeled P_SRC/P_DST ports
(NOT the slow mt48 model). Its cyc/px is a floor; the phase RATIO is model-independent.
Swept `+define+PROF_SRC_LAT` to model cache-miss fetch latency.

## Data — SRC_LAT sweep (COPY small 16x16 = the interior/parallax tile character)

| SRC_LAT | cyc/px | comp% (active ALU) | prefetch-wait (stall) |
|---|---|---|---|
| 4 (sim floor) | 2.23 | 75.5% | ~11% |
| 8  | 3.12 | 54.0% | ~33% |
| 16 | 5.12 | 32.9% | ~55% |
| 32 | **9.12** | **18.5%** | **~69%** |

- FILL (no source fetch) stays flat at **1.05 cyc/px** at every latency — latency-insensitive.
- Device measured **~10 cyc/px** on the house (comp=22ms / ~200k px). That matches the
  sim at SRC_LAT≈32 → the device's effective source latency is ~32 cyc/beat.
- As fetch latency rises, `comp%` (ALU actually compositing) COLLAPSES 75→18%; the growth
  is all prefetch-WAIT (stall). The prefetch can't hide fetch for small spans (a 16px span =
  ~16 cyc of compute to overlap a multi-tens-of-cycle fetch).

## Root cause (confirmed in RTL)

`fpga/rtl/sdram_fb_cache.sv`: `RO_BLOCKS = 2, RO_BLKSIZE = 256` → the P_SRC source cache is
**512 bytes ≈ ONE 16x16 tile**. The map working set is ~150 distinct patterns (`[blitter
resident] patterns=153`) ≈ **78 KB** — 150× the cache. Every distinct tile MISSES → a 256B
block-fill from the single-beat SDRAM controller (~32 cyc). Wide same-source blits hit within
the blit (lower cyc/px); FILL has no source (1.05). Small distinct tiles miss constantly.

## Answer to the parallelization question

- **Parallel compute pipelines: NO.** The ALU is already ~80% idle waiting on fetch; more
  idle ALUs don't help, and they'd contend on the one SDRAM port + cost area on a Cyclone V
  SE already near timing/BRAM ceiling.
- **The lever is the SOURCE FETCH (memory-parallelism):** enlarge the on-chip P_SRC cache to
  hold the map's ~150-pattern working set so per-tile misses become 1-cyc multi-ported BRAM
  hits. cyc/px would fall from ~9-10 toward the ~1-2 hit/FILL floor → **~4-5x fabric speedup
  on fabric-bound scenes (house, parallax), standing AND scrolling** (fetch cost is
  motion-independent — unlike the layer-cache idea).
- **Smallest concrete lever:** `RO_BLOCKS`/`RO_BLKSIZE` are PARAMETERS. Bumping them (if BRAM
  allows) is a parameterized RTL change, sim-measurable (rerun this profiler) + CI-buildable.

## Caveat to size next

BRAM budget: comp_fbram (FB-in-BRAM) already consumes ~150-300 KB of the 5CSEBA6's ~490 KB
BRAM. A 78 KB source cache may not fit alongside a double-buffered 320x240 FB — the
enlargement may need to be partial (hot-N patterns / LRU) or trade against FB buffering.
Size it in sim (sweep RO_BLOCKS vs cyc/px) + a Quartus fit/timing check before committing.
