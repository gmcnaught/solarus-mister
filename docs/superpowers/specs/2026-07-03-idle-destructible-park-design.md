# Idle-destructible parking (`SOLARUS_IDLEPARK`) — design

**Date:** 2026-07-03
**Status:** design approved, pre-implementation
**Depends on:** PR #57 (`SOLARUS_IDLESKIP`, the idle predicate this reuses)

## Motivation

In a heavy Mystery-of-Solarus-DX overworld, `Entities::update()` walks `all_entities`
(a `std::list`) every logical tick, and Solarus's fixed 100 Hz catch-up runs that walk
~5–7× per displayed frame. ~600–800 of the entities are **idle grass/bushes**
(destructibles on the ground, never touched) whose `update()` is a no-op.

PR #57 (`SOLARUS_IDLESKIP`) early-outs the no-op `update()` but **still iterates** all
~700 every tick; the skip-*check* costs about as much as the update it replaces, capping
the win at +15%.

A throwaway probe (`SOLARUS_IDLELIST`, branch `probe/idlelist-throwaway`) that removes
idle destructibles from the *iteration* entirely measured, HW, same standing spot:

| Arm | fps | eng_cpp | entities | steps/fr |
|---|---|---|---|---|
| baseline | ~15.0 | ~43ms | ~25.5ms | ~6.6 |
| IDLESKIP (PR #57) | ~17.3 | ~35ms | ~20ms | ~5.7 |
| **IDLELIST probe** | **~23.5** | ~22ms | ~10.4ms | ~4.3 |

**The iteration, not the update, is the cost.** The probe is not shippable — it
over-skips, freezing a bush mid-cut. This feature makes that +57% correct.

## Goal / non-goals

**Goal:** idle destructibles are excluded from the per-tick update walk, while any
destructible that is being cut, regenerating, waiting to regenerate, moving, suspended,
or animating stays fully live. Env-gated (`SOLARUS_IDLEPARK`), default off, engine-only,
no ABI/RTL change.

**Non-goals:**
- Generic "sleeping" for arbitrary entity types (YAGNI — only destructibles measured).
- Touching the fabric/RTL, draw path, or collision path (all unaffected — see below).
- Changing game logic or timing (parked ≡ the update was already a proven no-op).

## Why it is correct to remove idle destructibles from the walk

1. **Draw is independent of the update walk.** `Entities::draw`/`entities_to_draw` and
   the compositor emit from the entity's own state; a parked destructible still renders.
   (Probe screenshot confirmed grass renders while parked.)
2. **Collision is driven by the mover, not the destructible.** A destructible is a
   detector; its collisions are checked when the **hero/sword moves**
   (`Hero::update` → check-collision-with-detectors → quadtree query →
   `Destructible::notify_collision*`). The destructible's own `update()` is not what
   receives collisions, so parking it cannot miss a cut.
3. **A parked destructible is by definition a proven no-op this tick** — it satisfies the
   PR #57 `solarus_destructible_skippable` predicate, so skipping the whole call changes
   no observable state and fires no callback.

## Wake / sleep state machine

A destructible's idle→active transitions all originate **outside** its own `update()`:

- **Cut / lift / destroy:** every path funnels through
  `Destructible::play_destroy_animation()` (Destructible.cpp:444, the sole
  `is_being_cut = true`) — reached from `notify_collision` (sword),
  `notify_collision_with_hero`, and `notify_action_command_pressed` (lift).
- **Explode:** `Destructible::explode()`.
- **Regeneration lifecycle (self-sustaining once woken):** after a cut, a regenerating
  destructible runs a 10 s `waiting_for_regeneration` timer that is polled **inside**
  `update()` (`System::now() >= regeneration_date`). Therefore once woken it must stay
  active across the whole `is_being_cut → waiting_regen → is_regenerating → on_ground`
  chain — it only returns to idle after regeneration completes.
- **Exotic / Lua:** a quest could animate a destructible's sprite or give it a movement
  with no C++ chokepoint. Handled by the re-scan backstop below.

**Sleep** happens when an active destructible, after updating, again satisfies the idle
predicate (back to `on_ground`, no movement/stream, static sprite, not suspended).

## Architecture (Approach 1, destructible-scoped)

Confined to `Entities` (container + walk) and `Destructible` (wake hooks).

### Data structure

- **`entities_to_update`** — the list the update loop walks: `all_entities` **minus
  currently-parked (sleeping) destructibles**. So it contains every non-destructible plus
  every *active* destructible. `all_entities` is unchanged (queries/draw still use it).
- Each destructible carries a `bool parked` flag and, for O(1) unlink, a cached
  handle (iterator) into `entities_to_update`. (Container choice — `std::list` with
  cached iterators vs. swap-pop `std::vector` — is an implementation-plan detail; the
  invariant is O(1) wake and O(1) sleep.)

### Update loop (gated)

```
for (entity : entities_to_update) {
    if (!being_removed && type != CAMERA) entity->update();
}
// after updating, park any destructible that is now idle again (sleep check)
```

Non-gated path is the stock `all_entities` walk (bit-identical to today).

### Membership maintenance

- **`add_entity`:** insert into `entities_to_update` (destructibles start active; the
  first sleep-check parks them within one tick — bounded, cheap).
- **removal path (`remove_marked_entities`):** unlink from `entities_to_update` if present.
- **wake (`play_destroy_animation`, `explode`, and any future movement hook):** if parked,
  re-insert into `entities_to_update`, clear `parked`.
- **sleep (post-update check):** if the idle predicate holds, unlink from
  `entities_to_update`, set `parked`.

### Re-scan backstop

Every **N = 30** ticks, walk **all** destructibles (via `all_entities` or a typed cache)
and wake any that fail the idle predicate but are parked. Catches Lua-driven sprite
animation / movement with no C++ hook. Cut response is always instant via the hooks and
does not depend on the re-scan. O(n_destructibles) amortized over 30 ticks ≈ negligible.

*(Possible refinement, not in v1: phase-stagger the re-scan across destructibles to avoid
a synchronized O(n) spike every 30th tick. Deferred — profile first.)*

## Edge cases

- **Map load / teardown:** on new map, `entities_to_update` is rebuilt from the fresh
  `all_entities`; all destructibles start active and park within a tick.
- **`is_being_removed`:** guarded in the loop (as today); a destructible removed mid-cut
  is unlinked in the removal path.
- **Suspend/resume (pause):** independent of the walk — `Entities::set_suspended`
  iterates `all_entities` separately (Entities.cpp:1144), so a parked destructible still
  receives `set_suspended`. A destructible only needs `update()` while suspended to no
  useful end (its `update()` early-returns on `is_suspended()`), so parking across a
  suspend is safe; no special handling required.
- **Gate off:** zero behavioural change — stock walk.

## Testing

**Host (unit):**
- Membership-transition test: wake adds exactly once (idempotent), sleep removes,
  double-wake/double-sleep are no-ops, removal unlinks. Reuse the PR #57 predicate as the
  sleep oracle.
- Invariant: `entities_to_update` == `all_entities` minus parked destructibles, after any
  sequence of add/wake/sleep/remove.

**HW (device 192.168.20.81), same heavy overworld save:**
- **Standing:** fps ≈ probe (~22–23), destructible bucket ~absent, no fatal.
- **Cutting grass:** cut several bushes — they animate, drop treasure, and (if
  regenerating) regrow after ~10 s. This is the correctness case the probe could not do.
- **A/B vs gate-off** for the fps delta; screenshot for visual parity.

## Rollout

Env-gated default off, like `SOLARUS_IDLESKIP`. If HW-clean (standing win + cutting +
regen all correct), it supersedes `IDLESKIP` for destructibles; decide then whether to
make it the default or keep gated. Ships engine-only (`deploy.py --no-rbf`).
