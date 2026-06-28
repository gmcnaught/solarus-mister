# Resident Tile-List (Tier A engine + Tier B fabric) — design + plan

**Issue #52 follow-up.** Status: design. Branch: `worktree-agent-a5cb75201f5472293`
(forked from `master`/`847e64b`). Author: resident-tilelist work session 2026-06-27.

## Problem

HW-profiled (see memory `solarus-tilelist-dumb-emitter` + `solarus-blackscreen-engine-hang-diagnosis`):
after #52's dumb-emitter BLT_OP_TILELIST landed, a heavy area is **A9-bound** (~17 fps,
~52 ms/frame). ~20 ms of that is `Entities::draw` **re-walking ~3758 animated tiles every
frame** to rebuild the tile-list entry buffer — *even standing still*. Each tile costs a
`tile.overlaps(camera)` rect test, a virtual `get_tile_pattern()`, a virtual
`get_draw_region()` (resolves `frames[final_frame_index]`), a `Point` construct and a
`vector::push_back`, then per-bucket `memcpy` + emit.

A prior naive cache (invalidate the *whole* list on *any* phase tick) got 0 % hit because,
with many patterns, the *union* ticks almost every frame. **NOTE: that broken ANIMCACHE is
NOT on this branch's master base — it lives on the unmerged `perf/issue52-engcpp-animcache`.
This work implements the resident list FRESH; it does not reuse the animcache code.**

### Key static-content insight (verified against upstream Solarus v1.6)

`AnimatedTilePattern` (`work/solarus/.../AnimatedTilePattern.{h,cpp}`):
- A tile pattern is **shared** by every tile referencing that pattern id in a tileset
  (`Tile::get_tile_pattern()` returns a reference into the `Tileset`). There are only a
  **handful of distinct animated patterns** per scene.
- `get_draw_region(dst, tileset, out_src, out_dst)` returns `out_src =
  frames[final_frame_index]` (mirror_loop ping-pong resolves `final_frame_index`),
  `out_dst = dst`. **`out_src` does not depend on the tileset arg**; it depends only on the
  pattern's `frame_index`. `parallax` returns `false` (escape).
- `frame_index` advances only in `AnimatedTilePattern::update()` (time-gated by
  `frame_delay`), *not* every frame.

So while the camera is still and the map/tileset unchanged: the **set of visible animated
tiles and their `dst` positions is identical frame-to-frame**; only the per-pattern
`src` rect changes, and only when that pattern *ticks*. The dst, tileset bucket, blend and
paint order are all invariant.

## Design — two gated tiers over one resident-list infra

Both gates default **OFF** (OFF == current #52 behavior, byte-for-byte).

- `SOLARUS_TILERESIDENT`  — Tier A (engine only, runs on the CURRENT RBF).
- `SOLARUS_TILERESIDENT_HW` — Tier B (needs the new RBF; implies Tier A's plumbing).

### Shared resident list

A **resident tile list** held in the DDR `TL_BUF` region (`0x3BF40000`, the same region the
fabric already reads for #52 TILELIST entries). It is built by walking the animated tiles
**ONCE** and rebuilt **ONLY** on a scene-signature change — never on a phase tick. Entries
stay in **draw order** and are patched **in place** (paint order preserved, no regrouping).

**Scene signature** = `(map ptr, map.get_tileset() id/ptr, camera vp.x, vp.y)`. This covers
every approved invalidation trigger:
- camera move → vp changes,
- map change → map ptr changes,
- tileset change / animated-tile-set change → tileset id changes.

(Per-tile tileset overrides within a map are static, so they are safe under a fixed
map+vp+tileset signature.)

Each resident entry is tagged with its **pattern token** = `const TilePattern*` (0 for
patterns that never animate). The renderer groups entries by token so a ticked pattern's
entries can be patched together.

### Invalidation matrix

| Event                                   | Action            | Per-frame cost |
|-----------------------------------------|-------------------|----------------|
| map change / tileset (anim-set) change  | **REBUILD** list  | full walk (rare) |
| camera viewport top-left moves          | **REBUILD** list  | full walk (while scrolling) |
| a layer contains an escape (parallax/multi-pattern) | that layer falls back to the per-tile walk (recorded as non-fast) | per-tile (rare layers) |
| a pattern's `final_frame_index` changed (tick) | **SRC-PATCH** that pattern's entries in place, resubmit | scatter 8 B/entry of ticked patterns |
| nothing ticked + camera still           | **NO-OP RESUBMIT** (re-emit headers only) | ~0 |

### Tier A (engine, no RBF) — `SOLARUS_TILERESIDENT`

Per frame:
1. `Entities::draw` computes the scene signature once.
2. **Signature matches (fast path):** do **not** walk tiles. For each distinct animated
   pattern token (a handful), re-resolve `src` via `get_draw_region` and ask the renderer to
   patch entries whose stored src changed; then per layer emit the recorded TILELIST
   header(s) at the layer's paint position. Nothing ticked → headers only (near-zero).
3. **Signature differs (build path):** walk `tiles_in_animated_regions[layer]` per layer,
   recording each batchable tile's `(token, src, dst)` into the renderer's resident store
   (which writes the DDR entries and groups offsets by token); escapes flush the open bucket
   and `tile.draw(*camera)` as today, marking the layer non-fast.

Target: ~20 ms → ~2–5 ms animated-tile cost. Diag counter `[blitter resident]`:
rebuilds / src-patches / no-op resubmits / patched-entries per 60 fr.

### Tier B (fabric, new RBF) — `SOLARUS_TILERESIDENT_HW`

Moves src resolution into the fabric so the A9 per-frame animated-tile cost → ~0 (it writes
only a tiny per-pattern current-frame table, ~tens of bytes/frame).

**ABI additions** (single source of truth `blt_wire.h` / `blitter_ref.h`, mirrored in
`blitter_defs.vh`):

- `BLT_OP_TILELIST_RES = 6` — resident/pattern-indexed tile list. Header is the TILELIST
  header (shared tex/blend/format/flags, `w|h<<16 = N`, `dst_x|dst_y<<16 = entry byte
  offset`).
- `blt_tile_entry_res_t` — **8-byte** entry, qword-aligned (one entry == one aligned qword,
  no straddle window):
  ```c
  typedef struct { uint16_t pattern_id; int16_t dst_x, dst_y; uint16_t _rsvd; } blt_tile_entry_res_t;
  ```
- **Frame-rect table (FRT)** — `frame_rect[pattern_id][final_frame_index]` → an 8-byte src
  rect `{u16 src_x, src_y, w, h}` (one qword per (pid,frame)). Resident in DDR at
  `FRT_BUF` and mirrored into fabric **BRAM** (loaded once per scene via
  `BLT_OP_FRT_UPLOAD = 7`). Sized `MAXP × MAXF` qwords (`MAXP=128`, `MAXF=8` ⇒ 1024 qwords
  = 8 KiB BRAM).
- **Current-frame table (CFT)** — `cur_frame[pattern_id]` → `u16` final_frame_index. Resident
  in DDR at `CFT_BUF` (`MAXP` u16 = 256 B). The A9 writes it each frame (only used pids).
  The fabric preloads it into a small BRAM at TILELIST_RES command start (one short burst),
  so per-entry resolution stays on-chip.
- `BLT_OP_FRT_UPLOAD = 7` — header carries DDR src offset + qword count; the fabric streams
  FRT DDR→BRAM. Emitted once per scene (when the FRT changes).

**Fabric per-entry resolution** (inside the existing II=1 stream): read entry qword
(`pattern_id`, `dst`) from `TL_BUF` (1 DDR read, same as #52) → `f = cft_bram[pid]` (1 cyc) →
`src = frt_bram[pid*MAXF + f]` (1 cyc) → issue the blit to `comp_pipeline` exactly like
OP_BLIT. The 2 BRAM cycles are hidden behind the SRCFILL-bound composite, so throughput is
unchanged. Parallax tiles stay on the per-tile escape path.

**Wire layout**: TILELIST_RES reuses the TILELIST header packing. FRT_UPLOAD packs
`src_off = FRT DDR byte offset`, `w|h<<16 = qword count`. The C ref model, host emitter and
RTL decode all read these from `blt_wire.h`.

## Memory map additions (host `mister_blitter_renderer.cpp` ⇄ fabric `blitter_defs.vh`)

Free space above the existing 64 KiB `TL_BUF` (`0x3BF40000..0x3BF50000`) up to the region
end (`0x3C000000`, ~704 KiB) hosts the new resident tables (Tier B):
- `FRT_BUF` = `0x3BF50000` (8 KiB) — `MAXP*MAXF` × 8-byte rects.
- `CFT_BUF` = `0x3BF52000` (256 B → round to 4 KiB) — `MAXP` × u16.
Host `OFF_FRTBUF`/`OFF_CFTBUF` static_assert-coupled to the fabric `FRT_BUF_QW`/`CFT_BUF_QW`
(same discipline as `OFF_TLBUF == TL_BUF_QW<<3`).

Tier A reuses `TL_BUF` for resident *entries*; the per-frame transient `blt_tile_list`
cursor is bumped past the resident high-water mark (`em.tl_used = resident_bytes` at
`begin_frame`) so a stray transient batch never clobbers resident entries.

## Validation

- Host ref-model self-test (`blitter_ref.c` `BLT_REF_SELFTEST`): a TILELIST_RES + FRT/CFT
  composites **bit-exact** to the equivalent N expanded per-tile BLITs (extends the existing
  `test_tilelist_equals_n_blits`). Added to `tests/run_tests.sh`.
- Host emitter self-test (`blt_emitter.c` `BLT_EMITTER_SELFTEST`): `blt_tile_list_res` emits
  the correct header + 8-byte entries; `blt_frt_upload`/`blt_cft_write` pack correctly.
- RTL sim gate `fpga/sim/tb_tilelist_res.sv` (icarus): fabric TILELIST_RES (with FRT_UPLOAD +
  CFT) renders a frame **pixel-identical** to the same frame as N expanded OP_BLITs — same
  structure as `tb_tilelist.sv`. Wired into `run_sims.sh`.
- `g++ -fsyntax-only` on `mister_blitter_renderer.cpp` (memory `fpga-renderer-native-typecheck`).
- Engine injections type-checked by re-running `scripts/build_engine.sh`'s python edits
  against the cloned tree are NOT possible here (no armhf build) — keep them idempotent and
  grep-guarded; HW build is the maintainer's gate.

## HW A/B recipe

Tier A (current RBF): launch with `SOLARUS_TILERESIDENT=1` (and `SOLARUS_BLITTER_DIAG=1`).
Confirm `[blitter resident]` shows `rebuilds` low (only on move/transition), `noop_resubmit`
high while standing, and the A9 `emit` phase drops vs `SOLARUS_TILERESIDENT` unset. Banner:
`[blitter resident] /60fr: rebuild=.. patch=.. noop=.. patched_entries=..`.

Tier B (new RBF): `SOLARUS_TILERESIDENT_HW=1`. Confirm `anim_tiles` host-side resolve cost
→ ~0 (the engine writes only CFT). Same `tb_tilelist_res` gate must be green in CI. Couple
the engine + RBF deploy (ABI lives in both).

## Plan (bite-sized, TDD)

Tier A:
1. AnimatedTilePattern accessors (`get_final_frame_index`, `get_num_frames`) via
   `build_engine.sh` injection.
2. Renderer resident store + new base-`Renderer` virtuals + diag counters
   (`mister_blitter_renderer.{h,cpp}`, `Renderer.{h,cpp}` injection). `g++ -fsyntax-only`.
3. `Entities::draw` fast/build path injection (`build_engine.sh`), gated `SOLARUS_TILERESIDENT`.

Tier B (TDD red→green):
4. ABI: `blt_wire.h` + `blitter_ref.h` (entry_res, FRT/CFT, opcodes) + `blitter_defs.vh`.
5. Ref model: `blt_execute` TILELIST_RES + FRT/CFT, `BLT_REF_SELFTEST` equivalence. Test fails→passes.
6. Emitter: `blt_tile_list_res`/`blt_frt_upload`/`blt_cft_write`, `BLT_EMITTER_SELFTEST`.
7. RTL: `blitter_top.sv` FRT BRAM + CFT BRAM + TILELIST_RES/FRT_UPLOAD FSM.
8. Sim gate: `fpga/sim/tb_tilelist_res.sv`, wire into `run_sims.sh`. Icarus green.
9. Renderer Tier-B path (emit FRT_UPLOAD on rebuild, CFT each frame) gated `SOLARUS_TILERESIDENT_HW`.
</content>
</invoke>
