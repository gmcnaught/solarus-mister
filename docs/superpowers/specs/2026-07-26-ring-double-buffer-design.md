# Command-ring double-buffer — overlap A9 emit with fabric composite

**Date:** 2026-07-26
**Status:** approved (user-reviewed in session)
**Predecessor:** PR #151 (vblank-barrier retirement), whose caveats named this as the
next limiter: "the single command ring still serialises A9 against fabric
(~9.8 ms/frame of A9 idle). Out of scope; deserves its own spec."

## 1. Context

Post-#151 the frame loop is: A9 emits frame S's commands, rings the doorbell,
then `ensure_frame()` at the top of frame S+1 spins on `C_DONE == S` before
touching the shared DDR state again. A9 work and fabric work are **summed** into
the frame period. Measured on the dialog capture: ~10 ms/frame of A9 idle
(`fabwait`), fps 37.5 with `fabric_hw` ≈ 16.9 ms.

An old conclusion (PR #54 era, memory `solarus-engcpp-levers-pr54`) declared
ring double-buffering "dead" — that was measured when heavy areas were A9-bound
with the fabric ~0.5 ms idle, so `max(A9, fabric) ≈ A9` and overlap bought
nothing. The world has since inverted (tilemap channel, sprite channel, blend
layers moved the pixels to the fabric): the fabric is now the busy half in the
scenes that matter, and the textbook `max` win is back.

**Goal:** pipeline depth 2 — A9 emits frame S+1 while the fabric composites
frame S. Frame period goes from `A + F` to `max(A, F, cap)` where `A` = A9
time, `F` = fabric time, cap = 16.69 ms.

**Success criteria:** per-scene fps gain matching the Phase 0 prediction within
noise; zero tearing on the objective counter test; no wedges across the
transition soak; operator visual PASS; `SOLARUS_RINGDBUF=0` behaviour identical
to today on the new RBF.

## 2. Phase 0 — sizing measurement (gates the RTL work)

One HW session under post-#151 pacing, four scenes: dialog (map 40, dialog
held), map 119 parallax, town, map 3. Capture per frame: `A` (A9 emit + engine
time), `F` (`fabric_hw`), `fabwait`, cap `sleep`, fps.

Per scene compute:
- predicted pipelined fps = `1 / max(A, F, 16.69 ms)`
- predicted added latency = `max(0, F − A)` (see §6)

**Go/no-go:** proceed to RTL only if ≥ one target scene predicts ≥ +15 % fps.
The same captures re-baseline the two map-119 conclusions #151 flagged as
barrier-contaminated (bgfill attribution, GRIDOV NO-GO) — different columns,
zero extra HW time.

### Phase 0 RESULT (2026-07-26): **GO**

Full record + traps: `docs/superpowers/data/ring-dbuf-phase0/README.md`.

| scene | fps now | A | F | pred. fps | gain | latency add |
|---|---|---|---|---|---|---|
| map 3, standing | 55.7 | 9.8 | 13.0 | 59.9 (cap) | +7.5 % | 0 |
| map 3 + dialog | 39.4 | 17.3 | 14.4 | 57.9 | **+47 %** | 0 |
| map 119 parallax | 31.0 | 16.4 | 21.5 | 46.5 | **+50 %** | 5.1 ms |
| map 119 + dialog | 33.4 | 15.4 | 19.6 | 51.0 | **+53 %** | 4.2 ms |

The halves are now balanced (A 9.8-17.4 ms vs F 13.0-21.5 ms) — dialog is
A9-bound, map 119 is fabric-bound, and only a lever that overlaps the two helps
both. This is also the direct evidence that the PR #54-era "ring double-buffer
is dead" verdict is stale (Appendix A).

**Baseline validity:** the engine already on the device was **pre-#151** (barrier
still running, `skips=8-12/60`); it read map 3 at 31.5 fps instead of 55.7. The
table above is from a freshly cross-built master engine
(`libsolarus.so.1.6.5` sha1 `ad579377…`), `skips=0/60`, `sleep≈0`.

## 3. Architecture (fabric)

### 3.1 Bank selection by sequence parity

Frame with submit seq `S` lives in bank `S & 1`. No new doorbell. The fabric
derives the bank from the frame it is **starting**, not the newest submit:
`frame_bank = (done_reg + 1) & 1` (frames are consumed in seq order; the host
may already be a frame ahead, so `submit_reg & 1` would be wrong).

### 3.2 Banking enable bit (compat)

`C_SUBMIT` is a 64-bit qword; only low32 (the seq) is used today. **Bit 32
(high-word bit 0) becomes `BANK_EN`.** Fabric: `bank = BANK_EN ? (done_reg+1)&1
: 0`.

- Old engine on new RBF: writes low32 only, high word stays 0 → bank 0 always →
  fully compatible.
- New engine, `SOLARUS_RINGDBUF=0`: writes `BANK_EN=0`, keeps the old
  `C_DONE == S-1` fence → byte-identical behaviour to today.
- New engine, `=1`: sets `BANK_EN`, alternates banks, 2-deep fence.

### 3.3 Memory layout — symmetric banks

Bank `b` = 8-qword control block + ring at `0x3B000000 + b*0x80000`, identical
internal layout (ring at ctrl+0x40, ring cap 0x7FFC0 — a bank spans exactly
0x80000 bytes). Bank 0 is byte-identical to the current map. Bank 1 occupies
`0x3B080000..0x3B100000`; **the DDR source heap base moves from `0x3B080000`
to `0x3B100000`**. This is NOT host-only: the fabric's `SRC_QW` in
`blitter_defs.vh` is derived from the heap base (`(BLT_DDR_PHYS + OFF_HEAP) >> 3`;
stage sources read from `SRC_QW + src_off`), so `SRC_QW` moves
`0x07610000 → 0x07620000` in the same RBF. Heap shrinks by exactly 512 KiB;
the plan verifies capacity against heavy-map highwater with the existing
counters.

Fabric mux: `base_qw = `BLTCTRL_QW + (bank ? 29'h10000 : 29'h0)` applied to the
5 per-frame control reads and the `S_FETCH` ring base.

Two control words stay **global at bank-0 addresses** and are never duplicated:

- `C_SUBMIT` — single poll address, monotonic seq (+1 per frame, both modes).
- `C_DONE` — monotonic completion seq.

All other per-frame words (`C_CMDCOUNT`, `C_TARGET`, `C_FLAGS`, `C_SRCSEL`,
`C_CLEAR`) are read from the starting frame's bank, which kills the
control-word overwrite race: the host writes bank ¬b's words while the fabric
reads bank b's.

### 3.4 C_DONE semantics — MUST change

Today `S_WR_DONE` writes `submit_reg` (`blitter_top.sv` S_WR_DONE:
`bm_din <= {perf_frame_cyc, submit_reg}`). With two frames in flight that
**collapses a frame**: fabric composites S, publishes `C_DONE = S+1`, frame
S+1 never runs. The change: `S_WR_DONE` writes `done_reg + 1` and updates
`done_reg <= done_reg + 1`. The poll loop then naturally picks up the next
pending frame (`C_SUBMIT != C_DONE` still true) and composites it — one frame
per handshake round, in seq order. This is correct in both modes and is the
load-bearing RTL fix; a TB must cover the two-in-flight case.

### 3.5 Publish-spacing gate (tear guard)

New hazard: with a 1-deep pipeline, publish times are composite-completion
times and can compress (slow frame → backlog → fast frame → two snapshots
inside one reader vblank window; the second writes the DDR3 bank the reader is
scanning). The `present()` cap paces *submits*, not completions — it cannot see
this.

Guard: the snapshot FSM refuses to start a snapshot if `vsync_count` has not
advanced since the previous snapshot; it defers to the next vblank edge. This
is **not** the retired `S_SNAP_WAIT` (which gated every frame in the critical
path, ~16.7 ms/frame — removed by PR #138): this gate can only fire during
backlog recovery, where the fabric was already > 1 frame behind. Steady-state
cost: zero. The existing WORK-reuse fence (`fence_done_seen`) holds the next
composite until the deferred snapshot drains.

Side benefit: restores a real fabric-side rate guard, downgrading #151's "the
cap is the SOLE guard" warning to defense-in-depth. Add a `snap_deferred`
counter so HW validation can *see* the gate fire rather than assert it.

### 3.6 RTL delta summary (blitter_top.sv only; compositor untouched)

1. `S_POLL_SUBMIT`/`S_POLL_DONE`: unchanged (global addresses); latch
   `BANK_EN` from `C_SUBMIT[32]`.
2. `S_CHK_NEW`: compute `frame_bank` when work exists.
3. Control-read and `S_FETCH` bases: bank mux.
4. `S_WR_DONE`: write/update `done_reg + 1` (§3.4).
5. Snapshot publish-spacing gate + `snap_deferred` counter (§3.5).

TL/SP/GRID/FRT/CFT/CLUT walkers, staging, comp_pipeline, fb_ddr_writer,
scanout: untouched. Those fetches resolve through per-command embedded offsets
(verified: TILELIST `u32[5]` = entry byte offset, fabric adds `TL_BUF_QW`;
GRID `cells_off` is GRID_BUF-relative).

## 4. Host-side changes

### 4.1 Emitter banks

`blt_begin_frame` becomes bank-aware: from `seq & 1` select the ctrl/ring base
and — host-side only — which **half** of SP_BUF this frame's sprite cursor runs
in. Mechanism: the per-frame cursor (`sp_used`) *starts at the parity half's
base offset* instead of 0 and caps at the half's end — offsets stay
SP_BUF-relative, so the emitted commands need no other change and the fabric
walkers are untouched.

> **CORRECTION (2026-07-26, found in Task 5 review — this section originally
> split TL_BUF too, which was wrong).** TL_BUF is **not** per-frame data and
> must **not** be split. Its only writer is `res_arm_`
> (`mister_blitter_renderer.cpp:3623,3635`), which is a **per-scene** rebuild
> that already begins with a full `drain_pipeline()` — so no frame is ever in
> flight while TL_BUF is rewritten, exactly like FRT/CFT/GRID_BUF (§4.4).
> Splitting it bought nothing and introduced a real bug: `res_arm_` writes from
> a local cursor starting at 0 regardless of bank, so a halved cap would
> spuriously latch `res_fatal` on a heavy map purely by `submit_seq` parity,
> while providing no actual separation. **TL keeps the full `tl_cap`; only
> SP_BUF is halved.** This also retires the TL capacity question entirely (the
> map-119 highwater no longer competes for a half).

SP_BUF is genuinely per-frame — the sprite channel writes entries every frame
via `sp_used`, so frame S's entries must survive while the fabric reads them and
frame S+1 writes its own. Its existing overflow counters already fall back
cleanly if a frame exceeds its half.

### 4.2 Fence — the 2-deep rule

Frame S reuses bank (S−2)'s space. `ensure_frame()`'s spin changes from
`C_DONE == S−1` to `C_DONE ≥ S−2` before writing bank `S&1`. When the fabric
keeps up this never blocks; when the fabric is the limiter the host stays at
most one frame ahead (this bound is the ≤1-frame latency cap, §6). Keep the
spin cap + usleep escape + wedge diagnostics. The per-frame fabric perf
counters (`C_DONE+4`, `C_STATUS+4`) are sampled at fence time; with two frames
in flight attribution shifts by one frame — acceptable for the banner, noted in
the runbook.

### 4.3 Heap hazard rule — deferred free, never mutate in place

Stage commands inside frame S's ring read DDR heap extents when the fabric
executes S. The host must never rewrite or free an extent a not-yet-done frame
may reference:

- **Re-upload of a dirty source** → allocate a *fresh* extent (`blt_alloc`),
  upload there, push the old extent onto a **deferred-free queue** tagged with
  the current seq; drain entries whose seq ≤ `C_DONE`.
- **Explicit frees** (surface destruction) → same queue.
- Cost: transiently one extra copy of whatever changed this frame — bounded by
  the per-frame upload volume OVERLAYSKIP already minimised.

SDRAM sources need no new hazard logic: pixels reach SDRAM via staging commands
*inside the ring*, executed in frame order by the same FSM.

### 4.4 Rare-rewrite resources (FRT/CFT/CLUT/GRID_BUF)

Rewritten on map/tileset change, not per frame. A frame that rewrites any of
them does a **full drain first** (spin `C_DONE == S−1`; one deliberately
serialized frame). Transitions already hitch for loading; one serialized frame
is invisible, and it keeps these regions out of the banking scheme entirely.

### 4.5 Flag & rollback

`SOLARUS_RINGDBUF`, **default OFF until HW-validated**. `=0`: bank 0 only,
`BANK_EN=0`, old fence, full-width TL/SP — byte-identical to today. Merge PR
ships default OFF; a follow-up flips default ON after the operator gate passes
(SPRITECH/SCROLLFAB lifecycle).

### 4.6 Observability & tests

- Banner: split `fabwait` into `fence` (the new 2-deep wait) so the A/B against
  Phase 0 is direct.
- Wire constants (CTRL1/RING1 bases, `BANK_EN` bit, heap base move) →
  `blitter_ref.h` + `test_wire_constants.py`.
- Host suite: fence-ordering model, bank alternation, deferred-free queue,
  TL/SP half-capacity fallback.
- `fpga/sim` TBs: two-in-flight handshake (§3.4), bank mux reads, publish-
  spacing gate (back-to-back publish deferred to next vblank), BANK_EN=0
  compat.

## 5. Pacing & tear safety

- Submit spacing: unchanged — the `present()` cap still spaces submits
  ≥ 16,689 µs apart.
- Publish spacing: enforced fabric-side by §3.5 — at most one snapshot per
  reader vblank window, structurally.
- Ring/ctrl overwrite: per-bank alternation + 2-deep fence (§4.2).
- Heap: deferred free (§4.3). FRT/GRID/CLUT: full drain (§4.4).
- Wedge safety: the fence remains the anti-wedge mechanism; the transition soak
  (§7) targets exactly the drain paths.

## 6. Latency

The pipeline holds at most one extra frame in flight (fence bound, §4.2).

- **Cap-limited scenes** (both halves finish inside 16.69 ms — the scenes with
  headroom): the queue never forms; by the time the cap releases submit S,
  frame S−1 has long since composited. **Zero added latency.**
- **Fabric-bound scenes** (`F` > period > `A`): the host runs one frame ahead.
  Input-to-display goes from ~`A + F` (serialized) to ~`2F` (pipelined) —
  **added latency = `F − A`**. Balanced halves (dialog: A ≈ 16, F ≈ 16.9 ms)
  → ~1 ms added while fps goes 37.5 → ~59. Only a near-idle A9 against a slow
  fabric approaches a full frame — and those scenes' frames get ~2× shorter,
  so the wall-clock add shrinks correspondingly.

**Measured (Phase 0, 2026-07-26).** No scene on this hardware reaches or exceeds
the ~60 fps cap, so a "100 fps scene" does not exist here — the `present()` cap
holds the producer just under 59.92 Hz.

| scene | regime | added latency |
|---|---|---|
| map 3, standing (55.7 fps) | cap-limited | **0** — the queue never forms |
| map 3 + dialog (39.4 fps) | A9-bound (A 17.3 > F 14.4) | **0** — `F − A` negative |
| map 119 + dialog (33.4 fps) | fabric-bound | 4.2 ms, period 30.0 → 19.6 ms |
| map 119 parallax (31.0 fps) | fabric-bound | **5.1 ms** (worst measured), period 32.3 → 21.5 ms |

So the cost is confined to fabric-bound scenes and is at most ~5 ms there, bought
with a ~50 % fps gain; every other regime pays nothing.

## 7. HW validation

- **A/B per scene** vs the Phase 0 baseline (flag on/off, same RBF): fps,
  `fence` wait, and `fabric_hw` unchanged-check (proves a clean A/B, same
  technique as #151).
- **Tear test, extended:** #151's published-vs-displayed counter method, plus a
  targeted publish-compression probe: force a backlog (map 119), watch for
  ≥ +2 excursions, and read `snap_deferred` to see the gate fire.
- **Wedge soak:** transitions (map loads = the full-drain path) and the
  lua-console teleport harness — noting the known pre-existing teleport race
  (transition/retained-scene, exists with tilemap+scrollfab off) so it is not
  misattributed.
- **Compat leg:** `SOLARUS_RINGDBUF=0` on the *new* RBF A/B'd against the old
  pairing (the bank-mux fabric runs even when the host serializes).
- **Operator visual gate** per the standing rule (no self-declared visual
  validation).

## 8. Risks

| Risk | Mitigation |
|---|---|
| Frame collapse with 2 in flight (C_DONE = submit copy) | §3.4 done+1 semantics; dedicated TB |
| Publish compression tear | §3.5 gate; targeted HW probe + counter |
| Heap extent reused while in flight | §4.3 deferred free; host-suite model |
| TL/SP half overflow on heavy maps | existing overflow counters + clean replay fallback; capacity check in plan |
| Old engine on new RBF | `BANK_EN` bit (§3.2); compat leg in HW validation |
| Heap 513 KiB smaller | capacity check vs highwater in plan |
| Perf-counter attribution shifts one frame | runbook note (§4.2) |

## 9. Out of scope

- Map 119's fabric composite cost itself (~14 ms, overdraw-bound) — the
  animated-tile replay-coalescing lever is separate; this spec only hides the
  A9 under it.
- Extending OVERLAYSKIP to `game_on_draw` — possibly superseded by #149; needs
  its own re-measure.
- Pipeline depth > 2.

## Appendix A — lever survey (post-#151), as requested in the PR

| Lever | Kind | Status |
|---|---|---|
| **Ring double-buffer (this spec)** | RTL + engine, new RBF | Named next limiter by #151; ceiling max(A,F) instead of A+F |
| Map 119 fabric overdraw (~14 ms comp, 96 % overdraw; animated-tile replay coalescing) | Fabric/engine | Open; measured under old pacing — re-baselined by Phase 0 |
| Extend OVERLAYSKIP to `game_on_draw` (dialog re-composite) | Engine-only | Possibly superseded by #149's blend-layer offload; re-measure |
| emit_walk / draw-walk reduction (map 3) | Engine-only | Likely moot — map 3 now at the 60 cap |
| Blend-layer Z-order Part B | Correctness (parked) | Not perf; parking doc has 3 candidate fixes |

The PR #54-era "ring double-buffer is dead" conclusion is recorded as **stale**:
it held only while heavy scenes were A9-bound with an idle fabric.
