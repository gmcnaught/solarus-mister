#!/usr/bin/env bash
# Build + run the fat-AABB precise re-filter test (issue #105). Host-only, no
# engine link, no SDL -- a faithful model of the Lua-query re-filter added in
# patch 0037 (Entities::get_entities_in_region_z_sorted +
# LuaContext::map_api_get_entities_in_rectangle). Proves the re-filtered set
# equals the documented bounding-box-overlap reference across queries/margins,
# and (negative self-test) that the fat margin really does leak without it.
set -euo pipefail
cd "$(dirname "$0")"
# -std=c++11 to match the Solarus engine toolchain (see build_test_pixconv.sh).
CXXFLAGS="-std=c++11 -O2 -Wall -Wextra"

echo "== fat-AABB re-filter (reference vs re-filtered, positive + negative) =="
# shellcheck disable=SC2086
c++ $CXXFLAGS test_fatfilter.cpp -o /tmp/test_fatfilter
/tmp/test_fatfilter
