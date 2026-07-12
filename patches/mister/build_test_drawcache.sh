#!/usr/bin/env bash
# Build + run the DRAWCACHE differential cache-invalidation test (issue #89).
# Host-only, no engine link, no SDL -- a faithful model of the
# Entities::entities_to_draw_dirty contract (patches 0022/0028). Proves the
# SOLARUS_DRAWCACHE fast path stays bit-for-bit equal to the flag-off reference
# across every mutation, and (negative self-test) that dropping any invalidation
# site is actually caught.
set -euo pipefail
cd "$(dirname "$0")"
# -std=c++11 to match the Solarus engine toolchain (see build_test_pixconv.sh).
CXXFLAGS="-std=c++11 -O2 -Wall -Wextra"

echo "== drawcache differential (ON vs OFF, positive + negative) =="
# shellcheck disable=SC2086
c++ $CXXFLAGS test_drawcache.cpp -o /tmp/test_drawcache
/tmp/test_drawcache
