# Dumb Emitter — Fabric Tile-List Command (Design)

**Date:** 2026-06-27
**Branch:** `fix/issue52-atlas-load-phase`
**Issue:** #52 (heavy-area path-to-60fps; black screen already fixed)
**Status:** Design — awaiting review before implementation planning.

## Problem & validated data

In heavy areas the engine renders at ~6.7fps. HW instrumentation (this session,
lib `bce464cd`, `SOLARUS_BLITTER_DIAG=1`) pins the bottleneck precisely:

```
A9 = 137ms = emit 112ms + eng_cpp 15ms + lua_vm 5ms + present 2ms
fabric_hw = 23.8ms (comp 97%)  — concurrent, IDLE (C_DONE==C_SUBMIT)
drawcat: anim_tiles = 3,758/fr  +  entities = 64/fr   (p0 draws ≈ 3,825/fr ✓)
cvt: cold_upload=0 dyn_reup=0 sdl_fallback=0          (conversion already free)
```

Conclusions (see issue #52 comments + memory `solarus-blackscreen-engine-hang-diagnosis`):

- **A9-bound; the fabric is idle.** Rendering is already offloaded; the wall is host CPU.
- **`emit` (112ms) is the wall** — per-draw host cost of ~3,758 tile draws (~30µs each:
  Solarus `tile.draw()` dispatch + renderer `emit_draw` = `map_blend` + upload-cache lookup +
  clip + ring-write).
- **The draws are 98% animated tiles**, not sprites. `NonAnimatedRegions` flattens only
  *static* tiles into 512×256 cells (cap 25); every animated tile is drawn individually each
  frame. `eng_cpp` (engine update) is only ~15ms — not the prize. Conversion is free (`cvt=0`).

**Goal:** collapse the ~3,758 per-tile draws into per-tileset **tile-list commands** the
fabric expands, taking A9 from ~137ms → ~25-35ms (~7fps → ~35-42fps, the fabric floor).

### Non-goals

- Reducing the *fabric* cost (23.8ms / ~42fps floor). That's a later lever (animated-region
  caching); this design deliberately stops at the floor.
- Batching entities (64/fr) or static cells (already batched). Out of scope.
- ARGB8888 source conversion offload — conversion is already free (`cvt=0`); not this work.

## Architecture & data flow

Four layers; the per-tile cost dies at the first two, the fabric does the pixels:

```
ENGINE (Solarus core)   Entities::draw animated-tile loop: extract (src_rect, dst_xy)
                        per tile via a draw-free TilePattern query, append to a batch
                        grouped by (tileset_image, blend, flags). [kills per-tile DISPATCH]
      │ one batch per (tileset texture, blend)
      ▼
RENDERER (MisterBlitter) resolve the tileset texture handle ONCE; build the entry array;
                        emit ONE BLT_OP_TILELIST.            [kills per-tile map_blend/upload/emit]
      │ header (ring) + entry array (VRAM tile-list buffer)
      ▼
FABRIC (blitter_top →    decode header; stream N entries from VRAM; composite each via the
        comp_pipeline)   EXISTING per-blit datapath (texture base warm).   [~same 23.8ms]
      │
      ▼
GOLDEN (blitter_ref.c)   blt_execute TILELIST = loop N entries as BLITs. Bit-exact == N BLITs.
```

**Core invariant:** a TILELIST of N entries is **pixel-identical** to N individual
`BLT_OP_BLIT`s with the shared params. True by construction; gated in sim against the
reference model (the project's standard RTL-vs-golden pattern).

## Command ABI

New opcode `BLT_OP_TILELIST = 5` (next free after `STAGE=4`). One 32-byte header command
(reusing `blt_cmd_t`) + a separate VRAM **entry array**.

### Header (`blt_cmd_t` field mapping)

| `blt_cmd_t` field | TILELIST meaning |
|---|---|
| `opcode` | `BLT_OP_TILELIST` |
| `blend_mode`, `format`, `flags`, `alpha`, `colorkey` | **shared** blend params for the batch |
| `src_off`, `src_stride` | **shared** tileset texture base offset + row stride |
| `src_x`, `src_y` | tileset texture dims (w, h) — source-addressing bounds |
| `w` `\|` `h<<16` | **entry count N** (32-bit, packed like STAGE packs size) |
| `dst_x`, `dst_y` → one u32 | byte offset of the entry array in the tile-list VRAM buffer |
| `_pad[3]` | reserved (zero) |

### Entry (12 bytes, `3×u32`, naturally aligned)

```c
typedef struct {              // BLT_OP_TILELIST entry
    uint16_t src_x, src_y;    // tile's sub-rect origin in the tileset
    uint16_t w, h;            // tile size (8/16/…)
    int16_t  dst_x, dst_y;    // signed dst (offscreen-cullable, like BLIT)
} blt_tile_entry_t;
```

~3,758 tiles → ~45 KB/frame.

### Reference-model semantics (`blt_execute`, the golden contract)

```
case BLT_OP_TILELIST:
  for i in 0..N-1:
      e = entries[entry_off + i]
      blit_one(fb, heap, header_shared_params,
               e.src_x, e.src_y, e.w, e.h, e.dst_x, e.dst_y)   // == one BLT_OP_BLIT
```

So **TILELIST ≡ N BLITs** by definition. The bit-exact gate is
`blt_execute(tile-list) == blt_execute(expanded N blits)`, plus the RTL-vs-golden diff.

### ABI placement / vendoring

`blitter_ref.h`, `blitter_ref.c`, `blt_emitter.{h,c}` are **vendored** from
`github.com/gmcnaught/mister-fpga-blitter` ("edit upstream + re-copy"). The opcode, entry
struct, `blt_execute` case, and `blt_tile_list(...)` emitter API land **upstream first**, then
re-copy into `patches/mister/blitter/`.

### Deliberate ABI choices

- **Entry array in VRAM, not inline in the ring** — keeps the command fixed 32 bytes (ring
  parser structurally unchanged) and decouples entry-array size from ring capacity.
- **Shared params in the header, not per entry** — valid because a batch is one tileset + one
  blend + one flags set by construction; transform/colormod tiles escape rather than bloat the
  entry.
- **Flip (`BLT_F_HFLIP`/`VFLIP`) is part of the batch key, not per entry.** Solarus tile
  patterns are flip-free in the common case (the pattern bakes orientation into its source
  rect), so in practice all tiles share `flags=0`; a pattern that ever sets flip simply forms a
  separate sub-bucket (≤4 combinations) or escapes. This keeps the entry at 12 bytes.

## Engine-side batching (Solarus core)

### Draw-free extraction (new virtual)

```cpp
// TilePattern.h — default false = "not batchable, draw me normally"
virtual bool get_draw_region(const Point& dst_position, const Tileset& tileset,
                             Rectangle& out_src, Point& out_dst) const { return false; }
```

- `SimpleTilePattern`: returns `position_in_tileset` + `dst_position` → `true`.
- `AnimatedTilePattern`: returns the **current frame's** src rect (same computation `draw()`
  already does) + `dst_position` → `true`.
- `Parallax/SelfScrolling` (and any future scrolling pattern): default `false` → **escape**.

This bypasses the `Drawable`/`Surface::draw`/`SurfaceImpl` dispatch per tile.

### Batched loop (`Entities::draw`, the `tiles_in_animated_regions[layer]` loop)

```cpp
for tile in tiles_in_animated_regions[layer]:
    if (!tile.overlaps(*camera) && tile.is_drawn_at_its_position()) continue;
    const TilePattern& p = tile.get_tile_pattern();
    Rectangle src; Point dst;
    if (p.get_draw_region(tile_dst_pos(tile, camera), tileset, src, dst))
        batch[tileset_image].push_back({src, dst});   // cheap append
    else {
        flush_open_batches();                          // preserve paint order
        tile.draw(*camera);                            // escape: unchanged path
    }
flush_all_batches();   // → renderer.draw_tile_batch(...) per bucket
```

**Draw-order correctness.** Tiles paint back-to-front; batching must not reorder overlapping
tiles. Within one `(tileset_image, blend)` bucket, push order is preserved. An escape tile, or
a bucket switch, **flushes open batches first**, so paint order is identical to today.
(Animated-region tiles are co-planar within a layer; flush-on-break makes it correct regardless.)

### Renderer API (new virtual on `Renderer`)

```cpp
virtual void draw_tile_batch(const SurfaceImpl& tileset_image, BlendMode blend,
                             const std::vector<TileBatchEntry>& entries);
```

- **`SDLRenderer`** (software fallback / non-MiSTer build): loops `draw_region` over the
  entries — pixel-identical to today.
- **`MisterBlitterRenderer`**: resolves the tileset texture handle **once** via the upload
  cache, maps blend once, writes the entry array to the VRAM tile-list buffer, emits one
  `BLT_OP_TILELIST` via `blt_tile_list(...)`. On upload-fail / blend-escape → fall back to
  looping `emit_draw` per entry (never a software composite; fabric is the sole renderer).

### Files / mechanism

`TilePattern.h`, `SimpleTilePattern.cpp`, `AnimatedTilePattern.cpp` (query),
`Entities.cpp` (loop), `Renderer.h` + `SDLRenderer` (virtual + fallback),
`mister_blitter_renderer` (fabric emit). Engine-core edits land as **idempotent
`build_engine.sh` patch blocks** (the established reset-and-patch mechanism). The `Entities.cpp`
draw-loop patch is a single well-anchored block. Batching is gated behind env
`SOLARUS_TILEBATCH` (default on) for HW A/B and instant rollback.

## Fabric processing & VRAM layout

### Command FSM (`blitter_top.sv`)

`comp_pipeline` is **unchanged** — it already composites one blit descriptor. We only add the
descriptor *source* (entry stream vs single ring command):

```
S_FETCH_CMD:  opcode==TILELIST → latch shared {src_off, src_stride, format, blend, alpha,
                                 flags, tex_w, tex_h}; N = w|h<<16; entry_ptr={dst_x,dst_y}; i=0
S_TL_ENTRY:   DMA-read 12-byte entry[i] → form per-blit descriptor (shared header + entry rect)
              → issue to comp_pipeline
S_TL_WAIT:    on pass-done: i++; i<N ? S_TL_ENTRY : S_FETCH_CMD
```

Shared `src_off` is constant across entries → `P_SRC` atlas addressing stays warm.

### Entry read path

- **(recommended)** read entries through the existing source-read master (treat the tile-list
  buffer as another DDR/SDRAM region) — reuses arbitration, no new bus client.
- A dedicated entry-prefetch FIFO (overlap entry[i+1] fetch with composite[i]) is **deferred**
  — 12-byte fetch is tiny vs the composite and the fabric is idle.

### VRAM layout (extend the existing DDR map)

| Region | Today | Change |
|---|---|---|
| Control block (`C_SUBMIT`…) | `0x3B000000` | — |
| Command ring | 512 KB | — |
| **Tile-list buffer (NEW)** | — | **128 KB, double-buffered (2×64 KB)**, ping-ponged by `target_buf` |
| Source heap / SDRAM atlas | — | — |

Host `blt_emitter` gets a third cursor (`tile_list_alloc`) reset in `blt_begin_frame`,
mirroring the per-frame command-list reset. Double-buffering matches the existing frame N /
N-1 producer-scanout discipline so the fabric never reads a half-written entry array.

### Coherency / failure

Entry array written by the A9, read by the fabric within the existing submit/done handshake —
no new barrier. Entries reference the already-staged tileset texture (steady-state `cvt=0`), so
no new staging coherency. A malformed/zero-N TILELIST is a no-op (advance), like `NOP`/cull. No
new on-fabric escape path (the host emits the per-tile path when it can't batch).

## Validation, rollout & success metric

### Bit-exact gate (load-bearing)

1. **Reference-model self-equivalence** (host, no HW): randomized batches assert
   `blt_execute(tile-list) == blt_execute(expanded N blits)`.
2. **RTL-vs-golden** (sim, gating): new `tb_tilelist` drives `blitter_top`+`comp_pipeline`,
   compares `comp_fbram` to the reference model — bit-exact. Cover: 1 entry, N entries,
   overlapping dst (draw-order), partial/full offscreen (cull), each blend mode, ARGB4444
   per-pixel alpha, N spanning multiple source-fetch bursts. Full existing suite must still pass.
3. **Host A/B on HW**: `SOLARUS_TILEBATCH` on vs off renders identically (static-area
   screenshot diff).

### Build/deploy stages (each independently verifiable)

- **Stage 1 — host + reference model** (`blitter_ref`/`blt_emitter` + tests). No HW. Gate: test 1.
- **Stage 2 — RTL + sim.** FSM states + `tb_tilelist`. Gate: test 2 + no regression.
- **Stage 3 — engine batching** (`build_engine.sh` blocks + renderer emit),
  `SOLARUS_TILEBATCH` default **off**. Verify `SDLRenderer` fallback first (CI type-check +
  `draw_region` loop = identical pixels).
- **Stage 4 — RBF + HW.** Build RBF (seed-pinned per STA discipline), deploy coupled
  (RBF + engine, per the #52 coupled-deploy lesson). Flip `SOLARUS_TILEBATCH=1`. Gate: test 3
  + diag banner.

### Success metric (measured)

Re-capture the same heavy area with the existing instrumentation:

| Signal | Now | Target (batched) |
|---|---|---|
| `emit` | ~112ms | **~5-15ms** |
| host draws (anim tiles) | 3,758 emit_draws | **~1-3 tile-list cmds** (fabric still does 3,758 composites) |
| `A9` | ~137ms | **~25-35ms** |
| `fps` | ~6.7 | **~35-42** (fabric floor 23.8ms) |

Ship criterion: A/B-identical pixels **and** a measured A9/emit drop landing near the fabric
floor. If fps stalls well short of ~40 with `emit` collapsed, the next limiter is the fabric
floor (the deferred animated-region-caching lever), not this work.

### Rollback

`SOLARUS_TILEBATCH=0` reverts to the per-tile path instantly (engine env flag, no redeploy);
the RTL TILELIST path is simply unused.

## Risks / open flags

- **Draw-order across buckets** — mitigated by flush-on-break; `tb_tilelist` overlapping-dst
  case + the static-area A/B screenshot are the proof.
- **Vendored ABI** — opcode/entry struct/`blt_execute` must land upstream and be re-copied, not
  edited only in-tree.
- **`Entities.cpp` structural patch** — larger than existing idempotent blocks; kept to one
  well-anchored block, behind the env flag.
- **Fabric-floor ceiling** — this work targets ~42fps, not 60. Reaching 60 needs the separate
  animated-region-caching lever (out of scope here).

## Related

- Issue #52 (comments record the validated attribution + lever ranking).
- Memory: `solarus-blackscreen-engine-hang-diagnosis` (data + lever ranking),
  `fpga-comp-pipeline-cycle-profile` (fabric floor), `fpga-fb-in-bram-feasibility`.
- Instrumentation added this session (`g_me_draw_*` / `g_me_upd_*` counters, `[blitter drawcat]`
  / `[blitter engcpp]` banners) is the measurement harness for the success metric.
