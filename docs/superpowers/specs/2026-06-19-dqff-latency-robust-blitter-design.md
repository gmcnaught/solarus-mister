# dq_ff packed SDRAM capture + latency-robust blitter — design

**Issue:** #34 (VRAM relocation — SDRAM DQ-capture wedge)
**Date:** 2026-06-19
**Status:** design approved; ready for implementation plan
**Branch:** `feature-sdram-64mb-geometry`

## Problem

The SDRAM source/dst wedge (`S_SRC_SDRAM_WAIT`, also dst reads) is a **marginal,
build-variable** read-capture failure, not logic. Root cause: `sdram_psx` captures
`SDRAM_DQ` directly into `dout64[cap_idx*16 +: 16]` — a 1→4 demux that **cannot pack
into the I/O Fast-Input register**, so it carries ~5.2 ns of fabric routing. With
`SDRAM_CLK` = inverted `clk_sys` (~98.44 MHz), the capture has only a half-cycle
(~5.08 ns) for chip `tAC` (~5–6 ns) **plus** that 5.2 ns routing → physically
unmeetable. Some fits route it slightly better and survive (618i/618j ran 10k–17.5k
frames); others wedge (618h @1733, 618k @~0). The jtframe-style keeper multicycle-2
currently in `Solarus.sdc` (commit `9396da6`) makes STA *report* clean but only
**masks** the marginal path — it does not change the silicon. Confirmed: timing-clean
618k still wedges reproducibly.

The standard MiSTer/jtframe pattern avoids this by capturing into a **flat, packable
`dq_ff` register** (~0 routing) and demuxing from it. That is the durable fix.

## Constraints / prior evidence

- **bug1 (`S_WWAIT` dst desync, commit `71f5c85`) is fixed and HW-confirmed — do not
  disturb it.**
- `dq_ff` inherently adds **+1 read-data cycle** to `dout64`/`dout_ready`: the data
  arrival is CAS-fixed (`CAS_LATENCY=2`), so a pin register is necessarily one stage
  before `dout64`. The +1 cycle **cannot be absorbed inside `sdram_psx`**.
- That +1 latency previously "broke the blitter write-coalesce" (commits `4dd5e39`
  and the 2026-06-19 redo). **New finding (this design):** under +1 latency,
  `tb_blitter_system` PHASE1/2/4 **PASS**; only **PHASE3** (per-command source mux)
  fails, with **exactly 4 pixel errors = ONE qword**. The steady-state read path is
  already handshake-gated (`blitter_top` `S_RD_WAIT` waits on `mem_dout_ready`), so
  the intolerance is **one fragile transition at a source/command boundary**, not a
  global write-coalesce failure. This bounds the blitter change.
- The vendored core blitter (blend/coalesce) should be touched **minimally**; the
  SDRAM source path (`S_SRC_SDRAM_WAIT`, `S_STAGE_*`, issue #19/#34 additions) is our
  own code and free to change.

## Approach (chosen: A — `dq_ff` + targeted transition fix)

Rejected alternatives:
- **B — full write-coalesce handshake rework:** most robust but deep vendored surgery
  that failed twice; overkill given PHASE3 = one qword.
- **C — phase-shifted capture clock:** valid physical fix, zero latency, zero blitter
  edits, but adds a capture-clock domain/CDC and is not the `dq_ff` route. Kept as a
  fallback if A's blitter change unexpectedly grows.

### Component 1 — `sdram_psx`: packed `dq_ff` capture

Re-apply the reverted `4dd5e39` `sdram_psx.sv` change verbatim:
- `reg [15:0] dq_in;` (the packed pin register) `+ reg dr0_q;` (capture trigger
  delayed one cycle to match `dq_in`'s stage).
- `dq_in <= SDRAM_DQ; dr0_q <= data_ready_delay[0];` each cycle.
- Burst capture reads `dq_in` instead of `SDRAM_DQ`; word0 capture gated on `dr0_q`
  instead of `data_ready_delay[0]`; reset clears `dr0_q`.

Effect: splits the binding `SDRAM_DQ → dout64` path into `SDRAM_DQ → dq_in` (packed,
meets the half-cycle) and `dq_in → dout64` (internal reg→reg, full cycle). Data-correct
(`tb_sdram_psx`/sweep/scanout/capture_race already PASS with this change). Cost: +1
cycle on `dout_ready`/`dout64`.

### Component 2 — `Solarus.sdc`: revert the mask, restore honest `set_input_delay`

Because `dq_in` packs, `SDRAM_DQ → dq_in` genuinely meets a real input-delay
constraint. Revert the keeper-multicycle "mask" (`9396da6`) and restore the honest
`set_input_delay -clock SDRAM_CLK` model. Goal: STA reports clean **for real**, on the
now-packable path, rather than by hiding it. (Validate the magnitude against the
SDRAM datasheet; the 6.4/3.2 values are MiSTer-reference starting points.) Keep the
generated `SDRAM_CLK` + clock-to-clock multicycle. If the honest model still shows a
violation after packing, that is real signal to investigate (do not re-mask).

### Component 3 — `blitter_top`: fix the one PHASE3 transition (TDD)

Driven by the existing failing test:
1. Add a per-pixel mismatch dump to `tb_blitter_system` PHASE3 to localize the
   corrupted qword (coordinates).
2. Trace the `blitter_top` FSM at that boundary to identify the single transition
   that assumes a fixed read-data arrival cycle (candidates: the src/dst cache
   populate/hit check, or the coalesce flush vs next-read ordering at a
   command/source boundary).
3. Gate that transition on the explicit read-data-valid handshake (or equivalent
   cache-valid signal) so it absorbs the extra cycle.

**Scope guard:** the fix must remain bounded to this transition. If correcting it
cascades into broad write-coalesce changes, stop — that is the signal we have
mis-scoped, and we reconsider approach C (phase-shifted clock) instead of an open-ended
vendored rework.

## Data flow (interface unchanged)

`SDRAM_DQ → dq_in (packed) → dout64 → sdram_src_arb → vram_demux / blitter` — identical
module ports and handshakes, data simply one cycle later; absorbed everywhere by the
existing `*_dready` handshakes except the single transition fixed in Component 3.

## Testing / done-criteria

TDD order:
1. **RED:** with Components 1–2 applied, `tb_blitter_system` PHASE3 fails (1 qword);
   the per-pixel dump localizes it.
2. **GREEN:** Component 3 fix → PHASE3 PASS.
3. **No regression:** full sim suite 19/19, including `tb_blitter_rd_desync`,
   `tb_vram_contention`, `tb_capture_race`, `tb_blitter_blend/coalesce/palpha`.
4. **Build:** honest `set_input_delay` SDC reports clean global slack (real margin).
5. **HW (the real bar):** robust **across fits**, not one lucky build. Deploy and soak
   the mystery quest well past prior wedge points; ideally confirm on a **second
   fitter seed** so we are validating robustness, not a fit. Success = frame_ctr
   advances indefinitely, no `S_SRC_SDRAM_WAIT`/`S_RD_WAIT` wedge.

## Risks

- **Blitter change grows beyond one transition** → mis-scoped; fall back to C.
- **Honest SDC still violates after packing** → the `dq_in → dout64` internal path or
  another SDRAM path is the new binding one; investigate (do not re-mask).
- **HW still build-variable after dq_ff** → packing didn't fully remove the margin
  problem; escalate to C (phase-shifted capture clock) or a clock-rate reduction.

## Out of scope

- Re-introducing the debug probe (stripped in `091fcfd`; re-add only transiently if
  needed for HW forensics, then strip again).
- Fitter-seed sweep as a *primary* fix (it's a fallback / robustness check, not the
  cure).
