# Cached SDRAM Framebuffer (jtframe_cache_mux) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hand-rolled `sdram_burst_arb` with jtframe's maintained `jtframe_cache_mux` (over the already-vendored `jtframe_burst_sdram`) so the compositor's SDRAM framebuffer path is fast *and* correct, using jtframe code that already solves the burst read/write timing.

**Architecture:** Vendor the jtframe cache stack. Build one wrapper `sdram_fb_cache.sv` = `jtframe_cache_mux` (ch0 R/W = P_DST, ch4 = P_SCAN, ch5 = P_SRC, all `DW=64`) + `jtframe_burst_sdram` + `altddio_out` SDRAM_CLK forwarder + refresh timer + a small coherency sequencer (flush/invalidate at `vs`). Adapt `vram_demux`/reader/blitter-source to the cache `addr/rd/wr/din/dout/ok/wdsn` interface. Swap it into `Solarus.sv`; prove it on `tb_vram_contention`.

**Tech Stack:** SystemVerilog/Verilog, Icarus Verilog (iverilog/vvp) for local sim, `fpga/sim/run_sims.sh` runner, Micron `mt48lc16m16a2` chip model, Quartus (CI-only) for synth/STA.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-06-21-jtframe-cache-sdram-fb-design.md`.
- Branch `feat/jtframe-burst-sdram`, worktree `/Users/gmcnaught/MisterFPGA-Projects/solarus-mister/.claude/worktrees/pipelined-compositor`. All sim commands run from `fpga/sim`.
- iverilog for local sim; Quartus synth/STA is CI-only (arm64 host can't run x86 Quartus).
- One always-block per reg/array in RTL **we** write (Quartus Error 10028; iverilog won't catch it). Vendored `jtframe/*` files are copied **verbatim** — never hand-edit (GPL; regenerate by re-copying).
- jtcores source of truth: `/Users/gmcnaught/MisterFPGA-Projects/jtcores` (record `git rev-parse HEAD` in PROVENANCE.md when vendoring).
- Commit early/often in the worktree. Commit trailer for every commit:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01FpTCVxaYXyhnSKcHFkuMky
  ```
- Keep the full suite green at each task boundary except where a task explicitly notes a transient red (Task 8 cleanup). `tb_vram_contention` stays NON-GATING until Task 7 re-gates it.
- DE-RISK GATE (Task 1): if the cache stack cannot simulate under iverilog at `DW=64`, STOP and surface to the human partner before any integration.

---

### Task 1: De-risk gate — vendor the cache stack and prove it simulates (incl. DW=64)

**Files:**
- Create (vendored, verbatim): `fpga/rtl/jtframe/jtframe_cache.sv`, `jtframe_cache_ctrl.sv`, `jtframe_cache_req.sv`, `jtframe_cache_data.sv`, `jtframe_cache_tags.sv`, `jtframe_cache_mux.v`, `jtframe_cache_mux_arb.v`, `jtframe_cache_mux_flush.v`, `jtframe_dual_ram.v`, `jtframe_dual_ram16.v`, `jtframe_dual_ram32.v`
- Modify: `fpga/rtl/jtframe/PROVENANCE.md`
- Create (test): `fpga/sim/tb_jtframe_cache_smoke.sv`

**Interfaces:**
- Consumes: vendored `jtframe_burst_sdram` (already present) consumer port `addr/ba/rd/wr/din/dout[15:0]/ack/dst/dok/rdy`, and `mt48lc16m16a2` (already in `fpga/sim`).
- Produces: a vendored, iverilog-simulatable `jtframe_cache` + `jtframe_cache_mux`, and the answer to "does the cache stack simulate at `DW=64` under iverilog?" — the gate for everything else.

- [ ] **Step 1: Vendor the cache + ram files with provenance**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister/.claude/worktrees/pipelined-compositor
JT=/Users/gmcnaught/MisterFPGA-Projects/jtcores/modules/jtframe/hdl
for f in jtframe_cache jtframe_cache_ctrl jtframe_cache_req jtframe_cache_data jtframe_cache_tags; do cp "$JT/sdram/$f.sv" fpga/rtl/jtframe/; done
for f in jtframe_cache_mux jtframe_cache_mux_arb jtframe_cache_mux_flush; do cp "$JT/sdram/$f.v" fpga/rtl/jtframe/; done
for f in jtframe_dual_ram jtframe_dual_ram16 jtframe_dual_ram32; do cp "$JT/ram/$f.v" fpga/rtl/jtframe/; done
( cd /Users/gmcnaught/MisterFPGA-Projects/jtcores && git rev-parse HEAD )   # record in PROVENANCE.md
```
Prepend each copied file with the existing 2-line provenance comment style (see the burst files for the exact format). Append the 11 files + the recorded jtcores commit hash to `PROVENANCE.md` with "regenerate by re-copying; do not hand-edit."

- [ ] **Step 2: Elaborate the cache stack under iverilog (no missing modules)**

Run:
```bash
cd fpga/sim && iverilog -g2012 -t null -y ../rtl/jtframe -Y .v -Y .sv ../rtl/jtframe/jtframe_cache_mux.v 2>&1 | head
```
Expected: clean (no "Unknown module type"). If a module is missing, vendor it from jtcores and add to PROVENANCE.

- [ ] **Step 3: Write the failing smoke tb — write then read through the cache at DW=64**

Create `fpga/sim/tb_jtframe_cache_smoke.sv`. Instantiate ONE `jtframe_cache` (params `BLOCKS=2, BLKSIZE=64, AW=23, DW=64, EW=23`) → `ext_*` → `jtframe_burst_sdram #(.AW(22),.HF(1),.MISTER(0),.PROG_LEN(64))` → `mt48lc16m16a2`. Clock as in `tb_sdram_burst_arb.sv` (`clk_sdram` leads `clk` by 5 ns; mt48 on `clk_sdram`). Drive an internal `rfsh` pulse off a small counter (period 256). After `init` deasserts:
  - WRITE: pulse `wr=1` with `addr=A0`, `din=64'hCAFEBABE_0BADF00D`, `wdsn=8'h00` (write all bytes); wait `ok`; drop `wr`.
  - READ-BACK (same line, hit): pulse `rd=1` `addr=A0`; wait `ok`; assert `dout == 64'hCAFEBABE_0BADF00D`.
  - READ a different line (miss → fill) at `addr=A1` and assert it round-trips a value written there first.
  - Partial write: `wr=1 addr=A0 din=...AA.. wdsn` masking some lanes; read back; assert only unmasked bytes changed.
Print `RESULT: PASS` on success, `RESULT: FAIL — <detail>` otherwise. Add a `#<timeout> $display("RESULT: FAIL — timeout"); $finish;` safety initial.

Note the `wdsn` polarity from jtframe usage (jtframe_dwnld treats prog mask as the byte-select; in the cache, `wdsn[i]` selects byte lane `i`). The smoke's partial-write assertion pins the polarity empirically — document it in a tb comment for Task 3.

- [ ] **Step 4: Run it and watch it fail (module under test absent from build list / assertion)**

Run: `cd fpga/sim && ./run_sims.sh tb_jtframe_cache_smoke`
Expected: BUILD or FAIL (the cache files resolve via `-y ../rtl/jtframe`; first failure is most likely the `wdsn` polarity or address mapping in the tb itself).

- [ ] **Step 5: Iterate the tb until the round-trip passes**

Fix tb-side issues only (addressing, `wdsn` polarity, handshake: pulse `rd`/`wr` on a rising edge, wait `ok`). Do **not** edit vendored files.
Run: `cd fpga/sim && ./run_sims.sh tb_jtframe_cache_smoke`
Expected: `RESULT: PASS`.

**DECISION GATE:** If the cache stack cannot be made to round-trip at `DW=64` under iverilog (vendored-as-is), STOP and surface to the human partner (options: `DW=16` cache with packing in our wrapper, or reconsider). Do not proceed.

- [ ] **Step 6: Port jtframe's own cache tests as regression smokes (optional but recommended)**

Confirm jtframe's `cache_burst_sdram` and `cache_mux/rw` tests still pass in our tree (they passed in the de-risk spike). Either copy their `test.v` as `fpga/sim/tb_jtframe_cache_rw.sv` (adjusting the `mt48` path to our vendored copy and `test_tasks.vh` include) or document the exact upstream command used. Add `tb_jtframe_cache_smoke` (and the port, if added) to `run_sims.sh` with `pass_re` default (`RESULT: PASS`).

- [ ] **Step 7: Commit**

```bash
git add fpga/rtl/jtframe/ fpga/sim/tb_jtframe_cache_smoke.sv fpga/sim/run_sims.sh
git commit -F - <<'EOF'
vendor(jtframe): cache + cache_mux + dual_ram; DW=64 iverilog smoke (gate)
<trailer>
EOF
```

---

### Task 2: `sdram_fb_cache` wrapper + coherency sequencer + unit test

**Files:**
- Create: `fpga/rtl/sdram_fb_cache.sv`
- Create (test): `fpga/sim/tb_sdram_fb_cache.sv`

**Interfaces:**
- Consumes: `jtframe_cache_mux`, `jtframe_burst_sdram`, `altddio_out` (stub `fpga/sim/altddio_out_stub.sv` exists for sim), `mt48lc16m16a2`.
- Produces: module `sdram_fb_cache` with ports:
  - `clk, rst`
  - P_DST (ch0, R/W): `dst_addr[26:0], dst_rd, dst_wr, dst_din[63:0], dst_wdsn[7:0], dst_dout[63:0], dst_ok`
  - P_SCAN (ch4, read-only): `scan_addr[26:0], scan_rd, scan_dout[63:0], scan_ok`
  - P_SRC (ch5, read-only): `p0_addr[26:0], p0_rd, p0_dout[63:0], p0_ok`
  - Coherency: `vs` (input, frame swap), `coh_busy` (output, high during flush/invalidate)
  - SDRAM pins: `sdram_dq[15:0] (inout), sdram_a[12:0], sdram_dqml, sdram_dqmh, sdram_ba[1:0], sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke, sdram_clk`

- [ ] **Step 1: Write the failing unit test**

Create `fpga/sim/tb_sdram_fb_cache.sv`: `sdram_fb_cache` + `mt48lc16m16a2` (clock as in Task 1). Tasks:
  - T1 (P_DST band RMW): write 8 distinct qwords over `dst_*` to consecutive addresses (full `wdsn=0`), read them back over `dst_*`, assert equality.
  - T2 (P_DST partial write): write a qword with `dst_wdsn` masking 2 lanes, read back, assert only unmasked lanes changed.
  - T3 (P_SCAN read): preload SDRAM (direct `Bank` array write, jtframe read-test method), read via `scan_*`, assert.
  - T4 (P_SRC read): same via `p0_*`.
  - T5 (coherency): write dirty qwords over `dst_*`, pulse `vs`, wait `!coh_busy`; then read the SAME addresses back through a *cold* cache (the invalidate forced eviction; the flush committed them to SDRAM) and assert the values are the just-written ones (proves flush happened before invalidate).
Print `RESULT: PASS`/`FAIL`.

- [ ] **Step 2: Run, verify it fails (module missing)**

Run: `cd fpga/sim && ./run_sims.sh tb_sdram_fb_cache`
Expected: build error / FAIL (`sdram_fb_cache` not found).

- [ ] **Step 3: Implement `sdram_fb_cache.sv`**

Instantiate `jtframe_cache_mux` with: ch0 `DW=64` R/W (dst), ch4 `DW=64` read-only (scan), ch5 `DW=64` read-only (p0); `SDRAM_AW` matching `jtframe_burst_sdram` `AW`; per-channel `BLOCKS`/`BLKSIZE` from the spec's conservative defaults (start `BLOCKS0=8,BLKSIZE0=1024` for dst; `BLOCKS=2,BLKSIZE=256` for scan/p0 — note these in a comment as CI-fit-tunable). Map each client `addr[26:0]` byte address to the channel `addr[AW-1:AW0]` (qword address) and the channel bank via the FB addressing. Wire the single `ext_*` port to `jtframe_burst_sdram` (tie its `prog_*` off; drive `rfsh` from an internal counter — copy the `RFSH_PERIOD`/`hcnt` timer pattern from the old `sdram_burst_arb.sv`). Add the `altddio_out` SDRAM_CLK forwarder (copy from `Solarus.sv` JT-T6). One always-block per reg.

Coherency sequencer (in the same file, its own always-block per reg): a small FSM on `vs` rising edge → assert `flush0` until `flush_done0` → pulse `invalidate0`/`invalidate4`(/5) → `coh_busy` high throughout, low when done. Gate is observed by clients via `coh_busy` (they hold off new requests while high; the tb models this).

- [ ] **Step 4: Run the unit test until green**

Run: `cd fpga/sim && ./run_sims.sh tb_sdram_fb_cache`
Expected: `RESULT: PASS` (T1–T5). Use a `-DDEBUG_FB_CACHE` cycle trace if the coherency timing needs tuning.

- [ ] **Step 5: Add to the suite and commit**

Add `tb_sdram_fb_cache` to `run_sims.sh`.
```bash
git add fpga/rtl/sdram_fb_cache.sv fpga/sim/tb_sdram_fb_cache.sv fpga/sim/run_sims.sh
git commit -F - <<'EOF'
feat(sdram): sdram_fb_cache wrapper (cache_mux 3ch + coherency) + unit test
<trailer>
EOF
```

---

### Task 3: Adapt `vram_demux` to the P_DST cache channel

**Files:**
- Modify: `fpga/rtl/vram_demux.sv` (SDRAM-side outputs `sd_*`)
- Test: `fpga/sim/tb_vram_demux.sv` (update the behavioral SDRAM model it asserts against)

**Interfaces:**
- Consumes: `sdram_fb_cache` P_DST port (`dst_addr/dst_rd/dst_wr/dst_din[63:0]/dst_wdsn[7:0]/dst_dout[63:0]/dst_ok`).
- Produces: a `vram_demux` whose SDRAM side speaks the cache `ok` interface: `sd_addr, sd_rd, sd_wr, sd_din64[63:0], sd_wdsn[7:0], sd_dout64[63:0], sd_ok` (replacing `sd_we`/`sd_we_burst`/`sd_din`/`sd_busy`/`sd_dready`).

- [ ] **Step 1: Update the tb's SDRAM model to the cache `ok` protocol**

In `tb_vram_demux.sv`, replace the behavioral `sdram_src_arb`-protocol model (which modeled `sd_busy`/`sd_dready` accept) with a cache-`ok` model: on `sd_rd|sd_wr` rising, after a fixed latency assert `sd_ok` for one cycle with read data for reads; honor `sd_wdsn` byte lanes for writes; store into a local mem array for round-trip assertions. Update the existing partial-write and read-burst test cases to drive/expect the new protocol.

- [ ] **Step 2: Run, verify it fails (vram_demux still drives old `sd_*`)**

Run: `cd fpga/sim && ./run_sims.sh tb_vram_demux`
Expected: FAIL (port/protocol mismatch).

- [ ] **Step 3: Re-target `vram_demux` SDRAM side to the cache interface**

In `vram_demux.sv`: replace the `S_IDLE/S_WLANES/S_BWAIT/S_RDLAT/S_RDISS` `sd_we`/`sd_we_burst`/`sd_busy`-driven FSM with cache requests:
  - Full or partial FB write → `sd_wr=1`, `sd_addr=qword addr`, `sd_din64=blt_din`, `sd_wdsn` = inverse of the enabled-lane mask expanded to bytes (each 16-bit lane → 2 byte-selects); hold until `sd_ok`. Partial lanes are now ONE write with `sd_wdsn` (no per-lane serialization — delete `S_WLANES`).
  - FB read beat → `sd_rd=1`, `sd_addr=rd_cur_byte qword addr`; capture `sd_dout64` on `sd_ok`; advance per beat as today.
  - `blt_busy`/`blt_dout_ready` derive from `sd_ok`/in-flight instead of `sd_busy`/`sd_dready`.
Keep one always-block per reg.

- [ ] **Step 4: Run until green**

Run: `cd fpga/sim && ./run_sims.sh tb_vram_demux`
Expected: `RESULT: PASS` (or the tb's pass marker).

- [ ] **Step 5: Commit**

```bash
git add fpga/rtl/vram_demux.sv fpga/sim/tb_vram_demux.sv
git commit -F - <<'EOF'
feat(vram_demux): drive P_DST cache channel (ok/wdsn) instead of sd_we burst
<trailer>
EOF
```

---

### Task 4: Adapt the scanout reader (P_SCAN) to a read-only cache channel

**Files:**
- Modify: `fpga/rtl/openbor_video_reader.sv` (the SDRAM scan master: `sdram_addr/sdram_rd/sdram_burst/sdram_busy/sdram_dout64/sdram_dready`)
- Test: `fpga/sim/tb_scanout_sdram.sv` (update its SDRAM model to the cache `ok` protocol)

**Interfaces:**
- Consumes: `sdram_fb_cache` P_SCAN port (`scan_addr/scan_rd/scan_dout[63:0]/scan_ok`).
- Produces: a reader whose SDRAM line-fetch issues per-qword cache reads (`scan_rd` + `scan_addr`, capture `scan_dout` on `scan_ok`) instead of a `scan_burst` burst with `scan_dready` beats.

- [ ] **Step 1: Update `tb_scanout_sdram` SDRAM model to the cache `ok` protocol**

Replace the burst-arb model with a cache-`ok` line source: on `scan_rd` rising at `scan_addr`, after a fixed latency assert `scan_ok` with the preloaded line qword; the reader walks addresses per qword. Keep the existing line-content assertions.

- [ ] **Step 2: Run, verify it fails**

Run: `cd fpga/sim && ./run_sims.sh tb_scanout_sdram`
Expected: FAIL (protocol mismatch).

- [ ] **Step 3: Re-target the reader's SDRAM line fetch to per-qword cache reads**

In `openbor_video_reader.sv`, replace the `sdram_burst`+`sdram_dready`-beat loop with: per line, walk `scan_addr` over the line's qwords, `scan_rd=1`, capture `scan_dout` on `scan_ok` into the line FIFO/buffer, advance; `sdram_busy`-equivalent backpressure derives from `scan_ok`/in-flight. (The cache turns these per-qword reads into burst fills internally.) One always-block per reg.

- [ ] **Step 4: Run until green**

Run: `cd fpga/sim && ./run_sims.sh tb_scanout_sdram`
Expected: pass marker.

- [ ] **Step 5: Commit**

```bash
git add fpga/rtl/openbor_video_reader.sv fpga/sim/tb_scanout_sdram.sv
git commit -F - <<'EOF'
feat(reader): P_SCAN line fetch via per-qword cache reads (ok) over scan channel
<trailer>
EOF
```

---

### Task 5: Adapt the blitter source (P_SRC) to a read-only cache channel

**Files:**
- Modify: `fpga/rtl/blitter_top.sv` (or the source-read submodule driving `src_sdram_*`)
- Test: the relevant blitter source tb (`tb_blitter_system_pipe.sv` exercises `src_sdram_*` against the SDRAM model — update its model to the cache `ok` protocol)

**Interfaces:**
- Consumes: `sdram_fb_cache` P_SRC port (`p0_addr/p0_rd/p0_dout[63:0]/p0_ok`).
- Produces: blitter source reads issuing per-qword cache reads (`p0_rd`+`p0_addr`, capture `p0_dout` on `p0_ok`).

- [ ] **Step 1: Update the blitter-source tb's SDRAM model to the cache `ok` protocol**

In `tb_blitter_system_pipe.sv`, replace the `sdram_src_arb`+`sdram_psx` P_SRC model with a cache-`ok` source for `src_sdram_*`. Keep the source-pixel assertions.

- [ ] **Step 2: Run, verify it fails**

Run: `cd fpga/sim && ./run_sims.sh tb_blitter_system_pipe`
Expected: FAIL (protocol mismatch on the source path).

- [ ] **Step 3: Re-target the blitter source read to per-qword cache reads**

Drive `p0_rd`/`p0_addr`, capture `p0_dout` on `p0_ok`; `src_sdram_busy` derives from `p0_ok`/in-flight. (Staging writes that previously went to P_SRC `we`/`we_burst` are no longer needed — the FB write path is P_DST via the cache; confirm the blitter's staging-write usage and remove or re-route per its current behavior.) One always-block per reg.

- [ ] **Step 4: Run until green**

Run: `cd fpga/sim && ./run_sims.sh tb_blitter_system_pipe`
Expected: pass marker.

- [ ] **Step 5: Commit**

```bash
git add fpga/rtl/blitter_top.sv fpga/sim/tb_blitter_system_pipe.sv
git commit -F - <<'EOF'
feat(blitter): P_SRC source reads via per-qword cache reads (ok) over p0 channel
<trailer>
EOF
```

---

### Task 6: Wire `sdram_fb_cache` into `Solarus.sv`; whole-core elaborate

**Files:**
- Modify: `fpga/Solarus.sv` (the SDRAM block + the `vram_demux`/reader/blitter nets)
- Modify: `fpga/files.qip`

**Interfaces:**
- Consumes: `sdram_fb_cache` (Task 2) + the adapted `vram_demux`/reader/blitter (Tasks 3–5).
- Produces: a `Solarus.sv` whose SDRAM path is `sdram_fb_cache`; `SDRAM_*` pins preserved.

- [ ] **Step 1: Replace the instantiation**

Swap the current `sdram_burst_arb src_arb (...)` block for one `sdram_fb_cache` instance: wire `dst_*` from `vram_demux`, `scan_*` from the reader, `p0_*` from the blitter source, `vs` from the video timing (the frame-swap signal already present), and the `SDRAM_*`/`SDRAM_CLK` pins. Remove the now-dead intermediate nets. Keep `clk_sys`/`RESET`/`clk_sdram` usage (the wrapper's altddio uses `clk_sdram`).

- [ ] **Step 2: Update `files.qip`**

Add `rtl/sdram_fb_cache.sv` + the 11 vendored cache/ram files (`VERILOG_FILE` for `.v`, `SYSTEMVERILOG_FILE` for `.sv`). Remove `rtl/sdram_burst_arb.sv`. Keep `SEARCH_PATH rtl/jtframe`.

- [ ] **Step 3: Whole-core elaborate (SDRAM-path soundness)**

Run:
```bash
cd fpga/sim && printf '`define BUILD_DATE "JTC"\n' > /tmp/build_id.v
iverilog -g2012 -o /tmp/sol.vvp -I /tmp -I ../rtl -I ../rtl/jtframe -I ../sys -y ../rtl -y ../rtl/jtframe -y ../sys -Y .sv -Y .v ../Solarus.sv 2>&1 | grep -iE "sdram|cache|fb_cache|port|undeclared|unknown module" | head
```
Expected: **no SDRAM/cache-path errors** (only pre-existing vendor primitives `lcell/altddio_out/pll/dcfifo/cos` remain "missing" — same as JT-T6). Fix any wiring mismatches.

- [ ] **Step 4: Commit**

```bash
git add fpga/Solarus.sv fpga/files.qip
git commit -F - <<'EOF'
feat(sdram): wire sdram_fb_cache into Solarus; drop sdram_burst_arb instance
<trailer>
EOF
```

---

### Task 7: Re-point + re-gate `tb_vram_contention`; full suite green

**Files:**
- Modify: `fpga/sim/tb_vram_contention.sv`
- Modify: `fpga/sim/run_sims.sh`

**Interfaces:**
- Consumes: the full integrated path (`sdram_fb_cache` + adapted clients).
- Produces: a GATING `tb_vram_contention` that proves the FB workload completes (throughput) and is correct, plus a green suite.

- [ ] **Step 1: Re-point the tb to `sdram_fb_cache`**

Revert the JT-T7 dead-end edits first (`git checkout` the JT-T7 changes to `tb_vram_contention.sv`/`tb_sdram_burst_arb.sv` if still uncommitted), then replace the `sdram_src_arb`+`sdram_psx` (or any `sdram_burst_arb`) instantiation with one `sdram_fb_cache` driven by the real reader + `vram_demux` + blitter source + `mt48lc16m16a2` (clock as in Task 1; `vs` from the tb's frame timing). Update the heartbeat/wedge `$display`s to `sdram_fb_cache`/cache internals (remove dangling `sps.*`/`src_arb.c_*` refs).

- [ ] **Step 2: Run it — the FB workload must complete (no wedge)**

Run: `cd fpga/sim && ./run_sims.sh tb_vram_contention`
Expected: pass marker, **lines_done advances and no WEDGE** (the throughput fix — cache hits + burst fills/flushes, vs the AUTOPRECH 10× slowdown). If it wedges, capture the `-DJTT7_DIAG`-style trace and debug (likely coherency-flush timing or a cache sizing too small for the band working set — bump `BLOCKS0`/`BLKSIZE0` in `sdram_fb_cache`).

- [ ] **Step 3: Re-gate it and run the full suite**

In `run_sims.sh`, set `NONGATING=""` (remove `tb_vram_contention`). Update the "deferred sdram_psx livelock / NON-GATING" note in `tb_vram_contention.sv`'s header (the livelock is gone — cache path).
Run: `cd fpga/sim && ./run_sims.sh`
Expected: `RESULT: PASS`, gating-failures=0, **including `tb_vram_contention`**.

- [ ] **Step 4: Commit**

```bash
git add fpga/sim/tb_vram_contention.sv fpga/sim/run_sims.sh
git commit -F - <<'EOF'
test(sdram): re-point + re-gate tb_vram_contention on sdram_fb_cache (FB proof)
<trailer>
EOF
```

---

### Task 8: Cleanup — retire `sdram_burst_arb`, `sdram_psx`, `sdram_src_arb` + their benches

**Files:**
- Delete: `fpga/rtl/sdram_burst_arb.sv`, `fpga/rtl/sdram_psx.sv`, `fpga/rtl/sdram_src_arb.sv`
- Delete: `fpga/sim/tb_sdram_burst_arb.sv`, `tb_sdram_psx.sv`, `tb_sdram_src_arb.sv`, `tb_sdram_src_arb_beatloss.sv`, `tb_sdram_sweep.sv`, `tb_sdram_ctrl.sv`
- Modify: any remaining tb still referencing the deleted modules (`tb_sdram_stage.sv`, `tb_capture_race.sv`, `tb_demux_preempt.sv` — re-point to `sdram_fb_cache` or delete if purely a retired-DUT unit test)
- Modify: `fpga/sim/run_sims.sh` (drop deleted benches from lists/`timeout_s`)

**Interfaces:** none new — pure removal.

- [ ] **Step 1: Identify remaining references**

Run: `grep -rln "sdram_burst_arb\|sdram_psx\|sdram_src_arb" fpga/sim fpga/rtl`
For each integration tb that still instantiates a deleted module, re-point to `sdram_fb_cache` (mirror Task 7) or delete if it is purely a retired-DUT unit test.

- [ ] **Step 2: Delete retired RTL + pure-DUT benches**

```bash
git rm fpga/rtl/sdram_burst_arb.sv fpga/rtl/sdram_psx.sv fpga/rtl/sdram_src_arb.sv \
       fpga/sim/tb_sdram_burst_arb.sv fpga/sim/tb_sdram_psx.sv fpga/sim/tb_sdram_src_arb.sv \
       fpga/sim/tb_sdram_src_arb_beatloss.sv fpga/sim/tb_sdram_sweep.sv fpga/sim/tb_sdram_ctrl.sv
```
Remove their entries from `run_sims.sh` (`SKIP`/`NONGATING`/`timeout_s`/`defines_for`/`pass_re`).

- [ ] **Step 3: Full suite green after removal**

Run: `cd fpga/sim && ./run_sims.sh`
Expected: `RESULT: PASS`, gating-failures=0, no build errors from dangling references.

- [ ] **Step 4: Commit**

```bash
git add -A fpga/sim/run_sims.sh fpga/rtl fpga/sim
git commit -F - <<'EOF'
chore(sdram): retire sdram_burst_arb/sdram_psx/sdram_src_arb + their benches
<trailer>
EOF
```

---

### Task 9: Push, open PR, CI fit/STA

**Files:** none (CI).

- [ ] **Step 1: Verify the suite one final time**

Run: `cd fpga/sim && ./run_sims.sh`
Expected: `RESULT: PASS`, gating-failures=0.

- [ ] **Step 2: Push and open the PR**

Push `feat/jtframe-burst-sdram`; open a PR summarizing: cache-based SDRAM FB (jtframe_cache_mux) replacing the hand-rolled arb; the JT-T5b throughput finding that motivated it; the de-risk evidence; `tb_vram_contention` re-gated as the FB proof. PR body trailer:
```
🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

- [ ] **Step 3: Watch CI for Quartus fit + STA**

CI runs Quartus (synth/fit/STA) which the arm64 host cannot. Watch for: BRAM over-budget (the per-channel caches — tune `BLOCKS`/`BLKSIZE` down if fit fails) and SDRAM IO STA closure (the jtframe burst IO is designed for it; confirm). Address findings; re-run.

---

## Self-Review notes (coverage)

- Spec "Vendoring" → Task 1. "Architecture / channel map / DW=64 / coherency" → Tasks 1–2. "Integration changes (vram_demux/reader/blitter/Solarus/files.qip)" → Tasks 3–6. "Coherency at swap" → Task 2 (sequencer) + Task 7 (system proof). "Testing & validation" → Tasks 1,2,7 + per-task tbs. "What gets removed/superseded" → Task 8 (+ revert dead-end in Task 7 Step 1). "Risks: cache sizing" → Task 7 Step 2 / Task 9 Step 3; "DW=64" → Task 1 gate; "reader/demux adaptation" → Tasks 3–5; "ext_* address width" → Task 1 Step 3 + Task 2 Step 3.
- Open design parameters deliberately deferred to implementation/CI: exact per-channel `BLOCKS`/`BLKSIZE` (Task 2 defaults, Task 7/9 tune), `wdsn` byte polarity (pinned empirically in Task 1 Step 3).
