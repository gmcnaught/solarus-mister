/* Bit-layout pin for the 32-bit tilemap grid cell (Stage 3b Phase B1).
 * The fabric decodes these exact bit positions; a silent field move here
 * desynchronizes host and RTL. */
#include "blitter/grid_cell.h"
#include <stdio.h>
#include <string.h>

static int fails = 0;
#define CHECK(cond, ...) do { if (!(cond)) { \
    printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); fails++; } } while (0)

int main(void) {
    /* 1. Round-trip across the full range of every field. */
    for (uint16_t pid = 0; pid < 4096; pid += 7) {
        for (uint8_t sx = 0; sx < 16; ++sx) {
            for (uint8_t sy = 0; sy < 16; ++sy) {
                for (uint8_t r = 0; r < 16; ++r) {
                    blt_grid_cell_t c = blt_grid_cell_pack(pid, sx, sy, r);
                    CHECK(blt_grid_cell_pid(c) == pid, "pid %u != %u", blt_grid_cell_pid(c), pid);
                    CHECK(blt_grid_cell_sub_x(c) == sx, "sub_x %u != %u", blt_grid_cell_sub_x(c), sx);
                    CHECK(blt_grid_cell_sub_y(c) == sy, "sub_y %u != %u", blt_grid_cell_sub_y(c), sy);
                    CHECK(blt_grid_cell_run(c) == (uint8_t)(r + 1), "run %u != %u",
                          blt_grid_cell_run(c), (unsigned)(r + 1));
                }
            }
        }
    }

    /* 2. EXACT bit positions. These literals are the host<->RTL contract:
     *    pid=0x123, sub_x=4, sub_y=5, run_m1=6 -> 0x0065_4123 */
    blt_grid_cell_t k = blt_grid_cell_pack(0x123, 4, 5, 6);
    CHECK(k == 0x00654123u, "layout drifted: got 0x%08X want 0x00654123", k);

    /* 3. Spare bits [31:24] are written zero. */
    CHECK((blt_grid_cell_pack(0xFFF, 15, 15, 15) >> 24) == 0u, "spare bits not zero");

    /* 4. Empty sentinel. */
    blt_grid_cell_t e = blt_grid_cell_pack(BLT_GRID_PID_EMPTY, 0, 0, 0);
    CHECK(blt_grid_cell_is_empty(e), "empty sentinel not detected");
    CHECK(!blt_grid_cell_is_empty(blt_grid_cell_pack(0, 0, 0, 0)), "pid 0 wrongly reported empty");

    /* 5. run is remaining-from-here and is never zero — a zero run would make a
     *    walker emit a zero-width blit and fail to advance. */
    CHECK(blt_grid_cell_run(blt_grid_cell_pack(1, 0, 0, 0)) == 1, "minimum run must be 1");

    if (fails) { printf("test_gridcell: %d FAILURES\n", fails); return 1; }
    printf("test_gridcell: all checks passed\n");
    return 0;
}
