#!/bin/bash
#============================================================================
#
#  build_solarus.sh -- Build the Solarus MiSTer RBF from the command line.
#
#  Run from fpga/ directory. Requires Quartus Prime Lite 17.0+ in PATH
#  or at the standard Windows location. CI builds it via raetro/quartus:17.0
#  in GitHub Actions (.github/workflows/build-rbf.yml).
#
#  Usage: ./build_solarus.sh [output_dir]
#  Default output: ../_Other/
#
#  Copyright (C) 2026 MiSTer Organize -- GPL-3.0
#
#============================================================================

set -e

OUTPUT_DIR="${1:-../_Other}"
PROJECT="Solarus"           # matches Solarus.qpf revision (don't change)
RBF_PREFIX="Solarus"        # output filename prefix → Solarus_YYYYMMDD.rbf
DATE=$(date +%Y%m%d)

# Locate quartus_sh. Prefer PATH, then fall back to the Windows default.
if command -v quartus_sh >/dev/null 2>&1; then
    QUARTUS_SH=quartus_sh
elif [ -x "/opt/intelFPGA/quartus/bin/quartus_sh" ]; then
    # raetro/quartus Docker image (CI) — abs path in case PATH was reset.
    QUARTUS_SH="/opt/intelFPGA/quartus/bin/quartus_sh"
elif [ -x "/c/intelFPGA_lite/17.0/quartus/bin64/quartus_sh.exe" ]; then
    QUARTUS_SH="/c/intelFPGA_lite/17.0/quartus/bin64/quartus_sh.exe"
else
    echo "ERROR: quartus_sh not found in PATH, /opt/intelFPGA, or /c/intelFPGA_lite/17.0/"
    exit 1
fi

echo "============================================"
echo "  MiSTer_Solarus -- Quartus Build"
echo "  Quartus: $QUARTUS_SH"
echo "============================================"
echo ""

# Generate build_id.v (date-stamped)
echo "\`define BUILD_DATE \"$(date +%y%m%d)\"" > build_id.v

# Compile
echo ">>> Running quartus_sh --flow compile $PROJECT ..."
"$QUARTUS_SH" --flow compile "$PROJECT" 2>&1 | tee "build_${DATE}.log"

SRC_RBF="output_files/${PROJECT}.rbf"
if [ ! -f "$SRC_RBF" ]; then
    echo ""
    echo "ERROR: RBF not produced. See build_${DATE}.log"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
DST_RBF="$OUTPUT_DIR/${RBF_PREFIX}_${DATE}.rbf"
cp "$SRC_RBF" "$DST_RBF"
SIZE=$(ls -lh "$DST_RBF" | awk '{print $5}')

echo ""
echo "============================================"
echo "  Build complete"
echo "  $DST_RBF ($SIZE)"
echo "============================================"
