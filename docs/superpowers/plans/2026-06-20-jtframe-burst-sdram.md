# Adopt jtframe_burst_sdram — Implementation Plan (Phase 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `sdram_psx` + `sdram_src_arb` with jtframe's `jtframe_burst_sdram` full-page burst controller, fronted by a new `sdram_burst_arb` (3-client priority + 4×16↔64 packing) that preserves the existing client ports, so the compositor can burst-write the SDRAM framebuffer without the refresh livelock.

**Architecture:** Vendor the jtframe burst controller + deps into `fpga/rtl/jtframe/`. Build `sdram_burst_arb` presenting the SAME `scan_*`/`dst_*`/`p0_*` client ports the system already uses, implemented over jtframe's single 16-bit `addr/ba/rd/wr/din/dout + ack/dst/dok/rdy` consumer port; jtframe owns refresh (driven by a small ~64µs `rfsh` timer). Swap the instantiation in `Solarus.sv`; demux/scanout/comp_pipeline unchanged.

**Tech Stack:** SystemVerilog/Verilog (Cyclone V / DE10-Nano), iverilog sim via `fpga/sim/run_sims.sh`, `mt48lc16m16a2` + `sdram_chip_model` sim models, Quartus fit/STA via CI (`build-rbf.yml`).

## Global Constraints

- One always-block per reg/array (Quartus Error 10028); iverilog won't catch it.
- Quartus synth/STA is CI-only — arm64 host cannot run x86 Quartus. Local gate is iverilog `run_sims.sh`.
- Vendored files carry a provenance header ("VENDORED from jtcores/modules/jtframe/hdl/sdram/<f>; do not edit here, edit upstream + re-copy") and jtframe GPL-3 attribution; never hand-edit vendored RTL.
- Client ports MUST stay byte-compatible: `scan_*` (addr[26:0], rd, burst[7:0], busy, dout64[63:0], dready), `dst_*` (addr[26:0], rd, we, din[15:0], we_burst, din64[63:0], busy, dout64[63:0], dready), `p0_*` (addr[26:0], rd, busy, we, din[15:0], waddr[26:0], we_burst, din64[63:0], dready, dout64[63:0]). `vram_demux`, the scanout reader, and `comp_pipeline` do not change.
- Commit bodies end with:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` and the `Claude-Session:` line.
- jtframe upstream path: `/Users/gmcnaught/MisterFPGA-Projects/jtcores/modules/jtframe/hdl/sdram/`.
- Vendored dep list (from `ver/sdram/burst_sdram_64mb/gather.f`): `jtframe_burst_sdram.v`, `jtframe_burst_mode.v`, `jtframe_burst_ctrl.v`, `jtframe_burst_mux.v`, `jtframe_burst_io.v`, `jtframe_sdram64_init.v`, `jtframe_sdram64_rfsh.v`, `jtframe_sdram64_bank.v`. Chip model `mt48lc16m16a2.v` already exists in `fpga/sim/`.

## File Structure

- `fpga/rtl/jtframe/*.v` — CREATE: the 8 vendored jtframe SDRAM files (do not edit).
- `fpga/rtl/jtframe/PROVENANCE.md` — CREATE: upstream commit/path + dep list.
- `fpga/rtl/sdram_burst_arb.sv` — CREATE: 3-client priority + 16↔64 bridge over jtframe's consumer port. The only substantial new RTL.
- `fpga/Solarus.sv` — MODIFY: replace `sdram_src_arb` + `sdram_psx` instantiation with `sdram_burst_arb` + `jtframe_burst_sdram` + refresh timer.
- `fpga/files.qip` — MODIFY: add the vendored files + `sdram_burst_arb.sv`; remove `sdram_psx`/`sdram_src_arb` if listed.
- `fpga/sim/tb_sdram_burst_arb.sv` — CREATE: unit test (arb + jtframe_burst + chip model).
- `fpga/sim/tb_sdram_psx.sv`, `fpga/sim/tb_sdram_src_arb.sv`, `tb_sdram_src_arb_beatloss.sv` — DELETE (DUTs removed).
- `fpga/rtl/sdram_psx.sv`, `fpga/rtl/sdram_src_arb.sv` — DELETE.
- `fpga/sim/run_sims.sh` — MODIFY: re-gate `tb_vram_contention`; drop removed benches.

---

### Task 1: Vendor jtframe controller + iverilog sim SPIKE (de-risking gate)

**Files:**
- Create: `fpga/rtl/jtframe/jtframe_burst_sdram.v` (+ 7 deps), `fpga/rtl/jtframe/PROVENANCE.md`
- Create (temp): `fpga/sim/tb_jtframe_burst_smoke.sv`

**Interfaces:**
- Produces: a vendored, iverilog-elaboratable `jtframe_burst_sdram` and the answer to "does it simulate under iverilog?" — which gates the rest of the plan.

- [ ] **Step 1: Copy the 8 jtframe files verbatim + write provenance**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister/.claude/worktrees/pipelined-compositor
mkdir -p fpga/rtl/jtframe
JT=/Users/gmcnaught/MisterFPGA-Projects/jtcores/modules/jtframe/hdl/sdram
for f in jtframe_burst_sdram jtframe_burst_mode jtframe_burst_ctrl jtframe_burst_mux \
         jtframe_burst_io jtframe_sdram64_init jtframe_sdram64_rfsh jtframe_sdram64_bank; do
  cp "$JT/$f.v" "fpga/rtl/jtframe/$f.v"
done
( cd /Users/gmcnaught/MisterFPGA-Projects/jtcores && git rev-parse HEAD 2>/dev/null ) # record this hash in PROVENANCE.md
```
Prepend each copied file with a 2-line provenance comment. Write `PROVENANCE.md` listing the upstream repo, commit hash, the 8 files, and "regenerate by re-copying; do not hand-edit."

- [ ] **Step 2: Resolve missing includes/defines**

Run: `cd fpga/sim && iverilog -g2012 -o /tmp/jt_elab.vvp -I ../rtl/jtframe -y ../rtl/jtframe -Y .v ../rtl/jtframe/jtframe_burst_sdram.v 2>&1 | head -40`
Expected: elaboration errors reveal any missing `` `include `` (e.g. a jtframe defs/macro file) or undefined module. If a jtframe macro/defs include is referenced, copy it into `fpga/rtl/jtframe/` too and add to PROVENANCE. Iterate until elaboration is clean (no "unknown module"/"cannot open include").

- [ ] **Step 3: Write a minimal smoke testbench (one write burst, then one read burst, verify data)**

`fpga/sim/tb_jtframe_burst_smoke.sv`: instantiate `jtframe_burst_sdram` (params from `burst_sdram_64mb`: AW per that test) + `mt48lc16m16a2` on the DQ/cmd pins, tie off `prog_*`, drive a periodic `rfsh`. After `init` deasserts: issue `wr` for 4 words at addr A (din 0x1111,0x2222,0x3333,0x4444, drop wr on `rdy`), then `rd` 4 words at A, capture `dout` on `dok`, assert they equal what was written. Print `RESULT: PASS` / `RESULT: FAIL`.

```bash
# get the exact AW/param + tie-offs from the upstream test driver:
sed -n '1,120p' /Users/gmcnaught/MisterFPGA-Projects/jtcores/modules/jtframe/ver/sdram/burst_sdram_64mb/test.v
```

- [ ] **Step 4: Run the smoke test under iverilog**

Run: `cd fpga/sim && iverilog -g2012 -o /tmp/jt_smoke.vvp -I ../rtl/jtframe -y ../rtl/jtframe -Y .v -y . -Y .sv mt48lc16m16a2.v tb_jtframe_burst_smoke.sv && vvp /tmp/jt_smoke.vvp`
Expected: `RESULT: PASS` (write then read returns the same 4 words).

**DECISION GATE:** If iverilog cannot elaborate/run `jtframe_burst_io` (DDIO/`inout` DQ handling) — STOP. Do not proceed. Surface to the human partner: choose (a) add a Verilator local flow for the SDRAM path, or (b) test `sdram_burst_arb` against a behavioral jtframe-consumer stub locally and rely on CI/Verilator for the real controller. The rest of this plan assumes Step 4 passed.

- [ ] **Step 5: Commit the vendored controller + passing smoke test**

```bash
git add fpga/rtl/jtframe/ fpga/sim/tb_jtframe_burst_smoke.sv
git commit -m "vendor: jtframe_burst_sdram + deps; iverilog smoke test (write/read burst)"
```

---

### Task 2: `sdram_burst_arb` — single-client READ burst path (P_SCAN)

**Files:**
- Create: `fpga/rtl/sdram_burst_arb.sv`
- Test: `fpga/sim/tb_sdram_burst_arb.sv`

**Interfaces:**
- Consumes: `jtframe_burst_sdram` consumer port (`addr[AW-1:0], ba[1:0], rd, wr, din[15:0], dout[15:0], ack, dst, dok, rdy, rfsh`).
- Produces: module `sdram_burst_arb` with (this task's subset) client port
  `scan_addr[26:0], scan_rd, scan_burst[7:0], scan_busy, scan_dout64[63:0], scan_dready`,
  controller side wired to one `jtframe_burst_sdram`, plus `rfsh` from an internal ~64µs timer. `scan_burst` = number of 64-bit beats; a read fetches `scan_burst*4` 16-bit words and emits one `scan_dready`+`scan_dout64` per 4 `dok` beats.

- [ ] **Step 1: Write the failing test — a single multi-qword scan read burst**

In `tb_sdram_burst_arb.sv`: instantiate `sdram_burst_arb` + `jtframe_burst_sdram` + `mt48lc16m16a2`, tie `dst_*`/`p0_*` idle. Pre-seed SDRAM (via a write burst helper, or `$readmemh` into the chip model array if supported; otherwise write then read). Issue `scan_rd=1, scan_addr=A, scan_burst=4` (4 qwords = 16 words). Collect 4 `scan_dout64` beats on `scan_dready`; assert they equal the 4 expected qwords (each = `{w3,w2,w1,w0}` little-endian). Print PASS/FAIL.

- [ ] **Step 2: Run, verify it fails (module missing)**

Run: `cd fpga/sim && ./run_sims.sh tb_sdram_burst_arb`
Expected: BUILD! (`sdram_burst_arb` not found) or FAIL.

- [ ] **Step 3: Implement the read-burst path**

`sdram_burst_arb.sv`: on `scan_rd & idle`: latch `addr/ba` from `scan_addr` (map 27-bit byte addr → jtframe word addr+ba per the chip geometry), assert `rd`, hold while beats remain. Count `dok` beats; shift each `dout[15:0]` into a 64-bit assembler (`{dout, asm[63:16]}`); every 4th `dok` emit `scan_dout64`+`scan_dready` (one beat) and decrement the qword counter; drop `rd` after the last word so jtframe stops the page burst; return to idle on `rdy`. `scan_busy` = not-idle-or-not-this-client. One always-block per reg.

- [ ] **Step 4: Run, verify it passes**

Run: `cd fpga/sim && ./run_sims.sh tb_sdram_burst_arb`
Expected: `RESULT: PASS`.

- [ ] **Step 5: Commit**

```bash
git add fpga/rtl/sdram_burst_arb.sv fpga/sim/tb_sdram_burst_arb.sv
git commit -m "feat(sdram): sdram_burst_arb scan read-burst path over jtframe_burst"
```

---

### Task 3: `sdram_burst_arb` — WRITE burst path + post-write read (P_DST RMW)

**Files:**
- Modify: `fpga/rtl/sdram_burst_arb.sv`
- Test: `fpga/sim/tb_sdram_burst_arb.sv` (add cases)

**Interfaces:**
- Produces: `dst_*` client port (`dst_addr[26:0], dst_rd, dst_we, dst_din[15:0], dst_we_burst, dst_din64[63:0], dst_busy, dst_dout64[63:0], dst_dready`). A `dst_we_burst` multi-qword write consumes `dst_din64` beats (unpacked to 4×16 `din`); a following `dst_rd` of the same band returns correct data (RMW post-write read).

- [ ] **Step 1: Write the failing test — write a band then read it back (RMW alignment)**

Add to `tb_sdram_burst_arb.sv`: drive `dst_we_burst=1, dst_addr=B, dst_din64=<N qwords>` (provide each next qword when the arb accepts the prior — mirror comp_burst: advance on the arb's accept strobe), then `dst_rd=1, dst_addr=B, dst_burst=N`; assert read-back qwords == written. This is the exact RMW pattern that livelocked `sdram_psx`.

- [ ] **Step 2: Run, verify it fails**

Run: `cd fpga/sim && ./run_sims.sh tb_sdram_burst_arb`
Expected: FAIL (write path not implemented).

- [ ] **Step 3: Implement the write-burst path**

On `dst_we_burst & idle`: latch `addr/ba`, assert `wr`, and for each qword unpack to 4 `din[15:0]` words (drive word k on consecutive accepted cycles), advancing to the next `dst_din64` when the arb has consumed 4 words; signal the client to advance (drop `dst_busy` for one beat per qword consumed, matching comp_burst's `!mem_busy` advance); hold `wr` across all `4N` words; drop `wr` after the last; idle on `rdy`. Verify no refresh can interrupt mid-burst (jtframe defers; the test in Task 5 proves it).

- [ ] **Step 4: Run, verify it passes**

Run: `cd fpga/sim && ./run_sims.sh tb_sdram_burst_arb`
Expected: `RESULT: PASS` (read-back matches written band).

- [ ] **Step 5: Commit**

```bash
git add fpga/rtl/sdram_burst_arb.sv fpga/sim/tb_sdram_burst_arb.sv
git commit -m "feat(sdram): sdram_burst_arb dst write-burst + RMW read-back"
```

---

### Task 4: `sdram_burst_arb` — 3-client priority (scan > dst > src, scan-never-starve)

**Files:**
- Modify: `fpga/rtl/sdram_burst_arb.sv`
- Test: `fpga/sim/tb_sdram_burst_arb.sv` (add cases)

**Interfaces:**
- Produces: `p0_*` client port (`p0_addr[26:0], p0_rd, p0_busy, p0_dready, p0_dout64[63:0]`; staging-write ports `p0_we, p0_din[15:0], p0_waddr[26:0], p0_we_burst, p0_din64[63:0]` accepted for interface compatibility). Priority: a request is granted only when no higher-priority client holds the burst; `scan_rd` preempts at the next burst boundary (never mid-burst — full-page bursts are atomic) and is never starved.

- [ ] **Step 1: Write the failing test — concurrent scan + dst, assert scan progress + correctness**

Add: assert `scan_rd` continuously (back-to-back line reads) while `dst_we_burst` hammers band writes; over M cycles, require scan completes ≥K line reads AND dst completes ≥1 band, and all read-back data is correct (no cross-client corruption). Mirrors the `tb_vram_contention` intent at unit scope.

- [ ] **Step 2: Run, verify it fails**

Run: `cd fpga/sim && ./run_sims.sh tb_sdram_burst_arb`
Expected: FAIL (only one client served / starvation / corruption).

- [ ] **Step 3: Implement priority + per-burst arbitration**

Grant at burst boundaries (`idle`): pick scan > dst > p0 among asserted requests; latch the granted client for the whole burst; route `dout`/`dready` to that client's `*_dout64`/`*_dready`, `din` from that client's data. After `rdy`, re-arbitrate. Scan-never-starve: because bursts are bounded (line / band) and scan is highest priority, scan always wins the next boundary. One always-block per state reg.

- [ ] **Step 4: Run, verify it passes**

Run: `cd fpga/sim && ./run_sims.sh tb_sdram_burst_arb`
Expected: `RESULT: PASS`.

- [ ] **Step 5: Commit**

```bash
git add fpga/rtl/sdram_burst_arb.sv fpga/sim/tb_sdram_burst_arb.sv
git commit -m "feat(sdram): sdram_burst_arb 3-client priority (scan-never-starve)"
```

---

### Task 5: Refresh timer + refresh-vs-burst correctness

**Files:**
- Modify: `fpga/rtl/sdram_burst_arb.sv` (or a tiny `sdram_rfsh_timer` sub-module)
- Test: `fpga/sim/tb_sdram_burst_arb.sv` (add cases)

**Interfaces:**
- Produces: an `rfsh` pulse ~every 64µs (rows/refresh-interval at the SDRAM clock; use `RFSHCNT`/period consistent with jtframe defaults). Drives `jtframe_burst_sdram.rfsh`. Proves refresh runs in burst gaps and never corrupts a live burst.

- [ ] **Step 1: Write the failing test — sustained writes spanning multiple refresh intervals**

Add: run dst write bursts continuously for > 2 refresh periods (shorten the period via a test param/define if needed for sim time), interleaved with scan reads; assert ALL written bands read back correctly AND the run makes progress (no wedge within a watchdog). This is the direct unit-level analog of the `sdram_psx` livelock.

- [ ] **Step 2: Run, verify it fails (or wedges) without the timer wired**

Run: `cd fpga/sim && ./run_sims.sh tb_sdram_burst_arb`
Expected: FAIL/timeout if `rfsh` never fires (no refresh → eventual data issue) — confirming the test exercises refresh.

- [ ] **Step 3: Implement the refresh timer and wire `rfsh`**

Add a counter that pulses `rfsh` at the configured interval (parameter, default = jtframe's). Wire to `jtframe_burst_sdram.rfsh`. jtframe's `_rfsh` defers to live bursts and runs in the gap — no arb-side refresh logic needed.

- [ ] **Step 4: Run, verify it passes**

Run: `cd fpga/sim && ./run_sims.sh tb_sdram_burst_arb`
Expected: `RESULT: PASS` (sustained writes + refresh, all data correct, no wedge).

- [ ] **Step 5: Commit**

```bash
git add fpga/rtl/sdram_burst_arb.sv fpga/sim/tb_sdram_burst_arb.sv
git commit -m "feat(sdram): refresh timer; sustained-write-vs-refresh correctness"
```

---

### Task 6: Integrate into `Solarus.sv`; remove `sdram_psx`/`sdram_src_arb`

**Files:**
- Modify: `fpga/Solarus.sv` (≈lines 419–582: the `sdram_src_arb` + `sdram_psx` block)
- Modify: `fpga/files.qip`
- Delete: `fpga/rtl/sdram_psx.sv`, `fpga/rtl/sdram_src_arb.sv`

**Interfaces:**
- Consumes: `sdram_burst_arb` (client ports identical to old `sdram_src_arb`) + `jtframe_burst_sdram`.
- Produces: a `Solarus.sv` whose SDRAM path is the new controller; `scan_*`/`dst_*`/`p0_*` net names and the SDRAM chip-pin connections preserved.

- [ ] **Step 1: Replace the instantiation**

Swap `sdram_src_arb src_arb (...)` + `sdram_psx #(.BURST_BEATS(1)) sps (...)` for `sdram_burst_arb` (same client nets `rdr_sdram_*`/`dst_*`/`bs_src_*`/`p0_*`) + `jtframe_burst_sdram` (chip pins `SDRAM_*`) + the refresh timer. Keep `assign bs_src_dout64=p0_dout64; assign bs_src_dready=p0_dready;`.

- [ ] **Step 2: Update `files.qip`**

Add `fpga/rtl/jtframe/*.v` and `fpga/rtl/sdram_burst_arb.sv`; remove `sdram_psx.sv`/`sdram_src_arb.sv` lines if present. Then `git rm fpga/rtl/sdram_psx.sv fpga/rtl/sdram_src_arb.sv`.

- [ ] **Step 3: Elaborate the whole core under iverilog**

Run: `cd fpga/sim && iverilog -g2012 -o /tmp/sol_elab.vvp -I ../rtl -I ../rtl/jtframe -I ../sys -y ../rtl -y ../rtl/jtframe -y ../sys -Y .sv -Y .v ../Solarus.sv 2>&1 | head -40`
Expected: no "unknown module"/undeclared-net errors for the SDRAM path. Fix wiring mismatches.

- [ ] **Step 4: Commit**

```bash
git add fpga/Solarus.sv fpga/files.qip
git commit -m "feat(sdram): wire sdram_burst_arb + jtframe_burst into Solarus; drop sdram_psx/src_arb"
```

---

### Task 7: Re-gate the system tests; remove obsolete benches

**Files:**
- Modify: `fpga/sim/run_sims.sh`
- Delete: `fpga/sim/tb_sdram_psx.sv`, `tb_sdram_src_arb.sv`, `tb_sdram_src_arb_beatloss.sv`
- Modify (if they instantiate the removed modules): `tb_sdram_stage.sv`, `tb_scanout_sdram.sv`, `tb_vram_contention.sv`, `tb_sdram_sweep.sv`, `tb_sdram_ctrl.sv`

**Interfaces:**
- Produces: a green gating suite with `tb_vram_contention` re-gated as the SDRAM-FB proof.

- [ ] **Step 1: Point any TB that used `sdram_psx`/`sdram_src_arb` at the new path**

Grep: `grep -rln "sdram_psx\|sdram_src_arb" fpga/sim`. For each, swap to `sdram_burst_arb` + `jtframe_burst_sdram` (or delete if purely a psx/src_arb unit test → covered by `tb_sdram_burst_arb`). `git rm` the three pure-DUT benches above.

- [ ] **Step 2: Re-gate `tb_vram_contention`**

In `run_sims.sh`, set `NONGATING=""` (remove `tb_vram_contention`); drop the deleted benches from `timeout_s`/lists. Remove the "NON-GATING / deferred sdram_psx" note from `tb_vram_contention.sv`'s header (the livelock is fixed by the controller swap).

- [ ] **Step 3: Run the full suite**

Run: `cd fpga/sim && ./run_sims.sh`
Expected: `RESULT: PASS`, gating-failures=0, **including `tb_vram_contention`** (the FB-in-SDRAM compositor now bursts correctly), and `tb_sdram_burst_arb`.

- [ ] **Step 4: Commit**

```bash
git add fpga/sim/run_sims.sh fpga/sim/*.sv
git commit -m "test(sdram): re-gate tb_vram_contention; retire psx/src_arb benches"
```

---

### Task 8: Push, open PR, CI fit/STA (Phase-2 entry)

**Files:** none (CI).

- [ ] **Step 1: Push the branch**

```bash
git push -u origin feat/jtframe-burst-sdram
```

- [ ] **Step 2: Open the PR against master**

```bash
gh pr create --base master --title "Adopt jtframe_burst_sdram controller (fix SDRAM-FB burst-write livelock)" --body "<summary + link to spec; note Phase-2 = on-device validation>"
```
Body ends with the Claude Code generated-with line.

- [ ] **Step 3: Watch CI; confirm fit + STA**

Run: `gh pr checks <N> --watch --interval 60`
Expected: `iverilog`, `lint`, `build-windows` (Quartus fit + STA) all pass. If the Fitter flags `jtframe_burst_io` LOC pragmas, relax/remove them (keep `FAST_OUTPUT_REGISTER`) and re-push. **Do not merge** — on-device validation is the Phase-2 gate (separate, human-driven).

## Self-Review

**Spec coverage:** vendor + provenance (Task 1) = spec §Components.1; `sdram_burst_arb` read/write/priority/packing (Tasks 2–4) = §Components.2 + §Data flow; refresh timer (Task 5) = §Components.3 + Refresh; `prog` tie-off (Task 1 smoke + Task 6) = §Components.4; Solarus integration + module removal (Task 6) = acceptance #1–2; test re-gate (Task 7) = §Testing + acceptance #3; CI fit/STA (Task 8) = acceptance #4. Acceptance #5 (on-device) is Phase-2, explicitly out of this plan. The iverilog-vs-Verilator risk (spec didn't call it out) is handled by Task 1's decision gate.

**Placeholder scan:** no TBD/TODO; commands and module/port names are concrete. HDL bodies are described at logic level (not full Verilog) because exact code depends on jtframe's word-address/`ba` mapping discovered in Task 1 — each such step names the precise signals and behavior, and is gated by a concrete passing test.

**Type consistency:** client port names/widths match `Solarus.sv` (`scan_*`/`dst_*`/`p0_*`, addr[26:0], dout64[63:0], burst[7:0]) and the spec; jtframe consumer port (`addr/ba/rd/wr/din/dout/ack/dst/dok/rdy/rfsh`) matches the doc and `jtframe_burst_sdram.v` header.
