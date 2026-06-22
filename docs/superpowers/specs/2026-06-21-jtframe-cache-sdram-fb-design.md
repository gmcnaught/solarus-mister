# Design: cached SDRAM framebuffer via jtframe_cache_mux

**Status:** Draft for review
**Date:** 2026-06-21
**Branch (current work):** `feat/jtframe-burst-sdram` (worktree `pipelined-compositor`)
**Supersedes:** the hand-rolled `sdram_burst_arb` controller path (JT-T2…T6) and the
in-flight JT-T7 re-point. Keeps the vendored `jtframe_burst_sdram` stack.

## Context & motivation

The JTFRAME-burst cycle replaced `sdram_psx`+`sdram_src_arb` with a hand-rolled
`sdram_burst_arb` over the vendored `jtframe_burst_sdram` controller to fix the
deferred SDRAM-framebuffer write-refresh livelock. Two problems emerged:

1. **Read capture is timing-fragile (JT-T5).** `jtframe_burst_sdram`'s consumer
   read-data timing (`dout` vs `dst/dok`) varies with post-write state, page
   hit/miss, and async refresh — no fixed downstream capture rule covers it.
2. **The JT-T5b fix is too slow.** Routing through the AUTOPRECH prog path gives
   uniform (correct) read timing, but reads become ≤3 usable words per cold
   command and writes are single-location (~13 cyc/word). System-level
   measurement (`tb_vram_contention`, re-pointed) showed the compositor cannot
   fill a frame within budget — **functionally correct but ~10× too slow**.

**Root cause:** consuming `jtframe_burst_sdram`'s two-stage-pipelined burst IO
correctly *and* fast is hard by hand. Re-vendoring the burst files does not help
(the latest IO pipelining is already in our snapshot and is the *source* of the
asymmetry, added for STA closure).

**Discovery:** upstream jtframe (post-snapshot) has a maintained, validated
**cache subsystem** (`jtframe_cache` v2.2, `jtframe_cache_mux`) that sits on the
same `ext_*` burst-controller port we already drive and **encapsulates the exact
read/write timing we were fighting** — line fills/write-backs are clean, cold,
full-line bursts (uniform timing), captured internally. jtframe's own
`cache+burst_sdram` and `cache_mux/rw` tests **pass under our iverilog** (de-risk
spike already run), proving correct reads, correct write-back, and multi-client
arbitration.

`jtframe_lfbuf` (line framebuffer) was evaluated and rejected: it is single-pass
line rendering with per-line clear and no persistent-FB load, which does not fit
the compositor's load→composite→flush band-RMW model (`comp_dest_band`).

## Goal

Replace `sdram_burst_arb` with `jtframe_cache_mux` (over the existing
`jtframe_burst_sdram`), giving the compositor's three SDRAM clients a fast,
correct, cached interface — fixing both the read-capture correctness and the
throughput, using jtframe's maintained code instead of hand-rolled timing.

## Architecture

```
  scanout reader  (P_SCAN, read-only)  ─┐
  vram_demux SDRAM (P_DST, read+write) ─┤→ jtframe_cache_mux ─ ext_* ─→ jtframe_burst_sdram ─→ SDRAM
  blitter source  (P_SRC, read-only)   ─┘   (per-channel cache)            (already vendored)         + altddio_out SDRAM_CLK
```

`jtframe_cache_mux` replaces `sdram_burst_arb` entirely. It provides per-channel
caches and arbitrates the single `ext_*` SDRAM-controller port. Channels 0–3 are
read/write (each with `flush`/`invalidate`); channels 4+ are read-only.

**Channel assignment:**
- **Channel 0 (R/W): P_DST** — `vram_demux` band load (read) + flush (write).
  Needs the largest cache (band working set) and `flush`/`invalidate` for
  coherency. `wdsn` carries the per-lane byte mask, so vram_demux's partial
  sub-qword writes become ordinary cache writes (the single-location-write hack
  in JT-T6 is removed).
- **Channel 4 (read-only): P_SCAN** — scanout reader. Small cache (streaming;
  the cache here is just a correct burst-read engine, ~1–2 lines).
- **Channel 5 (read-only): P_SRC** — blitter source reads. Small cache.

**Data width:** all channels `DW=64` (clients are 64-bit qwords: `scan_dout64`,
`dst_din64`/`dst_dout64`, `p0_dout64`). The cache bridges `DW=64` ↔ the 16-bit
SDRAM port internally (validated config to confirm in the de-risk; jtframe's own
tests use `DW=16`, so a `DW=64` smoke is part of Task 1).

**Address:** client 27-bit byte addresses map to cache word/qword addresses
(`addr = byte_addr[AW:AW0]`), consistent with the SDRAM FB base. `AW`/`EW` chosen
so the cache's `ext_addr` matches `jtframe_burst_sdram`'s `AW` (the JT-T5b
analysis that `AW=23` gives the correct linear mapping still applies to `ext_*`).

## Data flow

**P_DST band RMW (compositor):** `comp_dest_band` already does the pixel-level
blend-RMW in on-chip BRAM. So the SDRAM only sees sequential **band loads** and
**band flushes**:
- *Load:* the demux issues per-qword reads over channel 0; first access to a line
  misses → cache burst-fills the line from SDRAM (clean, correct); subsequent
  qwords in that line hit (fast). Overlapping blits touching the same band hit.
- *Flush:* composited qwords are written over channel 0 (`wr`/`din`/`wdsn`);
  dirty lines are written back to SDRAM as clean bursts.

**P_SCAN scanout:** sequential per-qword reads over channel 4. Each line is a
cold miss → burst fill (correct, fast) → consumed once. No reuse, so the cache is
purely a correct-burst-read engine here.

**P_SRC source:** per-qword reads over channel 5 (same as scan).

## Coherency (double-buffered framebuffer)

The FB is double-buffered (FB0/FB1 via `vram_demux`). Within a frame the
compositor writes the **back** buffer (P_DST) while scanout reads the **front**
buffer (P_SCAN) — different addresses, no intra-frame conflict. At `vsync` swap:

1. **Flush channel 0** (P_DST): commit all dirty back-buffer lines to SDRAM
   before that buffer becomes the scanout front buffer (`flush0` → wait
   `flush_done0`).
2. **Invalidate channels 0, 4** (and 5 if it aliases the FB): so the next frame
   loads fresh from the swapped buffers rather than returning stale lines cached
   two frames ago.

This runs during vertical blank (ample time). The cache_mux exposes per-channel
`flush`/`invalidate` + `*_done`. We add a **small coherency-sequencer module**
(ours, one always-block per reg) instantiated in `Solarus.sv` next to the
cache_mux: it observes `vs`, then drives `flush0`→wait `flush_done0`→pulse the
channel `invalidate`s, gating new P_DST/P_SCAN traffic until done.

## Integration changes

- **`fpga/Solarus.sv`**: replace the `sdram_burst_arb` instance with
  `jtframe_cache_mux` + `jtframe_burst_sdram` + the `altddio_out` SDRAM_CLK
  forwarder (the forwarder from JT-T6 stays). Wire the coherency sequencer to
  `vsync`.
- **`fpga/rtl/vram_demux.sv`**: drive cache channel 0 (`addr/rd/wr/din/dout/ok/
  wdsn`) instead of `sd_*`. Partial-lane writes → `wdsn`. The `ok` handshake
  replaces `sd_busy`/`sd_dready`. (Simpler than today's burst handshake.)
- **scanout reader / blitter source**: drive read-only channels (per-qword
  `addr/rd/dout/ok`). The reader's burst loop becomes per-qword cache reads
  (the cache turns them into burst fills).
- **`fpga/files.qip`**: add the vendored cache + ram files; remove
  `sdram_burst_arb.sv` (and `sdram_psx.sv`/`sdram_src_arb.sv`, already retired
  from the build list in JT-T6).

## Vendoring

Copy verbatim into `fpga/rtl/jtframe/` (with the existing 2-line provenance
header + PROVENANCE.md entry, GPL preserved), from jtcores
`modules/jtframe/hdl/`:
- `sdram/jtframe_cache.sv`, `jtframe_cache_ctrl.sv`, `jtframe_cache_req.sv`,
  `jtframe_cache_data.sv`, `jtframe_cache_tags.sv`
- `sdram/jtframe_cache_mux.v`, `jtframe_cache_mux_arb.v`,
  `jtframe_cache_mux_flush.v`
- `ram/jtframe_dual_ram.v`, `jtframe_dual_ram16.v`, `jtframe_dual_ram32.v`

Record the jtcores commit hash. The `jtframe_burst_sdram` stack is already
vendored and unchanged.

## What gets removed / superseded

- `fpga/rtl/sdram_burst_arb.sv` — replaced by `jtframe_cache_mux`. Delete after
  the system test passes on the cache path.
- The uncommitted JT-T7 `tb_vram_contention` re-point + `tb_sdram_burst_arb`
  debug probes — revert (dead-end of the AUTOPRECH approach).
- `tb_sdram_burst_arb.sv` — retire (it tested the hand-rolled arb). Its
  intent (3-client read/write/RMW correctness) moves to a new cache-path tb.
- `sdram_psx.sv`/`sdram_src_arb.sv` + their pure-DUT benches — delete (already
  retired from the build in JT-T6).

## Testing & validation

1. **De-risk (Task 1, partly done):** vendor the cache stack; port jtframe's
   `cache+burst_sdram` and `cache_mux/rw` tests into `fpga/sim` + `run_sims.sh`
   and confirm PASS under our iverilog (already passing in the spike). Add a
   `DW=64` smoke (our clients are 64-bit) to confirm that config.
2. **Unit tb (`tb_cache_sdram_fb`):** drive the 3 channels (P_DST band
   load/flush with `wdsn` partial writes + RMW read-back; P_SCAN streaming read;
   P_SRC read) against `jtframe_cache_mux`+`jtframe_burst_sdram`+`mt48lc16m16a2`;
   assert data correctness and a coherency flush/invalidate cycle.
3. **System tb (`tb_vram_contention`, re-pointed + re-gated):** wire the real
   reader + `vram_demux` + compositor to the cache path; assert the FB workload
   **completes within the watchdog** (throughput) and data is correct — the FB
   livelock/throughput proof. Re-gate it (remove from `NONGATING`).
4. **Full suite:** `./run_sims.sh` green; gating-failures=0.
5. **Quartus fit/STA:** CI-only (arm64 host can't run x86 Quartus). BRAM budget
   for the per-channel caches is a fit risk to watch in CI.

## Constraints

- iverilog for local sim; Quartus synth/STA in CI only.
- One always-block per reg/array (Quartus Error 10028) in any RTL *we* write
  (the wrapper/coherency sequencer); vendored files are exempt (do not edit).
- Vendored jtframe files copied verbatim (GPL); regenerate by re-copying.

## Risks & open questions

- **Cache sizing vs BRAM budget.** Per-channel caches consume BRAM; the P_DST
  cache must hold a band's working set without starving Quartus fit. Resolve
  with conservative initial sizes + CI fit feedback. (Open: exact
  `BLOCKS`/`BLKSIZE` per channel.)
- **`DW=64` config.** jtframe's tests use `DW=16`; confirm `DW=64` end-to-end in
  Task 1 before building on it.
- **Coherency sequencing.** Flush-then-invalidate at `vsync` must complete in
  vblank; confirm timing and that no scanout read races an unflushed line.
- **Reader/demux interface adaptation.** Converting the reader's burst loop and
  vram_demux's `sd_*` handshake to the cache `ok` interface is the main
  integration effort; behavior is validated by the system tb.
- **`ext_*` address width.** Confirm the cache `EW`/`AW` ↔ `jtframe_burst_sdram`
  `AW` mapping for our FB addressing (Task 1 smoke with a known address).

## High-level task order

1. De-risk: vendor cache stack + port jtframe cache tests + `DW=64` smoke (gate).
2. Unit tb + the cache wrapper/coherency sequencer (3 channels, flush/invalidate).
3. Solarus integration: swap instance, adapt `vram_demux` + reader + source,
   `files.qip`.
4. Re-point + re-gate `tb_vram_contention`; full suite green.
5. Remove `sdram_burst_arb` + retired benches; revert JT-T7 dead-end.
6. Push / PR / CI fit + STA.
