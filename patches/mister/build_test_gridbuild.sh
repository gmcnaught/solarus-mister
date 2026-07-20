#!/usr/bin/env bash
# Stage 3b Phase B1: grid builder (tile list -> cell grid with runs).
set -euo pipefail
cd "$(dirname "$0")"
cc -std=c99 -Wall -Wextra -Werror -I . -I blitter \
   test_gridbuild.c -o /tmp/test_gridbuild
/tmp/test_gridbuild
echo "== gridbuild OK =="
