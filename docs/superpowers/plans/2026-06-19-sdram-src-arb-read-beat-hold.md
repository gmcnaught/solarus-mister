# sdram_src_arb Read-Beat Hold Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the `S_SRC_SDRAM_WAIT` HW wedge by making `sdram_src_arb` hold a granted READ's owner until its data beat (`c_dready`) is delivered, not just until `c_ready`.

**Architecture:** Add `rd_held` (this transaction is a read) and `beat_seen` (its beat arrived) to `sdram_src_arb`; release `held_txn` for reads only once the beat is delivered, for writes on `c_ready` as today. Keyed on `rd_held`, this hardens all three read clients (P_SRC/P_DST/P_SCAN). Validated by a new directed sim that separates `c_ready` from `c_dready` with a SCAN preemptor (the faithful full-system sims align the two strobes and never reproduce it).

**Tech Stack:** SystemVerilog (`fpga/rtl/sdram_src_arb.sv`), iverilog sim suite (`fpga/sim/run_sims.sh`, auto-discovers `tb_*.sv`), GitHub Actions `build-rbf.yml` (windows), busybox `devmem` HW probe on 192.168.20.81.

## Global Constraints

- Branch: `feature-sdram-64mb-geometry`. Base for PR: `master`.
- Done-bar (user choice): directed-sim **repro→green** is the PRIMARY gate; then full suite stays green; then an **HW relaunch-soak** with the probe core (several relaunches clean, probe `0x3A070004` never `0xFF01481F`).
- ONLY `fpga/rtl/sdram_src_arb.sv` changes in RTL. No `blitter_top.sv` / `vram_demux.sv` / `Solarus.sv` / wiring / TB-port changes.
- The fix must NOT regress writes: `rd_held=0` keeps the exact current write-release timing. Confirm via `tb_blitter_system` (write coalescing) + `tb_sdram_src_arb`.
- Probe stays in the core for the HW check (do not strip; strip at #34 close).
- Out of scope: the write-behind-write S_BWAIT / S_WR_WAIT per-write accept handshake (tracked in the spec; only manifests under +1 read-latency we are not adding).
- Commit messages end with the repo's required trailers (Co-Authored-By + Claude-Session).
- Arbiter owner encoding: 0=none, 1=SCAN, 2=SRC, 3=DST. `p0_dready = c_dready & (owner==2)`; `p0_busy = (owner!=2)|c_busy`.

---

### Task 1: RED directed sim — reproduce the source-read beat-loss

Create a focused `sdram_src_arb` unit test where the controller asserts `c_ready`
before the read's `c_dready` beat, with a SCAN client that preempts the instant the
(buggy) arbiter releases the owner. The P_SRC client mirrors `blitter_top`
`S_SRC_SDRAM_WAIT` (drops `p0_rd` on `!p0_busy`, waits for `p0_dready`). Must FAIL on
current RTL.

**Files:**
- Create: `fpga/sim/tb_sdram_src_arb_beatloss.sv`

**Interfaces:**
- Consumes: `sdram_src_arb` (current ports, see `fpga/rtl/sdram_src_arb.sv:17-70`).
- Produces: a self-checking TB printing `RESULT: PASS` / `RESULT: FAIL` (run_sims default verdict).

- [ ] **Step 1: Write the RED testbench**

Create `fpga/sim/tb_sdram_src_arb_beatloss.sv` with exactly this content:

```systemverilog
`timescale 1ns/1ps
`default_nettype none
// tb_sdram_src_arb_beatloss.sv — #34 directed repro of the S_SRC_SDRAM_WAIT wedge.
//
// The controller stub asserts c_ready=1 / c_busy=0 ALWAYS (ready for the next
// command) but delivers the SRC read's data beat (c_dready) GAP cycles LATER — the
// HW separation the faithful sdram_psx sim never shows. A SCAN client requests the
// instant the SRC read is granted, so a buggy arbiter (releases owner on c_ready)
// hands the bus to SCAN before the SRC beat arrives -> p0_dready is masked off
// (owner!=2) -> the SRC beat is lost -> the P_SRC client (mirroring blitter
// S_SRC_SDRAM_WAIT) starves. PASS requires the P_SRC client to receive its beat.
module tb_sdram_src_arb_beatloss;
  reg clk=0; always #5 clk=~clk;
  reg reset=1;

  localparam [26:0] SRC_ADDR  = 27'h0001000;
  localparam [26:0] SCAN_ADDR = 27'h0400000;
  localparam [63:0] SRC_DATA  = 64'hCAFED00D_12345678;
  localparam integer GAP = 3;            // cycles c_ready leads c_dready
  localparam integer WATCHDOG = 200;     // cycles before declaring starvation

  // P_SRC client (mirrors blitter_top S_SRC_SDRAM_WAIT)
  reg  [26:0] p0_addr = SRC_ADDR;
  reg         p0_rd = 0;
  wire        p0_grant, p0_busy, p0_dready;
  wire [63:0] p0_dout64;

  // P_SCAN preemptor
  reg  [26:0] scan_addr = SCAN_ADDR;
  reg         scan_rd = 0;
  reg  [7:0]  scan_burst = 8'd1;
  wire        scan_busy, scan_dready;
  wire [63:0] scan_dout64;

  // P_DST unused here
  wire        dst_busy, dst_dready; wire [63:0] dst_dout64;

  // controller stub
  wire [26:0] c_addr; wire c_rd, c_we, c_we_burst;
  wire [15:0] c_din;  wire [63:0] c_din64;
  reg         c_ready = 1, c_busy = 0;
  reg         c_dready = 0; reg [63:0] c_dout64_r = 0;

  integer errors = 0;

  sdram_src_arb dut (
    .clk(clk), .reset(reset),
    .scan_addr(scan_addr), .scan_rd(scan_rd), .scan_burst(scan_burst),
    .scan_busy(scan_busy), .scan_dout64(scan_dout64), .scan_dready(scan_dready),
    .p0_addr(p0_addr), .p0_rd(p0_rd), .p0_grant(p0_grant), .p0_busy(p0_busy),
    .p0_we(1'b0), .p0_din(16'd0), .p0_waddr(27'd0), .p0_we_burst(1'b0), .p0_din64(64'd0),
    .p0_dready(p0_dready), .p0_dout64(p0_dout64),
    .dst_addr(27'd0), .dst_rd(1'b0), .dst_we(1'b0), .dst_din(16'd0),
    .dst_we_burst(1'b0), .dst_din64(64'd0),
    .dst_busy(dst_busy), .dst_dout64(dst_dout64), .dst_dready(dst_dready),
    .c_addr(c_addr), .c_rd(c_rd), .c_we(c_we), .c_din(c_din),
    .c_we_burst(c_we_burst), .c_din64(c_din64),
    .c_ready(c_ready), .c_busy(c_busy), .c_dready(c_dready), .c_dout64(c_dout64_r)
  );

  // --- controller stub: deliver the SRC read's beat GAP cycles after it issues ---
  reg        src_armed = 0;
  reg [7:0]  src_cnt = 0;
  always @(posedge clk) begin
    c_dready <= 1'b0;
    if (reset) begin src_armed <= 0; src_cnt <= 0; end
    else begin
      if (c_rd && (c_addr == SRC_ADDR) && !src_armed) begin
        src_armed <= 1'b1; src_cnt <= GAP[7:0];
      end
      if (src_armed) begin
        if (src_cnt == 0) begin
          c_dready <= 1'b1; c_dout64_r <= SRC_DATA; src_armed <= 1'b0;
        end else src_cnt <= src_cnt - 8'd1;
      end
    end
  end

  // --- P_SRC client: issue one read, drop p0_rd on !p0_busy, await p0_dready ----
  reg p0_done = 0; reg [63:0] p0_data = 0;
  always @(posedge clk) begin
    if (reset) begin p0_done <= 0; end
    else begin
      if (p0_rd && !p0_busy) p0_rd <= 1'b0;   // accepted; drop request
      if (p0_dready) begin p0_done <= 1'b1; p0_data <= p0_dout64; end
    end
  end

  // --- SCAN preemptor: request the cycle AFTER the SRC read is granted ----------
  always @(posedge clk) if (p0_grant) scan_rd <= 1'b1;

  // --- stimulus -----------------------------------------------------------------
  integer w;
  initial begin
    repeat(3) @(posedge clk); reset <= 0;
    @(posedge clk);
    p0_rd <= 1'b1;                 // kick off the SRC read (SCAN idle, so SRC wins)
    // wait for completion or watchdog
    for (w = 0; w < WATCHDOG; w = w + 1) begin
      @(posedge clk);
      if (p0_done) w = WATCHDOG;   // exit early on success
    end

    if (!p0_done) begin
      errors = errors + 1;
      $display("FAIL: P_SRC starved in S_SRC_SDRAM_WAIT — beat lost (owner released before c_dready)");
    end else if (p0_data !== SRC_DATA) begin
      errors = errors + 1;
      $display("FAIL: P_SRC got a beat but wrong data %h (exp %h)", p0_data, SRC_DATA);
    end

    $display("errors=%0d", errors);
    if (errors == 0) $display("RESULT: PASS");
    else             $display("RESULT: FAIL");
    $finish;
  end

  initial begin #100000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
```

- [ ] **Step 2: Run it on current RTL — expect FAIL**

Run: `cd fpga/sim && ./run_sims.sh tb_sdram_src_arb_beatloss`
Expected: `RESULT: FAIL` with "P_SRC starved in S_SRC_SDRAM_WAIT — beat lost". This
proves the test reproduces the wedge on the unfixed arbiter.

- [ ] **Step 3: Commit the RED test**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
git add fpga/sim/tb_sdram_src_arb_beatloss.sv
git commit -m "test(#34): RED directed sim — sdram_src_arb loses P_SRC read beat (S_SRC_SDRAM_WAIT wedge)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JXncPJXr9YurT9qc19bhWe"
```

---

### Task 2: Enrich the existing arbiter TB stub to deliver read beats

The fix (Task 3) holds reads until `c_dready`. The existing `tb_sdram_src_arb` stub
sets `c_ready=1` but NEVER pulses `c_dready`, so after the fix its reads would hang.
Make the stub deliver a one-cycle `c_dready` beat after each accepted read command.
This is behavior-preserving on the CURRENT (unfixed) arbiter (which ignores
`c_dready` for release), so the TB must still PASS now — isolating the stub change
from the fix.

**Files:**
- Modify: `fpga/sim/tb_sdram_src_arb.sv:44` (the `c_dready` reg) and add a driver.

**Interfaces:**
- Consumes: `c_rd` (command-accepted strobe from the arbiter).
- Produces: `c_dready` pulsing one cycle after every read command.

- [ ] **Step 1: Drive c_dready one cycle after each read command**

In `fpga/sim/tb_sdram_src_arb.sv`, the controller is stubbed `c_ready=1, c_busy=0`
and `c_dready` is declared but never driven (`fpga/sim/tb_sdram_src_arb.sv:44`).
Add a driver after the DUT instantiation (e.g. right after the
`sdram_src_arb dut (...)` block, near line 68) so every accepted read returns a beat:

```systemverilog
  // Controller stub returns a read beat one cycle after each accepted command
  // (the original stub claimed ready but never delivered a beat — unrealistic;
  //  the #34 read-beat-hold fix requires a beat to release a read).
  always @(posedge clk) c_dready <= c_rd;
```

(Leave `c_dready=0` initialization at its declaration; remove no existing code.)

- [ ] **Step 2: Run the existing arbiter TB on current RTL — expect PASS (unchanged)**

Run: `cd fpga/sim && ./run_sims.sh tb_sdram_src_arb`
Expected: `RESULT: PASS` with `errors=0` and `max_gap <= 4` (the current arbiter
ignores `c_dready`, so behavior is unchanged). If `max_gap` rose above 4, STOP — the
stub change altered timing unexpectedly; investigate before proceeding.

- [ ] **Step 3: Commit**

```bash
git add fpga/sim/tb_sdram_src_arb.sv
git commit -m "test(#34): tb_sdram_src_arb stub delivers a read beat per command

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JXncPJXr9YurT9qc19bhWe"
```

---

### Task 3: Apply the read-beat hold fix to sdram_src_arb

Hold a granted READ's owner until its beat is delivered. Keyed on `rd_held` so it
covers P_SRC/P_DST/P_SCAN; writes (`rd_held=0`) release on `c_ready` as before.

**Files:**
- Modify: `fpga/rtl/sdram_src_arb.sv` (declarations ~73-86, reset ~92-103, held/grant logic ~111-167)

**Interfaces:**
- Consumes: `c_dready` (per-beat strobe), `c_ready` (line-complete), `p0_rd`/`dst_rd`/`scan_rd`.
- Produces: unchanged ports; the only behavioral change is the `held_txn` release timing for reads.

- [ ] **Step 1: Declare `rd_held` and `beat_seen`**

In `fpga/rtl/sdram_src_arb.sv`, after the `reg just_granted;` declaration (around
line 86), add:

```systemverilog
   // #34: a granted READ must not release the owner until its data beat (c_dready)
   // has been routed to the client — otherwise re-arbitration steals the owner and
   // c_dready & (owner==N) masks the beat off (S_SRC_SDRAM_WAIT wedge). Writes have
   // no return beat and release on c_ready as before.
   reg       rd_held;   // in-flight transaction is a READ awaiting its beat
   reg       beat_seen; // c_dready observed during the current held transaction
```

- [ ] **Step 2: Reset the new regs**

In the `if (reset)` block (around lines 93-103), after `p0_grant <= 1'b0;` add:

```systemverilog
         rd_held   <= 1'b0;
         beat_seen <= 1'b0;
```

- [ ] **Step 3: Change the held-release condition + latch the beat**

Replace the held_txn block (currently lines ~111-119):

```systemverilog
         if (held_txn) begin
            if (just_granted) just_granted <= 1'b0;
            else if (c_ready)  held_txn    <= 1'b0;
         end else if (!c_busy) begin
```

with:

```systemverilog
         if (held_txn) begin
            if (c_dready) beat_seen <= 1'b1;           // remember the beat arrived
            if (just_granted) just_granted <= 1'b0;
            // write: release on c_ready; read: also require the beat delivered
            else if (c_ready && (!rd_held || beat_seen || c_dready))
               held_txn <= 1'b0;
         end else if (!c_busy) begin
```

- [ ] **Step 4: Tag read-vs-write + clear beat_seen at each grant**

In the SCAN grant branch (after `just_granted <= 1'b1;`, ~line 127) add:

```systemverilog
               rd_held   <= 1'b1;   // SCAN is always a read
               beat_seen <= 1'b0;
```

In the SRC grant branch (after `just_granted <= 1'b1;`, ~line 131) add:

```systemverilog
               rd_held   <= p0_rd;  // read if p0_rd, else a staging write
               beat_seen <= 1'b0;
```

In the DST grant branch (after `just_granted <= 1'b1;`, ~line 149) add:

```systemverilog
               rd_held   <= dst_rd; // read if dst_rd, else a write
               beat_seen <= 1'b0;
```

(The `owner <= 2'd0` idle branch needs no change — no transaction is held there.)

- [ ] **Step 5: Run the RED sim — now expect PASS**

Run: `cd fpga/sim && ./run_sims.sh tb_sdram_src_arb_beatloss`
Expected: `RESULT: PASS` (`errors=0`). The P_SRC client now receives its beat
(owner held to `P_SRC` until `c_dready`).

- [ ] **Step 6: Run the full suite — expect all green, no regression**

Run: `cd fpga/sim && ./run_sims.sh`
Expected: `RESULT: PASS`, `passed=20 gating-failures=0 non-gating-failures=0`
(19 prior + the new `tb_sdram_src_arb_beatloss`). Pay special attention that
`tb_sdram_src_arb`, `tb_blitter_system` (write coalescing), `tb_vram_contention`,
`tb_demux_preempt`, and `tb_scanout_sdram` all PASS. If any read client now hangs,
STOP — a grant branch is missing its `rd_held`/`beat_seen` assignment.

- [ ] **Step 7: Commit the fix**

```bash
git add fpga/rtl/sdram_src_arb.sv
git commit -m "fix(#34): sdram_src_arb holds a read's owner until its beat (S_SRC_SDRAM_WAIT wedge)

Release held_txn for a READ only once its data beat (c_dready) has been routed to
the owner (rd_held + beat_seen); writes release on c_ready as before. Keyed on
rd_held so P_SRC/P_DST/P_SCAN reads are all correct-by-construction (no longer rely
on client re-request workarounds). tb_sdram_src_arb_beatloss RED->GREEN; suite 20/20.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JXncPJXr9YurT9qc19bhWe"
```

---

### Task 4: Build + HW relaunch-soak

**Files:** none (build + deploy + observe).

**Interfaces:** consumes the CI RBF; uses the probe (already in the core from `12b8e1d`).

- [ ] **Step 1: Push to trigger the windows build**

```bash
git push
sleep 8
gh run list --workflow build-rbf.yml -L 1
```
Then wait for completion:
```bash
gh run view <id> --json status -q .status   # poll until "completed"
gh run view <id> --json conclusion -q .conclusion   # expect "success"
gh run view <id> --log | grep -m1 "Worst-case setup slack is"
```

- [ ] **Step 2: Download + stage + push the RBF (verify sha1)**

```bash
rm -rf /tmp/solrbf && gh run download <id> -n solarus-rbf -D /tmp/solrbf
shasum /tmp/solrbf/Solarus_20260619.rbf
cp /tmp/solrbf/Solarus_20260619.rbf _Other/Solarus_20260619.rbf
ssh root@192.168.20.81 'rm -f /media/fat/_Other/Solarus_20260619.rbf'
scp _Other/Solarus_20260619.rbf root@192.168.20.81:/media/fat/_Other/Solarus_20260619.rbf
ssh root@192.168.20.81 'sha1sum /media/fat/_Other/Solarus_20260619.rbf'   # must match shasum above
```

- [ ] **Step 3: Load the core, boot, and relaunch-soak**

```bash
ssh root@192.168.20.81 'bash -s' <<'EOF'
kill -9 $(pidof solarus-run) 2>/dev/null
echo "load_core /media/fat/_Other/Solarus_20260619.rbf" > /dev/MiSTer_cmd
sleep 7
echo "games/Solarus/quests/mystery_of_solarus_dx.sol" > /media/fat/config/Solarus.s0
for r in 1 2 3 4 5; do
  kill -9 $(pidof solarus-run) 2>/dev/null; sleep 1
  rm -rf /tmp/solarus_quest
  cd /media/fat/games/Solarus
  setsid env SOLARUS_SDRAM_SRC=1 ./solarus_run.sh >/tmp/sol_boot.log 2>&1 &
  sleep 10
  f1=$(busybox devmem 0x3A000000); sleep 4; f2=$(busybox devmem 0x3A000000)
  if [ "$f1" = "$f2" ]; then
    echo "relaunch $r WEDGED: frame=$f1 probe=$(busybox devmem 0x3A070004)"
  else
    echo "relaunch $r OK: $f1 -> $f2 (advancing)"
  fi
done
EOF
```
Expected: all 5 relaunches print `OK ... (advancing)`; the probe never reads
`0xFF01481F` (or any `0xFF......` stuck value). Per the done-bar, this is the HW
confirmation.

- [ ] **Step 4: Record the outcome in memory**

Update `fpga-vram-bug3-resume.md` + `MEMORY.md`: the source-read beat-hold fix
landed (commit hash, sim RED→GREEN, suite 20/20, HW relaunch-soak result). If clean,
note #34 is HW-resolved pending probe-strip + final clean build; if it still wedges,
capture the new probe signature and reopen.

---

## Self-Review

**Spec coverage:**
- Spec "RTL change" (rd_held/beat_seen, release condition, per-grant tagging) → Task 3 Steps 1-4. ✓
- Spec "RED directed sim" (c_ready-before-c_dready stub + SCAN preemptor + blitter-mirroring P_SRC client) → Task 1. ✓
- Spec note that the fix would deadlock the old unrealistic stub → Task 2 (enrich `tb_sdram_src_arb`). ✓ (necessary prerequisite the spec implies via "no regression: tb_sdram_src_arb")
- Spec validation/done-bar (RED→GREEN, suite 19→20, HW relaunch-soak) → Task 3 Steps 5-6, Task 4. ✓
- Spec audit (fix covers P_SRC/P_DST/P_SCAN) → Task 3 Step 4 tags all three; Step 6 checks all read clients. ✓
- Spec out-of-scope (write-behind-write) → Global Constraints; not implemented here. ✓

**Placeholder scan:** `<id>` is the CI run id produced in Task 4 Step 1; no TODO/TBD;
all code blocks are complete (full TB, exact edits). ✓

**Type/name consistency:** `rd_held`, `beat_seen`, `c_dready`, `held_txn`,
`just_granted`, `owner`, `p0_dready`, `p0_busy`, `SRC_ADDR`/`SCAN_ADDR`/`SRC_DATA`
used identically across tasks. The release expression
`c_ready && (!rd_held || beat_seen || c_dready)` is identical in spec and plan. ✓
