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
#   ./run_sims.sh                 # all testbenches (Icarus)
#   ./run_sims.sh tb_sdram_ctrl   # a subset (names with or without .sv)
#   ./run_sims.sh --sim=verilator # only the Verilator-capable TBs, under Verilator
#   ./run_sims.sh --sim=auto      # Verilator where capable, Icarus elsewhere
#
# ── simulator selection (--sim=, default icarus) ────────────────────────────
# icarus    (default) every TB under iverilog — byte-identical to before this flag.
# verilator ONLY the VERILATOR_OK TBs, under Verilator. Everything else reports
#           "n/a" (not capable) rather than failing.
# auto      Verilator for VERILATOR_OK TBs, Icarus for the rest, in one pass.
#
# WHY: some TBs Icarus cannot actually run. tb_profile completes only its FIRST
# blit under Icarus and then hits its own per-blit await timeout (~2M cycles) on
# every subsequent one — at the default config too, which is what produced its
# "setup 100.0%" garbage rows. Under Verilator the whole bench runs in <1s (6s to
# build), row 1 is CYCLE-IDENTICAL to Icarus, and rows 2-9 reproduce the
# COPY wide 1.65 / sprite 1.75 floor recorded in the bench's own header. The
# Icarus divergence beyond blit 1 is NOT root-caused.
#
# ADDING A TB TO VERILATOR_OK — the bar is equivalence, not "it builds":
#   1. ./run_sims.sh --sim=verilator <tb>   builds and PASSes, and
#   2. its numbers/verdict match the Icarus run (or, where Icarus cannot complete,
#      match a value independently recorded in the TB itself).
# Verilator is 2-state, so it CANNOT catch X-propagation bugs an Icarus gate may
# rely on — it complements the Icarus suite, it does not replace it. Keep every
# correctness gate on Icarus unless you have checked that TB does not depend on X.
#
# WHAT CANNOT PORT: any TB instantiating the Micron model (mt48lc16m16a2 — 12
# inout/specify/$setuphold constructs) or otherwise needing tristate/timing checks.
# That is tb_sdram_fb_cache, tb_sdram_fb_cache_xl, tb_psrc_walk_ab and friends;
# they stay on Icarus, which is correct — they are the ones that need a faithful
# chip model.
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
# tb_psrc_walk_ab is likewise a MEASUREMENT bench, not a gate: it walks a PAL8 span
# through the real sdram_fb_cache + jtframe_burst_sdram + mt48 model and reports true
# wall-clock cyc/px for the old (2 reads per source qword) vs deduplicated (1 read +
# 1 held-half beat) walk. It is the instrument behind the PAL8-dedup change; keep it
# runnable but out of the gate (it always prints RESULT: PASS and takes ~2 min).
#   ./run_sims.sh tb_psrc_walk_ab   # (SKIP means "report, don't gate")
# tb_miss_anatomy is the third MEASUREMENT bench: it probes ch5's jtframe_cache_ctrl
# during a single COLD read and reports where the ~145 cycles go — when the requested
# qword physically lands in block RAM vs when the cache finally returns it. The answer
# is the case for early-restart / hit-under-fill: at block offset 0 (the linear-walk
# case) the word is in BRAM at cycle 15 and handed over at 145, so 130 cycles are spent
# waiting for the REST of the block. Also out of the gate (always prints RESULT: PASS).
#   ./run_sims.sh tb_miss_anatomy
SKIP="tb_profile tb_psrc_walk_ab tb_miss_anatomy"
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
# tb_comp_replay is NON-GATING and CANNOT be gated as-is (#96 correction — the old
# "DOES PASS in ~350s" note was STALE). It is a visual-DUMP dev tool, not a self-
# checking test: it $readmemh's an external capture `bltdump.hex` that is NOT in the
# repo (so in CI it loads an EMPTY command stream, composites a trivial frame, and
# dumps fb0_replay.bin with no PASS assertion), AND it scan-reads FB0 from SDRAM —
# the scanout path FB-in-BRAM (#49) retired (scanout now reads comp_fbram via
# fbram_scan_adapter), so the scan port never serves SDRAM_FB0_BASE and it dies
# "scan_read timeout @0400000". Gating it would require (a) committing a real
# bltdump.hex capture + a golden, and (b) re-pointing its readback to comp_fbram
# (as #96 did for tb_blitter_system_pipe). Until then it stays NON-GATING + nightly-
# only; the reducer's loud NON-GATING-failure banner surfaces it in nightly so it
# cannot drift silently. Tracked as a follow-up. #44/#96.
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
# [FB-in-BRAM #96] tb_blitter_system_pipe is now GATING again. It had rotted after the
# FB-in-BRAM cutover: the TB never wired comp_fbram / blitter_top.fb_* (so every
# composite vanished) nor drove vs (so the pipe wedged in S_SNAP_WAIT after frame 1 and
# later submits never composited) -> all phases read stale SDRAM = 0 and it "FAILed +
# was slow". #96 wired comp_fbram + the fb_* ports, drove a free-running vs, and
# re-pointed the dest readback (getpx) from the retired SDRAM FB to comp_fbram WORK.
# All four phases (FILL/reader-concurrency, tall-chunk, multi-cmd painter, per-cmd
# SDRAM-source mux, carry-forward) now PASS in ~1.6ms sim (seconds wall) -> gating in
# every tier. (tb_comp_banding / tb_comp_banding_scanout / tb_fbcopy_dst2src_sameframe were
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
# [#96] tb_blitter_system_pipe was FIXED and REMOVED from NONGATING (it gates in every
# tier now). tb_comp_replay remains NON-GATING — it is a visual-dump dev tool that
# cannot self-check without a committed capture + a comp_fbram scanout re-point (see the
# long note above). It is NOT silenced: the reducer's loud NON-GATING-failure banner
# surfaces its failure in nightly. The banner mechanism future-proofs any new NON-GATING
# TB against drifting from "known-slow" into "known-broken".
NONGATING="tb_comp_replay"

# ── Verilator-capable TBs (see the --sim= note in the header) ───────────────
# Populated ONLY from TBs verified to build AND run AND agree with Icarus (or,
# for tb_profile, with the floor recorded in its own header — Icarus cannot
# complete it). A TB being absent here means "not verified", not "known bad".
# Under --sim=verilator, a SKIP-listed bench in this list DOES run (that is the
# point: it is the only way to get tb_profile's numbers at all) and is forced
# NON-GATING, so a broken bench surfaces through the loud non-gating banner
# rather than turning the suite red on a benchmark.
#
# SURVEY 2026-08-16 (Verilator 5.020, whole suite attempted) — candidates, NOT
# promotions. 32/46 build and self-report PASS. They are deliberately NOT listed
# here yet: passing under a 2-state simulator is not evidence a GATE is safe to
# move, and moving gates was never the goal. Promote one only with the two-step
# bar above, TB by TB, when there is a reason to.
#   32  build + PASS ......... candidates
#    9  build FAIL, real ..... mt48 tristate (tb_jtframe_*_smoke, tb_sdram_fb_cache[_xl],
#                              tb_psrc_walk_ab, tb_stage_psrc[_sameframe], tb_comp_replay),
#                              `disable` outside a block (tb_blitter_system_pipe),
#                              top-module/filename mismatch (tb_ddr_blitter_arb)
#    4  build FAIL, since FIXED  they only needed $STUBS passed explicitly
#                              (tb_scanout_ddr3, tb_vram_contention, tb_audio_burst_wedge)
#    1  build OK but RUN=FAIL . tb_blitter_colormod_pipe — PASSES under Icarus, FAILS
#                              under Verilator with a single pixel wrong:
#                              "MISMATCH cm-copy-blit (30,30): got 0000 exp 821f".
#                              UNEXPLAINED and worth a look: it is a bit-exact
#                              golden-diff TB against blitter_ref.c, so a
#                              simulator-dependent verdict is either a 2-state/X
#                              dependence in the TB or a real RTL sensitivity. Do not
#                              promote it; do not assume it is a Verilator bug.
VERILATOR_OK="tb_profile"

# ── tiers ───────────────────────────────────────────────────────────────────
# NIGHTLY_ONLY: TBs excluded from the PR tier. tb_comp_replay is a non-gating visual-
# dump tool (see note above) — deferred in PR (surfaced by the DEFERRED note), and it
# still RUNS non-gating in nightly where the loud banner flags its failure. It is NOT a
# fast gate. tb_blitter_system_pipe is NO LONGER here: after the #96 fix it runs in
# ~1.6ms sim, so it gates in EVERY tier (incl. PR).
# (The background-plane bake's heavy XL benches — maptrans/inval_teeth/write_pipe_xl/
# 3plane_xl/equivalence/pal8 — were deleted along with that RTL in Stage 3b Phase B2.)
NIGHTLY_ONLY="tb_comp_replay"

# +defines applied to EVERY compile in the nightly tier to restore full
# HW-faithful geometry/rate. Harmless on TBs that don't reference a macro, so
# Phase 2 tasks add each _FULL guard in their TB file and the macro here is a
# no-op until that guard lands. Pre-populated with ALL 7 macros (team-execution
# amendment) so Phase 2 is pure TB-file edits.
# NOTE: iverilog 13.0 takes -D<NAME> on the command line (the +define+<NAME>
# form is command-FILE only; on argv it is parsed as a source file). This matches
# the -D form already used by defines_for() (e.g. -DP2_SDRAM_SYS).
# (The BGPLANE_EQUIV_FULL/BGPLANE_WRITE_FULL/BGPLANE_MAPTRANS_FULL/BGPLANE_INVAL_FULL
# full-geometry guards were deleted along with their TBs in Stage 3b Phase B2.)
# [#97] -DFABRIC_ASSERT turns on the sim-only fabric SVAs (immediate assertions gated by
# `ifdef FABRIC_ASSERT in the RTL; iverilog has no concurrent-assertion support). Active
# in nightly so a violated invariant (e.g. stage_barrier dropped mid-sequence) prints
# "FABRIC-ASSERT FAIL ..." -> trips FAIL_RE and fails the suite.
TIER_DEFINES_FULL='-DVRAM_CONTENTION_FULL -DSCAN_QWORDDUP_FULL -DSCANOUT_DDR3_FULL -DAUDIO_WEDGE_FULL -DFBRAM_SDRAM_FULL -DFABRIC_ASSERT'

# Per-TB positive marker (default = "PASS"); FAIL markers are common to all.
pass_re() { case "$1" in
  tb_ddr_blitter_arb)           echo 'read errors=0|PASS' ;;
  *)                            echo 'RESULT: PASS|PASS' ;;
esac; }
FAIL_RE='FAIL|DEADLOCK|STARV|WEDGE|Assertion failed|PROTO:|TIMEOUT'

# Per-TB wall-clock budget (seconds); slow ones get more.
timeout_s() { case "$1" in
  # GATING faithful-mt48 TBs (reduced sim geometry, see NONGATING note): ~55s
  # local. Budget 120->180: the sim job now runs at nproc-1 (see sim.yml) so light
  # TBs no longer share a saturated core, but keep generous margin for the slower CI
  # core — this is the TB that spuriously timed out at 120s under the old --jobs=nproc.
  # (tb_scan_qworddup retired with the SDRAM scanout path — FB-in-BRAM scanout reads
  #  the DDR3 double-buffer via ddr3_scan_adapter, covered pixel-exact by tb_scanout_ddr3.)
  tb_vram_contention)                      echo 180 ;;
  # A/B grid-vs-replay equivalence TB driving blitter_top through 2 full frames,
  # incl. the WORK->DDR3 snapshot each frame: ~58s local, needs margin on slow CI.
  tb_tilemap)                              echo 300 ;;
  # Non-gating full-frame visual-dump TB: ~350s to actually PASS, capped low.
  tb_comp_replay)                          echo 30 ;;
  # (The background-plane bake's heavy XL timeout entries — equivalence/write_pipe_xl/
  # 3plane_xl/maptrans/inval_teeth/pal8 — were deleted along with those TBs and the
  # RTL they exercised in Stage 3b Phase B2.)
  *)                                       echo 120 ;;
esac; }

# Per-TB extra +defines (default none). tb_blitter_system_pipe gates on the
# SDRAM-source/dest phases (PHASE1-pipe/2A/2B/3/4); without the define it falls
# back to DEFERRED stubs and the real phases would not be exercised.
defines_for() { case "$1" in
  # -DFABRIC_ASSERT keeps blitter_top's tear-free fence SVA (VCTRL only after the
  # WORK->DDR3 burst drains) + the fb_bank alternation SVA LIVE in every tier for the
  # system pipe (the fence is the point of the Stage 5 P2 re-point), not just nightly.
  tb_blitter_system_pipe) echo '-DP2_SDRAM_SYS -DFABRIC_ASSERT' ;;
  *)                      echo '' ;;
esac; }

# ── prerequisites ───────────────────────────────────────────────────────────
TIMEOUT=$(command -v timeout || command -v gtimeout || true)   # optional

BUILD=.simbuild; rm -rf "$BUILD"; mkdir -p "$BUILD"
RESULTS="$BUILD/results"; mkdir -p "$RESULTS"
STUBS=$(ls ./*_stub.sv 2>/dev/null || true)

# ── tier + jobs + positional-TB parsing ─────────────────────────────────────
TIER=pr; JOBS=0; SIM=icarus; POS=()
for a in "$@"; do
  case "$a" in
    --tier=*) TIER="${a#--tier=}" ;;
    --jobs=*) JOBS="${a#--jobs=}" ;;
    --sim=*)  SIM="${a#--sim=}" ;;
    *)        POS+=("$a") ;;
  esac
done
case "$TIER" in pr|nightly|all) ;; *) echo "ERROR: --tier must be pr|nightly|all"; exit 2;; esac
case "$SIM"  in icarus|verilator|auto) ;; *) echo "ERROR: --sim must be icarus|verilator|auto"; exit 2;; esac

# Prerequisites depend on the selected simulator. `auto` degrades to Icarus with a
# visible note rather than failing, so a machine without Verilator still runs the
# suite; `--sim=verilator` is an explicit request and hard-fails if it is missing.
if [ "$SIM" != verilator ]; then
  command -v iverilog >/dev/null || { echo "ERROR: iverilog not found"; exit 2; }
  command -v vvp      >/dev/null || { echo "ERROR: vvp not found"; exit 2; }
fi
if [ "$SIM" = verilator ]; then
  command -v verilator >/dev/null || { echo "ERROR: verilator not found (--sim=verilator)"; exit 2; }
elif [ "$SIM" = auto ] && ! command -v verilator >/dev/null; then
  echo "### NOTE: verilator not found — --sim=auto falling back to Icarus for every TB."
  SIM=icarus
fi
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
  local eng=icarus vcap=0 vdir
  top="${tb%.sv}"   # separate stmt: in one `local`, all RHS expand pre-assignment
  t0=$(date +%s.%N)

  # Engine selection must precede the SKIP short-circuit: under --sim=verilator a
  # SKIP-listed BENCH is exactly what we want to run.
  case " $VERILATOR_OK " in *" $top "*) vcap=1;; esac
  if [ "$SIM" = verilator ]; then
    if [ $vcap -eq 0 ]; then
      row=$(printf '%-26s %-8s %s' "$top" "n/a" "not Verilator-capable (see VERILATOR_OK)")
      printf '%s,1,skip,0\n' "$top" >"$RESULTS/$top.result"; printf '%s\n' "$row" >"$RESULTS/$top.row"
      [ "$JOBS" = 1 ] && printf '%s\n' "$row"; return 0
    fi
    eng=verilator
  elif [ "$SIM" = auto ] && [ $vcap -eq 1 ]; then
    eng=verilator
  fi

  case " $SKIP " in *" $top "*)
    if [ "$eng" != verilator ]; then
      row=$(printf '%-26s %-8s %s' "$top" "skip" "benchmark (no verdict)")
      printf '%s,1,skip,0\n' "$top" >"$RESULTS/$top.result"; printf '%s\n' "$row" >"$RESULTS/$top.row"
      [ "$JOBS" = 1 ] && printf '%s\n' "$row"; return 0
    fi
    gating=0;;   # a bench that DOES run is reported, never gates (see VERILATOR_OK note)
  esac
  case " $NONGATING " in *" $top "*) gating=0;; esac
  if [ "$TIER" = pr ]; then case " $NIGHTLY_ONLY " in *" $top "*)
    row=$(printf '%-26s %-8s %s' "$top" "defer" "nightly-only (excluded from pr tier)")
    printf '%s,%s,defer,0\n' "$top" "$gating" >"$RESULTS/$top.result"; printf '%s\n' "$row" >"$RESULTS/$top.row"
    [ "$JOBS" = 1 ] && printf '%s\n' "$row"; return 0;; esac; fi
  blog="$BUILD/$top.build.log"; vdir="$BUILD/vl_$top"
  # Build under the selected engine. Verilator notes:
  #  -j 1        the xargs pool above already provides the parallelism; letting each
  #              verilator spawn its own make jobs would oversubscribe the box.
  #  -Wno-fatal  Verilator's width/timescale lint is far stricter than Icarus's and this
  #              RTL carries many such warnings (verilator-lint.yml is advisory for
  #              exactly that reason) — a lint warning must not fail a sim build here.
  #  --timing    needed for the TBs' `always #5 clk` / timeout delays.
  #  $STUBS      passed explicitly, exactly as the iverilog path does: the stub files
  #              are named *_stub.sv while the modules inside are altddio_out / dcfifo,
  #              so -y (which searches by module NAME) can never resolve them. Omitting
  #              them is what produced the "Cannot find file containing module" build
  #              failures on every TB that reaches sdram_fb_cache or openbor_video_reader.
  if [ "$eng" = verilator ]; then
    verilator --binary -j 1 -Wno-fatal --timing -sv \
        $(defines_for "$top") $TIER_DEFINES \
        -I../rtl -I../rtl/jtframe -I../sys -I. \
        -y ../rtl -y ../rtl/jtframe -y ../sys -y . +libext+.sv+.v \
        --top-module "$top" --Mdir "$vdir" -o "$top" $STUBS "$tb" >"$blog" 2>&1
    rc=$?
    note="verilator build error: $(grep -m1 '%Error' "$blog" | cut -c1-90)"
  else
    iverilog -g2012 -o "$BUILD/$top.vvp" $(defines_for "$top") $TIER_DEFINES \
        -I ../rtl -I ../rtl/jtframe -I ../sys -I . \
        -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v \
        $STUBS "$tb" >"$blog" 2>&1
    rc=$?
    note="build error: $(grep -iE 'error|cannot|no such' "$blog" | head -1)"
  fi
  if [ $rc -ne 0 ]; then
    row=$(printf '%-26s %-8s %s' "$top" "BUILD!" "$note")
    printf '%s,%s,BUILD!,0\n' "$top" "$gating" >"$RESULTS/$top.result"; printf '%s\n' "$row" >"$RESULTS/$top.row"
    [ "$JOBS" = 1 ] && printf '%s\n' "$row"; return 0
  fi
  note=""
  rlog="$BUILD/$top.run.log"; to=$(timeout_s "$top")
  if [ "$TIER" = nightly ]; then case "$top" in
    tb_comp_replay)          to=600 ;;   # needs ~350s to PASS
    tb_blitter_system_pipe)  to=300 ;;
    tb_vram_contention)      to=300 ;;   # FULL geometry safety margin
    # FULL-geometry reduced TBs (~75-95s standalone) need margin over the 120s
    # default under --jobs=nproc contention on a slower CI core (else spurious
    # nightly gating timeout). scanout ~95s is the tightest.
    tb_scanout_ddr3)         to=200 ;;
    tb_audio_burst_wedge)    to=200 ;;
  esac; fi
  local runcmd
  if [ "$eng" = verilator ]; then runcmd=("$vdir/$top"); else runcmd=(vvp "$BUILD/$top.vvp"); fi
  if [ -n "$TIMEOUT" ]; then "$TIMEOUT" "$to" "${runcmd[@]}" >"$rlog" 2>&1; rc=$?
  else "${runcmd[@]}" >"$rlog" 2>&1; rc=$?; fi
  secs=$(awk "BEGIN{printf \"%.1f\", $(date +%s.%N)-$t0}" 2>/dev/null || echo 0)
  out=$(cat "$rlog")
  if [ $rc -eq 124 ]; then verdict=timeout; note="timeout (${to}s)"
  elif echo "$out" | grep -qE "$FAIL_RE"; then verdict=FAIL; note="failed: $(echo "$out" | grep -iE "$FAIL_RE" | head -1)"
  elif echo "$out" | grep -qE "$(pass_re "$top")"; then verdict=PASS; ok=1; note=""
  else verdict=noPASS; note="no PASS marker; finished rc=$rc"; fi
  # Tag the engine in the note whenever it is NOT the default, so an `auto` run
  # makes it obvious which TBs were served by which simulator.
  local engtag=""; [ "$eng" = verilator ] && engtag="[verilator] "
  if [ $ok -eq 1 ]; then
    row=$(printf '%-26s %-8s %s' "$top" "PASS" "$engtag$([ $gating -eq 0 ] && echo '(non-gating)')")
  else
    tag=$([ $gating -eq 1 ] && echo "FAIL" || echo "fail")
    row=$(printf '%-26s %-8s %s' "$top" "$tag" "$engtag$note$([ $gating -eq 0 ] && echo ' (non-gating)')")
  fi
  printf '%s,%s,%s,%s\n' "$top" "$gating" "$verdict" "$secs" >"$RESULTS/$top.result"
  printf '%s\n' "$row" >"$RESULTS/$top.row"
  [ "$JOBS" = 1 ] && printf '%s\n' "$row"
  return 0
}

# ── dispatch (xargs pool) + reducer ─────────────────────────────────────────
export BUILD RESULTS STUBS TIER TIER_DEFINES TIMEOUT JOBS SKIP NONGATING NIGHTLY_ONLY FAIL_RE
export SIM VERILATOR_OK
export -f run_one_tb pass_re timeout_s defines_for

printf '%-26s %-8s %s\n' "TESTBENCH" "RESULT" "NOTE"
printf '%s\n' "-------------------------------------------------------------"

# -P1 => serial, in TBS order, streaming live (identical to today).
# -PN => parallel; rows written to files, printed in deterministic TBS order below.
printf '%s\n' "${TBS[@]}" | xargs -P "$JOBS" -I{} bash -c 'run_one_tb "$@"' _ {}

[ "$JOBS" != 1 ] && for tb in "${TBS[@]}"; do cat "$RESULTS/${tb%.sv}.row" 2>/dev/null; done
printf '%s\n' "-------------------------------------------------------------"
passed=0; gate_fail=0; nongate_fail=0; skipped=0; deferred=0
nongate_fail_names=""; defer_names=""
for tb in "${TBS[@]}"; do
  top="${tb%.sv}"; [ -f "$RESULTS/$top.result" ] || continue
  IFS=, read -r _t g v _s <"$RESULTS/$top.result"
  case "$v" in
    PASS)  passed=$((passed+1)) ;;
    skip)  skipped=$((skipped+1)) ;;
    defer) deferred=$((deferred+1)); defer_names="$defer_names $top" ;;
    *) if [ "$g" = 1 ]; then gate_fail=$((gate_fail+1));
       else nongate_fail=$((nongate_fail+1)); nongate_fail_names="$nongate_fail_names ${top}:${v}"; fi ;;
  esac
done
# [#96] Loud, un-missable banner so a NON-GATING failure or a DEFERRED (nightly-only)
# TB can never slip past silently — the whole point of the issue: stop "known-slow"
# drifting into "known-broken". Non-gating failures do NOT flip the exit code (that is
# their contract) but they MUST be seen; deferrals are surfaced so PR reviewers know a
# TB did not actually run here.
if [ "$nongate_fail" -gt 0 ]; then
  echo   "!!!==========================================================================!!!"
  printf '!!! WARNING: %d NON-GATING TB failure(s) — NOT gating the suite, but BROKEN:\n' "$nongate_fail"
  ohw_ifs=$IFS; IFS=' '
  for n in $nongate_fail_names; do [ -n "$n" ] && printf '!!!   - %s (verdict=%s)\n' "${n%:*}" "${n##*:}"; done
  IFS=$ohw_ifs
  echo   "!!! A non-gating TB that FAILS is drifting toward known-broken. Fix or re-gate."
  echo   "!!!==========================================================================!!!"
fi
if [ "$deferred" -gt 0 ]; then
  printf '### NOTE: %d TB(s) DEFERRED (nightly-only, did NOT run in this tier):%s — run --tier=nightly to gate them.\n' \
         "$deferred" "$defer_names"
fi
# A BENCH has no verdict to gate on — its VALUE is its stdout (tb_profile's cyc/px
# table). When one actually ran (only possible under Verilator, see VERILATOR_OK),
# echo it so the numbers land in the local terminal and the CI log instead of being
# buried in .simbuild/. Silent when no bench ran, so the default Icarus run is
# byte-identical to before.
for tb in "${TBS[@]}"; do
  top="${tb%.sv}"
  case " $SKIP " in *" $top "*)
    [ -s "$BUILD/$top.run.log" ] && {
      printf '\n--- %s (benchmark output, no verdict) ---\n' "$top"
      cat "$BUILD/$top.run.log"
      printf -- '---\n'
    } ;;
  esac
done
printf 'passed=%d  gating-failures=%d  non-gating-failures=%d  skipped=%d' \
       "$passed" "$gate_fail" "$nongate_fail" "$skipped"
[ "$deferred" -gt 0 ] && printf '  deferred=%d' "$deferred"; echo
[ $gate_fail -eq 0 ] && { echo "RESULT: PASS"; exit 0; } || { echo "RESULT: FAIL"; exit 1; }
