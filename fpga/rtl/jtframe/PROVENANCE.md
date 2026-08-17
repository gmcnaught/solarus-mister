# jtframe SDRAM Vendor Provenance

## Source

- **Upstream repo:** https://github.com/jotego/jtcores (local mirror at `/Users/gmcnaught/MisterFPGA-Projects/jtcores`)
- **Upstream paths:** `modules/jtframe/hdl/sdram/` and `modules/jtframe/hdl/ram/`
- **Commit hash at time of copy (both stacks):** `1be22f172898aa2cc3db50ad372db928ed823fd2` (re-vendored 2026-08-06; burst stack was `5eaee8d9e...`, cache stack was `03176bfd...`)
- **Date both stacks vendored:** 2026-08-06
- **Previously:** burst_sdram 2026-06-25 at `5eaee8d9e` (orig 2026-06-20 at `32c81d1f`); cache stack 2026-06-21 at `03176bfd`

> **2026-08-06 full re-vendor to upstream master (`1be22f172`).** Verified
> file-by-file: every vendored file was ALREADY byte-identical to upstream master
> except the 2-line provenance header, so this is bookkeeping plus one real change
> — upstream added `SYNFILE_LO`/`SYNFILE_HI` pass-through parameters to
> `jtframe_dual_ram16.v` (3 lines). Our `jtframe_dual_ram.v` already carries the
> matching `SYNFILE` parameter, so the addition elaborates as-is.
>
> **This re-vendor does NOT change SDRAM read timing.** Upstream master still
> hardcodes `CAS Latency = 2` in `jtframe_sdram64_init.v` (the mode-register
> write, `010`), with no parameter to override it. There was no upstream fix
> waiting for the 98.4375 MHz read-capture problem — jtframe's `HF` parameter
> scales command/row timing (`PRE_ACT`/`PRE_RD`, "HF operation starts at
> 66.6MHz") but not CAS latency, which is why the vendored stack targets 48 MHz
> CL2 and we run it at roughly twice that.

## Local deltas against upstream master

Three. The first two were re-verified after the 2026-08-06 copy; the third was
added afterwards and is described in full below.

1. **`jtframe_burst_io.v`** — the `#46` DQ-capture patch (14 lines), described
   in its own section below.
2. **`jtframe_sdram64_init.v` / `jtframe_burst_sdram.v` / `sdram_fb_cache.sv`** —
   an `INIT_WAIT_SIM` parameter (default `0` = the upstream 100 us power-on
   wait, so **hardware behaviour is unchanged**). It exists because no testbench
   in this suite runs for 100 us of simulated time, so the init FSM never
   reached its `CMD_LOAD_MODE` state and the chip model ran with `Mode_reg`
   all-`x`. CAS latency lives ONLY in that register, so it — and every other
   mode-register field — was completely uncovered by simulation. Setting
   `INIT_WAIT_SIM` nonzero lets a testbench reach LOAD MODE; `tb_sdram_fb_cache`
   uses `40`. Never set it nonzero in a synthesised build.
3. **`jtframe_cache_ctrl.sv` / `jtframe_cache_req.sv` / `jtframe_cache.sv` /
   `jtframe_cache_mux.v`** — the `EARLY` early-restart + hit-under-fill path
   (default `0` = stock upstream behaviour). See its own section below.
4. **`jtframe_cache_ctrl.sv` / `jtframe_cache.sv` / `jtframe_cache_mux.v`** —
   the `FASTHIT` same-block fast hit path (default `0` = stock upstream lookup).
   Shares delta 3's response pipeline. See its own section below.

### Delta 3 — early restart + hit-under-fill (`EARLY`)

**Why.** Upstream answers a read miss only after the ENTIRE block has streamed
in: `S_POSTFILL_WAIT` is reachable only from `ext_rdy`, the last beat. Measured
on this core with `fpga/sim/tb_miss_anatomy.sv` (256 B block = 128 beats): the
requested qword is in block RAM at cycle **15** and handed to the client at cycle
**145**. 130 of the 145 cycles are spent waiting for bytes the client never asked
for. Block offset 0 dominates, because a linear span walk (`comp_pipeline`
`F_WALK`) enters every new block at offset 0.

**What.** With `EARLY=1` the controller answers a read as soon as the fill front
has passed its word, and keeps serving further reads into the same block from the
block RAM while the rest of it streams. Both halves are required: answering early
alone changes nothing, because `miss_busy` (`st != S_IDLE`) keeps the channel shut
for the remaining 130 cycles and the client's next read stalls exactly as long.

**Files touched, and why each:**

| file | change |
|------|--------|
| `jtframe_cache_ctrl.sv` | `EARLY` parameter; `fill_front`/`fill_active` tracking; the early-serve comb + 1-cycle response pipeline; skips `S_POSTFILL_WAIT` when the originating read was already answered |
| `jtframe_cache_req.sv` | new `ctrl_busy` input — hold a request that arrives mid-miss instead of dropping it |
| `jtframe_cache.sv` | `EARLY` parameter pass-through to `u_ctrl` |
| `jtframe_cache_mux.v` | `EARLY5` parameter, ch5 only (kept to one channel to keep the vendored diff small; ch5 is the only steady-state client on this core) |

**Constraints — read before enabling it on another channel:**

- **One-outstanding clients only.** The early path holds a single response slot.
  P_SRC (`comp_pipeline` `F_WALK`) satisfies this and is already asserted at #110.
- **Reads only.** A write miss takes the stock path untouched.
- `ctrl_busy` is driven constant `0` when `EARLY=0`, so `jtframe_cache_req` is
  bit-for-bit upstream in the default configuration.

**Evidence.** `fpga/sim/tb_early_restart_ab.sv` runs two independent stacks
(`SRC_EARLY` 0 vs 1) with identical `F_WALK` drivers: cold **2663 → 1458 cyc
(1.83x)**, warm **1537 → 1537 (1.00x)**, **0** read-data mismatches between the
legs. The `EARLY=0` leg reproduces the pre-change numbers exactly, which is the
inertness evidence. Four opt-in `FABRIC_ASSERT` SVAs guard the invariants and were
confirmed non-vacuous by fault injection. **Not hardware-validated.**

> **2026-06-25 burst_sdram re-vendor:** refreshed the 8 burst-stack files to
> upstream `5eaee8d9e`. Brings XL-SDRAM (dual-chip / 128MB) support — the new
> internal `sel_chip` path threaded through `jtframe_burst_sdram` → `burst_io`/
> `burst_mux`. **Behavior-neutral at our `SDRAM_AW=23`** (XL activates only at
> `AW==24`: `PAW=AW`, `sel_chip=0`). `jtframe_burst_sdram`'s external port list is
> unchanged, so `sdram_fb_cache.sv` needed no edits. Verified: full sim suite green
> (incl. `tb_jtframe_*_smoke`, `tb_sdram_fb_cache`, `tb_scanout_sdram`,
> `tb_scan_qworddup` PASS).

## Vendored Files — burst_sdram stack

| File | Purpose |
|------|---------|
| `jtframe_burst_sdram.v` | Top-level burst SDRAM controller |
| `jtframe_burst_io.v` | IO pad stage (two-stage pipeline; DDIO/tristate DQ handling) |
| `jtframe_burst_ctrl.v` | Burst state machine (ACT / TRCD / READ / WRITE / PRE) |
| `jtframe_burst_mux.v` | Mux between init / mode / refresh / prog / burst paths |
| `jtframe_burst_mode.v` | Mode register write sequencer (switches BL on prog_en toggle) |
| `jtframe_sdram64_init.v` | SDRAM power-on initialisation sequence |
| `jtframe_sdram64_rfsh.v` | Auto-refresh arbiter |
| `jtframe_sdram64_bank.v` | Per-bank open-row state machine (used by prog path) |

## Vendored Files — cache stack (commit 03176bfd1c32ffa2b137df50c63fca64f4018fbd)

Dependency tree: `jtframe_cache.sv` → {`jtframe_cache_ctrl.sv` → `jtframe_cache_req.sv`,
`jtframe_cache_data.sv` → `jtframe_dual_ram16.v` + `jtframe_dual_ram32.v`,
`jtframe_cache_tags.sv` → `jtframe_dual_ram.v`}; plus `jtframe_cache_mux.v` +
`jtframe_cache_mux_arb.v` + `jtframe_cache_mux_flush.v`.

| File | Source path | Purpose |
|------|-------------|---------|
| `jtframe_cache.sv` | `hdl/sdram/` | Top-level cache (BLOCKS/BLKSIZE/AW/DW/EW parameterised) |
| `jtframe_cache_ctrl.sv` | `hdl/sdram/` | FSM: lookup/fill/writeback/flush/invalidate |
| `jtframe_cache_req.sv` | `hdl/sdram/` | Rising-edge request capture + pending queue |
| `jtframe_cache_data.sv` | `hdl/sdram/` | Data RAM mux (16/32/64/128-bit width) |
| `jtframe_cache_tags.sv` | `hdl/sdram/` | Tag RAM (valid/dirty/tag per way/set) |
| `jtframe_cache_mux.v` | `hdl/sdram/` | Multi-client cache mux (top) |
| `jtframe_cache_mux_arb.v` | `hdl/sdram/` | Arbitration for cache_mux |
| `jtframe_cache_mux_flush.v` | `hdl/sdram/` | Flush coordination for cache_mux |
| `jtframe_dual_ram.v` | `hdl/ram/` | Single-port dual-clock RAM (used by cache_tags) |
| `jtframe_dual_ram16.v` | `hdl/ram/` | 16-bit dual-port RAM (used by cache_data DW<32) |
| `jtframe_dual_ram32.v` | `hdl/ram/` | 32-bit dual-port RAM (used by cache_data DW>=32) |

Do not hand-edit vendored files; regenerate by re-copying from upstream.

## LOCAL PATCHES (re-apply after any re-vendor)
- **`jtframe_burst_io.v` (#46):** the SDRAM DQ read-capture `dout <= sdram_dq` was
  moved OUT of the shared, reset-bearing Stage-2 `always` block into its own
  standalone, reset-less `always @(posedge clk) dout <= sdram_dq;` at the end of the
  module. Reason: in the shared block Quartus rejected `dout` as an "invalid fast
  I/O register assignment" (fit warning 176250), leaving it un-IOB-packed in core
  fabric (duplicated, delay-chain-fed) → marginal first-beat-after-burst capture →
  the 64px scanout seam. The standalone reset-less form is the canonical packable
  input-register shape (mirrors upstream's classic-path `dq_ff`); paired with the
  targeted `FAST_INPUT_REGISTER` in `fpga/Solarus.qsf`. Upstream's burst path has
  no IOB-pack for `dout` yet — candidate to push upstream. Marked inline with
  `[#46 local patch]`.

## Chip Model

`mt48lc16m16a2.v` is vendored separately into `fpga/sim/` from:
`modules/jtframe/hdl/ver/mt48lc16m16a2.v` — same upstream repo and commit.

## Regeneration

To refresh burst_sdram stack:
```bash
JT=/path/to/jtcores/modules/jtframe/hdl/sdram
cd fpga/rtl/jtframe
for f in jtframe_burst_sdram jtframe_burst_mode jtframe_burst_ctrl jtframe_burst_mux \
         jtframe_burst_io jtframe_sdram64_init jtframe_sdram64_rfsh jtframe_sdram64_bank; do
  cp "$JT/$f.v" "$f.v"
done
```

To refresh cache stack:
```bash
JT=/path/to/jtcores/modules/jtframe/hdl
cd fpga/rtl/jtframe
for f in jtframe_cache jtframe_cache_ctrl jtframe_cache_req jtframe_cache_data jtframe_cache_tags; do
  cp "$JT/sdram/$f.sv" "$f.sv"
done
for f in jtframe_cache_mux jtframe_cache_mux_arb jtframe_cache_mux_flush; do
  cp "$JT/sdram/$f.v" "$f.v"
done
for f in jtframe_dual_ram jtframe_dual_ram16 jtframe_dual_ram32; do
  cp "$JT/ram/$f.v" "$f.v"
done
```
**Do not hand-edit vendored files.** Patch upstream and re-copy.

## Notes

- `jtframe_burst_io` uses `assign sdram_dq = dq_pad` with `dq_pad` initialized to
  `16'hzzzz` on reset and driven to `16'hzzzz` when `next_dq_oe_r == 0`. This is
  correct tristate simulation behavior for iverilog; no special handling required.
- No additional `include` files were needed — all macros/ifdefs used (`VERILATOR`,
  `SIMULATION`, `JTFRAME_SDRAM_DEBUG`) have safe defaults when undefined.

### Delta 4 — same-block fast hit (`FASTHIT`)

**Why.** A stock hit costs three controller cycles — `S_IDLE` (take the request,
address the tag RAM), `S_LOOKUP` (`hit_blk_now` out, address the data RAM),
`S_RD_RESP` (`req_q` out, register `dout`/`ok`). `S_LOOKUP` exists only because
the data RAM address depends on `hit_blk_now`, which is the tag RAM's REGISTERED
output. Measured end to end in `fpga/sim/tb_hit_anatomy.sv`, a warm read is **5
cycles**: those three, plus one for `jtframe_cache_mux`'s `ok_hold` register and
one for the client's turnaround. Only `S_LOOKUP` is removable from in here.

**What.** Remember the block that served the last read (`fh_tag`/`fh_set`/
`fh_blk`). A sequential span walk asks for the next word of the same block over
and over, so on a `(tag,set)` match the block is known WITHOUT the tag lookup and
the data RAM can be addressed in the request cycle itself, reusing delta 3's
response pipeline. Reading all `WAYS` of data in parallel and late-selecting would
remove `S_LOOKUP` for every hit rather than just same-block ones, but costs
`WAYS` x the data RAM ports; this costs one comparator and three small registers.

**Staleness** is the whole correctness question. `fh_valid` is dropped on
flush/invalidate/init, and on eviction of the block it names. The eviction check
is deliberately **belt-and-braces** — see the comment at that line: fault
injection shows it is currently redundant, because every fill *completion*
re-points `fh` and `fh_hit` only fires in `S_IDLE` so it cannot fire during the
window in between. That argument is global and depends on both facts staying
true, so the local check stays.

**Cross-feature hazard, found by the suite.** The response pipeline is shared with
delta 3 and was initially gated on `EARLY` alone, so `FASTHIT=1` with `EARLY=0`
consumed a request (the fast path suppresses the `S_LOOKUP` transition) and never
answered it — a hang. It is now gated on either. `tb_early_restart_ab`'s `EARLY=0`
leg is what caught it, by timing out.

**Evidence.** `fpga/sim/tb_fasthit_ab.sv` runs two independent stacks, both
`SRC_EARLY=1`, differing only in `SRC_FASTHIT`, over a walk spanning 4x the cache
and then replayed so blocks are evicted and re-filled under the predictor:
**re-walk 3073 -> 2577 cyc (1.19x)**, cold 1.03x (early restart already covers
cold), **0** read-data mismatches. That 1.19x agrees with two independent
estimates: the 5 -> 4 cycle decomposition above, and `tb_profile`'s
`PROF_SRC_LAT` 4 -> 3 sweep (1.65 -> 1.40 cyc/px). A stale-prediction SVA
cross-checks every fast hit against the tag RAM's own answer one cycle later, and
was confirmed non-vacuous by fault injection. **Not hardware-validated.**
