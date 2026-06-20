# Faithful SDRAM Contention Sim — reproduce the scanout-wedge deadlock

**Status:** PLAN (2026-06-18). Goal: reproduce, in iverilog, the HW deadlock where the
VRAM scanout reader hard-wedges the SDRAM bus and starves the blitter — then fix the RTL.
Context: memory `fpga-sdram-source-f2h-scanout-contention.md` (2026-06-18 updates).

## Problem (confirmed on HW, +0.046 ns core sha1 965f9d87)

The scanout reader, fetching scanlines from SDRAM (P_SCAN), HARD-WEDGES the instant the
blitter starts compositing FB writes to SDRAM (P_DST). Screen stays BLACK. Mechanism:
scanout VSYNC freezes first, then the (even free-running) blitter freezes — the strict-
priority arbiter (scan>src>dst) lets a wedged scanout lock the bus and starve the blitter.
Only a fabric reset clears it. ALL existing sims pass — they don't model it.

## Why existing sims miss it (the gap)

1. **`tb_blitter_system`** wires the arbiter's `scan_*` port **tied off** (`.scan_rd(1'b0)`)
   — blitter writes P_DST but nothing reads P_SCAN → no scan-vs-blit contention.
2. **`tb_scanout_sdram`** has the real `openbor_video_reader` but a **stubbed SDRAM** for the
   scan fetch (not `sdram_psx`) — the stub likely delivers a whole line per request, hiding
   the beat-protocol mismatch.
3. **`sdram_chip_model.sv`** is explicitly **ZERO-DELAY** ("NOT real-silicon timing — tRCD/
   tRP/tRC/CL margins") — it models refresh *commands* but enforces no timing, so refresh/
   CAS stalls that perturb the handshake never happen.

No sim runs the REAL `sdram_psx` + arbiter + concurrent P_SCAN line-fetch + P_DST blitter
writes under realistic timing — exactly the missing combination.

## Prime suspect (from RTL trace)

- Reader `ST_READ_LINE` asserts `sdram_rd` once, sets `sdram_burst<=80`, then `ST_WAIT_LINE`
  waits for **80** `sdram_dready` beats (`beat_count==LINE_BURST`). It does NOT re-issue
  `sdram_rd` per beat. `openbor_video_reader.sv:651-668`, beat capture `:425-429`,
  `sdram_rd` de-assert `:417` (`if(!sdram_busy) sdram_rd<=0`).
- Arbiter + `sdram_psx` are **`BURST_BEATS=1`**: one 64-bit beat per granted txn, `held_txn`
  released each `c_ready`; `scan_burst` is documented UNUSED (`sdram_src_arb.sv:24-30`).
- So a full line needs 80 grants, but the reader pulses one request. Whether the reader gets
  80 beats depends on `scan_busy`-driven re-request timing — untested, and the seam where a
  refresh/CAS stall (real timing) can drop the reader into a permanent wait (`beat_count`
  stalls < 80, `ST_WAIT_LINE` only advances a timeout that → `ST_IDLE`; meanwhile the held
  grant / owner state vs the blitter's P_DST request may lock).

Confirm the exact stuck state in sim before fixing.

## jtframe assets to use (`../jtcores`, per /misterfpga)

- **`modules/jtframe/hdl/ver/mt48lc16m16a2.v`** — Micron behavioral model of the actual
  MiSTer SDRAM chip: real banks, tRCD/tRP/tRC/CAS, AUTO_REFRESH timing. Standard pins
  (Dq/Addr/Ba/Cs_n/Ras_n/Cas_n/We_n/Dqm/Cke/Clk) — drop in for `sdram_chip_model.sv` behind
  `sdram_psx` (which drives those exact pins, `sdram_psx.sv:54-64`). 32MB/9-col vs our
  64MB/10-col is FINE: geometry is silicon-proven; we only need faithful TIMING, and FB
  (0x400000) + atlas (0x1000000) fit in 32MB. Tie the jt-extra inputs (downloading/VS/
  frame_cnt) to 0.
- **`modules/jtframe/hdl/video/jtframe_lfbuf_sdr_ctrl.v`** — reference line-buffer-from-SDRAM
  controller (the proven discipline our reader mirrors): cross-check how jtframe gates the
  line fetch vs writes / refresh.
- **`modules/jtframe/doc/sdram.md`, `burst_sdram.md`, `sdram_timing.ods`** — timing data.
- **`modules/jtframe/ver/sdram/*`** (e.g. `sdram_bank64`, `burst_sdram_64mb`) — how jtframe
  wires an SDRAM testbench with the Micron model (cadence, refresh, init wait).

## Harness to build: `fpga/sim/tb_vram_contention.sv`

Instantiate the REAL pipeline (mirror `Solarus.sv` wiring):
- `blitter_top` → `vram_demux` → P_DST of `sdram_src_arb`
- `openbor_video_reader` SDRAM scan port → P_SCAN of `sdram_src_arb` (the part `tb_blitter_
  system` tied off) — drive a realistic scanline cadence (new_line/vcount from a tiny video-
  timing stub, or reuse `openbor_video_timing`).
- `sdram_src_arb` → `sdram_psx #(.BURST_BEATS(1))` → **`mt48lc16m16a2`** (NOT
  `sdram_chip_model`).
- DDR side of `vram_demux` + the reader's DDR master → the existing backpressuring DDR stub
  (reuse `tb_blitter_system`'s).

Stimulus: load a command list that composites a full frame to FB (dst→SDRAM) while the reader
scans lines from SDRAM — i.e., both P_SCAN and P_DST active every frame, across several frames
incl. a refresh interval (≥780 cycles). 

Pass/fail: the reader completes every scanline (`beat_count` reaches 80 each line, vsync
writeback advances) AND the blitter completes frames (done_seq advances) for N frames with no
hang. The UNFIXED RTL must HANG here (watchdog `$display` + `$finish` on no-progress) — that
is the reproduction. Add to `run_sims.sh` as gating once it passes post-fix.

## Steps

1. Stand up the harness with `sdram_chip_model` first (should PASS — matches today's green
   sims) to validate wiring.
2. Swap to `mt48lc16m16a2` + enable concurrent P_SCAN. Expect HANG = reproduction. Capture
   the exact stuck signals (owner, held_txn, c_busy/c_ready, scan_busy, beat_count, refresh).
3. Root-cause the stuck state (likely: beat-protocol/`scan_busy` re-request, or refresh-during-
   held-scan, or arbiter owner-lock starving P_DST). Fix in `sdram_src_arb` / reader scan FSM
   / `vram_demux` per the actual finding (candidates: bound the scan hold to its line + yield
   to a pending refresh; ensure P_DST gets serviced between scan lines; writer-gate blitter
   f2h... no — SDRAM-side now).
4. Re-run: harness PASSES with the Micron model. `tb_blitter_system` still PASS.
5. Rebuild RBF; HW retest a scrolling scene (no wedge, no black).

## Notes / risks

- The Micron model is `timescale 1ns/1ps` and uses real delays — the harness must use a
  realistic clock period (sdram clk ~100 MHz / 10 ns) and let init/refresh run. iverilog
  handles `#` delays fine.
- This is the documented sim-clean/HW-broken SDRAM gap (#30). The whole point is the faithful
  TIMING model — do not regress to the zero-delay one for the contention test.
- Keep the timing fix (commit e82f635, +0.046 ns) — orthogonal and correct.
