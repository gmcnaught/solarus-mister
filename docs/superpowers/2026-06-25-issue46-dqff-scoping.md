# #46 64px seam — dq_ff fix scoping (onto current jtframe controller)

**Date:** 2026-06-25  **Base:** master `4830dff` (single-pipeline)
**Supersedes the targeting of:** `docs/superpowers/plans/2026-06-19-dqff-latency-robust-blitter.md`
(that plan targets the retired `sdram_psx` + direct-blitter-read architecture; the controller
is now `jtframe_burst_sdram` behind `jtframe_cache_mux`, so the plan's *file map* is stale —
its *concept* (robust DQ capture + honest SDC) still applies).

## Root cause (confirmed this session — see [[fpga-46-seam-sdram-burst-timing]])
64px vertical seams at exactly x=64,128,192,256 (every 16 qw = 64 SDRAM words = the active
read-burst granularity). Content-independent (visible on black), **dotted** (only some rows per
column) = marginal/metastable capture. Refuted: PROG_LEN (no-op, prog path tied off) and
COMP_MAXBURST (real change, seam unmoved → not the compositor). Logic is sim-clean
(`tb_scan_qworddup` real cache+SDRAM PASS) ⇒ **timing**. STA shows SDRAM_CLK setup +15.5ns
(passes) because the #44 multicycle-2 masks it.

**Mechanism:** SDRAM_CLK is DDIO-forwarded and takes ~12ns to reach the chip pin (`Solarus.sdc`
read-capture comment), so DQ returns ~1 full period (~10.16ns) late. The jtframe bank model
(`jtframe_sdram64_bank.v:88`, `DST = READ + (SHIFTED?1:2)`, here **SHIFTED=0 ⇒ DST=READ+2**)
times `dst`/`dok` at a FIXED offset from READ. For back-to-back beats the DQ stream flows and the
IOB capture (`jtframe_burst_io.v:180 dout <= sdram_dq`) tracks fine; for the **first beat after a
burst (re)start** the DQ bus transitions Hi-Z→driven and that first beat's setup at the IOB FF —
given the ~12ns forward skew — is marginal, yet `dok` says "valid" at the fixed DST=READ+2. The
multicycle-2 keeps STA happy. → one corrupt qword at every burst boundary = the 64px dotted seam.

## What is ALREADY in place (do NOT re-do)
- `fpga/sys/sys.tcl:97` — `FAST_INPUT_REGISTER ON -to SDRAM_DQ[*]` (IOB input capture already requested).
- `fpga/rtl/jtframe/jtframe_burst_io.v:180` — `dout <= sdram_dq` (the single capture flop; output
  side already two-stage IOB-packed via FAST_OUTPUT_REGISTER, input side is the plain flop).
- `fpga/Solarus.sdc` ~line 81-100 — the #44 keeper "mask": `set_multicycle_path SDRAM_CLK→clk_sys
  -setup -end 2 / -hold -end 1`. **This is the mask to remove once capture is robust.**
- Dedicated phase-shifted `clk_sdram` (PLL general[3], phase 5079) forwards SDRAM_CLK via DDIO
  (`sdram_fb_cache.sv:503-520`) — "fallback C". `jtframe_burst_sdram.v:204 .SHIFTED(0)`.

## Fix options

### Option A (recommended, targeted): +1 internal capture stage + aligned model + honest SDC
Add a SECOND register after the IOB capture so the long IOB(pads X50_Y0)→controller(X46_Y19) hop
gets a full clean reg→reg cycle (symmetric to the existing OUTPUT Stage-1→Stage-2), then realign the
read-data-valid model by +1 so `dst`/`dok`/`dout` stay coherent.
- `jtframe_burst_io.v`: insert `(* preserve *) reg [15:0] dq_cap; dq_cap <= sdram_dq;` (IOB input
  reg) and change the consumer-facing capture to `dout <= dq_cap;` (internal reg→reg). +1 cycle on
  `dout`.
- Realign valid: the cleanest is to make the bank model emit `dst`/`dok`/`rdy` one cycle later so
  they track the delayed `dout`. `jtframe_sdram64_bank.v` `DST/RDY` are derived from `READ`; needs a
  +1 (e.g. a `CAPLAT`-style extra, or extend the SHIFTED ladder to a +3 case). **This is the delicate
  part** — `dst/dok/rdy/in_busy/dqm_busy` are a coherent set computed from `st[]` shifts; bump them
  together, not piecemeal.
- `Solarus.sdc`: replace the multicycle-2 mask with an honest `set_input_delay -clock SDRAM_CLK`
  (max/min from AS4C32M16 tAC/tOH + the DDIO forward delay). Already partially present
  (`set_input_delay ... SDRAM_DQ` lines 71-72) — reconcile so the honest model is the ONLY one.
- **Scope guard:** if the model realignment cascades beyond the bank's strobe set into the cache_mux
  handshake, STOP — that's the mis-scope signal.

### Option B (larger, "align to upstream"): adopt jtframe's canonical MiSTer SDRAM clock/capture
This integration bolted fallback-C (separate phase-shifted clk + multicycle mask) onto `.SHIFTED(0)`.
jotego's reference MiSTer cores capture DQ correctly with jtframe's own clocking + `SHIFTED`/SDC.
Re-deriving from the upstream `jtframe_sdram64` MiSTer reference (correct SHIFTED, clock phase, and
jtframe's shipped SDC) may be more correct than layering another fix — but it's a bigger change with
its own bring-up risk. Consider only if Option A's model realignment proves intractable.

## Validation gates
- Zero-delay suite green: `cd fpga/sim && ./run_sims.sh` (esp. `tb_scan_qworddup`, `tb_scanout_sdram`,
  `tb_vram_contention`, `tb_comp_*`). The +1 latency must not break any (they use handshakes, should
  tolerate it — that's the proof the realignment is correct).
- Micron-timing: `tb_vram_contention` / `tb_scan_qworddup` under `-DUSE_MICRON` still PASS.
- **HW is the real bar (timing bug, sim-blind):** build, deploy, and re-measure with the scratchpad
  tools (`deploy_measure.sh` + `seam_metric.py`). PASS = seam gone (no energy at x=64/128/192/256 on a
  near-black frame). Validate across ≥2 independent fits (timing wanders run-to-run; one clean fit is
  necessary, not sufficient — per the old plan's 618j/618k lesson).

## Files in play
- `fpga/rtl/jtframe/jtframe_burst_io.v` (capture stage) — VENDORED, has PROVENANCE.md; edit + note the deviation.
- `fpga/rtl/jtframe/jtframe_sdram64_bank.v` (latency model) — VENDORED.
- `fpga/Solarus.sdc` (revert mask → honest input-delay).
- `fpga/sys/sys.tcl` (FAST_INPUT_REGISTER already on; verify no conflict).
- Confirm `fpga/rtl/sdram.sv` (separate CAS_LATENCY controller) is DEAD on the active path before ignoring.

## Risk summary
- Touches VENDORED jtframe timing-critical code (burst_io + bank). Editing the latency model is the
  highest-risk step; keep the strobe set coherent.
- Cannot be confirmed in functional sim (timing). Confirmation is the HW fix-and-measure loop — now
  cheap thanks to the measurement tooling.
- Build variance: a fix that passes one fit may not be robust; require 2 clean fits.
