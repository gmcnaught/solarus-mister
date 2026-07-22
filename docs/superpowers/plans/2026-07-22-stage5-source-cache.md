# Stage 5 Phase 1 — Fabric Source-Cache Enlargement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut the atlas source-fetch stalls that dominate fabric-bound scenes by enlarging the on-chip P_SRC cache, sized from a measured hit-rate curve, within current free BRAM (no framebuffer relocation).

**Architecture:** Task A measures the fully-associative LRU hit-rate vs cache-size curve offline (engine fetch-trace diag → Python LRU model → the "knee" that captures most of the win) so the cache is sized from data, not guessed. Task B adds a `SRC_BLOCKS` param to `sdram_fb_cache` (decoupled from P_SCAN) set to the knee. Task C builds the RBF via CI (fit/STA gate for the associativity cost) and HW-A/Bs baseline vs enlarged on the fabric-bound spots. Reuses the Stage 5 capture harness and the `tb_profile` cyc/px transfer function.

**Tech Stack:** Python 3 (offline LRU model + tests, `scripts/perf/`), C++11 (`mister_blitter_renderer.cpp` diag), SystemVerilog (`fpga/rtl/sdram_fb_cache.sv`, `jtframe_cache`), Quartus 17.0.2 via CI `build-rbf.yml` (no local Quartus), the Stage 5 device harness (`scripts/perf/capture_map119.sh` + `stage5_ab2.sh`), device `192.168.20.81`.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-07-22-stage5-source-cache-design.md`. **Grounding:** `docs/superpowers/2026-07-21-stage5-fabric-parallelization-analysis.md` (fetch-stall proof, transfer fn), whole-core fit baseline **461/553 M10K (83%), ~92 free**.
- **This is an RBF-level change — NOT env-gatable.** Validation is a **two-RBF A/B** (baseline RBF vs enlarged-cache RBF), not a runtime flag. `SRC_BLOCKS` **default = 2** must reproduce today's RBF behavior exactly (the baseline leg).
- **`jtframe_cache` is fully-associative** — no conflict misses (capacity = hit-rate), but tag-compare scales with block count, so `SRC_BLOCKS` has a **timing ceiling**. The knee from Task A is a *target*; CI STA is the *ceiling*. If they conflict, timing wins (back off `SRC_BLOCKS`; if the knee can't fit, STOP and escalate to Phase 2 per spec §8).
- **`RO_BLOCKS`/`RO_BLKSIZE` are shared by P_SCAN + P_SRC.** Only P_SRC (ch5) grows; P_SCAN stays at 2.
- **No local Quartus.** RBF builds go through CI (`gh workflow run build-rbf.yml` / push to a branch); fetch results with `gh run download`. STA + fit summary are in the `quartus-reports` artifact (`Solarus.fit.summary`, `Solarus.sta.summary`).
- **jtframe is vendored** (`fpga/rtl/jtframe/jtframe_cache*.sv`, "do not hand-edit; regenerate by re-copying") — do NOT edit jtframe internals; only pass a larger `BLOCKS` param from `sdram_fb_cache.sv`.
- **Coherency unchanged:** the existing `stage_barrier` (ch1→ch5 flush+invalidate) and per-vsync ch5 invalidate keep P_SRC correct; a bigger cache reuses them.
- **Never self-declare visual correctness** — Task C's final gate is the operator.
- **Commit trailers:** end every commit with the repo's `Co-Authored-By:` + `Claude-Session:` lines.

**Line numbers are anchors as of `feat/stage5-perf-rebaseline` @ HEAD; re-grep before editing.**

---

### Task A: Measure the hit-rate curve (offline, RBF-free)

**Files:**
- Create: `scripts/perf/cache_hitrate.py`, `scripts/perf/test_cache_hitrate.py`
- Modify: `patches/mister/mister_blitter_renderer.cpp` (a diag-gated fetch-trace log)
- Create: `docs/superpowers/data/stage5/cache-knee.md` (result + chosen `SRC_BLOCKS`)

**Interfaces:**
- Produces: `lru_hitrate(block_seq, n_blocks) -> float` and `sweep(block_seq, sizes) -> list[(B, hitrate, cycpx)]` (cyc/px via `2.2 + (1-hitrate)*7.0`), consumed by Task A's analysis + the `cache-knee.md` result that sets Task B's `SRC_BLOCKS`.

- [ ] **Step 1: Write the failing test for the LRU model.** Create `scripts/perf/test_cache_hitrate.py`:

```python
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from cache_hitrate import lru_hitrate, cycpx_for

def approx(a, b, e=1e-6): assert abs(a-b) < e, f"{a} != {b}"

def test_fully_assoc_capacity():
    # cyclic access to N distinct blocks: LRU cache of B<N blocks -> 0 hits
    # (every block evicted before reuse); B>=N -> all-hit after the cold fill.
    seq = [i % 5 for i in range(100)]         # 5 distinct blocks, cyclic
    assert lru_hitrate(seq, 4) == 0.0          # 4<5: thrash, 0 hits
    hr5 = lru_hitrate(seq, 5)                   # 5>=5: only the first 5 are cold
    approx(hr5, 95/100)                         # 95 hits / 100 accesses

def test_reuse_locality():
    # a hot block reused with small reuse-distance hits even in a small cache.
    seq = [0,1,0,1,0,1,0,1]                     # 2 distinct, distance 1
    approx(lru_hitrate(seq, 2), 6/8)           # first 2 cold, rest hit

def test_cycpx_transfer():
    approx(cycpx_for(1.0), 2.2)                 # all hits -> floor
    approx(cycpx_for(0.0), 9.2)                 # all miss -> 2.2 + 7

if __name__ == "__main__":
    for name in [n for n in dir() if n.startswith("test_")]:
        globals()[name](); print(f"OK: {name}")
```

- [ ] **Step 2: Run to verify it fails.**

  Run: `python3 scripts/perf/test_cache_hitrate.py` → FAIL (`cannot import name 'lru_hitrate'`).

- [ ] **Step 3: Implement `cache_hitrate.py`.** Create `scripts/perf/cache_hitrate.py`:

```python
#!/usr/bin/env python3
"""Offline fully-associative LRU hit-rate model for the P_SRC atlas cache (Stage 5 Phase 1).
Feed the block-id access sequence (from the engine fetch-trace diag); sweep cache sizes to
find the knee that captures most of the win. cyc/px via the tb_profile transfer function."""
from collections import OrderedDict

def lru_hitrate(block_seq, n_blocks):
    """Fully-associative LRU of n_blocks blocks. Returns hits/accesses."""
    if not block_seq: return 0.0
    cache = OrderedDict()           # block_id -> None, MRU at end
    hits = 0
    for b in block_seq:
        if b in cache:
            hits += 1
            cache.move_to_end(b)
        else:
            cache[b] = None
            if len(cache) > n_blocks:
                cache.popitem(last=False)   # evict LRU
    return hits / len(block_seq)

def cycpx_for(hitrate):
    """tb_profile transfer fn: all-hit ~2.2 cyc/px, all-miss ~9.2 (2.2 + miss*7)."""
    return 2.2 + (1.0 - hitrate) * 7.0

def sweep(block_seq, sizes):
    return [(B, lru_hitrate(block_seq, B), cycpx_for(lru_hitrate(block_seq, B))) for B in sizes]

def blocks_for_tile(src_off, src_x, src_y, w, h, stride, blksize=256):
    """Atlas byte addresses a tile's source region touches -> distinct 256B block ids."""
    blocks = set()
    for row in range(h):
        row_base = src_off + (src_y + row) * stride + src_x * 2   # RGB565 = 2 B/px
        for col_byte in range(0, w * 2, blksize):
            blocks.add((row_base + col_byte) // blksize)
    return sorted(blocks)

if __name__ == "__main__":
    import sys, re
    # stdin: lines "FETCH src_off src_x src_y w h stride" from the engine diag.
    seq = []
    for line in sys.stdin:
        m = re.search(r"FETCH (\d+) (\d+) (\d+) (\d+) (\d+) (\d+)", line)
        if m:
            seq += blocks_for_tile(*(int(x) for x in m.groups()))
    sizes = [2, 8, 16, 32, 48, 64, 96, 128, 256]
    print(f"total accesses={len(seq)} distinct blocks={len(set(seq))}")
    for B, hr, cp in sweep(seq, sizes):
        print(f"  SRC_BLOCKS={B:4d}  hit={hr*100:5.1f}%  cyc/px={cp:.2f}")
```

- [ ] **Step 4: Run to verify it passes.**

  Run: `python3 scripts/perf/test_cache_hitrate.py` → `OK: ...` for all three, exit 0.

- [ ] **Step 5: Add the engine fetch-trace diag.** In `patches/mister/mister_blitter_renderer.cpp`, add a diag gated on `getenv("SOLARUS_FETCHTRACE")` that, for a **bounded window (e.g. the first fully-composited frame after a settle)**, prints one `FETCH <src_off> <src_x> <src_y> <w> <h> <stride>` line per tile source as it is emitted to the fabric (the tile-list / grid / sprite emit sites that carry an atlas `src_off`). Bound it (a static counter, stop after N≈8000 tiles or one frame) so the log stays small. Re-grep the emit sites: `grep -n "src_off\|blt_tile_list\|emit_draw\|blt_grid_list" patches/mister/mister_blitter_renderer.cpp`. Type-check with the `-std=c++11` recipe (CLAUDE.md) → exits 0.

- [ ] **Step 6: Capture traces + compute the knee.** Build the engine (armhf Docker — note the git-am-in-Docker flake: retry, or apply the series on host; recipe in `docs/superpowers/next-session-enemy-simd.md`), deploy `--no-rbf`, and with `SOLARUS_FETCHTRACE=1` capture one frame's trace on **map 1** and **map 119** (Stage 5 harness spots). Pull the logs; run `python3 scripts/perf/cache_hitrate.py < trace.log` for each. Record in `docs/superpowers/data/stage5/cache-knee.md`: the sweep tables, the **knee** (smallest `SRC_BLOCKS` with ≥~85% hit / cyc/px within ~15% of the floor), and the chosen `SRC_BLOCKS` target for Task B. If the knee exceeds a plausibly-timing-feasible fully-associative size (say > ~64), record that and flag **escalate to Phase 2** (spec §8) — do not proceed to Task B with an infeasible size.

- [ ] **Step 7: Commit.**
  ```bash
  git add scripts/perf/cache_hitrate.py scripts/perf/test_cache_hitrate.py patches/mister/mister_blitter_renderer.cpp docs/superpowers/data/stage5/cache-knee.md
  git commit -m "perf(stage5): offline LRU hit-rate model + fetch-trace diag; map1/map119 cache knee"
  ```

---

### Task B: Enlarge the P_SRC cache (RTL)

**Files:**
- Modify: `fpga/rtl/sdram_fb_cache.sv`

**Interfaces:**
- Consumes: the `SRC_BLOCKS` knee value from Task A's `cache-knee.md`.
- Produces: a larger ch5 (P_SRC) cache; P_SCAN unchanged.

- [ ] **Step 1: Add a decoupled `SRC_BLOCKS` param.** In `sdram_fb_cache.sv`, add `parameter integer SRC_BLOCKS = 2` (default 2 = baseline) next to `RO_BLOCKS`. Route it to the P_SRC (ch5) `jtframe_cache`/`jtframe_cache_mux` `BLOCKS` param **only** — leave P_SCAN (ch4) on `RO_BLOCKS`. Re-grep the instantiation: `grep -n "jtframe_cache_mux\|RO_BLOCKS\|BLOCKS\|ch5\|P_SRC" fpga/rtl/sdram_fb_cache.sv`. Do NOT edit `fpga/rtl/jtframe/*` (vendored) — only pass the param. If the mux applies one `RO_BLOCKS` to both RO channels, thread a separate per-channel block count through the mux param list (still `sdram_fb_cache`-side only; if the vendored mux genuinely can't express per-channel sizes, STOP and report — that's a jtframe-structure blocker to resolve before proceeding).

- [ ] **Step 2: Set `SRC_BLOCKS` to the knee** (Task A) at the top-level instantiation of `sdram_fb_cache` (grep `sdram_fb_cache #(` / the instance in `blitter_top.sv` or `Solarus.sv`). Keep the default at 2 so an unset override reproduces baseline.

- [ ] **Step 3: Verify coherency wiring intact + lint.**

  Run: `grep -n "stage_barrier\|dst_barrier\|inval\|ch5" fpga/rtl/sdram_fb_cache.sv` → the ch5 invalidate/flush wiring must be unchanged (bigger cache, same barriers).
  Run the verilator lint + wire-constants CI locally if available, else rely on the CI in Task C: `bash fpga/sim/run_sims.sh` (or the subset that compiles `sdram_fb_cache`) → the P_SRC unit test `tb_sdram_fb_cache` still passes (warm-hit/cold-miss guard holds with more blocks).

- [ ] **Step 4: Commit.**
  ```bash
  git add fpga/rtl/sdram_fb_cache.sv
  git commit -m "perf(stage5): decouple SRC_BLOCKS, enlarge P_SRC atlas cache to <N> blocks (Task A knee)"
  ```

---

### Task C: CI build (fit/STA gate) + HW A/B (operator-gated)

**Files:**
- Create: `docs/superpowers/2026-07-22-stage5-source-cache-hw-validation.md`

- [ ] **Step 1: CI build the enlarged-cache RBF + the fit/STA gate.** Push the branch (or `gh workflow run build-rbf.yml`); wait for the run. `gh run download <id> -n quartus-reports` and check `Solarus.fit.summary` (RAM Blocks ≤ ~90% for margin, fit Successful) and `Solarus.sta.summary` (**positive slack**). If STA is negative or RAM overflows, reduce `SRC_BLOCKS` (Task B Step 2) and rebuild — timing/fit is the ceiling. Record the fit/STA numbers.

- [ ] **Step 2: Get both RBFs.** The **baseline** RBF = the current shipped `Solarus_YYYYMMDD.rbf` (or a CI build of HEAD with `SRC_BLOCKS=2`). The **enlarged** RBF = Step 1's artifact (`gh run download -n solarus-rbf`). Name them distinctly in `_Other/` for OSD A/B (per the joypad-inject memory's core-swap recipe).

- [ ] **Step 3: HW A/B on the fabric-bound spots.** Deploy each RBF (+ the same engine); load each core; capture map 1 (house) + map 119 (parallax) with the Stage 5 harness. Assert on the enlarged leg vs baseline: **`[blitter hwperf]` fabric_hw + comp DROP**, `[blitter timing]` fps/period improve, and (if a cache hit/miss counter is exposed) hit-rate rises. Quantify the deltas vs the ~4× projection.

- [ ] **Step 4: Regression sweep.** On the enlarged RBF, capture an A9-bound scene (map 23 dungeon / town) and one transition: confirm **no fps regression** on non-fabric-bound scenes and no correctness change (the cache is transparent; a regression means a coherency bug — the `stage_barrier` reuse should prevent it).

- [ ] **Step 5: Operator visual gate.** Operator confirms on device: map 1, map 119, the dungeon, and a transition all render **correctly** with the enlarged-cache RBF (no stale/torn tiles from a cache-coherency miss). Never self-declare.

- [ ] **Step 6: Record + PR.** Write `docs/superpowers/2026-07-22-stage5-source-cache-hw-validation.md`: the knee, fit/STA, the A/B deltas (fabric_hw/comp/fps on map1/map119), regression result, operator confirmation. Commit. Open/UPDATE the Stage 5 PR (`feat/stage5-perf-rebaseline` → master) summarizing the whole Stage 5 arc: baseline finding → grid-overlap lever (correct but inert/neutral, default-off) → **source-cache enlargement (the real fabric win)** + the Phase-2 pointer. Do NOT mark done until the operator confirms.

---

## Self-Review

**Spec coverage:** §1 goal (enlarge P_SRC within free BRAM, measured sizing) → Tasks A/B ✓; §2 why (fetch-stall, transfer fn) → Task A model + cycpx_for ✓; §3 fully-assoc constraint (capacity=hitrate, timing ceiling) → Task A knee + Task C STA-is-ceiling + escalate-to-Phase-2 ✓; §3 RO shared → Task B decouples `SRC_BLOCKS` from P_SCAN ✓; §4 Task A offline model + fetch-trace + knee → Task A ✓; §4 Task B `SRC_BLOCKS` + stage_barrier coherency → Task B Steps 1/3 ✓; §4 Task C sim + CI fit/STA + two-RBF A/B + regression + operator → Task C ✓; §6 testing (synthetic-trace LRU validation, default-2 baseline, CI gate, regression) → Task A Step 1 / Task B default / Task C ✓; §7 risks (timing, big knee, RAM pressure, coherency, no-env-gate) → Global Constraints + Task C gates + Task A escalation ✓; §8 Phase 2 escape → Task A Step 6 flag ✓.

**Placeholder scan:** No TBD/TODO. `<N>` / `SRC_BLOCKS` value is the measured knee from Task A (Step 6 produces it, Task B Step 2 consumes it) — a measure-then-set, with an explicit "if the knee is infeasible, STOP + escalate" branch rather than a vague number. The fetch-trace diag's exact emit sites are named by a re-grep (Task A Step 5) because line numbers drift.

**Type consistency:** `lru_hitrate(seq, n_blocks) -> float`, `cycpx_for(hitrate) -> float`, `blocks_for_tile(...) -> list`, `sweep(...)` are defined in Task A Step 3 and consumed by its tests (Step 1) and the `__main__` analysis (Steps 3/6). `SRC_BLOCKS` is named identically across Task B Steps 1/2 and Task C Steps 1/2. The `FETCH src_off src_x src_y w h stride` diag format (Task A Step 5) matches the `blocks_for_tile` args and the `__main__` regex exactly.
