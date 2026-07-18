# Retained-Scene Compositor + Framework Scanout — design

**Date:** 2026-07-17
**Status:** design approved (brainstorm), pending spec review → implementation plan
**Goal:** 60 fps target / 30 fps floor with functional correctness, by replacing the
imperative command-stream + reconstructed-cache renderer with a declarative
**retained scene** the fabric composites in Solarus's exact draw order, and moving
scanout to the MiSTer framebuffer framework (ascal).

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
burst WORK → DDR3 @FB_BASE                                    ← was: fbram_snapshot + openbor_video_reader
framework ascal: FB_BASE → scale → HDMI/analog, triple-buffered
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

## 3. Scanout — move to the MiSTer framework framebuffer (ascal)

**Delete** `openbor_video_reader`, `fbram_scan_adapter`, `fbram_snapshot`, and all
custom scanout/seam machinery (#44/#46 lived here — the most bug-prone fabric block).

**Framework FB contract** (`MISTER_FB=1` in the QSF; ports in
`emu`/`sys_top.v`): `FB_EN`, `FB_FORMAT[4:0]` (for RGB565: `[2:0]`=100 16bpp,
`[4]`=RGB, 565/1555 selected by `[3]` — pin the exact bit against `sys_top.v` at
Stage 0), `FB_WIDTH[11:0]`, `FB_HEIGHT[11:0]`, `FB_BASE[31:0]` (DDRAM byte base in the
`0x3000_0000` region), `FB_STRIDE[13:0]`, `FB_VBL`/`FB_LL` (in), `FB_FORCE_BLANK`.
Optional `MISTER_FB_PALETTE=1` exposes a 256-entry 24-bit CLUT (`FB_PAL_*`) — a
latent hardware path for the paletted work (#84/#120), not used in this design.

**Refinement (mandatory): do not composite per-pixel into DDR3.** That reintroduces
the per-pixel-RMW-over-DDR3 contention that #44/#46/PR #49 fought. Instead keep the
compositor on-chip and add **one burst per frame:**

```
comp_pipeline → comp_fbram WORK   (on-chip II=1 RMW — UNCHANGED)
        └─ fb_writeout: once/frame linear burst  WORK → DDR3 @FB_BASE
                └─ framework ascal reads FB_BASE → scale → HDMI/analog, triple-buffered
```

Only the finished 320×240 frame (~150 KB) makes one linear DDR3 round-trip per frame
(fabric burst write + ascal cached bursty read) — categorically different from
per-pixel RMW + custom scanout mid-composite.

**Wins beyond deletion:**
- **Frame pacing solved structurally.** ascal triple-buffers and resyncs input→output
  rate; the engine stops polling a vsync counter to hand-pace and just submits
  completed frames.
- **Free scaling / aspect (`VIDEO_ARX/ARY`) / scanlines / HDMI+analog** from the
  framework instead of fixed 320×240 raw-out.
- Step toward a standard-template core (currently forked from `OpenBOR_7533`).

**Tradeoff (accepted):** finished-frame pixels now live in DDR3, reversing the "no
frame pixels in DDR3/SDRAM" invariant. Worth it: framework-blessed pattern, one
linear burst not per-pixel traffic, buys the whole MiSTer video stack + pacing.

**Verify at implementation (not blocking design):** the `FB_LL` vs full-triple-buffer
latency choice; DDR3 contention against the A9 command-ring/audio traffic (expected
minor at one burst/frame).

**Out of scope:** audio stays on its current custom DDR ring; moving to framework
`AUDIO_*` is a separate later decision.

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
  9. fb_writeout: burst WORK → DDR3 @FB_BASE
Framework:
 10. ascal reads FB_BASE → scale → HDMI/analog, triple-buffered
```

On map change, add: rebuild per-layer index grids once (amortized across the map).

### Budget — pinned to the real clock

`comp_pipeline` runs on **`clk_sys` = 98.4375 MHz** (PLL `outclk_0`), which is also
`DDRAM_CLK`, and `clk_sdram` is the same 98.4375 MHz phase-shifted. Compositor, SDRAM
source reads, and the FB writeout therefore share one ~98.44 MHz domain — the
`fb_writeout → DDR3` path needs **no CDC**. Measured on-chip throughput: FILL ~1.05
cyc/px, COPY ~1.65 cyc/px (double-buffered `comp_src_linebuf` hides source latency).

Worst-case parallax overworld (per layer = 320×240 = 76,800 px):

| Work | Pixels | @1.65 cyc/px | @3.0 cyc/px (pessimistic tile-granular) |
|---|---|---|---|
| 3 tilemap layers | 230,400 | 3.9 ms | 7.0 ms |
| Sprites (~200×16²) | 51,200 | 0.9 ms | 0.9 ms |
| Overlay 320×240 | 76,800 | 1.3 ms | 1.3 ms |
| fb_writeout (150 KB burst) | — | 0.3 ms | 0.3 ms |
| **Total** | | **~6.4 ms** | **~9.5 ms** |

Against the 16.7 ms 60fps budget, the pessimistic column is ~9.5 ms — **~1.75×
headroom at the existing clock.** Conservative twice over: upper overworld layers are
sparse (transparent tiles skipped), and this is the worst scene.

**The clock is not the variable; tilemap fetch efficiency (cyc/px) is.** Raising the
clock above ~98 MHz is actively bad: it adds CDCs to the SDRAM read and DDR3 writeout
paths that are currently free; Cyclone V SE is already near the comfortable ~100 MHz
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
| Overlay upload vs ascal read | governed by `FB_VBL`/`FB_LL` handshake |

**Map-change path** is a well-defined event: rebuild index grids once, reset pattern
tables, clear sprite list. No render state carries across maps → removes the
*cumulative* failure mode (the class #84's cumulative-transition symptom lived in;
atlas residency #66 is orthogonal, unchanged).

---

## 7. Migration staging + testing

Ships as **env-gated stages, each independently HW-validatable and reversible.**
Ordering lands correctness wins early and cheap; the riskiest RTL (`tilemap_unit`)
lands last on a proven foundation.

| Stage | Change | Wins landed | Gate flag |
|---|---|---|---|
| **0 — Framework scanout** | swap only the tail: `fb_writeout` → `MISTER_FB`/ascal, fed from the **current** compositor; delete `openbor_video_reader`/`fbram_snapshot`; flat path otherwise unchanged | pacing fix + kills #44/#46, in isolation | build flag on old scanout until validated |
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

- `FB_LL` vs full-triple-buffer latency choice (Stage 0 HW measure).
- DDR3 contention: FB writeout + ascal read vs A9 command-ring/audio (Stage 0 HW measure).
- `tilemap_unit` real cyc/px + prefetch design (Stage 3 acceptance).
- Sprite cap value (generous, e.g. a few hundred) — set from worst-case official-quest census.
- Scratch SDRAM arena size for dynamic-source world blits (census official quests).
- Exact index-grid encoding + max map dims that fit the descriptor budget before per-layer fallback.

## References
- `docs/frame-dataflow.md` — current architecture (what this replaces).
- `work/solarus/src/entities/Entities.cpp:1509` — authoritative per-layer draw order.
- `patches/mister/mister_blitter_renderer.{h,cpp}` — current renderer + `resident_*` hooks.
- `fpga/Solarus.sv`, `fpga/rtl/comp_pipeline.sv`, `fpga/rtl/blitter_top.sv` — fabric; `clk_sys` at `fpga/rtl/pll/pll_0002.v`.
- `.claude/skills/misterfpga/reference/01-core-architecture.md` — `FB_*` framebuffer contract.
- `docs/superpowers/specs/2026-07-09-parallax-layer-compositor-design.md` — the bgplane design this supersedes.
