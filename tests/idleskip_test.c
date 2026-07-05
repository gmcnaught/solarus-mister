/* Host unit test for the idle-destructible update-skip predicate (SOLARUS_IDLESKIP).
 *
 * The heavy-overworld A9 profile (memory: solarus-heavy-area-profile-and-offloads)
 * shows ~600-660 destructible (grass/bush/pot) update() calls per displayed frame,
 * ~4.5ms, almost all of it idle busy-work: a static, uncut, non-regenerating
 * destructible's Destructible::update() — and the base Entity::update() it calls —
 * change no observable state and fire no callback this tick.
 *
 * solarus_destructible_skippable() is the pure predicate the injected
 * Destructible::update() consults (under SOLARUS_IDLESKIP) to early-out. It MUST
 * be conservative: skip ONLY when the update is provably a no-op. This test locks
 * the truth table so a future edit can't silently drop a veto (e.g. dropping the
 * being_cut guard would freeze a bush mid-cut).
 *
 * Build+run (from repo root):
 *   cc -Wall -Wextra -O2 -I patches/mister \
 *       tests/idleskip_test.c -o /tmp/idleskip_test && /tmp/idleskip_test
 */
#include "mister_idleskip.h"
#include <stdio.h>

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s (line %d)\n", msg, __LINE__); failures++; } \
} while (0)

/* The 7 inputs, in order:
 *   suspended, being_cut, waiting_regen, regenerating,
 *   has_movement, has_stream, sprite_may_change */

/* A fully idle, static destructible (uncut, not regenerating, no movement/stream,
 * static sprite, game running) is the ONLY skippable configuration. */
static void test_idle_static_is_skippable(void)
{
    CHECK(solarus_destructible_skippable(0,0,0,0,0,0,0) == 1,
          "idle static destructible must be skippable");
}

/* Each veto condition ALONE must forbid the skip (update() would do real work). */
static void test_each_condition_vetoes_skip(void)
{
    CHECK(solarus_destructible_skippable(1,0,0,0,0,0,0) == 0,
          "suspended must not be skipped (normal suspend handling)");
    CHECK(solarus_destructible_skippable(0,1,0,0,0,0,0) == 0,
          "being_cut must not be skipped (finishing cut anim -> remove/regen)");
    CHECK(solarus_destructible_skippable(0,0,1,0,0,0,0) == 0,
          "waiting_for_regeneration must not be skipped (times regen start)");
    CHECK(solarus_destructible_skippable(0,0,0,1,0,0,0) == 0,
          "regenerating must not be skipped (regen anim -> on_ground)");
    CHECK(solarus_destructible_skippable(0,0,0,0,1,0,0) == 0,
          "has_movement must not be skipped (movement + collision-on-move)");
    CHECK(solarus_destructible_skippable(0,0,0,0,0,1,0) == 0,
          "has_stream must not be skipped (stream action must run)");
    CHECK(solarus_destructible_skippable(0,0,0,0,0,0,1) == 0,
          "sprite_may_change must not be skipped (animated/looping sprite)");
}

/* Any combination that includes a veto is non-skippable (spot-check a few). */
static void test_combined_vetoes(void)
{
    CHECK(solarus_destructible_skippable(0,1,0,0,0,0,1) == 0,
          "being_cut + animating must not be skipped");
    CHECK(solarus_destructible_skippable(1,0,0,0,1,0,0) == 0,
          "suspended + movement must not be skipped");
    CHECK(solarus_destructible_skippable(0,0,1,1,0,0,0) == 0,
          "waiting + regenerating must not be skipped");
}

int main(void)
{
    test_idle_static_is_skippable();
    test_each_condition_vetoes_skip();
    test_combined_vetoes();

    if (failures) { printf("idleskip: %d FAILED\n", failures); return 1; }
    printf("idleskip: all passed\n");
    return 0;
}
