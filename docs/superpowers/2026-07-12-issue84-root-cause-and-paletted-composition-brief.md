# Issue #84 — Root Cause + Paletted-Composition Design Brief

**Date:** 2026-07-12
**Status:** Root cause CONFIRMED on HW. Near-term host fix scoped. Strategic
paletted-composition refactor ready for a dedicated brainstorming session (this
doc is its input).
**Related memory:** `solarus-84-root-cause-perm-restage`,
`solarus-84-luaconsole-teleport-repro`, `solarus-tileset-alpha-census-paletted`.

---

## 1. Executive summary

Issue #84 (cumulative map/tile corruption: static tiles missing, background
colour/garbage showing through, "water not blue / semi-transparent", sprites+HUD
unaffected) is **not** a bgplane bake/composite bug as the last issue comment
concluded. It is an **asset-residency bug in the shared source path**:

> Tileset surfaces are preloaded into SDRAM in a single **guessed** pixel format
> (ARGB4444, because their PNGs carry an alpha channel), but their tiles are
> drawn **opaque → RGB565**. The RGB565 variant misses the preload cache and is
> **re-staged fresh at gameplay (~0.75 MB per new tileset) into the permanent
> region's ~3.84 MiB headroom**. After ~5 distinct tilesets that headroom is
> exhausted and the next tileset's source offset **runs past the perm region →
> garbage source**. Both the bake and the per-bucket replay then faithfully draw
> garbage. Older (pre-overflow) tilesets stay correct.

This reproduces with the FPGA bake **ON and OFF** — proving the fault is
**upstream of the bake/replay split**, in the shared source-atlas residency.

The art census then revealed a clean strategic fix: the tilesets are **paletted
and ~99.7% binary-transparent**, so **paletted composition** (8bpp index atlas +
palette CLUT + a tiny index→alpha LUT) halves the source SDRAM, dissolves the
whole bug class, *improves* colour fidelity, and eases parallax fabric pressure.

---

## 2. Reproduction (self-service, no manual walking)

Solarus' built-in `-lua-console=yes` reads Lua from stdin and evals it live.
Drive it over a held-open FIFO to teleport through maps and trip the cumulative
bug on demand.

**Harness** (`/tmp/sol_repro.sh` on device — scratch copies also in the session
scratchpad): kill `quest_manager.sh` + `core_watch.sh` + `solarus-run`;
`mkfifo /tmp/sol_in`; `tail -f /dev/null > /tmp/sol_in &` (holds the write end so
the console `getline` never EOFs); env `SDL_VIDEODRIVER=dummy`,
`LD_LIBRARY_PATH=$GAMEDIR/libs:$GAMEDIR`, `HOME=/media/fat/saves/Solarus`,
`SOLARUS_BLITTER=1 SOLARUS_BLITTER_SINGLEBUF=1`, **`SOLARUS_BGPLANE=1`** (the
diagnosed path — WITHOUT it you reproduce a *different*, bake-off face),
`SOLARUS_BGPLANE_DIAG=1` (ARM base census), `SOLARUS_BLITTER_DIAG=1`
(`[blitter cvt] cold_upload MB` — the residency smoking gun); then
`setsid ./solarus-run -force-software-rendering -lua-console=yes /tmp/solarus_quest < /tmp/sol_in > /tmp/sol_repro.log 2>&1 &`.

**Start a game from the console (no menu nav):**
```lua
sol.main.game = sol.game.load("save1.dat"); sol.menu.stop_all(sol.main); sol.main:start_savegame(sol.main.game)
```
(saves at `/media/fat/saves/Solarus/.solarus/zsdx/save{1,2}.dat`).

**Teleport:** `sol.main.game:get_hero():teleport("<mapid>","<dest>")`. Dungeons
use `from_outside`; overworld/edge maps need a named dest or `_side0/1/2/3`
(E/N/W/S). `sol.main.game` is the running game (MoSDX `main.lua:90`).

**Trip it:** in a fresh session, teleport through **≥6 DISTINCT-tileset** maps.
One-map-per-tileset with good entrances:

| step | map | tileset | scene |
|---|---|---|---|
| 1 | 12  | 0  House            | Sahasrahla's House (`from_B1`) |
| 2 | 15  | 2  Ice              | Sahasrahla icy room (`from_B2`) |
| 3 | 88  | 4  Blue dungeon     | Castle Basement |
| 4 | 89  | 12 Castle           | Castle 1F |
| 5 | 23  | 5  Green dungeon    | First Dungeon (Forest) |
| 6 | 30  | 7  Brown dungeon    | Roc's Cavern / "Earth" — **FIRST BROKEN** |
| 7 | 40  | 14 Forest dungeon   | Arbor's Den (Dungeon 3) |
| 8+ | 47,58,60,105,16,128,109,3 | 9,10,11,15,3,8,16,1 | remaining |

**Observed:** steps 1–5 render correctly; **step 6 (Roc's) and every subsequent
new tileset are corrupt; already-loaded maps stay correct.** A "broken" map
loaded *first* in a fresh session renders fine — which is why isolated-map tests
falsely looked "resolved" before. The corruption is confirmed with bake ON and
bake OFF.

**Gotchas:** put Lua in a device-side script file, not nested ssh single-quotes
(literal `\"` leaks; a `print("x %s")` label breaks the *same* chunk). Restore
normal play by reloading the Solarus core from the OSD. Never self-declare a
frame visually clean — use the user's eyes or an objective probe.

---

## 3. Root cause — evidence chain

**3.1 It's not the bgplane arena.** With `SOLARUS_BGPLANE=1`, the
`[bgplane diag ARM]` census shows every map's plane bases **reset to
`0x05400000`** (arena start) — no cross-map leak — and no `escapes the arena` /
`arena exhausted` assert fires. Largest map (105) uses 27.8 MB of the 40 MB
arena and fits. The free-all-then-realloc per rebuild
(`mister_blitter_renderer.cpp:2911-2967`) works correctly.

**3.2 It reproduces bake ON and OFF.** The bake (ARGB4444 plane + PALPHA COPY)
and the per-bucket replay are near-disjoint render paths; both corrupt
identically ⇒ the fault is **upstream, in the shared source read** (resident
build + SDRAM source-atlas residency). This rules out the entire bgplane
bake/composite subsystem the last issue comment blamed.

**3.3 The shared source path re-stages tilesets at gameplay.** With
`SOLARUS_BLITTER_DIAG=1`, `[blitter cvt] cold_upload`:
- preload: **60.18 MB** staged once;
- **every first-visit tileset: ~0.5–0.9 MB cold upload** (cache MISS);
- **0.00 MB** on revisit (cache hit).

If the preload format matched the draw format, gameplay cold-upload would be ~0.
It isn't.

**3.4 The perm-headroom math matches the threshold exactly.**
- Perm region = 64 MiB (`SDRAM_PERM_BASE 0x01000000` → `SDRAM_INTER_BASE 0x05000000`).
- Preload used **60.16 MiB**, ending `0x04c29098` → **headroom = 3.84 MiB**.
- **3.84 MiB ÷ ~0.75 MB/tileset ≈ 5.1** → the **6th** distinct tileset overflows.
  Roc's was step 6. ✅

**3.5 The mechanism is documented in the code as the "residency's core bug"**
(`mister_blitter_renderer.cpp:1333-1339`):
- Preload guesses one format per surface:
  `SDL_ISPIXELFORMAT_ALPHA(pss) ? ARGB4444 : RGB565` (`:1341-1342`). Tileset PNGs
  carry an alpha channel → staged **ARGB4444**.
- Tiles draw opaque → RGB565 (`map_blend` per draw). `handles[{tileset,RGB565}]`
  misses (`upload()`, `:1471`) → fresh RGB565 upload, routed to **perm** because
  the surface is immutable (`is_immutable → blt_stage_surface_perm`, `:1555`).
- The overflowing offset "ran past the perm region" → garbage. Frames still
  **commit** (garbage, not frozen — animated water updates over it), so it is a
  *runaway offset*, not a hard `perm_overflow` latch
  (`committed = !perm_overflow`, `:3423`, would freeze instead).

**Every symptom explained:** ~5–6 distinct-tileset threshold; older-fine /
newer-broken (grow-only, pre-overflow valid); order-dependent; load-first-works
(false-negative isolated repros); bake on & off; not reset per map (perm never
freed); "which map breaks varies" (depends on load order + sizes).

---

## 4. Art census — the input for the strategic fix

Measured from `data/tilesets/*.tiles.png` (host: ffmpeg alpha-plane extract +
direct PNG PLTE/tRNS parse).

- **19 of 20 tilesets are `pal8`** (8-bit indexed, ≤134 colours each). Only
  **ts9** is rgba (258 distinct RGBA — 2 over 256; same alpha pattern;
  palettizable once alpha is factored out, else a direct-colour fallback for one
  tileset).
- **Transparency is ~99.7% binary** (a0 transparent / a255 opaque). Aggregate
  partial-alpha = **0.29%** of pixels.
- **ALL partial-alpha is exactly 3 palette indices per tileset, always the same
  3 blue water shades** `(88,96,232) (104,112,240) (152,176,255)` — translucent
  water drawn as half-alpha palette colours (confirms "water is the apartial
  content, the compositor blends it"). Overworld ts1 = 0 partial (opaque water).
- **Only TWO partial-alpha values in the entire quest: 127 (50%) and 191 (75%,
  ts2 Ice / ts8).** With 0 and 255 → **4 alpha levels total = 2 bits.**

Per-tileset partial indices (index:alpha:rgb) for reference:
```
ts0  7,8,9      a127   ts10 32,33,34  a127
ts2  28,29,30   a191   ts11 45,46,47  a127
ts3  15,16,17   a127   ts12 67,68,69  a127
ts4  23,24,25   a127   ts14 28,29,30  a127
ts7  32,33,34   a127   ts15 18,19,20  a127
ts8  21,22,23   a191   ts17 28,29,30  a127
ts9  (rgba) water a127 ts18 37,38,39  a127
                       ts19 37,38,39  a127
ts1,5,6,13,16: no partial
```

### 4.1 Tile-level dedup potential (8×8 grain, all 20 tilesets)

Measured by chopping every tileset into 8×8 blocks and hashing both the exact
pixels and a palette-independent canonical shape (relabel colours by first
appearance).

| metric | value |
|---|---|
| total 8×8 blocks | 61,056 |
| distinct **exact** (pixels+palette) | 18,688 → **~69% exact duplicates** |
| distinct **canonical** (shape, any palette) | 6,377 → **~90% redundant by shape** |
| canonical shapes reused across >1 tileset | **3,003** (LW/DW-style palette reuse) |
| distinct non-trivial (>1 colour) shapes | 6,376 |

**Whole-tileset** palette-swaps do NOT exist (ts4/ts8, ts5/ts9, ts17/18/19 differ
in layout + colour count) — the reuse is at the **tile** grain. Two tiers:
- **Exact dedup (~69%)** needs no palette work — content-hash tiles, share one
  copy. Near-free, independent of the refactor.
- **Palette-variant dedup (the extra ~20%)** is the "same shape, different
  palette" case — it *requires* paletted composition to exploit.

**Caveats:** ratios are inflated by empty/solid atlas regions (the all-transparent
block repeats thousands of times). And **tilesets are only ~7.5 MiB of the 60 MiB**
staged atlas (3.9 M px × 16bpp) — the other ~53 MiB is **sprites/menus, not yet
analysed**. So tileset dedup reclaims a few MiB; the headline lever remains the
16→8bpp paletted halving across *all* assets, with dedup compounding on top
(sprite dedup TBD). Granularity (8×8 vs Solarus pattern rects from the `.dat`) and
build-time vs runtime dedup are open design choices.

### 4.2 Entities + sprites alpha census (resolves open Q1)

Same method over the 20 tileset `NN.entities.png` and all 220 `sprites/**/*.png`:

- **Tileset `entities.png` (20): 0% partial — 100% binary.**
- **Sprites (220): only 4 files partial**, all at a single value **a=119** (0.085%
  of sprite pixels) — and they are `sprites/entities/dark0-3.png`, the **dungeon
  darkness overlay** (a screen-space translucent-black effect, not a per-tile
  source; can be special-cased out of the tile alpha LUT).

**Complete quest-wide partial-alpha set = {119, 127, 191}** → with 0 and 255,
**5 alpha levels total → a 3-bit alpha LUT covers the entire quest exactly** (or
store 8-bit alpha/index; 256 B regardless). Partial alpha is a rounding error in
every asset class; >99.7% of everything is binary (colorkey). The transparency-LUT
approach is confirmed across tiles, entities, and sprites.

**Entities dedup (8×8, 20 `entities.png`)** — even more redundant than tiles:
total 35,376 blocks → **12,323 distinct exact (65% dup)** → **1,010 distinct
canonical shapes (97% shape-redundant)**, with **670 shapes reused across >1
tileset**. Only ~1,010 distinct meaningful entity shapes across all 20 tilesets =
the same doors/pots/switches/chests recoloured per tileset palette. Absolute size
is small (2.16 → 0.75 exact → 0.06 canonical MiB at 8bpp) but the redundancy is a
strong argument for paletted composition.

### 4.3 Sprite dedup + palette census

**Palette census (220 sprites, all pal8 — no truecolor anywhere except tileset 9):**
per-category union distinct colours — enemies 346, entities 542, hero 93, hud 166,
menus 323, npc 236. **Per-sprite palettes are small** (median 6–15 colours; hero
max 34, enemies 68). Gameplay union = 1,145 colours (>256, so not one shared
palette, but ~5 banks cover *all* gameplay; per-frame far fewer are live). → per-
frame palette-bank pressure is modest; sub-palette packing (multiple small sprite
palettes into one 256 bank via a per-blit base offset) is viable.

**Dedup (8×8):** total 302,083 blocks (18.4 MiB @ 8bpp) → **39,840 distinct exact
(87% dup)** → **23,910 distinct canonical (92%)**. **Caveat:** heavily inflated by
transparent animation-strip padding (only ~25% of blocks are non-trivial; real
content dedup ~68%). That inflation is itself a finding: much of current sprite
SDRAM is transparent padding staged at 16bpp → **frame trim/pack is a large win
independent of paletting.**

### 4.4 Combined atlas footprint (tiles + entities + sprites, ~48 MiB @ 16bpp today)

| | 16bpp today | 8bpp paletted | +exact dedup | +palette-variant |
|---|---|---|---|---|
| MiB | ~48 | ~24 | ~4.3 | ~1.9 |

Even discounting the whitespace inflation, **paletting + exact-dedup + frame-trim
takes the atlas from ~48 MiB to well under 10 MiB** — freeing most of the 60 MiB
region and dissolving #84's 4 MiB deficit many times over. Uniform pal8 (one rgba
outlier), ≤3-bit alpha, small sprite palettes → the whole pipeline is clean.

---

## 5. Fork video-pipeline reality (checked against RTL)

There is **no palette LUT anywhere in the fabric** — do not plan around one:
- `fpga/sys/video_freak.sv` = stock geometry only (crop / integer-scale /
  aspect; Grabulosaure/Melnikov). No colour path.
- Repo-wide grep for `palette|clut|color_lut|pal_ram` across the fabric →
  nothing.
- Only output-path LUTs are `fpga/sys/gamma_corr.sv` / `gamma_fast` =
  **per-channel gamma ramps** (`gamma_curve_r/g/b[256]`, 8-bit value → 8-bit
  value). Usually disabled — likely the "two disabled LUTs" recollection — but
  they are gamma, not palettes, and cannot do index→RGB.

**Location matters:** an output-stage LUT sits *after* compositing, so it only
works if the whole frame is a single ≤256-colour global palette. MoSDX mixes a
per-tileset palette + per-sprite palettes (>256/frame), so an output-stage
palette is a non-starter. The memory win requires a **source-stage** CLUT inside
`comp_pipeline` with **per-blit palette selection** — new RTL regardless.

---

## 6. Proposed architecture — paletted composition + transparency LUT

```
8bpp index atlas in SDRAM  (~30 MiB, half of today's 60 MiB
                            → dissolves #84 with ~30 MiB spare)
        │
 comp_pipeline source read:
     index ─┬─► palette CLUT  → RGB565   (full 5-6-5; better than ARGB4444's 4-4-4-4)
            └─► alpha   LUT   → a ∈ {0,127,191,255}   (2-bit is enough for tiles)
        │
     blend into the RGB565 framebuffer
        │   one path for opaque / colorkey / translucent-water
        ▼   NO ARGB4444, no dual-format, no preload format guess, no perm re-stage
```

**Why it beats the alternatives:**
- vs today (dual RGB565/ARGB4444 + guess): removes the guess and the re-stage —
  the bug's cause — and halves source SDRAM.
- vs "everything ARGB4444": ARGB4444 is 4-bit/channel → colour banding on opaque
  tiles; paletted keeps full RGB565 and uses *half* the memory.
- vs "everything RGB565+colorkey": can't express the 127/191 water; the alpha LUT
  handles it exactly.

---

## 7. Open questions for the brainstorm (#2)

1. ~~**Sprite/entity alpha + palette + dedup census.**~~ **RESOLVED (§4.2–4.4):**
   entities 100% binary; sprites only `dark0-3` at a=119 → quest-wide alpha
   {119,127,191} → **3-bit alpha LUT**. All sprites pal8 with small palettes
   (≤68; hero ≤34). Sprite dedup 87% exact / 92% shape (inflated by strip padding
   → frame-trim is a separate win).
2. **Palette selection granularity.** A map = 1 tileset palette; sprites carry
   their own small ones (gameplay union 1,145 colours ≈ ~5 banks total, fewer
   live/frame). Options: multiple palette banks vs reload-on-switch vs per-blit
   palette id **+ sub-palette base offset** (pack several small sprite palettes
   into one 256 bank). Open: exact per-frame live-palette count (needs a runtime
   probe or a per-map static estimate) to size the bank count.
3. **CLUT + alpha-LUT storage/upload.** 256×RGB565 = 512 B + alpha (2–4 bit) per
   palette; where do they live (BRAM banks), and how are they uploaded/staged and
   kept in sync with the index atlas across map transitions?
4. **comp_pipeline read-path change.** Insert index→{RGB,alpha} lookup before the
   blend; latency/timing impact on the issue-interval-1 compositor; STA.
5. **Hybrid for non-paletted sources** (ts9 rgba; any true-colour sprite): keep a
   direct-colour path, or palettize offline? Cost of one fallback format vs a
   uniform pipeline.
6. **Wire protocol / host changes.** Stage 8bpp indices + palettes; emit palette
   ids; the `blt_emitter` / tile-list ABI bits; preload changes (no format guess).
7. **Migration & risk.** Land behind a flag; regression test that is *cumulative
   multi-tileset* (a single-map test cannot catch this class — the whole reason
   #84 looked resolved).
8. **Interaction with the bake.** The bgplane plane is ARGB4444 today; with
   paletted sources, does the bake composite in index space, or resolve to RGB at
   bake time? How does per-layer occlusion (binary alpha) coexist with water
   (127/191)?

---

## 8. Near-term host-only fix (independent of #2, ships #84)

Options (pick 1, keep it small + flagged + regression-tested):
- **A. Fix the `:1341` guess for tilesets** — stage RGB565 (they draw opaque
  despite the alpha channel); let the rare water tiles re-stage ARGB4444. Directly
  kills the measured 0.75 MB/tileset re-stage.
- **C. Give the immutable gameplay re-stage a bounded home** — route it to a
  recycled region (or reserve perm gameplay-restage headroom) so a re-stage can
  never run past perm.
- Recommended: A, with C as a backstop, plus the cumulative regression test.

---

## 9. Key code references

- `patches/mister/mister_blitter_renderer.cpp`
  - Preload format guess (root cause): `:1333-1343` (esp. `:1341`)
  - `SOLARUS_PRELOAD=0` lazy-correct-format path: `:1303-1305`
  - Preload walks all PNGs, marks immutable: `:1321-1331`
  - `upload()` source staging (perm vs inter): `:1471`, `:1552-1558`
  - `forget_surface` / recycled-slot free: `:880-895`
  - SDRAM region layout (PERM/INTER/BGPLANE): `:274-312`
  - `bgplane_enabled = getenv("SOLARUS_BGPLANE")`: `:1887`
  - bgplane arena free-per-rebuild + alloc + asserts: `:2903-3018`
  - `committed = !perm_overflow`: `:3423`
  - Diag banner (`uploads=`, `cold_upload MB`): `:3463-3488`
- `fpga/sys/video_freak.sv` (geometry only), `fpga/sys/gamma_corr.sv` (per-channel
  gamma, not a CLUT)

## 10. Device / session state

Engine left running in repro mode on `192.168.20.81` (watchers stopped, parked
mid-route). Reload the Solarus core from the OSD to restore normal auto-launch.
Scratch scripts: `sol_repro.sh`, `sweep.sh`, `route.sh`, `route2.sh`,
`alpha_census.py` in the session scratchpad.
