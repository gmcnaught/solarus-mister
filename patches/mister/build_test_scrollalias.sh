#!/usr/bin/env bash
# Build + run the scroll-transition offset arithmetic test (Stage 3a, Task 7).
# Host-only, no engine link, no SDL -- a faithful model of
# TransitionScrolling::get_mister_scroll_offsets and Impl::emit_draw's additive
# off_x/off_y, proving the offset arithmetic, the "one screen apart" invariant,
# and (negative self-test) the exact double-application regression fixed in
# 13259fd.
set -euo pipefail
cd "$(dirname "$0")"
# -std=c++11 to match the Solarus engine toolchain (see build_test_pixconv.sh).
CXXFLAGS="-std=c++11 -O2 -Wall -Wextra"

echo "== scroll-transition offsets (arithmetic, invariant, doubling regression) =="
# shellcheck disable=SC2086
c++ $CXXFLAGS test_scrollalias.cpp -o /tmp/test_scrollalias
/tmp/test_scrollalias
