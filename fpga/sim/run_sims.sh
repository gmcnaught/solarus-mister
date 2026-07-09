#!/usr/bin/env bash
# run_sims.sh — build + run every fpga/sim testbench under Icarus Verilog and
# report PASS/FAIL. Used both locally and by .github/workflows/sim.yml.
#
# Why a runner instead of per-test filelists: every tb_*.sv resolves its RTL
# deps through iverilog's library search (-y over ../rtl ../sys and this dir,
# module-name == file-name), so one invocation builds all of them with zero
# hand-maintained file lists. Verified: 0 build errors across the suite.
#
# Pass detection: the suite uses several success conventions (PASS / RESULT:
# PASS / "errors=0" / RESULT: ALIVE), so each TB's positive marker is given
# below; a run passes iff it prints its PASS marker, prints no FAIL marker, and
# exits within its timeout. SKIP and NONGATING tune which TBs affect the exit
# code (see comments). Unknown/new tb_*.sv default to needing "PASS".
#
# Usage:
#   ./run_sims.sh                 # all testbenches
#   ./run_sims.sh tb_sdram_ctrl   # a subset (names with or without .sv)
set -uo pipefail

cd "$(dirname "$0")"   # fpga/sim — relative ../rtl, ../sys resolve from here

# ── tuning ────────────────────────────────────────────────────────────────
# tb_profile is a cycle-budget PROFILER (analysis, not a correctness gate): it
# runs representative blits through the real comp_pipeline + vram_demux datapath
# and buckets every cycle by FSM phase (setup/load/SRCFILL/comp/WB) to report
# cyc/px. Run it directly, with optional knob sweeps:
#   iverilog -g2012 -o /tmp/p.vvp -I ../rtl -I ../rtl/jtframe -I ../sys -I . \
#     -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v tb_profile.sv && vvp /tmp/p.vvp
#   ( +define+PROF_SRC_LAT=n / +PROF_DST_LAT=n / +COMP_BAND_H=n / +COMP_MAXBURST=n )
# It always prints RESULT: PASS, so it stays SKIP (no verdict to gate on).
# (The legacy sdram_psx/sdram_src_arb/sdram_burst_arb modules and their benches —
# (The legacy sdram_psx/sdram_src_arb/sdram_burst_arb modules and their benches —
# tb_sdram_psx/ctrl/sweep/burst_arb/src_arb[_beatloss], plus the retired-DUT
# tb_capture_race/tb_demux_preempt and tb_sdram_stage — were deleted in JC-T8 when
# the SDRAM path pivoted to sdram_fb_cache; the cache wrapper is covered by
# tb_sdram_fb_cache and the per-client cache-ok paths by tb_vram_demux /
# tb_scanout_sdram / tb_blitter_system_pipe.)
SKIP="tb_profile"
# Self-checking but slow under Icarus: run them, report, but don't fail the
# suite on their result (so a CI timeout can't block unrelated work). The legacy
# tb_blitter_system was retired with the legacy renderer; tb_blitter_system_pipe
# (gating) is the system-level check now.
#
# tb_vram_contention is NON-GATING: JC-T7 re-pointed it onto sdram_fb_cache + mt48.
# It builds and the cache serves P_DST, but completing the full contention workload
# under the faithful mt48 model in iverilog is impractically slow; a CI-tractable
# system re-gate (+ the coh_busy client-gating refinement) is a JC follow-up. See
# the tb header.
#
# tb_comp_replay is NON-GATING: it composites a FULL 320x240 frame (real captured
# title commands) through the faithful mt48 model + real scanout reader. It DOES PASS
# — completes a clean title in 3,490,072 cycles (~350s wall) and dumps fb0_replay.bin
# — but that is far past a CI-tractable 120s budget, so it times out under the cap.
# It is a visual-dump tool, not a fast unit gate. #44.
# tb_scan_qworddup (#44 A,A,C,C guard) and tb_vram_contention (P_DST/P_SCAN
# contention) are now GATING: a sim-only full-rate ce_pix (vs the HW ÷8 pixel
# clock) shrinks the reader's frame-paced sync from ~1.5M to ~188k cycles, and
# reduced scan-rows / fill-height keep coverage while cutting wall time to ~36s /
# ~53s. The full HW-faithful geometry is restored with +define+SCAN_QWORDDUP_FULL
# / +define+VRAM_CONTENTION_FULL (nightly).
# v2 "blitter escape elimination" equivalence TBs (Workstream C). They diff the
# comp_pipeline RTL against the C goldens (blitter_ref.c) for the new colour ops:
#   tb_blitter_add_pipe       — ADD blend (mode 4),  BLIT + FILL  == blt_add565
#   tb_blitter_mul_pipe       — MULTIPLY blend (mode 5), BLIT + FILL == blt_mul565
#   tb_blitter_colormod_pipe  — COLORMOD (0x40) over COPY/CONST_ALPHA/PALPHA + FILL
# GATING as of the v2 integration: Workstream B's ADD/MULTIPLY/COLORMOD comp_pipeline
# is merged and these diff bit-exact against the C goldens (all three PASS), so they
# now fail the suite on any RTL/golden divergence. The tint wire layout was reconciled
# at integration to byte27=cb / byte30=cr / byte31=cg (blt_wire.h ↔ blitter_top.sv).
# [FB-in-BRAM] tb_blitter_system_pipe is NON-GATING: CLEAR + the legacy-FSM FILL still
# write mem_*->vram_demux->SDRAM (not comp_fbram), and the faithful mt48 model makes it
# slow. (tb_comp_banding / tb_comp_banding_scanout / tb_fbcopy_dst2src_sameframe were
# RETIRED 2026-06-26: they tested the SDRAM FB write / async-flush / ch0->ch5 carry-
# forward paths that FB-in-BRAM deletes — premises moot, no re-point needed.)
# The comp_pipeline mixer-boundary cutover itself is fully gated bit-exact by
# tb_comp_pipeline + the seven tb_blitter_*_pipe equivalence TBs (all reading comp_fbram).
#
# tb_tilelist (#52 dumb emitter) is GATING (default config; auto-discovered by the
# tb_*.sv glob): it renders a frame as one BLT_OP_TILELIST and again as the N expanded
# BLITs and asserts comp_fbram is pixel-identical ("TB_TILELIST: PASS"), so the fabric
# TILELIST FSM in blitter_top.sv is held bit-exact to its N-BLIT expansion.
#
# tb_tilelist_res (#52 Tier B, resident pattern-indexed list) is GATING too: it submits
# CLEAR + BLT_OP_FRT_UPLOAD + one BLT_OP_TILELIST_RES (8-byte pid+dst entries) and asserts
# comp_fbram is pixel-identical to the same frame as N expanded BLITs with the resolved
# rects (src = FRT[pid][CFT[pid]]) — holding the fabric table-resolution FSM bit-exact.
NONGATING="tb_comp_replay tb_blitter_system_pipe"

# Per-TB positive marker (default = "PASS"); FAIL markers are common to all.
pass_re() { case "$1" in
  tb_ddr_blitter_arb)           echo 'read errors=0|PASS' ;;
  *)                            echo 'RESULT: PASS|PASS' ;;
esac; }
FAIL_RE='FAIL|DEADLOCK|STARV|WEDGE|Assertion failed|PROTO:|TIMEOUT'

# Per-TB wall-clock budget (seconds); slow ones get more.
timeout_s() { case "$1" in
  # GATING faithful-mt48 TBs (reduced sim geometry, see NONGATING note): ~53s
  # local; 120s budget gives margin for slower CI runners.
  # (tb_scan_qworddup retired with the SDRAM scanout path — FB-in-BRAM scanout reads
  #  comp_fbram via fbram_scan_adapter, covered pixel-exact by tb_scanout_fbram.)
  tb_vram_contention)                      echo 120 ;;
  # Non-gating full-frame visual-dump TB: ~350s to actually PASS, capped low.
  tb_comp_replay)                          echo 30 ;;
  # [Phase 3b Task 7] GATING equivalence TB against the REAL sdram_fb_cache+mt48
  # model on BOTH the ch0 write side (OP_BGPLANE_WRITE x2 cells) and the p0 read
  # side (96-entry TILELIST atlas fetches x3 + the plane-COPY readback), PLUS
  # [Task 3] a third real BLT_F_BGCOV bake+PALPHA-readback scenario (Phase GAP) —
  # ~303s local measured after that addition (was ~250s before it); budget
  # bumped from 300 to 450 for real margin on slower CI runners.
  tb_bgplane_equivalence)                  echo 450 ;;
  *)                                       echo 120 ;;
esac; }

# Per-TB extra +defines (default none). tb_blitter_system_pipe gates on the
# SDRAM-source/dest phases (PHASE1-pipe/2A/2B/3/4); without the define it falls
# back to DEFERRED stubs and the real phases would not be exercised.
defines_for() { case "$1" in
  tb_blitter_system_pipe) echo '-DP2_SDRAM_SYS' ;;
  *)                      echo '' ;;
esac; }

# ── prerequisites ───────────────────────────────────────────────────────────
command -v iverilog >/dev/null || { echo "ERROR: iverilog not found"; exit 2; }
command -v vvp      >/dev/null || { echo "ERROR: vvp not found"; exit 2; }
TIMEOUT=$(command -v timeout || command -v gtimeout || true)   # optional

BUILD=.simbuild; rm -rf "$BUILD"; mkdir -p "$BUILD"
STUBS=$(ls ./*_stub.sv 2>/dev/null || true)

# Which testbenches to run
if [ $# -gt 0 ]; then
  TBS=(); for a in "$@"; do TBS+=("${a%.sv}.sv"); done
else
  TBS=(tb_*.sv)
fi

gate_fail=0; nongate_fail=0; passed=0; skipped=0
printf '%-26s %-8s %s\n' "TESTBENCH" "RESULT" "NOTE"
printf '%s\n' "-------------------------------------------------------------"

for tb in "${TBS[@]}"; do
  top="${tb%.sv}"
  case " $SKIP " in *" $top "*) printf '%-26s %-8s %s\n' "$top" "skip" "benchmark (no verdict)"; skipped=$((skipped+1)); continue;; esac
  gating=1; case " $NONGATING " in *" $top "*) gating=0;; esac

  blog="$BUILD/$top.build.log"
  if ! iverilog -g2012 -o "$BUILD/$top.vvp" \
        $(defines_for "$top") \
        -I ../rtl -I ../rtl/jtframe -I ../sys -I . \
        -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v \
        $STUBS "$tb" >"$blog" 2>&1; then
    note="build error: $(grep -iE 'error|cannot|no such' "$blog" | head -1)"
    printf '%-26s %-8s %s\n' "$top" "BUILD!" "$note"
    [ $gating -eq 1 ] && gate_fail=$((gate_fail+1)) || nongate_fail=$((nongate_fail+1))
    continue
  fi

  rlog="$BUILD/$top.run.log"
  to=$(timeout_s "$top")
  if [ -n "$TIMEOUT" ]; then "$TIMEOUT" "$to" vvp "$BUILD/$top.vvp" >"$rlog" 2>&1; rc=$?
  else vvp "$BUILD/$top.vvp" >"$rlog" 2>&1; rc=$?; fi

  out=$(cat "$rlog")
  ok=0
  if [ $rc -eq 124 ]; then note="timeout (${to}s)"
  elif echo "$out" | grep -qE "$FAIL_RE"; then note="failed: $(echo "$out" | grep -iE "$FAIL_RE" | head -1)"
  elif echo "$out" | grep -qE "$(pass_re "$top")"; then ok=1; note=""
  else note="no PASS marker; finished rc=$rc"
  fi

  if [ $ok -eq 1 ]; then
    printf '%-26s %-8s %s\n' "$top" "PASS" "$([ $gating -eq 0 ] && echo '(non-gating)')"
    passed=$((passed+1))
  else
    tag=$([ $gating -eq 1 ] && echo "FAIL" || echo "fail")
    printf '%-26s %-8s %s\n' "$top" "$tag" "$note$([ $gating -eq 0 ] && echo ' (non-gating)')"
    [ $gating -eq 1 ] && gate_fail=$((gate_fail+1)) || nongate_fail=$((nongate_fail+1))
  fi
done

printf '%s\n' "-------------------------------------------------------------"
echo "passed=$passed  gating-failures=$gate_fail  non-gating-failures=$nongate_fail  skipped=$skipped"
[ $gate_fail -eq 0 ] && { echo "RESULT: PASS"; exit 0; } || { echo "RESULT: FAIL"; exit 1; }
