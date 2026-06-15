# SDRAM burst re-integration (issue #19) — scoping

**Date:** 2026-06-15. **Status:** scoped, not started. **Depends on:** #18 (generalized
blit, closed). Referenced by #19's acceptance criteria.

## Goal & validated result

Move the blitter's graphics source traffic **off the shared HPS DDR3 f2h bus** (which it
shares with the live video scanout via `ddr_blitter_arb.sv`) **onto the DE10-Nano's
separate SDRAM module** — a dedicated VRAM-like second bus, mirroring CV1000's dedicated
graphics RAM (`sdram-second-bus.md` on branch `sdram-burst`).

**Compute result is already validated** (branch `sdram-burst`, v3.0 controller):
- `BURST_LENGTH=4` + **column-low address remap** (col=addr[9:1], bank=[11:10],
  row=[24:12]) so a 64-bit beat = 4 consecutive columns in one row, one ACTIVE+READ.
- HW heavy-overworld: **21.0 fps** vs 17.8 (DDR3 readcache, shipping) vs 12.5 (BL=1
  scattered) vs 5.9 (single-beat). **+18% over the shipping readcache.**
- Sims 8/8 green (`tb_sdram_ctrl.sv` + `sdram_chip_model.sv`), CI timing closes
  (+0.076ns), render correct.

## The blocker (why it's rolled back)

**Analog YPbPr vsync ROLL** on real hardware when the SDRAM second bus is active. The
shipping core keeps the SDRAM **idle**; turning it on introduces the roll. Critically,
**CI and simulation cannot see this** — timing "closes", sims pass, the DDR framebuffer
screenshots are clean. Counters lie about analog (a recurring lesson). HDMI is unaffected;
only the analog (VGA resistor-DAC) output rolls.

## Diagnosis (by comparison to the proven PSX_MiSTer controller)

Reviewed `MiSTer-devel/PSX_MiSTer/rtl/sdram.sv` + `PSX.sdc` and our stack:

| | our standard `sdram.sv` | our burst v3.0 | PSX (proven, analog-clean) |
|---|---|---|---|
| burst | BL=1 single word | BL=4, one 64-bit beat | **BL=2 ×4 back-to-back** → 128-bit line, 1 ACTIVE; avoids BL=8 page-wrap |
| ports | 1 (rd/we) | 1 | **3 channels + DMA FIFO, arbitrated** |
| SDRAM I/O SDC | none | none | **none** |
| CDC isolation | `set_clock_groups -async` | same | `set_false_path` (equivalent) |

Conclusions:
1. **Not fundamental SDRAM noise.** PSX drives the SDRAM hard (CPU+GPU+DMA, 128-bit
   lines) and is analog-clean → heavy SDRAM activity is compatible with clean analog.
   Our roll is integration-specific and **fixable**, not a board-level dead end.
2. **Not SDRAM I/O constraints.** Neither PSX nor we constrain SDRAM_DQ/CLK delays
   (normal at 100MHz). Not the cause.
3. **It's video-path timing margin.** Our burst closed at **+0.076ns** — razor-thin, on
   the fitter-noisy ascal/video path. `Solarus.sdc` documents this exact risk: the
   clk_sys↔clk_pix CDC "works by silicon luck" and "any RTL change risks tripping the
   lucky margin." The burst is a large `clk_sys` change → tips the marginal video path →
   on real silicon (V/T) the analog (clk_pix) sync goes marginal → roll. HDMI is
   re-buffered (tolerant); the analog CRT shows roll.
4. **Exact mechanism still open** (needs HW): (a) clk_pix/PLL jitter from SDRAM current
   transients (power), vs (b) scanout CDC/arbiter marginality, vs (c) a specific
   clk_sys→clk_pix path the burst pushed marginal.

## Direction

1. **Adopt the PSX controller pattern** for the second bus instead of the ad-hoc BL=4
   hack: BL=2 pipelined back-to-back reads for a wide cache line, a proper multi-port
   arbiter, page-wrap-safe. Proven, better fit for blitter line reads, and likely closes
   with more margin.
2. **HW-diagnose the roll FIRST, before more RTL** (counters lie):
   - Toggle SDRAM activity at runtime; watch the analog display for the onset.
   - Confirm HDMI stays clean while analog rolls (localizes to the analog/clk_pix path).
   - Vary burst rate / add idle gaps (tests the power-transient hypothesis).
   - Inspect the worst-slack path in the burst build's timing report (is it ascal, or a
     clk_sys→clk_pix CDC the burst created?); add targeted constraints/pipelining.
   - Requires **the user's eyes on the analog/CRT output** + Quartus build iteration.
3. Fix per the diagnosed cause; **re-validate analog visually** (mandatory).

## Open questions
- Does the scanout's DDR3 read deadline get tighter with the second bus active (arbiter)?
- Is clk_pix sourced from a PLL whose margin/jitter degrades under SDRAM current load?
- Would routing the SDRAM on its own PLL output (isolated from clk_pix) help?

## Sequencing
Gated within the FPGA track on the 4-wide datapath (`fabric-4wide`) per `sdram-second-bus.md`.
Higher risk + heavier loop (Quartus + on-device analog validation) than the engine-side
work; the shipping analog-clean baseline is the DDR3 readcache at 17.8 fps. See memories
[[burst-dma-timing-outcome]], [[ddr-heap-allocator]], [[hybrid-core-guide]].
