# SRCFILL throughput → 60fps — design

**Date:** 2026-06-26
**Branch (cleanup base):** `perf/fb-bram-rebaseline-cleanup`
**Goal:** Push the FB-in-BRAM compositor toward 60fps on heavy (source-blit-bound)
scenes by attacking the SRCFILL bottleneck from two complementary angles.

## Background / why

The FB-in-BRAM re-baseline (`tb_profile`, commit 16ae0bb) shows the compositor is now
**SRCFILL-bound**: WB and LOAD are 0% (dest + scanout are on-chip `comp_fbram`), and the
serial SDRAM **P_SRC atlas fetch** is the dominant bucket:

| blit | cyc/px | SRCFILL | comp |
|---|---|---|---|
| COPY/ALPHA/PALPHA wide 320×48 | 2.55 | 58.9% | 40.5% |
| COPY sprite 64×64 | 2.76 | 55.0% | 42.5% |
| FILL wide (no source) | 1.05 | 0% | 99.0% |

`tb_profile` is an **optimistic floor**: P_SRC is latency-modeled as fixed ~4-cycle
*hits* with no misses. Two distinct real-HW costs hide inside "SRCFILL", needing
different fixes — so the design addresses both.

Per-span flow today (`comp_pipeline`): the single FSM does `SRCFILL(span N)` →
`composite(span N)` → `SRCFILL(span N+1)` … strictly sequentially. `composite` serves
pixels from `comp_src_linebuf` (on-chip) and **never touches P_SRC**, so the fetch port
is idle during composite.

## Lever B — warm the P_SRC atlas cache

**Problem.** `sdram_fb_cache` fires the vsync flush (`flush0`, `INVAL_MASK0 = ch0|ch5`)
every frame, which **invalidates ch5 (P_SRC)** — dumping the atlas cache. Atlas
surfaces "upload once" (renderer `mister_blitter_renderer.cpp:526`) and persist across
frames, so every frame's first atlas reads become cold block-fill misses from SDRAM.

**Change.** Remove ch5 from `INVAL_MASK0` (vsync mask) in `sdram_fb_cache.sv`. Keep
`INVAL_MASK1` (the `stage_barrier` mask) as the **sole** ch5 invalidation.

**Why safe.** P_SRC caches the *atlas*, not the framebuffer. Every atlas mutation is a
STAGE write (ch1) followed by `stage_barrier` → `flush1` → invalidate ch5 — covering all
correctness needs, including SDRAM address reuse (each reuse re-STAGEs). The vsync ch5
invalidation is redundant; it only forces needless cold re-fetches of unchanged data.

**Effect.** Invisible in `tb_profile` (hit-only model); on HW, converts per-frame
first-touch atlas misses into warm hits. ~1-line, low-risk, potentially large HW payoff.

**Note.** The vsync `flush0` now commits the dead ch0 (P_DST) and `flush2` invalidates
the dead ch4 (P_SCAN) — both no-ops post-FB-in-BRAM. Fully retiring those is part of the
separately-tracked, higher-risk ch0/ch4 channel-deletion cleanup; lever B touches only
the ch5 bit of `INVAL_MASK0` and does not depend on that cleanup.

## Lever A — double-buffered linebuf fetch/composite overlap

**Idea.** While compositing span N from one linebuf bank, prefetch span N+1's source row
into the *other* bank over the idle P_SRC port. Per-span time drops from `fill + comp`
to `max(fill, comp)` — fill≈comp≈len cycles, so ≈**40% cut on multi-row source blits**.
FILL and single-span blits are unaffected (no regression).

**Changes.**
- `comp_src_linebuf.sv`: 2 banks (A/B), `+1 M10K` (~2 KiB). A bank-select bit on the
  fill port and the serve port. Serve latency stays 1 cycle.
- `comp_pipeline.sv`: split the monolithic fill-then-composite span loop into two
  concurrently-running activities:
  - **fill-issue** — drives `p0_rd`/captures `p0_ok` into bank `!b` for span N+1;
  - **composite** — the existing II=1 serve→mixer→`fb_wr` path, reading bank `b` for
    span N.
  Advance to the next span only when *both* complete. The mixer datapath is **untouched**
  (bit-exact). Edge cases: prologue fill of span 0; no prefetch on the last span;
  single-span blits degrade to current sequential behavior.

**Rejected alternatives.**
- *Intra-span pipelining* (fill-cursor ahead of serve-cursor, single bank): helps only
  very wide single spans; Solarus spans are per-row (≤320px) and the cost is the *many
  rows*, so it barely helps multi-span sprites.
- *Bigger single buffer*: does not decouple fill from serve — same sequential bottleneck.

## Risks

- **Timing (primary).** Core is on pinned SEED 7 with thin slack. The 2nd bank + serve
  bank-mux + concurrent control may pressure `clk_sys`. Mitigation: datapath unchanged
  (+1 M10K + control only); if STA goes negative, register the bank-select (same
  technique as the colormod s3 split). **STA is the real gate.**
- **Concurrency correctness.** The fill-issue path (using P_SRC) running alongside the
  composite serve must preserve II=1 and bit-exactness. Guarded by sim (below).

## Verification

- **Bit-exact:** `tb_comp_pipeline` + the seven `tb_blitter_*_pipe` equivalence TBs must
  remain bit-exact (gating). The mixer datapath is unchanged, so this should hold by
  construction.
- **Throughput:** `tb_profile` must show the multi-span / wide-blit cyc/px drop toward
  `max(fill, comp)`; FILL unchanged.
- **Overlap proof:** new TB exercising a multi-row source blit, asserting `p0_rd` for
  span N+1 is issued while span N is still compositing (fill/comp temporal overlap).
- **HW (owed, user-relaunch):** read `0x3B00002C` (fabric cyc) / `0x3B000034` (pipe cyc)
  and fps before/after on a heavy overworld; confirm lever B warms the cache (lower
  fabric cyc/frame) and lever A reduces compositor cyc/frame. ssh-launch dies on
  disconnect — user must relaunch via OSD/Scripts.

## Sequencing

1. **B** first — trivial `INVAL_MASK0` change; run gating suite (must stay green).
2. **A** — `comp_src_linebuf` 2-bank, then `comp_pipeline` span-loop split; verify
   bit-exact + `tb_profile` improvement + new overlap TB at each step.
3. RBF build + **STA gate** (clk_sys slack ≥ 0 on the pinned seed) before HW.
4. HW validation (user-relaunch): perf counters + fps on a heavy scene.

## Out of scope

- ch0/ch4 SDRAM cache-channel deletion + `vram_demux` dst routing (separate higher-risk
  cleanup; lever B does not need it).
- `SOLARUS_SW` engine-path removal (separate cleanup).
- Engine/A9-side changes — both levers are fabric-only.
