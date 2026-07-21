#!/usr/bin/env bash
# Stage 3b Phase B3: GRID_BUF bump allocator (qword-align + cap enforce).
set -euo pipefail
cd "$(dirname "$0")"
cc -std=c99 -Wall -Wextra -Werror -I . -I blitter \
   blitter/test_grid_alloc.c -o /tmp/test_grid_alloc
/tmp/test_grid_alloc
echo "== grid_alloc OK =="
