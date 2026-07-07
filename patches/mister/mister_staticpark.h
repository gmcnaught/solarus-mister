/*
 * [perf] Static-entity update-skip predicate (SOLARUS_STATICPARK).
 *
 * Walls, teletransporters, and destinations (~230 of ~390 per-tick entity
 * updates in the heavy village room) never override Entity::update() -- they
 * run the base Entity::update() (update_sprites + movement->update() +
 * update_stream_action() + update_state()), which is a provable no-op when
 * the entity has no sprite that can advance a frame or fire a callback, no
 * movement, no active stream action, no custom state attached, and isn't
 * suspended. Reuses the same conservative-by-design contract as
 * mister_idleskip.h's destructible predicate, minus the 3 Destructible-only
 * inputs, plus has_state (base Entity exposes set_state() generically, e.g.
 * Camera's TrackingState, so it must be checked even though these 3 types
 * don't use it today).
 *
 * CONSERVATIVE BY DESIGN: return true (skip) ONLY when every path that could
 * do work this tick is inactive. Any doubt -> return false.
 *
 * Header-only, zero deps, C and C++ safe (see tests/staticpark_test.c).
 */
#ifndef MISTER_STATICPARK_H
#define MISTER_STATICPARK_H

#ifdef __cplusplus
extern "C" {
#endif

static inline int solarus_staticpark_skippable(
    int suspended, int has_movement, int has_stream, int has_state,
    int sprite_may_change) {
  return !suspended && !has_movement && !has_stream && !has_state
      && !sprite_may_change;
}

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif /* MISTER_STATICPARK_H */
