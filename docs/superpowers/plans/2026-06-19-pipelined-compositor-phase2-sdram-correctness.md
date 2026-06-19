# Pipelined Compositor — Phase 2 SDRAM Correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `comp_pipeline`'s SDRAM framebuffer writes/reads and `C_SRCSEL=1` SDRAM sprite-source reads correct under `comp_burst`'s burst `mem_*` protocol, re-enabling every deferred `tb_blitter_system_pipe` phase and closing Quartus synth/STA (G5).

**Architecture:** `comp_burst` already drives the DDR `mem_*` path as a burst master (reads = one `mem_rd`+`burstcnt=N` then N streamed `mem_dout_ready` beats; writes = N per-beat `mem_wr` pulses). This cycle makes `vram_demux` decompose those FB-range bursts onto the single-beat `sdram_psx` controller (reads need a new beat loop; writes need cadence/partial-BE validation), and routes `comp_pipeline`'s source fetch to the existing `sdram_src_arb` P_SRC port via new read-only `src_sdram_*` ports owner-muxed in `blitter_top`. `sdram_psx` stays `BURST_BEATS=1` — this is a correctness cycle, not an SDRAM-throughput cycle.

**Tech Stack:** SystemVerilog (Icarus Verilog `-g2012`, `-y` library mode); `fpga/sim/run_sims.sh` test runner; Quartus Prime 17.0 (via `raetro/quartus:17.0` Docker) for synth/STA.

## Global Constraints

Every task implicitly includes these (verbatim from the spec §6):

- **Bit-exact to the golden** (`patches/mister/blitter/blitter_ref.h`/`.c`); the host/fabric contract (`blt_cmd_t`, opcodes, blend modes, 32-byte ring entry, submit/done handshake) is **frozen** — do not change it.
- The blitter is a **guest**: the video reader keeps default ownership of f2h and **must never starve**; SDRAM access goes through `sdram_src_arb` with reader/scanout priority unchanged.
- **`sdram_psx` stays `BURST_BEATS=1`.** SDRAM-side multi-beat bursts are explicitly out of scope.
- New/changed RTL: `module == file name`, in `fpga/rtl/`; file header `// <file> — <purpose>` + `// Copyright (C) 2026 — GPL-3.0`.
- Worktree commits are safe — commit after every green step. End commit bodies with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` (single trailer; match repo convention).
- Toolchain gotchas (carried from Phase 1/2a): Icarus `-y` single-compilation-unit include-guard interactions; Icarus-13 unsized-integer-in-concatenation casts (use `16'(x)` style); `comp_*` modules have **no reset port** — power-on state via `initial`.

## How to build/run one testbench

The runner builds all `tb_*.sv` via `-y` library mode. To iterate on a single tb (and to pass `-DP2_SDRAM_SYS`, which the default runner does NOT pass):

```bash
cd fpga/sim
# unit tb (no extra define):
./run_sims.sh tb_vram_demux
# system tb WITH the SDRAM-dest/source phases enabled — manual build:
mkdir -p .simbuild
iverilog -g2012 -o .simbuild/tbp.vvp -DP2_SDRAM_SYS \
  -I ../rtl -I ../sys -I . -y ../rtl -y ../sys -y . -Y .sv -Y .v \
  $(ls ./*_stub.sv 2>/dev/null) tb_blitter_system_pipe.sv
vvp .simbuild/tbp.vvp
```

A system pass prints `RESULT: PASS` and each phase's `PHASE..: PASS`; failures print a token in `FAIL|DEADLOCK|STARV|WEDGE|Assertion failed|PROTO:|TIMEOUT` (the runner's `FAIL_RE`), or hang into the `#400000000` timeout (`RESULT: FAIL (timeout/hang)`).

## Diagnosis-first note (read before Tasks 1, 2, 4)

The exact `vram_demux` FSM edits are **root-caused from the failing waveform**, not guessed. For each dest task: enable the failing test, run it, read the actual failure (lost beat / double write / hang / wrong data), then implement the fix preserving the documented invariants (the `FIX A/A'/B` comments at `vram_demux.sv:109-126,226-234,304-310`). The determinate parts (new ports, signal threading, beat-counter registers) are shown in full; the precise cycle where a state advances is confirmed by the unit test you write in step 1.

---

### Task 1: `vram_demux` — N-beat SDRAM read streaming (band LOAD)

`comp_burst` issues an FB read as a single `mem_rd=1` + `mem_burstcnt=N`, then expects **N** `mem_dout_ready` beats (`comp_burst.sv:104-131`, states `S_RDSETUP/S_RDISSUE/S_RDBEATS`). `vram_demux` currently has **no `burstcnt` input** and returns exactly one `sd_dready` per read (`vram_demux.sv:199-215,278-285`). A burst read to an FB address therefore strands `comp_burst` in `S_RDBEATS` waiting for N−1 beats → hang. This task threads `blt_burstcnt` into the demux and loops N single-beat `sdram_psx` reads.

**Files:**
- Modify: `fpga/rtl/vram_demux.sv` (add `blt_burstcnt` input; multi-beat read loop in `S_RDLAT`)
- Modify: `fpga/sim/tb_vram_demux.sv` (new test: burst read of N beats)
- Modify (instantiation sites — add the new port): `fpga/sim/tb_blitter_system_pipe.sv`, `fpga/rtl/Solarus.sv` (or wherever `vram_demux` is instantiated — grep below)

**Interfaces:**
- Consumes: `comp_burst` read protocol — `mem_rd` held until `!mem_busy`, then N beats expected on `mem_dout_ready`/`mem_dout`, `mem_burstcnt=N` valid at issue.
- Produces: `vram_demux` port `input wire [7:0] blt_burstcnt;` — used **only** for FB (SDRAM) reads, where it sets the single-beat SDRAM read-loop count. The demux has no DDR burstcnt port: DDR bursts route separately (blitter `mem_burstcnt` → `ddr_blitter_arb`, around the demux), so non-FB traffic is untouched. Single-beat callers drive `8'd1` (unchanged behavior).

- [ ] **Step 1: Write the failing test** — append to `fpga/sim/tb_vram_demux.sv` a numbered test that drives a 4-beat FB burst read and checks 4 ordered `blt_dout_ready` beats with incrementing SDRAM addresses. Use the file's existing negedge/posedge `sd_busy`/`sd_dready` model convention (documented at `tb_vram_demux.sv:41-66`). Drive `blt_burstcnt=8'd4`, `blt_addr` in the FB0 qword range, `blt_rd=1` held one cycle (mirroring `comp_burst` dropping `mem_rd` after accept). Feed `sd_dready` + `sd_dout64` for 4 successive `sd_rd` pulses; assert exactly 4 `blt_dout_ready` strobes with `sd_addr` advancing by 8 bytes each beat, in order.

```systemverilog
  // ── Test 8: N-beat FB burst read decomposed to N single-beat SDRAM reads ──
  begin
    integer beats_seen; reg [63:0] exp;
    beats_seen = 0;
    @(negedge clk);
    blt_addr   = {3'd0, `FB_DDR0_QW};  // first qword of FB0 (existing tb addr form)
    blt_burstcnt = 8'd4;
    blt_rd     = 1'b1; sd_busy = 1'b0;
    @(posedge clk);                    // demux accepts read, latches burst=4
    blt_rd     = 1'b0;                 // comp_burst drops mem_rd after accept
    // Serve 4 SDRAM beats; each sd_rd pulse answered by one sd_dready next cycle.
    for (i = 0; i < 4; i = i + 1) begin
      // wait for the demux to assert sd_rd for beat i
      while (!sd_rd) @(posedge clk);
      if (sd_addr !== (`SDRAM_FB0_BASE + i*8)) begin
        $display("FAIL: burst-read beat %0d sd_addr=%h exp=%h", i, sd_addr, `SDRAM_FB0_BASE + i*8);
        errs = errs + 1;
      end
      @(negedge clk); sd_dout64 = 64'hA000_0000_0000_0000 | i; sd_dready = 1'b1;
      @(posedge clk);
      if (blt_dready && blt_dout === (64'hA000_0000_0000_0000 | i)) beats_seen = beats_seen + 1;
      @(negedge clk); sd_dready = 1'b0;
    end
    if (beats_seen !== 4) begin $display("FAIL: burst read returned %0d/4 beats", beats_seen); errs = errs + 1; end
    else $display("Test 8 burst-read N=4: PASS");
    wait_idle;
  end
```

- [ ] **Step 2: Run it to confirm it fails** (the unmodified demux ignores `blt_burstcnt`, returns 1 beat then idles → `beats_seen=1`, likely hang on the 2nd `while(!sd_rd)`):

```bash
cd fpga/sim && ./run_sims.sh tb_vram_demux
```
Expected: `tb_vram_demux` FAILs (build error: `blt_burstcnt` not a port yet, or `burst read returned 1/4 beats`).

- [ ] **Step 3: Add the `blt_burstcnt` input and the N-beat read loop to `vram_demux.sv`.** Determinate changes:
  - Port list (after `blt_be`): `input wire [7:0] blt_burstcnt,`
  - New registers near `lane`/`rd_on_sdram`: `reg [7:0] rd_beats_left; reg [26:0] rd_cur_byte;`
  - In `S_IDLE` FB-read branch (`vram_demux.sv:200-203,252-256`): on accept, latch `rd_beats_left <= blt_burstcnt`, `rd_cur_byte <= qw_byte + 27'd8` (next beat), keep `sd_addr=qw_byte` for beat 0, set `rd_on_sdram<=1`, go to `S_RDLAT`.
  - In the combinational SDRAM block (`always @(*)`, `vram_demux.sv:190-239`): in `S_RDLAT`, drive `sd_rd = (rd_beats_left != 0)` and `sd_addr = rd_cur_byte` so each remaining beat issues a fresh single-beat read.
  - In `S_RDLAT` registered (`vram_demux.sv:278-285`): on each `sd_dready`, the beat is forwarded to `blt_dout`/`blt_dout_ready` via the existing `rd_on_sdram` mux (`vram_demux.sv:139-140`). Decrement `rd_beats_left`, advance `rd_cur_byte += 8`. When the **last** beat returns (`rd_beats_left` reaches 0 after the first beat's count), clear `rd_on_sdram` and return to `S_IDLE`.
  - Keep `blt_busy` asserted across the whole multi-beat window (extend the `S_RDLAT` term at `vram_demux.sv:122`) so `comp_burst`'s `S_RDISSUE` (`!mem_busy` gate) and `S_RDBEATS` stay correctly fed. **Invariant:** exactly `blt_burstcnt` `blt_dout_ready` strobes, in address order, one `sdram_psx` read each.

  *The exact beat-0-vs-remaining bookkeeping (whether beat 0 counts in `rd_beats_left`) is settled by making Step-1's `beats_seen==4` and the address sequence pass.*

- [ ] **Step 4: Thread the new port through every `vram_demux` instantiation.** Find them and add `.blt_burstcnt(...)`:

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister/.claude/worktrees/pipelined-compositor
grep -rn "vram_demux" fpga/rtl fpga/sim | grep -v "\.git"
```
  - `tb_vram_demux.sv`: declare `reg [7:0] blt_burstcnt;` (default `8'd1` in the init block) and add `.blt_burstcnt(blt_burstcnt)`.
  - `tb_blitter_system_pipe.sv` (`vdemux` instance, ~line 70): add `.blt_burstcnt(bt_burstcnt)` where `bt_burstcnt` is `blitter_top`'s `mem_burstcnt` output (`blitter_top.sv:45`). Declare/wire `bt_burstcnt` if not already.
  - `Solarus.sv` (production demux instance): add `.blt_burstcnt(<blitter mem_burstcnt net>)`.

- [ ] **Step 5: Run the unit test — verify it passes**

```bash
cd fpga/sim && ./run_sims.sh tb_vram_demux
```
Expected: `Test 8 burst-read N=4: PASS` and `tb_vram_demux ... PASS`.

- [ ] **Step 6: Confirm no build/regression breakage from the new port**

```bash
cd fpga/sim && ./run_sims.sh
```
Expected: every previously-passing tb still PASS (the new port defaults to `8'd1` everywhere = old single-beat behavior).

- [ ] **Step 7: Commit**

```bash
git add fpga/rtl/vram_demux.sv fpga/sim/tb_vram_demux.sv fpga/sim/tb_blitter_system_pipe.sv fpga/rtl/Solarus.sv
git commit -m "fix(demux): decompose N-beat FB burst reads to single-beat sdram_psx

vram_demux gains blt_burstcnt; FB reads loop N single-beat SDRAM reads
streaming N blt_dout_ready beats so comp_burst's S_RDBEATS is fed.
Non-FB reads pass burstcnt to DDR unchanged; single-beat callers (8'd1)
unaffected.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `vram_demux` — full-qword write burst cadence

`comp_burst` writes are **N per-beat `mem_wr` pulses** (`comp_burst.sv:138-179`: `S_WRLOAD→S_WRARM→S_WRWAIT` loops once per beat, `mem_addr` incrementing, `mem_wr=1` per beat, advances on `!mem_busy`). The demux services one full-qword write per `S_IDLE`→`S_BWAIT`→`S_IDLE` (`vram_demux.sv:204-206,226-234,304-310`), with `blt_busy` in `S_BWAIT` following `sd_busy`. This task verifies/fixes that consecutive full-qword write beats each land exactly once with no lost/double beat as `sd_busy` toggles.

**Files:**
- Modify: `fpga/sim/tb_vram_demux.sv` (new test: back-to-back full-qword writes)
- Modify (only if the test exposes a desync): `fpga/rtl/vram_demux.sv`

**Interfaces:**
- Consumes: `comp_burst` write cadence — each beat: `mem_wr=1` + `mem_addr=cur_addr` (incrementing by 1 qword), held until the demux drops `mem_busy`(=`blt_busy`), then `comp_burst` fires `wr_take` and advances.
- Produces: no new ports. Behavioral guarantee: K consecutive full-qword (`blt_be=8'hFF`) write beats → exactly K `sd_we_burst & ~sd_busy` accepts, addresses in order.

- [ ] **Step 1: Write the failing/characterizing test** — append a test driving 3 consecutive full-qword writes (`blt_be=8'hFF`) at qword addresses `base, base+1, base+2`, each beat presented `mem_wr`-style (assert `blt_wr=1` + new `blt_addr`, hold until `blt_busy` drops, then advance), with `sd_busy` toggled high for one cycle mid-sequence. Assert the existing `burst_count` (`tb_vram_demux.sv:80-88`, increments on `sd_we_burst & ~sd_busy`) reaches exactly 3 and the captured `sd_addr` sequence is `base*8, (base+1)*8, (base+2)*8`.

```systemverilog
  // ── Test 9: back-to-back full-qword write beats (comp_burst cadence) ──
  begin
    integer wb; reg [26:0] seen_addr [0:2]; integer si;
    burst_count = 0; si = 0;
    for (wb = 0; wb < 3; wb = wb + 1) begin
      @(negedge clk);
      blt_addr = {3'd0, `FB_DDR0_QW} + wb; // consecutive FB qwords
      blt_din  = 64'hC0DE_0000_0000_0000 | wb;
      blt_be   = 8'hFF; blt_wr = 1'b1;
      sd_busy  = (wb == 1);              // stall the middle beat one cycle
      @(posedge clk);
      if (sd_busy) begin @(negedge clk); sd_busy = 1'b0; @(posedge clk); end
      // hold blt_wr until blt_busy drops (the arbiter-accept), then deassert
      while (blt_busy) @(posedge clk);
      if (sd_we_burst) seen_addr[si] = sd_addr;  // capture (best-effort; comb)
      @(negedge clk); blt_wr = 1'b0;
      @(posedge clk);
    end
    if (burst_count !== 3) begin $display("FAIL: %0d/3 full-qword bursts landed", burst_count); errs = errs + 1; end
    else $display("Test 9 burst-write cadence: PASS");
    wait_idle;
  end
```

- [ ] **Step 2: Run it and read the result**

```bash
cd fpga/sim && ./run_sims.sh tb_vram_demux
```
Expected: either `Test 9 ... PASS` (cadence already correct against `comp_burst` — likely, since `S_BWAIT` already follows `sd_busy` per FIX A) or a concrete `N/3` desync to fix in Step 3.

- [ ] **Step 3: If (and only if) Step 2 failed, fix the cadence in `vram_demux.sv`.** Preserve the FIX A invariant (`vram_demux.sv:226-234,304-310`): `S_BWAIT` exits on `!sd_busy` (the accept), not `!blt_wr`. The likely desync is the one-cycle `S_BWAIT→S_IDLE` turnaround vs `comp_burst`'s `S_WRWAIT→S_WRLOAD→S_WRARM→S_WRWAIT` (≥3 cycles/beat), so a lost beat is unlikely but a **double-accept** on a held `blt_wr` is the risk — guard that `sd_we_burst` only re-asserts for a genuinely new beat (new `blt_addr`/`blt_wr` edge), not a stale hold. If Step 2 passed, record "no fix needed — cadence correct" in the report and skip to Step 4.

- [ ] **Step 4: Run the unit test — verify pass**

```bash
cd fpga/sim && ./run_sims.sh tb_vram_demux
```
Expected: `Test 9 burst-write cadence: PASS`.

- [ ] **Step 5: Commit**

```bash
git add fpga/sim/tb_vram_demux.sv fpga/rtl/vram_demux.sv
git commit -m "test(demux): full-qword write-beat cadence vs comp_burst (+fix if needed)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: System gate — PHASE1-pipe + PHASE2A green via SDRAM-dest

With read-burst (Task 1) and write cadence (Task 2) correct, the `C_PIPE=1` FILL through the SDRAM-dest path should composite end-to-end. PHASE1-pipe (`64×48` FILL at `(128,96)`, qword-aligned) and PHASE2A (`4×32` tall, two band-chunks, qword-aligned) exercise read-burst band-LOAD + full-qword write-burst FLUSH with **no** partial-BE. The test code already exists behind `-DP2_SDRAM_SYS` (`tb_blitter_system_pipe.sv:212-213,385-405`).

**Files:**
- Test only: `fpga/sim/tb_blitter_system_pipe.sv` (build with `-DP2_SDRAM_SYS`; no source edits expected)

**Interfaces:**
- Consumes: Tasks 1+2 (`vram_demux` burst read + write cadence).
- Produces: PHASE1 `phase1_ok=1` under `C_PIPE=1`, `PHASE2A ... PASS`.

- [ ] **Step 1: Run the system tb with the define — observe current state**

```bash
cd fpga/sim && mkdir -p .simbuild
iverilog -g2012 -o .simbuild/tbp.vvp -DP2_SDRAM_SYS \
  -I ../rtl -I ../sys -I . -y ../rtl -y ../sys -y . -Y .sv -Y .v \
  $(ls ./*_stub.sv 2>/dev/null) tb_blitter_system_pipe.sv && vvp .simbuild/tbp.vvp
```
Expected: PHASE1 prints, PHASE2A prints, and `RESULT: PASS` if Tasks 1-2 fully closed the path. If a phase FAILs or it hangs, capture the failing pixel(s) and `SPROBE` the write/flush stream.

- [ ] **Step 2: If a phase fails, root-cause with the in-tb probe.** Rebuild adding `-DSPROBE` (`tb_blitter_system_pipe.sv:233-238` dumps `FL`/`PWR` flush+write beats). Trace whether the wrong pixel is a band-LOAD read miss (Task 1 boundary) or a FLUSH write miss (Task 2 boundary), and fix in the owning task's module. Re-run until `PHASE2A (tall-fill chunk): PASS`.

- [ ] **Step 3: Verify both phases pass**

```bash
cd fpga/sim && vvp .simbuild/tbp.vvp | grep -E "PHASE1|PHASE2A|RESULT"
```
Expected: `PHASE1 (FILL/reader): PASS`, `PHASE2A (tall-fill chunk): PASS`. (PHASE2B may still FAIL — that's Task 4.)

- [ ] **Step 4: Commit** (report-only if no RTL changed; include any fix)

```bash
git add -A
git commit -m "test(system): C_PIPE=1 PHASE1-pipe + PHASE2A green through SDRAM-dest

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: `vram_demux` — partial-BE writes under burst (PHASE2B)

PHASE2B's overlapping blue FILL at `x=6` spans two qwords partially (`blt_be ≠ 8'hFF`), driving the `S_WLANES` 16-bit-word serialization loop (`vram_demux.sv:217-224,287-297`) under `sd_busy` backpressure — now sourced by `comp_burst` per-beat writes rather than the legacy FSM. This task validates/fixes the serialized partial write in the burst cadence and greens PHASE2B.

**Files:**
- Modify: `fpga/sim/tb_vram_demux.sv` (partial-BE write under a burst-style hold)
- Modify (if exposed): `fpga/rtl/vram_demux.sv`
- Test: `fpga/sim/tb_blitter_system_pipe.sv` PHASE2B (already behind the define)

**Interfaces:**
- Consumes: Tasks 1-3.
- Produces: a partial-BE write (`blt_be` with a qword-spanning lane pattern) emits one `sd_we` per active lane, correct addresses, `blt_busy` held across the whole `S_WLANES` walk; PHASE2B PASS.

- [ ] **Step 1: Write the failing test** — append a partial-BE write test with `blt_be=8'b0011_1100` (lanes 1+2 active, lanes 0+3 idle — the qword-spanning pattern PHASE2B produces) at an FB qword, with `sd_busy` asserted high for one cycle during the lane walk. Use the existing `we_count` counter (`tb_vram_demux.sv:34-35`, increments per `sd_we`). Assert exactly 2 `sd_we` pulses, at `sd_addr = base + 2` and `base + 4` (lane*2-byte offsets, `vram_demux.sv:209,220`), and `blt_busy` held high continuously from first lane to `S_WWAIT`.

```systemverilog
  // ── Test 10: partial-BE serialized write under sd_busy hold ──
  begin
    integer we0;
    we0 = we_count;
    @(negedge clk);
    blt_addr = {3'd0, `FB_DDR0_QW};
    blt_din  = 64'h1111_2222_3333_4444;
    blt_be   = 8'b0011_1100;   // lanes 1 (bytes 3:2) + 2 (bytes 5:4)
    blt_wr   = 1'b1; sd_busy = 1'b0;
    @(posedge clk);            // S_IDLE emits lane 1, goes to S_WLANES
    sd_busy = 1'b1; @(posedge clk);   // stall mid-walk
    if (!blt_busy) begin $display("FAIL: blt_busy dropped during S_WLANES stall"); errs = errs + 1; end
    @(negedge clk); sd_busy = 1'b0;
    while (blt_busy) @(posedge clk);   // walk completes -> S_WWAIT -> idle
    @(negedge clk); blt_wr = 1'b0; @(posedge clk);
    if ((we_count - we0) !== 2) begin $display("FAIL: partial-BE wrote %0d lanes (exp 2)", we_count - we0); errs = errs + 1; end
    else $display("Test 10 partial-BE under burst: PASS");
    wait_idle;
  end
```

- [ ] **Step 2: Run it and read the result**

```bash
cd fpga/sim && ./run_sims.sh tb_vram_demux
```
Expected: `Test 10 ... PASS` (the Task 2b 3-bit-`start` fix already hardened `first_enabled_lane`, `vram_demux.sv:146-168`) or a concrete lane-count/`blt_busy`-drop failure to fix.

- [ ] **Step 3: If Step 2 failed, fix the `S_WLANES` walk** preserving the lane priority-encoder invariants (`vram_demux.sv:142-185`) and the `S_WLANES` `blt_busy` hold (`vram_demux.sv:123`). Otherwise record "no fix needed" and proceed.

- [ ] **Step 4: Run the system PHASE2B**

```bash
cd fpga/sim && vvp .simbuild/tbp.vvp | grep -E "PHASE2B|PHASE2 |RESULT"
```
Expected: `PHASE2B (multi-cmd painter): PASS`, `PHASE2 (DDR-source FILL): PASS`. (Rebuild with the Task-3 `-DP2_SDRAM_SYS` command first if `.simbuild/tbp.vvp` is stale.)

- [ ] **Step 5: Run the full unit suite (no regression)**

```bash
cd fpga/sim && ./run_sims.sh
```
Expected: all gating tbs PASS.

- [ ] **Step 6: Commit**

```bash
git add fpga/sim/tb_vram_demux.sv fpga/rtl/vram_demux.sv
git commit -m "fix(demux): partial-BE serialized SDRAM write under burst cadence; PHASE2B green

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: `comp_pipeline` — SDRAM-source fetch (`C_SRCSEL=1`)

The SDRAM sprite atlas is **not** in the FB range, so it cannot reach SDRAM through `vram_demux` (FB-only) — it needs the `sdram_src_arb` P_SRC port. `comp_pipeline` currently fetches the source row via `comp_burst`/`mem_*` (DDR) in `P_SRCFILL` (`comp_pipeline.sv:244-245`, addressing at `:446-470`). This task adds read-only `src_sdram_*` ports and routes `P_SRCFILL` to them when `C_SRCSEL=1`.

**Files:**
- Modify: `fpga/rtl/comp_pipeline.sv` (add `c_srcsel` input + `src_sdram_*` read ports; route `P_SRCFILL`)
- Modify: `fpga/sim/tb_comp_pipeline.sv` (behavioral SDRAM-source model + a `C_SRCSEL=1` COPY test)

**Interfaces:**
- Consumes: `c_srcsel` (the command's `C_SRCSEL` bit, already latched in `blitter_top`); the same `c_src_off/c_src_stride/c_src_x/c_src_y` source addressing already in `comp_pipeline`.
- Produces (new `comp_pipeline` ports, read-only, mirror of `blitter_top.sv:57-61`):
  - `input wire c_srcsel,`
  - `output reg [26:0] src_sdram_addr,` (qword-aligned byte address)
  - `output reg src_sdram_rd,` (held until granted)
  - `input wire [63:0] src_sdram_dout64,`
  - `input wire src_sdram_dout_ready,`
  - `input wire src_sdram_busy,`

- [ ] **Step 1: Write the failing test** — in `fpga/sim/tb_comp_pipeline.sv`, add a behavioral SDRAM-source responder (on `src_sdram_rd & !src_sdram_busy`, return `src_sdram_dout64` = a known sprite qword after a fixed latency, pulse `src_sdram_dout_ready`) and a test that runs a small COPY blit with `c_srcsel=1`, source seeded so the composited destination equals a known pattern. Assert the dest band matches the golden COPY result. (Model `src_sdram_busy` low; one beat per `rd`.) Drive `c_srcsel=1` and the source ports; leave the existing DDR `mem_*` model in place for band LOAD/FLUSH.

```systemverilog
  // ── SDRAM-source COPY: c_srcsel=1 routes P_SRCFILL to src_sdram_* ──
  // Behavioral P_SRC responder: one 64-bit beat per held src_sdram_rd.
  reg [63:0] srcmem [0:1023];
  always @(posedge clk) begin
    src_sdram_dout_ready <= 1'b0;
    if (src_sdram_rd && !src_sdram_busy) begin
      src_sdram_dout64     <= srcmem[src_sdram_addr[12:3]];  // qword-indexed
      src_sdram_dout_ready <= 1'b1;
    end
  end
  // ... seed srcmem with a 4px sprite row, run a COPY (c_srcsel=1), check dest.
```

- [ ] **Step 2: Run it to confirm it fails** (ports/`c_srcsel` don't exist yet → build error; or COPY reads zeros from DDR → wrong dest):

```bash
cd fpga/sim && ./run_sims.sh tb_comp_pipeline
```
Expected: FAIL (build error on `src_sdram_*`/`c_srcsel`, or dest mismatch).

- [ ] **Step 3: Add the ports + routing to `comp_pipeline.sv`.** Determinate:
  - Add the six ports above to the module header.
  - In `P_SRCFILL_ISS/WAIT` (`comp_pipeline.sv:244-245` states; the COPY source-fill issue site), branch on `c_srcsel`: when `0`, keep the existing `cb_req`/`comp_burst` DDR fetch; when `1`, drive `src_sdram_rd<=1` with `src_sdram_addr = {src_qw_byte[26:3],3'b000}` (qword-aligned, derived from the same `fill_qw`/`gpix` source address already computed at `:446-470`), hold until `!src_sdram_busy`, capture `src_sdram_dout64` on `src_sdram_dout_ready` into the linebuf via the existing `db_ld_we/db_ld_qw/db_ld_idx` path (`comp_pipeline.sv:119-121,138`).
  - **HFLIP stays applied exactly once** (the existing `serve_x` cursor / `gpix ± k`); do not add a second flip in the SDRAM fetch.
  - **Invariant:** for `c_srcsel=0` the source path is byte-identical to today (DDR via `comp_burst`) — the four `C_PIPE=1` equivalence variants must stay bit-exact.

- [ ] **Step 4: Run the test — verify pass**

```bash
cd fpga/sim && ./run_sims.sh tb_comp_pipeline
```
Expected: the new SDRAM-source COPY test PASSes; existing `tb_comp_pipeline` checks still PASS.

- [ ] **Step 5: Commit**

```bash
git add fpga/rtl/comp_pipeline.sv fpga/sim/tb_comp_pipeline.sv
git commit -m "feat(comp): SDRAM-source (C_SRCSEL=1) fetch via read-only src_sdram_* ports

P_SRCFILL routes to src_sdram_* when c_srcsel=1 (sprite atlas lives outside
the FB range -> sdram_src_arb P_SRC, not vram_demux). c_srcsel=0 DDR path
byte-identical; HFLIP still applied once.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: `blitter_top` — source owner mux

`blitter_top` owns `src_sdram_*` as `output reg`s driven by the legacy FSM (`blitter_top.sv:57-75,313-321,490-514`) and instantiates `u_pipe` with a `pipe_busy` owner mux for `mem_*` (`blitter_top.sv:744-774`). This task muxes the source-read ports between the legacy FSM and `u_pipe`, mirroring the `mem_*` mux, and wires `c_srcsel` into `u_pipe`.

**Files:**
- Modify: `fpga/rtl/blitter_top.sv` (mux `src_sdram_rd`/`src_sdram_addr`; route read-data back; pass `c_srcsel` to `u_pipe`)

**Interfaces:**
- Consumes: Task 5 `comp_pipeline` source ports (`p_src_sdram_addr`, `p_src_sdram_rd`, and `src_sdram_dout64/_ready/_busy` inputs).
- Produces: `blitter_top` `src_sdram_addr`/`src_sdram_rd` = `pipe_busy ? p_src_sdram_* : <legacy FSM value>`; the write-side `src_sdram_we/we_burst/din/waddr/din64` stay legacy-only (the pipe never stages).

- [ ] **Step 1: Write the failing test** — extend `fpga/sim/tb_blitter_system_pipe.sv` (or a focused `tb_blitter_copy_pipe` variant) to run a `C_PIPE=1, C_SRCSEL=1` COPY and confirm `u_pipe` drives the system `src_sdram_*` while `pipe_busy=1` (probe `blt.u_pipe.src_sdram_rd` reaching `src_arb` P_SRC). Initially the unmuxed `blitter_top` leaves `src_sdram_rd` driven only by the legacy FSM (idle during a pipe blit) → the COPY reads nothing → dest mismatch.

- [ ] **Step 2: Run it to confirm failure**

```bash
cd fpga/sim && mkdir -p .simbuild
iverilog -g2012 -o .simbuild/tbp.vvp -DP2_SDRAM_SYS \
  -I ../rtl -I ../sys -I . -y ../rtl -y ../sys -y . -Y .sv -Y .v \
  $(ls ./*_stub.sv 2>/dev/null) tb_blitter_system_pipe.sv && vvp .simbuild/tbp.vvp
```
Expected: the `C_SRCSEL=1` COPY dest is wrong / source never read (legacy FSM idle while `pipe_busy`).

- [ ] **Step 3: Add the source owner mux to `blitter_top.sv`.** Determinate, mirroring `:760-766`:
  - Convert the legacy `src_sdram_addr`/`src_sdram_rd` reg drives into internal `l_src_sdram_addr`/`l_src_sdram_rd` (legacy), and add `wire p_src_sdram_rd; wire [26:0] p_src_sdram_addr;` from `u_pipe`.
  - `assign src_sdram_addr = pipe_busy ? p_src_sdram_addr : l_src_sdram_addr;`
  - `assign src_sdram_rd   = pipe_busy ? p_src_sdram_rd   : l_src_sdram_rd;`
  - Route the inputs `src_sdram_dout64/_dout_ready/_busy` into `u_pipe` (they fan to both owners; only the active one consumes).
  - Add `.c_srcsel(srcsel)` (the latched `C_SRCSEL` bit, `blitter_top.sv:313`) and the `.src_sdram_*` connections to the `u_pipe` instantiation (`:744-758`).
  - Leave `src_sdram_we/we_burst/din/waddr/din64` driven solely by the legacy FSM (STAGE path).

- [ ] **Step 4: Run — verify the C_SRCSEL=1 COPY now reads source and composites**

```bash
cd fpga/sim && vvp .simbuild/tbp.vvp | grep -E "PHASE|RESULT"
```
Expected: the COPY dest matches; no regression in PHASE1/2A/2B.

- [ ] **Step 5: Confirm legacy + equivalence regression**

```bash
cd fpga/sim && ./run_sims.sh
```
Expected: `tb_blitter_{copy,blend,coalesce,palpha}_pipe` bit-exact, legacy `C_PIPE=0` suite unchanged.

- [ ] **Step 6: Commit**

```bash
git add fpga/rtl/blitter_top.sv fpga/sim/tb_blitter_system_pipe.sv
git commit -m "feat(blitter): owner-mux src_sdram_* between legacy FSM and comp_pipeline

pipe_busy gates src_sdram_rd/addr to u_pipe (read-only); c_srcsel threaded
in; write/STAGE path stays legacy-only. Mirrors the mem_* owner mux.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: System gate — PHASE3 + PHASE4 (write the tests + green)

PHASE3 (per-command source mux) and PHASE4 (carry-forward FB1→FB0) are currently `$display "DEFERRED"` stubs (`tb_blitter_system_pipe.sv:443-448`) — the test code must be **written**. They need an SDRAM-source sprite seeded (helpers `seed_sd_px`/`sdram_fb*_px` exist at `:150-167`) and `C_PIPE=1, C_SRCSEL=1` COPY/blit commands.

**Files:**
- Modify: `fpga/sim/tb_blitter_system_pipe.sv` (replace the PHASE3/4 stubs with real tests under `-DP2_SDRAM_SYS`)

**Interfaces:**
- Consumes: Tasks 5+6 (SDRAM-source through the full system).
- Produces: `PHASE3 ... PASS`, `PHASE4 ... PASS`, folded into the final `RESULT: PASS` verdict (extend the `:450` condition to include `p3_errs==0 && p4_errs==0`).

- [ ] **Step 1: Write PHASE3** — seed an SDRAM-source sprite (e.g. a 4×4 patterned tile via `seed_sd_px` into a source region), submit a `C_PIPE=1, C_SRCSEL=1` COPY into FB0, and a second command with `C_SRCSEL=0` FILL in the same submit; assert the COPY pixels equal the seeded sprite and the FILL pixels equal the fill colour — proving the per-command source mux selects SDRAM-source only for the COPY. Add a `run_pipe_copy(...)` helper alongside `run_pipe_fill` (`:266-295`). Add `integer p3_errs=0;` and per-pixel checks like the PHASE2 blocks.

- [ ] **Step 2: Run PHASE3, root-cause to green**

```bash
cd fpga/sim && iverilog -g2012 -o .simbuild/tbp.vvp -DP2_SDRAM_SYS \
  -I ../rtl -I ../sys -I . -y ../rtl -y ../sys -y . -Y .sv -Y .v \
  $(ls ./*_stub.sv 2>/dev/null) tb_blitter_system_pipe.sv && vvp .simbuild/tbp.vvp | grep -E "PHASE3|RESULT"
```
Expected: iterate to `PHASE3 (per-cmd mux): PASS`.

- [ ] **Step 3: Write PHASE4** — carry-forward: COPY from SDRAM FB1 (seed `SDRAM_FB1_BASE` via `seed_sd_px`) into FB0 with `C_SRCSEL=1`, source addressed at the FB1 base, assert FB0 receives FB1's content (the painter round-trip across buffers). Add `integer p4_errs=0;` + checks.

- [ ] **Step 4: Run PHASE4 to green + extend the final verdict**

Change the verdict line (`tb_blitter_system_pipe.sv:450`) to:
```systemverilog
    if (phase1_ok && p2_errs==0 && p3_errs==0 && p4_errs==0) $display("RESULT: PASS");
```
Run:
```bash
cd fpga/sim && iverilog -g2012 -o .simbuild/tbp.vvp -DP2_SDRAM_SYS \
  -I ../rtl -I ../sys -I . -y ../rtl -y ../sys -y . -Y .sv -Y .v \
  $(ls ./*_stub.sv 2>/dev/null) tb_blitter_system_pipe.sv && vvp .simbuild/tbp.vvp | grep -E "PHASE|RESULT"
```
Expected: PHASE1/2A/2B/3/4 all PASS, `RESULT: PASS`.

- [ ] **Step 5: Commit**

```bash
git add fpga/sim/tb_blitter_system_pipe.sv
git commit -m "test(system): PHASE3 per-cmd source mux + PHASE4 carry-forward (C_SRCSEL=1) green

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: Gate the suite on `-DP2_SDRAM_SYS`

The default `run_sims.sh` builds `tb_blitter_system_pipe` **without** the define (passing on DEFERRED stubs). Now that all phases are green, make the suite gate on the real phases so a regression is caught.

**Files:**
- Modify: `fpga/sim/run_sims.sh` (build `tb_blitter_system_pipe` with `-DP2_SDRAM_SYS`)

**Interfaces:**
- Consumes: Tasks 1-7.
- Produces: `run_sims.sh` includes `-DP2_SDRAM_SYS` for that one tb (a per-tb define hook), default suite gates on the SDRAM phases.

- [ ] **Step 1: Add a per-tb define hook to the build line** (`run_sims.sh:70-77`). Add near the `pass_re`/`timeout_s` helpers:

```bash
# Per-TB extra defines (default none).
defines_for() { case "$1" in
  tb_blitter_system_pipe) echo '-DP2_SDRAM_SYS' ;;
  *)                      echo '' ;;
esac; }
```
and inject `$(defines_for "$top")` into the `iverilog` invocation (`:70`).

- [ ] **Step 2: Run the whole suite — verify green with the phases gated**

```bash
cd fpga/sim && ./run_sims.sh
```
Expected: `tb_blitter_system_pipe ... PASS` (now running PHASE1-pipe/2A/2B/3/4), all other gating tbs PASS, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add fpga/sim/run_sims.sh
git commit -m "test(runner): gate tb_blitter_system_pipe on -DP2_SDRAM_SYS (SDRAM phases live)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 9: G5 — Quartus synthesis + STA

Synth the combined RTL (Phase-2a burst + this cycle's dest/source changes) and close timing. Quartus is **not** on the local PATH — it runs via `fpga/build_solarus.sh` (Quartus Prime 17.0; CI uses `raetro/quartus:17.0` Docker, abs path `/opt/intelFPGA/quartus/bin`). `comp_*` + `comp_burst` + `sdram_src_arb` are already in `fpga/files.qip:13-20`; verify the new `vram_demux` port and `blitter_top` mux carry through.

**Files:**
- Verify/Modify: `fpga/files.qip` (confirm all touched files listed), `fpga/Solarus.sdc` / `fpga/sys/sys_top.sdc` (f2h clock constraint), `fpga/build_solarus.sh` (invocation)

**Interfaces:**
- Consumes: Tasks 1-8 (final RTL).
- Produces: a Quartus compile log with **Worst-case setup slack ≥ 0** at the f2h clock, and confirmation that `comp_defs.vh` (`COMP_DIV255`, `COMP_BAND_H`, `COMP_MAXBURST`) resolves authoritatively under Quartus.

- [ ] **Step 1: Confirm the synth filelist covers all touched RTL**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister/.claude/worktrees/pipelined-compositor
grep -E "vram_demux|blitter_top|comp_pipeline|comp_burst|sdram_src_arb|sdram_psx" fpga/files.qip fpga/Solarus.qsf
```
Expected: every modified module appears (add any missing `set_global_assignment -name SYSTEMVERILOG_FILE rtl/<file>`).

- [ ] **Step 2: Run synth + STA via the build script** (in the Quartus environment — Docker if no local Quartus):

```bash
# Local Quartus 17.0 on PATH:
cd fpga && ./build_solarus.sh
# OR containerized (no local Quartus):
docker run --rm -v "$PWD":/work -w /work/fpga raetro/quartus:17.0 bash build_solarus.sh
```
Expected: compile completes; the script greps and prints `Worst-case setup slack` (`build_solarus.sh:55-60`).

- [ ] **Step 3: Verify the timing gate**

```bash
grep -E "Timing requirements not met|Worst-case setup slack" fpga/build_*.log | tail
```
Expected: **Worst-case setup slack ≥ 0** at the f2h clock, no "Timing requirements not met". If negative, apply the carried fallback levers in order: pipeline only `comp_mixer`, then shrink `COMP_BAND_H` (BRAM relief) — re-synth and re-check. Confirm the new `vram_demux` read-loop / `blitter_top` source mux is not the critical path node.

- [ ] **Step 4: Verify `comp_defs.vh` authority under Quartus** — grep the synthesis report for the resolved parameter values (or add a synth-time `$info`/assertion) to confirm Quartus used `comp_defs.vh`'s `COMP_BAND_H`/`COMP_MAXBURST`/`COMP_DIV255`, not an `ifndef` fallback. If confirmed clean, optionally tighten `comp_dest_band`'s `` `ifndef `` fallback to `` `error `` (spec §5 / §7).

- [ ] **Step 5: Commit the synth evidence + any timing fix**

```bash
git add fpga/files.qip fpga/Solarus.sdc fpga/rtl/comp_dest_band.sv docs/superpowers/
git commit -m "synth: G5 — Quartus 17.0 STA setup slack >= 0 with SDRAM-correctness RTL

comp_defs.vh authority confirmed under Quartus; combined burst + SDRAM
dest/source RTL closes timing at the f2h clock.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Definition of done (cycle exit)

- `./run_sims.sh` green with `tb_blitter_system_pipe` gated on `-DP2_SDRAM_SYS`: **PHASE1-pipe / 2A / 2B / 3 / 4 PASS**, `RESULT: PASS`.
- Four `C_PIPE=1` equivalence variants bit-exact; `tb_comp_pipeline` green; legacy `C_PIPE=0` suite no regression.
- New unit coverage: `tb_vram_demux` burst-read (Test 8), write cadence (Test 9), partial-BE under burst (Test 10); `tb_comp_pipeline` `C_SRCSEL=1` COPY.
- **G5:** Quartus STA worst-case setup slack ≥ 0 at the f2h clock; `comp_defs.vh` authoritative.
- HW (G2) and SDRAM-side burst throughput remain out of scope.
