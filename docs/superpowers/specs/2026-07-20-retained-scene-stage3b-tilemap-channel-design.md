# Retained-Scene Compositor — Stage 3b design (bake deletion + tilemap channel)

**Date:** 2026-07-20
**Status:** design approved (brainstorm), pending spec review → implementation plan
**Parent design:** `docs/superpowers/specs/2026-07-17-retained-scene-compositor-design.md`
**Predecessor:** `docs/superpowers/specs/2026-07-19-retained-scene-stage3-tilemap-channel-design.md`
**Branch base:** `origin/master` @ `97ae768` (Stage 3a merged, PR #128)

---

## 0. What changed from the Stage 3 design — read this first

The Stage 3 design was written on 2026-07-19. On 2026-07-20 the bake was proven to be the
single cause of #122, #127, and probably #123, and `SOLARUS_BGPLANE` was flipped to
**default OFF**. That changes Stage 3b's scope and its ordering.

### 0.1 Bake deletion moves from Stage 4 into Stage 3b

Stage 3 design §0.3 deferred `bgplane` deletion to Stage 4. **Operator decision: delete it in
3b.** The bake is default-OFF, HW-proven defective, and its only remaining function was to buy
parallax throughput that the tilemap channel supersedes. Leaving ~700 lines of dead, defective
code in the file that Stage 3b must heavily edit is a net cost, not a saving.

`resident_` and the flat-command remnants are **not** in scope. They remain Stage 4.

### 0.2 Deletion goes FIRST, and its HW gate needs no new core

Stage 3b runs as two phases with separate gates:

- **Phase A — delete the bake (host only).** No RTL, therefore **no Quartus build, no seed
  sweep, no new RBF**. `OP_BGPLANE_WRITE` is simply never emitted; the existing fabric arm
  goes unused and inert.
- **Phase B — `TilemapChannel` + `tilemap_unit`.** The bgplane *RTL* removal rides along with
  this phase's core build.

**Rationale.** Quartus builds plus seed sweeps are the slowest and least deterministic step in
this project, and STA margin is thin (§3.3). Folding the RTL deletion into Phase B's build buys
one Quartus/STA/seed-sweep cycle instead of two, at no correctness cost — dead RTL that is
never issued cannot misbehave. Phase A still gets a real HW gate, just on the current RBF.

Since `SOLARUS_BGPLANE` is already default-OFF, **the correct Phase A result is no visible
change at all** versus today's build. That makes gate A a clean regression check and is what
lets #122/#127 be closed by *removal* rather than by flag suppression.

### 0.3 Correction to the Stage 3 design's STA figure

Stage 3 design §2.4 cites worst-case setup slack **+0.316 ns**. Pulled from CI run
`29702887930` (`Solarus.sta.summary`), the real figure is **+0.155 ns** on
`pll_hdmi|…|counter[0].output_counter|divclk`. The blitter clock
(`emu|pll|…|general[0]`) is **+0.361 ns**, which the earlier doc had right. TNS is 0.000 on
every clock — the design meets timing, but the margin is thinner than recorded.

### 0.4 Two findings that simplify the design

**Sub-cell offset needs no modulo.** Stage 3 design §2.4 assumed tile entries *repeat* a
pattern across a rectangle, making the sub-cell offset `cell_pos mod pattern_cells`. The engine
asserts otherwise: `Entities::add_tile_info` requires
`box.width == pattern->get_width() && box.height == pattern->get_height()`
(`work/solarus/src/entities/Entities.cpp:819-823`). **Every static tile is exactly one pattern
instance.** The offset is plain subtraction, `cell_pos - tile_origin_cell`. The 4+4 bit sizing
is unchanged (largest pattern = 16×14 cells).

**bgplane is not upstream.** `patches/mister/blitter/` mirrors the `mister-fpga-blitter`
repository, which contains **zero** bgplane references. All bgplane code in the mirror is
solarus-local divergence. Deleting it needs no upstream coordination and *reduces* mirror drift.

---

## 1. Phase A — delete the bake (host)

### 1.1 Clean deletions

| Site | ~Lines | What |
|---|---|---|
| `mister_blitter_renderer.cpp:3185-3533` | 349 | `bake_background_plane_step()` — per-cell bake, coverage FILL, bucket replay, overflow retry |
| `:3537-3603` | 67 | `bake_all_planes_sync()` — the sync batched bake |
| `:3150-3183` | 34 | `bgplane_gradient_*()` debug-colour helpers |
| `:~1386-1440` | 55 | `run_bgw_probe()` — `SOLARUS_BGW_PROBE` HW A/B |
| `:398-415` | 18 | `SDRAM_BGPLANE_BASE/SIZE` + `static_assert`s |
| `:640-689` | 50 | `Impl::BgPlane`, `bg_planes` map, `bgplane_enabled`, `bgplane_sync` |
| `:710-758` | 49 | diag flags `bgw_probe`, `bgplane_diag`, `bgplane_solid`, `bgplane_copydbg` |
| `:1704-1715` | 12 | arena headroom banner |
| `:2520-2551`, `:2630-2635` | ~10 | six `SOLARUS_BGPLANE*` env reads + `blt_alloc_init(&em.sdram_bgplane, …)` |
| `:30-32` | 3 | the three `blitter/bgplane_*.h` includes |

Plus: headers `bgplane_bounds.h` (61), `bgplane_geom.h` (73), `bgplane_sync.h` (22); tests
`bgplane_bounds_test.cpp`, `bgplane_geom_test.cpp`, `bgplane_sync_bake_test.c`,
`bgplane_sync_batch_test.c`, `blt_bgplane_write_test.c` and their five stanzas in
`tests/run_tests.sh:126-158`; `blt_bgplane_write_cell()` (`blt_emitter.h:267-276`,
`blt_emitter.c:520-530`); `blt_alloc_t sdram_bgplane` (`blt_emitter.h:67`); series patches
**0032** and **0035**; the `BGPLANE=` banner field in `games/Solarus/solarus_run.sh:80`; the
bgplane comment blocks in `games/Solarus/diag.env`.

### 1.2 Entangled sites — excisions from functions that survive

Five places where bgplane is interleaved *into* kept code rather than adjacent to it. Each is
an excision; the enclosing function stays.

1. **`res_arm_()` — `:3798-3990`.** A ~190-line `if (d->bgplane_enabled) {…}` block sits inside,
   immediately before `d->res_armed = true`. It only **reads** `res_static_buckets`; it mutates
   no resident state. Delete the block and trim the surrounding rationale comments
   (`:3798-3810`), which become stale.
2. **`resident_emit_static_layer()` — `:4106-4340`.** This override **must survive** (declared
   `mister_blitter_renderer.h:87`, called from `Entities.cpp`). Lines `4119-4136` are already
   the non-plane fallback. **Collapse the function to that fallback unconditionally**, dropping
   the `bg_planes` lookup, the early-return guard, and the ~200 plane-only lines. Before
   deleting the Stage-3a `scroll_bias_x/y` destination clip at `4315-4330`, verify it is
   genuinely duplicated in `res_emit_static_bucket_` rather than unique here.
3. **`resident_begin_frame()`** — remove the per-frame bake driver (`:3078-3081`) with its
   45-line snapshot-safety comment (`:3050-3077`), and the plane-invalidation loop
   (`:3121-3123`) with its rationale comment (`:3110-3120`).
4. **`fill()` — `:2760-2780`.** Two diag hooks inside a live hot path; the `bgplane_solid` one
   **rewrites the fill colour to magenta**. Remove both.
5. **`Impl` per-frame reset — `:1326`.** One line: `for (auto& kv : bg_planes) …copied_this_frame = false;`.

Also `present()` — remove the `if (d->bgw_probe) { d->run_bgw_probe(); return; }` dispatch.

### 1.3 Deliberately KEPT — decide, do not reflex-delete

- **`BLT_OP_BGPLANE_WRITE = 8`** (`blitter_ref.h:89`) and **`BLT_F_BGCOV = 0x80`** (`:171-174`)
  stay as **reserved** wire-ABI constants. Phase B introduces a new opcode; renumbering the wire
  ABI while simultaneously adding to it is needless risk, and `scripts/tests/test_wire_constants.py:71,78,131,159`
  asserts host↔RTL numbering. The emitter function goes; the numbers stay reserved with a
  comment saying so.
- **The `min_layer` parameter** on `resident_begin_frame` (series patch 0034). It is a live
  3-arg ABI on a surviving virtual and Phase B wants it. Remove only the `(void)min_layer`
  discard at `:3086`.
- **`mister_set_background_color`** (series patch 0033). Its sole current consumer is
  `bake_all_planes_sync:3551`, but series patch 0040 also declares it, and Phase B needs the map
  background colour. Keep it; confirm the 0040 dependency during implementation.
- **`blt_fill_flags()`** (`blt_emitter.h:139`) becomes callerless but is a reasonable generic
  API. Keep.

### 1.4 Series-patch dispositions

| Patch | Disposition |
|---|---|
| 0032 (`resident_static_before_animated` virtual) | **Drop** — already fully reverted by 0036 |
| 0033 (`mister_set_background_color` publish) | **Keep** — see §1.3 |
| 0034 (`min_layer` threading) | **Keep the `min_layer` half**; its `resident_static_before_animated(int layer)` half is deleted by 0036 already |
| 0035 (comment fix) | **Drop or reword** — bgplane-describing comments only |
| 0036 (removes `resident_static_before_animated`) | **Keep** — a net simplification that must be preserved |

### 1.5 Gate A

- Host tests (`patches/mister/build_host_tests.sh` — the CI gate) and
  `scripts/tests/test_wire_constants.py` pass.
- `g++ -fsyntax-only` renderer type-check (recipe in `CLAUDE.md`).
- In-container build: `scripts/docker_run.sh bash scripts/build_engine.sh`, **grepping
  `BUILD_EXIT`** rather than trusting the task exit code.
- HW session **on the existing RBF**. Expected result: **behaviour identical to today's
  default-OFF build.** Operator's eyes, per memory `solarus-no-self-declared-visual-validation`.
- **Explicit verdicts on #122, #127, #123** — closed by removal, or still open.

---

## 2. Phase B — `TilemapChannel` (host)

### 2.1 Scope: the static path only, at the seam Phase A just cleaned

The grid op covers **static tiles**. Tiles in animated regions keep the existing
`OP_TILELIST_RES` batch path. Static tiles reach the fabric through
`resident_emit_static_layer()` — precisely the function Phase A collapses to its bucket-replay
fallback. **Phase B replaces that fallback with a grid op at the same seam bgplane occupied.**
One insertion point serves both phases.

### 2.2 Cell encoding

**32-bit cell = 12-bit pattern index + 4-bit sub-x + 4-bit sub-y + 12 spare** (unchanged from
the Stage 3 design), with the §0.4 simplification: sub-offset is `cell_pos - tile_origin_cell`.

Grid is **8px**, which the census establishes as mandatory: 100.00% of the 64,155 placements are
8px-aligned, but only 30.0% are 16px-aligned — a 16px grid is unrepresentable for ~70% of the
quest.

Budget: worst map (44, 3056×2256) is 1.23 MiB across 3 layers = **8% of the ~15.5 MiB heap**;
two maps co-resident during a scroll ≈ 16%. Non-issue.

12-bit index over 8-bit: the worst map measures 251 distinct patterns, leaving an 8-bit encoding
only 5 headroom — too thin for third-party quests. 12 bits also spans the sparse raw id range
(to 1227), so remapping can be skipped if that proves simpler.

### 2.3 Grid build and invalidation

Build rides the existing BUILD-frame walk in `NonAnimatedRegions::record_static`
(`work/solarus/src/entities/NonAnimatedRegions.cpp:370-465`) — whole-map, camera-independent,
and already correctly deduped for `Grid<TileInfo>`'s multi-cell storage (`:398-404`). No new
enumeration is needed.

`resident_begin_frame`'s `(map_id, tileset_id)` signature miss
(`mister_blitter_renderer.cpp:3044`) stays the rebuild edge. It fires on the first
`Entities::draw()` after either changes and is memoized per frame. Its pointer-identity basis
(`&map`, `&map.get_tileset()`) can alias on a freed-and-reallocated `Map`; the existing code
accepts that risk everywhere and this design does not change it.

A mid-map tileset swap (`Entities::notify_tileset_changed`) leaves grid **geometry** valid —
only the pattern→src table needs rebuilding.

### 2.4 Camera, parallax, animation — all already expressed

- **Camera/parallax bias** exists at emit time: `res_emit_static_bucket_` computes
  `ratio<=1 → bias = -camera`, `ratio>1 → bias = camera/ratio - camera`. The grid stores map
  coordinates; the host writes **one bias per layer per frame**. This is exactly the "scroll is
  the only per-frame descriptor field" contract.
- **Parallax ratio** is a compile-time constant 2
  (`include/solarus/entities/ParallaxScrollingTilePattern.h:55`), selected per bucket at
  `Entities.cpp:1615-1617`.
- **Animated patterns** ride the existing per-frame `resident_update(token, cur_src,
  cur_frame, frame_count, frames[])` loop (`Entities.cpp:1536-1550`). Frame rects are captured
  once at arm; only the current-frame index moves per frame. No cache, no invalidation
  heuristic.

### 2.5 Host↔fabric contract

Per layer: **descriptor** (SDRAM atlas base, grid dims in cells, blend, scroll x/y, pointer to
the cell grid) + **cell grid** (W×H × 32-bit, rebuilt on map change only) + **pattern→src
table** (per frame, small).

### 2.6 Two required engine patches

1. **Pattern tokens on the static path.** `resident_record_static` currently discards pattern
   identity and stores raw src rects (`mister_blitter_renderer.cpp:3717-3720`), but the grid is
   *built on* pattern indices. Add a `tokens` parameter through `Renderer.h:113-117`,
   `NonAnimatedRegions.cpp:382`, and the renderer. Runtime identity is the `TilePattern*` used
   as `uintptr_t`, interned to a dense slot by `res_pat_index` — the same scheme the animated
   path already uses, extended to static patterns. There is no engine-side stable integer
   pattern id; the dense host intern index is the grid's 12-bit value.
2. **Map dimensions at load** (`w8`/`h8`, via `Map::get_width8()/get_height8()`), so grids are
   sized rather than grown. The renderer holds `map_id` as an opaque `uintptr_t` and has no
   `Map&`. Natural hook: `Entities::notify_map_starting()` (`Entities.cpp:676-697`), after the
   `build()` loop.

### 2.7 Known limitation, inherited not introduced

`SelfScrollingTilePattern` has no `get_draw_region` override, so it escapes to `res_fatal`
(`mister_blitter_renderer.cpp:3733-3741`) — a hard failure. It has no representation in
**either** resident path today. Stage 3b inherits this unchanged. Recorded so it is a known
limitation rather than a surprise at the HW gate.

### 2.8 Per-layer fallback

Ship v1 with the fallback **wired but the threshold set so it never triggers**. The real risk is
a dense grid for a nearly-empty layer — 28 of 352 map-layers are below 10% coverage, 3 below 2%
— not grid size. The mechanism is the existing ordered bucket-replay path, so a layer opting out
is an already-supported shape. Picking a threshold needs measurement that does not exist;
guessing one puts an unmeasured constant in the hot path, the same class of error that produced
Stage 2's ~450 sprites/frame estimate against an actual peak of 122.6.

---

## 3. Phase B — `tilemap_unit` (RTL)

### 3.1 A front end, not a new pipeline

`OP_TILELIST_RES` (opcode 6) is already pattern-index → src-rect indirection with a per-batch
signed scroll bias:

- `res_bias_x/res_bias_y` (`blitter_top.sv:684-685`, applied `:924-925`) **is** the scroll offset;
- CFT + `frt_bram` (`:402`) **is** the pattern→src table;
- `S_TLR_SLICE` (`:918`) resolves pid → rect then joins the shared `S_TL_ISSUE`, proving a new
  address-generation front end can inherit the existing cull/issue/await-done loop.

**Delta:** a 2D counter over the visible window (vs. a flat list walk), a packed 32-bit cell
fetcher, sub-cell offset application, scrolled-edge tile clipping, and widening `frt_bram`.

FSM state is `reg [5:0]` (`:212`) with ~10-12 free codes; the grid op reuses
`S_TL_ISSUE`/`S_TL_WAIT`. Opcode space is 8-bit, highest used is 10 after Stage 2.

### 3.2 `frt_bram`: `MAXP` 128 → 256

`MAXP` is defined as "max distinct **animated** patterns" (`blitter_defs.vh:127`). **This design
widens its scope**: the grid indirects *every* cell through the pattern table. Against the
measured max of **251 distinct patterns in one map** (map 3), the table must reach ≥256. `MAXF=8`
frames/pattern is unchanged.

Cost: `frt_bram` is `MAXP*MAXF` = 1024 words × 64 bits ≈ 64 Kbit ≈ **8 M10K blocks**; doubling
`MAXP` adds **~8**, against **86 free** — ~9% of true headroom. For scale, `comp_fbram` is
~240 blocks, so this is ~3% of what the on-chip framebuffer costs.

**Caveat that must be honoured:** the fit report shows block memory *bits* at 61% but *blocks*
at 84% — blocks are underfilled, so **block count is the binding constraint and bit arithmetic
understates cost**. Confirm the real delta against the post-change fit report; if it contradicts
this estimate, the conclusion changes.

**The DDR-framebuffer escape hatch stays unspent.** Moving framebuffers to DDR to free BRAM
would trade ~240 blocks of the project's most load-bearing optimisation to buy ~8, re-open the
#44/#46 seam class that PR #49 closed, and push every composite onto the already-saturated SDRAM
path (comp=75%). It belongs to the throughput workstream, evaluated on cycle cost — not spent as
small change on a pattern table.

### 3.3 Timing discipline

Baseline (run `29702887930`): blitter clock `general[0]` **+0.361 ns**; worst-in-design
+0.155 ns (`pll_hdmi`, unrelated); TNS 0.000 everywhere.

- **A single post-change build is not evidence.** Stage 2's own −0.187 ns delta on this clock
  was **not attributable** — `spi_sck` (−0.949) and `h2f_user0` (+0.847) moved more in the same
  build, so placement variance dominated. **Run a seed sweep.**
- **A passing RBF is not evidence of passing timing** — baseline `27c421c` built at −3.359 ns.

### 3.4 bgplane RTL removal (rides this build)

**Whole-module deletions:** `fbram_to_sdram.sv` (252 lines, the bake write-back path),
`bgw_ch0_mux.sv` (57), `bgplane_coverage.sv` (87).

**In-place excisions:** 85 refs in `blitter_top.sv`, 2 in `comp_src_linebuf.sv`, plus the
`OP_BGPLANE_WRITE` / `BGCOV` declarations in `blitter_defs.vh` — noting §1.3 keeps the *host*
enum values reserved, so the RTL side must stay numerically consistent with
`test_wire_constants.py` even where the logic goes.

**Sim:** twelve `tb_bgplane_*` / `tb_pal8_bgplane` TBs and their `run_sims.sh` +
`.github/workflows/sim.yml` entries.

`tilemap_unit` reads atlas + grid from DDR and never bakes back to SDRAM, so **none of this RTL
is reusable by Phase B** — the removal strands nothing. Deleting the known-slow `tb_bgplane_*`
TBs should also speed the sim suite; historical CI timeouts there were slowness, not RTL bugs.

---

## 4. Gates

### 4.1 Phase A — see §1.5. No core build.

### 4.2 Phase B

Gate flag `SOLARUS_TILEMAPCH`, **default OFF**.

**Objective (must pass):**
- **Bit-exact grid walk vs. a host reference walker** — the #24 arena-probe 60/60 pattern.
  Objective, not eyeballed.
- **Host scene tests** via `build_host_tests.sh`: emit a scene from a known map/frame; assert
  descriptor + cell-grid + pattern-table contents; assert per-layer draw order.
- **RTL sim** (`fpga/sim`): `tilemap_unit` grid walk vs. the same reference.
- **Fit**: confirm the real `frt_bram` block delta (§3.2).
- **STA**: seed sweep, compared against the +0.361 ns blitter-clock baseline (§3.3).

**Visual (must pass) — operator's eyes, never self-declared:**
- **Map 119 "Outside world C3"** — the parallax acceptance scene, the only map where parallax is
  load-bearing (295 parallax entries vs. 1 elsewhere), and conveniently small (640×752).
- **Map 3 "Outside world A3"** — 251 distinct patterns, the quest maximum; the map that pins the
  index-width and `MAXP` margin.

**Measured and recorded, NOT a gate:** `tilemap_unit` cyc/px on map 119. 60 fps is out of scope
for this stage (Stage 3 design §0.1); record the number so the throughput workstream starts from
a measurement rather than an estimate.

---

## 5. Process discipline

Every item is a recorded failure mode, not a precaution.

- **Build inside the container** — `scripts/docker_run.sh bash scripts/build_engine.sh` — and
  **grep `BUILD_EXIT`**, not the task exit code. Host builds leave a host-path `CMakeCache.txt`
  that blocks the container build. In-docker `git am` is flaky; patch on the host.
- **`mister_blitter_renderer.{cpp,h}` and `patches/mister/blitter/` are whole-file copies**, not
  in the patch series — edit directly. Use `export_patches.sh` for series changes.
- **Deploy** ships from `deploy/libs/`; **sha1-verify on device**. `deploy.py` exit 0 says
  nothing about which files moved.
- **HW gate:** leave `Solarus.s0` **empty**, load the core, launch with a private `S0_FILE`
  override — two concurrent engines wedge the host. Log to `/media/fat/logs/Solarus/`, never
  `/tmp`. **Never blind-inject joypad input.**
- **Confirm which RBF is loaded.** Multiple RBFs remain on the device; sending an opcode to a
  fabric with no arm for it falls through to the default FILL/BLIT branch and produces visible
  garbage that looks like a bug.
- **Treat OSD interaction as a hazard** — it ended two consecutive validation sessions.
- **CI:** the Windows RBF runner is flaky (run `29707947939` died with "runner has received a
  shutdown signal", not an RTL fault). Re-run rather than debug RTL on that signal.

---

## 6. Out of scope

- **60 fps / `comp_pipeline` throughput** — separate workstream.
- **`resident_` and flat-command removal** — Stage 4.
- **Clean-laning the source/upload path** (`upload()`/`handles`/INTER staging/`blt_alloc`).
- **`SelfScrollingTilePattern` support** — §2.7, pre-existing `res_fatal`.
- **Scanout** — unchanged direct `comp_fbram` path, not `MISTER_FB`/ascal.
- **#124** (overlay under-dims translucent menus) — open from Stage 1, unchanged here; cheap to
  fold into either HW cycle if wanted.

---

## 7. Evidence index

| Claim | Source |
|---|---|
| Stage 3a merged, base `97ae768` | `git log origin/master`, PR #128 |
| RAM 467/553 (84%), 86 free; bits 61%; ALM 34% | CI `29702887930` `Solarus.fit.summary` |
| Worst setup +0.155 ns; blitter clk +0.361 ns; TNS 0 | CI `29702887930` `Solarus.sta.summary` |
| Stage 3 design's +0.316 ns is stale | same file, direct read |
| Master RBF failure is a lost Windows runner | CI `29707947939` log tail |
| Static tiles are exactly pattern-sized | `work/solarus/src/entities/Entities.cpp:819-823` |
| Whole-map static enumeration exists | `NonAnimatedRegions.cpp:370-465`, dedup `:398-404` |
| Static path carries no pattern token | `mister_blitter_renderer.cpp:3717-3720` |
| Pattern identity is `TilePattern*` interned by `res_pat_index` | `Entities.cpp:1653`; `mister_blitter_renderer.cpp:3668-3690` |
| Parallax ratio is constexpr 2 | `include/solarus/entities/ParallaxScrollingTilePattern.h:55` |
| Emit-time camera/parallax bias formula | `mister_blitter_renderer.cpp:4021-4030`, `:4051-4059` |
| Per-frame animated table already exists | `Entities.cpp:1536-1550` |
| `SelfScrollingTilePattern` → `res_fatal` | `mister_blitter_renderer.cpp:3733-3741` |
| Rebuild edge = `resident_begin_frame` signature miss | `mister_blitter_renderer.cpp:3044`, `:3081-3120` |
| bgplane absent from upstream blitter | `grep -rn bgplane ~/MisterFPGA-Projects/mister-fpga-blitter/` → 0 hits |
| `frt_bram` sized `MAXP*MAXF`; `MAXP=128` = animated only | `blitter_top.sv:402`; `blitter_defs.vh:127` |
| `res_bias_x/y` is the scroll offset | `blitter_top.sv:684-685`, applied `:924-925` |
| 8px 100% aligned, 16px 30% | census over 64,155 placements |
| Max 251 distinct patterns (map 3); map 119 = 295 parallax entries | census |
| RBF builds with negative slack (`27c421c` −3.359 ns) | `2026-06-25-compositor-throughput-session.md:68` |
| Measured ceiling 19.9 fps, comp=75% | `2026-06-25-compositor-throughput-session.md:44-48` |
