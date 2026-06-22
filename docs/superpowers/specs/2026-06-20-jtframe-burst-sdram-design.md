# Adopt `jtframe_burst_sdram` as the SDRAM controller

**Date:** 2026-06-20
**Branch:** `feat/jtframe-burst-sdram` (off `master`)
**Status:** Approved design — proceeding to implementation plan

## Summary

Replace the vendored `sdram_psx` SDRAM controller (and its companion
`sdram_src_arb`) with jtframe's **`jtframe_burst_sdram`** full-page burst
controller, fronted by a new small 3-client arbiter/width-bridge
(`sdram_burst_arb`). The rest of the SDRAM path — `vram_demux`, the scanout
reader, and `comp_pipeline` — keeps its existing client interface and does not
change.

This is the strategic fix for the deferred SDRAM-framebuffer burst-write gap (see
`2026-06-20-supersede-legacy-renderer-design.md` Findings). `sdram_psx`'s write
path is single-access with per-beat auto-precharge, which both wastes bandwidth
and livelocks against refresh under the compositor's sustained P_DST burst
writes. `jtframe_burst_sdram` does full-page sequential bursts for reads **and**
writes and owns refresh arbitration internally (deferring refresh during a live
burst), which dissolves that bug class by construction instead of patching it.

## Why jtframe_burst_sdram

- Authored 2026 by Jose Tejada (jtframe author; the de-facto MiSTer SDRAM
  authority); part of the validated `jtframe_sdram64` family.
- **Targets MiSTer / DE10-Nano SDRAM** — the same board and chip class as this
  core — and is validated by dedicated regressions including
  `modules/jtframe/ver/sdram/burst_sdram_64mb` (our 64MB AS4C32M16 class). This
  sharply lowers the HW-only-failure risk that makes a from-scratch rewrite
  unattractive.
- Ships `jtframe_burst_io` — a timing-closed registered pad path (two-stage DDIO
  with `FAST_OUTPUT_REGISTER` / `DONT_RETIME`), i.e. the "better timing data"
  already in silicon-proven form.

## Consumer protocol (what we integrate against)

Single consumer burst port (16-bit words):

```
input  [AW-1:0] addr;  input [1:0] ba;
input           rd, wr;
input  [15:0]   din;   output [15:0] dout;
output          ack;   // burst accepted
output          dst;   // first returned read beat
output          dok;   // each returned read beat
output          rdy;   // burst complete
input           rfsh;  // refresh request pulse (~every 64us)
// + a prog_* download port (tied off here)
```

Full-page sequential: assert `rd`/`wr` to start, hold to continue, drop to stop
at the desired length. Refresh is deferred while an acknowledged burst is in
progress and runs once the burst path is free.

Internal blocks (all vendored): `jtframe_sdram64_init`, `jtframe_sdram64_rfsh`,
`jtframe_burst_mode`, `jtframe_burst_ctrl`, `jtframe_burst_mux`,
`jtframe_sdram64_bank`, `jtframe_burst_io`.

## Architecture

```
scanout (P_SCAN) ┐
demux/FB (P_DST) ├─► sdram_burst_arb ─► jtframe_burst_sdram ─► SDRAM pads
atlas    (P_SRC) ┘   (priority + 16↔64)   (init/rfsh/bank/io)
                              ▲ rfsh ◄── ~64us refresh timer
```

### Components

1. **Vendored jtframe controller.** Copy `jtframe_burst_sdram.v` + the deps
   listed above into `fpga/rtl/jtframe/`, each with a provenance header
   ("VENDORED from jtcores/modules/jtframe/hdl/sdram/...; do not edit here") and
   jtframe GPL-3 attribution. Add all files to `fpga/files.qip`. Pin the upstream
   commit/path in a `fpga/rtl/jtframe/PROVENANCE.md`.

2. **`sdram_burst_arb` (new — the only substantial new RTL).** Presents the
   **same client ports the system already uses** (`scan_*`, `dst_*`, `p0_*` with
   their 64-bit `*_dout64`/`*_dready`/`*_busy` semantics) so `vram_demux`, the
   scanout reader, and `comp_pipeline` are unchanged. Internally it:
   - arbitrates scan > dst > src with **scan-never-starve** priority;
   - **packs 4×16↔64**: a 64-bit qword request becomes a 4-word burst on
     jtframe's 16-bit port; returned `dok` beats are assembled into `*_dout64`
     and strobed on `*_dready`; multi-qword (N-beat) transfers hold `rd`/`wr`
     across `4N` words and drop to stop;
   - drives jtframe's `ack/dst/dok/rdy` handshake;
   - carries **no refresh logic** (jtframe owns it) — replacing
     `sdram_src_arb`'s psx-era `held_txn`/refresh-awareness.

   The arb-boundary decision (deferred to design): **replace `sdram_src_arb`,
   keep its client-facing port shape.** Rationale: jtframe owning refresh makes
   `held_txn`/refresh-awareness dead weight, and the full-page-burst handshake is
   too different from the per-txn `c_*` protocol to bridge cleanly; re-expressing
   only the priority core against jtframe's handshake (and keeping the upstream
   port shape) is cleaner and keeps the blast radius off the demux/scanout/pipe.

3. **Refresh requester.** A small counter producing an `rfsh` pulse ~every 64µs
   (8192 rows / 64ms at the SDRAM clock); jtframe's `_rfsh` does the br/bg
   arbitration against the burst.

4. **`prog` port tied off.** This core writes SDRAM (framebuffers, staged atlas)
   at runtime via the compositor/STAGE path, not via jtframe ROM download.

## Data flow

- **P_SCAN read (line fetch):** arb grants scan, issues a read burst at the line
  base, holds `rd` for the line length, assembles `dok` beats into 64-bit beats
  to the reader, drops `rd` at line end.
- **P_DST RMW (compositor band):** dst read burst (band load) → `*_dout64`
  stream to `vram_demux`/`comp_pipeline`; then dst write burst (band flush):
  64-bit qwords unpacked to 4 `din` words/qword, `wr` held across the band, then
  dropped. Sustained writes no longer livelock — refresh defers to the burst and
  runs in the gap.
- **P_SRC (atlas) read:** same as P_SCAN, lower priority (Phase-2 client; wired
  but exercised when comp_pipeline's SDRAM-source path is enabled).

## Testing

- **Sim (local, iverilog) — gating:**
  - `tb_vram_contention` re-gated as the **primary proof** (FB-in-SDRAM
    compositor vs real P_SCAN; must PASS once bursts+refresh are correct).
  - New `tb_sdram_burst_arb` — unit test of the arb/width-bridge against a
    behavioral jtframe consumer + SDRAM chip model (read/write bursts, 16↔64
    packing, scan-priority, refresh-during-idle vs deferred-during-burst).
  - Retire/replace `tb_sdram_psx` and `tb_sdram_src_arb` (their DUTs are gone);
    fold still-relevant assertions into `tb_sdram_burst_arb`.
  - Keep the full compositor suite (`tb_comp_*`, `tb_blitter_*_pipe`,
    `tb_capture_race`, `tb_vram_demux`, `tb_demux_preempt`, `tb_sdram_stage`,
    `tb_scanout_sdram`) green; adapt any that instantiate `sdram_psx`/
    `sdram_src_arb` directly to the new modules.
  - Port `burst_sdram_64mb`'s read/write-burst expectations where useful (chip
    geometry, post-write read latency).
- **HW / CI:** Quartus `build-windows` for fit + STA (validate the
  `jtframe_burst_io` floorplan within this project; adjust/relax LOCs if Fitter
  flags them), then on-device bring-up.

## Staging

- **Phase 1 (this spec/plan):** vendor jtframe controller + `sdram_burst_arb` +
  refresh requester; wire into `Solarus.sv` replacing `sdram_psx`/`sdram_src_arb`;
  sim-validate (contention test green, compositor suite green).
- **Phase 2 (follow-on):** CI fit/STA closure + on-device validation; tune
  refresh interval / burst lengths / IO floorplan as STA requires.

## Risks

- **Shared SDRAM controller swap with HW-only failure modes.** Mitigated:
  jtframe targets our exact board/chip and is upstream-validated (incl. 64MB);
  STA via CI; on-device bring-up is an explicit Phase-2 gate.
- **16↔64 packing + post-write read latency** is the subtle correctness area
  (the jtframe doc flags read-after-write alignment of `ack`/`dok`/data). The arb
  unit test must cover RMW (write then immediate read of the same band) directly.
- **Floorplan LOCs in `jtframe_burst_io`** are jtframe-project coordinates; may
  need relaxing for this project's Fitter. STA-gated in CI.
- `comp_pipeline`, `vram_demux`, and the scanout reader are not modified
  (client-port shape preserved), bounding the blast radius.

## Acceptance criteria

1. `sdram_psx` and `sdram_src_arb` removed; `jtframe_burst_sdram` + deps vendored
   with provenance; `sdram_burst_arb` presents the existing client ports.
2. `Solarus.sv` instantiates the new SDRAM path; demux/scanout/compositor
   unchanged.
3. `tb_vram_contention` PASSES and is re-gated; `tb_sdram_burst_arb` passes;
   full compositor suite green; obsolete psx/src_arb benches removed.
4. CI `build-rbf.yml` (`build-windows`) fits + STA-clean (Phase-2 gate).
5. On-device validation of the SDRAM-framebuffer compositor path (Phase-2 gate).
