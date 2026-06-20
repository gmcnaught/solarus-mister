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
    QUARTUS_STA=quartus_sta
elif [ -x "/opt/intelFPGA/quartus/bin/quartus_sh" ]; then
    # raetro/quartus Docker image (CI) — abs path in case PATH was reset.
    QUARTUS_SH="/opt/intelFPGA/quartus/bin/quartus_sh"
    QUARTUS_STA="/opt/intelFPGA/quartus/bin/quartus_sta"
elif [ -x "/c/intelFPGA_lite/17.0/quartus/bin64/quartus_sh.exe" ]; then
    QUARTUS_SH="/c/intelFPGA_lite/17.0/quartus/bin64/quartus_sh.exe"
    QUARTUS_STA="/c/intelFPGA_lite/17.0/quartus/bin64/quartus_sta.exe"
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

# --- Resource utilization report (always; runs even if the Fitter can't fit) -
# Surfaces WHERE the logic/LABs go so a fit failure (Error 11802 / 170012) is
# self-diagnosing without downloading the .rpt files. Pulls the per-entity table
# + usage summaries from the Analysis & Synthesis (.map.rpt) and Fitter (.fit.rpt)
# reports, plus the uninferred-RAM / can't-fit blocker lines.
echo ""
echo ">>> Resource utilization:"
for stage in map fit; do
    RPT="output_files/${PROJECT}.${stage}.rpt"
    [ -f "$RPT" ] || continue
    echo "----- ${RPT} -----"
    awk '/Resource Usage Summary/{s=1} s&&/^\+---/{n++} s{print} s&&n>=2&&/^\+---/{s=0}' "$RPT" | head -60
    awk '/Resource Utilization by Entity/{e=1} e{print} e&&/^Note:/{exit}' "$RPT" | head -220
done
echo ">>> Fit blockers (uninferred RAM / can't-fit):"
grep -hE "uninferred due to asynchronous|can't infer memory|Error \(11802\)|Fitter requires .* LABs|blocks of type combinational" \
     "build_${DATE}.log" 2>/dev/null | sed -E 's/\s+File:.*//' | sort -u | head -40
echo ">>> (end resource utilization)"
echo ""

# --- Timing closure diagnostics ---------------------------------------------
# An RBF that "builds" can still FAIL timing (Critical Warning 332148, not an
# error) and present as an INTERMITTENT/metastable HW bug. Always surface the
# worst-case setup slack + the failing path nodes so the log is self-diagnosing.
echo ""
echo ">>> Timing closure check (setup):"
grep -E "Timing requirements not met|Worst-case setup slack" "build_${DATE}.log" || \
    echo "    (no setup-slack line found in build log)"
echo ">>> Top failing setup paths (report_timing — From/To nodes):"
cat > rpt_timing.tcl <<'TCL'
project_open Solarus
create_timing_netlist -model slow
read_sdc
update_timing_netlist
report_timing -setup -npaths 8 -detail summary -stdout
# Full node-by-node breakdown of THE single worst path:
report_timing -setup -npaths 1 -detail full_path -stdout
project_close
TCL
"$QUARTUS_STA" -t rpt_timing.tcl 2>&1 | grep -vE "^Info \(2|^Info \(1[0-9]{4}\)" | head -160 || true
echo ">>> (end timing diagnostics)"
echo ""

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
