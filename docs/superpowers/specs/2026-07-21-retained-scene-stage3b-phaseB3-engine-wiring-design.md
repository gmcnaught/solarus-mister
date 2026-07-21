# Retained-Scene Compositor — Stage 3b Phase B3 design (engine wiring + GRID_BUF allocator + HW gate)

**Date:** 2026-07-21
**Status:** design approved (brainstorm), pending spec review → implementation plan
**Parent design:** `docs/superpowers/specs/2026-07-20-retained-scene-stage3b-tilemap-channel-design.md` (§2 = the host contract this refines)
**Predecessors merged:** Phase A (bake deletion, PR #130), B1 (grid wire format, PR #132), B2 (`tilemap_unit` RTL + bgplane RTL removal, PR #133)
**Branch base:** `origin/master` @ `291187c` (B2 merged)

---

## 0. What B3 is

B1 delivered the host **emitter** (`blt_grid_list`, `blt_grid_list_init`, `grid_build.h`,
`grid_cell.h`, the `blt_ref_tilemap` golden model, the 2 MiB GRID_BUF region). B2 delivered the
**fabric** (`tilemap_unit`, `BLT_OP_TILEMAP=11`, `MAXP=256`) and removed the bgplane RTL. Neither
is wired to the engine — nothing builds a grid from real map data or emits `BLT_OP_TILEMAP` in
gameplay.

**B3 is the engine/renderer wiring** that closes that gap, behind `SOLARUS_TILEMAPCH` (default
OFF), plus the GRID_BUF allocator (which B3 owns) and the HW gate. It is the last phase of Stage
3b.

This document records the B3-specific decisions and refines the parent design's §2 against the
**current (post-B2) code**. Where §2 and this doc agree, §2 is the authority on rationale; this
doc is the authority on the concrete B3 seams and the decisions resolved in the B3 brainstorm.

---

## 1. Scope (resolved)

**In:**
- The parent design's §2 host scope (grid build + per-frame `BLT_OP_TILEMAP` emit at the static
  seam) behind `SOLARUS_TILEMAPCH`, **default OFF**.
- The two engine patches (§4).
- The GRID_BUF allocator, incl. the two items B2 deferred to B3 (§5).
- The per-layer fallback **wiring**, with the coverage-threshold trigger present but disabled (§7).
- A host↔RTL cell-bitfield cross-check in `test_wire_constants.py` (§8).
- The DDR GRID_BUF-tail HW-soak (§8).
- The map-119 + map-3 HW gate (§9).

**Out (unchanged from parent §6, re-confirmed in the B3 brainstorm):**
`SelfScrollingTilePattern` support; `resident_`/flat-command removal (Stage 4 — and it is B3's
flag-OFF A/B reference, so it *cannot* be removed here); source/upload path clean-laning;
60 fps / `comp_pipeline` throughput; scanout; #124 (overlay under-dims translucent menus). The
coverage-threshold fallback firing is also out — wired but disabled (§7).

The bucket-replay path (`res_static_ops` / `res_emit_static_bucket_`) is the flag-OFF path and
the A/B reference. It stays intact throughout B3.

---

## 2. Data lifecycle

**Build on map change.** The resident BUILD walk already calls
`resident_record_static(layer, scroll_ratio, tileset_image, blend, entries)`
(`patches/mister/mister_blitter_renderer.cpp:2983`), storing raw src/dst rects into
`res_static_buckets`. B3:
1. Threads a **pattern token** per entry (engine patch #1, §4) and interns it via the existing
   `res_pat_index` (§6).
2. At build finalize (`res_arm_`), converts each static layer's recorded tiles into a
   `blt_grid_tile_t[]` (pid = intern slot; `cell_x/cell_y` = `dst/8`; `w_cells/h_cells` =
   `src.w/8`, `src.h/8`) and runs `blt_grid_build()` **directly into the GRID_BUF DDR region**
   (§5), producing one cell array per layer plus its `cells_off`.

Rebuild edge is the unchanged `resident_begin_frame` `(map_id, tileset_id)` signature miss
(`:3044`), memoized per frame. A mid-map `notify_tileset_changed` leaves grid geometry valid —
only the pattern→src table is rebuilt (that already happens on the animated path).

**Emit per frame.** `resident_emit_static_layer(layer)` (`:3203`) — the seam whose own comment
reads *"Phase B replaces this body with the tilemap grid op at this same seam"* — emits, flag ON,
**one `BLT_OP_TILEMAP` per layer** via `blt_grid_list(tex, blend, colorkey, alpha, flags,
cells_off[layer], grid_w, grid_h, bias_x, bias_y, pal_color)`. The bias is the per-frame
camera/parallax offset computed exactly as `res_emit_static_bucket_` computes it today
(`ratio<=1 → bias=-camera`; `ratio>1 → bias=camera/ratio-camera`; plus the Stage-3a scroll bias).
Cells are static and never rewritten per frame — only the header + bias move.

## 3. The seam (flag-gated)

```
resident_emit_static_layer(layer):
  d->flush_sprites_before_other_op();               // unchanged — keep sprites under this op
  if (tilemapch && grid_ok[layer])
      emit BLT_OP_TILEMAP for layer                 // new (§2)
  else
      for op in res_static_ops where op.layer==layer // today's body, verbatim
          res_emit_static_bucket_(op.bk)
```

One insertion point. Flag OFF, or any layer marked `!grid_ok` by the allocator (§5), reproduces
today's output byte-for-byte.

## 4. Two engine patches (git-am series — they modify pristine upstream files)

1. **Pattern tokens on the static path.** `resident_record_static` currently discards pattern
   identity (`:3006-3011` push raw src rects). Add a `tokens` parameter threaded through
   `include/solarus/graphics/Renderer.h`, `src/entities/NonAnimatedRegions.cpp:record_static`,
   and the renderer override. Runtime identity is the `TilePattern*` as `uintptr_t`; the existing
   `res_pat_index` interns it to a dense slot shared with animated patterns (`BLT_MAXP=256`). That
   dense slot **is** the grid cell's 12-bit pid. There is no engine-side stable integer pattern
   id; the host intern index is the id.
2. **Map dimensions at load** (`Map::get_width8()/get_height8()`) so grids are sized, not grown.
   The renderer holds `map_id` as an opaque `uintptr_t` and has no `Map&`; hook is
   `Entities::notify_map_starting()` after the `build()` loop, publishing `(w8, h8)` to the
   renderer.

Both are whole-of-upstream edits → **series patches**, not `patches/mister/` whole-file copies.
`grep` the series before editing to confirm the target lines aren't already carried.

## 5. GRID_BUF allocator — B3 owns this (closes two B2-deferred items)

- **Bump allocator over the 2 MiB GRID_BUF region** (`OFF_GRIDBUF` / `GRID_BUF_BYTES`, already
  defined post-B1/B2), reset at each map rebuild. Each static layer's cell array (`grid_w *
  grid_h * 4` bytes) is allocated sequentially and **qword (8-byte) aligned**. This makes
  `cells_off` alignment a property guaranteed by the allocator rather than pinned only by a TB
  assertion (B2-deferred item #2, closed).
- **`grid_cap` enforced.** `blt_grid_list_init` records `grid_cap` but the emitter does not check
  it (B2-deferred item #1). B3's allocator enforces it: if a layer's cell array does not fit the
  remaining GRID_BUF, **that layer is marked `!grid_ok` and falls back to bucket-replay** (§3),
  with a loud log line. This is decision (C) for the GRID_BUF budget: graceful, per-layer, always
  renders correctly (just slower for an over-budget third-party quest). The shipping quest never
  trips it — worst map = 1.23 MiB of cells across all 3 layers vs. 2 MiB.

## 6. Pattern table — no new budget code

Static patterns intern into the **existing** `res_pat_index` / `res_patterns` (cleared per scene
at `:2868`, `BLT_MAXP=256`). The existing overflow guard `if (pi >= BLT_MAXP) { res_fatal; … }`
(`:2955-2965`) **is** decision (C) for the pattern-table budget: a map with >256 distinct
patterns is a table-index correctness violation and hard-fails, exactly as the animated path does
today. B3 adds nothing here beyond feeding static tokens into the same intern. (Shipping worst =
251 distinct patterns, map 3.)

## 7. Per-layer fallback wiring (trigger OFF)

The `grid_ok[layer]` gate (§3) is the fallback mechanism. In B3 it is driven **only** by
GRID_BUF-fit (§5). The parent design's §2.8 *coverage-threshold* trigger (route a sparse,
mostly-empty layer back to bucket-replay) is wired but its threshold is set so it never fires.
Reason (parent §2.8): the honest threshold needs measurement that does not exist pre-HW, and a
guessed constant in the hot path is the exact error class that produced Stage 2's bad sprite
estimate. B3's HW gate produces the coverage/cyc-px data a follow-up would use to enable it.

## 8. Small closures

- **Cell-bitfield cross-check.** `scripts/tests/test_wire_constants.py` pins opcode 11 and
  GRID_BUF base/size but not the cell bit positions (B1→B2 handoff item #2). Add a host↔RTL
  assertion for `pid[11:0] / sub_x[15:12] / sub_y[19:16] / run_m1[23:20] / spare[31:24]` matching
  `grid_cell.h` and the `tilemap_unit` decode. This is the one guard B1/B2 left to the sim diff
  alone.
- **DDR GRID_BUF-tail HW-soak.** The grown tail `0x3C000000..0x3C200000` (BLT_DDR 16→18 MiB) is
  inside the kernel reserved window and architecturally safe, but only the old 16 MiB was HW
  pattern-verified. Soak the grown tail before trusting live grid traffic (nothing read it in
  B1/B2).

## 9. Gates

Gate flag: `SOLARUS_TILEMAPCH`, **default OFF**.

**Objective (must pass):**
- **Bit-exact host grid walk vs. `blt_ref_tilemap`** — the #24 arena-probe 60/60 pattern; emit a
  scene from a known map/frame, assert descriptor + cell grid + pattern→src table contents and
  per-layer draw order.
- **Host suite** `patches/mister/build_host_tests.sh` (the CI gate).
- **`test_wire_constants.py`** including the new §8 bitfield assertion.
- **Renderer `g++ -fsyntax-only`** with the mandatory `-DMISTER_NATIVE_VIDEO
  -DMISTER_NATIVE_AUDIO` (CLAUDE.md recipe — omitting them type-checks almost nothing).
- **In-container** `scripts/docker_run.sh bash scripts/build_engine.sh`, verified by grepping
  `BUILD_EXIT`, not the task exit code.

**Visual (operator's eyes, never self-declared — memory `solarus-no-self-declared-visual-validation`):**
- **Map 119 "Outside world C3"** — the parallax acceptance scene (295 parallax entries vs 1
  elsewhere), small (640×752).
- **Map 3 "Outside world A3"** — 251 distinct patterns, the quest max; pins the `MAXP`/index
  margin.
- A/B `SOLARUS_TILEMAPCH` on vs off on both maps: no visible change is the pass condition (the
  grid walk is pixel-equivalent to bucket replay; §0.4 of the parent proves the sub-cell offset
  is exact).

**Measured and recorded, NOT gated:** `tilemap_unit` cyc/px on map 119 (Stage 3 spec §0.1 keeps
60 fps out of scope; record the number so the throughput workstream starts from measurement). The
grid-walk vs per-tile ratio is a *measured* worst-case 2.0× — expect up to ~2× transactions on a
small parallax scene, which is accepted.

## 10. Process discipline (recorded failure modes, not precautions)

- Build **inside the container** and grep `BUILD_EXIT`; host builds leave a `CMakeCache.txt` that
  blocks the container build. In-docker `git am` is flaky — patch on the host.
- `mister_blitter_renderer.{cpp,h}` and `patches/mister/blitter/` are **whole-file copies** (edit
  directly); the two engine patches (§4) are **series** patches (`export_patches.sh`).
- Deploy ships from `deploy/libs/`; **sha1-verify on device**. `deploy.py` exit 0 says nothing
  about which files moved.
- HW gate: leave `Solarus.s0` **empty**, load the core, launch with a private `S0_FILE` override
  — two concurrent engines wedge the host. Log to `/media/fat/logs/Solarus/`, never `/tmp`. Never
  blind-inject joypad input. **Confirm which RBF is loaded** — an opcode sent to a fabric with no
  arm falls through to FILL/BLIT and looks like a bug. Treat OSD interaction as a hazard.
- CI: the Windows RBF runner is flaky (shutdown-signal deaths ≠ RTL faults) — re-run, don't debug
  RTL on that signal.

---

## 11. Evidence index

| Claim | Source |
|---|---|
| B2 merged, base `291187c` | `git log origin/master`, PR #133 |
| Static seam = `resident_emit_static_layer`, comment says Phase B replaces it | `mister_blitter_renderer.cpp:3203-3211` |
| Static record path stores raw rects, no token | `mister_blitter_renderer.cpp:2983-3011` |
| Pattern-table overflow already `res_fatal` | `mister_blitter_renderer.cpp:2955-2965` |
| `res_pat_index` interns `TilePattern*`; cleared per scene | `mister_blitter_renderer.cpp:2868`, `:2904`, `:2951-2965` |
| `BLT_MAXP=256`; FRT relocated above GRID_BUF | `mister_blitter_renderer.cpp:307-313`, `:400-403` |
| GRID_BUF region defined (B1/B2) | `OFF_GRIDBUF` / `GRID_BUF_BYTES`, `mister_blitter_renderer.cpp:402` |
| Emitter has `grid_cap` field, not enforced | `blt_emitter.h:82`; `blt_grid_list_init` / `blt_grid_list` |
| Cell encoding + golden model | `grid_cell.h`; `blt_ref_tilemap` in `blitter_ref.c` |
| Grid build two-pass (paint, then runs) | `grid_build.h` |
| Worst map cells 1.23 MiB / 3 layers; max 251 patterns; 8px 100% / 16px 30% | census (parent §2.2, §2.5) |
| Grid-walk vs per-tile ratio worst 2.0× | B1 9-scenario measurement (handoff §"Measurements") |
| Static tile == exactly one pattern instance (sub-offset is subtraction) | `work/solarus/src/entities/Entities.cpp:819-823` (parent §0.4) |
| Camera/parallax bias formula | `res_emit_static_bucket_` (parent §2.4) |
| DDR tail grown 16→18 MiB, un-soaked | B1→B2 handoff §"Already-owed" |
| `test_wire_constants.py` lacks cell-bitfield pin | B1→B2 handoff item #2 |
