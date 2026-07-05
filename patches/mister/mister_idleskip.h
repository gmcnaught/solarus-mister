/*
 * [perf] Idle-destructible update-skip predicate (SOLARUS_IDLESKIP).
 *
 * A Solarus Destructible (grass/bush/pot/...) runs its full update() every logical
 * tick — and the 100Hz catch-up amplifies that ~4-5x per displayed frame. In a
 * heavy overworld ~600-660 of these run per frame (~4.5ms) doing nothing: an
 * uncut, non-regenerating, static, movement-less destructible's Destructible::update()
 * and the base Entity::update() it calls neither change observable state nor fire a
 * callback this tick. This predicate lets the injected Destructible::update()
 * early-out for exactly those, under the SOLARUS_IDLESKIP gate.
 *
 * CONSERVATIVE BY DESIGN: return true (skip) ONLY when every path that could do
 * work this tick is inactive. Any doubt -> return false (run the normal update).
 * The 7 inputs mirror the branches in Destructible::update() + Entity::update():
 *   - suspended         : is_suspended() — game/entity paused; let normal handling run
 *   - being_cut         : is_being_cut — finishing the cut anim (-> remove or regen)
 *   - waiting_regen     : is_waiting_for_regeneration() — tick times the regen start
 *   - regenerating      : is_regenerating — regen anim playing (-> back to on_ground)
 *   - has_movement      : movement != nullptr — movement + collision-on-move must run
 *   - has_stream        : an active stream action — must run
 *   - sprite_may_change : any sprite could advance a frame / fire a callback this tick
 *
 * Header-only, zero deps, C and C++ safe (see tests/idleskip_test.c).
 */
#ifndef MISTER_IDLESKIP_H
#define MISTER_IDLESKIP_H

#ifdef __cplusplus
extern "C" {
#endif

static inline int solarus_destructible_skippable(
    int suspended, int being_cut, int waiting_regen, int regenerating,
    int has_movement, int has_stream, int sprite_may_change) {
  return !suspended && !being_cut && !waiting_regen && !regenerating
      && !has_movement && !has_stream && !sprite_may_change;
}

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif /* MISTER_IDLESKIP_H */
