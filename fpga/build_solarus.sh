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
    echo "----- ${RPT} : usage summary -----"
    # Match the TABLE BODY header (";Resource;Usage;"), not the table-of-contents
    # entry. Print to the table's closing border.
    awk '/^; *Resource +; *Usage/{s=1} s{print} s&&/^\+---/{n++} s&&n>=2{exit}' "$RPT" | head -50
    echo "----- ${RPT} : utilization by entity -----"
    # The per-entity table's column header is unique to the body (TOC has neither
    # "Combinational ALUTs" nor "Logic Cells"); print until the trailing Note.
    awk '/; *(Combinational ALUTs|Logic Cells|ALMs needed) *;/{e=1} e{print} e&&/^Note:/{exit}' "$RPT" | head -200
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
# #44 banding: the FB/scanout corruption is on the 98.44MHz core clock (general[0]),
# the blitter/SDRAM domain. Surface its WORST setup paths in FULL detail so the
# exact failing register->adder->register can be pipelined.
puts "=== CORE 98.44MHz (general[0]) worst setup paths (summary) ==="
report_timing -setup -npaths 12 -detail summary -stdout \
    -to_clock {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
puts "=== CORE 98.44MHz (general[0]) worst setup FULL PATH ==="
report_timing -setup -npaths 3 -detail full_path -stdout \
    -to_clock {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
puts "=== blitter-scoped worst setup paths (to blitter regs) ==="
report_timing -setup -npaths 6 -detail summary -stdout \
    -to [get_registers {*blitter_top:blitter*}]
# 60fps-campaign Phase 3a STA gate: pll_hdmi's divclk (framework HDMI-TX domain,
# sys/sys_top.sdc) regressed to negative setup slack after the 128MB XL SDRAM
# growth (was clean +0.122ns at e7fe0a2, now ~-1.0ns across a 10-seed sweep with
# too narrow a spread to be placement noise -- looks like a real logic-depth
# deficit, not a routing-luck problem). Full-path detail to name the actual
# failing registers.
puts "=== pll_hdmi divclk (framework HDMI-TX, 148.54MHz) worst setup paths (summary) ==="
report_timing -setup -npaths 12 -detail summary -stdout \
    -to_clock {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}
puts "=== pll_hdmi divclk worst setup FULL PATH ==="
report_timing -setup -npaths 3 -detail full_path -stdout \
    -to_clock {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}
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
