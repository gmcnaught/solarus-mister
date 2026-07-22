# Stage 5 Phase 2 — Framebuffer → DDR3 (scan-only) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the framebuffer's scanout copy off-chip to a DDR3 double-buffer while keeping the compositing WORK buffer on-chip, freeing ~160 M10K (89%→~60% BRAM) with no fabric-throughput regression.

**Architecture:** The compositor keeps RMW-ing an on-chip WORK buffer (`comp_fbram` WORK banks) at 1-cyc BRAM speed. A vblank snapshot burst-writes the finished frame into a DDR3 double-buffer via the blitter's existing `mem_*` master; the OpenBOR-style scanout reader is un-bridged from `comp_fbram` back to DDR3. Because the composite hot loop never touches DDR3, perf-neutrality is structural. Mostly deletions (SCAN banks, `fbram_scan_adapter`, dead SDRAM FB path) plus a snapshot retarget and a tear-free write fence.

**Tech Stack:** SystemVerilog (Cyclone V / DE10-Nano), Icarus Verilog sim (`fpga/sim/run_sims.sh`), Quartus RBF build in CI (self-hosted runner), armhf engine unchanged.

## Global Constraints

- **Target die:** Cyclone V on DE10-Nano; 553 M10K total. Current usage **493/553 (89%)**; target after this work **~333/553 (~60%)**.
- **Output resolution is fixed 320×240 RGB565.** FB is 19200 qwords (80 qwords/line × 240 lines); qword index = `y*80 + (x>>2)`, lane = `x[1:0]`.
- **No ascal.** Scanout stays the direct OpenBOR reader → `VGA_*` path.
- **Perf-neutral is a hard gate.** The compositor's per-frame fabric/comp cycle counts (HW counters `0x3B00002C` fabric-busy, `0x3B000034` comp-busy) must be unchanged vs the `Solarus_20260722` baseline on map 119 + map 1.
- **DDR3 (f2h) memory map (verbatim):** control word `0x3A000000` (`{frame_counter[31:2], active_buffer[1:0]}`); FB buffer 0 `0x3A000040`; FB buffer 1 `0x3A040040`; command ring `0x3A0E0000`; GRID_BUF/TL_BUF as today. Source atlases are on the **separate SDRAM chip** — never DDR3.
- **Sim runner:** `cd fpga/sim && ./run_sims.sh [tb_name…]`. A TB passes iff it prints its PASS marker, no FAIL marker, within timeout. `FABRIC_ASSERT` SVAs are enabled by the runner's tier defines. Never hand-maintain filelists — iverilog library-search resolves deps (`-y ../rtl ../rtl/jtframe ../sys .`).
- **Current pinned fitter seed:** `Solarus.qsf:64` → `set_global_assignment -name SEED 3` (from Stage 3b B2). Unpinning is a **bonus** task, not a gate.
- **Copyright header on any new RTL file:** `// Copyright (C) 2026 — GPL-3.0`.
- Commit after every green step. Do not push until Task 9 (the CI gate).

---

## File-structure map

| File | Responsibility | Change |
|---|---|---|
| `fpga/rtl/comp_fbram.sv` | On-chip framebuffer | **Shrink to WORK-only** (delete SCAN banks + scan/snap ports) |
| `fpga/rtl/fbram_scan_adapter.sv` | Bridge reader `scn_*` → `comp_fbram` SCAN | **Delete** (Task 6) |
| `fpga/rtl/fbram_snapshot.sv` | Vblank WORK→SCAN copy | **Repurpose or delete** → WORK→DDR3 burst writer (Task 4) |
| `fpga/rtl/vram_demux.sv` | Route blitter `mem_*` DDR vs SDRAM | **Retarget FB region → DDR3**, delete dead `sd_*` SDRAM FB path |
| `fpga/rtl/openbor_video_reader.sv` | Scanout reader | **Un-bridge** scanout to DDR3 (mechanism per Task 1) |
| `fpga/rtl/blitter_top.sv` | Compositor top; owns snapshot + control-word write | Retarget snapshot to DDR3 writer; add write→ctrl-word fence + buffer alternation |
| `fpga/Solarus.sv` | Core top; DDR3 arbiter/demux wiring (~L490–730) | Remove `comp_fbram` scan/snap + `fbram_scan_adapter`; wire DDR3 scanout |
| `fpga/sim/tb_scanout_ddr3.sv` | **New** — reader reads DDR3 FB double-buffer, pixel-exact | Create (Task 6) |
| `fpga/sim/tb_fb_ddr_writer.sv` | **New** — WORK→DDR3 snapshot burst correctness + ctrl-word fence SVA | Create (Tasks 4–5) |
| `fpga/sim/tb_fbram.sv`, `tb_scanout_fbram.sv`, `tb_fbram_snapshot.sv`, `tb_blitter_snapshot_pipe.sv`, `tb_blitter_snapshot_blend_pipe.sv` | Existing FB/scan/snap TBs | Update (WORK-only) or retire (Tasks 2, 7) |
| `docs/superpowers/data/stage5/phase2-reader-audit.md` | **New** — Task 1 audit findings | Create (Task 1) |

---

### Task 1: Audit the reader's scanout path; decide the un-bridge mechanism

No RTL change — this task produces the facts every later scanout task consumes. "Prefer existing code" is the tie-breaker.

**Files:**
- Read: `fpga/rtl/openbor_video_reader.sv`, `fpga/rtl/fbram_scan_adapter.sv`, `fpga/sim/tb_scanout_fbram.sv`, `fpga/sim/tb_scanout_sdram.sv` (if present in git history)
- Create: `docs/superpowers/data/stage5/phase2-reader-audit.md`

**Interfaces:**
- Produces: `SCANOUT_MECHANISM ∈ {native-restore, thin-ddr3-adapter}`; the exact reader signals that carry pixel-scan fetch today (`scan_addr[26:0]`, `scan_rd`, plus the `scn_ok`/`scn_dout` return served by `fbram_scan_adapter`); whether the OpenBOR `dcfifo` line read-ahead + `LINE_BURST=80` + `BUF0_ADDR`/`BUF1_ADDR` DDR-burst logic survives in-file or must come from git history.

- [ ] **Step 1: Trace the current pixel-scan datapath.** Run:
```bash
grep -nE "scan_addr|scan_rd|ST_READ_LINE|ST_WAIT_DISPLAY|LINE_BURST|dcfifo|line_fifo|buf_base_addr|ddr_addr *<=|BUF0_ADDR|BUF1_ADDR" fpga/rtl/openbor_video_reader.sv
```
Determine: does `ST_READ_LINE` drive `ddr_addr` bursts (native) or `scan_addr` (cache-ok)? (Expected from prior review: `scan_addr` cache-ok; `ddr_addr` is used only for the control-word poll `CTRL_ADDR` and cart/joystick housekeeping.) Note whether a `dcfifo`/`line_fifo` read-ahead is still instantiated in-file.

- [ ] **Step 2: Check git history for the pre-fork native DDR3 scanout.** Run:
```bash
git log --oneline --all -- fpga/rtl/openbor_video_reader.sv | head; \
git log --oneline --all -- fpga/sim/tb_scanout_sdram.sv | head
```
Record the last commit where the reader read scanlines via native `ddr_addr` `LINE_BURST`, and whether a retired `tb_scanout_sdram.sv` exists to model the DDR3 read side.

- [ ] **Step 3: Decide the mechanism and write the audit note.** Write `docs/superpowers/data/stage5/phase2-reader-audit.md` with: the traced datapath, the two candidate mechanisms with their concrete diffs, and the choice. Decision rule (per user "prefer existing code"): choose whichever reuses the most shipped, validated RTL for the least new code —
  - **thin-ddr3-adapter** (expected winner): reader FSM + `scan_addr`/`scn_ok` interface untouched (maximally existing); replace `fbram_scan_adapter` with `ddr3_scan_adapter.sv` that services `scan_addr` reads from the DDR3 FB double-buffer through a line read-ahead FIFO (reuse the `dcfifo` pattern already in the reader/OpenBOR history).
  - **native-restore**: re-convert `ST_READ_LINE` to `ddr_addr` `LINE_BURST` from git history. Choose only if the FSM conversion is a clean revert AND the thin adapter would duplicate the reader's own FIFO.

- [ ] **Step 4: Commit.**
```bash
git add docs/superpowers/data/stage5/phase2-reader-audit.md
git commit -m "docs(stage5-p2): reader scanout audit — un-bridge mechanism decision"
```

---

### Task 2: Shrink `comp_fbram` to WORK-only

Delete the SCAN half. This is the ~160 M10K win.

**Files:**
- Modify: `fpga/rtl/comp_fbram.sv`
- Test: `fpga/sim/tb_fbram.sv` (existing; WORK read/write coverage)

**Interfaces:**
- Produces: `comp_fbram` module with ports `clk, wr_en, wr_qw[14:0], wr_lane[1:0], wr_pix[15:0], rd_en, rd_qw[14:0], rd_qword[63:0]` **only** (no `scan_*`, no `snap_*`).

- [ ] **Step 1: Confirm `tb_fbram` covers WORK read/write and does NOT depend on scan/snap.** Run:
```bash
grep -nE "scan_|snap_|sbank" fpga/sim/tb_fbram.sv
```
If it drives `scan_*`/`snap_*`, note those lines for Step 4.

- [ ] **Step 2: Delete the SCAN banks and ports in `comp_fbram.sv`.** Remove: the four `sbank0-3` declarations (lines ~50–53); the `snap_we/snap_qw/snap_qword` ports and their `always` block (lines ~39–42, ~66–73); the `scan_rd_en/scan_rd_qw/scan_rd_qword` ports and their read block (lines ~35–38, ~91–97); the `#110` SCAN read-during-write SVA (lines ~99–112). Update the header comment to describe a single WORK buffer (~160 M10K, 4 banks). Keep the compositor RMW-read note (lines ~75–83).

- [ ] **Step 3: Build the module standalone to catch port/decl errors.**
```bash
cd fpga/sim && iverilog -g2012 -o /tmp/cf.vvp -I ../rtl -I ../rtl/jtframe -I ../sys -I . \
  -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v tb_fbram.sv 2>&1 | tail
```
Expected: no build errors. If `tb_fbram.sv` references removed ports, fix the TB (Step 4); else skip to Step 5.

- [ ] **Step 4: If needed, trim `tb_fbram.sv` to WORK-only.** Remove any `scan_*`/`snap_*` stimulus/checks; keep WORK write-then-read-back assertions.

- [ ] **Step 5: Run the TB.**
```bash
cd fpga/sim && ./run_sims.sh tb_fbram
```
Expected: `tb_fbram … PASS`.

- [ ] **Step 6: Commit.**
```bash
git add fpga/rtl/comp_fbram.sv fpga/sim/tb_fbram.sv
git commit -m "feat(stage5-p2): comp_fbram WORK-only — delete SCAN half (~160 M10K)"
```

---

### Task 3: Retarget `vram_demux` FB region to DDR3; delete dead SDRAM FB path

**Files:**
- Modify: `fpga/rtl/vram_demux.sv`
- Test: `fpga/sim/tb_vram_demux.sv` (existing)

**Interfaces:**
- Consumes: `` `FB_DDR0_QW ``/`` `FB_DDR1_QW ``/`` `FB_QWORDS `` from `blitter_defs.vh` (already used for the `is_fb` decode).
- Produces: `vram_demux` routing **all** blitter `mem_*` traffic (including the FB region) to the DDR side (`ddr_*`); the SDRAM side (`sd_*`) removed.

- [ ] **Step 1: Read the current decode.** Confirm lines ~65–81: `is_fb` selects the `sd_*` (SDRAM) remap today (`fb_base = SDRAM_FB0/1_BASE`), and non-FB passes to `ddr_*` gated by `& ~is_fb`.

- [ ] **Step 2: Update `tb_vram_demux.sv` to expect FB→DDR (failing).** Add/modify an assertion: a write to `` `FB_DDR0_QW `` appears on `ddr_addr`/`ddr_wr` (not `sd_*`). Run and confirm it FAILS against the current SDRAM routing:
```bash
cd fpga/sim && ./run_sims.sh tb_vram_demux   # expect FAIL on the new FB→DDR assertion
```

- [ ] **Step 3: Retarget the decode.** In `vram_demux.sv`: drop the `& ~is_fb` gate so `ddr_rd/ddr_wr = blt_rd/blt_wr` pass through for all addresses (FB writes already carry the DDR qword address `` `FB_DDR0_QW ``+off). Delete the `sd_*` port group, the `S_WOKWAIT/S_RDLAT` SDRAM state machine, `acc_qw`, and the `fb_base`/`qw_byte` SDRAM remap. Route `blt_busy`/`blt_dout`/`blt_dout_ready` from the DDR side only.

- [ ] **Step 4: (Deferred to Task 8 — do NOT edit `Solarus.sv` here.)** Removing the `sd_*` ports from `vram_demux` leaves the `Solarus.sv` instantiation (`.sd_addr(dst_addr)` etc., ~L687–721) with dangling connections, so `Solarus.sv` will not elaborate until Task 8 updates the instantiation and deletes the now-unused arbiter `dst_*`/P_DST SDRAM channel. That is expected and is Task 8's job. This task changes only `vram_demux.sv` + `tb_vram_demux.sv` and gates on `tb_vram_demux` (which instantiates the demux standalone).

- [ ] **Step 5: Run the TB.**
```bash
cd fpga/sim && ./run_sims.sh tb_vram_demux
```
Expected: PASS (FB writes now route to DDR3).

- [ ] **Step 6: Commit.**
```bash
git add fpga/rtl/vram_demux.sv fpga/sim/tb_vram_demux.sv fpga/Solarus.sv
git commit -m "feat(stage5-p2): vram_demux routes FB region to DDR3, drop dead SDRAM FB path"
```

---

### Task 4: WORK→DDR3 snapshot burst writer

Repurpose `fbram_snapshot` to burst-write the finished WORK frame into the DDR3 inactive buffer via the blitter `mem_*` master, in vblank.

**Scope:** purely additive — a new standalone module + its module-level TB. Does NOT touch `blitter_top.sv` or `fbram_snapshot.sv` (Task 5 owns all `blitter_top` integration and the old-module cleanup). This keeps Task 4 self-contained and cleanly gated.

**Files:**
- Create: `fpga/rtl/fb_ddr_writer.sv` (new WORK→DDR3 burst-write master)
- Create: `fpga/sim/tb_fb_ddr_writer.sv`

**Interfaces:**
- Consumes: a `comp_fbram`-style WORK read port (`rd_en`/`rd_qw[14:0]`/`rd_qword[63:0]`, registered, 1-cyc) and a write-accept strobe from the bus (`mem_accept`).
- Produces the module `fb_ddr_writer` (Task 5 instantiates it), with this exact interface:
```systemverilog
module fb_ddr_writer #(parameter integer FB_QWORDS=19200, parameter integer AW=15) (
    input  wire         clk, rst,
    input  wire         start,          // 1-cyc pulse (vblank): begin WORK→DDR3 burst
    input  wire [28:0]  base_qw,        // inactive-buffer base (DDR qword addr) = `FB_DDR0_QW or `FB_DDR1_QW
    output reg          busy,
    output reg          done,           // 1-cyc pulse when the LAST write is accepted (drained)
    output reg          rd_en,          // WORK read port (→ comp_fbram rd_*)
    output reg  [AW-1:0] rd_qw,
    input  wire [63:0]  rd_qword,       // registered, valid 1 cyc after rd_qw/rd_en
    output reg          mem_wr,         // DDR write master (Task 5 funnels onto blitter mem_* during snap)
    output reg  [28:0]  mem_addr,       // = base_qw + k
    output reg  [63:0]  mem_din,        // = WORK qword k
    output wire [7:0]   mem_be,         // 8'hFF
    output reg  [7:0]   mem_burstcnt,   // real burst length (NEVER 8'd1 for a multi-beat write — the `#1` wedge class)
    input  wire         mem_accept      // write accepted this cycle (bus ready; e.g. ~mem_busy)
);
```
Behavior: on `start`, stream qword k=0..FB_QWORDS-1 — read WORK[k], write DDR[`base_qw`+k] — honoring `mem_accept` backpressure (hold the request until accepted). `done` pulses once, the cycle the 19200th write is accepted; no writes after `done`. Prefer a line-granular burst (`mem_burstcnt=80`) to amortize DDR latency; single-beat is a fallback only if the write handshake requires it.

- [ ] **Step 1: Write the failing module TB.** Create `fpga/sim/tb_fb_ddr_writer.sv`: instantiate `fb_ddr_writer` + a WORK-read model (qword k = `{4{k[15:0]}}`) + a DDR write-sink model that captures `(mem_addr, mem_din)` on accepted writes AND can inject backpressure (deassert `mem_accept` for N cycles). Pulse `start` with `base_qw=`FB_DDR1_QW`. Assert:
```systemverilog
assert (write_count == 19200);
assert (first_addr  == `FB_DDR1_QW);
assert (last_addr   == `FB_DDR1_QW + 19199);
assert (data_matches_work_ramp);                       // each DDR[base+k] == WORK[k]
assert ($rose(done) |-> (writes_accepted == 19200));   // done only after full drain
assert (no_write_after_done);
assert (mem_burstcnt != 8'd1 || total_beats == 1);     // multi-beat writes carry a real burstcnt
```

- [ ] **Step 2: Run it, expect FAIL (module doesn't exist yet).**
```bash
cd fpga/sim && ./run_sims.sh tb_fb_ddr_writer   # FAIL: fb_ddr_writer not found
```

- [ ] **Step 3: Implement `fb_ddr_writer.sv`** to the interface above, with backpressure handling and the burst write. Copyright header `// Copyright (C) 2026 — GPL-3.0`.

- [ ] **Step 4: Run the TB, expect PASS** (including the backpressure-injection case).
```bash
cd fpga/sim && ./run_sims.sh tb_fb_ddr_writer
```

- [ ] **Step 5: Commit.**
```bash
git add fpga/rtl/fb_ddr_writer.sv fpga/sim/tb_fb_ddr_writer.sv
git commit -m "feat(stage5-p2): fb_ddr_writer — WORK->DDR3 burst-write master (module + TB)"
```

---

### Task 5: `blitter_top` integration — drive `fb_ddr_writer`, reorder the fence, alternate buffers

Wire the Task-4 writer into `blitter_top`'s FSM, and **reorder** so the WORK→DDR3 burst drains BEFORE the control word (VCTRL) is published — the tear-free fence. This is the one new correctness obligation.

**Current state (verified anchors, `blitter_top.sv`):** the FSM currently publishes the control word in `S_FRAME_VCTRL` (:1180, `bm_wr` to `` `VCTRL_QW ``, `vctrl_val`=:554 = `{(frame_counter+1)<<2, target_buf[0]}`) and only THEN runs the snapshot (`S_SNAP_WAIT`→`S_SNAP_BUSY`→`S_SNAP_DRAIN`, :1212–1217). The single `mem_*` master is a 2-way mux (:1329–1332): compositor `p_mem_*` when `pipe_busy_q`, else the FSM's `bm_*` (with `mem_burstcnt` hardwired `8'd1`). The snapshot instance is `fbram_snapshot` (:1300); `fb_rd_*` is already muxed to it during `snap_busy` (:1314–1315).

**Files:**
- Modify: `fpga/rtl/blitter_top.sv`
- Delete: `fpga/rtl/fbram_snapshot.sv` (its WORK→SCAN role is obsolete — SCAN is gone)

**Interfaces:**
- Consumes: `fb_ddr_writer` (Task 4) — `start`/`base_qw`/`busy`/`done`/`rd_*`/`mem_*`/`mem_accept`.
- Produces: on each frame — WORK→DDR3 burst into the **inactive** buffer, THEN a fenced VCTRL write flipping `target_buf[0]` to the just-written buffer and bumping `frame_counter`.

- [ ] **Step 1: Swap the snapshot instance.** Replace the `fbram_snapshot` instance (:1300) with `fb_ddr_writer`: keep `start`(=`snap_start`)/`busy`(=`snap_busy`)/`rd_en`/`rd_qw`/`rd_qword` wiring; add `base_qw = target_buf[0] ? `FB_DDR0_QW : `FB_DDR1_QW` (the INACTIVE buffer = opposite of what VCTRL is about to publish), `done`(→`snap_done`), and the `mem_*`/`mem_accept` write side. Delete `fbram_snapshot.sv` and the `fb_snap_we/qw/qword` outputs (dead since Task 2).

- [ ] **Step 2: Funnel the writer's `mem_*` onto the master during snap.** Extend the mux (:1329–1332): during `snap_busy` route `mem_wr/mem_addr/mem_din/mem_be/mem_burstcnt` from `fb_ddr_writer`; wire `mem_accept` from the master's accept/`~mem_busy`. Keep compositor `p_mem_*` when `pipe_busy_q`, `bm_*` otherwise. **`mem_burstcnt` must carry the writer's real burst length during snap — not `8'd1`.**

- [ ] **Step 3: Reorder the FSM for the fence.** Make the per-frame order: composite → `S_SNAP_WAIT` (wait `vs_rise`) → run the WORK→DDR3 burst (`S_SNAP_BUSY`/`S_SNAP_DRAIN`, now the writer) → on `snap_done`, `S_FRAME_VCTRL` publishes VCTRL with `target_buf` flipped to the just-written buffer + bump `frame_counter` → `C_DONE`/`C_STATUS`. VCTRL must NOT be issued until `snap_done`. Add a `FABRIC_ASSERT` SVA in `blitter_top`: `bm_wr && (bm_addr==`VCTRL_QW)` implies the prior `fb_ddr_writer.done` fired for this frame (fence holds).

- [ ] **Step 4: Build blitter_top standalone to catch elaboration errors** (the full system TB is re-pointed in Task 7; here just confirm `blitter_top` + `fb_ddr_writer` elaborate together):
```bash
cd fpga/sim && iverilog -g2012 -o /tmp/bt.vvp -I ../rtl -I ../rtl/jtframe -I ../sys -I . \
  -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v tb_fb_ddr_writer.sv 2>&1 | tail
```
Also re-run the writer gate (unchanged by this task): `./run_sims.sh tb_fb_ddr_writer` → PASS.
> Note: end-to-end fence + ordering is verified in Task 7 (re-pointed `tb_blitter_system_pipe` reads the DDR3 FB, so a mis-ordered fence yields a torn/stale frame the TB catches). `blitter_top` will not fully elaborate in `Solarus.sv` until Task 8.

- [ ] **Step 5: Commit.**
```bash
git add fpga/rtl/blitter_top.sv && git rm fpga/rtl/fbram_snapshot.sv
git commit -m "feat(stage5-p2): drive fb_ddr_writer from blitter_top; fence VCTRL after DDR drain; flip buffer"
```

---

### Task 6: Un-bridge the reader — scanout from DDR3

Per Task 1's `SCANOUT_MECHANISM`. Steps below assume **thin-ddr3-adapter** (expected). If Task 1 chose **native-restore**, follow the audit note's diff instead and still land `tb_scanout_ddr3` green.

**Files:**
- Create: `fpga/rtl/ddr3_scan_adapter.sv` (thin-adapter case)
- Delete: `fpga/rtl/fbram_scan_adapter.sv`
- Modify: `fpga/rtl/openbor_video_reader.sv` (only if native-restore)
- Create: `fpga/sim/tb_scanout_ddr3.sv`

**Interfaces:**
- Consumes: reader `scan_addr[26:0]`/`scan_rd` (fetch req) → returns `scn_ok`/`scn_dout[63:0]`; DDR3 read master (shares the reader's `rdr` arbiter port or a dedicated read port).
- Produces: pixel-exact scanout of the DDR3 FB `active_buffer`. **Read-ahead lives in the reader already** — the audit (`docs/superpowers/data/stage5/phase2-reader-audit.md`) establishes the reader's line ping-pong is `linebuf` (a 256×64 BRAM inside `openbor_video_reader.sv`, addressed by line parity), sitting **downstream of** the `scan_addr`/`scan_rd`/`scan_dout`/`scan_ok` handshake. The adapter must **not** re-instantiate that read-ahead; it services the `scan_*` cache-ok handshake from DDR3 (matching `fbram_scan_adapter.sv`'s shape) and hides DDR3 latency with its **own line-granular DDR3 burst prefetch** into a small adapter buffer.

- [ ] **Step 1: Write the failing scanout TB.** Create `fpga/sim/tb_scanout_ddr3.sv` modeled on `tb_scanout_fbram.sv`: preload a known 320×240 frame into a DDR3 model at `` `FB_DDR0_QW ``, set the control word `{1, active_buffer=0}`, run the reader, and assert the emitted `vga_r/g/b` stream is pixel-exact for the whole frame (and reads from BUF0, not BUF1).

- [ ] **Step 2: Run, expect FAIL (still bridged to comp_fbram).**
```bash
cd fpga/sim && ./run_sims.sh tb_scanout_ddr3
```

- [ ] **Step 3: Implement the un-bridge (mechanism = `thin-ddr3-adapter`, per Task 1).** Create `ddr3_scan_adapter.sv` shaped like `fbram_scan_adapter.sv`: it presents the reader's `scan_addr`/`scan_rd` → `scan_dout`/`scan_ok` cache-ok interface **unchanged** (reader FSM + its `linebuf` untouched), and services each request from the DDR3 FB `active_buffer` base. To hide DDR3 latency, the adapter issues a **line-granular DDR3 burst** (80 qwords) into a small internal line buffer and serves the per-qword `scan_*` requests from it (do NOT add a second 2-line read-ahead — `linebuf` already provides the line ping-pong). Add a new DDR3 read leg on `ddr_blitter_arb` (shaped like its existing masters) for the adapter's bursts. Wire the `active_buffer` select into `buf_base_addr`'s existing mux point (`openbor_video_reader.sv:701`, today hardwired `27'd0`). Delete `fbram_scan_adapter.sv`. (If Task 1 had chosen `native-restore`, apply the audit-note diff to `openbor_video_reader.sv` instead — but it chose `thin-ddr3-adapter`.)

- [ ] **Step 4: Run, expect PASS.**
```bash
cd fpga/sim && ./run_sims.sh tb_scanout_ddr3
```

- [ ] **Step 5: Add an underrun SVA** (in the adapter under `FABRIC_ASSERT`): the adapter's internal line buffer must hold the requested qword whenever the reader asserts `scan_rd` in active scan (i.e. the line-burst prefetch stays ahead of the reader's per-qword consumption). Re-run to confirm no underrun in sim.

- [ ] **Step 6: Commit.**
```bash
git add fpga/rtl/ddr3_scan_adapter.sv fpga/sim/tb_scanout_ddr3.sv
git rm fpga/rtl/fbram_scan_adapter.sv
git commit -m "feat(stage5-p2): un-bridge scanout — reader reads DDR3 FB double-buffer"
```

---

### Task 7: Retire dead FB/scan TBs; system sim green

**Files:**
- Delete/retire: `fpga/sim/tb_scanout_fbram.sv`, `tb_fbram_snapshot.sv`, `tb_blitter_snapshot_pipe.sv`, `tb_blitter_snapshot_blend_pipe.sv`
- Modify: `fpga/sim/tb_blitter_system_pipe.sv` (re-point scanout readback from comp_fbram to DDR3), `fpga/sim/run_sims.sh` (drop retired TBs from any name lists/timeouts)

**Interfaces:**
- Produces: a fully green `run_sims.sh` gate reflecting the DDR3 scanout end-state.

- [ ] **Step 1: Retire the comp_fbram-scanout + snapshot TBs.**
```bash
cd fpga/sim && git rm tb_scanout_fbram.sv tb_fbram_snapshot.sv tb_blitter_snapshot_pipe.sv tb_blitter_snapshot_blend_pipe.sv
```
Remove their names from any per-TB timeout/SKIP/NONGATING lists in `run_sims.sh` (e.g. the `tb_scanout_fbram) to=200` line).

- [ ] **Step 2: Re-point `tb_blitter_system_pipe.sv`** so its end-to-end scanout readback reads the DDR3 FB (as Task 6's model does) rather than `comp_fbram`. Assert a full composited frame scans out pixel-exact.

- [ ] **Step 3: Run the whole suite.**
```bash
cd fpga/sim && ./run_sims.sh
```
Expected: all gating TBs PASS; no FAIL. Confirm `tb_fbram`, `tb_vram_demux`, `tb_fb_ddr_writer`, `tb_scanout_ddr3`, `tb_blitter_system_pipe` are green.

- [ ] **Step 4: Commit.**
```bash
git add -A fpga/sim
git commit -m "test(stage5-p2): retire comp_fbram-scanout TBs, re-point system pipe to DDR3, suite green"
```

---

### Task 8: Core wiring in `Solarus.sv`

Wire the DDR3 scanout end-state; remove `comp_fbram` scan/snap wiring and `fbram_scan_adapter`; delete the now-unused arbiter `dst_*`/P_DST SDRAM FB channel.

**Files:**
- Modify: `fpga/Solarus.sv` (~L384–521, ~L633–730)

**Interfaces:**
- Produces: `comp_fbram` instantiated WORK-only; scanout served from DDR3 (Task 6 module) via the reader; no `fbram_scan_adapter`; snapshot `mem_*` reaching the arbiter/demux DDR side.

- [ ] **Step 1: Remove the `comp_fbram` scan/snap connections** (~L500–508): drop `scan_rd_en/scan_rd_qw/scan_rd_qword` and the snapshot write wiring from the `comp_fbram` instance.
- [ ] **Step 2: Remove the `fbram_scan_adapter` instance** (~L512–521); wire the reader's `scn_*` (or native) scanout to the Task-6 DDR3 path instead.
- [ ] **Step 3: Delete the arbiter/demux `dst_*` SDRAM FB channel** left dangling after Task 3, and any `SDRAM_FB0/1_BASE`-only wires.
- [ ] **Step 4: Native syntax/elaboration check via the sim toolchain** (no Quartus needed):
```bash
cd fpga/sim && iverilog -g2012 -o /tmp/top.vvp -I ../rtl -I ../rtl/jtframe -I ../sys -I . \
  -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v tb_blitter_system_pipe.sv 2>&1 | tail
```
Expected: no unresolved-module / port-mismatch errors. (Solarus.sv `.*` connections can hide port mismatches — grep the changed instances to confirm ports exist.)
- [ ] **Step 5: Full suite re-run + commit.**
```bash
cd fpga/sim && ./run_sims.sh && cd ../.. && \
git add fpga/Solarus.sv && \
git commit -m "feat(stage5-p2): wire DDR3 scanout in Solarus.sv, remove comp_fbram scan/snap + adapter"
```

---

### Task 9: Fit/STA CI gate (push)

**Files:** none (CI).

**Interfaces:**
- Produces: an RBF fit with **~333/553 (~60%) M10K** and non-negative slack on shipping clocks (`clk_sys`; the async-grouped HDMI PLL neg-slack is pre-existing and not a gate).

- [ ] **Step 1: Push the branch and trigger the RBF build workflow.**
```bash
git push -u origin feat/stage5-phase2-fb-ddr3
gh workflow run <rbf-build-workflow>.yml --ref feat/stage5-phase2-fb-ddr3   # name from .github/workflows
```
- [ ] **Step 2: Watch the run; pull the fit summary.**
```bash
gh run watch <id>; gh run download <id> -n quartus-reports   # or the reports artifact name
```
- [ ] **Step 3: Verify the gate.** Confirm RAM utilization dropped to ~60% (from 89%) and `clk_sys` slack ≥ 0. Record numbers in `docs/superpowers/2026-07-22-stage5-phase2-fb-ddr3-design.md` (a "Task 9 result" note) and commit.

---

### Task 10: HW A/B — perf-neutral proof + operator visual gate

**Files:** `docs/superpowers/2026-07-22-stage5-phase2-hw-validation.md` (new)

**Interfaces:**
- Produces: HW evidence that fabric/comp cycle counts are unchanged vs baseline, and an operator-confirmed tear-free visual gate.

- [ ] **Step 1: Build the two cores.** Baseline = `Solarus_20260722.rbf` (already shipped); candidate = the Task-9 RBF. Refresh `deploy/` engine/libs only if the engine changed (it did not — this is RTL-only; the shipped engine is unchanged).
- [ ] **Step 2: Run the A/B harness** (model on `scripts/perf/stage5_ab_cache.sh`): identical workload on map 119 (fabric-bound) and map 1; capture fabric-busy (`0x3B00002C`) + comp-busy (`0x3B000034`) per frame and fps.
- [ ] **Step 3: Assert perf-neutral.** Candidate comp/fabric cycles per frame within measurement noise of baseline on both maps (this is criterion 1 — a regression here fails Phase 2).
- [ ] **Step 4: Operator visual gate.** Ask the operator (do NOT self-declare, per `solarus-no-self-declared-visual-validation`) to confirm: standing play, scrolling, and **fade transitions** are tear-free and correct across map 119, an interior, a dungeon, and a transition.
- [ ] **Step 5: Record + commit** the validation doc with the A/B tables and the operator verdict.

---

### Task 11 (bonus, non-gating): Attempt to unpin the fitter seed

**Files:** `fpga/Solarus.qsf:64`

- [ ] **Step 1: Remove the pin.** Delete `set_global_assignment -name SEED 3` (Solarus.qsf:64).
- [ ] **Step 2: Re-run the RBF build** (Task 9 mechanism) on a throwaway commit.
- [ ] **Step 3: Decide.** If the unpinned fit is clean (non-negative slack, RAM ~60%), keep it removed and commit `chore(stage5-p2): unpin fitter seed (160 M10K headroom relaxes placement)`. If not, restore the pin and record in the design doc that unpinning remains blocked. Either outcome is acceptable — this does not gate Phase 2.

---

## Self-review

**Spec coverage:** §1 goal → Tasks 2 (160 M10K) + 10 (perf-neutral) + 9 (fit); §4 invariant → structural (WORK untouched, Task 2 keeps RMW on-chip); §5.1 comp_fbram → Task 2; §5.2 snapshot retarget → Task 4; §5.3 demux → Task 3; §5.4 reader un-bridge → Tasks 1+6; §5.5 tear-free fence → Task 5; §6 memory map → Global Constraints + Tasks 4/5/6; §7 validation → Tasks 6/7 (sim), 9 (fit), 10 (HW); §8 risks → the fence (Task 5), FIFO underrun (Task 6 SVA), audit fallback (Task 1), burst-count wedge (Task 4 note); §9 unpin bonus → Task 11. No gaps.

**Placeholder scan:** RTL diffs gated on the Task-1 audit (Task 6) are the only non-verbatim code; they are bounded by the audit's produced interface and carry the concrete fallback (thin adapter) with real file/port names — not a "TBD". All sim/gate steps have exact commands + expected markers.

**Type consistency:** `comp_fbram` WORK ports (`wr_*`/`rd_*`) named identically across Tasks 2/4/8; `snap_done`/`active_buffer`/`` `CTRL_ADDR `` consistent across Tasks 4/5; `scan_addr`/`scn_ok`/`scn_dout` reader handshake consistent across Tasks 1/6/8; `` `FB_DDR0_QW ``/`` `FB_DDR1_QW `` consistent across Tasks 3/4/6.
