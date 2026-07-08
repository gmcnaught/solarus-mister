/* Host unit test for fps_overlay.h — the pure FPS-clamp math and the 7-segment
 * digit lookup table (OSD FPS Overlay feature). The renderer itself can't be
 * unit-tested on the host (pulls in SDL/Solarus), so only the branch-worthy
 * logic is factored out and exercised directly here, mirroring loadbar_test.c.
 *
 * Build+run (from repo root):
 *   cc -Wall -Wextra -O2 -I patches/mister \
 *       tests/fps_overlay_test.c -o /tmp/fps_overlay_test && /tmp/fps_overlay_test
 */
#include "fps_overlay.h"
#include <stdio.h>
#include <stdint.h>

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s (line %d)\n", msg, __LINE__); failures++; } \
} while (0)

int main(void)
{
    /* clamp: negative -> 0 */
    CHECK(fps_overlay_clamp(-5.0) == 0, "-5.0 -> 0");
    /* clamp: exact zero */
    CHECK(fps_overlay_clamp(0.0) == 0, "0.0 -> 0");
    /* round to nearest */
    CHECK(fps_overlay_clamp(59.6) == 60, "59.6 -> 60 (round)");
    CHECK(fps_overlay_clamp(59.4) == 59, "59.4 -> 59 (round)");
    /* in-range exact */
    CHECK(fps_overlay_clamp(99.0) == 99, "99.0 -> 99");
    /* saturate at the 2-digit ceiling */
    CHECK(fps_overlay_clamp(99.5) == 99, "99.5 -> 99 (saturate, would round to 100)");
    CHECK(fps_overlay_clamp(250.0) == 99, "250.0 -> 99 (saturate)");

    /* segment table: every entry must be a 7-bit value (bits 0-6 only) */
    for (int d = 0; d < 10; d++) {
        CHECK((FPSOV_SEGMENTS[d] & 0x80) == 0, "segment table entry is 7-bit");
    }
    /* spot-check known digit shapes */
    CHECK(FPSOV_SEGMENTS[0] == 0x3F, "digit 0 shape");
    CHECK(FPSOV_SEGMENTS[1] == 0x06, "digit 1 shape (2 segments: b,c)");
    CHECK(FPSOV_SEGMENTS[8] == 0x7F, "digit 8 shape (all 7 segments)");
    /* digit 1 must be exactly 2 segments lit (the classic "thin" digit) */
    int ones_bits = 0;
    for (int b = 0; b < 7; b++) if (FPSOV_SEGMENTS[1] & (1 << b)) ones_bits++;
    CHECK(ones_bits == 2, "digit 1 lights exactly 2 segments");
    /* digit 8 must light all 7 segments */
    int eight_bits = 0;
    for (int b = 0; b < 7; b++) if (FPSOV_SEGMENTS[8] & (1 << b)) eight_bits++;
    CHECK(eight_bits == 7, "digit 8 lights all 7 segments");

    if (failures) { printf("fps_overlay: %d FAILURES\n", failures); return 1; }
    printf("fps_overlay: all checks passed\n");
    return 0;
}
