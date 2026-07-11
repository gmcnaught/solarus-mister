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

# ── tiers ───────────────────────────────────────────────────────────────────
# NIGHTLY_ONLY: non-gating TBs that cannot finish in the PR budget (comp_replay
# ~350s, blitter_system_pipe >120s + currently FAILs). Excluded from the PR tier
# (zero gating coverage lost — the pipe cutover is covered by tb_comp_pipeline +
# the 7 tb_blitter_*_pipe TBs and tb_vram_demux). They still run (non-gating) in
# nightly/all.
NIGHTLY_ONLY="tb_comp_replay tb_blitter_system_pipe"

# +defines applied to EVERY compile in the nightly tier to restore full
# HW-faithful geometry/rate. Harmless on TBs that don't reference a macro, so
# Phase 2 tasks add each _FULL guard in their TB file and the macro here is a
# no-op until that guard lands. Pre-populated with ALL 7 macros (team-execution
# amendment) so Phase 2 is pure TB-file edits.
# NOTE: iverilog 13.0 takes -D<NAME> on the command line (the +define+<NAME>
# form is command-FILE only; on argv it is parsed as a source file). This matches
# the -D form already used by defines_for() (e.g. -DP2_SDRAM_SYS).
# NOTE: tb_bgplane_equivalence's full-geometry guard is BGPLANE_EQUIV_FULL (named
# by #82/Task-22, which reduced this TB in parallel with this work) — NOT
# BGPLANE_EQUIVALENCE_FULL. Keep this token matching the TB's `ifdef` or nightly
# silently runs reduced geometry.
TIER_DEFINES_FULL='-DVRAM_CONTENTION_FULL -DSCAN_QWORDDUP_FULL -DBGPLANE_EQUIV_FULL -DSCANOUT_FBRAM_FULL -DAUDIO_WEDGE_FULL -DBGPLANE_WRITE_FULL -DFBRAM_SDRAM_FULL'

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
  # PR tier runs EQUIVALENCE/GAP/KEY/PALPHA/TL_COV (all through the STAGE-ch1 bake path);
  # the two extra full-bake probes TL_COV_PA + TL_COV_RACE are gated behind BGPLANE_EQUIV_FULL
  # (nightly, via TIER_DEFINES_FULL) so the PR-tier wall-clock stays in budget.
  tb_bgplane_equivalence)                  echo 900 ;;
  # [#24 arena] Whole-system OP_BGPLANE_WRITE bake into the HIGH SDRAM arena
  # (chip1 high banks) on the 2-die XL harness, read back via ch5 across all 240
  # rows x2 scenarios (RGB565 cell data + ARGB4444 coverage) — ~118s local; 300s
  # budget for margin on slower CI runners.
  # Budget bumped 300->720: the ch0->ch1 STAGE reroute (route OP_BGPLANE_WRITE through
  # ch1) streams the bake through the smaller RO-blocksize STAGE cache, so the big XL-arena
  # write evicts/flushes far more lines through the 2-die mt48 model than the old ch0 path
  # -- a sim-model cost only (real SDRAM eviction is free). ~134s local; the shared CI
  # runner under parallel contention needs the extra headroom (was tipping over 300s).
  tb_bgplane_write_pipe_xl)                echo 720 ;;
  # [#24 dungeon] Three back-to-back per-layer plane bakes into disjoint arena
  # bases, ch5 readback of each incl. the last-baked plane's ARGB4444 alpha —
  # ~150s local (3 full-cell bakes); 360s budget for CI margin.
  # Budget bumped 360->720 for the same STAGE-reroute mt48-eviction cost as write_pipe_xl
  # above (3 back-to-back XL plane bakes). ~169s local; extra headroom for the CI runner.
  tb_bgplane_3plane_xl)                    echo 720 ;;
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
RESULTS="$BUILD/results"; mkdir -p "$RESULTS"
STUBS=$(ls ./*_stub.sv 2>/dev/null || true)

# ── tier + jobs + positional-TB parsing ─────────────────────────────────────
TIER=pr; JOBS=0; POS=()
for a in "$@"; do
  case "$a" in
    --tier=*) TIER="${a#--tier=}" ;;
    --jobs=*) JOBS="${a#--jobs=}" ;;
    *)        POS+=("$a") ;;
  esac
done
case "$TIER" in pr|nightly|all) ;; *) echo "ERROR: --tier must be pr|nightly|all"; exit 2;; esac
set -- ${POS[@]+"${POS[@]}"}            # bash-3.2-safe empty-array expansion (macOS)

TIER_DEFINES=''
[ "$TIER" = nightly ] && TIER_DEFINES="$TIER_DEFINES_FULL"

# default N = nproc-2 (>=1); N=1 reproduces today's exact serial order+output
if [ "$JOBS" -le 0 ] 2>/dev/null; then
  NPROC=$( { command -v nproc >/dev/null && nproc; } || sysctl -n hw.ncpu || echo 2 )
  JOBS=$(( NPROC > 2 ? NPROC - 2 : 1 ))
fi

# Which testbenches to run
if [ $# -gt 0 ]; then
  TBS=(); for a in "$@"; do TBS+=("${a%.sv}.sv"); done
else
  TBS=(tb_*.sv)
fi

# ── per-TB body (one call per TB; parallel-safe) ────────────────────────────
# Emits two files per TB: $RESULTS/$top.result (CSV: top,gating,verdict,secs —
# consumed by the reducer) and $RESULTS/$top.row (the formatted display row).
# When JOBS=1 it also prints the row live, so -P1 streams identically to the old
# serial loop. Row text is byte-identical to the pre-parallel serial formatting.
run_one_tb() {
  local tb="$1" top row gating=1 blog rlog to rc out ok=0 verdict note tag secs t0
  top="${tb%.sv}"   # separate stmt: in one `local`, all RHS expand pre-assignment
  t0=$(date +%s.%N)
  case " $SKIP " in *" $top "*)
    row=$(printf '%-26s %-8s %s' "$top" "skip" "benchmark (no verdict)")
    printf '%s,1,skip,0\n' "$top" >"$RESULTS/$top.result"; printf '%s\n' "$row" >"$RESULTS/$top.row"
    [ "$JOBS" = 1 ] && printf '%s\n' "$row"; return 0;; esac
  case " $NONGATING " in *" $top "*) gating=0;; esac
  if [ "$TIER" = pr ]; then case " $NIGHTLY_ONLY " in *" $top "*)
    row=$(printf '%-26s %-8s %s' "$top" "defer" "nightly-only (excluded from pr tier)")
    printf '%s,%s,defer,0\n' "$top" "$gating" >"$RESULTS/$top.result"; printf '%s\n' "$row" >"$RESULTS/$top.row"
    [ "$JOBS" = 1 ] && printf '%s\n' "$row"; return 0;; esac; fi
  blog="$BUILD/$top.build.log"
  if ! iverilog -g2012 -o "$BUILD/$top.vvp" $(defines_for "$top") $TIER_DEFINES \
        -I ../rtl -I ../rtl/jtframe -I ../sys -I . \
        -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v \
        $STUBS "$tb" >"$blog" 2>&1; then
    note="build error: $(grep -iE 'error|cannot|no such' "$blog" | head -1)"
    row=$(printf '%-26s %-8s %s' "$top" "BUILD!" "$note")
    printf '%s,%s,BUILD!,0\n' "$top" "$gating" >"$RESULTS/$top.result"; printf '%s\n' "$row" >"$RESULTS/$top.row"
    [ "$JOBS" = 1 ] && printf '%s\n' "$row"; return 0
  fi
  rlog="$BUILD/$top.run.log"; to=$(timeout_s "$top")
  if [ "$TIER" = nightly ]; then case "$top" in
    tb_comp_replay)          to=600 ;;   # needs ~350s to PASS
    tb_blitter_system_pipe)  to=300 ;;
    tb_bgplane_equivalence)  to=600 ;;   # nightly FULL geometry (240-row + Phase GAP) > the 450 reduced default
    tb_vram_contention)      to=300 ;;   # FULL geometry safety margin
    # FULL-geometry reduced TBs (~75-95s standalone) need margin over the 120s
    # default under --jobs=nproc contention on a slower CI core (else spurious
    # nightly gating timeout). scanout ~95s is the tightest.
    tb_scanout_fbram)        to=200 ;;
    tb_audio_burst_wedge)    to=200 ;;
    tb_bgplane_write_pipe)   to=200 ;;
  esac; fi
  if [ -n "$TIMEOUT" ]; then "$TIMEOUT" "$to" vvp "$BUILD/$top.vvp" >"$rlog" 2>&1; rc=$?
  else vvp "$BUILD/$top.vvp" >"$rlog" 2>&1; rc=$?; fi
  secs=$(awk "BEGIN{printf \"%.1f\", $(date +%s.%N)-$t0}" 2>/dev/null || echo 0)
  out=$(cat "$rlog")
  if [ $rc -eq 124 ]; then verdict=timeout; note="timeout (${to}s)"
  elif echo "$out" | grep -qE "$FAIL_RE"; then verdict=FAIL; note="failed: $(echo "$out" | grep -iE "$FAIL_RE" | head -1)"
  elif echo "$out" | grep -qE "$(pass_re "$top")"; then verdict=PASS; ok=1; note=""
  else verdict=noPASS; note="no PASS marker; finished rc=$rc"; fi
  if [ $ok -eq 1 ]; then
    row=$(printf '%-26s %-8s %s' "$top" "PASS" "$([ $gating -eq 0 ] && echo '(non-gating)')")
  else
    tag=$([ $gating -eq 1 ] && echo "FAIL" || echo "fail")
    row=$(printf '%-26s %-8s %s' "$top" "$tag" "$note$([ $gating -eq 0 ] && echo ' (non-gating)')")
  fi
  printf '%s,%s,%s,%s\n' "$top" "$gating" "$verdict" "$secs" >"$RESULTS/$top.result"
  printf '%s\n' "$row" >"$RESULTS/$top.row"
  [ "$JOBS" = 1 ] && printf '%s\n' "$row"
  return 0
}

# ── dispatch (xargs pool) + reducer ─────────────────────────────────────────
export BUILD RESULTS STUBS TIER TIER_DEFINES TIMEOUT JOBS SKIP NONGATING NIGHTLY_ONLY FAIL_RE
export -f run_one_tb pass_re timeout_s defines_for

printf '%-26s %-8s %s\n' "TESTBENCH" "RESULT" "NOTE"
printf '%s\n' "-------------------------------------------------------------"

# -P1 => serial, in TBS order, streaming live (identical to today).
# -PN => parallel; rows written to files, printed in deterministic TBS order below.
printf '%s\n' "${TBS[@]}" | xargs -P "$JOBS" -I{} bash -c 'run_one_tb "$@"' _ {}

[ "$JOBS" != 1 ] && for tb in "${TBS[@]}"; do cat "$RESULTS/${tb%.sv}.row" 2>/dev/null; done
printf '%s\n' "-------------------------------------------------------------"
passed=0; gate_fail=0; nongate_fail=0; skipped=0; deferred=0
for tb in "${TBS[@]}"; do
  top="${tb%.sv}"; [ -f "$RESULTS/$top.result" ] || continue
  IFS=, read -r _t g v _s <"$RESULTS/$top.result"
  case "$v" in
    PASS)  passed=$((passed+1)) ;;
    skip)  skipped=$((skipped+1)) ;;
    defer) deferred=$((deferred+1)) ;;
    *) if [ "$g" = 1 ]; then gate_fail=$((gate_fail+1)); else nongate_fail=$((nongate_fail+1)); fi ;;
  esac
done
printf 'passed=%d  gating-failures=%d  non-gating-failures=%d  skipped=%d' \
       "$passed" "$gate_fail" "$nongate_fail" "$skipped"
[ "$deferred" -gt 0 ] && printf '  deferred=%d' "$deferred"; echo
[ $gate_fail -eq 0 ] && { echo "RESULT: PASS"; exit 0; } || { echo "RESULT: FAIL"; exit 1; }
