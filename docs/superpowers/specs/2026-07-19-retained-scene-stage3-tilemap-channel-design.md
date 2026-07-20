# Retained-Scene Compositor — Stage 3 design (transition bandaid + tilemap channel)

**Date:** 2026-07-19
**Status:** design approved (brainstorm), pending spec review → implementation plan
**Parent design:** `docs/superpowers/specs/2026-07-17-retained-scene-compositor-design.md`
**Predecessor:** `docs/superpowers/specs/2026-07-19-retained-scene-stage2-sprite-channel-design.md`
**Branch base:** `master` @ `69c0b43` (Stage 2 merged, PR #126)

---

## 0. What changed from the parent design — read this first

Three deviations from parent §7's Stage 3 row, all deliberate operator decisions this
session. Anyone reading the parent design alone will have the wrong expectations.

### 0.1 Stage 3 is a CORRECTNESS project. 60 fps is out of its acceptance criteria.

Parent §7 sells Stage 3 as "parallax → 60". Stage 2 design §7 attached a gate: *re-measure
the `comp_pipeline` ceiling on the current default-ON build before committing to Stage 3*,
because the only **measured** ceiling in the repo
(`2026-06-25-compositor-throughput-session.md:44-48`) puts the overworld at fps=19.9,
fabric=36.6 ms, **comp=75%** — fabric-bound with the A9 idle, `pipeline_ceiling ~25–31 fps`
even double-buffered. A new expanding opcode cuts ring-walk and emit cost but **not the 75%
that is `comp_pipeline` itself**. The parent's "~1.8× headroom" (§5) is an *estimate*; the
19.9 fps figure is a *measurement*.

**Operator decision: skip the gate and reframe the stage.** Stage 3 ships for bug deletion.
`tilemap_unit` cyc/px is **measured and recorded, but is not a pass/fail gate**. The parent's
"≤ 3.0 cyc/px" acceptance number is demoted to an observation.

**Consequence:** reaching 60 fps now requires a **separate `comp_pipeline` throughput
workstream**, scheduled independently. It is not descoped from the project, only from this
stage. Do not let Stage 3's completion be read as progress toward 60 fps.

### 0.2 Stage 3 splits into 3a and 3b, in that order

Parent §7 bundles the grid op with the `g_transition_scroll` removal (§9.1). They are
independently landable and the bandaid is the cheaper, lower-risk half. Landing it first
means the grid op is brought up on a base where the scroll path is no longer a software
fallback, and an artifact seen at 3b's HW gate can be attributed.

### 0.3 Deletion stays in Stage 4

Stage 3 **adds** `TilemapChannel` + `tilemap_unit` behind `SOLARUS_TILEMAPCH=0` and switches
to it. `bgplane`, `resident`, and flat-command remnants come out in Stage 4, after 0–3
validate. Both stages stay reversible by env flag. Scale of what Stage 4 will remove, for
sizing: 189 `bgplane`/`plane_` references and 40 `resident_` references in a 4,656-line
`mister_blitter_renderer.cpp`, plus 24 bgplane references in the 1,327-line `blitter_top.sv`.

---

## 1. Stage 3a — remove the `g_transition_scroll` bandaid

### 1.1 What the bandaid is

`g_transition_scroll` (`mister_blitter_renderer.cpp:228-231`) is set true only for
`TransitionScrolling` (`active && needs_previous_surface()`). While true, it disables the
fabric alias entirely, so the whole map re-composites **in software** through SDL for the
transition's duration. It gates six sites: alias adoption (`:2708`), promote-skip (`:2737`),
promote-lock (`:2758`), case-2 alias composite (`:2807`), alias reset (`:2863`), and the
resident tile-list fast path (`:2872`).

The comment at `:209-231` gives two justifications:

1. the alias composites the new map into DDR at (0,0), leaving the camera *surface's* own
   pixels empty, "so the new map has nothing to scroll in (only the old map scrolls away)";
2. "the two maps' atlases co-resident overflow the heap (**black flicker**)" — i.e. #123.

### 1.2 Justification (2) is dead code — VERIFIED

Stage 2 design §9.1 flagged (2) as *possibly* stale since #66. It is worse than stale: **the
mechanism the comment describes no longer exists.**

- The per-edge heap reset was deleted by commit `4f91c1b` ("refactor(renderer): drop
  scene_too_big + heap-reset/transition-reclaim (residency)"). `heap_reset_pending`,
  `was_in_transition`, `did_reset_last` all return **zero hits** in the renderer.
- The deletion was pre-planned in `docs/superpowers/plans/2026-07-06-sdram-asset-residency.md:631`, which
  names the exact two `if` blocks removed **and adds "and their explanatory comment block."**
  The blocks went; the comment did not. That is the stale artifact.
- Every surviving `blt_heap_reset` call is unrelated to transitions: SDRAM/bgplane probes
  (`:1305`, `:1355`), loadbar flush (`:1504`), end of preload (`:1614`), bounce-overflow
  drain inside preload staging (`:1721`, `:1754`).

The co-residency premise is independently gone. Tileset atlases resolve to **perm SDRAM**:
`res_bucket_params` hits `pal_handles` and returns the preloaded PAL8 perm ref with **no
allocation at all** (`:1965-1971`); on a miss the surface is marked immutable and `upload()`
routes immutable sources to `blt_stage_surface_perm` (`:1934-1937`). The DDR3 heap is still
a *bounce* for the DDR3→SDRAM stage, but per map load the traffic is bounded to first-sight
tilesets — the `handles` cache (`:939`, `:1854-1886`) means a revisit allocates nothing. Two
maps co-resident is at most ~2 × ~0.9 MiB (`:1976`) against a ~15.2 MiB heap (`:263`).

### 1.3 Justification (1) is real — and the fabric already expresses the fix

(1) is accurate: `:2709-2710` sets `alias_off_x = alias_off_y = 0` ("full-screen camera
composites at (0,0)") and case-2 draws composite via `emit_draw(src, infos, d->alias_off_x,
d->alias_off_y)` (`:2824`). During a scroll the camera surface's own pixels are never
populated.

**But signed per-batch dst bias already exists and is fully plumbed.** No RTL work is needed:

- Fabric: `res_bias_x/res_bias_y` are `reg signed [15:0]` (`blitter_top.sv:395`), latched
  **per command header** at three decode sites — `OP_TILELIST` (`:729-730`),
  `OP_TILELIST_RES` (`:755-756`), `OP_SPRITELIST` (`:793-794`) — and added to every entry's
  dst (`:897-898`, `:951-952`, `:1027-1028`). Per-batch, not global.
- Host: `blt_tile_list_res` / `blt_tile_list_static` / `blt_sprite_channel_flush` all take
  `int16_t bias_x, bias_y` (`blt_emitter.h:248`, `:259`, `:294`, `:357`), packed into the
  header's `src_x/src_y` slots (`blt_emitter.c:372-373`, `:431-432`), with the C reference
  model agreeing (`blitter_ref.c:342-343`, `:367-368`, `:394-396`) and unit tests pinning
  the encoding (`blt_emitter.c:617-618`, `:648-649`).
- The tile path already computes bias from the live camera (`:3851`, `:3875`).
- Host-side per-draw offset also already exists: `alias_off_x/alias_off_y` (`:526`) are
  applied as `bdx = dr.get_x() + off_x` in both `emit_draw` (`:2626`, `:2648`, `:2657`) and
  `sprite_channel_push` (`:2268`), followed by `clip_to_fb` in final framebuffer coords
  (`:2280`). They are already non-zero on the heuristic promote-lock path (`:2761-2762`).

**The actual blocker is narrower than §9.1 guessed:** the alias is **single-target** — one
`alias_target` pointer (`:526`) — and the old map's pixels live in `previous_map_surface`,
for which there is no channel. This is host-side plumbing, not fabric expressiveness.

### 1.4 Stage 3a scope — three parts, no RTL change

**(a) Correct the stale comment.** Strip the heap-overflow clause and every "heap reset"
reference from `:209-231` (`:215`, `:217`, `:221`, `:228`), keeping only justification (1).
As written it sends readers hunting for code deleted in `4f91c1b`.

**(b) Add a DDR-heap high-water tracker.** There is currently **no way to observe DDR-heap
pressure**: `em.heap_used` is instantaneous (`:1681`), never reset per frame, with no peak
tracker and no assert. The `[blitter inter] used=%u/%u leaked=%u` line (`:4253-4262`) reads
`blt_alloc_used(&d->em.sdram_alloc)` — the **SDRAM INTER arena**, a different region; the
comment at `:4247-4252` says so directly ("despite the region's name, there is no
`sdram_inter` member").

> **Correction of record.** The Stage 2 HW validation doc (`2026-07-19-stage2-hw-validation.md`,
> §Arena) reports `[blitter inter] peak 0.75 / 4.00 MiB`. That figure is about the SDRAM
> INTER arena and **cannot** be used to argue anything about DDR-heap overflow during a
> scroll. Any future claim about #123's heap premise must cite `heap_used`/`heap_cap`
> (`:4227`), the per-frame `ovf` (`:4197`), or `g_esc_overflow`/`g_esc_toobig`
> (`:2181-2182`, printed `:4225`).

This is deliberate scope creep, accepted by the operator: it is a few lines, and its absence
is precisely why a false claim survived two stages.

**(c) Two-target alias.** Replace the single `alias_target` pointer with a small fixed target
set carrying a per-target bias: the new map at bias = scroll offset, and
`previous_map_surface` at bias = scroll offset + W (or + H for vertical scrolls). Both maps'
sources are perm-SDRAM-resident, so a two-batch two-bias composite has **no per-frame upload
cost**. Then remove all six `g_transition_scroll` gate sites and the flag itself.

Fixed-size target set (2), not a dynamic container — Solarus scrolls between exactly two maps.

### 1.5 Stage 3a acceptance — the scroll A/B is the gate

Parent design predicted Stage 1 would structurally delete #122 and #123. That was **never
verified** — scroll was observed only in passing. Stage 2's own HW record lists "#122 / #123
not assessed" under *What is NOT established*, and notes Stage 2 was gated behind
`!g_transition_scroll` so its A/B would have measured the software fallback anyway.

**3a does not land without a deliberate scroll-transition A/B on hardware, with the
operator's eyes on it:**

- bandaid ON vs OFF, same core, same two maps, on the Stage 2 session's pinned scroll targets
  (map 8→9, 9→3);
- an **explicit verdict** on #122 and on #123 — closed, still open, or changed. Not "looks
  fine in passing";
- `heap_used`/`heap_cap`, per-frame `ovf`, and `esc_overflow` captured **across a scroll
  edge** — the measurement no session has ever taken, and the one that settles whether
  justification (2)'s premise was ever reachable in the current build.

No stage advances on the agent's say-so (memory `solarus-no-self-declared-visual-validation`).

---

## 2. Stage 3b — `TilemapChannel` + `tilemap_unit`

### 2.1 Census — the measured basis (Mystery of Solarus DX)

137 maps, 20 tilesets, 64,155 `tile` entries, 6,402 `tile_pattern` definitions, parsed from
`deploy/quests/mystery_of_solarus_dx/data/`. This replaces the parent design's estimates.

| Quantity | min | median | p95 | max |
|---|---|---|---|---|
| map width (px) | 320 | 640 | 2256 | 3056 |
| map height (px) | 240 | 616 | 1808 | 2320 |
| cells @8px | 1,200 | 4,800 | 54,692 | **107,724** |
| tile entries / map | 0 | 240 | 1,322 | **6,053** |
| distinct patterns / map | — | 68 | 157 | **251** |

Largest map: **44** (inside_world, ts3) 3056×2256 = 382×282 cells @8px.

**Layer count is fixed.** All 137 maps declare `min_layer=0, max_layer=2` — exactly 3 layers,
no exceptions. 87 populate all three, 49 use two, 1 uses one.

### 2.2 The grid must be 8px — decisive

- **100.00%** of pattern dimensions are multiples of 8, and **100.00%** of the 64,155 tile
  placements are 8px-aligned in x and y (0 misaligned, 0 maps affected).
- Only **20.1%** of placements have a pattern size that is a multiple of 16, and only
  **30.0%** are 16px-aligned in position — 44,918 of 64,155 misaligned, across **135 of 137
  maps**.

A 16px cell grid is not merely lossy, it is **unrepresentable** for ~70% of the quest. 8px
also divides every map dimension exactly, while 13 maps have widths and 11 have heights that
are not multiples of 16 and would need padding.

43 distinct pattern sizes exist; 42% of pattern definitions are non-square; by placement,
**45.3% are neither 8×8 nor 16×16** (8×8 36.5%, 16×16 18.2%, 8×16 8.5%, 24×24 8.3%, 16×8
7.9%, 16×24 5.6%, 24×16 4.9%). Because every pattern is a whole number of 8px cells on the
8px lattice, **no irregular tile geometry forces a fallback** — a non-8×8 pattern is a
rectangular run of cells.

### 2.3 Descriptor budget is a non-issue — parent §8 open item CLOSED

Heap is 16 MiB at `0x3B000000`, less `0x40` ctrl + 512 KiB ring ≈ **15.5 MiB**
(`mister_blitter_renderer.cpp:241-243`).

| Encoding | worst map (44), 3 layers | % of heap |
|---|---|---|
| 8px / 8-bit index | 315.6 KiB | 2% |
| 8px / 16-bit index | 631.2 KiB | 4% |
| **8px / 32-bit cell (chosen)** | **1.23 MiB** | **8%** |

Two maps co-resident during a scroll at the chosen encoding = ~2.5 MiB = 16%. The **entire
137-map quest** resident at once fits (4.88 MiB @8b, 9.76 MiB @16b).

**Parent §8's "max map dims that fit the descriptor budget before per-layer fallback" is
closed: no map dimension in this quest forces a fallback.**

### 2.4 Cell encoding — 32-bit: 12-bit pattern index + 4+4 sub-cell offset

39.4% of tile entries (25,283 of 64,155) span more than one cell — maps are already
run-length rectangles, not per-cell lists. Top spans (1,1) 38,872, (1,2) 2,755, (2,1) 2,472,
(3,1) 1,513, (4,1) 1,410; the largest single entry spans 82×226 = 18,532 cells (a full-map
floor fill). A cell therefore needs pattern index **plus** its position inside that pattern.

Because entries *repeat* a pattern across a rectangle, the sub-cell offset is
`cell_pos mod pattern_cells` — bounded by the largest pattern, 128×112 = **16×14 cells**. So
**4 bits x + 4 bits y covers every case in the quest** with margin.

**Chosen: 32-bit cell = 12-bit pattern index + 4-bit sub-x + 4-bit sub-y + 12 spare.**

Rationale, and the constraint that drove it — **BRAM, not DDR**:

- The existing pattern table is `frt_bram` (`blitter_top.sv:402`), sized `MAXP*MAXF` with
  **`MAXP = 128`** — and note the definition reads *"max distinct **animated** patterns"*
  (`blitter_defs.vh:127`). Today it bounds animated patterns only. **Under this design its
  scope widens: the grid indirects _every_ cell through the pattern table, not just animated
  ones.** Against the measured max of **251 distinct patterns in one map** (map 3, "Outside
  world A3"), the table must grow to ≥256 — an architectural consequence of the grid op, not
  a pre-existing shortfall. `MAXF=8` frames/pattern is unchanged.
- **Sized: the delta is small.** `frt_bram` is `MAXP*MAXF` = 1024 words × 64 bits ≈ 64 Kbit
  ≈ **8 M10K blocks**. `MAXP` 128→256 takes it to ~16 — **a delta of ~8 blocks**. Doubling
  MAXP doubles the array, but the array is small to begin with.
- **Headroom, from REAL CI data (not the dated doc):** Quartus run `29701340705` reports
  **467/553 RAM blocks (84%)** — block memory bits 3,426,218/5,662,720 (61%), ALMs
  13,992/41,910 (33%). **Only 86 blocks free**, not the ~118 an earlier draft of this spec
  inferred from `plans/2026-07-08-phase3b-background-plane-cache.md` (435/553, 79%). The
  ~8-block delta is ~9% of true remaining headroom — still comfortable, but the margin is
  thinner than the dated figure suggested. **Use 467/553; the 79% number is stale.**
- **STA margin is thin and must be respected:** the same baseline shows worst-case setup
  slack **+0.316 ns**, and `clk_sys general[0]` (the blitter clock) at **+0.361 ns** after
  Stage 2. Stage 2's own −0.187 ns delta on that clock was **not attributable** — unrelated
  clocks (`spi_sck` −0.949, `h2f_user0` +0.847) moved more in the same build, so placement
  variance dominated. **Run a seed sweep before trusting any single post-Stage-3b build.**
- **For scale**, `comp_fbram` is 8 banks (`bank0-3` WORK + `sbank0-3` SCAN, the PR #49
  double-buffer) × 19,200 words × 16 bits ≈ 2.46 Mbit ≈ **~240 M10K blocks** — roughly 30×
  the entire cost of this table growth.

**On the DDR-framebuffer escape hatch.** The project has long held that if BRAM runs out, the
framebuffers move to DDR. That option stands, but **Stage 3b must not spend it**: it would
trade ~240 blocks' worth of the project's most load-bearing optimization to buy ~8.

The cost is not merely BRAM-for-DDR. It lands on the throughput workstream deferred in §0.1:

- The compositor is **already memory-bound** (comp=75%, `pipeline_ceiling ~25–31 fps`,
  `2026-06-25-compositor-throughput-session.md:44-48`). On-chip FB is what makes `comp_fbram`'s
  II=1 RMW possible; in DDR every composite becomes SDRAM read-modify-write traffic on the
  measured bottleneck path. The plausible outcome is a **worse** ceiling.
- FB-in-BRAM was adopted precisely because it **eliminated the #44/#46 seam class** (PR #49,
  memory `fpga-fb-in-bram-feasibility`) and dissolved the scanout-contention arc (#31→#34).
  Moving back to DDR re-opens HW-validated fixes.

**Disposition: the DDR-FB hatch belongs to the throughput workstream**, to be evaluated there
on cycle cost with the seam class re-litigated deliberately — not spent as small change on a
pattern table.

**Caveat:** these block counts are arithmetic from array declarations plus dated planning
docs; no Quartus reports are in-tree. The plan must confirm the real `frt_bram` delta against
current CI fit data before the RTL work commits (§2.6). If fit data contradicts this, the
conclusion changes.
- RAM blocks stand at **467/553 = 84%** (`plans/2026-07-08-phase3b-background-plane-cache.md:1190-1196`),
  with `comp_fbram` the bulk (~404/553, `plans/2026-06-26-fb-in-bram-compositor.md:19,151-152`).
  `blitter_top.sv:359-364` documents a prior "LAB-overflow chase" that forced explicit
  `ramstyle` pragmas. BRAM is the binding constraint.
- Therefore: keep sub-cell handling in the **DDR grid cell** (abundant — 8% of heap) rather
  than expanding the **BRAM pattern table** (scarce). Splitting multi-cell patterns into
  per-cell sub-patterns was rejected for exactly this reason: it trades the scarce resource
  for the abundant one.
- 12-bit index (4096) vs 8-bit: the 8-bit option needs per-map remapping to a dense 0..N
  space and the worst map measures 251 distinct — **5 headroom**. Too thin for third-party
  quests, and the memory saved is 4% of heap versus 8%. Raw pattern ids are sparse to 1227,
  so 12 bits is also enough to skip remapping entirely if that proves simpler.

`frt_bram` sizes to ≥256 entries (measured max 251); 320 gives margin without a second BRAM
tier. Pattern table itself is small: 773 entries (largest tileset) × 8–16 B = 6–12 KiB.

### 2.5 Host↔fabric contract

Per layer:

- **Descriptor** — SDRAM atlas base, grid dims (cells), blend, **scroll x/y**, pointer to
  the cell grid. *Scroll is the only per-frame field.*
- **Cell grid** — W×H × 32-bit cells as §2.4. *Rebuilt on map change only.*
- **Pattern→src table** — pattern index → current src rect. *Per frame, small.*

Per frame the host writes: scroll offsets (3), the pattern→src table, the sprite list
(Stage 2), and the overlay if dirty (Stage 1). Across a stable map the grids never change.

### 2.6 Fabric — `tilemap_unit`

`OP_TILELIST_RES` (opcode 6) is already a pattern-index → src-rect indirection with a
per-batch scroll offset, so the unit is largely built:

- `res_bias_x/res_bias_y` (`blitter_top.sv:684-685`, applied `:924-925`) **is** the scroll
  offset;
- CFT + `frt_bram` (`:402`) **is** the pattern→src table (today scoped to animated patterns —
  see §2.4);
- `S_TLR_SLICE` (`:918`) resolves pid → rect then joins the shared `S_TL_ISSUE`, proving a
  new address-generation front end can inherit the existing cull/issue/await-done loop.

**Delta to a grid op:** iteration source only (2D counter over the visible window vs a flat
list), a packed 32-bit cell fetcher, sub-cell offset application, scrolled-edge tile
clipping, and widening `frt_bram` to ≥256.

FSM state is `reg [5:0]` (`blitter_top.sv:212`) with ~10–12 free codes; the grid op reuses
`S_TL_ISSUE`/`S_TL_WAIT`. Opcode space is ample (8-bit, highest used is 10 after Stage 2).

**Caveat carried from Stage 2:** these fit/BRAM/state figures are quoted from dated planning
docs. **No Quartus reports are in-tree** — `Solarus.fit.summary` / `Solarus.sta.summary` are
CI artifacts (`gh run download <id> -n quartus-reports`). Pull current fit/STA before the
implementation plan commits to any RTL sizing claim.

### 2.7 Two census findings that need explicit homes

**Animated patterns.** ~350 quest-wide (66 multi-frame patterns in ts1/ts13, ~27 typical
elsewhere) have a frame list rather than a single src rect. They ride the **per-frame
pattern→src table** — exactly what `resident_update(token, cur_src, …)` already computes.
No cache, no invalidation heuristic: the table is a direct function of animation state.

**`dynamic_tile` entries.** Median 0, p95 36, **max 228 (map 130)**. These are runtime-toggled
and **cannot live in a static grid**. They route to **Stage 2's sprite channel**. Stage 2 is
load-bearing for Stage 3, which is worth noting given Stage 2 design §2.3 argued
`sprite_unit` was not strictly required by architecture (ii).

### 2.8 Per-layer fallback — criterion is SPARSITY, not size

Parent §6 anticipated fallback for maps whose grid exceeds a descriptor budget. §2.3 shows
that never happens. The real case is the opposite: **a dense grid for a nearly-empty layer.**

Per-layer 8px coverage (covered cells / total cells): median **0.368**, p95 1.165, max 2.153
(>1 = overdraw from stacked entries). **28 of 352 map-layers are below 10% coverage; 3 are
below 2%.**

**Ship v1 with the fallback wired but the threshold set so it never triggers.** The
mechanism is the existing ordered sprite-stream path, so a layer opting out is already a
supported shape. Picking a threshold requires measurement that does not exist yet, and
guessing one now would be an unmeasured constant in the hot path — the same class of
unsourced figure that produced Stage 2's ~450 sprites/frame estimate (actual peak: 122.6).

### 2.9 Map-change path

A map change is a well-defined event: rebuild the three cell grids once, reset the pattern
table, clear the sprite list. No render state carries across maps, which removes the
*cumulative* failure mode that #84's cumulative-transition symptom lived in. Atlas residency
(#66) is orthogonal and unchanged.

### 2.10 Stage 3b acceptance

Gate flag `SOLARUS_TILEMAPCH`, **default OFF**.

**Objective (must pass):**
- **Bit-exact grid walk vs a host reference walker** — the #24 arena-probe 60/60 pattern
  (memory `solarus-24-arena-probe-sdram-bit-exact`). Objective, not eyeballed.
- **Host scene tests** via `patches/mister/build_host_tests.sh` (the CI gate;
  `tests/run_tests.sh` is referenced by no workflow): emit a scene from a known map/frame,
  assert descriptor + cell-grid + pattern-table contents; assert per-layer draw order
  including the static-after-animated rule.
- **RTL sim** (`fpga/sim`): `tilemap_unit` grid walk vs the same reference. Mind the suite's
  known-slow TBs — historical CI timeouts there were slowness, not RTL bugs (memory
  `solarus-bgplane-sim-tbs-slow-not-broken`).
- **STA**: pull `Solarus.sta.summary` from CI, compare slack against the pre-change baseline.
  **A passing RBF is not evidence of passing timing** — `2026-06-25-compositor-throughput-session.md:68`
  records "RBF builds even with neg slack" (baseline `27c421c` was −3.359 ns).

**Visual (must pass):** operator's eyes on **map 119 "Outside world C3"** — see §2.11.

**Measured and recorded, NOT a gate:** `tilemap_unit` cyc/px on map 119. Per §0.1, 60 fps is
out of scope for this stage. Record the number so the separate throughput workstream starts
from a measurement rather than an estimate.

### 2.11 Named acceptance scenes

**Parallax is a `tile_pattern` property** (`scrolling = "parallax"`), **not** a map or layer
flag — 42 patterns across 4 tilesets (ts1 and ts13, ids 1146–1201; ts15 id 660; ts7 id 628).
**Only 3 maps place one:**

| Map | Tileset | Size | Cells @8px | Tile entries | Parallax entries | Grid (3 layers, 32-bit cell) |
|---|---|---|---|---|---|---|
| **119 "Outside world C3"** | ts1 | 640×752 | 7,520 | 1,044 | **295** | ~88 KiB |
| 31 "Dungeon 2 B1" | ts7 | 1152×768 | 13,824 | 416 | 1 | ~162 KiB |
| 130 "Dungeon 9 boss" | ts15 | 480×480 | 3,600 | 184 | 1 | ~42 KiB |

**Map 119 is the parallax acceptance scene** — the only map where parallax is load-bearing
(295 entries vs 1 elsewhere), and conveniently small.

**The "town" could not be identified from the data files.** `project_db.dat` labels overworld
maps only positionally ("Outside world A1..C3"); no map is named town or village. Ranked by
NPC count the candidates are **map 4 "Outside world B3"** (17 NPCs — most in the quest,
120×126 cells, 1,135 entries, 213 distinct patterns) and **map 3 "Outside world A3"**
(12 NPCs, 140×126 cells, 1,994 entries, **251 distinct patterns — the quest maximum, the map
that pins the index-width margin**). Confirming which is "the town" needs a screenshot, not
`.dat` structure. **Map 3 should be visited regardless**, as the worst case for the pattern
table.

---

## 3. Testing and process discipline (both stages)

Carried forward from Stage 2 §8; every item below is a recorded failure mode, not a
precaution.

- **Build inside the container** — `scripts/docker_run.sh bash scripts/build_engine.sh` — and
  **grep `BUILD_EXIT`** rather than trusting the task exit code. Running on the host produces
  a host-path `CMakeCache.txt` that then blocks the container build. In-docker `git am` is
  flaky; patch on the host (memory `solarus-docker-git-am-flaky-host-patch-workaround`).
- **Renderer type-check without armhf Docker:** the `g++ -fsyntax-only` recipe in
  `CLAUDE.md`. Note `mister_blitter_renderer.{cpp,h}` and `patches/mister/blitter/` are
  whole-file copies, **not** in the patch series — edit them directly.
- **Deploy** ships from `deploy/libs/`; **sha1-verify on device**. `deploy.py` exit 0 says
  nothing about which files moved — a Stage 1 run reported success having updated only
  `solarus-run`.
- **HW gate:** leave `Solarus.s0` **empty**, load the core, launch with a private `S0_FILE`
  override — two concurrent engines make the host mostly unresponsive (memory
  `solarus-two-engines-wedge-launch-recipe`). Log to `/media/fat/logs/Solarus/`, never `/tmp`
  (wiped on restart). **Never blind-inject joypad input.**
- **Confirm which RBF is loaded.** Both `Solarus_20260713.rbf` (no `sprite_unit`) and
  `Solarus_20260719.rbf` remain on the device. Loading the old core with `SOLARUS_SPRITECH=1`
  sends opcode 10 to a fabric with no arm for it, falling through to the default FILL/BLIT
  branch where `c_w`/`c_h` hold the entry count — **visible garbage that looks like a bug**.
- **Treat OSD interaction as a hazard.** Two consecutive validation sessions were ended by it
  (Stage 1: hammered input walked a menu into quit; Stage 2: another core started mid-session).

---

## 4. Out of scope

- **60 fps / `comp_pipeline` throughput** — separate workstream (§0.1).
- **Deleting `bgplane` / `resident` / flat-command remnants** — Stage 4 (§0.3).
- **Clean-laning the source/upload path** (`upload()`/`handles`/INTER staging/`blt_alloc`) —
  still deferred, as in Stage 2 §6.
- **Parent §6.2's dynamic-source scratch SDRAM arena** — follows the upload path. Note its
  sizing input is still missing: the Stage 2 session never visited the heaviest scenes, so
  its INTER occupancy peak (0.75/4.00 MiB) is a floor, not a census.
- **Frame-owning `scene_walker`** — rejected in Stage 2 §2.3; the grid op is an **in-band ring
  op** emitted at the correct ordinal position, so sprites stay in the ordered ring and
  Z-order remains guaranteed by ring order.
- **Scanout** — unchanged, direct `comp_fbram` path, not `MISTER_FB`/ascal (parent §3, memory
  `solarus-scanout-avoid-ascal-direct-path`).

---

## 5. Open items carried into implementation planning

- **Pull current fit/STA from CI** before any RTL sizing claim (§2.6).
- **Per-layer sparsity threshold** — deliberately unset in v1 (§2.8); needs measurement.
- **Confirm which overworld map is "the town"** — needs a screenshot (§2.11).
- **Scroll ratio computation** for parallax patterns is engine-side
  (`TilePattern`/`ParallaxScrollingTilePattern`), not in the `.dat` files; the host must read
  it from engine truth when building descriptors.
- **Whether the runtime layer set ever differs from the declared 0..2** — Lua can create
  dynamic tiles and `draw_on_map` overlays. The census establishes the *declared* set only.
- **#124** (overlay under-dims translucent menus) remains open from Stage 1; unchanged by
  this stage, cheap to fold into either build/HW cycle if wanted.

---

## 6. Evidence index

| Claim | Source |
|---|---|
| Heap reset deleted; comment stale | commit `4f91c1b`; `docs/superpowers/plans/2026-07-06-sdram-asset-residency.md:631`; zero grep hits |
| Tileset atlases perm-resident | `mister_blitter_renderer.cpp:1965-1971`, `:1934-1937`, `:1854-1886` |
| `[blitter inter]` ≠ DDR heap | `mister_blitter_renderer.cpp:4247-4262` |
| DDR heap signals | `:4227`, `:4197`, `:2181-2182`, `:4225` |
| Alias is single-target, composites at (0,0) | `:526`, `:2709-2710`, `:2824` |
| Per-batch signed dst bias exists (fabric) | `blitter_top.sv:395`, `:729-730`, `:755-756`, `:793-794`, `:897-898`, `:951-952`, `:1027-1028` |
| Dst bias plumbed (host + ref + tests) | `blt_emitter.h:248,259,294,357`; `blt_emitter.c:372-373,431-432,617-618,648-649`; `blitter_ref.c:342-343,367-368,394-396` |
| 8px alignment 100%, 16px 30% | census over 64,155 placements in `deploy/quests/mystery_of_solarus_dx/data/` |
| Max 251 distinct patterns/map | census, map 3 "Outside world A3" |
| `frt_bram` sized MAXP*MAXF | `blitter_top.sv:402` |
| `MAXP = 128` = max **animated** patterns | `blitter_defs.vh:127` |
| Commit `4f91c1b` exists w/ stated message; symbols absent | verified by `git log` + grep, this session |
| RAM blocks 467/553 (84%), 86 free | CI run `29701340705` quartus-reports-linux |
| clk_sys slack +0.361 ns post-Stage-2 | CI run `29702887930` vs baseline `29701340705` |
| Measured ceiling 19.9 fps, comp=75% | `2026-06-25-compositor-throughput-session.md:44-48` |
| RBF builds with negative slack | `2026-06-25-compositor-throughput-session.md:68` |
| Stage 2 gaps (#122/#123 unassessed) | `2026-07-19-stage2-hw-validation.md` §What is NOT established |
