/* Host unit test for loadbar_fill_w — the pure bar-width math (issue #72).
 * The renderer itself can't be unit-tested on the host (pulls in SDL/Solarus),
 * so the only branch-worthy logic (fraction + clamp + divide-by-zero guard) is
 * factored into loadbar.h and exercised directly here.
 *
 * Build+run (from repo root):
 *   cc -Wall -Wextra -O2 -I patches/mister \
 *       tests/loadbar_test.c -o /tmp/loadbar_test && /tmp/loadbar_test
 */
#include "loadbar.h"
#include <stdio.h>
#include <stdint.h>

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s (line %d)\n", msg, __LINE__); failures++; } \
} while (0)

int main(void)
{
    /* empty: 0 staged -> 0 width */
    CHECK(loadbar_fill_w(200, 0, 331) == 0, "0/331 -> 0");
    /* full: staged == total -> full track */
    CHECK(loadbar_fill_w(200, 331, 331) == 200, "331/331 -> 200");
    /* half: 165/330 -> 100 */
    CHECK(loadbar_fill_w(200, 165, 330) == 100, "165/330 -> 100");
    /* floor: 1/331 -> 0 (monotonic, never negative) */
    CHECK(loadbar_fill_w(200, 1, 331) == 0, "1/331 -> 0 (floor)");
    /* divide-by-zero guard: total == 0 -> 0 */
    CHECK(loadbar_fill_w(200, 5, 0) == 0, "total==0 -> 0");
    /* over-count clamp: staged > total -> full track (never over-wide) */
    CHECK(loadbar_fill_w(200, 400, 331) == 200, "400/331 clamp -> 200");
    /* no 32-bit overflow at large counts */
    CHECK(loadbar_fill_w(200, 3000000u, 6000000u) == 100, "3e6/6e6 -> 100 (no overflow)");

    if (failures) { printf("loadbar: %d FAILURES\n", failures); return 1; }
    printf("loadbar: all checks passed\n");
    return 0;
}
