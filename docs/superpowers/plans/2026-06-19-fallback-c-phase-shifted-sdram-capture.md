# Fallback C — Phase-Shifted SDRAM Capture Clock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the SDRAM read-data DQ→`dout64` capture real timing margin by phase-shifting the SDRAM output clock from a dedicated PLL output, with zero RTL-logic / zero read-latency change.

**Architecture:** Add a 4th PLL output `clk_sdram` (clk_sys frequency, tunable phase φ) and source `SDRAM_CLK` from it instead of the altddio-invert of clk_sys. Moving the chip's clock slides the read-data eye so the (fixed) clk_sys capture edge lands inside the valid window after the unpackable ~5.2 ns `dout64` demux route. The capture stays on clk_sys, so the blitter write-coalesce is never touched. φ is found by a CI phase sweep reading the real STA margin.

**Tech Stack:** Intel/Altera Cyclone V `altera_pll` megafunction (hand-edited), SystemVerilog (`sdram_psx.sv`), Quartus 17.0 SDC timing constraints, iverilog sim suite (`fpga/sim/run_sims.sh`), GitHub Actions `build-rbf.yml`.

## Global Constraints

- Branch: `feature-sdram-64mb-geometry`. Base for PR: `master`.
- clk_sys = PLL `general[0]` = 98.4375 MHz, phase 0. Period = 10158.7 ps.
- The new `clk_sdram` is PLL `general[3]`, 98.4375 MHz, phase φ (swept).
- `clk_sdram` MUST be timed **synchronously** with clk_sys — do NOT add it to the
  `set_clock_groups -asynchronous` list in `fpga/Solarus.sdc`.
- ZERO change to `sdram_psx` read/capture logic, cap_idx, `data_ready_delay`, or
  read latency. The ONLY RTL change in `sdram_psx.sv` is the altddio `outclock`
  source (new `clk_sdram` port).
- Sims are a **regression guard only** (the DQ-capture margin is physical, invisible
  to behavioral sim). The real signal is the STA report's `SDRAM_DQ→dout64` setup
  margin (build script already emits it, `build_solarus.sh` lines 88–97).
- Done-bar (user choice): one φ with a genuinely positive, honestly-modeled setup
  margin on `SDRAM_DQ→dout64` + an HW smoke-boot that renders. Flag the actual
  margin; a marginal positive (< ~0.3 ns) warrants a soak before calling #34 closed.
- Commit messages end with the repo's required trailers (Co-Authored-By + Claude-Session).
- Phase→ps table (×10158.7 ps / 360): 45°=1270, 90°=2540, 135°=3810, 180°=5079,
  225°=6349, 270°=7619, 315°=8889 ps.

---

### Task 1: Plumb a dedicated `clk_sdram` PLL output to the SDRAM_CLK forwarder (phase 0 — behavior-identical)

At phase 0, `clk_sdram` ≡ clk_sys, so `SDRAM_CLK` (altddio-inverted `clk_sdram`) is
bit-identical to today's inverted-clk_sys output. This task is a pure plumbing
refactor; the full sim suite must still pass unchanged.

**Files:**
- Modify: `fpga/rtl/pll/pll_0002.v` (add 4th output)
- Modify: `fpga/rtl/pll.v` (expose outclk_3)
- Modify: `fpga/Solarus.sv:318` area (wire), `:325` area (PLL connect), `:472-488` (sps instance)
- Modify: `fpga/rtl/sdram_psx.sv:51` (port), `:565-588` (altddio outclock)
- Modify (tie new port to `clk`): `fpga/sim/tb_sdram_psx.sv:18`,
  `fpga/sim/tb_sdram_ctrl.sv:33`, `fpga/sim/tb_sdram_stage.sv:77`,
  `fpga/sim/tb_sdram_sweep.sv:77,105,133`, `fpga/sim/tb_blitter_system.sv:121`,
  `fpga/sim/tb_capture_race.sv:95`, `fpga/sim/tb_blitter_rd_desync.sv:141`,
  `fpga/sim/tb_vram_contention.sv:191`
- Test: `fpga/sim/run_sims.sh` (whole suite)

**Interfaces:**
- Produces: `sdram_psx` gains `input clk_sdram;` (the SDRAM_CLK forwarder clock).
  Top-level wire `clk_sdram` driven by PLL `.outclk_3`.

- [ ] **Step 1: Baseline — run the full sim suite, confirm all green BEFORE any change**

Run: `cd fpga/sim && ./run_sims.sh`
Expected: all testbenches PASS (record the count, e.g. "19/19"). This is the
regression baseline.

- [ ] **Step 2: Add the 4th PLL output in the megafunction instance**

In `fpga/rtl/pll/pll_0002.v`, change `number_of_clocks(3)` to `number_of_clocks(4)`
and set output 3's params (was `output_clock_frequency3("0 MHz")`):

```verilog
		.number_of_clocks(4),
```
```verilog
		.output_clock_frequency3("98.437500 MHz"),
		.phase_shift3("0 ps"),
		.duty_cycle3(50),
```

Add the port to the module header (after `output wire outclk_2,`):

```verilog
	// interface 'outclk3'
	output wire outclk_3,
```

And extend the `.outclk` concat in the `altera_pll` instance:

```verilog
		.outclk	({outclk_3, outclk_2, outclk_1, outclk_0}),
```

- [ ] **Step 3: Expose outclk_3 through the pll.v wrapper**

In `fpga/rtl/pll.v`, add to the `pll` module port list (after `output wire outclk_2,`):

```verilog
		output wire  outclk_3, // outclk3.clk
```

And to the `pll_0002 pll_inst (...)` connection (after `.outclk_2 (outclk_2),`):

```verilog
		.outclk_3 (outclk_3), // outclk3.clk
```

- [ ] **Step 4: Declare + connect `clk_sdram` in Solarus.sv**

In `fpga/Solarus.sv`, after `wire clk_20m;` / `wire clk_pix;` (the clk_pix comment
line near :320), add:

```verilog
wire clk_sdram; // PLL outclk_3: 98.4375 MHz, phase-shifted SDRAM capture clock (#34 fallback C)
```

In the `pll pll (...)` instance (after `.outclk_2(clk_pix),`):

```verilog
	.outclk_3(clk_sdram),
```

- [ ] **Step 5: Add `clk_sdram` input port to sdram_psx**

In `fpga/rtl/sdram_psx.sv`, in the port list right after `input clk,` (the
`// clock ~100MHz` line):

```verilog
   input             clk_sdram,   // phase-shiftable SDRAM_CLK forwarder clock (#34
                                  // fallback C); clk_sdram==clk at phase 0. Drives
                                  // ONLY the SDRAM_CLK altddio — capture stays on clk.
```

- [ ] **Step 6: Source the SDRAM_CLK altddio from clk_sdram**

In `fpga/rtl/sdram_psx.sv`, the `sdramclk_ddr` altddio instance, change ONLY:

```verilog
	.outclock(clk_sdram),
```
(was `.outclock(clk),`). Leave `datain_h(1'b0)`, `datain_l(1'b1)` unchanged.

- [ ] **Step 7: Connect clk_sdram at the Solarus.sv sps instance**

In `fpga/Solarus.sv` the `sdram_psx #(.BURST_BEATS(1)) sps (...)` instance, add an
explicit connection right after `.clk     (clk_sys),`:

```verilog
	.clk_sdram(clk_sdram),
```
(Explicit, not relying on `.*` — `.*` hides port mismatches the sims never catch.)

- [ ] **Step 8: Tie clk_sdram to clk in every sim instantiation**

In each of these 8 instances, add `.clk_sdram(clk),` immediately after the existing
`.clk(clk),` (or `.clk(<tb-clock>),`) connection. Use the SAME signal the TB already
feeds `.clk`:
- `fpga/sim/tb_sdram_psx.sv:18` (`dut`)
- `fpga/sim/tb_sdram_ctrl.sv:33` (`dut`)
- `fpga/sim/tb_sdram_stage.sv:77` (`sps`)
- `fpga/sim/tb_sdram_sweep.sv:77` (`dutA`), `:105` (`dutB`), `:133` (`dutC`)
- `fpga/sim/tb_blitter_system.sv:121` (`sps`)
- `fpga/sim/tb_capture_race.sv:95` (`sps`)
- `fpga/sim/tb_blitter_rd_desync.sv:141` (`sps`)
- `fpga/sim/tb_vram_contention.sv:191` (`sps`)

Example (tb_sdram_psx.sv): find the `.clk(clk),` line in the `dut` instance and add
below it:

```verilog
    .clk_sdram(clk),
```

- [ ] **Step 9: Re-run the full sim suite — must match the Step-1 baseline**

Run: `cd fpga/sim && ./run_sims.sh`
Expected: identical PASS result to Step 1 (same count, all green). clk_sdram==clk at
phase 0 ⇒ behavior is unchanged. If ANY test that passed in Step 1 now fails, a
wiring edit is wrong — fix before committing.

- [ ] **Step 10: Commit**

```bash
git add fpga/rtl/pll/pll_0002.v fpga/rtl/pll.v fpga/Solarus.sv fpga/rtl/sdram_psx.sv fpga/sim/tb_*.sv
git commit -m "feat(#34): add clk_sdram PLL output feeding SDRAM_CLK (phase 0, no-op refactor)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JXncPJXr9YurT9qc19bhWe"
```

---

### Task 2: SDC — honest DQ-capture model (drop the masking multicycle)

Replace the masking multicycle (which HIDES the DQ→dout64 path) with a real
`set_input_delay`, and source `SDRAM_CLK` from `clk_sdram` (general[3]). At phase 0
this will report the TRUE (currently marginal/negative) capture margin — that is the
expected, honest baseline that Task 4's sweep then improves.

**Files:**
- Modify: `fpga/Solarus.sdc` (SDRAM physical-interface section)

**Interfaces:**
- Consumes: `clk_sdram` = PLL `general[3]` output (from Task 1).

- [ ] **Step 1: Re-point the generated SDRAM_CLK to the clk_sdram PLL pin**

In `fpga/Solarus.sdc`, change `set sdram_clk_src` from `general[0]` to `general[3]`:

```tcl
set sdram_clk_src \
    {emu|pll|pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}
```
Leave the `create_generated_clock -name SDRAM_CLK -source [get_pins $sdram_clk_src]
-invert [get_ports SDRAM_CLK]` line as-is (still `-invert`: the altddio inverts).

- [ ] **Step 2: Delete the masking DQ→dout64 multicycle, add honest set_input_delay**

In `fpga/Solarus.sdc`, REMOVE the block:

```tcl
set sdram_dq_capture {emu:emu|sdram_psx:sps|dout64[*]}
set_multicycle_path -setup -end -from [get_keepers {SDRAM_DQ[*]}] \
    -to [get_keepers $sdram_dq_capture] 2
```

REPLACE it with an honest input-delay model (AS4C32M16 SDR SDRAM clock-to-DQ access
tAC max ≈ 5.4–6.0 ns, output-hold tOH min ≈ 2.5 ns, plus a small board allowance —
validate against the actual module datasheet; these are datasheet-derived, not the
old guessed 6.4/3.2):

```tcl
# DQ read-capture: honest source-synchronous input delay relative to SDRAM_CLK
# (datasheet tAC max / tOH min + board). With SDRAM_CLK center-aligned via the
# clk_sdram phase (#34 fallback C), STA reports the TRUE single-cycle capture
# margin on SDRAM_DQ -> sdram_psx|dout64[*] (no masking multicycle).
set_input_delay -clock SDRAM_CLK -max 6.0 [get_ports {SDRAM_DQ[*]}]
set_input_delay -clock SDRAM_CLK -min 2.5 [get_ports {SDRAM_DQ[*]}]
```

- [ ] **Step 3: Remove the read-direction clock multicycle so the capture is timed honestly**

In `fpga/Solarus.sdc`, REMOVE the SDRAM_CLK→clk_sys (read/capture direction)
multicycle pair so the DQ capture is analyzed as a normal (single-cycle) source-sync
relationship against the now-center-aligned clock:

```tcl
set_multicycle_path -from [get_clocks {SDRAM_CLK}] \
    -to [get_clocks $sdram_clk_src] -setup -end 2
set_multicycle_path -from [get_clocks {SDRAM_CLK}] \
    -to [get_clocks $sdram_clk_src] -hold  -end 2
```
KEEP the clk_sys→SDRAM_CLK (write/command-out direction) multicycle pair and the
`set_output_delay` lines unchanged (they bound the drive-out side, which has margin).

- [ ] **Step 4: Confirm clk_sdram is NOT in the async clock-group**

Verify the `set_clock_groups -asynchronous` block still lists only general[0],
general[2], and pll_audio — NOT general[3]. (clk_sdram must stay synchronous to
clk_sys for the capture path to be analyzed.) No edit if already absent.

- [ ] **Step 5: Trigger a phase-0 baseline CI build and read the honest margin**

```bash
git add fpga/Solarus.sdc
git commit -m "fix(#34): honest SDRAM DQ-capture SDC (drop mask, real set_input_delay)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JXncPJXr9YurT9qc19bhWe"
git push
```
Then watch the auto-triggered windows build:
```bash
gh run list --workflow build-rbf.yml -L 3
gh run view <id> --log | grep -A30 "=== SDRAM: DQ read-capture"
```
Expected: the report now lists a REAL `SDRAM_DQ[*] -> ...sps|dout64[*]` setup path
with a finite (likely negative/marginal at phase 0) slack — NOT "masked"/absent.
This confirms the model is honest. Record the phase-0 slack as the sweep baseline.

---

### Task 3: Add a `sdram_phase` sweep input to build-rbf.yml

Let CI build an arbitrary φ without committing, so sweep points run as parallel jobs.

**Files:**
- Modify: `.github/workflows/build-rbf.yml`

**Interfaces:**
- Produces: `workflow_dispatch` input `sdram_phase` (ps string); when non-empty, the
  build seds `phase_shift3("...")` in `pll_0002.v` before compiling.

- [ ] **Step 1: Add the input + sed step**

In `.github/workflows/build-rbf.yml`, under `workflow_dispatch: inputs:` add:

```yaml
      sdram_phase:
        description: 'SDRAM_CLK phase shift in ps (blank = use committed pll_0002.v value)'
        type: string
        default: ''
```

In the `build-windows` job, add a step BEFORE "Compile RBF" (after `actions/checkout`):

```yaml
      - name: Override SDRAM phase (sweep)
        if: ${{ github.event.inputs.sdram_phase != '' }}
        run: |
          sed -i 's/\.phase_shift3("[^"]*")/.phase_shift3("${{ github.event.inputs.sdram_phase }} ps")/' fpga/rtl/pll/pll_0002.v
          grep phase_shift3 fpga/rtl/pll/pll_0002.v
```

- [ ] **Step 2: Validate the workflow file parses**

Run: `gh workflow view build-rbf.yml` (or `actionlint .github/workflows/build-rbf.yml`
if available). Expected: no syntax error; the new `sdram_phase` input is listed.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build-rbf.yml
git commit -m "ci(#34): add sdram_phase sweep input to build-rbf.yml

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JXncPJXr9YurT9qc19bhWe"
git push
```

---

### Task 4: Run the phase sweep, select φ, bake into pll_0002.v

**Files:**
- Modify: `fpga/rtl/pll/pll_0002.v` (`phase_shift3` final value)

**Interfaces:**
- Consumes: the `sdram_phase` CI input (Task 3); the DQ-capture STA report (Task 2).

- [ ] **Step 1: Fire the sweep builds**

For each φ in {1270, 2540, 3810, 5079, 6349, 7619, 8889} ps (45°…315°), launch a
build:
```bash
for P in 1270 2540 3810 5079 6349 7619 8889; do
  gh workflow run build-rbf.yml --ref feature-sdram-64mb-geometry \
    -f runner=windows -f sdram_phase=$P
done
gh run list --workflow build-rbf.yml -L 10
```
(The self-hosted windows runner serializes via the concurrency group; that's fine.)

- [ ] **Step 2: Read each build's DQ-capture setup slack**

For each completed run:
```bash
gh run view <id> --log | grep -A25 "=== SDRAM: DQ read-capture" | grep -i "slack\|dout64"
```
Tabulate φ (ps) → worst `SDRAM_DQ→dout64` setup slack. Combine with the phase-0
baseline from Task 2.

- [ ] **Step 3: Pick the φ with the best (most positive) setup slack**

Choose the φ with maximum margin. If two adjacent points are both positive and close,
prefer the midpoint phase for centering (optionally fire one refinement build between
them and re-read). Record the chosen φ and its slack.

- [ ] **Step 4: Bake the chosen φ into pll_0002.v**

In `fpga/rtl/pll/pll_0002.v`, set the committed value:
```verilog
		.phase_shift3("<chosen φ> ps"),
```

- [ ] **Step 5: Build the committed core and confirm the margin holds**

```bash
git add fpga/rtl/pll/pll_0002.v
git commit -m "fix(#34): bake SDRAM_CLK phase <φ>ps — positive DQ-capture margin

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JXncPJXr9YurT9qc19bhWe"
git push
gh run list --workflow build-rbf.yml -L 2
gh run view <id> --log | grep -A25 "=== SDRAM: DQ read-capture"
```
Expected: the committed (no-override) build reports the same positive
`SDRAM_DQ→dout64` setup slack as the chosen sweep point. Note the exact number —
if < ~0.3 ns, flag for a soak per the done-bar caveat.

---

### Task 5: HW smoke-boot + close-out

**Files:**
- Modify: memory (`fpga-vram-bug3-resume.md`, `fpga-sdram-source-f2h-scanout-contention.md`, `MEMORY.md`)

**Interfaces:** consumes the committed RBF from Task 4.

- [ ] **Step 1: Download + stage the committed RBF**

```bash
gh run download <committed-build-id> -n solarus-rbf -D /tmp/solrbf
cp /tmp/solrbf/Solarus_*.rbf _Other/   # deploy.py ships the latest-sorting one
```

- [ ] **Step 2: Deploy and smoke-boot on .81**

```bash
./deploy.py --no-rbf   # (or full ./deploy.py; engine in deploy/libs is unchanged)
# then on device, per [[fpga-vram-bug3-resume]] Build/deploy/HW recipe:
ssh root@192.168.20.81 'kill -9 $(pidof solarus-run) 2>/dev/null; \
  echo load_core /media/fat/_Other/Solarus_<date>.rbf > /dev/MiSTer_cmd; sleep 6; \
  echo games/Solarus/quests/mystery_of_solarus_dx.sol > /media/fat/config/Solarus.s0; \
  rm -rf /tmp/solarus_quest; \
  setsid env SOLARUS_SDRAM_SRC=1 /media/fat/games/Solarus/solarus_run.sh &'
```
(Retry launch 2–3× for the transient "Cannot open data file".)

- [ ] **Step 3: Confirm it renders**

```bash
ssh root@192.168.20.81 'for i in 1 2 3; do busybox devmem 0x3A000000; sleep 4; done'
```
Expected: frame ctr `0x3A000000` ADVANCES across samples (blitter composites,
scanout alive) and the game animates. That satisfies the STA-only + smoke-boot bar.

- [ ] **Step 4: Update memory + close-out**

Update `fpga-vram-bug3-resume.md` and `fpga-sdram-source-f2h-scanout-contention.md`
with: fallback C landed (φ=<value>ps, DQ-capture setup slack <number>), HW smoke-boot
result, and whether a soak is still owed (if margin < ~0.3 ns). Refresh the MEMORY.md
hooks. Note remaining #34 close-out items (strip debug probe/scaffolding; optional
fitter-seed cushion) if not done here.

---

## Self-Review

**Spec coverage:**
- §Design.1 (PLL 4th output) → Task 1 Steps 2–4. ✓
- §Design.2 (sdram_psx SDRAM_CLK from clk_sdram, no capture change) → Task 1 Steps 5–8. ✓
- §Design.3 (honest SDC: re-source, drop mask, set_input_delay, async-group, keep output) → Task 2. ✓
- §Design.4 (phase sweep CI input + selection + done-bar) → Tasks 3, 4. ✓
- §Validation (sims as regression guard; STA + HW the real check) → Task 1 Steps 1/9, Task 2 Step 5, Task 4, Task 5. ✓
- §Done-bar (STA margin + smoke-boot, <0.3 ns soak caveat) → Task 4 Step 5, Task 5 Step 3. ✓

**Placeholder scan:** `<chosen φ>`/`<φ>`/`<id>`/`<date>`/`<committed-build-id>` are
runtime-resolved values (the sweep result and CI run ids), not unfilled design TBDs —
each has an explicit step that produces it. set_input_delay 6.0/2.5 are concrete
datasheet-derived starting values with a validate note. No vague "add error handling".

**Type/name consistency:** `clk_sdram` port name, `outclk_3`, `general[3]`,
`phase_shift3`, `sdram_phase`, and the `SDRAM_DQ→dout64` STA target are used
identically across all tasks. ✓
