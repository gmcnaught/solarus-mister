# Stage 5 — fabric source-cache enlargement (Phase 1) — design

**Date:** 2026-07-22
**Status:** design approved (brainstorm), pending spec review → implementation plan
**Origin:** the Stage 5 fabric-parallelization analysis
(`docs/superpowers/2026-07-21-stage5-fabric-parallelization-analysis.md`) proved the compositor
is **fetch-stall-bound, not compute-bound**, and the on-chip P_SRC atlas cache is 512 B vs a
~78 KB working set. This is Phase 1 of the fix: enlarge the source cache **within current free
BRAM, no framebuffer relocation**. Phase 2 (FB→DDR3 to free BRAM for a full-working-set cache) is
a documented follow-on (§8), designed only if Phase 1's measured hit-rate curve shows a feasible
cache size is insufficient.

## 1. Goal

Cut the atlas source-fetch stalls that dominate fabric-bound scenes (interiors, parallax) by
enlarging the on-chip P_SRC cache, sized from a **measured hit-rate curve**, within the ~92 M10K
of currently-free BRAM (no FB move, no #49 revert). Success = a measured fabric_hw/`comp` drop and
fps/period improvement on the fabric-bound scenes (map 1 house, map 119 parallax) with no
correctness or timing regression.

**Non-goals.** No framebuffer relocation (Phase 2). No new cache architecture (a dedicated
pattern-pixel BRAM / set-associative redesign is the Phase-2/escape path if a feasible
fully-associative size can't capture enough of the win). No scanout change. No ascal.

## 2. Why (measured, verified)

- `tb_profile` SRC_LAT sweep: cyc/px 2.23→9.12 as fetch latency 4→32 (device ≈ 9-10 cyc/px on the
  house); `comp%` (active ALU) collapses 75→18% → the pipeline **stalls on source fetch**. FILL
  (no fetch) is latency-flat at 1.05.
- `sdram_fb_cache.sv`: P_SRC = `RO_BLOCKS=2 × RO_BLKSIZE=256` = **512 B ≈ one tile**; working set
  `[blitter resident] patterns=153` ≈ **78 KB** → every distinct tile misses (30+ cyc block-fill,
  per `tb_sdram_fb_cache.sv`'s own "warm hit 0 cyc / cold miss 30+ cyc" guard).
- **A warm hit ≈ 0-cyc source latency** → cyc/px collapses toward the ~2 floor. Full caching ≈ 4×
  on fabric-bound scenes; even 80% hit-rate ≈ 2.6×.

## 3. Two load-bearing structural facts (constrain the approach)

1. **`jtframe_cache` is fully-associative** (per-way tag RAM + LRU victim). Good: **no conflict
   misses** — capacity alone determines the hit-rate, so an LRU cache of B blocks holds the B most
   recently-used blocks. Bad: the parallel tag-compare scales with block count, so **`RO_BLOCKS`
   cannot grow to hundreds** (timing/logic blow-up). Phase 1 lives in the feasible-associativity
   range (tens of blocks); the full ~306-block working set needs a different structure (§8).
2. **`RO_BLOCKS`/`RO_BLKSIZE` are shared by P_SCAN and P_SRC.** P_SCAN (scanout line reader) is
   sequential and needs no large cache. Phase 1 **decouples P_SRC's block count** from P_SCAN (a
   dedicated `SRC_BLOCKS` param) so only the atlas cache grows — P_SCAN stays at 2.

## 4. Architecture — three gated tasks

### Task A — Measure the hit-rate curve (offline, RBF-free)

The win at a given cache size = hit-rate at that size, which depends on the atlas access pattern
(tile-reuse locality). Measure it:
- **Extract a real fetch trace:** a diag-gated engine log of the per-emit atlas source offset
  (`c_src_off`-equivalent, i.e. each tile's pattern → its atlas byte offset → the 256 B block id)
  for a captured frame on map 1 and map 119 (reuse the Stage 5 capture harness).
- **Offline LRU model (Python):** replay the block-id stream through a fully-associative LRU cache
  of B blocks for B ∈ {2, 8, 16, 32, 48, 64, 96, 128, full}; report hit-rate(B).
- **Convert to cyc/px** via the measured transfer function (`cyc/px ≈ 2.2 + miss_rate × ~7`).
- **Output:** the knee — the smallest B that captures ≥ ~80–90% of the full-cache win. This sizes
  `SRC_BLOCKS` from data and tells us whether a feasible fully-associative size suffices (Phase 1
  lands it) or not (escalate to §8 Phase 2).

### Task B — Enlarge the P_SRC cache

- In `sdram_fb_cache.sv`: add a `SRC_BLOCKS` parameter (default = current `RO_BLOCKS`=2 for a true
  baseline), route it to the P_SRC (ch5) `jtframe_cache` `BLOCKS` param, leaving P_SCAN on
  `RO_BLOCKS`. Optionally widen `RO_BLKSIZE`/`SRC_BLKSIZE` if the trace shows within-block spatial
  reuse (a bigger block amortizes the fill over more reused pixels).
- Set `SRC_BLOCKS` to Task A's knee value.
- **Coherency is unchanged:** the existing `stage_barrier` (ch1→ch5 flush+invalidate on atlas
  stage) and per-vsync ch5 invalidation already keep the source cache correct across atlas
  updates and frames; a bigger cache reuses the same barriers. Confirm the invalidation still
  covers the enlarged block set.

### Task C — Validate

- **Sim:** the offline model + transfer function predict the cyc/px; a fast `tb_profile`-style run
  at the modeled effective latency corroborates. (The real cache in a full mt48 sim is too slow —
  out of scope.)
- **CI fit/timing (the real gate for the associativity cost):** build the RBF via `build-rbf`; the
  enlarged fully-associative P_SRC must (a) fit within 553 M10K at safe margin, (b) close STA
  positive. If it won't close, reduce `SRC_BLOCKS` (the knee is a target, timing is the ceiling).
- **HW A/B (two RBFs):** this is an RBF-level change (not env-gatable), so A/B is baseline RBF vs
  enlarged-cache RBF on the **same** captured spots. Deploy each, capture map 1 + map 119 (Stage 5
  harness). Assert: fabric_hw/`comp` drop, fps/period improve, and a **regression sweep** (town,
  overworld, a transition) shows no correctness change and no fps regression on non-fabric-bound
  scenes. Operator visual gate (never self-declared).

## 5. Component boundaries

| Unit | Responsibility | Interface | Depends on |
|---|---|---|---|
| **fetch-trace diag** (engine, diag-gated) | log per-emit atlas block-id sequence for one frame | out: block-id stream in the device log | existing emit path |
| **`cache_hitrate.py`** (`scripts/perf/`) | offline fully-assoc LRU model → hit-rate(B) + cyc/px(B) | in: block-id trace; out: knee `SRC_BLOCKS` | none (pure) |
| **`sdram_fb_cache.sv` `SRC_BLOCKS`** | enlarge only the P_SRC cache | new param → ch5 `jtframe_cache.BLOCKS` | jtframe_cache (fully-assoc) |
| **A/B capture** (reuse `scripts/perf/`) | baseline-RBF vs enlarged-RBF on fixed spots | in: two RBFs; out: fabric_hw/comp/fps deltas | Stage 5 harness |

## 6. Testing strategy

- Task A: validate `cache_hitrate.py` against a synthetic trace with a known reuse pattern (e.g. a
  cyclic-N access → hit-rate 0 below N blocks, 100% at ≥N); host-unit-checkable, no hardware.
- Task B: the `SRC_BLOCKS`=2 default must reproduce today's RBF bit-for-bit behavior (true
  no-op baseline) — the A/B baseline leg proves it.
- Task C: CI fit/STA is the associativity-cost gate; HW A/B is the win gate; regression sweep +
  operator eyes are the correctness gate.

## 7. Risks

| Risk | Mitigation |
|---|---|
| Fully-assoc `SRC_BLOCKS` won't close timing at the knee size | CI STA gate; back off `SRC_BLOCKS` (timing is the ceiling); if the knee needs more than fits → §8 Phase 2 (pattern RAM) |
| Knee is near the full working set (poor locality) | Task A measures it up front; if so, Phase 1 yields little and we go straight to §8 |
| RAM pressure (83% → higher) hurts fit/routing | size `SRC_BLOCKS` to stay ≤ ~90% RAM; CI fit is the gate |
| Cache-coherency bug on the bigger block set | reuse the proven `stage_barrier`/vsync-invalidate; Task C regression sweep + operator gate |
| No env-gate (RBF-level) → risky ship | A/B via two RBFs; ship only after HW win + operator confirm; `SRC_BLOCKS` default-2 keeps baseline reproducible |

## 8. Phase 2 (documented follow-on — NOT this spec)

If Task A shows the knee exceeds the feasible fully-associative size, the full win needs either:
- a **dedicated on-chip pattern-pixel BRAM** (stage all ~150 patterns' pixels at map load,
  compositor reads by pattern index — no tags, scales cleanly, ~64 M10K), and/or
- **FB→DDR3 relocation** to free `comp_fbram`'s block count for it (survey:
  `research-scanout-survey.md` — OpenBOR's `openbor_video_reader` already targets a DDR3
  double-buffer; the new RTL is the fabric compositor writing its dest to DDR3, PSX-modeled).
Both are larger, RBF-level, and gated on Phase 1's measured curve. Kept separate so Phase 1 (the
low-risk partial win) ships independently.

## References
- `docs/superpowers/2026-07-21-stage5-fabric-parallelization-analysis.md` — the fetch-stall proof.
- `docs/superpowers/2026-07-21-stage5-decision.md` — the map-119 baseline + limiter history.
- `.superpowers/sdd/research-fb-scanout.md`, `research-scanout-survey.md` — the ascal/OpenBOR/PSX
  scanout research (Phase 2 grounding).
- `fpga/rtl/sdram_fb_cache.sv` (RO_BLOCKS/P_SRC/stage_barrier), `fpga/rtl/jtframe/jtframe_cache*.sv`
  (fully-associative), `fpga/sim/tb_profile.sv` (the cyc/px transfer function).
