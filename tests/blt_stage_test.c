/* Host unit test for BLT_OP_STAGE + blt_stage() emitter (issue #19). Pure C,
 * runs natively (no device).
 * Build+run: cc -I patches/mister/blitter tests/blt_stage_test.c \
 *              patches/mister/blitter/blt_emitter.c \
 *              patches/mister/blitter/blt_alloc.c \
 *              -o /tmp/blt_stage_test && /tmp/blt_stage_test
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
 * Field mapping for BLT_OP_STAGE:
 *   off  -> cmd.src_off        (wire word u32[1])
 *   size -> cmd.w | cmd.h<<16  (wire word u32[3]; size is 32-bit, split across
 *                               the two uint16_t fields w and h, since STAGE has
 *                               no meaningful pixel rect. Reconstruct as
 *                               (uint32_t)c.w | ((uint32_t)c.h << 16).)
 */

/* Helper: decode the nth command from the ring and return it as a blt_cmd_t. */
static blt_cmd_t ring_read(const blt_emitter_t *e, int n)
{
    blt_cmd_t c;
    memset(&c, 0, sizeof(c));
    blt_unpack_cmd(e->ring + (size_t)n * BLT_CMD_BYTES, &c);
    return c;
}

/* 1. Basic: blt_stage appends a STAGE command with the right opcode/fields. */
static void test_stage_basic(void)
{
    static uint8_t ring[16 * BLT_CMD_BYTES];
    static uint8_t heap[4096];
    blt_emitter_t e;
    blt_emitter_init(&e, ring, sizeof(ring), heap, sizeof(heap));
    blt_begin_frame(&e, 0, 0, 0);

    int before = e.cmd_count;
    int rc = blt_stage(&e, 0x40, 0x100);
    int after = e.cmd_count;

    CHECK(rc == 0,             "blt_stage returns 0 on success");
    CHECK(after == before + 1, "blt_stage bumps cmd_count by 1");

    blt_cmd_t c = ring_read(&e, before);
    CHECK(c.opcode == BLT_OP_STAGE, "decoded opcode == BLT_OP_STAGE");
    CHECK(c.src_off == 0x40,        "src_off carries the off argument");

    /* size is packed as w (low 16) | h<<16 (high 16) */
    uint32_t decoded_size = (uint32_t)c.w | ((uint32_t)c.h << 16);
    CHECK(decoded_size == 0x100,    "w|h<<16 carries the size argument");

    CHECK(e.overflow == 0,          "no overflow flag set");
}

/* 2. Round-trip: the wire encode/decode preserves off and size. */
static void test_stage_roundtrip(void)
{
    static uint8_t ring[16 * BLT_CMD_BYTES];
    static uint8_t heap[4096];
    blt_emitter_t e;
    blt_emitter_init(&e, ring, sizeof(ring), heap, sizeof(heap));
    blt_begin_frame(&e, 0, 0, 0);

    /* Use values that exercise upper 16 bits of size */
    blt_stage(&e, 0xDEAD0000u, 0xABCD1234u);

    uint8_t wire[BLT_CMD_BYTES];
    memcpy(wire, e.ring, BLT_CMD_BYTES);    /* first command */

    blt_cmd_t c;
    blt_unpack_cmd(wire, &c);

    CHECK(c.opcode == BLT_OP_STAGE,          "round-trip: opcode");
    CHECK(c.src_off == 0xDEAD0000u,          "round-trip: off");
    uint32_t s = (uint32_t)c.w | ((uint32_t)c.h << 16);
    CHECK(s == 0xABCD1234u,                  "round-trip: size (full 32-bit)");
}

/* 3. Overflow: ring-full sets overflow and returns -1 without touching cmd_count. */
static void test_stage_overflow(void)
{
    /* Ring fits exactly 2 commands */
    static uint8_t ring[2 * BLT_CMD_BYTES];
    static uint8_t heap[4096];
    blt_emitter_t e;
    blt_emitter_init(&e, ring, sizeof(ring), heap, sizeof(heap));
    blt_begin_frame(&e, 0, 0, 0);

    /* Fill the ring */
    blt_stage(&e, 0x10, 0x20);
    blt_stage(&e, 0x30, 0x40);

    CHECK(e.overflow == 0,    "no overflow before ring full");

    int before = e.cmd_count;
    int rc = blt_stage(&e, 0x50, 0x60);    /* must overflow */
    CHECK(rc == -1,            "blt_stage returns -1 on overflow");
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
    blt_stage(&e, 0x40, 0x200);

    blt_cmd_t fill_cmd = ring_read(&e, 0);
    blt_cmd_t stage_cmd = ring_read(&e, 1);

    CHECK(fill_cmd.opcode == BLT_OP_FILL,   "fill opcode preserved after stage added");
    CHECK(fill_cmd.color == 0xF800u,         "fill color preserved");
    CHECK(fill_cmd.dst_x == 10,              "fill dst_x preserved");
    CHECK(fill_cmd.dst_y == 20,              "fill dst_y preserved");
    CHECK(fill_cmd.w == 100,                 "fill w preserved");
    CHECK(fill_cmd.h == 80,                  "fill h preserved");

    CHECK(stage_cmd.opcode == BLT_OP_STAGE, "stage follows fill correctly");
}

int main(void)
{
    test_stage_basic();
    test_stage_roundtrip();
    test_stage_overflow();
    test_fill_unaffected();

    if (failures == 0) { printf("ALL PASS\n"); return 0; }
    printf("%d FAILURE(S)\n", failures);
    return 1;
}
