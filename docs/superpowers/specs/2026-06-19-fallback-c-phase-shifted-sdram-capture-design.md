# Fallback C — phase-shifted SDRAM capture clock (#34)

Date: 2026-06-19
Branch: `feature-sdram-64mb-geometry`
Status: design approved, ready for plan

## Problem

The VRAM-relocation core moves the framebuffer onto the dedicated SDRAM chip
(blitter composites to SDRAM via `vram_demux`; scanout reads SDRAM). Two wedges
were found and fixed earlier in #34:

1. Blitter dst read-issue desync (`vram_demux` S_WWAIT) — fixed `71f5c85`, HW-confirmed.
2. Source wedge traced to the SDRAM **DQ read-capture** path — partially addressed
   by the SDC fix `9396da6` but **not cured**.

The remaining root cause is physical: `sdram_psx` captures read data with
`dout64[cap_idx*16 +: 16] <= SDRAM_DQ` on `clk` (clk_sys). That `cap_idx`-indexed
1→4 demux **cannot pack into the I/O Fast-Input register**, so the path carries
~5.2 ns of fabric routing. `SDRAM_CLK` is the **inverted clk_sys** (altddio 180°),
so the chip launches read data only ~half a clk_sys period (~5.08 ns @ 98.4375 MHz)
before the clk_sys capture edge. tAC (~5.5 ns) **plus** the 5.2 ns route cannot fit
in that half-cycle window. Some fits route slightly better and survive; others wedge
(618h wedge@1733, 618i clean@10k, 618j clean@17.5k, 618k wedge@~0). The capture is
marginal and **build-variable**.

The durable alternative (a flat, Fast-Input-packable `dq_ff`, "Approach A / dq_ff")
adds **+1 read-latency**, which breaks the vendored blitter write-coalesce — proven
three times (`4dd5e39`, the 2026-06-19 redo, and the Task-3 scope-guard hit where
the fix needed a per-write accept handshake = deep vendored surgery). That path is
abandoned for now.

## Goal

Give the existing clk_sys DQ→`dout64` capture enough timing margin to be robust,
**without** changing read latency or touching the blitter write-coalesce.

## Approach (chosen: A — phase-shift the SDRAM output clock)

Add a dedicated, phase-shiftable PLL output `clk_sdram` (= clk_sys frequency,
tunable phase φ) and source `SDRAM_CLK` from it instead of the altddio-invert of
clk_sys. Shifting the clock the **chip** runs on moves *when the chip launches read
data*, sliding the data-valid eye so the (fixed) clk_sys capture edge — after the
unpackable 5.2 ns route — lands inside the valid window with margin.

The capture stays 100% on clk_sys: **zero RTL logic change, zero read-latency
change** → the blitter write-coalesce is never perturbed. This is the standard
Sorgelig / jtframe SDRAM-phase technique.

Rejected alternatives:
- **B — phase-shift the capture clock.** Clock the DQ→`dout64` demux on a late
  clock. But `cap_idx` and the `burst_cap`/`data_ready_delay` pipeline run on
  clk_sys; moving only the `dout64` write causes index/data domain skew, so the
  whole capture sub-FSM would have to move onto the shifted clock + a real CDC for
  `dout64`→consumer. More RTL, real CDC risk, no advantage over A.
- **C — hybrid retiming.** Intermediate input flop on a late clock feeding the
  demux on clk_sys; adds latency (back into blitter-fragility) or extra CDC.
  Strictly worse.

## Design

### 1. PLL — add a 4th output `clk_sdram`

The PLL files are wizard-generated but the `altera_pll` megafunction synthesizes
its C-counters from the string parameters at compile time, so a direct hand-edit is
valid (no Quartus GUI required). Current config: `number_of_clocks(3)` →
`outclk_0`=clk_sys (98.4375 MHz, 0°), `outclk_1`=clk_20m (20 MHz, unused),
`outclk_2`=clk_pix (53.693 MHz).

- `fpga/rtl/pll/pll_0002.v`: `number_of_clocks(3)→(4)`;
  `output_clock_frequency3("98.437500 MHz")`, `phase_shift3("<φ> ps")`,
  `duty_cycle3(50)`; add `output wire outclk_3` to the port list and
  `.outclk({outclk_3, outclk_2, outclk_1, outclk_0})`.
- `fpga/rtl/pll.v`: add `outclk_3` to the wrapper port list and the `pll_0002`
  instance connection.
- `fpga/Solarus.sv`: declare `wire clk_sdram;` and connect `.outclk_3(clk_sdram)`.

### 2. `sdram_psx.sv` — source SDRAM_CLK from `clk_sdram`

Keep the DDR output forwarder (clean I/O clock output); change only its `outclock`:

```
sdramclk_ddr ( .datain_h(1'b0), .datain_l(1'b1), .outclock(clk_sdram), .dataout(SDRAM_CLK), ... )
```

Because the altddio inverts (`datain_h=0`/`datain_l=1`), the net `SDRAM_CLK` phase
at the pin = φ + 180°. φ is chosen so the resulting pin phase centers the read-data
eye on the clk_sys capture edge (see §4).

`clk_sdram` is threaded as a new input port on `sdram_psx` and wired from
`Solarus.sv`. **No change to the capture logic** — `dout64[cap_idx*16 +: 16] <=
SDRAM_DQ` stays on `clk` (clk_sys). cap_idx, `burst_cap`, `data_ready_delay`, and
the entire read FSM remain on clk_sys. No read-latency change.

### 3. SDC — honest capture model (drop the mask)

`fpga/Solarus.sdc`:

- `create_generated_clock -name SDRAM_CLK`: source from the **general[3]** PLL
  output pin (clk_sdram) instead of general[0]; keep `-invert` (altddio inverts).
- **Delete** the masking `set_multicycle_path -setup -end 2` from `SDRAM_DQ[*]` to
  `dout64[*]` (added in `9396da6` — it hides the path rather than timing it).
- **Restore an honest `set_input_delay`** on `SDRAM_DQ` referenced to `SDRAM_CLK`,
  with max/min from the **AS4C32M16 datasheet** tAC (clock-to-output access, max)
  and tOH (output data hold, min), plus a small board/package allowance. Validate
  the exact numbers against the datasheet during implementation — do **not** reuse
  the old guessed 6.4/3.2.
- `clk_sdram` (general[3]) must **NOT** be added to the `set_clock_groups
  -asynchronous` list — it is timed **synchronously** with clk_sys so the DQ→dout64
  capture path is actually analyzed (the whole point: a real, honest margin).
- Keep the existing clk_sys↔SDRAM_CLK multicycle for the multi-cycle CAS round trip
  and the `set_output_delay` on command/address/data toward the chip (re-verify the
  write/command launch side still meets timing at the new phase; STA covers it).

### 4. Phase sweep + validation

φ is fit-dependent — the binding 5.2 ns route is only known post-fit — so the
optimum phase is found empirically:

1. Add an optional `sdram_phase` `workflow_dispatch` input to `build-rbf.yml` that
   seds `phase_shift3("...")` in `pll_0002.v` before building, so sweep points run
   as independent (parallelizable) CI jobs.
2. Build a small sweep of φ values spanning the period (e.g. 45° steps; refine near
   the best). For each build, read the **real** `SDRAM_DQ→dout64` setup margin from
   the STA report.
3. Pick the φ with the best honestly-modeled setup margin and bake it into
   `pll_0002.v` as the committed default.

### Done-bar (user choice: STA-margin only, no soak gate)

Done = one φ with a **genuinely positive, honestly-modeled** setup margin on
`SDRAM_DQ→dout64` (real generated clock + datasheet `set_input_delay`, mask
removed) **plus a smoke-boot on HW** to confirm the core renders with
`SOLARUS_SDRAM_SRC=1` + mystery (frame ctr `0x3A000000` advancing). Because the SDC
model is now physically real (no masking multicycle), the STA number is meaningful.

Caveat on record: a *marginal* positive (< ~0.3 ns) would warrant a soak before
calling #34 closed; flag the actual margin number when the sweep lands.

## Validation / sims

This is a physical-timing change; behavioral sims cannot show the DQ-capture margin
(they pass today and will pass after). The existing sim suite is a **regression
guard only**:
- `tb_sdram_psx` / sweep / scanout / `tb_capture_race` — must still PASS (the
  capture RTL is byte-unchanged except the new clock port; data path identical).
- `tb_blitter_system` (all phases), `tb_blitter_rd_desync`, `tb_vram_contention` —
  must still PASS (no blitter/demux/latency change). Sims drive `sdram_psx` with a
  single `clk`; the new `clk_sdram` port is the same clock in sim (zero phase), so
  behavior is unchanged.

The real validation is the STA margin (§4) + the HW smoke-boot.

## Out of scope

- The dq_ff packed capture + latency-robust blitter write-coalesce rework
  (per-write accept handshake) — abandoned for this fix; may revisit later for a
  larger-margin design.
- Fitter-seed sweep for margin cushion — orthogonal; can layer on later.
- Stripping the remaining debug probe/scaffolding — done separately at #34 close.

## Risks

- **PLL hand-edit correctness.** A malformed `pll_0002.v` fails synthesis loudly in
  CI (not silent). Mitigate by matching the existing parameter grammar exactly.
- **Write/command side at the new phase.** Shifting SDRAM_CLK also moves
  command/data launch; `set_output_delay` already models it — re-check the STA
  output side, not just input.
- **STA-only bar.** Trusting the margin number; mitigated because the model is now
  honest, with the <0.3 ns soak caveat above.
