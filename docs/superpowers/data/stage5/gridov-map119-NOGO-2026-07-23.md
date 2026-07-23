# GRIDOV on map119 — NO-GO (HW-measured 2026-07-23)

Device 192.168.20.81, ship RBF Solarus_20260723.rbf, engine build 2026-07-23 17:50
(GRIDOV default-on + per-sub-layer GRIDSTATS + SDRAM-mux fix). Fixed spot
("119","from_dungeon_10").

## Verdict: GRIDOV delivers ZERO compositor win on map119.

| metric              | baseline (GRIDOV off) | GRIDOV on | Δ    |
|---------------------|-----------------------|-----------|------|
| comp                | 14.89 ms              | 14.88 ms  | ~0   |
| fabric_hw           | 20.63 ms              | 20.60 ms  | ~0   |
| resident tile_blits | 11,764/frame          | 11,764/frame | 0 |

## Root cause: the dominant cost is ANIMATED tile replay, which cannot be gridded.

- GRIDOV decomposes only STATIC overlapping buckets. On map119 it decomposed
  exactly ONE: `[blitter gridov] layer=1 K=3 bytes=211680`, and that bucket is
  ~empty in the visible window (`GRIDSTATS layer=1 sub=0..2/3 nonempty=0 runs=0`).
  It contributes ~0 to comp.
- The real cost = `[blitter resident]` path: **6 buckets, 4071 entries,
  ~1,300 patched (animated) entries/frame** (`patch_pass=60`), emitting
  **11,764 blits/frame** via resident tile-list replay.
- A grid is a STATIC structure (one pattern-id per cell). Animated tiles change
  pattern per frame, so they inherently cannot use the grid path. GRIDOV was
  never able to touch map119's dominant cost.

## Consequence for the sizing premise
The Phase-0 sizing ("~5-7ms coalescable per-tile overhead") assumed the tile
cost could be coalesced via the grid. That is FALSE for animated content. The
only coalescing that can touch map119 is run-merging IN the resident tile-list
emitter itself (merge horizontally-adjacent same-RESOLVED-pattern runs at emit
time) — the "Option 1" rejected during design as redundant with GRIDOV. It is in
fact the ONLY viable approach for animated tiles, and is a separate, larger lever.

## Disposition (user decisions 2026-07-23)
- Keep GRIDOV default-on (broad benefit on OTHER maps with real static overlapping
  tiles: door-roofs, interiors — the original door-roof-fix motivation). Requires
  broad pixel validation to ship safely.
- Pause map119 60fps chase. map119 stays vsync-paced at 30fps. Resident-path
  coalescing (Option 1) is the documented next lever if revisited.

## Cheap-pre-check lesson
The count-only pre-check (GRIDOV=1 + GRIDSTATS, tile_blits unchanged) would have
surfaced this NO-GO in ONE capture, before the productization cycle. Productize-
directly paid a full build/deploy cycle to learn the same thing. Task 2's
instrument is what made the diagnosis unambiguous.
