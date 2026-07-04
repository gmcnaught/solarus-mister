/* Host unit test for the incremental re-scan sweep-range helper (SOLARUS_IDLEPARK).
 *
 * The backstop re-scan sweeps all destructibles over RESCAN_PERIOD ticks at an even
 * ~n/period per tick (no O(n) spike). This locks the arithmetic: per-tick count is
 * ceil(n/period), the cursor advances by that count mod n, and repeatedly stepping the
 * cursor covers every index at least once within `period` ticks. Edge cases: n==0,
 * n<period (count==1), a mid-sweep resize.
 *
 * Build+run (from repo root):
 *   cc -Wall -Wextra -O2 -I patches/mister tests/idlepark_test.c -o /tmp/idlepark_test \
 *     && /tmp/idlepark_test
 */
#include "mister_idlepark.h"
#include <stdio.h>

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s (line %d)\n", msg, __LINE__); failures++; } \
} while (0)

/* ceil(n/period) entries per tick; cursor wraps mod n. */
static void test_count_and_advance(void)
{
    int start, count, next;
    solarus_idlepark_sweep_range(0, 700, 30, &start, &count, &next);
    CHECK(count == 24, "ceil(700/30)=24 per tick");   /* 700/30 = 23.33 -> 24 */
    CHECK(start == 0, "start at cursor");
    CHECK(next == 24, "cursor advances by count");

    solarus_idlepark_sweep_range(690, 700, 30, &start, &count, &next);
    CHECK(count == 24, "count independent of cursor");
    CHECK(start == 690, "start at cursor near end");
    CHECK(next == (690 + 24) % 700, "cursor wraps mod n (=14)");
}

/* n==0: nothing to scan, cursor pinned at 0 (no div-by-zero). */
static void test_empty(void)
{
    int start, count, next;
    solarus_idlepark_sweep_range(0, 0, 30, &start, &count, &next);
    CHECK(count == 0, "n==0 -> count 0");
    CHECK(start == 0 && next == 0, "n==0 -> cursor pinned 0");
}

/* n<period: at least 1 per tick so small maps still fully covered. */
static void test_small_n(void)
{
    int start, count, next;
    solarus_idlepark_sweep_range(3, 5, 30, &start, &count, &next);
    CHECK(count == 1, "ceil(5/30)=1");
    CHECK(start == 3, "start at cursor");
    CHECK(next == 4, "advance by 1");
    solarus_idlepark_sweep_range(4, 5, 30, &start, &count, &next);
    CHECK(next == 0, "wrap from last index to 0");
}

/* Coverage: from any start, `period` successive ticks visit every index at least once. */
static void test_full_coverage_in_period(void)
{
    const int n = 700, period = 30;
    int seen[700] = {0};
    int cursor = 123;  /* arbitrary start */
    for (int t = 0; t < period; ++t) {
        int start, count, next;
        solarus_idlepark_sweep_range(cursor, n, period, &start, &count, &next);
        for (int k = 0; k < count; ++k) seen[(start + k) % n] = 1;
        cursor = next;
    }
    int covered = 1;
    for (int i = 0; i < n; ++i) if (!seen[i]) covered = 0;
    CHECK(covered == 1, "every index covered within `period` ticks");
}

int main(void)
{
    test_count_and_advance();
    test_empty();
    test_small_n();
    test_full_coverage_in_period();
    if (failures) { printf("idlepark: %d FAILED\n", failures); return 1; }
    printf("idlepark: all passed\n");
    return 0;
}
