/* Host unit test for BLT_OP_BGPLANE_WRITE + blt_bgplane_write_cell() emitter (Phase 3b).
 * Pure C, runs natively (no device).
 * Build+run: cc -I patches/mister/blitter tests/blt_bgplane_write_test.c \
 *              patches/mister/blitter/blt_emitter.c \
 *              patches/mister/blitter/blt_alloc.c \
 *              -o /tmp/blt_bgplane_write_test && /tmp/blt_bgplane_write_test
 */
#include "blitter_ref.h"
#include "blt_emitter.h"
#include "blt_wire.h"
#include <stdio.h>
#include <stdint.h>
#include <string.h>

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s (line %d)\n", msg, __LINE__); failures++; } \
} while (0)

/*
 * Field mapping for BLT_OP_BGPLANE_WRITE:
 *   sdram_qword_offset -> cmd.dst_x | cmd.dst_y<<16  (low 16 | high 16)
 *   dst_stride_qw      -> cmd.src_x                   (row stride in qwords)
 *   flags              -> cmd.flags                   (BLT_F_BGCOV, Task 4)
 */

/* Helper: decode the nth command from the ring and return it as a blt_cmd_t. */
static blt_cmd_t ring_read(const blt_emitter_t *e, int n)
{
    blt_cmd_t c;
    memset(&c, 0, sizeof(c));
    blt_unpack_cmd(e->ring + (size_t)n * BLT_CMD_BYTES, &c);
    return c;
}

/* 1. Basic: blt_bgplane_write_cell appends a BGPLANE_WRITE command with the
 *    right opcode/fields and advances cmd_count. */
static void test_bgplane_write_basic(void)
{
    static uint8_t ring[16 * BLT_CMD_BYTES];
    static uint8_t heap[4096];
    blt_emitter_t e;
    blt_emitter_init(&e, ring, sizeof(ring), heap, sizeof(heap));
    blt_begin_frame(&e, 0, 0, 0);

    int before = e.cmd_count;
    int rc = blt_bgplane_write_cell(&e, 0x12345, 160, 0);
    int after = e.cmd_count;

    CHECK(rc == 0,             "blt_bgplane_write_cell returns 0 on success");
    CHECK(after == before + 1, "blt_bgplane_write_cell bumps cmd_count by 1");

    blt_cmd_t c = ring_read(&e, before);
    CHECK(c.opcode == BLT_OP_BGPLANE_WRITE, "decoded opcode == BLT_OP_BGPLANE_WRITE");

    /* sdram_qword_offset packed as dst_x (low 16) | dst_y<<16 (high 16) */
    uint32_t decoded_offset = (uint32_t)(uint16_t)c.dst_x | ((uint32_t)(uint16_t)c.dst_y << 16);
    CHECK(decoded_offset == 0x12345, "dst_x|dst_y<<16 carries the qword offset");

    /* stride packed in src_x */
    CHECK((uint32_t)(uint16_t)c.src_x == 160, "src_x carries the stride argument");

    CHECK(c.flags == 0, "flags 0 when not requested");
    CHECK(e.overflow == 0, "no overflow flag set");
}

/* 2. Round-trip: the wire encode/decode preserves offset and stride. */
static void test_bgplane_write_roundtrip(void)
{
    static uint8_t ring[16 * BLT_CMD_BYTES];
    static uint8_t heap[4096];
    blt_emitter_t e;
    blt_emitter_init(&e, ring, sizeof(ring), heap, sizeof(heap));
    blt_begin_frame(&e, 0, 0, 0);

    /* Use values that exercise upper 16 bits of offset */
    blt_bgplane_write_cell(&e, 0xDEADBEEFu, 0x4321u, 0);

    uint8_t wire[BLT_CMD_BYTES];
    memcpy(wire, e.ring, BLT_CMD_BYTES);    /* first command */

    blt_cmd_t c;
    blt_unpack_cmd(wire, &c);

    CHECK(c.opcode == BLT_OP_BGPLANE_WRITE,  "round-trip: opcode");
    uint32_t off = (uint32_t)(uint16_t)c.dst_x | ((uint32_t)(uint16_t)c.dst_y << 16);
    CHECK(off == 0xDEADBEEFu,                 "round-trip: offset (full 32-bit)");
    CHECK((uint32_t)(uint16_t)c.src_x == 0x4321u, "round-trip: stride");
}

/* 2b. [Task 4] BLT_F_BGCOV round-trip: passing the flag through
 *     blt_bgplane_write_cell must survive pack/unpack in cmd.flags. */
static void test_bgplane_write_bgcov_flag(void)
{
    static uint8_t ring[16 * BLT_CMD_BYTES];
    static uint8_t heap[4096];
    blt_emitter_t e;
    blt_emitter_init(&e, ring, sizeof(ring), heap, sizeof(heap));
    blt_begin_frame(&e, 0, 0, 0);

    int rc = blt_bgplane_write_cell(&e, 0x555, 96, BLT_F_BGCOV);
    CHECK(rc == 0, "blt_bgplane_write_cell(BLT_F_BGCOV) returns 0 on success");

    blt_cmd_t c = ring_read(&e, 0);
    CHECK(c.opcode == BLT_OP_BGPLANE_WRITE, "bgcov: opcode preserved");
    uint32_t off = (uint32_t)(uint16_t)c.dst_x | ((uint32_t)(uint16_t)c.dst_y << 16);
    CHECK(off == 0x555, "bgcov: offset preserved");
    CHECK((uint32_t)(uint16_t)c.src_x == 96, "bgcov: stride preserved");
    CHECK(c.flags == BLT_F_BGCOV, "bgcov: c.flags == BLT_F_BGCOV after decode");
}

/* 3. Overflow: ring-full sets overflow and returns -1 without touching cmd_count. */
static void test_bgplane_write_overflow(void)
{
    /* Ring fits exactly 2 commands */
    static uint8_t ring[2 * BLT_CMD_BYTES];
    static uint8_t heap[4096];
    blt_emitter_t e;
    blt_emitter_init(&e, ring, sizeof(ring), heap, sizeof(heap));
    blt_begin_frame(&e, 0, 0, 0);

    /* Fill the ring */
    blt_bgplane_write_cell(&e, 0x100, 256, 0);
    blt_bgplane_write_cell(&e, 0x200, 512, 0);

    CHECK(e.overflow == 0, "no overflow before ring full");

    int before = e.cmd_count;
    int rc = blt_bgplane_write_cell(&e, 0x300, 768, 0);  /* must overflow */
    CHECK(rc == -1,            "blt_bgplane_write_cell returns -1 on overflow");
    CHECK(e.overflow == 1,     "overflow flag set on ring full");
    CHECK(e.cmd_count == before, "cmd_count unchanged on overflow");
}

/* 4. Regression: existing blt_fill/blt_blit encoding is not disturbed. */
static void test_fill_unaffected(void)
{
    static uint8_t ring[16 * BLT_CMD_BYTES];
    static uint8_t heap[4096];
    blt_emitter_t e;
    blt_emitter_init(&e, ring, sizeof(ring), heap, sizeof(heap));
    blt_begin_frame(&e, 0, 0, 0);

    blt_fill(&e, 10, 20, 100, 80, 0xF800u);
    blt_bgplane_write_cell(&e, 0x12345, 160, 0);

    blt_cmd_t fill_cmd = ring_read(&e, 0);
    blt_cmd_t bgp_cmd = ring_read(&e, 1);

    CHECK(fill_cmd.opcode == BLT_OP_FILL,   "fill opcode preserved");
    CHECK(fill_cmd.color == 0xF800u,         "fill color preserved");
    CHECK(fill_cmd.dst_x == 10,              "fill dst_x preserved");
    CHECK(fill_cmd.dst_y == 20,              "fill dst_y preserved");
    CHECK(fill_cmd.w == 100,                 "fill w preserved");
    CHECK(fill_cmd.h == 80,                  "fill h preserved");

    CHECK(bgp_cmd.opcode == BLT_OP_BGPLANE_WRITE, "bgplane_write follows fill correctly");
}

int main(void)
{
    test_bgplane_write_basic();
    test_bgplane_write_roundtrip();
    test_bgplane_write_bgcov_flag();
    test_bgplane_write_overflow();
    test_fill_unaffected();

    if (failures == 0) { printf("ALL PASS\n"); return 0; }
    printf("%d FAILURE(S)\n", failures);
    return 1;
}
