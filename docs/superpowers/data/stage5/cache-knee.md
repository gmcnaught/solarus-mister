# Stage 5 Phase 1 — P_SRC cache hit-rate knee (Task A result)

**Date:** 2026-07-22 · **Branch:** `feat/stage5-perf-rebaseline` · **Engine:** fetch-trace build
(`libsolarus.so.1.6.5` sha `e15a7509…`, `SOLARUS_FETCHTRACE=1`) · **Device:** 192.168.20.81

## TL;DR

- Baseline P_SRC (`RO_BLOCKS=2`, 512 B) hits **0 %** on both measured maps → **9.20 cyc/px**, exactly the
  fetch-stall the Stage 5 analysis predicted.
- **Recommended `SRC_BLOCKS` = 128** (ch5 only; must be a power-of-2-sets size — see below, so 96 is
  illegal). map119 (the fetch-bound parallax spot): **97.4 % hit → 2.38 cyc/px, a 3.9× speed-up** over
  baseline. map1 (house): 97.2 %. Fallback **64** → map119 93.1 % / 2.68 (3.4×).
- **Two spec/plan premises were WRONG and are corrected below** — the cache is **4-way set-associative
  (FIFO)**, not fully-associative, which (a) lowers the hit-rate at a given size (conflict misses,
  pushing the knee up from ~48 to ~96) but (b) makes a *large* cache **timing-cheap** (the 4-way tag
  compare is constant; growing `SRC_BLOCKS` only adds set-index BRAM depth). The real ceiling is **BRAM
  fit**, not tag-compare fan-out — so the plan's "knee > 64 ⇒ escalate to Phase 2" trigger is **moot**.

## How it was measured

`patches/mister/mister_blitter_renderer.cpp` gains a `SOLARUS_FETCHTRACE=1` diag that, **for exactly one
resident build frame per scene** (gated on `res_building`, counter reset + `FETCH_SCENE` marker at each
rebuild in `resident_begin_frame`), prints one `FETCH <src_off> <src_x> <src_y> <w> <h> <stride>` line per
atlas source it emits to the fabric (static tile records + that frame's parallax `emit_draw` composites +
sprites). One build frame is the correct unit because **P_SRC is invalidated per vsync** — the cache is
cold at each frame start, so cross-frame reuse would be a false hit.

`scripts/perf/cache_hitrate.py` expands each `FETCH` line into the 256 B blocks it touches
(`RO_BLKSIZE = 256`, confirmed in `sdram_fb_cache.sv:55`) and replays the block sequence through the cache
model. Captured with `scripts/perf/capture_fetchtrace.sh` (fresh launch per map, `teleport` to the target,
`CURMAP` confirmed on the live engine):

- `fetchtrace-map119.log` — map 119 parallax (`from_dungeon_10`), CURMAP confirmed 119. 107 741 accesses, 685 distinct blocks.
- `fetchtrace-map1.log` — map 1 house (`from_main_room`), CURMAP confirmed 1. 8 656 accesses, 232 distinct blocks.

## Result — the REAL (4-way set-assoc, FIFO) sweep

### map 119 (parallax — the fetch-bound target)

| SRC_BLOCKS | hit (real) | cyc/px | speed-up vs 9.20 | (full-assoc bound) |
|-----------:|-----------:|-------:|-----------------:|-------------------:|
| 2 (baseline) |   0.0 % | 9.20 | 1.0× |  0.0 % |
| 8          |   0.0 % | 9.20 | 1.0× | 77.2 % |
| 16         |  77.9 % | 3.75 | 2.5× | 85.6 % |
| 32         |  86.0 % | 3.18 | 2.9× | 92.4 % |
| 48         |  91.9 % | 2.77 | 3.3× | 95.5 % |
| 64         |  93.1 % | 2.68 | 3.4× | 96.3 % |
| **96**     | **96.7 %** | **2.43** | **3.78×** | 97.0 % |
| 128        |  97.4 % | 2.38 | 3.9× | 97.4 % |
| 256        |  98.3 % | 2.32 | 4.0× | 98.5 % |

### map 1 (house)

| SRC_BLOCKS | hit (real) | cyc/px | (full-assoc bound) |
|-----------:|-----------:|-------:|-------------------:|
| 2 (baseline) |  0.0 % | 9.20 |  0.0 % |
| 8          |  81.2 % | 3.52 | 81.3 % |
| 16         |  92.9 % | 2.70 | 93.0 % |
| 32         |  95.4 % | 2.53 | 95.4 % |
| 64         |  96.3 % | 2.46 | 96.5 % |
| 96         |  96.8 % | 2.42 | 96.9 % |

map1 spreads evenly across sets (its curve nearly matches the full-assoc bound); **map119 is the binding
case** — it suffers real conflict misses at small sizes (note `SRC_BLOCKS=8` → **0 %** real vs 77 % bound).

## The knee

Plan criterion: smallest `SRC_BLOCKS` with ≥ 85 % hit **and** cyc/px within ~15 % of the ~2.2 floor (≤ 2.53).
Binding map = 119.

- **≥ 85 % hit alone:** 32 (86.0 %).
- **Within 15 % of floor (≤ 2.53):** 96 (2.43). 64 (2.68) and 48 (2.77) miss it.

**`SRC_BLOCKS` must give a POWER-OF-2 number of sets** (⇒ `SRC_BLOCKS ∈ {4,8,16,32,64,128,256}` since
WAYS=4). jtframe derives the set index by **bit-slicing** the block address to `SET_BITS = clog2(SETS)`
bits (`jtframe_cache_req.sv:98-100`, `req_set = SETW'(uaddr >> OFFW)`) and stores tags in a `2^SETW`-deep
RAM with `repl_ptr[0:SETS-1]` — a non-power-of-2 SETS (e.g. 96 → SETS=24) lets the set index reach 31 and
address out-of-range replacement state. **So 96 is NOT a legal size**; the pick is 64 vs 128.

**Chosen `SRC_BLOCKS` target for Task B: 128** (SETS=32) — map119 **97.4 % / 2.38 / 3.9×**, map1 97.2 %;
near the 256-block floor (98.3 %). ~25.6 M10K data RAM on ch5 (256 B × 128 = 32 KB), fits the ~92 free with
margin. **Fallback 64** (SETS=16): map119 93.1 % / 2.68 / 3.4×, ~12.8 M10K — use if Task C CI fit/STA can't
take 128. (Phase 2 moves the FB out of BRAM, *freeing* M10K, so there is no reason to reserve headroom now.)

## Corrections to the spec/plan premises (load-bearing)

1. **NOT fully-associative.** `jtframe_cache_ctrl.sv`: `WAYS = BLOCKS<4 ? BLOCKS : 4`, `SETS = BLOCKS/WAYS`,
   and `jtframe_cache_tags.sv` replaces via a per-set `repl_ptr` advanced past the filled way — i.e. **4-way
   set-associative with round-robin/FIFO replacement**. The spec (§3) and plan ("`jtframe_cache` is
   fully-associative — capacity = hit-rate") are incorrect. `set(block_id) = block_id % SETS` (set bits sit
   just above the 256 B block offset in `line_base_uaddr`). The model was corrected: `saa_fifo_hitrate`
   (real) with `saa_hitrate` (4-way LRU) and `lru_hitrate` (full-assoc) as upper bounds. FIFO ≈ LRU on these
   traces (the pattern isn't recency-sensitive), so the knee is robust to the replacement policy; the
   set-associativity is what raises it (~48 full-assoc → ~96 real).

2. **Timing ceiling is BRAM, not tag-compare.** A 4-way cache does a **constant** 4-way tag compare
   regardless of `BLOCKS`; enlarging ch5 only deepens the set-index BRAM. So the plan's "tag-compare scales
   → timing ceiling → knee > 64 ⇒ escalate to Phase 2" does not apply. Enlarging ch5 to 96 is expected to
   be **timing-cheap**; the real gate is BRAM fit (Task C CI STA still authoritative).

   BRAM cost (ch5 only; 256 B block = 2048 bits, M10K = 10 240 bits; only ch5 grows 2→N, other RO channels
   stay at 2): **64 ≈ 13 M10K, 96 ≈ 19 M10K, 128 ≈ 26 M10K** for data RAM (+ small tag RAM). Whole-core
   baseline is 461/553 M10K (~92 free), so 96 fits with margin.

## Caveats

- `blocks_for_tile` assumes **2 B/px (RGB565)** for the intra-row byte span; most quest atlases are **PAL8
  (1 B/px)**, so the model over-states each tile's horizontal span → **conservative** (real working set ≤
  modeled ⇒ real hit-rate ≥ modeled at a given size; a cache sized to this knee over-performs). Stride is
  the real byte stride from the surface handle, so row addressing is exact.
- One build frame per map ≈ steady state (static tiles replay every frame; parallax composites every frame);
  the build frame may carry incoming-transition overlay draws, a minor addition.
- Only two maps measured (the two Stage 5 harness spots). map119 is the fetch-bound worst case and sets the
  knee; map1 corroborates. A third heavy overworld would tighten confidence but is not required to size.

## Next (Task B)

Add a decoupled `SRC_BLOCKS` param to `sdram_fb_cache.sv` (default 2 = baseline), route to **ch5 only**
(P_SCAN/ch4 stays at `RO_BLOCKS=2`), set to **128** (SETS=32). Then Task C: CI build → fit/STA gate (BRAM
is the ceiling) → two-RBF HW A/B on map1/map119.
