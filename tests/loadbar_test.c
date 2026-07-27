/* Host unit tests for loadbar.h — cell math and Loading... bitmap runs (issue #72).
 * The renderer itself can't be unit-tested on the host (pulls in SDL/Solarus),
 * so the only branch-worthy logic — cell math (fraction + clamp + divide-by-zero
 * guard) and the Loading... bitmap's run extraction — is factored into loadbar.h
 * and exercised directly here.
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

    /* ---- Loading... bitmap run extraction ---- */
    loadbar_run_t runs[LOADBAR_LABEL_MAX_RUNS];

    /* Row 7 is the descender row: only 'g' has ink, 3px at x=49. */
    CHECK(loadbar_label_runs(7, runs, LOADBAR_LABEL_MAX_RUNS) == 1, "row7 -> 1 run");
    CHECK(runs[0].x0 == 49 && runs[0].len == 3, "row7 run = (49,3) g descender");

    /* Row 1: only 'L' stem (x=0) and 'd' ascender (x=28). */
    CHECK(loadbar_label_runs(1, runs, LOADBAR_LABEL_MAX_RUNS) == 2, "row1 -> 2 runs");
    CHECK(runs[0].x0 == 0  && runs[0].len == 1, "row1 run0 = (0,1) L stem");
    CHECK(runs[1].x0 == 28 && runs[1].len == 1, "row1 run1 = (28,1) d ascender");

    /* Row 6 is the baseline: densest row, 11 runs, incl. the three periods. */
    CHECK(loadbar_label_runs(6, runs, LOADBAR_LABEL_MAX_RUNS) == 11, "row6 -> 11 runs");
    CHECK(runs[0].x0 == 0  && runs[0].len == 5, "row6 run0 = (0,5) L foot");
    CHECK(runs[8].x0  == 57 && runs[8].len  == 1, "row6 period 1 at x=57");
    CHECK(runs[9].x0  == 65 && runs[9].len  == 1, "row6 period 2 at x=65");
    CHECK(runs[10].x0 == 73 && runs[10].len == 1, "row6 period 3 at x=73");

    /* Out-of-range rows yield nothing (no OOB read). */
    CHECK(loadbar_label_runs(-1, runs, LOADBAR_LABEL_MAX_RUNS) == 0, "row -1 -> 0");
    CHECK(loadbar_label_runs(LOADBAR_LABEL_H, runs, LOADBAR_LABEL_MAX_RUNS) == 0,
          "row H -> 0");

    /* Defensive guards: null out, non-positive max. */
    CHECK(loadbar_label_runs(6, NULL, LOADBAR_LABEL_MAX_RUNS) == 0, "null out -> 0");
    CHECK(loadbar_label_runs(6, runs, 0) == 0, "max 0 -> 0");

    /* max clamps rather than overflowing the caller's array. */
    CHECK(loadbar_label_runs(6, runs, 3) == 3, "row6 with max=3 -> 3 runs");

    /* Per-row run counts, locked against the authored bitmap. Called with an
     * oversized array so the function's own clamp to `max` cannot mask a row
     * that outgrew LOADBAR_LABEL_MAX_RUNS. */
    {
        loadbar_run_t big[64];
        static const int want[LOADBAR_LABEL_H] = { 3, 2, 8, 11, 11, 11, 11, 1 };
        for (int r = 0; r < LOADBAR_LABEL_H; r++) {
            int n = loadbar_label_runs(r, big, 64);
            CHECK(n == want[r], "per-row run count matches the authored bitmap");
            CHECK(n <= LOADBAR_LABEL_MAX_RUNS, "row fits LOADBAR_LABEL_MAX_RUNS");
        }
    }

    if (failures) { printf("loadbar: %d FAILURES\n", failures); return 1; }
    printf("loadbar: all checks passed\n");
    return 0;
}
