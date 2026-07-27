/* Host unit tests for loadbar.h — cell math and Loading... bitmap runs (issue #72).
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
    /* empty: 0 staged -> 0 cells */
    CHECK(loadbar_cells_filled(32, 0, 331) == 0, "0/331 -> 0 cells");
    /* full: staged == total -> every cell */
    CHECK(loadbar_cells_filled(32, 331, 331) == 32, "331/331 -> 32 cells");
    /* half: 165/330 -> 16 cells */
    CHECK(loadbar_cells_filled(32, 165, 330) == 16, "165/330 -> 16 cells");
    /* floor: 1/331 -> 0 (monotonic, never negative) */
    CHECK(loadbar_cells_filled(32, 1, 331) == 0, "1/331 -> 0 cells (floor)");
    /* divide-by-zero guard: total == 0 -> 0 */
    CHECK(loadbar_cells_filled(32, 5, 0) == 0, "total==0 -> 0 cells");
    /* over-count clamp: staged > total -> full (never over-wide) */
    CHECK(loadbar_cells_filled(32, 400, 331) == 32, "400/331 clamp -> 32 cells");
    /* no 32-bit overflow at large counts */
    CHECK(loadbar_cells_filled(32, 3000000u, 6000000u) == 16,
          "3e6/6e6 -> 16 cells (no overflow)");

    if (failures) { printf("loadbar: %d FAILURES\n", failures); return 1; }
    printf("loadbar: all checks passed\n");
    return 0;
}
