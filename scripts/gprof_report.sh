#!/bin/bash
#
# Post-process a gmon.out captured from a gprof-instrumented Solarus engine
# (built with SOLARUS_GPROF=1, see scripts/build_engine.sh) into a human-
# readable flat profile + call graph.
#
# gmon.out is emitted by the -pg runtime when the engine EXITS NORMALLY. On
# MiSTer the engine is usually killed (kill -9) on core-change, which writes
# NOTHING — so to profile on device you must let the quest quit cleanly (e.g.
# the in-game "Quit" menu), or SIGTERM/SIGINT the process (glibc's atexit hook
# still runs). GMON_OUT_PREFIX (set by solarus_run.sh when SOLARUS_GPROF=1)
# controls where the file lands: "$GMON_OUT_PREFIX.<pid>".
#
# Usage:
#   scripts/gprof_report.sh [BINARY] [GMON] [OUT]
#     BINARY  instrumented ELF that produced the profile
#             (default: build/armhf/solarus-run)
#     GMON    the captured gmon.out (default: ./gmon.out)
#     OUT     report file to write (default: build/armhf/gprof-report.txt)
#
# The engine is an armhf cross-build, so we need the CROSS gprof
# (arm-linux-gnueabihf-gprof, shipped with the cross binutils). gprof reads the
# target ELF's symbol table + the gmon.out sample/arc data; the cross tool
# understands the ARM ELF. If the cross gprof is unavailable this falls back to
# the host `gprof` (usually fine — gprof is largely arch-neutral for reading).
#
set -euo pipefail
cd "$(dirname "$0")/.."

BINARY="${1:-build/armhf/solarus-run}"
GMON="${2:-gmon.out}"
OUT="${3:-build/armhf/gprof-report.txt}"

TRIPLE="${SOLARUS_TRIPLE:-arm-linux-gnueabihf}"

if [ ! -f "$BINARY" ]; then
  echo "ERROR: instrumented binary not found: $BINARY" >&2
  echo "       Build one with: SOLARUS_GPROF=1 scripts/build_engine.sh" >&2
  exit 1
fi
if [ ! -f "$GMON" ]; then
  echo "ERROR: profile data not found: $GMON" >&2
  echo "       Run the SOLARUS_GPROF=1 engine to a NORMAL exit to produce gmon.out," >&2
  echo "       then copy it here (device path is set via GMON_OUT_PREFIX)." >&2
  exit 1
fi

# Prefer the cross gprof that matches the armhf ELF; fall back to host gprof.
GPROF="${TRIPLE}-gprof"
if ! command -v "$GPROF" >/dev/null 2>&1; then
  echo "note: $GPROF not found, falling back to host gprof" >&2
  GPROF="gprof"
fi

mkdir -p "$(dirname "$OUT")"

echo "Generating gprof report:"
echo "  binary : $BINARY"
echo "  profile: $GMON"
echo "  tool   : $GPROF"
echo "  output : $OUT"

# -p flat profile, -q call graph, -b suppress the verbose field legends.
"$GPROF" -b -p -q "$BINARY" "$GMON" > "$OUT"

echo ""
echo "=== Top of flat profile ==="
# Show the header + the hottest ~25 functions for a quick look.
sed -n '1,32p' "$OUT"
echo ""
echo "Full report (flat profile + call graph): $OUT"
