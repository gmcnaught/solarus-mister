# Paletted Composition v1 — Design (Issue #84, strategic fix)

**Date:** 2026-07-12
**Branch:** `feat/paletted-composition`
**Status:** Design — awaiting review.
**Input brief:** `docs/superpowers/2026-07-12-issue84-root-cause-and-paletted-composition-brief.md`
**Related:** host-only #84 fix on `fix/issue-84-host-restage` (parallel, ships #84 first);
memories `solarus-84-root-cause-perm-restage`, `solarus-tileset-alpha-census-paletted`.

---

## 1. Goal & scope

**Goal.** Replace the immutable `pal8` PNG assets' SDRAM residency with an **8bpp
index atlas + on-chip palette CLUT**, so the compositor reads a 1-byte index per
source pixel and expands it to `{A4, RGB565}` via a per-blit-selected CLUT bank.

**Why (three wins, one root cause).**
1. **Dissolves #84's whole bug class.** The residency overflow (#84) is a
   *footprint* problem: the whole-quest atlas is ~60 MiB in a 64 MiB perm region
   (3.84 MiB headroom → the 6th distinct tileset re-stages past perm → garbage).
   Storing sources at 8bpp **halves** the atlas (~48→~24 MiB across tiles +
   entities + sprites), turning a 3.84 MiB deficit into tens of MiB of headroom.
   The format-guess/re-stage mechanism disappears because there is one source
   format, not a guessed RGB565-vs-ARGB4444 pair.
2. **Better colour fidelity.** The CLUT emits full **RGB565** (5-6-5), strictly
   better than today's ARGB4444 (4-4-4-4) for any blended tile.
3. **Parallax headroom.** Half the source bytes per pixel eases the fabric-bound
   parallax case (see `solarus-parallax-fabric-bound-perf`).

**v1 scope (this spec):** paletting only — 8bpp atlas, CLUT, `COMP_PAL8` format,
per-blit palette selection, bake integration, migration flag, cumulative
regression test. **Explicitly NOT in v1:** tile/sprite **dedup** and the on-disk
**palettized-asset cache**. Those are Phase 2 (§12) — the census shows paletting
*alone* fixes #84 with ~10× margin, so v1 takes the entire RTL risk at minimum
scope and validates the fabric palette model before anything is layered on top.

**Relationship to the host-only #84 fix.** A separate, small host fix (branch
`fix/issue-84-host-restage`) stops #84 bleeding immediately by correcting the
preload format guess + bounding the re-stage. This spec is the *strategic*
replacement that makes the dual-format guess obsolete. The two are independent;
paletted v1 lands on top of (or replaces) the host fix once HW-validated.

---

## 2. Non-goals / deferred

- **Dedup** (69% exact / 90% by-shape at 8×8) — Phase 2.
- **On-disk cache** of the palettized atlas + CLUTs — Phase 2 (its cost/benefit is
  clean only once index-recovery + dedup costs are known; §12).
- **Runtime-generated surfaces** (SDL_ttf text, menu/dialog composites, render
  targets) stay **direct-colour** (RGB565/ARGB4444) forever — they have no fixed
  palette. The fetch path is permanently mixed-format; paletting is only for the
  immutable `pal8` PNG assets.
- **`ts9`** (the one rgba tileset, 258 colours) — v1 keeps it on the existing
  direct-colour path (mixed format handles it for free). Offline palettization of
  `ts9` is a Phase-2 nicety, not a v1 requirement.

---

## 3. Architecture overview

```
 HOST (mister_blitter_renderer.cpp)                 FABRIC (fpga/rtl)
 ─────────────────────────────────                 ─────────────────
 preload: for each immutable pal8 PNG               comp_burst
   • recover 8-bit index plane + PLTE  ─┐             • byte-addressed 8bpp source read
   • stage 8bpp indices → SDRAM (half) ─┼─ SDRAM ──►   • per-format stride
   • register surface→(bank,base)       │  (8bpp        • zero-extend index → 16b lane at fill
 palette mgr:                           │   atlas)             │
   • pack small palettes into 8 banks   │                      ▼
   • upload changed banks ──────────────┼─ DDR ───►  comp_src_linebuf  (UNCHANGED, 16b lanes,
                                        │  CLUTBUF     index in low byte)
 emit blit (format=PAL8):               │                      │
   • color field = {pal_id, base_off} ──┼─ ring ──►  comp_pipeline
   • blend = COPY/KEY/PALPHA as today   │             • if c_format==PAL8:
                                        │                 idx = serve_pix[7:0] + base_off
                                        │                 {A4,RGB565} = CLUT[pal_id][idx]
                                        │             • else: RGB565/ARGB4444 as today
                                        │                      │  (same feed_src / mixer)
                                        │                      ▼
                                        └──────────►   blend into RGB565 framebuffer
```

**Contract summary (single source of truth = `blt_wire.h` + `comp_defs.vh`):**
- New source format `COMP_PAL8 = 8'd2` (host `BLT_FMT_PAL8`), joins RGB565=0,
  ARGB4444=1. `format` is a full wire byte — room exists.
- CLUT = **8 banks × 256 entries × `{A4[3:0], R[4:0], G[5:0], B[4:0]}`** (20b, pad
  to 32b) in fabric BRAM ≈ **8 KiB**. Bank count and A4 width per prior decision.
- Per-blit palette selection rides in the **`color`** wire field (u32[7] low 16),
  which is unused for COPY/KEY/PALPHA (it is the FILL colour): `color = pal_id[?]
  | base_offset[7:0]`. Zero ABI widening; no collision with the v2 colour-mod
  bytes (27/30/31) or `cmod_r/g` in u32[7] high 16.
- CLUT upload via a new opcode `BLT_OP_CLUT_UPLOAD`, modelled on
  `BLT_OP_FRT_UPLOAD`: host writes bank bytes to a reserved DDR `CLUTBUF` region,
  emits the command, fabric DMAs it into CLUT BRAM.

---

## 4. Fabric changes (Strategy R1 — absorb 8bpp at the linebuf fill)

**Chosen strategy R1** (keep the delicate serve path untouched). Verified against
the RTL: `comp_burst` is a **format-agnostic qword/beat mover** (no pixel
knowledge), and `comp_src_linebuf` serves fixed 16-bit lanes. The source-address
computation and the linebuf fill both live in **`comp_pipeline`'s prefetch
sub-FSM** (`comp_pipeline.sv` `F_WALK`, ~`:444-458`). So R1's "absorb at fill"
lands entirely in `comp_pipeline`; `comp_burst` and `comp_src_linebuf` are
**untouched**.

**Two-step de-risking (both are R1; the first is a validation stepping stone):**

### 4.1a Step 1 — CLUT + `COMP_PAL8` lookup with indices stored **16bpp**
- Stage index planes at 16bpp (index in the low byte, high byte zero). The
  prefetch fill stays **exactly 1:1** (`lb_fill_qw <= p0_dout`, unchanged) — the
  delicate `F_WALK`/`sf_idx` machinery is not touched.
- `comp_pipeline` decode gains `COMP_PAL8`: `serve_pix[7:0] + base_off → CLUT →
  {A4,RGB565}` into the existing `pa_expanded`/`feed_src` path.
- Proves the whole palette model (upload, per-blit `pal_id`, lookup, blend, bake)
  end-to-end in sim **and** on HW with **zero** risk to the fill path. **No memory
  win yet** (indices at 16bpp) — this step is about correctness, not footprint.

### 4.1b Step 2 — 8bpp source packing (the memory win + #84 dissolve)
- Stage index planes at **8bpp** (half the bytes). The `F_WALK` fill becomes
  **format-aware**: source addressing `>>3` (8 indices/qword, 1 B/px) and a **1:2
  expansion** — each fetched source qword lands as **two** linebuf qwords, each
  index zero-extended into a 16-bit lane. RGB565/ARGB4444 keep the 1:1 path.
- This is the **highest-risk change** (fill/addressing, seam-adjacent). It gets a
  dedicated golden TB (§8.2) and only runs after Step 1 is validated.

### 4.2 `comp_burst` / `comp_src_linebuf` — UNCHANGED
- `comp_burst` stays a generic qword mover. `comp_src_linebuf` stays 16-bit lanes
  for **every** format; PAL8 indices arrive zero-extended in the low byte. The
  `serve_lane`/hflip/serve path is never touched. (Linebuf holds indices at 16b —
  free; it is 2 KiB.)

### 4.3 CLUT BRAM + `BLT_OP_CLUT_UPLOAD`
- New BRAM: `clut[8][256]` of 20-bit `{A4,R5,G6,B5}` (pad 32b). Cyclone-V M10K:
  8 banks × 256 × 32b = 64 Kib ≈ trivial.
- New opcode DMAs `CLUTBUF` (reserved DDR region) → `clut`. `u32[3]` = qword count
  (as FRT_UPLOAD). Bank targeting: a small header, or upload all 8 banks as one
  contiguous image (8 KiB) — sizing/partial-upload decided in the plan.

### 4.4 `comp_pipeline` — the CLUT lookup (the easy part)
- At the existing decode point (`comp_pipeline.sv:~208-234`), add:
  ```
  wire is_pal8 = (c_format == 8'd2);
  wire [7:0]  pal_idx = lb_serve_pix[7:0] + base_off;   // base_off from cmd
  wire [19:0] clut_e  = clut[pal_id][pal_idx];          // pipelined BRAM read
  wire [15:0] pal_rgb = clut_e[15:0];                   // {R5,G6,B5}
  wire [3:0]  pal_a4  = clut_e[19:16];
  ```
  Then route PAL8 into the **same** `pa_expanded`/`feed_src`/`feed_a8` machinery
  the ARGB4444 path already uses (it already expands to RGB565 + a8 and handles
  every blend mode after #100). PAL8 → `feed_src = pal_rgb`, `a8 = {pal_a4,pal_a4}`,
  `feed_skip = (pal_a4==0)` for the transparent index. Blend logic unchanged.
- **Timing.** The CLUT read is **one pipelined BRAM stage** → added *latency*, not
  reduced throughput; issue-interval-1 preserved. STA to be re-run; the added
  stage registers on the core clock. Flagged as a verification gate.

### 4.5 Defs
- `comp_defs.vh`: `` `define COMP_PAL8 8'd2 ``.
- `blitter_defs.vh` / `blitter_top.sv` unpack: recognise `format==2`; extract
  `pal_id`/`base_off` from the `color` field when `format==PAL8`.

---

## 5. Host changes (`mister_blitter_renderer.cpp` + blitter/)

### 5.1 Index recovery (verify-then-pick)
Surfaces reach the renderer as **32-bit RGBA** in the current code
(`to_rgb565`/`to_argb4444`/`mpix` read 32-bit components). Two recovery paths:
- **Ideal (verify first):** if SDL_image actually keeps `pal8` PNGs as **8-bit
  indexed** `SDL_Surface`s (`format->palette` populated, `pixels` = indices), then
  index recovery + CLUT are **free**: copy the index plane, read the palette from
  `SDL_Palette`. **First implementation task: confirm the surface's real
  `BytesPerPixel` at the staging point.**
- **Fallback (if surfaces are 32-bit):** read the PNG's `PLTE`/`tRNS` for the
  palette, build an RGBA→index reverse map, map each pixel once at preload. Exact
  for `pal8` (every pixel's colour is in the palette). Cost: one pass over ~a few
  M px at boot — the exact cost the Phase-2 disk cache later amortizes.

Either path yields `(index plane, palette)` per surface. Non-`pal8` surfaces
(`ts9`, truecolor sprites, runtime surfaces) skip this and stay direct-colour.

### 5.2 Palette manager (allocation)
- Maintain up to **8 CLUT banks**. Each `pal8` surface's palette (small — median
  6–15 colours, ≤68 enemies, ≤34 hero, tileset ≤134) is **packed into a bank at a
  base offset**; the surface records `(bank, base_off)`.
- Allocation policy (v1, simple + predictable): **map's tileset palette → its own
  bank**; sprite/entity/HUD/menu palettes packed into the remaining banks by
  first-fit on `[0,256)` per bank. On map transition, re-pack + re-upload only
  banks whose contents changed (tileset bank always; sprite banks usually stable).
- Alpha folds into the CLUT entry (A4 per index) from `tRNS`/per-pixel alpha —
  no separate alpha LUT. Quest-wide alpha is 5 levels; A4 over-covers.

### 5.3 Preload / staging
- Stage the **8bpp index plane** (half the bytes) to the perm region instead of a
  16bpp colour buffer. **No format guess** — `pal8` surfaces have exactly one
  representation (index), so the #84 re-stage cannot occur.
- Upload the surface's palette into its assigned bank; emit `BLT_OP_CLUT_UPLOAD`
  when a bank changes.

### 5.4 Emit
- For a `pal8` source blit, set `format=BLT_FMT_PAL8`, `color = (pal_id<<8) |
  base_off`, keep `blend_mode` as today (COPY/COLORKEY/PALPHA). Colour-mod (tint)
  still works — CLUT emits RGB565, then cmod multiplies downstream.

---

## 6. Bake integration (bgplane)

The bgplane bake pre-composites static map layers into planes. With paletted
sources, **the bake resolves index→RGB565 at bake time** and writes a
**resolved-colour** plane (RGB565, or ARGB4444 for the one blended water layer),
exactly as today's plane formats. Rationale:
- Blending (water A127/191, per-layer occlusion) requires real RGB — you cannot
  blend palette *indices*. Resolving at bake keeps the plane a normal source the
  scanout/composite reads with **no** CLUT dependency at scan time.
- The bake's only change: its **source read** goes through the CLUT like any
  other PAL8 read; its **output** plane stays resolved-colour. Downstream
  (scanout, per-bucket replay) is unchanged.
- Per-layer occlusion (binary alpha) and water (A4=127/191→ nearest A4) coexist
  because the plane carries A4, same as the current ARGB4444 plane.

This keeps the bake subsystem's structure intact (the arena/free-per-rebuild
machinery is unchanged) and touches only the source-decode inside the bake.

---

## 7. Migration & flag

- Gate on `SOLARUS_PALETTE` (default OFF in v1 until HW-validated, then flip
  default-ON). When OFF, the existing dual-format residency path runs verbatim —
  full fallback, zero risk to the shipping path.
- The RTL recognises `COMP_PAL8` unconditionally (a new format value is inert when
  the host never emits it), so a fabric with PAL8 support runs the old host path
  fine. Host and fabric can therefore land/validate in either order.
- Coexistence with the host-only #84 fix: when `SOLARUS_PALETTE=1`, the format
  guess at `:1341` is bypassed entirely (paletted sources have one format). The
  two fixes do not fight.

---

## 8. Testing

**The bug class hid because single-map tests pass. v1's regression test MUST be
cumulative / multi-tileset.**

### 8.1 Host regression (the #84 catcher)
- Stage ≥6 distinct-tileset-sized paletted surfaces and assert **(a)** total perm
  footprint ≈ half the 16bpp baseline, and **(b)** no surface's source offset ever
  exceeds the perm region (no runaway offset). This is the cumulative check the
  old single-map tests structurally could not make.

### 8.2 RTL testbenches
- **`comp_burst` 8bpp addressing** (highest risk): byte-addressed source read +
  per-format stride + the 1-source-qword→2-linebuf-fill expansion, with hflip and
  non-qword-aligned `src_x`. Golden vs a reference unpack.
- **CLUT lookup golden:** `COMP_PAL8` pixel → `{A4,RGB565}` → blend, bit-exact vs
  a host reference over COPY/COLORKEY/PALPHA and the transparent index (A4=0).
- **Mixed-format sequence:** interleave PAL8, RGB565, and ARGB4444 blits in one
  command stream (proves the serve path stays format-agnostic; catches an R2-style
  regression if the linebuf were ever touched).
- **CLUT upload:** `BLT_OP_CLUT_UPLOAD` DMAs CLUTBUF→BRAM correctly; bank select +
  base-offset addressing.

### 8.3 HW validation
- Objective: `cold_upload MB` at gameplay ≈ 0 (no re-stage); perm high-water ≈
  half baseline. Then the §2-brief cumulative teleport route (≥6 distinct
  tilesets) with a human confirming tiles/water render correctly — **never
  self-declare visual correctness** (memory `solarus-no-self-declared-visual-validation`).

---

## 9. Risks

| Risk | Mitigation |
|---|---|
| `comp_burst` 8bpp addressing (seam-adjacent) | Dedicated golden TB (§8.2) before any HW; land RTL behind the inert format value. |
| CLUT read blows STA on the issue-1 pipeline | It's one pipelined BRAM stage (latency, not throughput); re-run STA as a gate; register on core clock. |
| Surfaces are 32-bit → per-pixel reverse-map at boot | Acceptable one-time boot cost in v1; Phase-2 disk cache removes it. Verify 8-bit-surface ideal first (may be free). |
| Palette bank overflow (a map needs >8 live palettes) | Census says ~5 banks cover gameplay; per-surface packing + base-offset gives slack. Add a loud assert + fallback-to-direct-colour for an over-budget surface. |
| Bake plane alpha rounding (A127/191→A4) | A4 covers the 5 quest alpha levels exactly; golden-check the water layer. |

---

## 10. Phase 2 preview (not in this spec)

Once v1 is HW-validated: **(a)** exact-tile dedup (content-hash 8×8 or Solarus
pattern-rects; ~69% exact) sharing one atlas copy; **(b)** the **on-disk cache** —
persist the palettized (+deduped) index atlas + CLUT banks + manifest to
`/media/fat/games/Solarus/cache/<quest-hash>/`, keyed by a quest-data hash, so
first boot of a new quest pays the palettize/dedup cost once and every subsequent
boot memoizes. Palette-variant dedup (same shape, different palette) becomes
exploitable *because* v1 made sources paletted.

---

## 11. Open questions for review

1. **CLUT upload granularity** — single 8 KiB whole-CLUT image per upload, or
   per-bank partial uploads keyed by a header? (Leaning per-bank to avoid
   re-uploading the stable sprite banks on every map transition.)
2. **`pal_id` width in the `color` field** — 3 bits (8 banks) vs 4 (16 banks,
   cheap headroom). Proposed 4 bits + 8-bit base = 12 of 16.
3. **`ts9` in v1** — confirm we ship it direct-colour (mixed format, zero work) vs
   palettize it offline now. Recommend direct-colour in v1.
4. **Bank allocation** — is per-surface first-fit packing enough for v1, or do we
   want static per-category banks up front? Recommend first-fit (simpler, matches
   the tiny-palette census).
