/*
 * [perf] Incremental re-scan sweep-range for SOLARUS_IDLEPARK.
 *
 * The idle-destructible parking backstop re-scans all destructibles over RESCAN_PERIOD
 * ticks, ~n/period per tick, to catch wakes with no C++ chokepoint (Lua-driven sprite
 * animation / movement). This computes, for a persistent cursor over n destructibles,
 * the contiguous slice to scan this tick and the next cursor position. Spreading the
 * scan avoids an O(n) spike every Nth tick (a jitter / deadline hazard).
 *
 * The slice is [start, start+count) taken modulo n by the caller (it may wrap past the
 * end of the array). Every index is visited at least once per `period` ticks.
 *
 * Header-only, zero deps, C and C++ safe (see tests/idlepark_test.c).
 */
#ifndef MISTER_IDLEPARK_H
#define MISTER_IDLEPARK_H

#ifdef __cplusplus
extern "C" {
#endif

static inline void solarus_idlepark_sweep_range(
    int cursor, int n, int period,
    int* out_start, int* out_count, int* out_next_cursor) {
  if (n <= 0) { *out_start = 0; *out_count = 0; *out_next_cursor = 0; return; }
  if (period < 1) period = 1;
  if (cursor < 0 || cursor >= n) cursor = 0;   /* defensive clamp */
  int count = (n + period - 1) / period;       /* ceil(n/period), >=1 for n>=1 */
  *out_start = cursor;
  *out_count = count;
  *out_next_cursor = (cursor + count) % n;
}

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif /* MISTER_IDLEPARK_H */
