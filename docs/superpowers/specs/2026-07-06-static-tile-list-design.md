# Static (non-animated) tile-list — retire cell-intermediate staging

Date: 2026-07-06
Branch: `design/sdram-asset-residency` (follows PR #66 residency work)

## Problem (evidence-based root cause)

After PR #66 (whole-quest atlas residency), the MoSDX overworld renders with
**title-screen fragments in specific background regions** (and menu dialogs stripe).
HW diagnosis this session established, by evidence, what it is and is **not**:

- **Not** re-upload / format cache-miss (`uploads=0 reup=0` steady state).
- **Not** intermediate-region overflow (`overflow=0`).
- **Not** a fabric throughput / ring failure (`escape=0 fatal=0 cmdcnt≈32 valid=1`).
- **Not** stale-pointer / address-reuse cache aliasing — the `cache-probe`
  `[stalechk]` run recorded **`FORGET=0`** across the whole title→overworld
  transition, i.e. no cached surface was destroyed, so no address was recycled.

What it **is**: the overworld background is composited by reading large chunks
from the **SDRAM intermediate region** — the upstream `NonAnimatedRegions`
per-cell surfaces (`optimized_tiles_surfaces`), which our port software-composites
then **stages DDR3→SDRAM (inter region) and blits back**. Those long-lived cell
slots are composited once and read every frame, and **the slot content / fabric
stage-and-read round-trip for the inter region is where the garbage originates**
(relocating the inter region off the top-of-XL, `0x07C0_0000` → `0x0500_0000`,
fixed the *bulk* of the corruption this session, confirming the inter round-trip
is the fault domain; a residual set of inter slots still reads wrong content).

The immutable file assets (perm region, `0x0100_0000`–`0x04c2_9098`) read **clean**
throughout (title pixel-perfect; sprites/HUD correct). The bug lives entirely on
the **mutable inter-region cell path**, not on the resident perm atlas.

## Goal

Retire the cell-intermediate staging for **non-animated tiles**. Render them the
same way animated tiles already render: a **fabric tile-list read directly from
the resident perm atlas**, composited onto the aliased camera FB — no software
cell composite, no DDR3→SDRAM cell stage, no inter-region round-trip. This removes
the garbage at its source (the overworld background is built from the proven-clean
perm atlas) and deletes a pre-offload optimization (`NonAnimatedRegions` cells)
that the fabric compositor has made redundant.

The SDRAM intermediate region remains only for true menu/title/HUD intermediates.
The inter-region **relocation** to `0x0500_0000` is **kept** (it is a real fix for
those remaining intermediates). Residual menu striping is out of scope (tracked
separately).

## Approach

Add a **static tile-list** built on the existing `BLT_OP_TILELIST` (opcode 5,
12-byte direct-source entries), parallel to the animated `BLT_OP_TILELIST_RES`
(opcode 6, 8-byte pattern-indexed) path, reusing the resident build/fast-frame,
camera-bias, bucketing and alias machinery.

**Why the direct 12-byte form (and not the RES 8-byte form):** a map's
non-animated tiles reference **hundreds of distinct patterns** and would blow the
animated path's `BLT_MAXP = 128` frame-rect-table cap; and they need no frame
indirection (src is fixed). The 12-byte entry `{src_x, src_y, w, h, dst_x, dst_y}`
carries its own src rect — no pattern limit, no FRT/CFT — which is both correct
and *simpler* than the animated path.

**Camera model:** whole-map, camera-independent (user-selected). Entries store
**map-coord** dsts; the fabric adds a **per-frame header bias** and culls
off-screen. A camera move re-emits only the per-bucket headers — no rebuild —
exactly like the animated RES path.

Rejected alternative: extend the RES path to static tiles as single-frame
patterns — blows `BLT_MAXP=128`, wastes the FRT. Not viable.

## Components & interfaces

### 1. Fabric (`fpga/rtl/blitter_top.sv`) — apply header bias to direct `OP_TILELIST`

Today `OP_TILELIST_RES` latches `res_bias_x/res_bias_y` from the header's
`src_x/src_y` slots at decode and adds them to each entry's dst; the direct
`OP_TILELIST` path does **not** (it latches `c_dst` verbatim at `S_TL_LATCH`).

Change: at `OP_TILELIST` decode (blitter_top.sv ~528), latch `res_bias_*` from
`c_src_x/c_src_y` (the TILELIST header's src slots are "informational... unused
here", so they are free to carry the bias). At `S_TL_LATCH` (~658), add the bias
to `c_dst_x/c_dst_y` for the **non-res** branch (`!tl_res`). The `S_TL_ISSUE`
`empty` cull already runs on the (now biased) dst — unchanged. ~3 lines.

### 2. Reference model (`fpga/rtl/blitter_ref.h` / gating TBs)

Mirror the same bias-on-direct-`TILELIST` in the C golden so sim/HW stay
bit-exact. Extend/author a gating TB proving `OP_TILELIST` + non-zero bias matches
the biased reference (parity with the existing RES TBs).

### 3. Emitter (`patches/mister/blitter/blt_emitter.{h,c}`)

- Pack 12-byte `blt_tile_entry_t` records into `TL_BUF`, **bump-allocated after**
  the animated RES entries/FRT (shared buffer; track the static base offset).
- Emit a `BLT_OP_TILELIST` header per static bucket: `N`, entry byte-offset, and
  the per-frame **bias in the header src_x/src_y slots**, plus the bucket's shared
  texture/blend/format/key/flags (reuse `res_bucket_params`).
- `TL_BUF` overflow (animated + static combined exceed capacity) → loud
  `res_fatal`, no partial write.

### 4. Renderer (`patches/mister/mister_blitter_renderer.cpp`)

- A **static record path** (sibling to `resident_record_batch`): stores 12-byte
  entries `(src rect, map-coord dst)` in per-bucket lists keyed
  `{tileset image, blend, scroll_ratio}`. No pattern tokens, no CFT, no per-frame
  per-entry update.
- Build frame: record static buckets alongside the animated ones under the same
  `res_valid` map/tileset signature (one build per area).
- Fast frame: re-emit each static bucket's `BLT_OP_TILELIST` header with the
  current camera bias (normal `-camera`; parallax `camera/ratio - camera`).
- Arm writes static entries to `TL_BUF` once per scene (like the RES arm).

### 5. Engine walk & cell suppression (`scripts/build_engine.sh` → `Entities.cpp`,
`NonAnimatedRegions.cpp`)

- In the `Entities.cpp` per-layer draw loop, in addition to the existing animated
  walk, **walk the non-animated tiles** (same `get_draw_region` → `(src,dst)`;
  repeated/fill tiles expanded to per-cell entries; parallax → `scroll_ratio`
  bucket) and record them into the static list on build frames.
- When the static path is active, **skip `non_animated_regions[layer]->draw_on_map()`**
  (and the corresponding `->update()` cell-eviction). With `draw_on_map` not called,
  `build_cell` never runs — no cell surfaces, no inter staging. The upstream
  `NonAnimatedRegions` machinery is left compiled but dormant.

## Gating

A kill-switch, `SOLARUS_TILESTATIC` (default ON), separate from
`SOLARUS_TILERESIDENT` so the static-tile path can be A/B'd independently of the
animated path during bring-up. OFF → the old cell path runs unchanged (safety net).

## Edge cases (mirror the animated walk's existing policy — no new behavior)

- Repeated / fill tiles (tile larger than its pattern): expand to per-cell entries.
- Parallax non-animated patterns: `scroll_ratio` bucket; bias uses the ratio.
- Non-batchable (`get_draw_region` fails, or a blend/tint the tile-list ABI can't
  carry): loud `res_fatal` — consistent with Task 7 "no silent fallback."

## Capacity & failure

Whole-map static entries at 12 B each share `TL_BUF` (512 KiB) with the animated
RES entries (~8 KB observed). MoSDX's whole-map non-animated set is expected to fit;
overflow is a loud `res_fatal` (not a silent degrade), fixable later by chunking or
enlarging `TL_BUF` if a real quest needs it.

## Testing

- **Sim/ref**: golden updated for bias-on-direct-`TILELIST`; gating TB proves the
  fabric `OP_TILELIST`+bias is bit-exact vs the biased reference.
- **Emitter**: host TDD — 12-byte entry packing, static bucket sub-range offset,
  bias-in-header, combined-overflow `res_fatal`.
- **HW**: deploy; drive the overworld — title-fragment garbage **gone standing AND
  moving** (proves camera-independence); `[blitmap]` shows background tile reads
  from the **perm atlas** with **no `0x05…` inter reads**; `uploads=0`; no
  `res_fatal`; A/B the `SOLARUS_TILESTATIC` gate; confirm title/menu/HUD still render.

## Success criteria

- Overworld background composited entirely from the perm atlas via `BLT_OP_TILELIST`
  (zero inter-region reads for non-animated tiles).
- Title-fragment background garbage eliminated, standing and moving.
- No new `res_fatal` on MoSDX maps.
- Static-tile path cost ≤ the retired cell path (no software cell composite, no
  DDR3→SDRAM cell stage round-trip).

## Out of scope

- Menu/title/HUD intermediate striping (separate track; those keep the inter path).
- Reverting the inter-region relocation (kept — it benefits the remaining
  intermediates).
- `TL_BUF` chunking / resize (only if a real quest overflows).
