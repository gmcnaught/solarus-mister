# TB Suite Runtime Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut the `fpga/sim` Icarus testbench suite from 818s to a PR-tier ~120–180s (local `--jobs=8` ~70–120s) with zero loss of verified properties.

**Architecture:** Three levers, all measured: (0) free wins — drop a redundant full-screen CLEAR in 6 TBs, tier out 2 always-timeout non-gating TBs; (1) a parallel job pool + tier system in `run_sims.sh`; (2) geometry/rate reductions in the heavyweights, each guarded by a `+define+*_FULL` so full HW-faithful coverage runs nightly. Build caching was measured (7.1s total) and deliberately omitted.

**Tech Stack:** Icarus Verilog 13.0 (`iverilog`/`vvp`), bash (macOS system bash 3.2 + GitHub `ubuntu-latest`), GitHub Actions.

## Global Constraints

- **Branch:** all work on `refactor/tb-suite-runtime` (already created off `master`).
- **Correctness discipline (every Phase 2 geometry/rate change):** (1) capture current PASS + checked-pixel/qword count; (2) make the reduction; (3) re-run reduced, assert still PASS and still exercises the same property; (4) add a `+define+<TB>_FULL` restoring exact HW-faithful geometry/rate; (5) append that macro to `TIER_DEFINES_FULL` in `run_sims.sh` so nightly runs it. A reduction that cannot show (3) is rejected.
- **Never touch the shared `fpga/sim/.simbuild`** while measuring — build into a private dir (e.g. `/tmp/tbrt_build`).
- **Local toolchain path:** iverilog is at `/opt/homebrew/bin` on the dev Mac (prefix commands with `PATH=/opt/homebrew/bin:$PATH`); use `gtimeout` locally, `timeout` in CI.
- **Exit semantics are invariant:** the suite exits 1 iff any *gating* verdict ≠ PASS. `skip`/`defer` never affect the exit code.
- **Tier definitions:** `pr` = all gating TBs at reduced geometry, EXCLUDING `tb_comp_replay` + `tb_blitter_system_pipe`. `nightly` = full suite + all `+*_FULL` defines + bumped timeouts. `all` = every TB at reduced geometry, no `+*_FULL` (so `--tier=all --jobs=1` is byte-identical to today's runner — the regression hatch).

## Task ordering / dependencies

- **Task 0a** (blitter CLEAR) is independent — can land any time.
- **Tasks 0b → 1 → 1-CI** are strictly ordered (Task 1's pool reads 0b's tier data; 1-CI invokes both flags).
- **Tasks 2a, 2b, 2c, 2e** are pure TB-file edits and are mutually independent — see the Team-execution amendment below (they do NOT touch `run_sims.sh`).
- **Task 2d is dropped** (mechanism refuted by measurement — see the note after Task 2e).

## Team-execution amendment (parallel, file-partitioned)

To let three implementers work in parallel with zero shared-file conflict, `fpga/sim/run_sims.sh` is owned **solely by the runner implementer**. This overrides the per-task "wire nightly" / "lower timeout" steps in Tasks 2a/2b/2c/2e:

1. **Task 0b pre-populates ALL `_FULL` macros up front.** In place of the two-macro seed, use:
   ```sh
   TIER_DEFINES_FULL='+define+VRAM_CONTENTION_FULL +define+SCAN_QWORDDUP_FULL +define+BGPLANE_EQUIVALENCE_FULL +define+SCANOUT_FBRAM_FULL +define+AUDIO_WEDGE_FULL +define+BGPLANE_WRITE_FULL +define+FBRAM_SDRAM_FULL'
   ```
   A `+define+X` whose `ifdef X` guard has not landed yet is a harmless no-op, so this is safe before/independent of the Phase 2 TB edits.
2. **Task 0b's nightly timeout bump must also cover the FULL-geometry heavyweights** (they exceed their reduced-tier budgets when `_FULL` restores full geometry). Extend the nightly `case`:
   ```sh
   if [ "$TIER" = nightly ]; then case "$top" in
     tb_comp_replay)          to=600 ;;
     tb_blitter_system_pipe)  to=300 ;;
     tb_bgplane_equivalence)  to=400 ;;   # FULL geometry ~314s > pr/all 300 budget
     tb_vram_contention)      to=300 ;;   # FULL geometry safety margin
   esac; fi
   ```
3. **Phase 2 tasks (2a/2b/2c/2e) edit ONLY their TB `.sv` file(s).** Skip every "append to `TIER_DEFINES_FULL`" and "lower `timeout_s`" sub-step — those are centralized in Task 0b. Keep the direct `iverilog -D<MACRO> …` FULL-geometry verify step (it does not need `run_sims.sh`). Commit only the `.sv` file(s).
4. **Worktree-isolation caveat for the runner implementer:** its worktree does NOT contain the Phase 2 TB reductions, so in isolation `tb_bgplane_equivalence` still runs ~314s. Therefore the runner implementer validates runner *mechanics* with `--tier=all --jobs=1` (byte-identical hatch) and `--jobs=8` (verdict equality); it does NOT lower the pr-tier bgplane timeout, and the pr-tier end-to-end wall-clock target is confirmed post-merge (whole-branch review), when the reductions are present. If `--tier=pr --jobs=8` is run in isolation, an unreduced-bgplane timeout is EXPECTED and not a failure.

**Ownership partition (no two implementers share a file):**
- `impl-runner` → `fpga/sim/run_sims.sh`, `.github/workflows/sim.yml` (Tasks 0b, 1, 1-CI)
- `impl-tbA` → the 6 `tb_blitter_*_pipe.sv` + `tb_fbram_to_sdram.sv` + `tb_fbram_to_sdram_backpressure.sv` (Tasks 0a, 2e)
- `impl-tbB` → `tb_bgplane_equivalence.sv`, `tb_scanout_fbram.sv`, `tb_audio_burst_wedge.sv`, `tb_bgplane_write_pipe.sv` (Tasks 2a, 2b, 2c)

---

### Task 0a: Drop redundant full-screen CLEAR in 6 color-op pipe TBs

**Files (exact line of the `mem[32'h200004]=64'd1` CLEAR flag — re-verified):**
- Modify: `fpga/sim/tb_blitter_add_pipe.sv:105`
- Modify: `fpga/sim/tb_blitter_blend_pipe.sv:107`
- Modify: `fpga/sim/tb_blitter_cafill_pipe.sv:112`
- Modify: `fpga/sim/tb_blitter_colormod_pipe.sv:158`
- Modify: `fpga/sim/tb_blitter_mul_pipe.sv:104`
- Modify: `fpga/sim/tb_blitter_palpha_pipe.sv:125`

**Why:** each TB already seeds the entire `comp_fbram` to `BG` in its `initial` block, then *also* sets the control-block CLEAR flag with `clear_color=BG`. The CLEAR re-composites BG over an already-BG framebuffer — a full-screen 320×240 fill (~80,500 cycles ≈ 805M ps) that dominated each run before the tiny 2×2 test blit. Pure redundancy, not coverage — so **no `_FULL` define is needed** (nothing to restore).

- [ ] **Step 1: record baseline.**
```bash
cd fpga/sim
mkdir -p /tmp/blitterpipe_build
for t in tb_blitter_add_pipe tb_blitter_blend_pipe tb_blitter_cafill_pipe \
         tb_blitter_colormod_pipe tb_blitter_mul_pipe tb_blitter_palpha_pipe; do
  PATH=/opt/homebrew/bin:$PATH iverilog -g2012 -o /tmp/blitterpipe_build/$t.vvp \
    -I ../rtl -I ../rtl/jtframe -I ../sys -I . \
    -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v *_stub.sv $t.sv \
    && /usr/bin/time -p gtimeout 120 vvp /tmp/blitterpipe_build/$t.vvp 2>&1 | grep -E "RESULT:|real"
done
```
Expected: each prints `RESULT: PASS` and a `real` line ~3.3–3.6 s.

- [ ] **Step 2: edit.** In each file change the CLEAR flag `1`→`0` on the cited line. Exact change for `tb_blitter_add_pipe.sv:105`:
```
before: mem[32'h200003]={48'd0,BG}; mem[32'h200004]=64'd1; mem[32'h200005]=64'd0;  // CLEAR=BG
after:  mem[32'h200003]={48'd0,BG}; mem[32'h200004]=64'd0; mem[32'h200005]=64'd0;  // no CLEAR: FB pre-seeded BG (Phase 0a)
```
The identical one-token edit (match on `mem[32'h200004]=64'd1`) applies to blend:107, cafill:112, colormod:158, mul:104, palpha:125. Leave `mem[32'h200003]` and the FB pre-seed loop untouched.

- [ ] **Step 3: re-run each — assert still bit-exact PASS, run time dropped.** Re-run the Step 1 loop. Expected: every TB still `RESULT: PASS` with zero `MISMATCH` lines, `real` now ~1.2–1.4 s. Measured reference: add 3.34→1.30, blend 3.36→1.19, cafill 3.49→1.16, colormod 3.59→1.28, mul 3.35→1.40, palpha 3.31→1.24.

- [ ] **Step 4: commit.**
```bash
git add fpga/sim/tb_blitter_add_pipe.sv fpga/sim/tb_blitter_blend_pipe.sv \
        fpga/sim/tb_blitter_cafill_pipe.sv fpga/sim/tb_blitter_colormod_pipe.sv \
        fpga/sim/tb_blitter_mul_pipe.sv fpga/sim/tb_blitter_palpha_pipe.sv
git commit -m "test(fpga/sim): drop redundant full-screen CLEAR in 6 color-op pipe TBs"
```

---

### Task 0b: Add `--tier=pr|nightly|all`; defer the 2 always-timeout non-gating TBs from PR

**Files:** Modify `fpga/sim/run_sims.sh`.

**Interfaces produced (Task 1 and Phase 2 consume these):**
- `NIGHTLY_ONLY="tb_comp_replay tb_blitter_system_pipe"` — deferred in `pr` tier.
- `TIER_DEFINES_FULL='...'` — macros applied to every compile in `nightly`; Phase 2 appends to it.
- `--tier=<pr|nightly|all>` arg; `TIER` / `TIER_DEFINES` vars.

- [ ] **Step 1: baseline (the invariant Task 1 diffs against).** Run once (~14 min):
```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
PATH=/opt/homebrew/bin:$PATH bash fpga/sim/run_sims.sh 2>&1 | tee /tmp/tb_baseline_today.log
```
Expected tail: `passed=…  gating-failures=0  non-gating-failures=…  skipped=1` then `RESULT: PASS`.

- [ ] **Step 2: add tier data block.** In `fpga/sim/run_sims.sh`, immediately after the `NONGATING=…` line (currently line 88):
```sh
# ── tiers ───────────────────────────────────────────────────────────────────
# NIGHTLY_ONLY: non-gating TBs that cannot finish in the PR budget (comp_replay
# ~350s, blitter_system_pipe >120s + currently FAILs). Excluded from the PR tier
# (zero gating coverage lost — the pipe cutover is covered by tb_comp_pipeline +
# the 7 tb_blitter_*_pipe TBs and tb_vram_demux). They still run (non-gating) in
# nightly/all.
NIGHTLY_ONLY="tb_comp_replay tb_blitter_system_pipe"

# +defines applied to EVERY compile in the nightly tier to restore full
# HW-faithful geometry/rate. Harmless on TBs that don't reference a macro, so
# Phase 2 tasks append their knob here as they add each _FULL guard.
TIER_DEFINES_FULL='+define+VRAM_CONTENTION_FULL +define+SCAN_QWORDDUP_FULL'
# (Phase 2 appends: BGPLANE_EQUIVALENCE_FULL SCANOUT_FBRAM_FULL AUDIO_WEDGE_FULL
#  BGPLANE_WRITE_FULL FBRAM_SDRAM_FULL)
```

- [ ] **Step 3: parse `--tier` and select defines.** Replace the TB-selection block (currently lines 130–135):
```sh
# ── tier + positional-TB parsing ────────────────────────────────────────────
TIER=pr; POS=()
for a in "$@"; do
  case "$a" in
    --tier=*) TIER="${a#--tier=}" ;;
    *)        POS+=("$a") ;;
  esac
done
case "$TIER" in pr|nightly|all) ;; *) echo "ERROR: --tier must be pr|nightly|all"; exit 2;; esac
set -- ${POS[@]+"${POS[@]}"}            # bash-3.2-safe empty-array expansion (macOS)

TIER_DEFINES=''
[ "$TIER" = nightly ] && TIER_DEFINES="$TIER_DEFINES_FULL"

# Which testbenches to run
if [ $# -gt 0 ]; then
  TBS=(); for a in "$@"; do TBS+=("${a%.sv}.sv"); done
else
  TBS=(tb_*.sv)
fi
```

- [ ] **Step 4: PR-tier defer + nightly timeout bump.** Add `deferred=0` to the tally-init line (line 137). After the SKIP line (line 143) insert:
```sh
  # PR tier defers the nightly-only non-gating TBs entirely (no verdict, no tally).
  if [ "$TIER" = pr ]; then
    case " $NIGHTLY_ONLY " in *" $top "*)
      printf '%-26s %-8s %s\n' "$top" "defer" "nightly-only (excluded from pr tier)"
      deferred=$((deferred+1)); continue;; esac
  fi
```
After the existing `to=$(timeout_s "$top")` (line 159):
```sh
  if [ "$TIER" = nightly ]; then case "$top" in
    tb_comp_replay)          to=600 ;;   # needs ~350s to PASS
    tb_blitter_system_pipe)  to=300 ;;
  esac; fi
```

- [ ] **Step 5: thread tier defines into the compile.** In the `iverilog` invocation (lines 148–151), add `$TIER_DEFINES` next to `$(defines_for "$top")`:
```sh
  if ! iverilog -g2012 -o "$BUILD/$top.vvp" \
        $(defines_for "$top") $TIER_DEFINES \
        -I ../rtl -I ../rtl/jtframe -I ../sys -I . \
        -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v \
        $STUBS "$tb" >"$blog" 2>&1; then
```

- [ ] **Step 6: summary line (append `deferred` only when >0).** Replace line 182:
```sh
printf 'passed=%d  gating-failures=%d  non-gating-failures=%d  skipped=%d' \
       "$passed" "$gate_fail" "$nongate_fail" "$skipped"
[ "$deferred" -gt 0 ] && printf '  deferred=%d' "$deferred"; echo
```
(Exit line 183 unchanged: `[ $gate_fail -eq 0 ] && exit 0 || exit 1`.)

- [ ] **Step 7: verify PR tier defers the 2, still PASSes.**
```bash
PATH=/opt/homebrew/bin:$PATH bash fpga/sim/run_sims.sh --tier=pr 2>&1 | tee /tmp/tb_pr.log
grep -E '^(tb_comp_replay|tb_blitter_system_pipe) +defer' /tmp/tb_pr.log | wc -l   # -> 2
grep 'RESULT: PASS' /tmp/tb_pr.log                                                  # present
```
Summary shows `gating-failures=0  …  deferred=2`. Wall drops ~150s (~660s pre-Phase-2, still serial).

- [ ] **Step 8: verify `all` runs everything, today-equivalent.**
```bash
PATH=/opt/homebrew/bin:$PATH bash fpga/sim/run_sims.sh --tier=all 2>&1 | tee /tmp/tb_all.log
grep -E '^tb_comp_replay|^tb_blitter_system_pipe' /tmp/tb_all.log   # real rows, NOT defer
diff <(awk '{print $1,$2}' /tmp/tb_baseline_today.log) <(awk '{print $1,$2}' /tmp/tb_all.log)  # no verdict diffs
```

- [ ] **Step 9: smoke nightly plumbing (define reaches compile).**
```bash
PATH=/opt/homebrew/bin:$PATH bash fpga/sim/run_sims.sh --tier=nightly tb_vram_contention 2>&1 | tee /tmp/tb_nightly_smoke.log
grep -c VRAM_CONTENTION_FULL fpga/sim/.simbuild/tb_vram_contention.build.log   # -> >=1
```

- [ ] **Step 10: commit.**
```bash
git add fpga/sim/run_sims.sh
git commit -m "sim: add --tier=pr|nightly|all; defer 2 non-gating always-timeout TBs from PR tier"
```

---

### Task 1: Parallel job pool (`--jobs=N`, `--jobs=1` = exact serial hatch)

**Files:** Modify `fpga/sim/run_sims.sh`. **Depends on Task 0b.**

Uses `xargs -P` (portable to macOS system bash 3.2; `wait -n` needs bash ≥4.3). iverilog uses unique `/var/folders/.../ivrlg<pid>` temp dirs and each TB writes distinct `$top.vvp`/logs, so parallel compiles into `.simbuild` don't collide. Build cache omitted (measured 7.1s).

- [ ] **Step 1: baseline the serial hatch invariant.**
```bash
PATH=/opt/homebrew/bin:$PATH bash fpga/sim/run_sims.sh --tier=all 2>&1 | tee /tmp/tb_all_serial.log
```

- [ ] **Step 2: parse `--jobs`.** Extend the parse block from Task 0b Step 3:
```sh
TIER=pr; JOBS=0; POS=()
for a in "$@"; do
  case "$a" in
    --tier=*) TIER="${a#--tier=}" ;;
    --jobs=*) JOBS="${a#--jobs=}" ;;
    *)        POS+=("$a") ;;
  esac
done
case "$TIER" in pr|nightly|all) ;; *) echo "ERROR: --tier must be pr|nightly|all"; exit 2;; esac
set -- ${POS[@]+"${POS[@]}"}
TIER_DEFINES=''; [ "$TIER" = nightly ] && TIER_DEFINES="$TIER_DEFINES_FULL"
# default N = nproc-2 (>=1); N=1 reproduces today's exact serial order+output
if [ "$JOBS" -le 0 ] 2>/dev/null; then
  NPROC=$( { command -v nproc >/dev/null && nproc; } || sysctl -n hw.ncpu || echo 2 )
  JOBS=$(( NPROC > 2 ? NPROC - 2 : 1 ))
fi
```

- [ ] **Step 3: add a results dir.** After `BUILD=.simbuild; rm -rf "$BUILD"; mkdir -p "$BUILD"` (line 127):
```sh
RESULTS="$BUILD/results"; mkdir -p "$RESULTS"
```

- [ ] **Step 4: extract the per-TB body into `run_one_tb()`.** Replace the entire `for tb in "${TBS[@]}"; do … done` loop (lines 141–179) with this function (today's body verbatim, plus per-TB `.result`/`.row` files; prints the row live only when `JOBS=1`):
```sh
run_one_tb() {
  local tb="$1" top="${tb%.sv}" row gating=1 blog rlog to rc out ok=0 verdict note tag secs t0
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
    tb_comp_replay) to=600 ;; tb_blitter_system_pipe) to=300 ;; esac; fi
  if [ -n "$TIMEOUT" ]; then "$TIMEOUT" "$to" vvp "$BUILD/$top.vvp" >"$rlog" 2>&1; rc=$?
  else vvp "$BUILD/$top.vvp" >"$rlog" 2>&1; rc=$?; fi
  secs=$(awk "BEGIN{printf \"%.1f\", $(date +%s.%N)-$t0}")
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
```

- [ ] **Step 5: dispatch (xargs pool) + reducer.** After the function, replace the old summary block (lines 181–183). Note the pre-loop tally-init line from 0b is removed — the reducer owns the counters:
```sh
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
```

- [ ] **Step 6: verify `--jobs=1` == serial hatch (byte-identical — the gate).**
```bash
PATH=/opt/homebrew/bin:$PATH bash fpga/sim/run_sims.sh --tier=all --jobs=1 2>&1 | tee /tmp/tb_all_j1.log
diff /tmp/tb_all_serial.log /tmp/tb_all_j1.log   # -> no diff
```
A non-empty diff blocks the task.

- [ ] **Step 7: verify `--jobs=8` same verdicts, faster.**
```bash
time PATH=/opt/homebrew/bin:$PATH bash fpga/sim/run_sims.sh --tier=all --jobs=8 2>&1 | tee /tmp/tb_all_j8.log
diff <(sort /tmp/tb_all_j1.log | awk '{print $1,$2}') <(sort /tmp/tb_all_j8.log | awk '{print $1,$2}')  # -> no diff
```
Wall-clock expect ~250–314s (floor = tb_bgplane_equivalence, pre-Phase-2).

- [ ] **Step 8: commit.**
```bash
git add fpga/sim/run_sims.sh
git commit -m "sim: parallel job pool (--jobs=N, xargs -P); per-TB result files + reducer; --jobs=1 = exact serial hatch"
```

---

### Task 1-CI: `sim.yml` — single runner, tiered, opportunistic `--jobs=nproc`

**Files:** Modify `.github/workflows/sim.yml`. **Depends on Task 0b + 1.** One job, no matrix sharding.

- [ ] **Step 1: add schedule + keep workflow_dispatch.** Replace the `on:` block:
```yaml
on:
  push:
    paths:
      - 'fpga/rtl/**'
      - 'fpga/sim/**'
      - '.github/workflows/sim.yml'
  pull_request:
    paths:
      - 'fpga/rtl/**'
      - 'fpga/sim/**'
  schedule:
    - cron: '0 7 * * *'        # nightly full-geometry safety net (07:00 UTC)
  workflow_dispatch:
```

- [ ] **Step 2: select tier by event + pass `--jobs=$(nproc)`.** Replace the "Build + run testbenches" step:
```yaml
  - name: Build + run testbenches
    env:
      # schedule + manual dispatch => full-geometry nightly net; push/PR => fast pr tier
      TIER: ${{ (github.event_name == 'schedule' || github.event_name == 'workflow_dispatch') && 'nightly' || 'pr' }}
    run: |
      set -o pipefail            # preserve run_sims.sh exit code through tee
      bash fpga/sim/run_sims.sh --tier="$TIER" --jobs="$(nproc)" | tee sim.log
```
Keep `timeout-minutes: 30`.

- [ ] **Step 3: local sanity-check both invocations (no push needed).**
```bash
PATH=/opt/homebrew/bin:$PATH bash fpga/sim/run_sims.sh --tier=pr --jobs="$( (command -v nproc>/dev/null && nproc) || sysctl -n hw.ncpu)"
```
Expect `RESULT: PASS`, 2 deferred, ~250s. (Nightly path is validated once on-branch before merge.)

- [ ] **Step 4: commit.**
```bash
git add .github/workflows/sim.yml
git commit -m "ci(sim): single runner + tiering — push/PR run --tier=pr --jobs=nproc; nightly cron runs --tier=nightly full geometry"
```

---

### Task 2a: `tb_bgplane_equivalence` geometry reduction (`+define+BGPLANE_EQUIVALENCE_FULL`)

**Files:** Modify `fpga/sim/tb_bgplane_equivalence.sv`; Modify `fpga/sim/run_sims.sh` (TIER_DEFINES_FULL). **Depends on 0b.**

Property preserved: qword-exact equivalence of baked-plane COPY vs static-tile replay, across a 2-cell 640-wide map, camera straddling x=320, non-degenerate cross-cell stride, varied per-tile sx/sy. Runtime scales with pixel *traffic* (`MAP_H`), not tile count. Baseline: 314.5s PASS (`EQUIVALENCE: PASS (76800 pixels)`).

- [ ] **Step 1: baseline.**
```bash
cd fpga/sim; mkdir -p /tmp/tbrt_build
PATH=/opt/homebrew/bin:$PATH iverilog -g2012 -o /tmp/tbrt_build/bg.vvp -I ../rtl -I ../rtl/jtframe -I ../sys -I . \
  -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v *_stub.sv tb_bgplane_equivalence.sv
time gtimeout 400 vvp /tmp/tbrt_build/bg.vvp   # ~314s, RESULT: PASS
```

- [ ] **Step 2: parameterize `MAP_H`.** Line 176 (`localparam integer MAP_W = 640, MAP_H = 240;`) →
```systemverilog
`ifdef BGPLANE_EQUIVALENCE_FULL
  localparam integer MAP_W = 640, MAP_H = 240;   // HW-faithful geometry (nightly)
`else
  localparam integer MAP_W = 640, MAP_H = 80;    // reduced: keep 640 width (2 cells → cross-cell stride)
`endif
```
`COLS/ROWS/NN` (177–178), `PLANE_STRIDE_QW` (=160), `CAM_X=200`, entry loops (214, 230) auto-scale; `NN` = 16×2 = 32; camera x=[200,519] still straddles 320.

- [ ] **Step 3: scale the COPY readback height.** Lines 394–395, change height arg `16'd240` → `16'(MAP_H)`:
```systemverilog
  wr_blit_copy(PLANE_BASE_QW*8, PLANE_STRIDE_QW[15:0]*8, CAM_X[15:0], CAM_Y[15:0],
               16'd320, 16'(MAP_H), 16'd0, 16'd0);
```
(Update the `$display` `h=240`→`h=%0d`,MAP_H — cosmetic.)

- [ ] **Step 4: restrict the two compare loops to round-tripped rows.** Line 339 (`capture_old`) and line 401 (final compare): `yy<240` → `yy<MAP_H` (both).

- [ ] **Step 5: re-run reduced, assert PASS + timing.**
```bash
PATH=/opt/homebrew/bin:$PATH iverilog -g2012 -o /tmp/tbrt_build/bg_r.vvp -I ../rtl -I ../rtl/jtframe -I ../sys -I . \
  -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v *_stub.sv tb_bgplane_equivalence.sv
time gtimeout 200 vvp /tmp/tbrt_build/bg_r.vvp
```
Expect `EQUIVALENCE: PASS (25600 pixels)` + `RESULT: PASS`, ~90–130s. **CHECKPOINT:** if >90s and ≤90s is required, set reduced `MAP_H = 40` (ROWS=1, NN=16) and re-measure → ~60–90s. Both preserve all four invariants.

- [ ] **Step 6: verify FULL define restores HW geometry + PASS.**
```bash
PATH=/opt/homebrew/bin:$PATH iverilog -g2012 -o /tmp/tbrt_build/bg_full.vvp -DBGPLANE_EQUIVALENCE_FULL -I ../rtl -I ../rtl/jtframe -I ../sys -I . \
  -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v *_stub.sv tb_bgplane_equivalence.sv
time gtimeout 400 vvp /tmp/tbrt_build/bg_full.vvp
```
Expect `EQUIVALENCE: PASS (76800 pixels)` + `RESULT: PASS` at ~314s.

- [ ] **Step 7: wire nightly + lower runner budget.** In `fpga/sim/run_sims.sh`: append `+define+BGPLANE_EQUIVALENCE_FULL` to `TIER_DEFINES_FULL`, and lower `timeout_s()` for `tb_bgplane_equivalence` (line 110) from `300` → `200` (reduced default fits well under). Re-run `bash run_sims.sh --tier=pr tb_bgplane_equivalence` (PASS) and `--tier=nightly tb_bgplane_equivalence` (define present in `.simbuild/tb_bgplane_equivalence.build.log`).

- [ ] **Step 8: commit.**
```bash
git add fpga/sim/tb_bgplane_equivalence.sv fpga/sim/run_sims.sh
git commit -m "perf(sim): reduce tb_bgplane_equivalence CI geometry (MAP_H 240->80) behind BGPLANE_EQUIVALENCE_FULL"
```

---

### Task 2b: full-rate `ce_pix` on `tb_scanout_fbram` + `tb_audio_burst_wedge`

**Files:** Modify `fpga/sim/tb_scanout_fbram.sv`, `fpga/sim/tb_audio_burst_wedge.sv`; Modify `fpga/sim/run_sims.sh`. **Depends on 0b.**

`tb_audio_burst_wedge` is the weakest, highest-risk lever (timing-sensitive #39 regression) and may be de-scoped independently. Its gate is the wedge-recovery check (line 461), NOT `px_checked` (dead code after `$finish` line 465).

#### 2b-i `tb_scanout_fbram` — clean ~8× win. Baseline 96.3s PASS (`checked=230400`).

- [ ] **Step 1: baseline.**
```bash
cd fpga/sim
PATH=/opt/homebrew/bin:$PATH iverilog -g2012 -o /tmp/tbrt_build/sc.vvp -I ../rtl -I ../rtl/jtframe -I ../sys -I . \
  -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v *_stub.sv tb_scanout_fbram.sv
time gtimeout 150 vvp /tmp/tbrt_build/sc.vvp   # ~96s, RESULT: PASS
```

- [ ] **Step 2: parameterize `CE_DIV`.** Lines 18–19 → keep `H_TOTAL=420`, guard `CE_DIV`:
```systemverilog
  localparam integer H_TOTAL = 420;
`ifdef SCANOUT_FBRAM_FULL
  localparam integer CE_DIV  = 8;   // HW-faithful ÷8 pixel clock (nightly)
`else
  localparam integer CE_DIV  = 1;   // sim-only full-rate ce_pix (~8× faster frame-paced scanout)
`endif
```
Make the divider honor `CE_DIV` — replace the counter update in the `always @(posedge clk_vid)` (lines 30–31):
```systemverilog
    else begin
      ce_div <= (ce_div == CE_DIV-1) ? 3'd0 : ce_div + 3'd1;
      ce_pix <= (ce_div == 3'd0);   // CE_DIV=1 → every clk_vid; CE_DIV=8 → 1-in-8 (== original)
    end
```

- [ ] **Step 3: cut 3→1 scan frame AND lower the checked threshold (mandatory together).** Add gated params near the top:
```systemverilog
`ifdef SCANOUT_FBRAM_FULL
  localparam integer N_SCAN_FRAMES = 3;
  localparam integer MIN_CHECKED   = 200000;
`else
  localparam integer N_SCAN_FRAMES = 1;
  localparam integer MIN_CHECKED   = 60000;   // one 320×240 frame = 76800 active px; require >60k
`endif
```
Change the scan loop (line 203) `scan < 3` → `scan < N_SCAN_FRAMES`, and the gate (line 210) `px_checked > 200000` → `px_checked > MIN_CHECKED`. Justification: one full frame scans all 76,800 addresses exactly once, so pixel-exactness is fully proven; the 3-frame repeat was belt-and-suspenders from the SDRAM-underflow variant (comp_fbram never backpressures). `MIN_CHECKED=60000` still fails a no-op run (checked≈0).

- [ ] **Step 4: re-run reduced.**
```bash
PATH=/opt/homebrew/bin:$PATH iverilog -g2012 -o /tmp/tbrt_build/sc_r.vvp -I ../rtl -I ../rtl/jtframe -I ../sys -I . \
  -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v *_stub.sv tb_scanout_fbram.sv
time gtimeout 60 vvp /tmp/tbrt_build/sc_r.vvp
```
Expect `PIXEL-EXACT: checked=76800 errs=0 -> PASS` + `RESULT: PASS`, ~10–14s.

- [ ] **Step 5: FULL define restores ÷8 + 3-frame + gate.**
```bash
PATH=/opt/homebrew/bin:$PATH iverilog -g2012 -o /tmp/tbrt_build/sc_full.vvp -DSCANOUT_FBRAM_FULL -I ../rtl -I ../rtl/jtframe -I ../sys -I . \
  -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v *_stub.sv tb_scanout_fbram.sv
time gtimeout 150 vvp /tmp/tbrt_build/sc_full.vvp
```
Expect `checked=230400 errs=0` + `RESULT: PASS` at ~96s.

#### 2b-ii `tb_audio_burst_wedge` — partial win (~80→~45s), highest risk. Baseline 80.6s PASS.

- [ ] **Step 6: baseline.** Build+run `tb_audio_burst_wedge.sv` (as above), `time gtimeout 150 vvp ...` → ~80s `RESULT: PASS`.

- [ ] **Step 7: parameterize `CE_DIV` ONLY.** Line 49 → guard behind `AUDIO_WEDGE_FULL` (8 / else 1); update the divider in `always @(posedge clk_vid)` (lines 62–72) to the same `ce_div <= (ce_div == CE_DIV-1) ? 3'd0 : ce_div + 3'd1;` pattern. **DO NOT** touch the pixel-exact phase (dead code after `$finish` line 465). **DO NOT** shorten `repeat(2_000_000) @(posedge ddr_clk)` at line 457 — it must exceed the reader's audio-ring `TIMEOUT_MAX` (~1.05M) to prove recovery; it is an irreducible ~20ms floor.

- [ ] **Step 8: re-run reduced.** Build + `time gtimeout 120 vvp ...`. Expect `RESULT: PASS` with `advanced≥2`, ~35–50s. **Executor MUST confirm the short burst still fires** (`AUDIO-RING: … after-wait` line prints; no `FAIL (audio-ring read never occurred)`).

- [ ] **Step 9: FULL define restores ÷8.** Build with `-DAUDIO_WEDGE_FULL`; `time gtimeout 150 vvp ...` → `RESULT: PASS` at ~80s.

- [ ] **Step 10: wire nightly + commit.** In `fpga/sim/run_sims.sh` append `+define+SCANOUT_FBRAM_FULL +define+AUDIO_WEDGE_FULL` to `TIER_DEFINES_FULL`. Then:
```bash
git add fpga/sim/tb_scanout_fbram.sv fpga/sim/tb_audio_burst_wedge.sv fpga/sim/run_sims.sh
git commit -m "perf(sim): full-rate ce_pix for tb_scanout_fbram (~96->~12s) + tb_audio_burst_wedge (~80->~45s) behind *_FULL defines"
```

---

### Task 2c: `tb_bgplane_write_pipe` rows 240→12 (`+define+BGPLANE_WRITE_FULL`)

**Files:** Modify `fpga/sim/tb_bgplane_write_pipe.sv`; Modify `fpga/sim/run_sims.sh`. **Depends on 0b.** Validated end-to-end: 82.3s→14.5s PASS.

**Key correction:** the TB's `CELL_ROWS` localparam only bounds preload/verify — the fabric bake volume is an RTL param on the `fbram_to_sdram` instance (`blitter_top.sv:984` `.FB_QWORDS(19200), .CELL_ROWS(240)`). The reduction needs a TB-side `defparam` override of that instance plus a scaled quadrant split.

- [ ] **Step 1: baseline.**
```bash
cd fpga/sim
PATH=/opt/homebrew/bin:$PATH iverilog -g2012 -o /tmp/b.vvp -I ../rtl -I ../rtl/jtframe -I ../sys -I . \
  -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v *_stub.sv tb_bgplane_write_pipe.sv
gtimeout 120 vvp /tmp/b.vvp
```
Expect `CELL DATA: PASS (19200 qwords)`, `GAP UNTOUCHED: PASS (4800 qwords)`, `RESULT: PASS`, ~77–82s.

- [ ] **Step 2a: edit localparams (lines 215–216).**
```systemverilog
  localparam integer CELL_ROW_QW = 80;
`ifdef BGPLANE_WRITE_FULL
  localparam integer CELL_ROWS  = 240;   // full HW plane height (nightly)
  localparam integer QSPLIT_ROW = 120;   // vertical quadrant split at mid-plane
`else
  localparam integer CELL_ROWS  = 12;    // reduced: 12 baked rows still cross the split
  localparam integer QSPLIT_ROW = 6;     // split scaled to CELL_ROWS/2 -> TL/TR + BL/BR both baked
`endif
```

- [ ] **Step 2b: edit the row split (line 224).** `if (row < 120)` → `if (row < QSPLIT_ROW)`.

- [ ] **Step 2c: edit the 4 FILLs (lines 263–266)** so painted split tracks `QSPLIT_ROW`:
```systemverilog
    wr_fill(0, 16'd0,   16'd0,            16'd160, 16'(QSPLIT_ROW),           COLOR_TL);
    wr_fill(1, 16'd160, 16'd0,            16'd160, 16'(QSPLIT_ROW),           COLOR_TR);
    wr_fill(2, 16'd0,   16'(QSPLIT_ROW),  16'd160, 16'(CELL_ROWS-QSPLIT_ROW), COLOR_BL);
    wr_fill(3, 16'd160, 16'(QSPLIT_ROW),  16'd160, 16'(CELL_ROWS-QSPLIT_ROW), COLOR_BR);
```

- [ ] **Step 2d: override the fabric bake volume** — insert immediately before the main `initial begin` at line 239:
```systemverilog
`ifndef BGPLANE_WRITE_FULL
  // Fabric bake volume = blitter_top's fbram_to_sdram instance (u_bgw:
  // FB_QWORDS=19200, CELL_ROWS=240). Override to the reduced window so the streamer
  // bakes only CELL_ROWS rows — strided per-row advance + gap-skip identical, fewer
  // repetitions. (TB-only; no production RTL change.)
  defparam blt.u_bgw.FB_QWORDS = CELL_ROWS*CELL_ROW_QW;
  defparam blt.u_bgw.CELL_ROWS = CELL_ROWS;
`endif
```

- [ ] **Step 3: re-run reduced.** Same build+run as Step 1. Expect `CELL DATA: PASS (960 qwords)`, `GAP UNTOUCHED: PASS (240 qwords)`, `RESULT: PASS`, ~14.5s. (Residual floor is faithful-mt48 init/eval, not bake volume.) Property preserved: 12 rows straddle the split (0–5 TL/TR, 6–11 BL/BR), `STRIDE_QW=100 > CELL_ROW_QW=80` keeps the 20-qword gap per row, columns 0–39/40–79 keep both x<160/x≥160 phases.

- [ ] **Step 4: verify FULL define restores HW geometry.**
```bash
PATH=/opt/homebrew/bin:$PATH iverilog -g2012 -DBGPLANE_WRITE_FULL -o /tmp/bf.vvp -I ../rtl -I ../rtl/jtframe -I ../sys -I . \
  -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v *_stub.sv tb_bgplane_write_pipe.sv
gtimeout 120 vvp /tmp/bf.vvp
```
Expect `CELL DATA: PASS (19200 qwords)`, `GAP UNTOUCHED: PASS (4800 qwords)`, `RESULT: PASS`, ~82s.

- [ ] **Step 5: wire nightly + commit.** Append `+define+BGPLANE_WRITE_FULL` to `TIER_DEFINES_FULL` in `run_sims.sh`. Then:
```bash
git add fpga/sim/tb_bgplane_write_pipe.sv fpga/sim/run_sims.sh
git commit -m "sim(2c): tb_bgplane_write_pipe 240->12 rows behind +define+BGPLANE_WRITE_FULL (82->14.5s, bit-exact)"
```

---

### Task 2e: `tb_fbram_to_sdram` + `_backpressure` rows 240→24 (`+define+FBRAM_SDRAM_FULL`)

**Files:** Modify `fpga/sim/tb_fbram_to_sdram.sv`, `fpga/sim/tb_fbram_to_sdram_backpressure.sv`; Modify `fpga/sim/run_sims.sh`. **Depends on 0b.** Validated in scratch (reduced PASS 0.11/0.13, full-define PASS 0.67/0.89).

- [ ] **Step 1: baseline.**
```bash
cd fpga/sim; B=/tmp/2e_base; mkdir -p $B
for t in tb_fbram_to_sdram tb_fbram_to_sdram_backpressure; do
  PATH=/opt/homebrew/bin:$PATH iverilog -g2012 -o $B/$t.vvp -I ../rtl -I ../rtl/jtframe -I ../sys -I . \
    -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v *_stub.sv $t.sv
  time vvp $B/$t.vvp | grep RESULT
done
```
Expect both `RESULT: PASS`, ~0.96s / ~1.29s.

- [ ] **Step 2: edit `tb_fbram_to_sdram.sv`.** Replace line 7 (`localparam integer NQW = CELL_ROW_QW*240;`) with the guard + NQW:
```systemverilog
`ifdef FBRAM_SDRAM_FULL
  localparam integer CELL_ROWS = 240;  // full 320x240 WORK cell (nightly)
`else
  localparam integer CELL_ROWS = 24;   // reduced default: still crosses many stride wraps
`endif
  localparam integer NQW = CELL_ROW_QW*CELL_ROWS;
```
Then dut param at line 35: `.CELL_ROWS(240)` → `.CELL_ROWS(CELL_ROWS)`.

- [ ] **Step 3: edit `tb_fbram_to_sdram_backpressure.sv` (identical guard).** Replace line 34 (`localparam integer NQW = CELL_ROW_QW*240;`) with the same ifdef block; dut param at line 69 `.CELL_ROWS(240)` → `.CELL_ROWS(CELL_ROWS)`. Verify no stray literals: `grep -n 240 fpga/sim/tb_fbram_to_sdram*.sv` should show only comment text like "320x240".

- [ ] **Step 4: re-run reduced.** Same loop as Step 1 (no define). Expect both `RESULT: PASS`, ~0.11s / ~0.13s.

- [ ] **Step 5: full geometry under define.** Add `-DFBRAM_SDRAM_FULL` to both builds. Expect both `RESULT: PASS` at NQW=19200 (~0.67s / ~0.89s).

- [ ] **Step 6: wire nightly + commit.** Append `+define+FBRAM_SDRAM_FULL` to `TIER_DEFINES_FULL` in `run_sims.sh`. Then:
```bash
git add fpga/sim/tb_fbram_to_sdram.sv fpga/sim/tb_fbram_to_sdram_backpressure.sv fpga/sim/run_sims.sh
git commit -m "test(sim): fbram_to_sdram TBs default to 24 rows; full 240 under +define+FBRAM_SDRAM_FULL"
```

---

### Task 2d: DROPPED — mechanism refuted by measurement

`tb_tilelist` / `tb_tilelist_res` were the speced target for a tile-size/bbox reduction. Empirical testing on scratch copies (4 variants) showed **~0% cycle change** (baseline 1,000,931 cyc → 990,811 with tiles shrunk; all bit-exact PASS). The cost is geometry-independent: a per-submit WORK→SCAN `fbram_snapshot` of the full 320×240 FB (~19,200 cyc × 10 submits ≈ 192k) plus per-tile comp_pipeline fill/P_SRC latency (~800k) that dwarfs pixel count. Per the Global Constraints correctness rule, no valid reduction exists TB-side, so the task is dropped. These two TBs stay at full geometry; Phase 1's parallel pool already overlaps their ~21s/35s with other TBs (net suite impact ≈ 0). A deferred RTL option (`+define+SIM_SKIP_SNAP` in `blitter_top`, ~19%, touches production RTL) is logged in the spec §8.

---

## Self-review

**Spec coverage:** Phase 0 (§5) → Tasks 0a, 0b. Phase 1 (§6) → Tasks 1, 1-CI. Phase 2 (§7): 2a→Task 2a, 2b→Task 2b, 2c→Task 2c, 2d→dropped (documented, spec §7-2d updated), 2e→Task 2e. Correctness discipline (§4) → Global Constraints + each Phase 2 task's `_FULL` steps. Build-cache omission (§2) → stated in Task 1. All covered.

**Placeholder scan:** no TBD/TODO; every code step shows exact before/after; every verify step shows the command + expected marker/timing.

**Type/name consistency:** `--tier` / `--jobs` / `TIER` / `TIER_DEFINES` / `TIER_DEFINES_FULL` / `NIGHTLY_ONLY` / `run_one_tb` / `RESULTS` used identically across Tasks 0b, 1, 1-CI, and the Phase 2 append steps. Every Phase 2 task appends its exact macro (`BGPLANE_EQUIVALENCE_FULL`, `SCANOUT_FBRAM_FULL`, `AUDIO_WEDGE_FULL`, `BGPLANE_WRITE_FULL`, `FBRAM_SDRAM_FULL`) matching its `ifdef` guard. `defparam blt.u_bgw.*` in 2c matches the `blitter_top.sv:984` instance name (executor must confirm the instance path `blt.u_bgw` resolves in the TB before relying on it).

**Shared-file coordination:** Tasks 0b, 1, 2a, 2b, 2c, 2e all edit `fpga/sim/run_sims.sh`. Ordering note at top mandates sequential execution so the `TIER_DEFINES_FULL` line and surrounding blocks don't conflict.

## Success criteria

- `--tier=all --jobs=1` byte-identical to today's runner (regression hatch, Task 1 Step 6).
- PR-tier CI 818s → ~120–180s; local `--jobs=8` ~70–120s.
- Every reduced TB PASSes bit-exact reduced AND under its `+*_FULL` define; nightly tier applies all `+*_FULL`.
- PR runs no longer carry the `tb_comp_replay` timeout or `tb_blitter_system_pipe` FAIL.
