# Fabric frame generator + extracted pacing — design

**Date:** 2026-07-25
**Base:** `origin/master` @ `00a23e0` (PR #151 merged — host vblank barrier retired)
**Scope:** engine-only + a new standalone on-device test binary. **No new RBF.**

## 1. Why

PR #151 retired the host-side vblank barrier and left the free-running cap in
`present()` as the **sole** rate guard — the fabric has no reader acknowledgement,
so nothing else stops the producer overwriting a buffer the scanout is still
reading. Its HW validation was good but carries one acknowledged gap
(`docs/superpowers/data/pacing-ab/overproduction-2026-07-25.md`):

> At 59.17 fps the engine is *below* the 59.92 Hz target, so `sleep=0.0` and the cap
> is barely firing. This proves no over-production occurs; it does NOT exercise the
> cap's clamping.

Two things are therefore unproven:

1. **The cap has never clamped anything.** Every scene measured sits under the scan
   rate. Safety so far comes from the engine not being fast enough.
2. **The detector is uncalibrated.** "We never observed over-production" is weak
   evidence when we have never observed over-production under *any* condition. We do
   not know the measurement can fail.

No game scene can currently reach the rates needed to settle either. Hence a
generator that drives the fabric directly, independent of the engine.

A third motivation is concrete rather than theoretical: the cap shipped with the
**wrong constant** (16667 µs / 60.00 Hz against a real 59.9228 Hz scan). A
whole-branch review caught it by reading RTL. That does not scale. A mechanical gate
that fails on over-production catches the *consequence* without needing anyone to
re-derive the scan rate.

## 2. Components

### 2.1 `patches/mister/mister_pace.h` (extraction — prerequisite)

Pure, dependency-free, `static inline`, following the existing
`mister_blend_layer.h` / `mister_overlay_id.h` convention.

```c
/* 59.9228 Hz scan period, rounded UP so drift stays on the safe side. Carry FULL
   precision -- the RTL comment's rounded "15,700 Hz / 59.92 Hz" figures do NOT
   reproduce this value:
     pixel clock 53,693,182 Hz, H total 3420, V total 262 lines
     period = 1e6 * 3420 * 262 / 53,693,182 = 16,688.15 us  ->  rounded UP: 16689
   Deriving from the rounded 15,700 Hz instead gives 16,687.90 -> 16,688, which is
   0.25 us SHORT and would reintroduce drift.  See fpga/rtl/openbor_video_timing.sv:12-13. */
#define MISTER_PACE_TARGET_US 16689

/* Microseconds still owed before the next submit may proceed; 0 if none. */
static inline long mister_pace_sleep_us(long elapsed_us, long target_us);
```

The target is a **parameter**, not baked in, so the frame generator's calibration
mode uses the identical code path with a different constant rather than a bypass.
`present()` passes `MISTER_PACE_TARGET_US`.

This is small, and that is the point: the constant that was wrong now lives in one
place, named, with its derivation attached, reachable by unit tests.

### 2.2 `patches/mister/frame_gen/frame_gen.c` (new)

Modelled directly on `patches/mister/sdram_selftest/sdram_selftest.c` — a tiny
libc-only static armhf binary, no SDL, no Solarus, RBF loaded but **engine not
required**.

- mmaps `0x3B000000` (control block / ring / heap) and `0x3A000000` (vctrl, vsync).
- Emits one trivial frame per iteration: `blt_begin_frame(clear=1, colour)` with the
  colour **alternating between two high-contrast values every frame**.
- **Honours the `C_DONE` handshake exactly as the engine does.**
- Paces via `mister_pace_sleep_us()`.
- Samples `vctrl` (frames published, `>>2`) and `vsync_count` (frames displayed) at
  start and end, **back-to-back in-process**.

**Why alternating flat colours.** Maximum tear contrast: a torn frame appears as a
hard horizontal split between two flat colours, unmissable. Game content hides
tearing in detail. It is also the cheapest possible frame (~1.05 cyc/px), so the
fabric never becomes the limiter and the rate control stays the only thing setting
the pace.

**Why the handshake is mandatory.** Without it the generator would overwrite a ring
the fabric is still reading, producing garbage and a wedge — not a clean
over-production test. At ~0.8 ms per trivial fill (1.05 cyc/px × 76,800 px) the
fabric completes well inside an 8.3 ms (120 fps) or 4.2 ms (240 fps) budget, so the
handshake never binds and pacing remains the sole variable.

### 2.3 `scripts/build_frame_gen.sh`

Cloned from `scripts/build_sdram_selftest.sh`: cross-builds in
`solarus-armhf-build:bullseye` to `build/armhf/frame_gen`, static, linking
`blt_emitter.c` + `blt_alloc.c`.

### 2.4 `tests/pace_test.c`

Host unit tests for `mister_pace.h`, wired into `tests/run_tests.sh`:
sleep owed below target; zero at exactly target; zero above target; negative elapsed
clamped to zero; a non-default target behaves identically about its own boundary.

### 2.5 `present()` change

Replace the inline pacing block with a `mister_pace_sleep_us()` call. **Must be
behaviour-identical.**

## 3. Modes and verdicts

Both modes run the same loop through the same sleep function. **They differ only in
the target constant** — one variable between gate and control.

| mode | target | expectation | PASS condition |
|---|---|---|---|
| `--paced` | `MISTER_PACE_TARGET_US` (16689 µs) | producer held under the scan rate | `published ≤ displayed` |
| `--rate N` (default 120) | `1e6 / N` µs | over-production, ratio ≈ N / 59.92 | `published > displayed` |

The `--rate` verdict is **deliberately inverted**: it passes when over-production is
detected. If driving at 120 fps does *not* over-produce, the detector is broken and
any `--paced` pass is meaningless.

**A `--paced` pass only counts if a `--rate` run on the same build passed first.**
That ordering is the whole calibration argument and is a hard requirement of the
runbook, not a suggestion.

Because the rate is bounded, the expected ratio is **predicted, not merely large**:
60 s at 120 fps should give ~7200 published against ~3595 displayed, ratio ≈ 2.0.
The generator reports the ratio so the check is quantitative.

**Rate ceiling: 240 fps.** Above that, ~1000 submits/sec means ~1000 DDR3 snapshot
bursts/sec — an abnormal bus regime no real workload approaches. A failure there is
more likely a bus artifact than a pacing finding, and would be uninterpretable. The
spec's position: above 240 you are characterising the bus, not the pacing, and a
wedge must not be reported as a pacing result.

## 4. What this proves — and what it cannot

**Proves:** whether the producer ever outruns the scanout, objectively, at rates no
game scene can reach.

**Cannot prove:** that any given frame is untorn. A torn frame is still exactly one
published frame; the counters cannot see it.

The positive-control run ties the two together **once**: on the same unpaced-ish
`--rate` run, confirm the counters fire *and* the operator sees the tear. Thereafter
the counter verdict stands in for the visual one on regressions. This limit is
stated here deliberately so a future reader does not mistake a green `--paced` run
for proof of visual correctness.

## 5. Safety

- **Refuses to run if `solarus-run` is alive.** Two producers on one command ring is
  the two-engines-wedge hazard; the generator exits non-zero rather than corrupting
  the ring.
- Requires the RBF loaded (no core → no fabric → meaningless).
- **`--rate` deliberately tears.** Documented as expected; relaunch the engine
  afterwards. It leaves no persistent state — the next `blt_begin_frame` resets the
  ring — so a crash mid-frame is recoverable by relaunching.

## 6. Testing and validation

- **Host:** `bash tests/run_tests.sh` — new `pace_test` plus the existing suite.
- **Type-check:** the renderer, with both mandatory `-D` flags.
- **Behaviour-identity of the extraction:** re-run `scripts/perf/capture_pacing_ab.sh`
  and confirm leg B still shows fps ≈ 37.5 and `sleep=0.0`. Cheap now the harness
  exists, and it is the only thing standing between "refactor" and "silent
  regression in the sole rate guard".
- **On-device, in order:**
  1. `frame_gen --rate 120` → expect `published ≈ 2 × displayed`, PASS (detector
     calibrated). **Operator: confirm the tear is visible.**
  2. `frame_gen --paced` → expect `published ≤ displayed`, PASS (cap clamps).
  3. Record both in `docs/superpowers/data/pacing-ab/`.

Step 1 is what finally exercises the clamp and closes PR #151's recorded gap.

## 7. Rollout

The generator becomes a **required step in the pacing runbook** for any future change
touching `mister_pace.h`, `present()`'s pacing, or the scanout timing — run the
calibration then the gate. That is the mechanical check that would have caught the
16667/16689 error without anyone re-deriving the scan rate from RTL.

## 8. Risks

1. **The extraction touches code that just merged HW-validated.** Mitigated by
   byte-identical behaviour plus the A/B re-run above. If the A/B moves, stop.
2. **`--rate` is an over-production regime by construction.** Anything odd observed
   there (bus stalls, scanout instability) needs care before being called a pacing
   finding; the 240 ceiling exists to keep the regime interpretable.
3. **The generator could rot** against a renderer whose pacing moves on. The shared
   `mister_pace.h` is the mitigation: if the two diverge, they diverge at a compile
   error rather than silently.

## 9. Out of scope

- A `--load` mode (heavy fabric work). When the fabric is slow the host blocks on
  `C_DONE` and the cap never fires — that is the regime *every* real scene is already
  in, with 90 s of counter evidence. It would test the measured case, not the
  unmeasured one.
- The `SOLARUS_VSYNC_BARRIER=1` escape-hatch path. The barrier lives inside
  `ensure_frame()` and is not extractable the same way; it is the fallback, not the
  shipping path, and gating it is not worth the coupling.
- Anything about the parked blend-layer Z-order work
  (`2026-07-25-blend-layer-zorder-parked.md`).
