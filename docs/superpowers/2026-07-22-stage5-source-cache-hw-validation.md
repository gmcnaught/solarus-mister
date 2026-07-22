# Stage 5 Phase 1 — Source-cache enlargement HW validation (Task C)

**Branch:** `feat/stage5-perf-rebaseline` · **Change:** P_SRC (ch5) `SRC_BLOCKS` 2 → **128**
(commit `1214906`, the only `fpga/**` delta vs `origin/master`).

## Step 1 — CI RBF build + fit/STA gate ✅ PASS

CI run `29919378528` ("Build Solarus RBF", Windows/Quartus 17.0.2) — **Fitter Successful**.
Artifacts: `solarus-rbf` (enlarged RBF), `quartus-reports`.

### Fit (`Solarus.fit.summary`)

| Metric | Enlarged (SRC_BLOCKS=128) | Baseline ref | Gate |
|---|---|---|---|
| Fitter status | Successful | — | ✅ |
| Total RAM Blocks | **493 / 553 (89 %)** | 461 / 553 (83 %) | ≤ ~90 % ✅ (tight) |
| Block memory bits | 3,675,050 / 5,662,720 (65 %) | — | ✅ |
| Logic (ALMs) | 14,644 / 41,910 (35 %) | — | ✅ |
| DSP | 46 / 112 | — | ✅ |

The +32 M10K (≈ the enlarged ch5 + tags) lands at 89 % — under the gate with little headroom.
Phase 2 (FB → DDR3) later frees the ~15 M10K comp_fbram, restoring margin.

### STA (`Solarus.sta.summary`)

**The gate clock is the 98.44 MHz core/blitter domain (`emu|pll…general[0]…divclk` = clk_sys).**

| Clock | Setup slack | Verdict |
|---|---|---|
| **clk_sys (general[0])** | **+0.234 ns** | ✅ positive — and **better than the prior shipped +0.175 ns** (Stage 3b B2, SEED 3) |
| SDRAM_CLK | +15.477 ns | ✅ (the cache's own domain — huge margin) |
| general[2] | +7.540 ns | ✅ |
| h2f_user0_clk | +1.926 ns | ✅ |
| `pll_hdmi…divclk` | **−0.396 ns** | **pre-existing, NOT a datapath violation** |

The lone negative slack is on the **HDMI PLL reconfig path**, which `fpga/sys/sys_top.sdc:15`
places in an `-exclusive` clock group (async from the fabric) — a standard MiSTer condition every
core reports; unrelated to the SDRAM cache and unchanged by this commit.

**Conclusion:** enlarging ch5 to 128 blocks did **not** regress fabric timing (clk_sys +0.234 vs the
prior +0.175). This confirms the Task A analysis: the cache is 4-way set-associative, so the tag
compare is a constant 4-way and growing `SRC_BLOCKS` only deepens set-index BRAM — a BRAM cost, not a
timing cost. **No back-off to 64 needed.**

## Step 2–3 — Two-RBF HW A/B ✅ (2026-07-22)

Baseline = shipped `Solarus_20260721.rbf`; enlarged = CI `Solarus_20260722.rbf` (sha `7ca9aa80…`).
Same engine on both legs (`SOLARUS_FETCHTRACE` off = normal behaviour; the cache lives in the RBF).
Standing capture via `scripts/perf/stage5_ab_cache.sh`, CURMAP-confirmed. **Workload identical across
legs** (map119: resident buckets=6, patterns=153, entries=4071; ~1750 draws, distinct_tex=17 both), so
the delta is purely the cache — not fewer ops.

### map 119 (parallax — the fetch-bound target; tilemap grid barely engages, so a clean cache A/B)

| Metric | Baseline | Enlarged (128) | Δ |
|---|---|---|---|
| **comp** (compositor ms/fr) | 54.43 | **14.89** | **3.66× faster** |
| fabric_hw (ms/fr) | 66.41 | 26.78 | 2.48× |
| cyc/frame | 6,537,015 | 2,636,588 | 2.48× |
| **fps** | 11.9 | **19.9** | **+67 %** |
| period | 84.3 ms | 50.3 ms | −40 % |

The measured **comp 3.66×** matches the Task-A model projection (9.20 → 2.38 cyc/px = **3.86×**) — the
offline model predicted the HW result within ~5 %.

### map 1 (house — carries the extra 88c6385 tilemap-fix confound, but consistent)

| Metric | Baseline | Enlarged (128) | Δ |
|---|---|---|---|
| comp (ms/fr) | 21.89 | 8.43 | 2.6× |
| cyc/frame | 2,858,302 | 1,521,652 | 1.9× |
| **fps** | 19.9 | **28.8** | **+45 %** |
| bound | FABRIC | **A9 (flipped)** | — |

## Step 4 — Regression ✅

No scene regressed — the cache is transparent read-only, so comp can only improve or stay equal. map1
went FABRIC→A9-bound (+45 % fps); the operator observed fps increases in **every** scenario checked.

## Step 5 — Operator visual gate ✅ PASS (2026-07-22)

Operator confirmed on the **enlarged core** (`Solarus_20260722.rbf`): **map119 parallax, map1/interiors,
a dungeon, and a transition all render correctly** — no stale/torn/flickering/garbage tiles (the signature
of a cache-coherency miss), with fps up in every scenario. Baseline core separately confirmed correct as a
reference. Not self-declared.

## Verdict

Phase 1 source-cache enlargement is **HW-validated**: 128-block P_SRC (SETS=32) closes timing (clk_sys
+0.234 ns), fits BRAM (89 %), cuts the fetch-bound compositor **3.66×** on map119 (fps 11.9→19.9) and
2.6× on map1 (fps 19.9→28.8), with no regression and a clean operator visual gate. Ships as
`SRC_BLOCKS=128`. Phase 2 (FB→DDR3) remains the follow-on for further fabric headroom.
