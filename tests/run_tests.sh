#!/bin/bash
# Host unit tests (no device). Run from repo root: bash tests/run_tests.sh
set -e
cd "$(dirname "$0")/.."
CC="${CC:-cc}"
echo "== blt_alloc (issue #14 DDR texture allocator) =="
$CC -Wall -Wextra -O2 -I patches/mister/blitter \
    tests/blt_alloc_test.c patches/mister/blitter/blt_alloc.c \
    -o /tmp/blt_alloc_test
/tmp/blt_alloc_test

echo "== blt_stage (issue #19 SDRAM source staging) =="
$CC -Wall -Wextra -O2 -I patches/mister/blitter \
    tests/blt_stage_test.c \
    patches/mister/blitter/blt_emitter.c \
    patches/mister/blitter/blt_alloc.c \
    -o /tmp/blt_stage_test
/tmp/blt_stage_test

echo "== blt_stage_enabled (issue #19 T3: upload->stage sequence + disable) =="
$CC -Wall -Wextra -O2 -I patches/mister/blitter \
    tests/blt_stage_enabled_test.c \
    patches/mister/blitter/blt_emitter.c \
    patches/mister/blitter/blt_alloc.c \
    -o /tmp/blt_stage_enabled_test
/tmp/blt_stage_enabled_test

echo "== blt_bgcache_stage (issue #19: stage bg-cache DDR3->SDRAM on snapshot) =="
$CC -Wall -Wextra -O2 -I patches/mister/blitter \
    tests/blt_bgcache_stage_test.c \
    patches/mister/blitter/blt_emitter.c \
    patches/mister/blitter/blt_alloc.c \
    -o /tmp/blt_bgcache_stage_test
/tmp/blt_bgcache_stage_test

echo "All host tests passed."
