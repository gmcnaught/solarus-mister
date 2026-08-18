#!/usr/bin/env bash
#============================================================================
#
#  seed_sweep.sh -- Build the Solarus RBF repeatedly with different fitter
#                   seeds and keep the one that closes timing best.
#
#  Usage (from anywhere in the repo):
#      fpga/scripts/seed_sweep.sh [-n TRIALS] [-o OUTDIR] [-l SLACK_LIMIT]
#                                 [--no-stop] [--self-test]
#
#      -n TRIALS       how many seed builds to attempt        (default 4)
#      -o OUTDIR       where the winning RBF lands            (default _Other)
#      -l SLACK_LIMIT  accept a build whose worst setup slack is >= this many
#                      ns even though timing formally failed  (default: unset)
#      --no-stop       run all TRIALS even after one passes (for surveying the
#                      seed landscape rather than just getting a good RBF)
#      --self-test     run the log-parser unit checks and exit
#
#  Create a file named `seed_sweep.stop` in the working directory to stop
#  gracefully after the current trial finishes.
#
#----------------------------------------------------------------------------
#  Modeled on `jtutil seed` from jotego's JTFRAME
#  (modules/jtframe/src/jtutil/cmd/seed.go in jotego/jtcores), which is what
#  drives ~100 MiSTer cores to timing closure nightly. Their CI calls it as
#  `jtutil seed --max-trials 4 <core> -mister`, i.e. seed retry is a NORMAL
#  part of every build there, not a manual escape hatch.
#
#  Four behaviours are taken from it deliberately:
#
#    1. FIRST TRIAL USES THE COMMITTED SEED. jotego's `--zero` default starts
#       at seed 0 so the first attempt is reproducible and a sweep that
#       succeeds immediately changes nothing. Ours starts at whatever
#       Solarus.qsf holds, for the same reason.
#    2. KEEP THE BEST, NOT THE LAST. Their `copy_if_best` only replaces the
#       release RBF when a trial's slack beats the incumbent. A sweep that
#       never closes timing still leaves you the least-bad bitstream.
#    3. STOP AS SOON AS TIMING IS MET (`--stop`, default on). Seeds are a
#       lottery; there is no value in buying more tickets after a win.
#    4. AN "ACCEPTABLE" THRESHOLD. Their JTFRAME_EASY_STA accepts slack better
#       than -0.5 ns for cores known to tolerate it. That is `-l` here, and it
#       is deliberately opt-in per invocation rather than a committed default.
#
#  Why this belongs on the NAS runner: a seed sweep is embarrassingly parallel
#  in wall-clock terms and pure CPU-hours in cost. That is exactly the workload
#  you do not want to rent from GitHub, and exactly what an idle NAS is for.
#
#  Copyright (C) 2026 MiSTer Organize -- GPL-3.0
#============================================================================

set -euo pipefail

TRIALS=4
OUTDIR=""
SLACK_LIMIT=""
STOP_ON_PASS=1
SELF_TEST=0
STOP_FILE="seed_sweep.stop"

#---------------------------------------------------------------------------
# Log parsing
#
# Quartus emits one "Worst-case setup slack is <ns>" line PER CLOCK DOMAIN, so
# the honest figure is the MINIMUM across all of them — the same reduction
# jotego does across every *.sta.summary it finds. Taking the last line, or the
# first, silently reports one domain's margin as if it were the core's.
#
# The pattern is anchored on the hyphenated "Worst-case <kind> slack is" wording
# used by the Fitter/TimeQuest summary. It deliberately does NOT match the
# "Worst case slack is" lines that build_solarus.sh's rpt_timing.tcl emits per
# report_timing section — notably the DQ-capture one, which CLAUDE.md records as
# NOT a valid cross-configuration comparator.
#---------------------------------------------------------------------------
slack_min() {
    local kind="$1" file="$2"
    [ -f "$file" ] || return 0
    awk -v kind="$kind" '
        index($0, "Worst-case " kind " slack is") {
            for (i = 1; i < NF; i++) {
                if ($i == "is") {
                    v = $(i + 1) + 0
                    if (!seen || v < min) { min = v; seen = 1 }
                }
            }
        }
        END { if (seen) printf "%.3f\n", min }
    ' "$file"
}

# Quartus reports a timing failure as a Critical Warning, not an error, so the
# compile "succeeds" either way. This line is the actual verdict.
timing_met() {
    local file="$1"
    [ -f "$file" ] || return 1
    ! grep -q "Timing requirements not met" "$file"
}

# Portable float compare: awk, because bash has no float arithmetic and `bc`
# is not guaranteed present in the runner image.
fgt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }

#---------------------------------------------------------------------------
# Self-test: the parser is the one piece of logic here that can be checked
# without a 40-minute Quartus run, so it is checked.
#---------------------------------------------------------------------------
run_self_test() {
    local tmp status=0
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    cat > "$tmp/multi.log" <<'EOF'
Info (332146): Worst-case setup slack is 1.234
Info (332146): Worst-case setup slack is -0.169
Info (332146): Worst-case setup slack is 0.500
Info (332146): Worst-case hold slack is 0.021
Info: Worst case slack is 5.499
EOF
    cat > "$tmp/fail.log" <<'EOF'
Critical Warning (332148): Timing requirements not met
Info (332146): Worst-case setup slack is -1.002
EOF
    printf 'nothing to see here\n' > "$tmp/none.log"

    check() {
        local what="$1" got="$2" want="$3"
        if [ "$got" = "$want" ]; then
            printf '  ok   %-38s -> %s\n' "$what" "$got"
        else
            printf '  FAIL %-38s -> got %q, want %q\n' "$what" "$got" "$want"
            status=1
        fi
    }

    echo "seed_sweep.sh self-test:"
    # Minimum across domains, NOT the first or last line seen.
    check "min setup slack over 3 domains" "$(slack_min setup "$tmp/multi.log")" "-0.169"
    check "hold slack parsed separately"   "$(slack_min hold  "$tmp/multi.log")" "0.021"
    check "no match -> empty"              "$(slack_min setup "$tmp/none.log")"  ""
    check "missing file -> empty"          "$(slack_min setup "$tmp/nope.log")"  ""
    check "negative slack parsed"          "$(slack_min setup "$tmp/fail.log")"  "-1.002"

    if timing_met "$tmp/multi.log"; then
        printf '  ok   %-38s -> pass\n' "timing_met on clean log"
    else
        printf '  FAIL %-38s -> reported failure\n' "timing_met on clean log"; status=1
    fi
    if timing_met "$tmp/fail.log"; then
        printf '  FAIL %-38s -> reported pass\n' "timing_met on failing log"; status=1
    else
        printf '  ok   %-38s -> fail\n' "timing_met on failing log"
    fi

    # The "Worst case slack is 5.499" line in multi.log must NOT be picked up —
    # that is the report_timing wording, and mixing it in would report a
    # DQ-capture path's margin as the core's worst setup slack.
    check "report_timing wording ignored"  "$(slack_min setup "$tmp/multi.log")" "-0.169"

    [ $status -eq 0 ] && echo "  all parser checks passed"
    return $status
}

#---------------------------------------------------------------------------
# Print the header block between the title line and the modeling note, with the
# comment markers stripped. Keeping usage text in exactly one place means it
# cannot drift from the header a reader sees when they open the file.
usage() {
    sed -n '/^#  seed_sweep\.sh --/,/^#-----/p' "$0" \
        | sed -e '$d' -e 's/^#\{1\} \{0,2\}//' -e 's/^#$//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -n) TRIALS="$2"; shift 2 ;;
        -o) OUTDIR="$2"; shift 2 ;;
        -l) SLACK_LIMIT="$2"; shift 2 ;;
        --no-stop)   STOP_ON_PASS=0; shift ;;
        --self-test) SELF_TEST=1; shift ;;
        -h|--help)   usage 0 ;;
        *) echo "ERROR: unknown argument '$1'" >&2; usage 1 ;;
    esac
done

if [ "$SELF_TEST" = 1 ]; then
    run_self_test
    exit $?
fi

case "$TRIALS" in
    ''|*[!0-9]*) echo "ERROR: -n must be a positive integer, got '$TRIALS'" >&2; exit 1 ;;
esac
[ "$TRIALS" -ge 1 ] || { echo "ERROR: -n must be >= 1" >&2; exit 1; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
FPGA_DIR="$REPO_ROOT/fpga"
QSF="$FPGA_DIR/Solarus.qsf"
[ -f "$QSF" ] || { echo "ERROR: $QSF not found" >&2; exit 1; }

if [ -z "$OUTDIR" ]; then OUTDIR="$REPO_ROOT/_Other"; fi
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"

SWEEP_DIR="$FPGA_DIR/seed_sweep"
rm -rf "$SWEEP_DIR"
mkdir -p "$SWEEP_DIR"

# Restore the committed Solarus.qsf however we exit — a sweep that leaves a
# random seed committed would silently change what every later build produces.
QSF_BACKUP="$SWEEP_DIR/Solarus.qsf.orig"
cp "$QSF" "$QSF_BACKUP"
# shellcheck disable=SC2317  # invoked indirectly, via the trap below
restore_qsf() { cp "$QSF_BACKUP" "$QSF"; }
trap restore_qsf EXIT INT TERM

COMMITTED_SEED="$(awk '/^set_global_assignment -name SEED /{print $NF}' "$QSF")"
[ -n "$COMMITTED_SEED" ] || { echo "ERROR: no SEED assignment found in $QSF" >&2; exit 1; }

set_seed() {
    sed -i "s/^set_global_assignment -name SEED .*/set_global_assignment -name SEED $1/" "$QSF"
}

echo "============================================"
echo "  Solarus RBF seed sweep"
echo "  trials      : $TRIALS"
echo "  first seed  : $COMMITTED_SEED (committed)"
echo "  output      : $OUTDIR"
[ -n "$SLACK_LIMIT" ] && echo "  accept >=   : $SLACK_LIMIT ns"
[ "$STOP_ON_PASS" = 1 ] && echo "  stop on pass: yes" || echo "  stop on pass: no"
echo "============================================"

best_slack=""
best_seed=""
best_rbf=""
passed=0
used_seeds=" $COMMITTED_SEED "
summary=""
sweep_start=$SECONDS

for trial in $(seq 1 "$TRIALS"); do
    if [ "$trial" -eq 1 ]; then
        seed="$COMMITTED_SEED"
    else
        # Distinct random seeds, as jotego's next_seed() does. Quartus accepts
        # 1..2^32-1; 32767 is plenty of lottery tickets and keeps $RANDOM honest.
        seed=$((RANDOM % 32767 + 1))
        while case "$used_seeds" in *" $seed "*) true ;; *) false ;; esac; do
            seed=$((RANDOM % 32767 + 1))
        done
        used_seeds="$used_seeds$seed "
    fi

    trial_dir="$SWEEP_DIR/seed-$seed"
    mkdir -p "$trial_dir"
    echo ""
    echo ">>> Trial $trial/$TRIALS — seed $seed"
    set_seed "$seed"

    trial_start=$SECONDS
    build_ok=1
    # build_solarus.sh must run from fpga/ (it uses relative output_files/ paths)
    # and takes the RBF destination as $1.
    ( cd "$FPGA_DIR" && bash build_solarus.sh "$trial_dir" ) 2>&1 \
        | tee "$trial_dir/console.log" || build_ok=0
    trial_secs=$((SECONDS - trial_start))

    # Keep this trial's Quartus logs; build_solarus.sh names them by DATE, so
    # same-day trials would otherwise overwrite each other.
    mv "$FPGA_DIR"/build_*.log "$FPGA_DIR"/sta_*.log "$trial_dir/" 2>/dev/null || true

    setup="$(slack_min setup "$trial_dir/console.log")"
    hold="$(slack_min hold  "$trial_dir/console.log")"
    # shellcheck disable=SC2012  # build_solarus.sh names these Solarus_YYYYMMDD.rbf —
    # fixed, alphanumeric, no whitespace — so ls is safe and clearer than find here.
    rbf="$(ls "$trial_dir"/Solarus_*.rbf 2>/dev/null | head -1 || true)"

    if [ "$build_ok" = 0 ] || [ -z "$rbf" ]; then
        echo ">>> seed $seed: BUILD FAILED after ${trial_secs}s (see $trial_dir/console.log)"
        summary="${summary}  seed ${seed}: build failed after ${trial_secs}s\n"
        continue
    fi

    met=0
    timing_met "$trial_dir/console.log" && met=1

    echo ">>> seed $seed: setup slack ${setup:-n/a} ns, hold ${hold:-n/a} ns, ${trial_secs}s, timing $([ $met = 1 ] && echo MET || echo FAILED)"
    summary="${summary}  seed ${seed}: setup ${setup:-n/a} hold ${hold:-n/a} $([ $met = 1 ] && echo MET || echo failed) (${trial_secs}s)\n"

    # Keep the best, not the last.
    if [ -n "$setup" ] && { [ -z "$best_slack" ] || fgt "$setup" "$best_slack"; }; then
        best_slack="$setup"
        best_seed="$seed"
        best_rbf="$rbf"
        echo ">>> seed $seed is the new best (setup slack $setup ns)"
    fi

    if [ "$met" = 1 ]; then
        passed=1
        if [ "$STOP_ON_PASS" = 1 ]; then
            echo ">>> Timing met — stopping early."
            break
        fi
    fi

    if [ -f "$STOP_FILE" ]; then
        echo ">>> $STOP_FILE present — stopping after this trial."
        break
    fi
done

echo ""
echo "============================================"
echo "  Sweep summary  ($(( (SECONDS - sweep_start) / 60 )) min total)"
printf "%b" "$summary"
echo "============================================"

if [ -z "$best_rbf" ]; then
    echo "ERROR: no trial produced an RBF." >&2
    exit 1
fi

cp "$best_rbf" "$OUTDIR/"
WINNER="$OUTDIR/$(basename "$best_rbf")"
echo "  best seed   : $best_seed"
echo "  setup slack : $best_slack ns"
echo "  RBF         : $WINNER"

if [ "$passed" = 1 ]; then
    echo "  verdict     : PASS (timing met)"
    if [ "$best_seed" != "$COMMITTED_SEED" ]; then
        echo ""
        echo "  NOTE: the winning seed is not the committed one. To make this"
        echo "        result reproducible, commit it:"
        echo "          set_global_assignment -name SEED $best_seed"
        echo "        in fpga/Solarus.qsf (Solarus.qsf has been restored to"
        echo "        seed $COMMITTED_SEED)."
    fi
    exit 0
fi

if [ -n "$SLACK_LIMIT" ] && [ -n "$best_slack" ] && fgt "$best_slack" "$SLACK_LIMIT"; then
    echo "  verdict     : ACCEPTED (slack $best_slack ns better than limit $SLACK_LIMIT ns)"
    exit 0
fi

echo "  verdict     : FAIL — no seed met timing"
exit 1
