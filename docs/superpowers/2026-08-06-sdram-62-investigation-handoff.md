# .62 SDRAM-source failure — investigation handoff (2026-08-06)

**Status: UNRESOLVED. The measuring instrument is not trustworthy, and the
comparative result the investigation was built on does not reproduce.** Read the
"Retracted" section before acting on anything else in this file.

---

## 1. The symptom (this part is solid)

`192.168.20.62` ("misterCade") renders **garbage** on the Solarus core: the
whole-screen background is horizontal streak noise in roughly correct colours,
while screen-space text (`www.solarus-games.org` on the title screen) renders
**pixel-correct**. `192.168.20.81` ("Superstation") rendered the same title
screen correctly earlier the same day.

Verified via MiSTer screenshots (`echo screenshot > /dev/MiSTer_cmd`, files land
in `/media/fat/screenshots/Solarus/`), not via any custom tooling.

The v1.1.0 release install on .62 is byte-verified against the GitHub asset:

| file | sha256 (matches `BUILD-INFO.txt`) |
|---|---|
| `_Other/Solarus_20260726.rbf` | `56b9aa4e…` |
| `games/Solarus/solarus-run` | `cb10af50…` |
| `games/Solarus/libs/libsolarus.so.1.6.5` | `a704952d…` |

.81 carries **byte-identical** copies of all three. The engine on .62 is
otherwise healthy while the screen is garbage: 53 fps, `escape=0`, `overflow=0`,
`dfq_drop=0`, preload completing with 31.74 MiB staged at `0x01000000`–`0x02fbe448`.

> **Release-gate implication, independent of the root cause:** every objective
> Gate 2 signal is green on a device rendering pure garbage. Gate 2 would pass
> .62 today. Gate 2 inspects no pixels.

---

## 2. RETRACTED — do not build on these

The investigation's spine was: *identical bits, .81 scores 100%, .62 scores 0%,
therefore .62's hardware is at fault.* *That is unsupported.*

**The .81 100% baseline does not survive a power cycle.** The shipped
`Solarus_20260726.rbf` scored 100% (8/8 offsets) on .81 in the afternoon and
**0%** on .81 that evening after the machine was powered off and on. Same device,
same bitstream, same test binary. Re-running the engine first did **not** restore
it, so the variable is the power cycle, not engine state.

Everything below was scored against that unstable reference and is therefore
void as evidence:

- **The phase sweep** (7 CI builds, `phase_shift3` = 1270/2540/3810/5079/6349/7619/8889 ps).
  Read as "0% at every phase on .62, 100% at two phases on .81" ⇒ "phase is not
  the variable". Unsupported.
- **The matched-config build** (`SRC_BLOCKS=2` + `phase=2540`, matching the
  working sibling core's SDRAM config). Read as "SDRAM interface exonerated".
  Unsupported — and it never got its .81 control, because .81 was powered off.
- **The half-clock build** (`clk_sys`/`clk_sdram` → 49.21875 MHz). Read as
  "doubling every setup budget doesn't help ⇒ the fault is logical, not timing".
  Unsupported.

Consequently the fix recommendations made during the session — **CAS latency 3**,
then **half-rate SDRAM**, then **core-clock timing closure** — each rested on a
link in that chain. None of them currently has an evidence base. The CASLAT work
in the tree is a solution to a hypothesis that lost its support.

---

## 3. The instrument problem (the real blocker)

`patches/mister/sdram_selftest/sdram_selftest.c` produced **five** false signals
during this session. Each one looked like a hardware verdict:

1. **Stale memory map.** Still had the pre-#154 `OFF_HEAP 0x8000` / `RING_CAP
   0x7FC0`; PR #154 moved `OFF_HEAP` to `0x100000` and the fabric's `SRC_QW`
   with it. *Fixed.*
2. **Wrong C_DONE fence.** Tested `== submit_seq`; the ring-dbuf RBF uses
   `done+1` semantics, so every offset falsely reported `HANDSHAKE-TIMEOUT` while
   the ~0.5 s spin silently acted as a delay that made the test "work". *Fixed.*
3. **Torn framebuffer reads.** Compared bank0, compared bank1, then hashed the
   winner — three separate reads of DDR3 the fabric is still snapshotting into
   every vblank. Produced 34–41% reps on a device whose round trip was perfect.
   *Fixed* (copy each window out once, then analyse the copies).
4. **Warm-up rep.** The first round trip of an offset reads whatever was on
   screen before, scoring 0% and dragging `min%` — the sweep score — to zero on
   good hardware. *Fixed* (discarded warm-up iteration).
5. **`--heap` parsed after `blt_emitter_init`** captured the heap base pointer,
   so the emitter staged from one base while the verify read another. Surfaced as
   `DDR3-PATTERN-BAD` on every offset — indistinguishable from a dead memory
   path. *Fixed.*

**Still broken, do not trust:**

- **The DDR3-source control leg fails on BOTH devices** (`0%`, `nz=2048` — exactly
  half the window), including .81 when .81 was otherwise scoring 100%. It was
  added to isolate SDRAM from the compositor/FB path and it cannot do that job.
  Likely a packing/stride fault in the tool; possibly the DDR3-source path is not
  meaningfully exercised by this fabric at all, since every real source read has
  gone through SDRAM since the #66 whole-quest preload.
- **A handshake timeout still yields a verdict.** The Maldita-then-Solarus leg
  printed `0%` alongside `HANDSHAKE-TIMEOUT=3` and `nz=0` — the fabric completed
  no frame, so there was no result to report. `HANDSHAKE-TIMEOUT` must invalidate
  the run.
- **State dependence is uncharacterised.** The tool returns 100% or 0% for the
  same hardware and bitstream depending on machine state it neither establishes
  nor checks. This is the thing to fix first.

**Method rule learned the hard way: never accept a .62 number without a matching
.81 control on the identical configuration, taken in the same session.** That
discipline is what caught #3 and #5, and its absence is what produced the
retracted conclusions.

---

## 4. Leading hypothesis

**Solarus's SDRAM initialisation may not work, and the design may have been
free-riding on whatever core ran before it.**

Supporting facts (all statically verified, none from the selftest):

- `sdram_fb_cache` wires jtframe's init-complete flag to nothing:
  `.init ()  // jtframe SDRAM-init flag (unused here)`.
- `jtframe_burst_ctrl` gates traffic on `!prog_en && !mode_busy && !rfshing` —
  **never on init being complete**. It will issue ACT/READ against an
  uninitialised chip.
- Proven in sim: the testbenches read from a chip whose `Mode_reg` was all-`x`
  and still passed. `INIT_WAIT` is 100 µs (10,000 cycles) and no TB ran that
  long, so **CAS latency had never been exercised in sim at all**.
- `prog_en` is tied to `1'b0` in `sdram_fb_cache.sv`, so `jtframe_burst_mode`
  never rewrites the mode register — the power-on init is the *only* writer.
- **An SDRAM mode register survives FPGA reconfiguration but not power-off.**
  That is the shape of a bitstream that works until the box is switched off,
  which is exactly what .81 did.

Counter-evidence: loading the working Maldita core first and then Solarus did
**not** make .62 pass — but that run reported `HANDSHAKE-TIMEOUT=3`, so it is
degraded and settles nothing either way. Worth redoing once the tool is fixed.

---

## 5. Next steps, in order

1. **Fix the instrument.** Make `sdram_selftest` self-sufficient and
   self-validating: verify (or perform) SDRAM initialisation rather than
   inheriting machine state; treat `HANDSHAKE-TIMEOUT` as "no result"; fix or
   delete the DDR3-source control leg. Until a tool returns the same answer for
   the same hardware across a power cycle, it cannot adjudicate anything.
2. **Characterise the power-cycle dependence deliberately.** On .81:
   cold-boot → straight to Solarus → score; then load another core → Solarus →
   score. That is the cheapest test of the init hypothesis, and it needs the
   fixed tool.
3. **Investigate the init gap on its own merits** regardless of the outcome —
   gating traffic on init completion is correct anyway, and now testable in sim
   because `INIT_WAIT_SIM` lets a TB reach LOAD MODE.
4. **Re-run the retracted experiments** only after 1–2, with .81 controls taken
   in the same session.

---

## 6. Artifacts and state

### Uncommitted, worth keeping
- **jtframe re-vendor to upstream master `1be22f172`** (`fpga/rtl/jtframe/*` +
  `PROVENANCE.md`). Verified file-by-file: everything was already byte-identical
  to master except the 2-line provenance header; the one real change is
  `jtframe_dual_ram16.v` gaining `SYNFILE_LO/HI`. The `#46` `jtframe_burst_io.v`
  IOB-packing patch is the only remaining local delta and was re-verified.
  **Upstream still hardcodes `CAS Latency = 2`** — there was no fix waiting.
- **`fpga/build_solarus.sh` — `DQCAP_SLACK_NS` repair.** The filter named
  `sdram_psx:sps|dout64[*]`, a module deleted when the path moved to
  `sdram_fb_cache`; it matched nothing, emitted no slack line, and the unbounded
  awk ran on into the *next* report and printed that number. Now targets
  `jtframe_burst_io:u_io|dout[*]` (confirmed correct — the same path
  `Solarus.qsf` and `Maldita.qsf` both use for `FAST_INPUT_REGISTER`), asserts
  the collection is non-empty, and is bounded by a section-end marker so a
  future rename prints `DQCAP_SLACK_NS UNREPORTED` instead of a wrong number.
  **The read-capture margin has never been correctly reported.**
- **`INIT_WAIT_SIM`** (`jtframe_sdram64_init.v` → `burst_sdram` →
  `sdram_fb_cache`, default 0 = real 100 µs). Lets a TB reach LOAD MODE; this is
  what exposed the never-programmed mode register.
- **`scripts/debug/sdram_score.sh`** — the scoring harness (moved out of the
  session scratchpad, which does not persist). Loads a candidate RBF, runs the
  selftest, reduces to `worst-min%` + `clean-offsets`. Inherits every caveat in
  §3.

### Uncommitted, now unsupported
- **CASLAT work** (`jtframe_burst_ctrl.v` `B_CL3` state, `jtframe_sdram64_init.v`
  + `jtframe_burst_mode.v` mode-register fields, plumbing through
  `burst_sdram`/`sdram_fb_cache`, `.CASLAT(3)` in `Solarus.sv`). Parameterised,
  default 2 = upstream. **CL2 mode words are proven bit-identical to the upstream
  literals** and the CL2 TBs pass. **`tb_sdram_fb_cache_cl3` FAILS** — readback
  shifted exactly one 16-bit word (`got babe0badf00dxxxx exp cafebabe0badf00d`),
  *identically with the extra wait state present and absent*, which contradicts
  both models of where the latency lands. Unresolved. Note CAS is `Mode_reg[6:4]`
  (the Micron model's own decode) — an early attempt put it at `[8:6]` and
  corrupted the op-mode/write-burst fields.
- `fpga/sim/tb_sdram_fb_cache.sv` (parameterised by `CASLAT`/`INIT_WAIT_SIM`) and
  new `fpga/sim/tb_sdram_fb_cache_cl3.sv`. Keep these even if CASLAT is dropped:
  they are the suite's only CAS coverage.

### Pushed branches — DIAGNOSTIC ONLY, NOT FOR MERGE
- `exp/srcblocks2-sdram-diag` (`c585ea3`) — `SRC_BLOCKS=2`, built with `sdram_phase=2540`.
- `exp/halfclk-sdram-diag` (`dae4086`) — `clk_sys`/`clk_sdram` 49.21875 MHz, `RFSH_PERIOD` 640→320.

### CI runs (artifacts downloadable via `gh run download <id> -n solarus-rbf`)
| purpose | run id |
|---|---|
| phase 1270 / 2540 / 3810 | 31129142491 / 31129143332 / 31129144152 |
| phase 6349 / 7619 / 8889 | 31129144956 / 31129145792 / 31129146632 |
| matched (`SRC_BLOCKS=2`, phase 2540) | 31133036066 |
| half-clock 49.21875 MHz | 31136996393 |

### Device state
Both .62 and .81 restored to `Solarus_20260726.rbf`; the temporary
`_Other/SolarusSweep.rbf` is deleted from both. `.62` still has
`games/Solarus/diag.env` (`SOLARUS_BLITTER_DIAG=1`) — harmless, but a normal
`deploy.py` run removes it. `/tmp/sdram_selftest` is on both devices and **is
lost on power cycle** (tmpfs) — re-`scp` it after any reboot, or the harness
reports `NO-DATA`.

---

## 7. Gotchas that cost time

- **`Solarus.s0` is truncated by MiSTer on core load.** A simulated OSD quest
  pick has to be re-written *after* the core is up, and `quest_manager.sh` only
  relaunches on an **mtime change**, so `touch` it or rewrite the path.
- **The sweep workflow already exists.** `build-rbf.yml` has `sdram_phase` and
  `seed` dispatch inputs with concurrency keyed per-combo. Phase must be a
  multiple of the ~105.8 ps VCO tap **and non-zero** (zero merges `outclk_3` into
  `outclk_0` and leaves `SDRAM_CLK` unconstrained). Halving `clk_sys` keeps the
  VCO, so existing tap values stay legal.
- **`RFSH_PERIOD` counts `clk_sys` cycles.** Any clock change must scale it or
  refresh drifts past the 7.8 µs row deadline (640 @ 49.2 MHz ≈ 13 µs).
- **Maldita Castilla on .62 is NOT a Jotego core.** It is the sibling GMLoader
  port (`~/MisterFPGA-Projects/maldita.castilla-mister`) with its own custom RBF.
  It uses the **same** `sdram_fb_cache`/`jtframe_burst_sdram`, **same**
  `SDRAM_AW(25)` 128MB XL geometry, **same** 98.4375 MHz `clk_sys`/`clk_sdram`,
  byte-identical `jtframe_burst_io`, same `SEED 1` and `FAST_INPUT_REGISTER` —
  differing only in `phase_shift3` (2540 vs 5079) and `SRC_BLOCKS` (2 vs 128).
  This kills the "we run jtframe at ~2× its documented 48 MHz CL2 target, unlike
  the working cores" framing that CL3 and half-rate were both argued from: a core
  that works on that board does exactly the same thing.
