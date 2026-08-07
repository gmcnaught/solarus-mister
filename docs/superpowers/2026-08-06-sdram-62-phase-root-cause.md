# .62 render fault — ROOT CAUSE: `phase_shift3 = 5079 ps` (2026-08-06/07)

Supersedes the open questions in `2026-08-06-sdram-62-investigation-handoff.md`.
The retractions in that document's §2 stand; this file re-establishes the phase
result on a trustworthy instrument.

## Result

**The shipped SDRAM clock phase (`phase_shift3 = "5079 ps"`, `fpga/rtl/pll/pll_0002.v:45`)
is the fault. It is the only swept phase that fails, and it fails only on .62.**

.62, v1.1.0 engine, screenshot judge, one continuous session:

| `phase_shift3` (ps) | phase @ 98.4375 MHz | .62 | .81 control |
|---|---|---|---|
| 1270 | 45° | PASS | — |
| 2540 | 90° | PASS | PASS |
| 3810 | 135° | PASS | PASS |
| **5079 — SHIPPED** | **180°** | **FAIL** | PASS |
| 6349 | 225° | PASS | — |
| 7619 | 270° | PASS | — |
| 8889 | 315° | PASS | — |

Six of six alternative phases pass on the failing board. The shipped phase was
re-tested *immediately after* the six passes, on the same device in the same
session, and failed again — so this is not drift, warm-up or state.

Note the shape: 5079 ps is almost exactly half the 10159 ps clock period, and it
is the *only* failing point, with 3810 and 6349 passing on either side. This is a
narrow bad window at ~180°, not a broad marginal region.

## Why the earlier sweep concluded the opposite

The original sweep read "0% at every phase on .62" and inferred phase was not the
variable. That reading came from `sdram_selftest`, which is untrustworthy (five
false verdicts; state-dependent across a power cycle — handoff §3). Scored on
pixels instead, the same phases separate cleanly. **The conclusion was inverted by
the instrument, not by the data.**

## What this excludes

Each excluded on a matched engine+RBF pair with a same-session .81 control:

| hypothesis | evidence |
|---|---|
| ring double-buffer RTL + `OFF_HEAP` move | v1.0.1 pair (`Solarus_20260723.rbf`) fails on .62 |
| FB→DDR3 scanout (Stage 5 Phase 2) | `Solarus_20260722.rbf` (on-chip SCAN) fails on .62 |
| `SRC_BLOCKS=128` P_SRC cache | `Solarus_20260721.rbf` (`RO_BLOCKS=2`) fails on .62 |
| .62's video/scanout path generally | MENU core renders on .62; language-select screen renders pixel-perfect |

That last row is the sharpest structural clue and it survives: **screen-space
overlay content renders correctly on .62 while SDRAM-atlas-sourced composite does
not.** The overlay channel sources its pixels from the DDR3 heap; the title
background sources them from SDRAM. Only the SDRAM-sourced path corrupts.

## The corruption signature

Measured on the .62 captures, not inferred:

- Strictly **period-2 in x**: mean |Δluma| at x-lag 1 is 149, at x-lag 2 is 3.6
  (a correct frame: 10.2 and 12.8). Columns x and x+2 are near-identical.
- Odd-x pixels read as **exactly zero** in 79-88% of cases.
- Within a row, the surviving even-x words are heavily repeated — several rows are
  a single 16-bit value broadcast across the whole row, interleaved with zeros.

16-bit granularity with one half of each 32-bit pair zeroed is a data-lane /
capture-timing signature, which is consistent with a clock-phase fault and
inconsistent with an addressing or cache-geometry fault.

## Recommended fix

Set `phase_shift3` to **2540 ps** in `fpga/rtl/pll/pll_0002.v`.

Rationale, strongest evidence first:
1. It passes on **both** boards here.
2. It is the value the sibling Maldita Castilla core uses — a core that has always
   worked on .62, on the same `sdram_fb_cache` / `jtframe_burst_sdram`, the same
   `SDRAM_AW(25)` 128 MB XL geometry and the same 98.4375 MHz clocks. It is
   therefore field-proven on the *failing* board.
3. It sits 2539 ps from the bad window, versus 3810's 1269 ps.

Caveats to state plainly:
- This is a **two-board sample**. Passing on .81 and .62 is not proof of margin
  across all DE10-Nano SDRAM modules.
- A phase change is a symptomatic fix. It does not address the fact that
  `jtframe_burst_ctrl` never gates traffic on SDRAM init completion and
  `jtframe_burst_mode` never rewrites the mode register (handoff §4) — still worth
  fixing on its own merits.
- `DQCAP_SLACK_NS` has **never been correctly reported** (the filter named a
  deleted module). With the repair now in the tree, the read-capture margin can
  finally be measured per phase, which would turn this empirical result into a
  quantified one. Do that before believing 2540 has margin rather than luck.

## Instrument

`scripts/debug/shot_capture.sh` + `scripts/debug/shot_score.py`. Replaces
`sdram_selftest` as the adjudicator. It measures the actual symptom through the
actual datapath, needs no on-device C, no handshake semantics and no memory-map
constants — the three things that generated every false verdict.

Verdicts: `PASS` / `FAIL-ALT` (the period-2 fault) / `FAIL-OTHER` / `BLANK` /
`NO-CAPTURE`. A core that did not load, an engine that died, or a missing
screenshot yields `NO-CAPTURE` and never a render verdict.

The gate signal is `textmatch`: exact-pixel agreement over the non-black golden
pixels of the footer band (rows 205-239, the "www.solarus-games.org" line). The
title screen cycles day/night, so a correct frame matches the full golden only
~58%; the footer is identical in both variants. Measured: correct 100%, fault
19-39%, black frame 0%.

## Traps that cost time tonight (all now handled in the harness)

- **Launching via `quest_manager` races the core load** and can leave an engine
  running across it, producing a torn frame that looks exactly like a hardware
  fault. The harness now launches the engine directly with an `S0_FILE` override
  and leaves `config/Solarus.s0` empty so `quest_manager` stays idle. One capture
  was misread as ".81 reproduces the fault" before this was fixed.
- **A PRECORE's loader outlives the core switch.** `gmloader` keeps ~200 MB
  resident; on a 492 MB box the engine is then OOM-killed mid-preload. Reaped now.
- **.62 can enter a stuck all-black state** in which *every* Solarus bitstream
  renders black, including the load bar, while the MENU core renders fine. A warm
  `reboot` clears it. Four ladder rungs were scored in this state and had to be
  re-run; the real fault only reproduces on a freshly rebooted device. **Reboot
  .62 before any run, and treat `BLANK` as "no result", never as a failure.**
- **The atlas preload takes well over a minute** (~31.7 MiB). Capturing at 30 s
  scores the "Loading..." bar on both devices. `WAIT_TITLE` defaults to 150 s.
- **A device with no `settings.dat`** sits on the language-select screen forever
  (joypad injection via `devmem 0x3A000008` did not move it). Copy
  `/media/fat/saves/Solarus/.solarus/zsdx/settings.dat` from a working device.
- **Leftover `diag.env`** (`SOLARUS_BLITTER_DIAG=1`) drops the engine below 1 fps
  by logging per-draw to FAT. Disabled on .62 as `diag.env.disabled`.

## Device state left behind

Both devices carry the **v1.1.0 release pair** (`Solarus_20260726.rbf` + engine),
sha1-verified. `_Other/SolarusShot.rbf` is the harness scratch core and is
whatever was last swept — delete it. The previously-installed core is preserved in
`games/Solarus/.rbfbak/`. `.62` renders correctly today only on a rebuilt phase;
on the shipped bitstream it still fails.
