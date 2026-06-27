#!/usr/bin/env bash
# Build + run the mpix converter bit-exactness test (issue #52). Host-only (uses
# system SDL2 as the oracle); no armhf cross-build needed. Runs the test twice:
# once with the default path (NEON on an ARM host) and once forced to scalar, so
# both kernels are proven bit-exact to SDL.
set -euo pipefail
cd "$(dirname "$0")"
# -std=c++11 to match the Solarus engine toolchain (catches C++14+ constructs that
# would compile here but fail the armhf engine build).
CXXFLAGS="$(pkg-config --cflags sdl2) -std=c++11 -O2 -Wall -Wextra"
LDFLAGS="$(pkg-config --libs sdl2)"

echo "== default path (NEON if ARM host) =="
# shellcheck disable=SC2086
c++ $CXXFLAGS test_pixconv.cpp mister_pixconv.cpp -o /tmp/test_pixconv $LDFLAGS
/tmp/test_pixconv

echo "== forced scalar (MPIX_FORCE_SCALAR) =="
# shellcheck disable=SC2086
c++ $CXXFLAGS -DMPIX_FORCE_SCALAR test_pixconv.cpp mister_pixconv.cpp -o /tmp/test_pixconv_scalar $LDFLAGS
/tmp/test_pixconv_scalar
