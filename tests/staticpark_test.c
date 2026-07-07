/* Host unit test for the static-entity update-skip predicate
 * (SOLARUS_STATICPARK). Locks the truth table: each veto condition alone
 * must forbid the skip.
 *
 * Build+run (from repo root):
 *   cc -Wall -Wextra -O2 -I patches/mister \
 *       tests/staticpark_test.c -o /tmp/staticpark_test && /tmp/staticpark_test
 */
#include "mister_staticpark.h"
#include <stdio.h>

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s (line %d)\n", msg, __LINE__); failures++; } \
} while (0)

/* Inputs, in order: suspended, has_movement, has_stream, has_state,
 * sprite_may_change */

static void test_idle_static_is_skippable(void) {
    CHECK(solarus_staticpark_skippable(0,0,0,0,0) == 1,
          "idle static entity must be skippable");
}

static void test_each_condition_vetoes_skip(void) {
    CHECK(solarus_staticpark_skippable(1,0,0,0,0) == 0,
          "suspended must not be skipped (normal suspend handling)");
    CHECK(solarus_staticpark_skippable(0,1,0,0,0) == 0,
          "has_movement must not be skipped (movement + collision-on-move)");
    CHECK(solarus_staticpark_skippable(0,0,1,0,0) == 0,
          "has_stream must not be skipped (stream action must run)");
    CHECK(solarus_staticpark_skippable(0,0,0,1,0) == 0,
          "has_state must not be skipped (custom state update() must run)");
    CHECK(solarus_staticpark_skippable(0,0,0,0,1) == 0,
          "sprite_may_change must not be skipped (animated/looping sprite)");
}

static void test_combined_vetoes(void) {
    CHECK(solarus_staticpark_skippable(1,0,0,0,1) == 0,
          "suspended + animating must not be skipped");
    CHECK(solarus_staticpark_skippable(0,1,0,1,0) == 0,
          "movement + state must not be skipped");
}

int main(void) {
    test_idle_static_is_skippable();
    test_each_condition_vetoes_skip();
    test_combined_vetoes();

    if (failures) { printf("staticpark: %d FAILED\n", failures); return 1; }
    printf("staticpark: all passed\n");
    return 0;
}
