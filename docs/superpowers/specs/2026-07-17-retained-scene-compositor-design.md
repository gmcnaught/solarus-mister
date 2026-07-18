# Retained-Scene Compositor — design

**Date:** 2026-07-17 (rev. 2026-07-18: scanout kept on the direct path, ascal/`MISTER_FB` dropped — see §3)
**Status:** design approved (brainstorm), pending spec review → implementation plan
**Goal:** 60 fps target / 30 fps floor with functional correctness, by replacing the
imperative command-stream + reconstructed-cache renderer with a declarative
**retained scene** the fabric composites in Solarus's exact draw order. Scanout is
unchanged — the existing on-chip `comp_fbram` → direct VGA pixel-stream path stays
(NOT the async ascal framebuffer; see §3).

---

## 1. Problem statement — why the current architecture fights us

Every open correctness problem traces to **one decision**: the fabric is fed by
hooking Solarus at `SDLRenderer::draw/fill/clear` — the point where the engine has
already *flattened* its structured world (tilemap layers, sprite lists, parallax)
into anonymous per-surface blits. All the downstream machinery (`resident` tile
lists, `bgplane` bakes) exists to **reconstruct structure the engine already knew
and threw away**. The bugs live in that reconstruction:

| Symptom | Root cause (this design removes it) |
|---|---|
| Resident-tile wrong at some locations | coherence bug in a reconstructed tile-list cache |
| bgplane transparent-tile garbage | coverage/ARGB4444 packing bug in a reconstructed static-layer bake |
| Menu / intro / dialog not offloaded | draws that never hit `fpga_target`/`alias_target`, fall through to base SDL, vanish |
| Parallax ~15 fps (fabric-bound) | 1500 static BLENDs re-composited every frame — flat stream has no "scrolling layer" concept |
| Inconsistent frame pacing | A9 does large, variable per-frame emit + cache maintenance; hand-paced off a vsync counter |

**Two independent bottlenecks, only one is a rendering problem.** Profiling splits
scenes into *fabric-bound* (parallax ~15 fps, 1500 BLEND/frame) and
*A9/simulation-bound* (town ~29 fps, enemy AI/Box2D/Lua ~78% of frame). A rendering
re-architecture crushes the fabric-bound class and the render-*emit* part of the A9
class. It **cannot** fix pure simulation cost — that stays with the engine levers
already winning (LuaJIT, audio thread, Box2D walk). The design keeps the two axes
cleanly separable.

**Scope decisions (from brainstorm):**
- Appetite: **clean-slate target architecture OK** (change both the engine hook
  point and the fabric tail).
- Compatibility bar: **optimize for official Solarus-team quests, exploit their
  structure**; software overlay is the universal catch-all so anything unusual
  degrades to *slower*, never *wrong*. Not pixel-exact vs upstream.

---

## 2. Target architecture — the Retained-Scene model

The A9 rebuilds a **declarative scene from engine truth every frame**; the fabric
composites it into the existing on-chip BRAM framebuffer **in Solarus's exact draw
order**, then a single burst hands the finished frame to the MiSTer framework FB
(ascal) for scaling + tear-free scanout. Nothing is "baked"; nothing is
"invalidated." The scene is cheap because it is descriptors, not pixels.

Three primitive kinds, matching three confirmed engine seams:

| Primitive | Source of truth | A9 sends per frame | Fabric does |
|---|---|---|---|
| **Tilemap layer** | `Entities` per-layer tile grid + `scroll_ratio` | descriptor (tileset, W×H pattern-index grid, blend, **scroll offset**); grid only on map change; **per-frame: only the scroll offset** | walks the visible grid window, indirects pattern→src in the SDRAM atlas, composites at `dst = tile_pos − scroll` |
| **Sprite** | ordered blits onto the camera surface (`entities_to_draw`, Y-sorted, + custom/Lua world draws) | compact sprite list (src rect, dst x/y, blend, layer, y-key), rebuilt each frame from culled entities | composites each after that layer's tiles |
| **Overlay** | everything else — HUD, menu, dialog, intro, title, transitions, arbitrary Lua `surface:draw` | one ARGB overlay surface, base-SDL software rendered, uploaded when dirty | composited **last**, on top, per-pixel alpha |

The fabric's per-frame loop is literally `Entities::draw` order (verified at
`work/solarus/src/entities/Entities.cpp:1509`):

```
for layer in min..max:
    composite tilemap[layer]   (scroll applied at fetch)      ← was: bgplane bake
    composite sprites[layer]   (in emission/Y order)          ← was: alias_target replay
composite overlay                                             ← was: the surfaces that went missing
snapshot WORK → SCAN at vblank                                ← unchanged (tear-free double-buffer)
(display path UNCHANGED: comp_fbram → openbor_video_reader/timing → VGA live stream → framework HDMI scaling)
```

**Why this dissolves the bug classes:**
- **bgplane bake → gone.** A static layer is a tilemap descriptor whose scroll never
  changes; the fabric re-walks it from the atlas each frame. A transparent tile is
  simply not composited — no ARGB4444 coverage packing, no transparent-tile edge case.
- **Resident-cache coherence → gone.** The grid is a faithful copy of engine data,
  re-sent on the well-defined map-change event, never heuristically patched.
- **Aliased surfaces → gone.** "Anything not tilemap/sprite" is *defined* as overlay,
  always composited. No `fpga_target`/`alias_target` special-casing to fall through.
- **Parallax saturation → gone.** Parallax = a different scroll offset per layer, one
  composite pass, not 1500 re-emitted BLENDs.

**Z-order fidelity is free.** Compositing in `Entities::draw` order — per layer,
tiles then Y-sorted sprites — reproduces Solarus layering exactly, including the
intra-layer Y-sorted tile/sprite interleave that a scanline PPU could not. This is
the decisive reason to composite-per-frame into BRAM rather than scan-time layer mix.

**Animation without a cache.** The grid stores static **pattern indices**. A tiny
per-frame **pattern→src-rect table** maps each pattern to its current animation
frame (exactly what `resident_update(token, cur_src, …)` already computes). The
fabric indirects grid → pattern-table → SDRAM src. Animation updates a ~hundred-entry
table, a *direct function* of animation state — no invalidation heuristic.

**Reused unchanged (validated investment):** `comp_pipeline` blend math,
`comp_fbram` WORK image + on-chip II=1 RMW, SDRAM whole-quest atlas residency (#66),
the double-buffered `comp_src_linebuf`.

---

## 3. Scanout — unchanged (keep the direct on-chip pixel stream; NOT ascal FB)

**Scanout is not touched by this design.** The finished frame stays on-chip in
`comp_fbram` and reaches the display via the existing direct path: the vblank
WORK→SCAN snapshot (`fbram_snapshot`, tear-free double-buffer) → `openbor_video_reader`
(drives `VGA_R/G/B`) + `openbor_video_timing` (drives `CLK_VIDEO/CE_PIXEL/VGA_HS/VS/DE`)
→ the framework's `video_mixer`/`video_freak` → sys_top, which scales the **live pixel
stream** for HDMI (analog VGA is driven directly).

**Explicitly NOT the MiSTer framebuffer (`MISTER_FB`/ascal).** An earlier revision of
this spec proposed moving scanout to a DDR3 framebuffer read by the framework's ascal
scaler; that was **rejected**. ascal is an **asynchronous** scaler — `MISTER_FB` makes
the core write a DDR3 framebuffer that ascal resamples on its own clock, a path meant
for cores with irregular frame timing or non-standard resolutions. For a fixed,
synchronous 320×240 2D core it only adds a DDR3 round-trip + async-scaler latency for
no benefit. The direct path already gets framework HDMI scaling (from the live stream),
and since FB-in-BRAM (PR #49) the on-chip scanout already eliminated the #44/#46 seam
class. (It was also learned that the `0x3A000040` FB0/FB1 DDR3 range is remapped to
SDRAM by `vram_demux`, so it was never a clean DDR3 framebuffer target anyway.)

**Consequences for this design:** no `fb_writeout`, no DDR3 framebuffer, no `FB_*`
wiring, no `MISTER_FB`. The retained-scene channels feed `comp_pipeline` → `comp_fbram`;
the display path consumes `comp_fbram` exactly as it does today. Frame pacing is
addressed by the retained-scene work itself — collapsing per-frame A9 emit from
thousands of draws to a sprite list + scroll removes the frame-time *variance* that
made pacing ragged, a more fundamental fix than an async scaler's triple buffer.

**Out of scope:** audio stays on its current custom DDR ring.

---

## 4. Component boundaries and the host↔fabric contract

One channel per primitive, each with a single responsibility and a narrow interface —
this is what makes each independently testable, versus today's single renderer where
`resident` stores, `bgplane` bakes, and `alias_target` all touch the same DDR state.

### Host (A9 / C++)

`MisterBlitterRenderer` still subclasses `SDLRenderer` (required to *be* the draw
singleton), but its body becomes a thin **router** into a `SceneAssembler`:

| Component | Responsibility | Fed by (engine seam) | Interface out |
|---|---|---|---|
| **TilemapChannel** | per-layer `TileGrid` descriptors (tileset, W×H pattern-index grid, blend, `scroll_ratio`); rebuilt **only on map change** | evolved `resident_record_static` / `resident_begin_frame` (already walks the grid) | descriptor table + index grids → DDR3 |
| **SpriteChannel** | ordered per-frame list of **all camera-surface blits** (entities + custom `on_draw` + Lua world draws); Z-correct by emission order | camera-surface draws (existing `draw()` classification) | sprite list → DDR3 |
| **OverlayChannel** | render everything-not-world (HUD/dialog/menu/intro/transitions/Lua screen draws) via **stock base SDL** into one ARGB surface | draws to the root/screen surface that aren't the camera composite | overlay surface → DDR3 (upload when dirty) |

`present()` writes the per-frame delta and rings one doorbell.

**Cheapness property:** across a stable map the grids never change. Per frame the A9
writes only: sprite list + scroll offsets + pattern→src table + overlay-if-dirty —
kilobytes, versus thousands of tile draws today. This is *why* pacing gets uniform
and the A9 render cost collapses.

### Fabric (RTL)

| Component | Responsibility | Replaces |
|---|---|---|
| **scene_walker** | reads the scene; per layer drives `tilemap_unit` then `sprite_unit`; then `overlay_unit`; then `fb_writeout` | flat ring decoder + TILELIST expansion + all bgplane/`OP_BGPLANE_WRITE` logic |
| **tilemap_unit** (new, clean) | walks the visible window of a grid, indirects pattern→src, computes `dst = pos − scroll`, streams composite ops | bgplane bake + static-bucket replay |
| **sprite_unit** | streams the sprite list as composite ops | `alias_target` blit replay |
| **overlay_unit** | composites the overlay surface, per-pixel alpha, on top | (new — ends missing surfaces) |
| **comp_pipeline → comp_fbram WORK** | blend + on-chip RMW | **unchanged** |
| **fb_writeout** (new) | burst WORK → DDR3 `FB_BASE`; drives `FB_*` | `fbram_snapshot` + `openbor_video_reader` (deleted) |

### Host↔fabric contract (DDR3 scene layout)

The interface is **data**, not a replayed command stream — which is what makes both
sides independently testable:

- **Tilemap descriptor table** — per layer: SDRAM atlas base, grid dims, tile size,
  blend, **scroll x/y**, ptr to index grid. *(scroll is the only per-frame field)*
- **Tile index grids** — per layer, W×H pattern indices. *(map-change only)*
- **Pattern→src table** — pattern id → current src rect. *(per frame, small)*
- **Sprite list** — bounded array of sprite records. *(per frame)*
- **Overlay surface** — ARGB 320×240. *(upload when dirty)*
- **Scene control block + doorbell** — frame seq, per-layer enable, overlay-dirty,
  scroll offsets.

---

## 5. Data flow through a frame + performance budget

### Steady-state sequence (no map change)

```
A9 per frame:
  1. engine simulates (Lua/entities/Box2D)          ← residual cost, unchanged
  2. tick animations → update pattern→src table      ← ~100 entries
  3. cull entities → build sprite list (capped)      ← tens–low hundreds
  4. write scroll offsets per layer (parallax = different offset per layer)
  5. if HUD/menu/dialog changed → base-SDL render overlay, mark dirty
  6. write scene control block, ring doorbell         ← one submit
Fabric per frame:
  7. scene_walker per layer: tilemap_unit → comp_pipeline → WORK
                             sprite_unit  → comp_pipeline → WORK
  8. overlay_unit → WORK
  9. snapshot WORK → SCAN at vblank (tear-free)
Display (unchanged):
 10. comp_fbram → openbor_video_reader/timing → VGA live stream → framework HDMI scaling
```

On map change, add: rebuild per-layer index grids once (amortized across the map).

### Budget — pinned to the real clock

`comp_pipeline` runs on **`clk_sys` = 98.4375 MHz** (PLL `outclk_0`); `clk_sdram` is
the same 98.4375 MHz phase-shifted, so the compositor and its SDRAM source reads share
one domain. Measured on-chip throughput: FILL ~1.05 cyc/px, COPY ~1.65 cyc/px
(double-buffered `comp_src_linebuf` hides source latency).

Worst-case parallax overworld (per layer = 320×240 = 76,800 px):

| Work | Pixels | @1.65 cyc/px | @3.0 cyc/px (pessimistic tile-granular) |
|---|---|---|---|
| 3 tilemap layers | 230,400 | 3.9 ms | 7.0 ms |
| Sprites (~200×16²) | 51,200 | 0.9 ms | 0.9 ms |
| Overlay 320×240 | 76,800 | 1.3 ms | 1.3 ms |
| **Total** | | **~6.1 ms** | **~9.2 ms** |

Against the 16.7 ms 60fps budget, the pessimistic column is ~9.2 ms — **~1.8×
headroom at the existing clock.** Conservative twice over: upper overworld layers are
sparse (transparent tiles skipped), and this is the worst scene.

**The clock is not the variable; tilemap fetch efficiency (cyc/px) is.** Raising the
clock above ~98 MHz is actively bad: it adds a CDC to the SDRAM read path that is
currently free; Cyclone V SE is already near the comfortable ~100 MHz
ceiling on this SDRAM-bound design (negative-slack builds have occurred); and the
compositor is memory-bound, so a faster clock just stalls more on SDRAM. ~98 MHz tied
to the memory clock is the MiSTer/jtcores sweet spot.

### Goal, honestly bucketed

- **Fabric-bound (parallax/overworld):** → 60. ✅
- **A9 render-emit-bound:** per-frame emit collapses to sprite list + scroll → moves
  toward 60. ✅
- **Simulation-bound (enemy AI/Box2D/Lua):** unchanged by rendering; rides the engine
  levers. Realistic landing **stable 30+, toward 60 as simulation levers land** — the
  60-target/30-floor framing, with the two axes kept separable.

---

## 6. Fallback boundary + error handling

Every draw that does not fit gets a bounded, logged fallback — never silently wrong.

**Classification is by surface, which makes Z automatic:**
- Camera-surface draws = world → **SpriteChannel** (ordered stream of *every*
  camera-surface blit, so arbitrary world draws land at correct Z by emission order —
  no priority encoding).
- Root/screen-surface draws = UI → **OverlayChannel** (composited last, on top).

**Two refinements that delete existing bugs by construction:**
1. **Transitions and fades are overlay effects.** During a scroll/fade transition the
   engine software-composites into the overlay and the world channels idle.
   Structurally eliminates **#122** (bgplane hold-frame) and **#123** (scroll black
   flicker) — with no bake and a software transition, neither can occur. Fade-to-black
   is a full-screen overlay alpha.
2. **Dynamic-source world blits stage to a bounded scratch SDRAM arena** and stream as
   sprites (preserves Z). The one dynamic-upload path kept, bounded + logged.
   Everything else sources from the #66 resident atlases.

**Overflow / degradation (all defined, all logged):**

| Condition | Behavior |
|---|---|
| Sprite list exceeds cap | composite up to cap in order; drop the tail; `log()` dropped count |
| A tilemap layer's grid exceeds descriptor budget (huge map) | that **layer alone** falls back to ordered sprite-stream replay; other layers unaffected (mirrors today's graceful per-layer bgplane fallback) |
| Dynamic-source scratch arena full | skip the offending blit; `log()`; bounded |
| Overlay upload mid-composite | overlay surface uploaded to DDR3 before the doorbell; `overlay_unit` composites it within the frame (no scanout race) |

**Map-change path** is a well-defined event: rebuild index grids once, reset pattern
tables, clear sprite list. No render state carries across maps → removes the
*cumulative* failure mode (the class #84's cumulative-transition symptom lived in;
atlas residency #66 is orthogonal, unchanged).

---

## 7. Migration staging + testing

Ships as **env-gated stages, each independently HW-validatable and reversible.**
Scanout is untouched (§3) — every stage feeds the existing on-chip `comp_fbram`
display path. Ordering lands correctness wins early and cheap; the riskiest RTL
(`tilemap_unit`) lands last on a proven foundation.

| Stage | Change | Wins landed | Gate flag |
|---|---|---|---|
| **1 — Overlay channel** | route screen-space + transition draws to `OverlayChannel` | **aliased surfaces fixed; #122/#123 deleted** — independent of tilemap work | `SOLARUS_OVERLAY=0` |
| **2 — Sprite channel** | replace `alias_target` replay with ordered `SpriteChannel` + `sprite_unit` | sprites Z-correct; sprite cap+log | `SOLARUS_SPRITECH=0` |
| **3 — Tilemap channel** | replace `resident`/`bgplane` with `TilemapChannel` + new `tilemap_unit`; **delete the bake** | parallax → 60; resident-cache + bgplane bugs gone | `SOLARUS_TILEMAPCH=0` |
| **4 — Delete dead paths** | remove bgplane, resident caches, flat-command remnants once 0–3 validated | the tangle is gone | — |

**Stage-3 acceptance measurement:** measure `tilemap_unit` cyc/px on the parallax
overworld; **target ≤ 3.0 cyc/px on a full layer; lever = prefetch (burst multiple
tiles, wider linebuf, skip-transparent), never clock.**

### Testing strategy

A *data* interface (grids/lists/surface) tests mostly without hardware:
- **Host-only scene tests** (extend `tests/run_tests.sh`): emit a scene from a known
  map/frame; assert descriptor + index-grid + sprite-list contents. Models
  engine-side logic like the existing host suite; no renderer compile.
- **Bit-exact unit checks:** `tilemap_unit` grid walk vs a host reference walker (the
  #24 arena-probe 60/60 pattern — objective, not eyeballed).
- **Full-datapath fabric sim:** scene → framebuffer, structural-diff vs a golden from
  **stock Solarus software render** of the same frame (tolerance for blend rounding;
  bar is "exploit structure," not pixel-exact).
- **Per-stage HW gate:** user's eyes + an objective signal (FB frame counter / mrext
  screenshot). Honors the "never self-declare visual correctness" rule; no stage
  advances on the agent's say-so.
- **Perf validation:** fabric HW cycle counters per scene type, confirming the §5
  budget on the real 98.44 MHz clock (parallax overworld = the acceptance scene).

---

## 8. Open items to resolve during planning / implementation

- `tilemap_unit` real cyc/px + prefetch design (Stage 3 acceptance).
- Sprite cap value (generous, e.g. a few hundred) — set from worst-case official-quest census.
- Scratch SDRAM arena size for dynamic-source world blits (census official quests).
- Exact index-grid encoding + max map dims that fit the descriptor budget before per-layer fallback.

## References
- `docs/frame-dataflow.md` — current architecture (what this replaces).
- `work/solarus/src/entities/Entities.cpp:1509` — authoritative per-layer draw order.
- `patches/mister/mister_blitter_renderer.{h,cpp}` — current renderer + `resident_*` hooks.
- `fpga/Solarus.sv`, `fpga/rtl/comp_pipeline.sv`, `fpga/rtl/blitter_top.sv` — fabric; `clk_sys` at `fpga/rtl/pll/pll_0002.v`.
- `docs/superpowers/specs/2026-07-09-parallax-layer-compositor-design.md` — the bgplane design this supersedes.
- Memory `solarus-scanout-avoid-ascal-direct-path` — why scanout stays direct (not ascal).
