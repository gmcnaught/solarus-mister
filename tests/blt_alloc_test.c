/* Host unit test for blt_alloc (issue #14). Pure C, runs natively (no device).
 * Build+run: cc -I patches/mister/blitter tests/blt_alloc_test.c \
 *              patches/mister/blitter/blt_alloc.c -o /tmp/blt_alloc_test && /tmp/blt_alloc_test
 */
#include "blt_alloc.h"
#include <stdio.h>
#include <stdlib.h>

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s (line %d)\n", msg, __LINE__); failures++; } \
} while (0)

/* 1. init: one region, alloc returns base, used tracks. */
static void test_init_and_basic_alloc(void) {
    blt_alloc_t a;
    blt_alloc_init(&a, 0x1000, 4096);
    CHECK(blt_alloc_used(&a) == 0, "init: nothing used");
    uint32_t o = blt_alloc(&a, 100);          /* rounds to 104 */
    CHECK(o == 0x1000, "first alloc at base");
    CHECK(blt_alloc_used(&a) == 104, "used == rounded size");
    uint32_t o2 = blt_alloc(&a, 8);
    CHECK(o2 == 0x1000 + 104, "second alloc packs after first");
    CHECK((o2 % BLT_ALLOC_ALIGN) == 0, "alloc is aligned");
}

/* 2. alloc that doesn't fit -> FAIL, and over-size -> FAIL. */
static void test_exhaustion(void) {
    blt_alloc_t a;
    blt_alloc_init(&a, 0, 256);
    uint32_t o = blt_alloc(&a, 256);
    CHECK(o == 0, "alloc whole region ok");
    CHECK(blt_alloc(&a, 8) == BLT_ALLOC_FAIL, "alloc when full -> FAIL");
    blt_alloc_t b;
    blt_alloc_init(&b, 0, 256);
    CHECK(blt_alloc(&b, 300) == BLT_ALLOC_FAIL, "alloc larger than region -> FAIL");
}

/* 3. free -> reuse: freeing a block lets a same-size alloc reuse that exact offset. */
static void test_free_and_reuse(void) {
    blt_alloc_t a;
    blt_alloc_init(&a, 0, 4096);
    uint32_t a0 = blt_alloc(&a, 512);
    uint32_t a1 = blt_alloc(&a, 512);
    (void)a1;
    blt_free(&a, a0, 512);
    uint32_t a2 = blt_alloc(&a, 512);         /* should reuse a0's hole (first-fit) */
    CHECK(a2 == a0, "freed block is reused");
}

/* 4. coalescing: free two adjacent blocks -> a single combined block is allocatable. */
static void test_coalesce(void) {
    blt_alloc_t a;
    blt_alloc_init(&a, 0, 4096);
    uint32_t b0 = blt_alloc(&a, 1000);        /* -> 1000 rounded to 1000 (mult of 8) */
    uint32_t b1 = blt_alloc(&a, 1000);
    uint32_t b2 = blt_alloc(&a, 1000);
    (void)b2;
    blt_free(&a, b0, 1000);                    /* free two ADJACENT blocks */
    blt_free(&a, b1, 1000);
    uint32_t big = blt_alloc(&a, 2000);        /* needs the coalesced 2000-byte hole */
    CHECK(big == b0, "adjacent frees coalesce into one allocatable block");
}

/* 5. free order independence + coalesce-with-both-neighbors (middle freed last). */
static void test_coalesce_middle_last(void) {
    blt_alloc_t a;
    blt_alloc_init(&a, 0, 4096);
    uint32_t c0 = blt_alloc(&a, 800);
    uint32_t c1 = blt_alloc(&a, 800);
    uint32_t c2 = blt_alloc(&a, 800);
    blt_free(&a, c0, 800);                      /* free outer two first */
    blt_free(&a, c2, 800);
    blt_free(&a, c1, 800);                      /* middle freed last -> merge all three */
    uint32_t all = blt_alloc(&a, 2400);
    CHECK(all == c0, "three frees (middle last) coalesce into one 2400 block");
}

/* 6. churn: a representative create/free/create sequence stays bounded (no leak). */
static void test_churn_no_leak(void) {
    blt_alloc_t a;
    blt_alloc_init(&a, 0, 1u << 20);            /* 1 MiB */
    for (int round = 0; round < 1000; round++) {
        uint32_t offs[32];
        for (int i = 0; i < 32; i++) offs[i] = blt_alloc(&a, 4096);
        for (int i = 0; i < 32; i++) CHECK(offs[i] != BLT_ALLOC_FAIL, "churn alloc ok");
        for (int i = 0; i < 32; i++) blt_free(&a, offs[i], 4096);
    }
    CHECK(blt_alloc_used(&a) == 0, "churn: all freed -> 0 used (no leak)");
    /* and the region is fully usable again */
    uint32_t whole = blt_alloc(&a, 1u << 20);
    CHECK(whole == 0, "churn: full region allocatable again (fully coalesced)");
}

/* 7. reset returns to a single full free block. */
static void test_reset(void) {
    blt_alloc_t a;
    blt_alloc_init(&a, 0, 4096);
    blt_alloc(&a, 1000);
    blt_alloc(&a, 1000);
    blt_alloc_reset(&a);
    CHECK(blt_alloc_used(&a) == 0, "reset: nothing used");
    CHECK(blt_alloc(&a, 4096) == 0, "reset: whole region allocatable");
}

int main(void) {
    test_init_and_basic_alloc();
    test_exhaustion();
    test_free_and_reuse();
    test_coalesce();
    test_coalesce_middle_last();
    test_churn_no_leak();
    test_reset();
    if (failures == 0) { printf("ALL PASS\n"); return 0; }
    printf("%d FAILURE(S)\n", failures);
    return 1;
}
