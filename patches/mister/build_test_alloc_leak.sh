#!/usr/bin/env bash
# Build + run the blt_alloc free-list-saturation leak-accounting test (issue
# #109, part 3). Host-only, pure C -- compiles the authoritative
# patches/mister/blitter/blt_alloc.c and asserts blt_free tallies bytes it drops
# on free-list saturation (blt_alloc_leaked) instead of losing them silently.
set -euo pipefail
cd "$(dirname "$0")"
echo "== blt_alloc saturation leak accounting (#109) =="
cc -std=c99 -O2 -Wall -Wextra -I. test_alloc_leak.c blitter/blt_alloc.c -o /tmp/test_alloc_leak
/tmp/test_alloc_leak
