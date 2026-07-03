# Camera-independent resident tile list (single fabric-resolved path, no fallback)

**Date:** 2026-07-02
**Status:** Design — awaiting HW for final validation + measurement
**Issue lineage:** #52 (dumb-emitter / BLT_OP_TILELIST), Tier A/B resident lists

## Problem

The resident animated-tile optimization (`SOLARUS_TILERESIDENT`) only pays off
when the hero is standing still. `resident_begin_frame()` keys its fast/rebuild
decision on `{map, tileset, vpx, vpy}` (`mister_blitter_renderer.cpp:1812`), and
each resident entry stores a **camera-dependent screen destination**
(`:1902`, `bdx = e.dst.x + alias_off`). Worse, the build walk records only tiles
that `overlaps(*camera)` at build time (`build_engine.sh:1350`) — the resident
set is the viewport, not the map. So any camera move both (a) invalidates the
cached screen dsts and (b) changes which tiles must be present, forcing a full
rebuild — the `get_draw_region` walk that is ~86% of per-frame `emit` (EMITSPLIT:
`emit = walk ~11ms + blit ~1.8ms`). The moment the player moves, emit returns to
~14–20 ms.

Both Tier A (engine patches src per pattern) and Tier B (fabric resolves src from
FRT/CFT) share this defect. Tier B alone does not fix movement; it only makes the
standing-still fast frame cheaper.

Secondary concern (the trigger for this work): multiple resident/legacy code paths
are more complexity than a standing-still-only win justifies.

## Goal

One resident path that is **camera-independent**: the animated-tile A9 cost drops
to O(buckets) per frame — near-zero — whether moving or standing still. Rebuild
happens only on genuine scene change (map/tileset), never on camera motion. Tier A
and the legacy non-resident walk are deleted.

## Design principles

- **No fallback.** The resident path is *the* path. There is no overflow-escape to
  a legacy walk, no gate-to-legacy safety net, and no whole-scene bail. The design
  must be correct and capacious on its own. Conditions that would have triggered a
  fallback (TL_BUF overflow, an unbatchable bucket) are treated as **bugs to fix**
  (resize the buffer, extend fabric support) and surface as **loud diagnostic
  failures**, not silent degradation.
- **Move work off the A9 onto the idle fabric.** The A9 is the bottleneck; the
  fabric is fully hidden under it. Whole-map culling belongs on the fabric.
- **YAGNI.** Reuse existing opcodes, structs, and the repeated/fill expansion
  already present. No fabric-side parallax/division. No new gates.

## Core invariant

A resident entry's destination is stored in **map coordinates** — fixed for the
life of a scene. The resident list holds the **whole map's** animated tiles for
each layer (not the viewport). Screen position is derived at emit time by adding a
**per-layer bias** the fabric applies to every entry in a `BLT_OP_TILELIST_RES`
batch; the fabric **culls** off-screen entries (it already culls in `S_TL_ISSUE`).

- `resident_begin_frame` signature drops `vpx/vpy` → `{map, tileset}` only.
  Camera move stays in fast mode (mode 2). Rebuild (mode 1) only on map/tileset
  change.
- Per displayed frame the A9 writes only: **CFT** (per-pattern current animation
  frame) + **one bias per bucket** (O(buckets)), then replays the recorded bucket
  headers. Entries stay resident in TL_BUF — the A9 never re-walks them, so the
  per-frame A9 cost is **O(buckets), independent of entry count**. The fabric does
  the per-entry work (resolve src from FRT/CFT, apply bias, cull, composite).

### Per-layer bias (handles parallax, eliminates escapes)

The camera offset is not global — layers scroll at different rates:

- **Normal layer:** `screen_dst = map_dst − camera_top_left` → `bias = −camera_top_left`,
  `map_dst = screen_dst_at_build + camera_top_left_at_build`.
- **Parallax layer:** `screen_dst = dst_position + camera_top_left / ratio` (matches
  the current parallax fix; `ratio` = `ParallaxScrollingTilePattern::ratio`, ~2) →
  `bias = +camera_top_left / ratio`, `map_dst = dst_position`.

The **host** computes one signed `{bias_x, bias_y}` per bucket per frame from the
camera and the bucket's layer type (the `/ratio` shift is host-side, once per
bucket). The **fabric** performs only a signed add.

Because parallax dependence is now expressed as bias (not a rebuild), parallax
animated tiles — currently *escapes* — become ordinary resident entries. Combined
with the existing repeated/fill → per-cell expansion, **every animated tile
becomes a resident entry: there are no escapes.** (Any bucket the fabric genuinely
cannot express is an open gap to close at the fabric/format level — see risks — not
a fallback to legacy.)

## Whole-map recording

In BUILD mode, drop the `overlaps(*camera)` filter: record **all** of
`tiles_in_animated_regions[layer]`, storing map-coord dsts, expanding repeated/fill
patterns into per-cell entries. This is a one-time (per scene) whole-map walk. From
then on, camera motion is a bias update + fabric re-cull — no A9 walk, no rebuild.

Cost lands entirely on capacity + fabric bandwidth, both handled below.

## Changes by layer

### DDR map + TL_BUF sizing (`mister_blitter_renderer.cpp`, `fpga/rtl/blitter_defs.vh`)

Current `TL_BUF = 64 KiB` (8192 8-byte entries) is viewport-sized and too small
for a whole-map set. The `0x3BF00000–0x3C000000` region has ~108 KiB unused above
bg-cache and ~700 KiB free above CFT.

All these buffers live in the **core-reserved top of the 1 GB DDR3** (HPS SDRAM
controller, reached by the fabric over the f2h bridge). The kernel cmdline
`mem=511M memmap=513M$511M` gives HPS Linux the low ~511 MiB and reserves the top
~513 MiB for the core, so the framebuffer (`0x3A000000`, 928 MiB) and blitter
region (`0x3B000000–0x3C000000`, 944–960 MiB) never collide with Linux memory.
Enlarging TL_BUF stays entirely within this reserved region. (This DDR3 is separate
from the FPGA-only daughterboard SDRAM that holds the composited VRAM framebuffer —
out of scope here.)

- Enlarge `TL_BUF_BYTES` to **512 KiB** (65536 entries). TL_BUF base stays at
  `0x3BF40000`; at 512 KiB it ends `0x3BFC0000`, so `OFF_FRTBUF`/`OFF_CFTBUF` move to
  `0x3BFC0000`/`0x3BFC2000` — FRT (8 KiB) + CFT (256 B) end at `0x3BFC2100`, still
  below the `0x3C000000` region end. Keep host constants and fabric
  `blitter_defs.vh` (`TL_BUF_QW`, `FRT_BUF_QW`, `CFT_BUF_QW`, `TL_BUF_BYTES`) in
  lockstep (the existing `static_assert`s enforce non-overlap — update them).
- **Size to the measured workload.** Instrument the whole-map animated-tile count
  per layer across all Mystery of Solarus DX maps; set TL_BUF to exceed the max
  with generous margin. Overflow is a **hard failure**: assert + a loud
  `[blitter resident] TL_BUF OVERFLOW` diag banner, not a fallback. If a map
  overflows, the fix is a larger TL_BUF, not a degrade path.

### ABI (`patches/mister/blitter/blt_wire.h`, `blitter_ref.h`) — no struct growth

A `TILELIST_RES` header does not use `src_x`/`src_y` (src comes from the FRT).
Repurpose those two 16-bit slots as the signed per-batch bias, **for
`TILELIST_RES` headers only**:

- `bias_x` → `u32[2]` bits `[31:16]` (the `src_x` slot)
- `bias_y` → `u32[4]` bits `[15:0]` (the `src_y` slot)

Both `int16_t`. No change to `BLT_CMD_BYTES` (32), no new pack/unpack. The 8-byte
`blt_tile_entry_res_t {u16 pattern_id; i16 dst_x,dst_y; u16 _rsvd}` is unchanged —
`dst_x/dst_y` now carry **map** coords.

### RTL (`fpga/rtl/blitter_top.sv`) — 2 signed adds + latch 2 fields

- At `BLT_OP_TILELIST_RES` decode (near `:542`), latch signed
  `bias_x <= header u32[2][31:16]`, `bias_y <= header u32[4][15:0]`.
- In `S_TLR_SLICE` (`:734`): `c_dst_x <= res_dx + bias_x; c_dst_y <= res_dy + bias_y;`
  (signed 16-bit add). Downstream cull/clip/issue unchanged.

### Host (`mister_blitter_renderer.cpp`, `scripts/build_engine.sh`)

- **Whole-map, map-coord record.** `resident_record_batch` records every animated
  tile (drop `overlaps` filter) with map-coord dst; expand repeated/fill into
  per-cell entries; parallax stored via `dst_position` (bias applied per frame).
- **Signature.** `resident_begin_frame` drops `vpx/vpy`; keys `{map, tileset}`.
- **Per-frame bias.** On each fast frame compute `{bias_x, bias_y}` per bucket from
  `mister_camera_x()/y()` and the bucket's layer parallax ratio; write it into the
  two repurposed header fields when replaying that bucket's header.
- **Delete Tier A + legacy walk + escapes + per-tile loop.** Remove: the 12-byte
  entry format, `res_patch_entry`/`rp.offs`, the per-pattern src-patch loop
  (`:1867–1877`), the `SOLARUS_TILERESIDENT` vs `SOLARUS_TILERESIDENT_HW` split
  (`:1381–1387`), `res_hw*` bifurcation, the whole-scene `res_build_escape`→legacy
  path, the non-resident `draw_tile_batch` walk, **and the original per-tile
  `tile.draw()` loop / `SOLARUS_TILEBATCH=0` path entirely.** The fabric-resolved
  resident path is the only path — no gate, no oracle, no fallback. (The sim TBs
  remain the bit-exact reference; no runtime reference path is retained.)

## Testing (all doable now; only fps + the HW flip wait)

- **Extend `fpga/sim/tb_tilelist_res.sv` (gating, bit-exact A==B):**
  1. Add per-batch `bias_x/bias_y`; assert resolved `dst == map_dst + bias` across
     all existing cases (COPY / clip / cull / partial / PALPHA / 24-span).
  2. **Movement/temporal case:** render frame N; change bias (camera pan) *and*
     advance CFT (animation tick); re-render N+1; assert both the dst shift and the
     frame advance are correct — the scenario the old design could not express.
  3. **Whole-map cull case:** a batch with many entries where most are off-screen
     under the current bias; assert the fabric culls them and composites only the
     on-screen remainder correctly.
- **Host build:** compiles clean in `solarus-armhf-build:bullseye`; confirm the
  removed gates/paths are gone (`strings` shows no `SOLARUS_TILERESIDENT_HW`, no
  `SOLARUS_TILEBATCH`, no Tier-A symbols).
- **Whole-map count instrumentation:** a diag banner reporting per-scene resident
  entry count (to size TL_BUF and prove no overflow on MoSDX maps).
- **Deferred to HW:** standing-still vs **moving** emit ms + fps A/B (moving should
  now match standing-still), tear check while moving, `[blitter resident]` banner
  showing `rebuild=0` *while moving*, and confirmation the enlarged whole-map fabric
  cull stays hidden under the A9.

## Rollout / HW-deferred boundary

Host + ABI + RTL + sim land together (coupled deploy — ABI/RTL and engine must
match). Per the no-fallback principle there is no runtime gate to legacy: the
resident path is validated bit-exact in sim before the RBF is trusted, and the
fps/tearing confirmation + whole-map-cull-bandwidth check happen when hardware
returns. Tier-A and legacy-walk deletion is part of this change, not staged.

## Non-goals / YAGNI

- No fabric-side division or parallax awareness (host bakes `ratio` into bias).
- No change to FRT/CFT upload semantics, `BLT_MAXP/BLT_MAXF`, or comp_pipeline.
- No new opcode — reuse `TILELIST_RES` (6) / `FRT_UPLOAD` (7).
- No reduction of the entity/sprite `emit` walk or `eng_cpp` here (separate campaign).

## Open risks

- **Fabric per-frame cull bandwidth.** The fabric now reads the whole-map entry set
  each frame (one DDR qword/entry) to cull it. Hidden under the A9 today with real
  headroom, but the margin narrows and it is **HW-unmeasurable now**. The whole-map
  count instrumentation + the sim cull case bound it in sim; HW confirms the hide.
- **TL_BUF sizing.** Must exceed the largest MoSDX whole-map animated set with
  margin. Measured via instrumentation; overflow is a hard failure by design.
- **Genuinely-unbatchable buckets.** If any MoSDX animated bucket can't be expressed
  as a resident entry even after parallax-bias + repeated/fill expansion
  (`res_bucket_params` fails — exotic blend/format), that is a fabric/format gap to
  close, not a fallback. Enumerate during implementation; extend fabric support if
  found.
- **Parallax `map_dst` geometry** must exactly reproduce the current escape-fix
  result; the temporal TB case is the guard.
- **Signed i16 dst range.** Map-coord dst (i16 wire field) + bias must stay in range
  across large maps + camera extremes. Confirm the largest MoSDX map's map-coord
  dsts fit i16; if not, the entry dst field width is the constraint to revisit.
