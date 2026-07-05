# Fat-AABB hysteresis for `Quadtree::move` — design

**Date:** 2026-07-05
**Branch:** `perf/quadtree-fat-aabb`
**Goal:** Cut per-move quadtree churn (the `g_me_ent_qtree_ns` bucket of enemy
move-bookkeeping) by skipping the tree remove+add when an entity's true bounding
box has not moved beyond a stored, inflated box.

## Motivation

Every enemy pixel-step calls `Entity::notify_position_changed`
(`src/entities/Entity.cpp:1857`), which does per step:

1. `notify_bounding_box_changed` → `Entities::notify_entity_bounding_box_changed`
   (`src/entities/Entities.cpp:1529`) → `quadtree->move(entity, max_bounding_box)`.
2. `update_ground_below` → `Map::get_ground` (another quadtree query + z-sort).
3. detector-collision checks.
4. obstacle tests inside the movement.

`Quadtree::move` (`include/solarus/containers/Quadtree.inl:165`) reinserts
(full `remove` + `add` tree walk) whenever the box differs *at all*. An enemy
sliding 1px therefore re-walks the tree every frame even though its tree
residency barely changes. This is pure churn and is the target of this change.

Prior profiling (banner `[blitter entsplit]`, hand-rolled) put enemy `move`
bookkeeping (`integ`) at ~3.5ms/frame on the heavy overworld, split across the
quadtree reinsert and the ground re-query. This change attacks the quadtree
reinsert share; the ground re-query is a separate, riskier follow-up (not in
scope here).

## Approach: fat-AABB (broad-phase) hysteresis

Store an **inflated** ("fat") box in the quadtree instead of the exact box.
Skip the reinsert while the entity's true box stays within the stored fat box —
the standard Box2D broad-phase trick.

On `move(element, new_true_box)`:

- **`stored_fat.contains(new_true_box)`** → do nothing to the tree, return
  `true`. The element stays registered under its old fat box.
- **otherwise** → `remove` (using the stored fat box, which matches what the
  nodes hold) + `add` with a freshly inflated `fat = new_true_box` grown by
  `margin` on all four sides.

### Correctness (load-bearing)

The nodes and the `elements` map store the box used for placement — the exact
box right after the initial `add()`, and the inflated ("fat") box after the
first hysteresis reinsert. The load-bearing invariant is that **the stored box
always contains the true box**: it holds at `add()` (stored == true), and we
only *skip* a reinsert when `stored.contains(new_true)`, so it is preserved. An
element is registered in every node its stored box overlaps, and
`Node::get_elements` tests the stored box against the query region. Since
`new_true ⊆ stored`, any query rectangle that overlaps the true box also
overlaps the stored box, so the element is always found — **no misses**.

Extra false positives (a query that overlaps the fat margin but not the true
box) are harmless: every consumer already precisely re-tests candidates with
`Entity::overlaps()` — e.g. `Map::get_ground` at `src/core/Map.cpp:1168`, and
all collision code. This is the textbook broad-phase / narrow-phase split; the
quadtree is broad-phase only.

## Changes

All in the generic container plus one env read and tests. **No** entity,
movement, `Map`, or call-site changes.

1. **`include/solarus/containers/Quadtree.h`** — document that
   `ElementInfo::bounding_box` holds the *fat* box when the feature is enabled.
   No new field: the containment check needs only the stored fat box.

2. **`include/solarus/containers/Quadtree.inl` — `move()`** — add the hysteresis
   branch. Inflation via `Rectangle::add_xy(-m, -m)` + `add_width(2m)` /
   `add_height(2m)`; containment via the existing
   `Rectangle::contains(const Rectangle&)`.

3. **Margin source** — read once from `SOLARUS_QTREE_MARGIN` (pixels). A
   file-scope `static const int` read via `std::getenv`, referenced from
   `move()`. **`0` disables the feature**: when margin is 0, keep the current
   `it->second.bounding_box == bounding_box` equality short-circuit path exactly
   as today, so the disabled build is byte-identical in behavior to baseline and
   A/B is clean.

## Gating & rollout

Matches the project pattern (default off → HW A/B → bake default on):

- Ship **default 0 (off)**.
- Enable with `SOLARUS_QTREE_MARGIN=8` (one 8px tile) for HW A/B.
- The `g_me_ent_qtree_ns` counter already in `notify_position_changed` reads the
  win directly; compare enabled vs disabled on the heavy overworld.
- Once validated on HW, bake the default margin to 8.

## Testing (TDD, host-side)

Extend `tests/src/tests/Quadtree.cpp` (runs host-side, no device):

- **Skip-within-margin**: move an element by a sub-margin delta; assert the tree
  did not reinsert (membership/box unchanged) **and** `get_elements(new_true_box)`
  still returns it.
- **Reinsert-beyond-margin**: move past the margin; assert it is reinserted and a
  query at the old location no longer returns it.
- **No-miss invariant fuzz**: random-walk an element for many steps; after every
  step assert `get_elements(true_box)` contains the element. This is the
  guarantee the whole design rests on.
- **Disabled parity**: with margin 0, behavior matches baseline (equality
  short-circuit; reinsert on any change).

## Risk & rollback

- Off by default; margin 0 = no behavior change → trivial rollback.
- Query bloat is bounded by the small margin; the only real tradeoff is margin
  size (churn savings vs. extra false-positive candidates in ground/collision
  queries). Single tunable constant, measured on HW.

## Scope boundary

Touches only `Quadtree.{h,inl}`, one env read, and `tests/src/tests/Quadtree.cpp`.
Ground-query caching (bucket #2) and obstacle-test pruning are explicitly out of
scope and left as follow-ups.
