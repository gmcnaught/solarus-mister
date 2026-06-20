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

# --- Timing closure diagnostics ---------------------------------------------
# An RBF that "builds" can still FAIL timing (Critical Warning 332148, not an
# error) and present as an INTERMITTENT/metastable HW bug. Always surface the
# worst-case setup slack + the failing path nodes so the log is self-diagnosing.
echo ""
echo ">>> Timing closure check (setup):"
grep -E "Timing requirements not met|Worst-case setup slack" "build_${DATE}.log" || \
    echo "    (no setup-slack line found in build log)"
echo ">>> Worst-case HOLD slack (min-delay — invisible to setup analysis):"
grep -E "Worst-case hold slack|Hold:.*slack|Minimum Pulse Width" "build_${DATE}.log" || \
    echo "    (no hold-slack line in build log; see report_timing -hold below)"
echo ">>> Top failing setup paths (report_timing — From/To nodes):"
cat > rpt_timing.tcl <<'TCL'
project_open Solarus
create_timing_netlist -model slow
read_sdc
update_timing_netlist
report_timing -setup -npaths 8 -detail summary -stdout
# Full node-by-node breakdown of THE single worst path:
report_timing -setup -npaths 1 -detail full_path -stdout
# --- HOLD (min-delay) analysis -------------------------------------------
# #34: a core can be CLEAN on setup (+slack) yet wedge deterministically on a
# HOLD violation — invisible to RTL sim and uncovered by setup slack. Report the
# worst hold paths globally, then TARGET the SDRAM dst-RMW path registers
# (vram_demux rd_on_sdram/st, sdram_src_arb owner/held_txn, blitter rd_issued/
# state, sdram_psx) where the wedge lives.
puts "=== HOLD: worst 12 paths (global) ==="
report_timing -hold -npaths 12 -detail summary -stdout
puts "=== HOLD: worst full path (global) ==="
report_timing -hold -npaths 1 -detail full_path -stdout
puts "=== HOLD: SDRAM dst-path targets (vdemux / src_arb / blitter dst regs) ==="
report_timing -hold -npaths 8 -detail summary -stdout \
    -to [get_registers {*vdemux*|*src_arb*|*blitter*rd_issued*|*blitter*state*}]
report_timing -hold -npaths 8 -detail summary -stdout \
    -from [get_registers {*vdemux*|*src_arb*|*sps*}]
# --- SDRAM physical I/O (#34): the read-CAPTURE path STA was previously blind to.
# Now that SDRAM_CLK is a generated clock with I/O delays, surface its slack.
puts "=== SDRAM: DQ read-capture (chip -> controller), setup+hold ==="
report_timing -setup -npaths 6 -detail summary -stdout -from [get_clocks {SDRAM_CLK}]
report_timing -hold  -npaths 6 -detail summary -stdout -from [get_clocks {SDRAM_CLK}]
puts "=== SDRAM: command/addr/data drive-out (controller -> chip), setup+hold ==="
report_timing -setup -npaths 6 -detail summary -stdout -to [get_clocks {SDRAM_CLK}]
report_timing -hold  -npaths 6 -detail summary -stdout -to [get_clocks {SDRAM_CLK}]
puts "=== SDRAM: worst DQ-capture full path ==="
report_timing -setup -npaths 1 -detail full_path -stdout -from [get_clocks {SDRAM_CLK}]
# #34 fallback C: the read-capture binding path is SDRAM_DQ -> sdram_psx|dout64[*].
# Report it explicitly (the most negative dout64 capture) so the honest read-capture
# margin is directly visible. report_timing prints "Worst case slack is X" which the
# shell step below greps with a unique tag.
puts "=== SDRAM: DQ->dout64 read-capture (tagged) ==="
report_timing -setup -npaths 1 -detail summary -stdout \
    -to [get_keepers {emu:emu|sdram_psx:sps|dout64[*]}]
project_close
TCL
"$QUARTUS_STA" -t rpt_timing.tcl > sta_${DATE}.log 2>&1 || true
grep -vE "^Info \(2|^Info \(1[0-9]{4}\)" sta_${DATE}.log | head -800 || true
echo ">>> #34 DQ->dout64 read-capture worst slack:"
awk '/SDRAM: DQ->dout64 read-capture \(tagged\)/{f=1} f&&/Worst case slack is/{print "DQCAP_SLACK_NS "$NF; exit}' sta_${DATE}.log || \
    echo "    (no dout64 capture path found — check the get_keepers match)"
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
