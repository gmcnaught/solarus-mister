# DDR texture allocator (issue #14, allocator-first)

**Date:** 2026-06-15
**Issue:** #14 (epic solarus-fpga-renderer). Scope: allocator-first (not the full
MisterSurfaceImpl/AD2 rewrite — deferred).
**Status:** approved design, implementing.

## Problem

The blitter source heap (`blt_emitter`, DDR region `0x3B008000 .. 0x3BF00000`, ~15 MB)
is a **bump allocator**: `upload16` advances `heap_used`; the only way to reclaim is
`blt_heap_reset` (wipe everything). `invalidate(surf)` and dirty re-uploads drop the
`handles` cache entry but **never free the bytes**, so old-scene atlases accumulate
until an overflow forces a full reset. Consequences:

- Map transitions hold two scenes' atlases co-resident → heap overflow → black frames
  (the #24 bug; currently worked around by a per-edge full reset — a hack).
- The working set is never tight, so there's no reliable DDR headroom to later
  re-partition for a larger (map-sized) bg-cache (the motivating goal).

## Goal

Replace the bump allocator with a real **alloc/free/reuse** allocator so individual
surfaces are reclaimed when invalidated/dirtied — no leak, tight stable working set,
and overflow becomes a true out-of-memory condition rather than normal churn.

Non-goals (deferred): MisterSurfaceImpl / all-surfaces-DDR-resident (AD2); LRU
eviction; the heap/cache re-partition itself (this only *enables* it); any RBF change.

## Architecture

Three units, smallest-correct:

### 1. `blt_alloc` — pure-C offset allocator (new `blt_alloc.{h,c}`)
Manages free space within a `[base_off, size)` byte region. Knows nothing about DDR or
pixels — pure offset bookkeeping, so it is host-unit-testable in isolation.

```
void     blt_alloc_init(blt_alloc_t*, uint32_t base_off, uint32_t size);
uint32_t blt_alloc(blt_alloc_t*, uint32_t size);          // -> aligned offset, or BLT_ALLOC_FAIL
void     blt_free(blt_alloc_t*, uint32_t offset, uint32_t size);  // returns + coalesces
void     blt_alloc_reset(blt_alloc_t*);                   // back to one free block
uint32_t blt_alloc_used(const blt_alloc_t*);              // bytes outstanding (diag)
```

- **Algorithm:** **free-list, first-fit + coalescing** (the allocator tracks only FREE
  blocks). Allocations are rounded up to 8-byte alignment (fabric qword reads); `alloc`
  and `free` use the SAME rounding so blocks line up for coalescing. The **caller passes
  the size to `blt_free`** (the `blt_surface_ref_t`/`handles` entry carries it), so the
  allocator needs no allocated-block table — it just inserts the freed extent into the
  free-list and coalesces with adjacent free neighbors.
- **`BLT_ALLOC_FAIL`** sentinel (e.g. `0xFFFFFFFF`) on out-of-space.
- Bounded metadata (fixed-capacity node pool — no malloc on the A9 hot path).

### 2. `blt_emitter` integration
- `upload16` calls `blt_alloc(need)` instead of bumping `heap_used`; on `BLT_ALLOC_FAIL`
  sets `overflow` (same as today). The returned `blt_surface_ref_t` already carries
  `off`; record `size` so the renderer can free it.
- Add `blt_emitter_free(e, ref)` → `blt_free`. `blt_heap_reset` → `blt_alloc_reset`.

### 3. Renderer integration (`mister_blitter_renderer.cpp`)
- `handles` map value records the allocated block (offset + size).
- `invalidate(surf)` → `blt_emitter_free` the block(s) for that surface, then erase the
  map entry. **This is the core leak fix.**
- Dirty re-upload (a `mark_src_dirty` surface re-uploaded) → free the old block before
  allocating the new.
- Keep the overflow → full-reset path as a **safety fallback** (true OOM).
- **Remove the #24 transition edge-reset hack** once the allocator is HW-validated:
  proper free-on-invalidate reclaims old-scene atlases, so the two scenes no longer
  co-reside. (Keep the alias-disable + bg-cache-LEARN parts of #24 — those are
  unrelated and correct.)

## Data flow

upload path: `draw()` needs src → `handles` hit? reuse : `blt_alloc`+memcpy→DDR, record.
free path: `invalidate`/dirty/scene-change → `blt_free(block)` → coalesce.
fabric: unchanged — reads pixels at `ref.off` exactly as today (no RTL change).

## Error handling

- `blt_alloc` returns `BLT_ALLOC_FAIL` → emitter `overflow=1` → existing handling
  (heap_reset_pending → full reset next frame). So worst case = today's behavior.
- Double-free / free-unknown-offset: assert in debug, no-op in release (defensive).

## Testing

- **Host unit test** (`blt_alloc_test.c`, runs in the build container, no device):
  alloc/free/reuse, coalescing (free-then-realloc fits), fragmentation under a
  representative create→free→create sequence, exhaustion returns FAIL, reset. This is
  the #14 AC and gates implementation (TDD: test first).
- **HW validation:** deploy; walk + several map transitions + house enter/exit;
  confirm no overflow/escape in diag (heap_used stays bounded, no churn), screenshots
  render correct, no regression to gameplay/#23/#24. Then remove the edge-reset hack
  and re-validate.

## Success criteria

- Allocator unit test passes (alloc/free/reuse/coalesce/exhaust/reset).
- HW: transitions no longer overflow *without* the edge-reset hack; heap working set
  is bounded and stable across scene changes; no visual regression.
- Engine-only; gameplay byte-path unchanged when nothing is freed.
