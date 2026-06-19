# dq_ff Packed SDRAM Capture + Latency-Robust Blitter — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the SDRAM read-capture robust (build-invariant) by packing the DQ capture into a Fast-Input register, absorbing the resulting +1 read-data cycle at the one fragile blitter transition, and restoring an honest (non-masking) SDC timing model.

**Architecture:** `sdram_psx` gains a flat `dq_in` pin register so `SDRAM_DQ → dout64` splits into a packed pin path + an internal reg→reg path (kills the ~5.2 ns binding route). That adds +1 cycle to `dout64`/`dout_ready`, which corrupts exactly one qword in `tb_blitter_system` PHASE3 (a single source/command-boundary transition); we localize and gate that transition on the existing read-data handshake. The SDC reverts from the keeper-multicycle "mask" back to an honest `set_input_delay`, which now passes because the path packs.

**Tech Stack:** SystemVerilog (Quartus 17.0 / DE10-Nano Cyclone V), Icarus Verilog sims (`fpga/sim/run_sims.sh`), Micron model (`-DUSE_MICRON`), GitHub-Actions Quartus build (`build-rbf.yml`, Windows self-hosted runner), `deploy.py` over SSH to `192.168.20.81`.

## Global Constraints

- **Do not disturb bug1 (`S_WWAIT` dst desync, commit `71f5c85`)** — HW-confirmed fixed.
- **Branch:** `feature-sdram-64mb-geometry`. Commit messages end with the repo's
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` + `Claude-Session:` trailers.
- **Vendored-blitter discipline:** the core blend/coalesce logic in `fpga/rtl/blitter_top.sv`
  is touched **minimally**; bound the Component-3 change to the single PHASE3 transition.
  If the fix cascades into broad write-coalesce changes, STOP — that is the mis-scope signal;
  escalate to fallback approach C (phase-shifted capture clock) rather than an open-ended rework.
- **Sim runner:** `cd fpga/sim && ./run_sims.sh [tb ...]` (zero-delay chip). Micron build is manual
  (`-DUSE_MICRON -y ../../../jtcores/modules/jtframe/hdl/ver`). The full gating suite must end `RESULT: PASS`.
- **The real bar is HW robustness ACROSS fits**, not one lucky build (618j ran 17.5k frames then
  618k — a probe-only refit — wedged). Validate on ≥2 independent fits.

---

### Task 1: Localize-the-qword instrumentation in tb_blitter_system PHASE3

Add a per-pixel mismatch dump to PHASE3 so the corrupted qword's coordinates are visible. PHASE3
currently only prints `p3errs` and pixel 0; we need coordinates to trace the FSM. This is pure test
instrumentation (no RTL change) and is harmless when there are 0 errors.

**Files:**
- Modify: `fpga/sim/tb_blitter_system.sv` (PHASE3 check loop, around the `p3errs` accumulation ~line 400-421)

**Interfaces:**
- Consumes: existing PHASE3 arrays `p3_a` (flagged→SDRAM dst) / `p3_b` (unflagged→DDR3 dst) and the
  `sdram_fb0_px(r,c)` / readback helpers already used by PHASE3.
- Produces: on mismatch, a line `P3 mismatch @r,c: got=%h exp=%h (src=SDRAM|DDR3)` — used by Task 3 to
  locate the qword.

- [ ] **Step 1: Read the current PHASE3 check to match its exact variables**

Run: `sed -n '382,424p' fpga/sim/tb_blitter_system.sv`
Expected: see the PHASE3 loop computing `p3errs` and the `$display("=== PHASE3 ...")` summary. Note the
exact loop indices and the expected/actual expressions it compares (mirror them in Step 2).

- [ ] **Step 2: Add a bounded per-pixel mismatch dump inside the PHASE3 compare loop**

In the PHASE3 comparison loop, immediately where `p3errs` is incremented, add a guarded print (cap at 16
lines so a full-sprite miss can't flood). Use the SAME expected/actual expressions the loop already uses;
the snippet below shows the shape — adapt the variable names to the ones found in Step 1:

```systemverilog
// #34 dqff: localize the corrupted qword (cap output)
if (p3errs < 16)
    $display("  P3 mismatch @%0d,%0d: got=%h exp=%h", r, c, got_px, exp_px);
```

- [ ] **Step 3: Build + run the suite's PHASE3 test to confirm the dump is silent when green**

Run: `cd fpga/sim && ./run_sims.sh tb_blitter_system 2>&1 | grep -E "PHASE3|RESULT"`
Expected: `PHASE3 (per-cmd mux): PASS` and no `P3 mismatch` lines (baseline RTL has 0 PHASE3 errors).

- [ ] **Step 4: Commit**

```bash
git add fpga/sim/tb_blitter_system.sv
git commit -m "test(#34): per-pixel PHASE3 mismatch dump to localize the dq_ff qword

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JXncPJXr9YurT9qc19bhWe"
```

---

### Task 2: Re-apply the packed `dq_in` capture in sdram_psx (RED)

Re-apply the exact `dq_in`/`dr0_q` change from the reverted commit `4dd5e39` (only the `sdram_psx.sv`
portion — NOT the demux/arbiter write-hold scaffolding that was in other files of that commit). This is
the production change; it makes `tb_blitter_system` PHASE3 fail (the RED for Task 3) while keeping the
SDRAM controller's own data-correctness tests green.

**Files:**
- Modify: `fpga/rtl/sdram_psx.sv` (restored verbatim from `4dd5e39`)

**Interfaces:**
- Consumes: nothing new.
- Produces: `dout64`/`dout_ready` arrive **+1 clk_sys cycle later**; the external port list is unchanged.

- [ ] **Step 1: Confirm sdram_psx is currently the baseline (no dq_in)**

Run: `git diff --quiet 84b0858 -- fpga/rtl/sdram_psx.sv && echo BASELINE || echo MODIFIED`
Expected: `BASELINE` (current file == pre-WIP; the `4dd5e39` dq_in change is the only delta to apply).

- [ ] **Step 2: Apply the dq_in change verbatim from 4dd5e39**

Run: `git checkout 4dd5e39 -- fpga/rtl/sdram_psx.sv`
Then verify it added exactly the packed-register stage:
Run: `grep -nE "dq_in|dr0_q" fpga/rtl/sdram_psx.sv`
Expected: `reg [15:0] dq_in;`, `reg dr0_q;`, `dq_in <= SDRAM_DQ;`, `dr0_q <= data_ready_delay[0];`,
`dout64[...] <= dq_in;`, `else if (dr0_q)`, and `dr0_q <= 1'b0;` in reset.

- [ ] **Step 3: Verify the SDRAM controller's own data-correctness tests still PASS**

Run: `cd fpga/sim && ./run_sims.sh tb_sdram_psx tb_sdram_sweep tb_scanout_sdram 2>&1 | tail -6`
Expected: all `PASS` (the +1 latency is data-correct; only the blitter's timing assumption is affected).

- [ ] **Step 4: Run tb_blitter_system to capture the RED + the qword coordinates**

Run: `cd fpga/sim && ./run_sims.sh tb_blitter_system 2>&1 | grep -E "PHASE|P3 mismatch|RESULT"`
Expected: PHASE1/2/4 PASS, **PHASE3 FAIL** with `p3errs=4`, and up to 4 `P3 mismatch @r,c` lines.
**Record the (r,c) coordinates** — Task 3 uses them. (Confirms the bug is one qword = 4 adjacent pixels.)

- [ ] **Step 5: Commit the RED baseline (PHASE3 is non-gating, so the suite still reports PASS overall)**

```bash
git add fpga/rtl/sdram_psx.sv
git commit -m "feat(#34): packed dq_in SDRAM capture (RED: tb_blitter_system PHASE3 1 qword)

Re-applies the 4dd5e39 sdram_psx dq_in/dr0_q Fast-INPUT-register stage ONLY (no
write-hold scaffolding). Splits the unpackable SDRAM_DQ->dout64 binding path into a
packed pin register + internal reg->reg. +1 read-data cycle; sdram_psx data tests
PASS; tb_blitter_system PHASE3 now fails by exactly one qword (the Task-3 target).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JXncPJXr9YurT9qc19bhWe"
```

---

### Task 3: Localize + fix the one fragile blitter transition (GREEN)

Use the PHASE3 coordinates from Task 2 to find the single `blitter_top` FSM transition that assumes a
fixed read-data arrival cycle, and gate it on the explicit read-data handshake so it tolerates the +1
cycle. The read CAPTURE is already handshake-safe (`S_RD_WAIT` waits on `mem_dout_ready`); the fragility
is a DOWNSTREAM consumer that reads `rd_data` / a cache value on an assumed cycle.

**Files:**
- Modify: `fpga/rtl/blitter_top.sv` (the single transition identified below — keep it minimal)
- (Reference only) `fpga/sim/tb_blitter_system.sv` PHASE3 — the failing test

**Interfaces:**
- Consumes: `mem_dout_ready` (the read-data-valid strobe), `rd_data` (captured beat), and the
  `src_cache_*` / `dst_cache_*` valid/qword signals already in `blitter_top`.
- Produces: PHASE3 passes; `dout64` +1 latency fully absorbed. No port changes.

- [ ] **Step 1: Map the corrupted (r,c) to the responsible FSM transition**

The corrupted qword sits at a **source/command boundary** (PHASE3 = per-command source mux; PHASE2 with
the same source path PASSES, so it's the *transition* between the flagged SDRAM-source blit and the
unflagged DDR-source blit, or the dst-cache state carried across it).

**Important framing:** the *read-result consumers* (`S_BLIT_GOTSRC`, `S_BLIT_GOTDST`) are reached only via
`rd_ret` out of `S_RD_WAIT`, which already waits on `mem_dout_ready` — so they receive valid `rd_data`
even under +1 latency. The bug is therefore NOT a read consumer reading early; it is a **data-coherency
hazard whose timing window the +1 cycle widens.** Inspect candidates in this priority order:

Run: `sed -n '474,620p' fpga/rtl/blitter_top.sv`
Candidates (lead hypothesis first):
  1. **dst RMW read-after-flush hazard** (`S_DST_FLUSH` write vs the next `S_BLIT_RDDST`/`S_DST_RDISS` read
     of the SAME qword). The coalesce flush is a WRITE; the next RMW reads the dst qword back. With +1 read
     latency the flush-vs-read ordering shifts, so an RMW read can be issued/captured **before the pending
     flush of that same qword has landed in SDRAM** → reads stale dst → wrong blend for that qword. This
     is the classic write-before-read coherency hazard and best fits "one qword at a boundary."
  2. **src/dst cache validity carried across the command switch** (`src_cache_vld`/`src_cache_qw`,
     `dst_cache_vld`/`dst_cache_qw`) — a HIT judged against a cache populated by the *previous* command
     whose in-flight read now lands a cycle later, so the hit/miss decision races the populate.
  3. **`S_BLIT_WR` coalesce-merge vs flush ordering** at the command boundary — the final-qword flush of
     command N overlapping command N+1's first read.

Identify the ONE transition where a value is consumed before the operation it depends on (a pending write,
or an in-flight cache populate) has completed. Write down the exact lines.

- [ ] **Step 2: Add a focused assertion that captures the bug (sharper RED than a pixel diff)**

In `fpga/sim/tb_blitter_system.sv`, near the identified transition's observable effect, add a temporary
`$display`/check that fires when the consumer reads stale data (e.g., capturing `rd_data` while the
blitter is NOT in the cycle the demux asserted `mem_dout_ready`). Keep it cheap; this both confirms the
diagnosis and guards the fix. Example shape (adapt signals to the located transition):

```systemverilog
// #34 dqff: flag a stale-read consume (read result used a cycle before/after dready)
if (blt.<consumer_state> && !blt.mem_dout_ready_q && blt.<uses_rd_data>)
    $display("  P3 STALE-CONSUME @%0t state=%0d", $time, blt.state);
```

Run: `cd fpga/sim && ./run_sims.sh tb_blitter_system 2>&1 | grep -E "STALE-CONSUME|PHASE3"`
Expected: at least one `STALE-CONSUME` line coincident with PHASE3 FAIL — confirms the located transition
is the culprit. (If no STALE-CONSUME fires at the located transition, the hypothesis is wrong — return to
Step 1 with the next candidate.)

- [ ] **Step 3: Gate the transition on the read-data handshake (minimal RTL change)**

Add an explicit ordering gate so the dependent consume waits for the operation it depends on. The exact
edit depends on Step 1's finding; the representative pattern for the lead hypothesis (RMW read-after-flush)
is to **hold the dst-RMW read issue until any pending flush of that same qword has been accepted**, e.g.:

```systemverilog
// Representative gate (RMW read-after-flush, lead hypothesis). The dst RMW read of
// dst_qw must not issue while a flush of the SAME qword is still pending/un-accepted.
// dst_cache_dirty marks an un-flushed qword; (dst_qw == dst_cache_qw) means the read
// targets it. Stall the read-issue state one beat until the flush is accepted.
S_DST_RDISS: begin
    if (dst_cache_dirty && (dst_qw == dst_cache_qw)) begin
        // pending flush of this qword: drain it first, then come back to read
        wr_ret2 <= S_DST_RDISS; state <= S_DST_FLUSH;
    end else begin
        mem_rd <= 1; mem_addr <= dst_qw; rd_ret <= S_BLIT_GOTDST; state <= S_RD_WAIT;
    end
end
```

If Step 1 instead points at candidate 2 (cache validity across the command switch), the gate is to
**invalidate / re-check the cache against the in-flight read's completion** rather than the previous
command's populate. Either way: keep the change to the **one** located transition.

**Scope guard:** if making this correct requires editing more than this transition (e.g., re-timing the
whole coalesce or adding handshakes across multiple states), STOP and escalate to fallback C
(phase-shifted capture clock) per the Global Constraints — do not start an open-ended write-coalesce rework.

- [ ] **Step 4: Verify PHASE3 now PASSES and remove the temporary stale-consume check**

Run: `cd fpga/sim && ./run_sims.sh tb_blitter_system 2>&1 | grep -E "PHASE|RESULT"`
Expected: PHASE1/2/3/4 all PASS, `RESULT: PASS`. Then delete the temporary STALE-CONSUME `$display` added
in Step 2 (keep the per-pixel dump from Task 1 — it's harmless and useful), and re-run to confirm still PASS.

- [ ] **Step 5: Full regression suite (no other test may regress)**

Run: `cd fpga/sim && ./run_sims.sh 2>&1 | tail -6`
Expected: `passed=19  gating-failures=0  non-gating-failures=0  skipped=1` / `RESULT: PASS` — including
`tb_blitter_rd_desync`, `tb_vram_contention`, `tb_capture_race`, `tb_blitter_blend/coalesce/palpha`.

- [ ] **Step 6: Micron-timing confirmation of the two contention sims (faithful CAS)**

Run:
```bash
cd fpga/sim
STUBS=$(ls ./*_stub.sv 2>/dev/null)
iverilog -g2012 -DUSE_MICRON -o .simbuild/vc_m.vvp -I ../rtl -I ../sys -I . \
  -y ../rtl -y ../sys -y . -y ../../../jtcores/modules/jtframe/hdl/ver -Y .sv -Y .v $STUBS tb_vram_contention.sv
gtimeout 540 vvp .simbuild/vc_m.vvp 2>&1 | grep -E "RESULT|WEDGE"
```
Expected: `RESULT: PASS` (the +1 latency under real CAS timing still completes).

- [ ] **Step 7: Commit the GREEN fix**

```bash
git add fpga/rtl/blitter_top.sv fpga/sim/tb_blitter_system.sv
git commit -m "fix(#34): absorb dq_ff +1 read latency at the PHASE3 transition (GREEN)

Gates the single source/command-boundary transition on the read-data handshake so
the packed-capture +1 cycle is absorbed. tb_blitter_system PHASE3 PASS; full suite
19/19 (zero-delay + Micron tb_vram_contention). Bounded to one transition per the
scope guard.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JXncPJXr9YurT9qc19bhWe"
```

---

### Task 4: Restore the honest SDC model + clean build

With `dq_in` packed, the `SDRAM_DQ → dq_in` path genuinely meets a real `set_input_delay`. Revert the
keeper-multicycle "mask" (`9396da6`) back to the honest model and confirm the build reports clean global
slack **for real** (not by hiding the path).

**Files:**
- Modify: `fpga/Solarus.sdc` (restored to the honest `set_input_delay` model from `84b0858`)

**Interfaces:**
- Consumes: the packed `dq_in` register from Task 2 (so the input path is now meetable).
- Produces: a build whose worst-case setup slack is positive on the honest model.

- [ ] **Step 1: Restore the honest set_input_delay SDC**

Run: `git checkout 84b0858 -- fpga/Solarus.sdc`
Then confirm it has the honest input-delay (not the keeper-multicycle mask):
Run: `grep -nE "set_input_delay|set_multicycle_path .*get_keepers" fpga/Solarus.sdc`
Expected: `set_input_delay -clock SDRAM_CLK -max 6.4` / `-min 3.2` present; NO `get_keepers {SDRAM_DQ[*]}`
multicycle. (If the keeper line is still present, the wrong revision was checked out.)

- [ ] **Step 2: Commit the SDC restore**

```bash
git add fpga/Solarus.sdc
git commit -m "fix(#34): restore honest set_input_delay SDC (dq_in now packs)

Reverts the 9396da6 keeper-multicycle mask. With dq_in packed at the pin, the
SDRAM_DQ->dq_in path meets a real input-delay; STA is truthful again rather than
hiding the binding path.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JXncPJXr9YurT9qc19bhWe"
```

- [ ] **Step 3: Push + kick the Windows build**

```bash
git push origin feature-sdram-64mb-geometry
sleep 6
gh run list --branch feature-sdram-64mb-geometry --limit 1 --workflow build-rbf.yml --json databaseId,status
```
Expected: a build `in_progress`; record its `databaseId`.

- [ ] **Step 4: Wait for the build + verify HONEST global slack is clean**

```bash
ID=<databaseId>
until [ "$(gh run view $ID --json status -q .status)" = "completed" ]; do sleep 20; done
gh run view $ID --json conclusion -q .conclusion
gh run view $ID --log | grep -iE "Worst-case setup slack is|Launch Clock : SDRAM_CLK|Found .* setup paths .* violated" | head -8
```
Expected: `success`; `Worst-case setup slack is` **positive**; the SDRAM_DQ→dq_in path is NOT in the
violated set. **If setup is still violated on the honest model**, the packing did not fully clear the
path — record the violated path and escalate (do not re-mask; this is the Risk-2 branch in the spec).

---

### Task 5: HW validation across ≥2 fits (the real bar)

Deploy the clean build and prove robustness across **independent fits**, since the wedge is build-variable.
One clean soak is necessary but not sufficient; a second fit must also stay clean.

**Files:** none (deploy + HW only). Device `192.168.20.81`.

**Interfaces:**
- Consumes: the RBF artifact from Task 4's build (`gh run download <ID> -n solarus-rbf`).
- Produces: HW evidence (frame_ctr advancing indefinitely, no wedge) on two fits.

- [ ] **Step 1: Stage + deploy the Task-4 RBF**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
rm -rf /tmp/rbf_dl && mkdir -p /tmp/rbf_dl
gh run download <ID> -n solarus-rbf -D /tmp/rbf_dl
cp /tmp/rbf_dl/Solarus_*.rbf _Other/Solarus_$(date +%Y%m%d)dqff1.rbf
./deploy.py
# verify sha1 matches local (FAT truncation guard)
shasum _Other/Solarus_*dqff1.rbf
ssh root@192.168.20.81 'sha1sum /media/fat/_Other/Solarus_*dqff1.rbf'
```
Expected: device sha1 == local sha1.

- [ ] **Step 2: Launch the mystery quest and soak ~3 min (well past prior wedge points)**

```bash
ssh root@192.168.20.81 'bash -s' <<'EOS'
kill -9 $(pidof solarus-run) 2>/dev/null; sleep 1
echo load_core /media/fat/_Other/$(ls /media/fat/_Other | grep dqff1 | tail -1) > /dev/MiSTer_cmd; sleep 7
echo games/Solarus/quests/mystery_of_solarus_dx.sol > /media/fat/config/Solarus.s0
rm -rf /tmp/solarus_quest
setsid env SOLARUS_SDRAM_SRC=1 /media/fat/games/Solarus/solarus_run.sh >/tmp/solarus.log 2>&1 &
sleep 9; grep -qi "Simulation started" /tmp/solarus.log && echo "LAUNCH OK"
prev=""; for i in $(seq 1 60); do f=$(busybox devmem 0x3A000000);
  [ "$f" = "$prev" ] && froze=$((froze+1)) || froze=0; prev="$f";
  [ $((i%10)) -eq 0 ] && echo "t≈$((i*3))s frame_ctr=$f";
  [ $froze -ge 3 ] && { echo "*** WEDGED @$((i*3))s frame_ctr=$f ***"; break; }; sleep 3; done
echo "final frame_ctr=$(busybox devmem 0x3A000000)"
EOS
```
Expected: `frame_ctr` advances throughout, NO `WEDGED` line (well past 618h@1733 / 618k@~0).

- [ ] **Step 3: Build a SECOND independent fit and soak it too**

A re-run of the workflow on the same commit yields a different placement (timing wanders commit-to-commit
and run-to-run). Trigger a fresh build, download, deploy as `...dqff2.rbf`, and repeat Step 2's soak.

```bash
gh workflow run build-rbf.yml --ref feature-sdram-64mb-geometry
# (wait/download/deploy as Steps 1-2, naming the artifact ...dqff2.rbf, then soak)
```
Expected: the second fit ALSO soaks clean. **Two clean independent fits = robustness demonstrated**
(contrast: 618j clean but 618k — a refit — wedged). If the second fit wedges, packing did not remove the
build-variance → escalate to fallback C (phase-shifted capture clock) per the spec's Risk-3.

- [ ] **Step 4: Record outcome in memory + close**

Update `fpga-vram-bug3-resume.md` with the result (RBF names, two-fit soak outcome, honest SDC slack). If
both fits are clean, #34's source wedge is resolved by the dq_ff fix; note the shippable RBF. If escalated,
record the failing fit's evidence and the pivot to C.

---

## Notes for the implementer

- **Debug probe is already stripped** (`091fcfd`); do NOT re-add it for this work (frame_ctr at
  `0x3A000000` is the functional wedge signal). Re-add transiently only if HW forensics are needed, then strip.
- **Device fallback:** if a build wedges mid-test, an older core (`_Other/Solarus_20260614.rbf`) gives a
  usable display.
- **HW launch is flaky:** the `.sol` read sometimes throws a transient "Cannot open data file"; retry the
  `setsid ... solarus_run.sh` launch 2–3× and re-check for "Simulation started".
