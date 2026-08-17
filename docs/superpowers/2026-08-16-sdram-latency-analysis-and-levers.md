# SDRAM path — holistic review, measured cost model, and the first two levers

**Date:** 2026-08-16 · **Branch:** `claude/sdram-latency-mux-optimization-i762d0`
**Scope:** the whole SDRAM stack — `sdram_fb_cache` → `jtframe_cache_mux` (+arb, +flush) →
8× `jtframe_cache` → `jtframe_burst_sdram` (ctrl/mux/io/rfsh/init/bank) — plus its one real
consumer, `comp_pipeline`'s `F_WALK` source prefetcher.
**Status:** two changes landed, **sim-green, HW-UNVALIDATED**. RTL changed ⇒ needs a new RBF.
**Instruments:** `fpga/sim/tb_psrc_walk_ab.sv` and `fpga/sim/tb_miss_anatomy.sv` (both added
here; `SKIP` tier — measurement, not gates).

## TL;DR

- **The SDRAM is a one-client bus now.** Only ch5 (P_SRC, atlas reads) is live in steady state;
  ch1 (STAGE) is load-time only; ch0/ch4 were tied off by Stage 5 Phase 2 and ch2/3/6/7 were
  never used. **Multi-client arbitration work would be optimising something that no longer
  happens** — the remaining problem is single-client latency.
- **Neither burst overhead nor bandwidth is the constraint.** A 256 B block fill is 145 clk =
  128 data beats + 17 clk of ACT/tRCD/CL/STOP/PRE/tRP (12 % on a fill, ~0 % on a hit), and the
  bus runs an estimated ~10 % utilised. Bank interleaving and open-row reuse in
  `jtframe_burst_ctrl` — the classic jtframe improvements — are worth ~5 % here.
- **Two changes landed:** the PAL8 duplicate source read is gone (**1.67× warm / 1.38× cold** on
  a PAL8 span, measured), and `RFSH_PERIOD` is corrected from a ~10.8× over-refresh.
- **Retracted:** CL2→CL3 as a read-margin fix for the `.62` board. It buys nothing (below).

## 1. What SDRAM actually carries

`Solarus.sv:441-500` instantiates a 3-channel-capable mux whose channels are mostly dead:

| channel | role | state |
|---|---|---|
| ch5 P_SRC | atlas source reads | **live — the only steady-state client** |
| ch1 STAGE | atlas DDR3→SDRAM writes | live, load-time only |
| ch0 P_DST | FB destination | **tied off** — FB moved to DDR3 (Stage 5 Phase 2) |
| ch4 P_SCAN | scanout | **tied off** — `ddr3_scan_adapter` serves it now |
| ch2,3,6,7 | — | never used |

So `jtframe_cache_mux_arb`'s strict priority order, and the flush/invalidate coordination it
exists to serialise, are near-inert. Six of the eight `jtframe_cache` instances serve nothing;
ch0 alone is 8 KB of data RAM plus tags plus a full writeback FSM. Whether Quartus prunes them
is a **fit-report question, not an assumption** — see lever 5.

Bus headroom: 16 bit × 98.4375 MHz = **197 MB/s peak**. Estimated atlas traffic is ~20 MB/s
(≈230 k px/frame at PAL8 1 B/px, ~2× amplified by 256 B block over-fetch at the measured miss
rate, at 30–50 fps) — **~10 % utilised**. Labelled an estimate; it is derived, not instrumented.

## 2. Measured cost model

Against the real stack (`sdram_fb_cache` `SRC_BLOCKS=128` + `jtframe_burst_sdram` +
`mt48lc16m16a2`), driven with `F_WALK`'s exact protocol (one outstanding, pulse `p0_rd`,
re-issue on `p0_ok`):

| | cycles |
|---|--:|
| cold MISS (256 B block fill) | **145** |
| warm walk, steady-state period per real read | **5** |

> **Correction to the first-pass numbers.** An earlier bench reported a "4-cycle warm hit". That
> was its own per-read counter, offset by the test task's handshake — **not** the back-to-back
> walk period. The true steady-state period is **5 clk per read** (2561 clk / 512 reads,
> free-running counter). Every derived figure below uses 5. The qualitative conclusions are
> unchanged; the arithmetic in §4 is not.

Consequences:

- **The cache adds no streaming throughput, only reuse.** The fill streams 1 qword per 4 clk,
  which is the same order as the hit service rate — the cache buys re-reads, not bandwidth.
- **Misses still cost ~44 % of the time at 97.4 % hit:** `0.974×5 + 0.026×146 ≈ 8.7 clk` per
  source qword. Enlarging the cache further is nearly exhausted (`cache-knee.md`: 256 blocks →
  98.3 %); the **miss penalty itself has never been attacked**. That is lever 3.

## 3. Change 1 — PAL8 duplicate source read eliminated

`comp_pipeline.sv` `src_byte_addr` maps linebuf qword `L` → source qword `L>>1`, so an even `L`
and the odd `L+1` after it resolve to the **same source address**. `F_WALK` was re-issuing a
full P_SRC read for that odd beat and paying another round trip to re-fetch a qword `p0_dout`
was still holding. Per CLAUDE.md, **271/335 quest assets are PAL8** — this is the gameplay path.

Fix: `src_hold` latches every real read; `dup_pending` marks the following odd beat, which is
served from `src_hold` in **one cycle with no bus traffic**. `f_beat = p0_ok | dup_pending`
replaces `p0_ok` everywhere in `F_WALK`, **including `prefetch_last`** — the final beat of a
PAL8 walk is frequently a dup beat, and keying the main FSM's advance off `p0_ok` alone would
hang `P_ADVANCE`.

**Measured A/B** (`tb_psrc_walk_ab`, 512 linebuf qwords = 2048 px, real stack):

| walk | cycles | cyc/px | |
|---|--:|--:|--|
| OLD (2 reads/src qword) COLD | 3687 | 1.800 | |
| NEW (1 read + 1 dup) COLD | 2663 | **1.300** | **1.38×** |
| OLD (2 reads/src qword) WARM | 2561 | 1.250 | |
| NEW (1 read + 1 dup) WARM | 1537 | **0.750** | **1.67×** |

Per source qword: OLD `5+5 = 10` clk / 8 px; NEW `5+1 = 6` clk / 8 px.

**Invariants held, and now asserted** (`FABRIC_ASSERT`, opt-in like the existing `#110` one):
`p0_rd && dup_pending` never overlap (one outstanding request preserved, so the `#110` contract
is untouched); a dup beat only ever serves an **odd** linebuf qword (an even one would replay
the wrong half and silently corrupt the left 4 px of every source qword); and `dup_pending` is
impossible when `!is_pal8`, so **16bpp is byte-identical to the pre-change walk**.

Alignment is handled by construction: the first beat of a walk is the `F_IDLE` kick, which
always issues a real read even when its linebuf index is odd — there is no previously-fetched
qword to reuse. Dups only ever follow an even `L`, which always did a real read.

*Not taken:* issuing the next real read **on** the dup-beat cycle rather than after it would
reach 5 clk / 8 px (a full 2×) instead of 6, but it decouples issue from consumption and its
correctness would rest on "`p0_ok` cannot arrive in ≤1 clk". Making correctness depend on a
minimum memory latency is exactly what this codebase documents against. Left as a follow-on
that needs the collision argument nailed down first.

## 4. Change 2 — `RFSH_PERIOD` 640 → 4096

**Unit confusion, not a tuning choice.** jtframe's `rfsh` input starts a **batch** of `RFSHCNT`
refresh commands, not one command (`jtframe_sdram64_rfsh.v`: `cnt <= cnt + RFSHCNT` on the rising
edge, then one REFRESH per decrement). `RFSHCNT` is jtframe's default 9, which `burst_sdram`
**doubles to 18 for XL** (alternating dies via `chip <= ~chip`) — 9 refreshes **per die** per
batch. The old comment read the parameter as "one refresh per 6.4 µs", so 640 was issuing
**~10.8× the JEDEC requirement**.

Sizing: 8192 rows / 64 ms ⇒ tREFI = 7.8125 µs ≈ 769 clk @ 98.4375 MHz. 9 commands per die per
batch ⇒ nominal batch period ≈ 6918 clk. **4096 keeps 1.69× margin** (455 clk = 4.62 µs per die)
while cutting refresh work 6.4×. Staying at `RFSHCNT=9` keeps jtframe's own validated batch shape.

**This is invisible today and that is the point.** `jtframe_sdram64_rfsh` only takes a grant when
`burst_idle_ok && noreq`, so batches were absorbed into idle gaps — measured, a 512-qword cold
walk cost 4318 clk against 4304 predicted with zero refresh interference. It is **not** free once
the source path saturates: 18 commands × 10 clk per batch / 640 = **28 % of bus cycles**. Fixing
it *before* the throughput levers, not after, is deliberate.

⚠️ This is a **data-retention** parameter. Wrong direction = silent corruption. The margin
arithmetic above is the whole safety argument and should be re-checked against the actual module
datasheet before release.

## 5. Retraction — CL2→CL3 is not a `.62` fix

Plausible-sounding and wrong. `Solarus.sdc:99-107` already establishes that `dout` is a
free-running per-cycle capture flop (`jtframe_burst_io.v:209`) and **DQ changes every beat during
a full-page burst**. CAS latency shifts *when the first beat arrives*; it does not widen the
per-beat eye. CL3 would cost a cycle per burst and buy nothing.

The genuinely available trade is different, and lever ordering makes it cheap: **capture DQ in a
phase-shifted domain through a small async FIFO** instead of directly on `clk_sys`. That
decouples read capture from the `clk_sdram` phase — which is precisely what `.62` is sensitive to
(`2026-08-06-sdram-62-phase-root-cause.md`: 5079 ps fails, six other phases pass) — for ~2 clk of
added read latency, i.e. **1.4 % of a miss and nothing on a hit**. We have latency headroom to
spend on signal-integrity margin here, which is unusual and worth using.

## 6. Remaining levers, ranked

1. **~~PAL8 dedup~~** — done (§3).
2. **Pipeline the cache hit path.** The 5 clk are `rd_rise → S_LOOKUP → S_RD_RESP → mux ok_hold`
   plus re-issue; nothing is pipelined and the walker is strictly one-outstanding, so an on-chip
   BRAM capable of 64 bit/clk delivers 8 B per 5 clk. A hit bypass (tag + data read issued
   together, 2 clk latency, 1 req/clk throughput) plus 2-deep issue approaches 1 clk/qword.
   **Biggest remaining win; touches vendored `jtframe_cache_ctrl.sv` and breaks the
   one-outstanding contract in two places.**
3. **Hit-under-fill / early restart — now MEASURED, see §9.** 130 of the 145 clk are spent
   waiting for block bytes the client never asked for. Biggest single reduction in the miss
   penalty; also `jtframe_cache_ctrl`.
4. **~~Refresh~~** — done (§4).
5. **Trim the dead channels.** Six of eight caches serve nothing, and the 8-way case/arbiter sits
   on the `addr`/`ba` path. **Read the fit report first** — Quartus may already prune it. Given
   BRAM history on this core, worth an hour.
6. **Bank interleaving / open-row reuse** in `jtframe_burst_ctrl` — the classic jtframe lever,
   worth only ~5 % here because the block is large. Listed last on purpose.

## 7. Validation status

- **Full sim suite: 43 PASS, 0 gating failures, 0 non-gating failures** (`tb_profile` skip,
  `tb_psrc_walk_ab` skip). `tb_comp_replay` is nightly-deferred but exercises the compositor
  this change touches, so it was run explicitly (`--tier=nightly`): **PASS**.
- PAL8/compositor benches re-run **with `FABRIC_ASSERT` enabled** (the suite does not define it,
  so the new SVAs are otherwise dead code): `tb_pal8_fill_8bpp`, `tb_mixed_format_seq`,
  `tb_comp_pipeline`, `tb_pal8_tilelist` — **0 assertion failures**.
- **NOT done: hardware validation.** Both changes need a Quartus build + fit/STA gate + an
  on-device A/B (map119 is the fetch-bound spot) and an operator visual gate — the PAL8 path
  touches every gameplay pixel, and the refresh change is a retention parameter. **RTL changed ⇒
  new RBF ⇒ deploy engine+RBF together** per the pairing rule in CLAUDE.md.
- **`tb_profile` phase split — recovered under Verilator.** See §8; an earlier draft of this
  document claimed the bench "wedges at any `PROF_SRC_LAT` other than its default". **That was
  wrong** and is corrected there.
- CLAUDE.md is **deliberately not updated** — its architecture notes record shipped,
  HW-validated behaviour, and neither change qualifies yet.

## 8. `tb_profile` under Verilator — and a correction

**Correction.** An earlier draft said `tb_profile` "wedges at any `PROF_SRC_LAT` other than its
default and needs more than 150 s/run under Icarus". Both halves are wrong. The bench is not
latency-sensitive, and the problem is not simulator speed: **under Icarus it completes only its
FIRST blit and then hits its own per-blit await timeout (~2 M cycles) on every subsequent one —
at the default config too.** That is why the earlier sweep produced `setup 100.0%` garbage rows.

Verilator 5.020 runs the whole bench cleanly. Evidence, in order of strength:

| | Icarus | Verilator |
|---|---|---|
| row 1 `COPY wide1band` | 4227 cyc, 1.65 cyc/px, SRCFILL 11.4 %, comp 62.6 % | **cycle-identical** |
| rows 2-9 | per-blit await timeout (~2 M cyc, `setup 100 %`) | complete, sane |
| `COPY wide` / `COPY sprite` | not reachable | **1.65 / 1.75** — exactly the floor recorded in the bench's own header |
| wall clock, full bench | killed at 3 min 21 s, 4 rows | **< 1 s** (6 s to build) |

Row 1 matching cycle-for-cycle, plus rows 2-9 reproducing the values the bench's header already
records, is the equivalence argument. The Icarus divergence beyond blit 1 is **not root-caused**.

Why this tree ports easily, where the SDRAM benches do not: `tb_profile` instantiates
`blitter_top` alone over *fixed-latency* P_SRC/P_DST models — **no `sdram_fb_cache`, no `mt48`,
no tristate**, and only two delays (`always #5 clk`, one global timeout), both handled by
`--timing`. `verilator --lint-only` over the tree reports **0 errors** (warnings only).
`tb_sdram_fb_cache` / `tb_psrc_walk_ab` are the opposite case: the Micron model carries 12
`inout`/`specify`/`$setuphold` constructs, so those stay on Icarus.

### What the recovered sweep buys — this sizes lever 2

`COPY wide` (16bpp, so one source qword = 4 px):

| `PROF_SRC_LAT` | 1 | 2 | 3 | **4** | **5** | 6 | 8 | 12 |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| cyc/px | 1.15 | 1.18 | 1.40 | 1.65 | 1.90 | 2.15 | 2.65 | 3.65 |

Linear at ~0.25 cyc/px per cycle of source latency (= 1 clk / 4 px) above ~3, then **flat below
3** — the composite becomes the bound. So:

- At the real measured 5-clk steady-state period, source latency costs ~0.75 cyc/px over floor.
- **Lever 2 (pipelined hit path, 5 → ~2 clk) is worth ~1.6× on this workload** (1.90 → 1.18) and
  lands essentially ON the 1.15 floor. **Going below 2 clk buys nothing** — that bounds the
  design target and says a 1-clk fully-pipelined hit path is not worth its complexity.

Caveat: `tb_profile`'s memory model is fixed-latency, so absolute cyc/px is a floor (its own
header says so) and these blits are 16bpp — the PAL8 dedup of §3 is not exercised here. The
*shape* (linear, knee at 3) is the model-independent result and is what sizes the lever.

### The flow, as landed

`run_sims.sh` gains `--sim=<icarus|verilator|auto>`; **`icarus` is the default and the
existing behaviour is byte-identical** (verified: full suite 43 PASS / 0 failures / 2 skipped /
1 deferred, same as before).

| mode | behaviour |
|---|---|
| `icarus` (default) | every TB under iverilog, exactly as before |
| `--sim=verilator` | only the `VERILATOR_OK` TBs; everything else reports `n/a`, not a failure |
| `--sim=auto` | Verilator where capable, Icarus for the rest, one pass; rows tagged `[verilator]` |

Eligibility is one list (`VERILATOR_OK`) next to `SKIP`/`NONGATING`, so policy stays in the
runner and CI stays a thin caller. A `SKIP`-listed **bench** in that list *does* run under
Verilator — that is the only way to get `tb_profile`'s table at all — and is forced
**non-gating**, with its stdout echoed after the results table so the numbers reach the terminal
and the CI log instead of `.simbuild/`. A new `verilator` job in `sim.yml` runs the leg; it is
deliberately **not** `continue-on-error`, so a bench that stops *building* still turns that leg
red rather than rotting.

**The bar for `VERILATOR_OK` is equivalence, not "it builds":** the TB must PASS under
`--sim=verilator` *and* agree with Icarus (or, where Icarus cannot complete, with a value
recorded independently in the TB). Verilator is 2-state and cannot catch X-propagation, so it
complements the Icarus gates rather than replacing them.

A full-suite survey under Verilator 5.020 found **32/46 build and self-report PASS**. They are
**not** promoted — passing under a 2-state simulator is not evidence a *gate* is safe to move,
and moving gates was never the goal. Two findings from that survey are recorded in the runner:

- Four build failures were **my bug, now fixed**: the Verilator path was not passing `$STUBS`.
  The stub files are `*_stub.sv` while the modules inside are `altddio_out` / `dcfifo`, so `-y`
  (which searches by module *name*) can never resolve them — the same reason the Icarus path has
  always passed them explicitly.
- **`tb_blitter_colormod_pipe` passes under Icarus and FAILS under Verilator**, one pixel wrong:
  `MISMATCH cm-copy-blit (30,30): got 0000 exp 821f`. Unexplained. It is a bit-exact golden-diff
  TB against `blitter_ref.c`, so a simulator-dependent verdict is either a 2-state/X dependence
  in the TB or a real RTL sensitivity — **not** something to write off as a Verilator bug. Worth
  its own investigation; it is deliberately left out of `VERILATOR_OK`.

## 9. Where the miss penalty actually goes — and how to remove it

`fpga/sim/tb_miss_anatomy.sv` probes ch5's `jtframe_cache_ctrl` during a single **cold** read
and reports when the requested qword physically lands in block RAM versus when the client is
finally given it:

| requested qword offset in block | total | burst ack | data in RAM | returned | **stall after its own data landed** |
|---|--:|--:|--:|--:|--:|
| **0** (the linear-walk case) | 145 | 9 | **15** | 145 | **130** |
| 8 | 145 | 9 | 47 | 145 | 98 |
| 16 | 145 | 9 | 79 | 145 | 66 |
| 31 (worst case) | 145 | 9 | 139 | 145 | 6 |

**The miss penalty is not memory latency — SDRAM hands the word over in 15 clk.** It is cache
policy: `S_POSTFILL_WAIT` is only reachable after `ext_rdy`, the *last* beat of the 128-beat
block, so `S_RD_RESP` fires 130 clk late. Offset 0 dominates, because a linear span walk enters
every new block at offset 0 — only a span's *first* miss has an arbitrary offset.

### 9.1 Early restart + hit-under-fill (one lever, not two)

Respond from the fill stream as it passes the requested offset, **and** let later requests into
the still-filling block proceed behind the fill front. Early restart alone buys nothing:
`miss_busy = st != S_IDLE` keeps the channel blocked for the remaining 130 clk regardless, so
the walker's next read stalls exactly as long.

Mechanism to add: a fill-front comparator. Today the tag is validated only on the final beat
(`tag_update_en` in `S_FILL_STREAM` when `ext_rdy`), so a lookup during the fill correctly
misses. Hit-under-fill needs "block B is filling with tag T, valid up to `stream_word` W", and
a hit when the tag matches and the offset is below W.

The rates favour it: the fill delivers a qword every **4** clk, the walker consumes one every
**5** clk (16bpp) or **6** clk per source qword (PAL8, post-§3). The consumer is the slower of
the two, so after an early restart the walker never catches the fill front inside a block and
the gate almost never stalls.

**Projection** on the cold 512-lbq PAL8 walk `tb_psrc_walk_ab` measures at 2663 clk:
8 blocks × (~15 clk to first data + 32 qwords × 6 clk) ≈ **1656 clk, ~1.61×** — within 8 % of
the *warm* walk (1537). Cold spans would cost about what warm spans cost. Projection, not a
measurement: it assumes the fill-front gate never stalls, which the rate argument above supports
but does not prove.

**Cost, stated plainly:** this forks `jtframe_cache_ctrl.sv`, which carries a *"do not hand-edit;
regenerate by re-copying"* header. There is precedent — PROVENANCE.md already records two local
deltas — but it becomes delta #3 and every future re-vendor must reapply it.

### 9.2 Then, in order

- **Sequential next-block prefetch.** With hit-under-fill in place, start block N+1's fill on
  entry to block N. The current fill ends at 145 clk while the walker needs ~192 clk to cross
  the block, so a 47-clk window hides the next miss entirely — cold becomes *equal* to warm.
  Meaningless **before** hit-under-fill: a prefetch through today's FSM blocks the channel for
  145 clk and is a net loss.
- **Row-open reuse in `jtframe_burst_ctrl`.** It runs a strict
  `ACT -> tRCD -> READ -> CL -> ...beats... -> STOP -> PRE -> tRP` per burst and
  **unconditionally precharges**; there is no row-match check anywhere on the runtime read path.
  (`jtframe_sdram64_bank` *has* row matching, but its only instance is `u_prog` on the download
  path, with `.match(1'b0)` tied off.) Eight consecutive 256 B blocks share one 2 KB row, so a
  linear walk re-activates the same row eight times. Worth ~5-6 clk of the ~15 clk residual —
  small absolutely, but ~35 % of what remains *after* the two levers above, which is why it
  ranks higher here than it does in §6.
- **`SRC_BLOCKS` 128 -> 256.** Cuts miss *count*, not penalty: 97.4 % -> 98.3 % hit
  (`cache-knee.md`), = -15 % on average source-qword cost. One parameter (SETS 32->64, still a
  power of 2) and much the cheapest item — but check BRAM headroom first, since it doubles the
  cache to 64 KB against the 61 % post-Phase-2 figure.

### 9.3 Two things NOT to do

- **Shrinking `BLKSIZE` to cut fill time is the intuitive move and it is backwards here.** The
  fill is bandwidth-bound at 16 bit/clk, so halving the block halves the penalty but doubles the
  miss count on a linear stream, and each miss still pays the fixed ~15 clk: per 256 B,
  `1 x 145 = 145` today vs `2 x 81 = 162` at 128 B blocks — strictly worse. 512 B is a marginal
  win that doubles wasted fetch. Both directions become irrelevant once the fill is no longer
  waited on.
- **Critical-word-first.** Only pays for late-offset misses, i.e. the first read of each span,
  and needs either a wrap-around burst or a second burst to fill the head — against a payoff
  early restart has already collected for the common case.

## 10. Change 3 — the fill-front comparator, built and measured

§9.1 proposed early restart + hit-under-fill and projected ~1.61x on a cold PAL8
walk. It is now built and A/B'd. **Measured 1.83x** — better than the projection,
for a reason worth recording (§10.2).

### 10.1 What landed

A parameterised local delta to the vendored cache stack, `EARLY`, **default 0 =
stock upstream**, enabled only on ch5 via `sdram_fb_cache`'s `SRC_EARLY` (default
1). Full description, file-by-file, in `fpga/rtl/jtframe/PROVENANCE.md` delta 3.

The controller now tracks a **fill front** — how many DW words of the block in
flight are valid — and answers a read the moment the front passes its word,
instead of at `ext_rdy`. Two things make it correct rather than merely fast:

- **The front is registered on the write cycle, and the early read presents its
  address no earlier than the next cycle.** So "covered" means *written in a
  strictly earlier cycle*, and the early read can never race the stream port
  writing the same address. This is the only real hazard in the design.
- **`jtframe_cache_req` had to learn to hold a request that arrives mid-miss.**
  Upstream drops it, which is unreachable upstream (its clients are
  one-outstanding and it cannot respond mid-miss) but becomes reachable the
  moment the client is unblocked during a fill. Missing this would have been a
  silent hang at every block boundary. The new `ctrl_busy` input is driven
  constant 0 when `EARLY=0`, so the default path is bit-for-bit upstream.

**Restriction, deliberate:** one-outstanding read clients only — the early path
holds a single response slot. That is the P_SRC contract (`F_WALK`, already
asserted at #110). Write misses take the stock path.

### 10.2 The A/B

`fpga/sim/tb_early_restart_ab.sv` instantiates **two independent stacks**
(`sdram_fb_cache` + `jtframe_burst_sdram` + `mt48lc16m16a2`), identical but for
`SRC_EARLY`, each driven by its own copy of `F_WALK`'s issue logic over the same
span, and compares the returned data beat-for-beat:

| walk | EARLY=0 | EARLY=1 | |
|---|--:|--:|--|
| COLD | 2663 cyc (1.300 cyc/px) | **1458 cyc (0.712 cyc/px)** | **1.83x** |
| WARM | 1537 cyc (0.750 cyc/px) | 1537 cyc (0.750 cyc/px) | 1.00x |

**read-data mismatches between the legs: 0.**

Three things in that table are worth more than the headline:

1. **The `EARLY=0` leg reproduces 2663 / 1537 exactly** — the numbers §3 measured
   before any of this existed. That is the evidence the default path is inert.
2. **WARM is 1.00x, not 0.99x or 1.02x.** No fill is in flight on a warm walk, so
   the early path never arms and the cycle count is *identical*, not merely close.
3. **COLD (1458) is now FASTER than WARM (1537).** That looks wrong and is not.
   The early response path is `er_serve -> er_rd_wait -> ok` = **2 cycles**, where
   the stock hit path is `S_IDLE -> S_LOOKUP -> S_RD_RESP` + re-issue = **5**. So
   while a fill is in flight, reads into that block are served faster than a
   normal cache hit. This is why the measurement beat the 1.61x projection, which
   had assumed early-restarted reads would cost the same 5-6 clk as hits.

   That is also **an unplanned partial delivery of lever 2** (§6): the early path
   *is* a pipelined hit path, just one that currently only exists during a fill.
   Generalising it to all hits is now a much smaller change than it looked, and
   §8's sweep says 5 -> 2 clk is worth ~1.6x on `COPY wide` and lands on the floor.

### 10.3 Validation

- **Full suite green with `SRC_EARLY=1` as the default**, so every existing TB
  that instantiates `sdram_fb_cache` exercises the new path:
  **44 PASS / 0 gating / 0 non-gating / 3 skipped / 1 deferred.**
- **`FABRIC_ASSERT` legs clean** on `tb_early_restart_ab`, `tb_sdram_fb_cache`,
  `tb_sdram_fb_cache_xl`, `tb_comp_pipeline`, `tb_pal8_fill_8bpp`,
  `tb_stage_psrc` — 0 assertion failures each.
- **The SVAs are not vacuous.** Fault injection (forcing `er_origin_covered` true)
  fires `early serve of word 0 beyond fill front 0 -> stale data` immediately, and
  the bench's own data comparison catches it independently.
- **NOT hardware-validated.** RTL changed => new RBF => engine+RBF deploy as a
  pair, per CLAUDE.md. Needs Quartus fit/STA (the early path adds a comparator and
  a mux on the block-RAM address, on a path that already exists) plus an on-device
  A/B — map119 is the fetch-bound scene — and an operator visual gate.

## 11. Row-open reuse — sized, then declined

§6 ranked this sixth and §10 said early restart had made it *more* attractive by
stripping away the streaming wait. Measuring it first said otherwise, and the
measurement is the reason it is not in the tree.

`fpga/sim/tb_rowopen_probe.sv` counts, over a cold walk spanning 4 rows:

```
  walk length              : 5847 cyc
  bursts (ACTIVATEs) issued: 32
  ... same (chip,bank,row) as the previous burst: 28
    saving = 140 cyc of 5847 = 2.39%
```

The row-hit **rate** is exactly as predicted — 28 of 32, 7 of every 8 blocks share
a 2 KB row. The **payoff** is not, and the earlier "~35 % of the residual" sizing
was the error: it was measured against a residual of 8 x 15 clk of ACT latency
that early restart has since absorbed into the fill, leaving the walk
consumer-bound. And this is the best case — one long linear span. In steady state
the cache hits 97.4 % and a hit issues no burst at all, so the lever does nothing.

Against 2.4 % on the 2.6 % path, the cost is a refresh-safety change:
`jtframe_sdram64_rfsh` is granted only at `burst_idle`, and AUTO REFRESH requires
all banks precharged, so holding a row open across idle means teaching the burst
controller to close it when a refresh is pending — a new input and state on the
data-retention path of a vendored file. The refresh-**safe** subset (reuse only
across genuinely back-to-back bursts, never holding a row through idle) is ruled
out by the same data: 32 bursts over 5847 clk is one per 183 clk against a 145 clk
burst, and the walker does not ask for the next block until ~45 clk after the
previous burst ended, so it would essentially never fire.

**Declined.** The probe is committed so the decision is re-checkable if the access
pattern ever changes.

## 12. Change 4 — the pipelined hit path

Chosen over row-open reuse because it attacks the **97.4 %** case rather than the
2.6 % one, and because §10.2 had already shown the early path beating the stock
hit path — the mechanism existed, it just only ran during a fill.

### 12.1 Where the 5 cycles are

`fpga/sim/tb_hit_anatomy.sv` traces one warm read (cycle 0 = client asserts `p0_rd`):

| cycle | |
|---|---|
| -1 | `ctrl_st=1` `S_IDLE` — request taken, tag RAM addressed with `front_req_set` |
| 0 | `ctrl_st=2` `S_LOOKUP` — `hit_blk_now` out, data RAM addressed |
| 1 | `ctrl_st=3` `S_RD_RESP` — `req_q` out, `dout`/`ok` registered |
| 2 | `cache_ok=1` — `jtframe_cache_mux` registers `ok_hold` |
| 3 | `p0_ok=1` — client sees it and issues the next read |

Back-to-back period: **5 cyc per read**, confirming §2. Only `S_LOOKUP` is
removable from inside the controller — the `ok_hold` register and the client
turnaround are structural, which **bounds this lever at 5 -> 4 before any code is
written**. §8's "5 -> 2 clk is worth ~1.6x" was reading `PROF_SRC_LAT` as if it
were the controller's cycle count; the real end-to-end request-to-`p0_ok` latency
is 4, so the achievable move is `PROF_SRC_LAT` 4 -> 3 = 1.65 -> 1.40 = **1.18x**.

> A trap worth recording: the first version of this bench waited only for `p0_ok`
> before tracing. With `SRC_EARLY=1` a read is acked while its block is still
> streaming, so it traced the EARLY path (`ctrl_st=10`, `S_FILL_STREAM`) and
> reported a 4-cycle hit. It must wait for `st == S_IDLE`.

### 12.2 What landed

`FASTHIT`, a second parameter alongside `EARLY` so the two A/B independently,
default 0 = stock, enabled on ch5 via `SRC_FASTHIT`. Full description in
`PROVENANCE.md` delta 4. It remembers the block that served the last read and, on
a `(tag,set)` match, addresses the data RAM in the request cycle — reusing delta
3's response pipeline. Reading all `WAYS` in parallel and late-selecting would
remove `S_LOOKUP` for *every* hit instead of just same-block ones, but costs
`WAYS` x the data RAM ports; this costs one comparator and three registers.

### 12.3 The A/B

`fpga/sim/tb_fasthit_ab.sv`, two stacks both `SRC_EARLY=1`, over a walk spanning
**4x the cache and then replayed**, so blocks are evicted and re-filled under the
predictor — the case that would expose a stale mapping:

| walk | `FASTHIT=0` | `FASTHIT=1` | |
|---|--:|--:|--|
| COLD | 2915 cyc (0.712 cyc/px) | 2817 cyc (0.688) | 1.03x |
| RE-WALK after eviction | 3073 cyc (0.750) | **2577 cyc (0.629)** | **1.19x** |

**0 read-data mismatches.** Cold is ~flat because early restart already covers it;
the warm leg is the point. The 1.19x agrees with both independent estimates —
the 5 -> 4 decomposition and the `PROF_SRC_LAT` sweep.

### 12.4 Validation, including one real bug

- **A cross-feature hang, caught by the suite.** The shared response pipeline was
  gated on `EARLY` alone, so `FASTHIT=1` + `EARLY=0` consumed a request and never
  answered it. `tb_early_restart_ab`'s `EARLY=0` leg timed out. Now gated on
  either. This is the argument for keeping both legs of an A/B in the gate.
- **Two assertions had to be corrected, not the RTL.** `early serve with no fill
  in flight` and `beyond fill front` were written when `er_serve` had one source;
  a fast hit legitimately has neither. They now name their source.
- **The stale-prediction SVA cross-checks every fast hit** against the tag RAM's
  own answer one cycle later — sound because `lookup_tag`/`lookup_set` still carry
  `(fh_tag, fh_set)`. Confirmed non-vacuous: corrupting `fh_blk` fires
  `fast hit read block 1, tag RAM says 0`.
- Full suite green with `SRC_FASTHIT=1` default; `FABRIC_ASSERT` legs clean on the
  cache, compositor and PAL8 TBs.
- **NOT hardware-validated.** `fh_hit` adds a comparator between the request
  address and the block-RAM address, in the request cycle — this is the one change
  in the series with a plausible fmax cost, and STA is the first gate.
