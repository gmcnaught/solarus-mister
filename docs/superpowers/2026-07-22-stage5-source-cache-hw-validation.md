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

## Step 2–5 — Two-RBF HW A/B + operator gate ⏳ PENDING (needs device + operator)

- **Baseline RBF:** since Task B is the sole `fpga/**` delta, a build of `origin/master` (or HEAD with
  `SRC_BLOCKS=2`) isolates the cache change exactly. (The shipped `Solarus_20260721.rbf` is the baseline
  iff it matches master's tip.)
- **A/B:** deploy each RBF + the same engine; capture map1 (house) + map119 (parallax) with the Stage 5
  harness. Expect on the enlarged leg: `[blitter hwperf]` fabric_hw + comp **drop**, `[blitter timing]`
  fps/period **improve** (projection: map119 ~9.20 → ~2.4 cyc/px composite, ~3.9×).
- **Regression:** an A9-bound scene (town/dungeon) + a transition — no fps regression, no correctness change.
- **Operator visual gate:** map1, map119, dungeon, a transition all render correctly (no stale/torn tiles).
  Never self-declared.

## Step 6 — Record + PR ⏳ (after the A/B)
