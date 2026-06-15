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
echo "All host tests passed."
