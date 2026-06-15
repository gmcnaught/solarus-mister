# #19 — PSX-pattern SDRAM second-bus controller (analog-safe burst re-integration)

**Date:** 2026-06-15. **Status:** designed, not started. **Issue:** #19 (epic
solarus-fpga-renderer, #12). **Builds on:** `fpga/docs/sdram-burst-reintegration.md`
(the scoping/diagnosis doc), #18 (generalized blit, closed), the `sdram-burst`
branch (validated-but-rolling v3.0).

## Why (measured)

The 60fps push is no longer A9-bound. HW measurement (issue #26 `[blitter luasplit]`,
2026-06-15, Solarus_20260614 core, LuaJIT+LTO baseline):

- Standing with the bg-cache ACTIVE already reaches **59.9fps** (fabric ≈ 0.4ms).
- **Scrolling/walking is FABRIC-bound: fabric ~30–39ms, A9 only ~8–12ms.** The
  bg-cache cannot engage while the camera scrolls, so the fabric recomposites the
  map every frame. Reaching the 16.67ms/60fps budget needs ~3× less fabric time.

This work attacks the fabric's **source-read** cost by moving blitter source traffic
off the shared HPS DDR3 f2h bus onto the DE10-Nano's dedicated SDRAM module (a
VRAM-like second bus), using the **proven PSX_MiSTer controller pattern** instead of
the ad-hoc v3.0 burst that rolled the analog output.

Note on sufficiency: the validated v3.0 burst gave **+18%** (17.8→21fps) on the old
readcache path — bandwidth alone does NOT close the 3× motion gap. The cycles/pixel
**pipeline** (#19 AC#1, a separate follow-on, see "Out of scope") is the other half.
This spec covers the controller/bus half only.

## Goal

A dedicated SDRAM second-bus controller that:
1. Serves blitter **source** reads over the existing burst interface
   (`burstcnt/addr/rd/dout/dout_ready/busy`), drop-in swappable with the shipping
   DDR3 readcache via a **runtime control-register** select (so the bring-up
   diagnosis can toggle SDRAM activity live without a rebuild).
2. Is **analog-safe** — re-integrates the second bus WITHOUT the YPbPr vsync roll
   (validated visually on device; counters/sims/HDMI cannot see the roll).
3. Closes timing with **more margin than v3.0's +0.076ns**.

## Non-goals (this spec)

- The cycles/pixel pipeline (≥1 px/cyc COPY/BLEND/PALPHA, dst line buffer) — that is
  #19 AC#1, a separate follow-on after this bus lands.
- Engine-side scroll-cache (a different, considered-and-deferred lever).
- Any change to the shipping DDR3 readcache path (it stays the analog-clean default).

## Architecture

The SDRAM controller is a self-contained source memory behind the blitter's existing
read interface. `blitter_top` / `ddr_blitter_arb` consume it unchanged; a runtime
control-register bit selects SDRAM-source vs DDR3-readcache-source so the analog-clean
baseline is always one live toggle away (and the bring-up diagnosis can switch it
on/off on device without a rebuild).

```
blitter_top --(burstcnt/addr/rd)-->  [SOURCE SELECT] --> DDR3 readcache (shipping, default)
                                                     \--> sdram_psx controller (this work)
                                                              |
                                                          MT48LC16M16 (second bus)
```

### Controller core (adapted from PSX_MiSTer/rtl/sdram.sv)

- **Burst:** `BL=2` reads issued back-to-back, CAS-pipelined, to assemble a wide
  cache line from a single `ACTIVE`. **Line width = 128-bit default** (8 px RGB565 =
  4 BL=2 bursts) — the balance point between amortizing the ACTIVE+CAS command
  overhead (the actual latency lever; bandwidth has ~50× headroom) and limiting
  edge over-fetch on short source-row runs. Kept as a `BURST_BEATS` parameter and
  **confirmed/tuned by a sim sweep** (see Validation). Page-wrap-safe
  (no BL=8 wrap hazard). No precharge between BL=2 bursts within an open row
  (page-open reuse); `PRE` / auto-precharge only on row change.
- **Address remap** (kept from v3.0): `col = addr[9:1]`, `bank = addr[11:10]`,
  `row = addr[24:12]` so consecutive columns sit in one row → one ACTIVE+READ per
  cache line.
- **Refresh:** distributed `AUTO_REFRESH` on a counter, arbitrated to fire only at
  request boundaries (never mid-line) so a refresh cannot stall an in-flight line
  (mid-line stalls would surface as scanout jitter).
- **Arbiter:** registered-grant, fixed-priority/round-robin over ports. Start with
  one blitter-source read port + structural headroom for a second port. The reader
  must get a **bounded grant gap** even when stalled (the `tb_ddr_blitter_arb`
  deadlock lesson: a reader gated by the grant can never assert `rd`, so a
  default-producer arbiter starves it → black screen).
- **Parameterized timings:** `CAS_LATENCY`, `BURST_BEATS`, `T_RC/T_RCD/T_RP/T_REFI`
  in one place, shared by the sim chip-model and the real MT48LC16M16 part.

### CDC / timing safety (the analog-margin concern)

The roll is diagnosed (sdram-burst-reintegration.md) as a **video-path timing-margin**
issue: a large `clk_sys` change tips the razor-thin clk_sys↔clk_pix path marginal on
real silicon; HDMI is re-buffered (tolerant), the analog DAC rolls. Mitigations baked
into the design:

- Replace `set_clock_groups -async` with **`set_false_path`** on the clk_sys↔clk_pix
  crossing (PSX-equivalent; same intent, explicit per-path).
- Keep the controller's clk_sys datapath shallow/pipelined to widen worst-slack.
- Treat **timing margin as an acceptance gate** (must beat +0.076ns), not a pass/fail
  boolean; capture and review the worst-slack path each build.

## Validation

### Autonomous (me, local iverilog + CI)

- Extend `sim/sdram_chip_model.sv` for BL=2×N + page-open reuse + refresh timing.
- New `sim/tb_sdram_psx.sv`: asserts (a) correct data for a representative blitter
  line-read trace, bit-exact vs the refmodel; (b) no protocol violation (tRCD/tRP/
  tRC/refresh honored); (c) page-wrap correctness across a row boundary; (d) bounded
  reader grant gap under contention.
- `tb_profile`: report cycles/line for sdram_psx vs v3.0 vs BL=1.
- **Cache-line-width sweep:** run `tb_profile` for `BURST_BEATS` = 64/128/256-bit
  against a representative overworld blit trace, and measure the source-row
  run-length distribution. Confirms/tunes the 128-bit default empirically (the
  optimum ≈ the average source-row run; wider over-fetches short runs, narrower
  re-adds command overhead). Cheap — all in iverilog.
- CI: Quartus build + timing closure; **gate = margin > +0.076ns**; archive worst-slack.

### On-device bring-up (you, gated — counters lie about analog)

RBF on device, **eyes on the analog/CRT**. Diagnosis is part of bring-up:
1. Runtime-toggle SDRAM activity; watch the analog display for roll onset.
2. Confirm HDMI stays clean while analog rolls → localizes to the clk_pix/analog path.
3. Vary burst rate / inject idle gaps → tests the power-transient hypothesis.
4. Inspect the build's worst-slack path → ascal vs a controller-created clk_sys→clk_pix
   path; add targeted constraints/pipelining.
5. Fix per the diagnosed cause; **re-validate analog visually** (mandatory).

The DDR3 readcache source remains the always-available, analog-clean fallback toggle.

## Sequencing & guardrails

1. Branch off `master` (shipping analog-clean DDR3 readcache baseline untouched).
2. Build controller + chip-model + tb; **all sims green** locally.
3. CI timing-close with margin > +0.076ns; commit.
4. **On-device analog bring-up with the user** — do NOT flip SDRAM-source default-on
   until the analog gate passes. Diagnose-and-fix loop if it rolls.
5. Then proceed to the cycles/pixel pipeline (#19 AC#1), separate spec.

## Acceptance criteria (this spec)

- [ ] `sdram_psx` controller serves the blitter source-read interface; source-select
      switch keeps DDR3 readcache as the default.
- [ ] Sims green and bit-exact vs refmodel; BL=2×N + page-open + refresh modeled.
- [ ] RBF builds; timing closes with margin > +0.076ns; worst-slack path captured.
- [ ] On-device: analog YPbPr vsync **clean** with SDRAM-source active (user visual
      gate), OR the roll mechanism is diagnosed and a fix path identified.
- [ ] Cycles/line improvement quantified in sim/profile vs the shipping path.

## References

- `fpga/docs/sdram-burst-reintegration.md` — scoping + roll diagnosis.
- `MiSTer-devel/PSX_MiSTer/rtl/sdram.sv`, `PSX.sdc` — the proven pattern.
- `fpga/rtl/sdram.sv` (current Sorgelig BL=1, idle), `sdram-burst` branch (v3.0).
- `fpga/rtl/ddr_blitter_arb.sv`, `fpga/sim/tb_ddr_blitter_arb.sv` — arbiter + deadlock test.
- Issue #26 `[blitter luasplit]` finding — motion is fabric-bound (the why).
