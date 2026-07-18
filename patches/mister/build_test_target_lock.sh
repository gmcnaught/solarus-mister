#!/usr/bin/env bash
# Build + run the root-target lock test (retained-scene Stage 1, Task 1).
# Host-only, no engine link, no SDL -- a faithful model of Impl::is_fpga_target().
# Proves the MainLoop root tag beats the first-wins heuristic, and (negative
# self-test) that dropping the tag check is caught.
set -euo pipefail
cd "$(dirname "$0")"
CXXFLAGS="-std=c++11 -O2 -Wall -Wextra"

echo "== root-target lock (tag beats first-wins, positive + negative) =="
# shellcheck disable=SC2086
c++ $CXXFLAGS test_target_lock.cpp -o /tmp/test_target_lock
/tmp/test_target_lock
